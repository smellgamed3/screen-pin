use crate::desktop;
use crate::engine::{ChangeOutcome, Engine, MatchKind};
use crate::model::*;
use crate::protocol::*;
use crate::store::{ConfigStore, LoadState};
use crate::topology;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

pub struct Controller {
    engine: Engine,
    store: ConfigStore,
    monitors: Vec<MonitorSnapshot>,
    windows: Vec<WindowSummary>,
    bindings: Vec<DisplayBinding>,
    active_profile: Option<String>,
    needs_association: bool,
    protected_reason: Option<String>,
}

impl Controller {
    pub fn open(directory: PathBuf) -> Result<(Self, bool), String> {
        let (store, state) = ConfigStore::open(directory)?;
        let (config, first_run, reason) = match state {
            LoadState::New(config) => (config, true, None),
            LoadState::Ready(config) => (config, false, None),
            LoadState::ReadOnly { reason, .. } => (Config::default(), true, Some(reason)),
        };
        Ok((
            Self {
                engine: Engine::new(config)?,
                store,
                monitors: Vec::new(),
                windows: Vec::new(),
                bindings: Vec::new(),
                active_profile: None,
                needs_association: false,
                protected_reason: reason,
            },
            first_run,
        ))
    }

    fn view(&self) -> View {
        View {
            config: self.engine.config().clone(),
            windows: self.windows.clone(),
            monitors: self.monitors.clone(),
            active_profile: self.active_profile.clone(),
            bindings: self.bindings.clone(),
            needs_association: self.needs_association,
            read_only: !self.store.is_writable(),
            config_path: self.store.path().display().to_string(),
            undo_label: self.engine.undo_label().map(str::to_owned),
            startup_warning: crate::startup::warning(
                self.engine.config().settings.autostart,
                self.store.directory(),
            ),
        }
    }

    fn refresh_topology(&mut self) -> Result<(), String> {
        let mut current = match desktop::monitors() {
            Ok(monitors) => monitors,
            Err(error) => {
                self.invalidate_topology();
                return Err(error);
            }
        };
        current.sort_by(|a, b| a.key.cmp(&b.key));
        if current == self.monitors && (self.active_profile.is_some() || self.needs_association) {
            return Ok(());
        }
        // The worker is serial; stabilization never blocks the shell message loop.
        thread::sleep(Duration::from_millis(150));
        let mut confirmation = match desktop::monitors() {
            Ok(monitors) => monitors,
            Err(error) => {
                self.invalidate_topology();
                return Err(error);
            }
        };
        confirmation.sort_by(|a, b| a.key.cmp(&b.key));
        if confirmation != current {
            self.invalidate_topology();
            return Err("正在识别显示器，请稍后刷新或重试".into());
        }
        self.apply_topology(current)
    }

    fn invalidate_topology(&mut self) {
        self.active_profile = None;
        self.bindings.clear();
        self.monitors.clear();
        self.needs_association = true;
    }

    fn apply_topology(&mut self, current: Vec<MonitorSnapshot>) -> Result<(), String> {
        // Invalidate the old profile BEFORE resolving or saving a new combination.
        // A failed save must not cache a new topology with the previous writable profile.
        self.invalidate_topology();
        if !self.store.is_writable() {
            self.monitors = current;
            return Ok(());
        }
        let resolution = topology::resolve(self.engine.config(), &current)?;
        if let Some(candidate) = resolution.candidate {
            self.engine
                .commit_config(candidate, |config| self.store.save(config))?;
        }
        self.active_profile = resolution.active_profile;
        self.bindings = resolution.bindings;
        self.needs_association = resolution.needs_association;
        self.monitors = current;
        Ok(())
    }

    fn profile_id(&self) -> Result<String, String> {
        if !self.store.is_writable() {
            return Err("配置受保护，请先恢复备份或明确新建配置".into());
        }
        self.active_profile
            .clone()
            .ok_or_else(|| "显示器身份尚未确定，请先关联屏幕".into())
    }

    fn assert_active(&self, id: &str, revision: u64) -> Result<(), String> {
        self.engine.require_revision(revision)?;
        if self.profile_id()? != id {
            return Err("非活动方案仅供查看，不能写入当前窗口配置".into());
        }
        Ok(())
    }

    fn capture(&self, handle: isize, pid: u32, token: u64) -> Result<WindowSnapshot, String> {
        desktop::validate_window_token(handle, pid, token)?;
        let snapshot = desktop::capture(handle)?;
        if snapshot.pid != pid || snapshot.token != token {
            return Err("目标窗口已改变，请重新选择".into());
        }
        Ok(snapshot)
    }

    fn check_topology(&mut self) -> Result<(), String> {
        let mut now = desktop::monitors()?;
        now.sort_by(|a, b| a.key.cmp(&b.key));
        if now != self.monitors {
            self.active_profile = None;
            self.bindings.clear();
            self.monitors.clear();
            return Err("显示器已变化，本次操作已取消，请重试".into());
        }
        Ok(())
    }

    fn revalidate(&mut self, window: &WindowSnapshot) -> Result<(), String> {
        self.check_topology()?;
        let now = self.capture(window.handle, window.pid, window.token)?;
        if now.process_started != window.process_started || now.app_id != window.app_id {
            return Err("目标进程已改变，本次操作取消".into());
        }
        let profile = self.profile_id()?;
        let old = self
            .engine
            .match_window(&profile, window)?
            .map(|m| m.preset.id.as_str());
        let new = self
            .engine
            .match_window(&profile, &now)?
            .map(|m| m.preset.id.as_str());
        if old != new {
            return Err("窗口标题改变了匹配规则，请重新触发".into());
        }
        Ok(())
    }

    fn placement(&self, window: &WindowSnapshot) -> Result<Placement, String> {
        let binding = self
            .bindings
            .iter()
            .find(|b| b.monitor_key == window.display_key)
            .ok_or("当前窗口所在显示器尚未关联")?;
        let monitor = self
            .monitors
            .iter()
            .find(|m| m.key == window.display_key)
            .ok_or("当前显示器已不可用")?;
        Ok(Placement {
            display_id: binding.display_id.clone(),
            rect: RelativeRect::from_rect(window.normal_rect, monitor.work)?,
            maximized: window.maximized,
        })
    }

    fn ensure_matched_target_available(
        &self,
        profile: &str,
        window: &WindowSnapshot,
    ) -> Result<(), String> {
        if let Some(matched) = self.engine.match_window(profile, window)?
            && !self
                .bindings
                .iter()
                .any(|b| b.display_id == matched.preset.placement.display_id)
        {
            return Err("命中的预设目标屏幕尚未关联，原预设已保留".into());
        }
        Ok(())
    }

    fn preset_app(&self, profile: &str, preset: &str) -> Result<String, String> {
        self.engine
            .config()
            .profile(profile)
            .and_then(|p| {
                p.applications.iter().find(|a| {
                    a.default.as_ref().is_some_and(|d| d.id == preset)
                        || a.rules.iter().any(|r| r.preset.id == preset)
                })
            })
            .map(|a| a.app_id.clone())
            .ok_or_else(|| "预设已不存在，请刷新".into())
    }

    fn execute(&mut self, request: Request) -> Result<String, String> {
        match request {
            Request::Refresh => {
                self.refresh_topology()?;
                self.windows = desktop::windows()?;
                if let Some(reason) = &self.protected_reason {
                    return Err(reason.clone());
                }
                Ok(if self.needs_association {
                    "请选择已有方案并关联屏幕，或明确建立新环境".into()
                } else {
                    "已就绪：先摆好窗口，用热键记住位置，再随时恢复".into()
                })
            }
            Request::Remember { handle, pid, token } => {
                self.refresh_topology()?;
                let profile = self.profile_id()?;
                let window = self.capture(handle, pid, token)?;
                self.ensure_matched_target_available(&profile, &window)?;
                let placement = self.placement(&window)?;
                self.revalidate(&window)?;
                let result = self
                    .engine
                    .remember(&profile, &window, placement, |config| {
                        self.store.save(config)
                    })?;
                if result == ChangeOutcome::Unchanged {
                    return Ok("位置未变化，已保留上一次有效撤销".into());
                }
                Ok(format!(
                    "已记住：{}",
                    self.engine.undo_label().unwrap_or(&window.app_name)
                ))
            }
            Request::CreateDefault { handle, pid, token } => {
                self.refresh_topology()?;
                let profile = self.profile_id()?;
                let window = self.capture(handle, pid, token)?;
                let placement = self.placement(&window)?;
                self.revalidate(&window)?;
                self.engine
                    .create_default(&profile, &window, placement, |c| self.store.save(c))?;
                Ok(format!(
                    "已创建应用默认：{}（同应用窗口共用），已有标题规则保留",
                    window.app_name
                ))
            }
            Request::CreateRule {
                handle,
                pid,
                token,
                keyword,
            } => {
                self.refresh_topology()?;
                let profile = self.profile_id()?;
                let window = self.capture(handle, pid, token)?;
                let placement = self.placement(&window)?;
                self.revalidate(&window)?;
                self.engine
                    .create_rule(&profile, &window, &keyword, placement, |config| {
                        self.store.save(config)
                    })?;
                Ok(format!(
                    "已创建标题规则：{}",
                    self.engine.undo_label().unwrap_or(&keyword)
                ))
            }
            Request::Restore { handle, pid, token } => {
                self.refresh_topology()?;
                let profile = self.profile_id()?;
                let window = self.capture(handle, pid, token)?;
                let matched = self
                    .engine
                    .match_window(&profile, &window)?
                    .ok_or("尚未配置：先摆好窗口，再按“记住位置”热键")?;
                let scope = match matched.kind {
                    MatchKind::Default => "应用默认（同应用窗口共用）".to_owned(),
                    MatchKind::Rule { keyword, .. } => format!("标题包含“{keyword}”"),
                };
                let placement = matched.preset.placement.clone();
                let binding = self
                    .bindings
                    .iter()
                    .find(|b| b.display_id == placement.display_id)
                    .ok_or("预设目标屏幕尚未关联，窗口保持原状")?;
                let monitor = self
                    .monitors
                    .iter()
                    .find(|m| m.key == binding.monitor_key)
                    .ok_or("目标屏幕已不可用")?
                    .clone();
                self.revalidate(&window)?;
                let result = desktop::restore(&window, &placement, &monitor)?;
                let status = match result {
                    RestoreOutcome::AlreadyCorrect => "已符合预设",
                    RestoreOutcome::Restored => "已恢复",
                    RestoreOutcome::Constrained => "受限恢复：应用限制了窗口尺寸或位置",
                    RestoreOutcome::Unconfirmed => "暂无法确认：请求可能稍后完成",
                };
                Ok(format!("{status} · {} · {scope}", window.app_name))
            }
            Request::Undo => {
                self.refresh_topology()?;
                if !self.store.is_writable() {
                    return Err("配置处于保护状态".into());
                }
                let label = self.engine.undo_label().unwrap_or("").to_owned();
                self.engine.undo(|config| self.store.save(config))?;
                Ok(format!("已撤销预设更新，窗口保持原状：{label}"))
            }
            Request::EditPreset {
                profile_id,
                preset_id,
                placement,
                keyword,
                expected_revision,
            } => {
                self.refresh_topology()?;
                self.assert_active(&profile_id, expected_revision)?;
                if !self
                    .bindings
                    .iter()
                    .any(|b| b.display_id == placement.display_id)
                {
                    return Err("目标屏幕未关联".into());
                }
                let app = self.preset_app(&profile_id, &preset_id)?;
                self.check_topology()?;
                let outcome = self.engine.edit(
                    &profile_id,
                    &app,
                    &preset_id,
                    placement,
                    keyword.as_deref(),
                    |c| self.store.save(c),
                )?;
                Ok(if outcome == ChangeOutcome::Changed {
                    "已保存预设，可撤销本次更新".into()
                } else {
                    "无变化，已保留撤销记录".into()
                })
            }
            Request::DeletePreset {
                profile_id,
                preset_id,
                expected_revision,
            } => {
                self.refresh_topology()?;
                self.assert_active(&profile_id, expected_revision)?;
                let app = self.preset_app(&profile_id, &preset_id)?;
                self.engine
                    .delete(&profile_id, &app, &preset_id, |c| self.store.save(c))?;
                Ok("已删除选中的预设".into())
            }
            Request::MoveRule {
                profile_id,
                preset_id,
                direction,
                expected_revision,
            } => {
                self.refresh_topology()?;
                self.assert_active(&profile_id, expected_revision)?;
                let app = self.preset_app(&profile_id, &preset_id)?;
                self.engine
                    .move_rule(&profile_id, &app, &preset_id, direction as isize, |c| {
                        self.store.save(c)
                    })?;
                Ok("已调整标题规则顺序".into())
            }
            Request::UpdateSettings(settings) => {
                settings.validate()?;
                let old = self.engine.config().settings.clone();
                let mut candidate = self.engine.config().clone();
                candidate.settings = settings.clone();
                let previous = if old.autostart != settings.autostart || settings.autostart {
                    Some(crate::startup::set(
                        settings.autostart,
                        self.store.path().parent().unwrap(),
                    )?)
                } else {
                    None
                };
                if let Err(error) = self.engine.commit_config(candidate, |c| self.store.save(c)) {
                    if let Some(previous) = previous {
                        crate::startup::restore(previous)?;
                    }
                    return Err(error);
                }
                Ok("设置已保存".into())
            }
            Request::Associate {
                profile_id,
                bindings,
            } => {
                self.check_topology()?;
                let candidate = topology::associate(
                    self.engine.config(),
                    &profile_id,
                    &bindings,
                    &self.monitors,
                )?;
                self.engine
                    .commit_config(candidate, |c| self.store.save(c))?;
                self.active_profile = Some(profile_id);
                self.bindings = bindings;
                self.needs_association = false;
                Ok("显示器已关联，原预设继续使用".into())
            }
            Request::RecoverBackup => {
                let config = self.store.recover_backup()?;
                self.engine = Engine::new(config)?;
                self.protected_reason = None;
                self.monitors.clear();
                self.refresh_topology()?;
                Ok("已恢复有效备份，损坏原件另外保留".into())
            }
            Request::RestartElevated => {
                crate::lifecycle::restart_elevated(&mut self.store)?;
                Ok("管理员实例已接管，原实例即将退出".into())
            }
            Request::ResetConfig => {
                let config = self.store.reset_explicitly()?;
                self.engine = Engine::new(config)?;
                self.protected_reason = None;
                self.monitors.clear();
                self.refresh_topology()?;
                Ok("已明确建立新配置，原文件另外保留".into())
            }
            Request::CreateEnvironment => {
                self.check_topology()?;
                if self.active_profile.is_some() || !self.needs_association {
                    return Err("当前环境已有可用方案，无需重复建立".into());
                }
                let mut candidate = self.engine.config().clone();
                let mut ids = Vec::new();
                let mut bindings = Vec::new();
                for monitor in &self.monitors {
                    let id = next_id();
                    candidate.displays.push(DisplayRecord {
                        id: id.clone(),
                        name: monitor.name.clone(),
                        fingerprints: monitor.fingerprints.clone(),
                    });
                    ids.push(id.clone());
                    bindings.push(DisplayBinding {
                        display_id: id,
                        monitor_key: monitor.key.clone(),
                    });
                }
                let id = next_id();
                candidate.profiles.push(Profile {
                    id: id.clone(),
                    name: format!("{} 屏方案", ids.len()),
                    display_ids: ids,
                    applications: Vec::new(),
                });
                self.engine
                    .commit_config(candidate, |c| self.store.save(c))?;
                self.active_profile = Some(id);
                self.bindings = bindings;
                self.needs_association = false;
                Ok("已建立当前环境的空方案，旧方案保留".into())
            }
            Request::RebindApplication {
                profile_id,
                old_app_id,
                handle,
                pid,
                token,
                expected_revision,
            } => {
                self.refresh_topology()?;
                self.assert_active(&profile_id, expected_revision)?;
                let window = self.capture(handle, pid, token)?;
                if old_app_id == window.app_id {
                    return Ok("所选窗口属于同一应用，无需重新关联".into());
                }
                self.revalidate(&window)?;
                let mut candidate = self.engine.config().clone();
                let profile = candidate
                    .profiles
                    .iter_mut()
                    .find(|p| p.id == profile_id)
                    .ok_or("方案已不存在")?;
                if profile.applications.iter().any(|app| {
                    app.app_id == window.app_id && (app.default.is_some() || !app.rules.is_empty())
                }) {
                    return Err("目标应用已有预设，未自动合并；请先整理目标应用的预设".into());
                }
                profile
                    .applications
                    .retain(|app| app.app_id != window.app_id);
                let app = profile
                    .applications
                    .iter_mut()
                    .find(|app| app.app_id == old_app_id)
                    .ok_or("原应用预设已不存在")?;
                let old_name = app.app_name.clone();
                app.app_id = window.app_id.clone();
                app.app_name = window.app_name.clone();
                self.engine
                    .commit_config(candidate, |c| self.store.save(c))?;
                Ok(format!(
                    "已将当前方案中 {old_name} 的默认预设及全部标题规则关联到 {}；窗口位置未改变",
                    window.app_name
                ))
            }
        }
    }
}

impl Backend for Controller {
    fn handle(&mut self, request: Request) -> Response {
        match self.execute(request) {
            Ok(message) => Response {
                view: self.view(),
                message,
                success: true,
            },
            Err(message) => Response {
                view: self.view(),
                message,
                success: false,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::os::windows::fs::OpenOptionsExt;

    #[test]
    fn failed_topology_commit_cannot_leave_old_profile_writable_or_cached() {
        let directory = std::env::temp_dir().join(format!("screen-pin-controller-{}", next_id()));
        let rect = Rect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        let monitors: Vec<_> = ["a", "b"]
            .into_iter()
            .map(|key| MonitorSnapshot {
                key: key.into(),
                name: key.into(),
                rect,
                work: rect,
                fingerprints: vec![format!("serial:{key}"), format!("path:{key}")],
            })
            .collect();
        {
            let (mut controller, _) = Controller::open(directory.clone()).unwrap();
            controller.apply_topology(monitors.clone()).unwrap();
            let old_profile = controller.active_profile.clone().unwrap();
            let original = controller.engine.config().clone();
            let held = OpenOptions::new()
                .read(true)
                .share_mode(1)
                .open(controller.store.path())
                .unwrap();
            assert!(
                controller
                    .apply_topology(vec![monitors[0].clone()])
                    .is_err()
            );
            assert!(controller.active_profile.is_none());
            assert!(controller.bindings.is_empty());
            assert!(controller.monitors.is_empty());
            assert!(controller.profile_id().is_err());
            assert_eq!(*controller.engine.config(), original);
            // A retry still attempts the failed transition instead of using the cached old profile.
            assert!(
                controller
                    .apply_topology(vec![monitors[0].clone()])
                    .is_err()
            );
            assert!(controller.active_profile.is_none());
            drop(held);
            controller
                .apply_topology(vec![monitors[0].clone()])
                .unwrap();
            assert!(controller.active_profile.is_some());
            assert_ne!(controller.active_profile.unwrap(), old_profile);
            assert_eq!(controller.engine.config().profiles.len(), 2);
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
