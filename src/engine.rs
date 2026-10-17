//! Pure operation coordinator. Publishing config and undo always follows a successful save.
use crate::model::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeOutcome {
    Changed,
    Unchanged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchKind<'a> {
    Default,
    Rule { index: usize, keyword: &'a str },
}

#[derive(Clone, Copy, Debug)]
pub struct PresetMatch<'a> {
    pub preset: &'a Preset,
    pub kind: MatchKind<'a>,
}

pub fn matching_preset<'a>(app: &'a AppPresets, title: &str) -> Option<PresetMatch<'a>> {
    let title = title.to_lowercase();
    for (index, rule) in app.rules.iter().enumerate() {
        if title.contains(&rule.keyword.to_lowercase()) {
            return Some(PresetMatch {
                preset: &rule.preset,
                kind: MatchKind::Rule {
                    index,
                    keyword: &rule.keyword,
                },
            });
        }
    }
    app.default.as_ref().map(|preset| PresetMatch {
        preset,
        kind: MatchKind::Default,
    })
}

#[derive(Clone, Debug, PartialEq)]
enum Entry {
    Default(Preset),
    Rule(WindowRule),
}

impl Entry {
    fn preset(&self) -> &Preset {
        match self {
            Self::Default(preset) => preset,
            Self::Rule(rule) => &rule.preset,
        }
    }

    fn same_content(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Default(a), Self::Default(b)) => a.id == b.id && a.placement == b.placement,
            (Self::Rule(a), Self::Rule(b)) => {
                a.keyword == b.keyword
                    && a.preset.id == b.preset.id
                    && a.preset.placement == b.preset.placement
            }
            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
struct UndoRecord {
    profile_id: String,
    app_id: String,
    preset_id: String,
    before: Option<Entry>,
    after: Entry,
    created_app: bool,
    label: String,
}

struct UndoIntent {
    profile_id: String,
    app_id: String,
    preset_id: String,
    before: Option<Entry>,
    created_app: bool,
    label: String,
}

enum UndoAction {
    Preserve,
    Replace(Box<UndoIntent>),
    Clear,
}

pub struct Engine {
    config: Config,
    undo: Option<UndoRecord>,
}

impl Engine {
    pub fn new(config: Config) -> Result<Self, String> {
        config.validate()?;
        Ok(Self { config, undo: None })
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn undo_label(&self) -> Option<&str> {
        self.undo.as_ref().map(|u| u.label.as_str())
    }

    pub fn require_revision(&self, expected: u64) -> Result<(), String> {
        if expected != self.config.revision {
            return Err("配置已改变，请刷新后重试。".into());
        }
        Ok(())
    }

    pub fn match_window(
        &self,
        profile_id: &str,
        window: &WindowSnapshot,
    ) -> Result<Option<PresetMatch<'_>>, String> {
        let profile = self
            .config
            .profile(profile_id)
            .ok_or("活动方案已改变，请重试。")?;
        Ok(profile
            .applications
            .iter()
            .find(|a| a.app_id == window.app_id)
            .and_then(|app| matching_preset(app, &window.title)))
    }

    /// The caller has already validated target-window identity, topology, and availability.
    pub fn remember<F>(
        &mut self,
        profile_id: &str,
        window: &WindowSnapshot,
        placement: Placement,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        let profile = self.config.profile(profile_id).ok_or("活动方案不存在。")?;
        check_placement(profile, &placement)?;
        let app = profile
            .applications
            .iter()
            .find(|a| a.app_id == window.app_id);
        let matched = app.and_then(|a| matching_preset(a, &window.title));
        if let Some(matched) = matched {
            let preset_id = matched.preset.id.clone();
            return self.edit(
                profile_id,
                &window.app_id,
                &preset_id,
                placement,
                None,
                persist,
            );
        }
        self.create_default(profile_id, window, placement, persist)
    }

    /// Explicit GUI action: title rules remain intact and keep their normal priority.
    /// An existing default must be edited through its own, clearly named action.
    pub fn create_default<F>(
        &mut self,
        profile_id: &str,
        window: &WindowSnapshot,
        placement: Placement,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        let profile = self.config.profile(profile_id).ok_or("活动方案不存在。")?;
        check_placement(profile, &placement)?;
        let app = profile
            .applications
            .iter()
            .find(|app| app.app_id == window.app_id);
        if app.is_some_and(|app| app.default.is_some()) {
            return Err("该应用已有默认预设，请选择已有默认预设编辑，避免误覆盖。".into());
        }
        let created_app = app.is_none();
        let mut candidate = self.config.clone();
        let profile = candidate
            .profiles
            .iter_mut()
            .find(|p| p.id == profile_id)
            .unwrap();
        let app = ensure_app(profile, window);
        let preset_id = next_id();
        app.default = Some(Preset {
            id: preset_id.clone(),
            revision: self.config.revision,
            placement,
        });
        let intent = UndoIntent {
            profile_id: profile_id.into(),
            app_id: window.app_id.clone(),
            preset_id,
            before: None,
            created_app,
            label: format!(
                "{} · {} · 应用默认（同应用窗口共用）",
                profile.name, window.app_name
            ),
        };
        self.commit(candidate, UndoAction::Replace(Box::new(intent)), persist)
    }

    pub fn create_rule<F>(
        &mut self,
        profile_id: &str,
        window: &WindowSnapshot,
        keyword: &str,
        placement: Placement,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        check_keyword(keyword)?;
        let profile = self.config.profile(profile_id).ok_or("活动方案不存在。")?;
        check_placement(profile, &placement)?;
        let existing = profile
            .applications
            .iter()
            .find(|a| a.app_id == window.app_id);
        if existing.is_some_and(|a| {
            a.rules
                .iter()
                .any(|r| r.keyword.to_lowercase() == keyword.to_lowercase())
        }) {
            return Err("该应用已有相同标题关键字（忽略大小写），请选择原规则编辑。".into());
        }
        let created_app = existing.is_none();
        let mut candidate = self.config.clone();
        let profile = candidate
            .profiles
            .iter_mut()
            .find(|p| p.id == profile_id)
            .unwrap();
        let app = ensure_app(profile, window);
        let preset_id = next_id();
        app.rules.push(WindowRule {
            keyword: keyword.into(),
            preset: Preset {
                id: preset_id.clone(),
                revision: self.config.revision,
                placement,
            },
        });
        let intent = UndoIntent {
            profile_id: profile_id.into(),
            app_id: window.app_id.clone(),
            preset_id,
            before: None,
            created_app,
            label: format!(
                "{} · {} · 标题包含“{}”",
                profile.name, window.app_name, keyword
            ),
        };
        self.commit(candidate, UndoAction::Replace(Box::new(intent)), persist)
    }

    /// `keyword: None` preserves the existing keyword; defaults reject a supplied keyword.
    pub fn edit<F>(
        &mut self,
        profile_id: &str,
        app_id: &str,
        preset_id: &str,
        placement: Placement,
        keyword: Option<&str>,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        let profile = self.config.profile(profile_id).ok_or("方案不存在。")?;
        check_placement(profile, &placement)?;
        let app = profile
            .applications
            .iter()
            .find(|a| a.app_id == app_id)
            .ok_or("应用预设不存在。")?;
        let before =
            find_entry(&self.config, profile_id, app_id, preset_id).ok_or("预设已不存在。")?;
        if let Some(keyword) = keyword {
            check_keyword(keyword)?;
            if matches!(before, Entry::Default(_)) {
                return Err("应用默认预设没有标题关键字。".into());
            }
            if app.rules.iter().any(|r| {
                r.preset.id != preset_id && r.keyword.to_lowercase() == keyword.to_lowercase()
            }) {
                return Err("该应用已有相同标题关键字（忽略大小写）。".into());
            }
        }
        let effective_keyword = keyword.map(str::to_owned).or_else(|| match &before {
            Entry::Rule(rule) => Some(rule.keyword.clone()),
            Entry::Default(_) => None,
        });
        if before.preset().placement == placement
            && match &before {
                Entry::Default(_) => true,
                Entry::Rule(rule) => effective_keyword.as_ref() == Some(&rule.keyword),
            }
        {
            return Ok(ChangeOutcome::Unchanged);
        }
        let label = match &effective_keyword {
            Some(keyword) => format!(
                "{} · {} · 标题包含“{}”",
                profile.name, app.app_name, keyword
            ),
            None => format!(
                "{} · {} · 应用默认（同应用窗口共用）",
                profile.name, app.app_name
            ),
        };
        let mut candidate = self.config.clone();
        let app = find_app_mut(&mut candidate, profile_id, app_id)?;
        if let Some(preset) = app.default.as_mut().filter(|p| p.id == preset_id) {
            preset.placement = placement;
        } else {
            let rule = app
                .rules
                .iter_mut()
                .find(|r| r.preset.id == preset_id)
                .unwrap();
            rule.preset.placement = placement;
            rule.keyword = effective_keyword.unwrap();
        }
        self.commit(
            candidate,
            UndoAction::Replace(Box::new(UndoIntent {
                profile_id: profile_id.into(),
                app_id: app_id.into(),
                preset_id: preset_id.into(),
                before: Some(before),
                created_app: false,
                label,
            })),
            persist,
        )
    }

    pub fn delete<F>(
        &mut self,
        profile_id: &str,
        app_id: &str,
        preset_id: &str,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        if find_entry(&self.config, profile_id, app_id, preset_id).is_none() {
            return Err("预设已不存在。".into());
        }
        let mut candidate = self.config.clone();
        let app = find_app_mut(&mut candidate, profile_id, app_id)?;
        if app.default.as_ref().is_some_and(|p| p.id == preset_id) {
            app.default = None;
        }
        app.rules.retain(|r| r.preset.id != preset_id);
        self.commit(candidate, UndoAction::Preserve, persist)
    }

    pub fn move_rule<F>(
        &mut self,
        profile_id: &str,
        app_id: &str,
        preset_id: &str,
        delta: isize,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        let mut candidate = self.config.clone();
        let app = find_app_mut(&mut candidate, profile_id, app_id)?;
        let from = app
            .rules
            .iter()
            .position(|r| r.preset.id == preset_id)
            .ok_or("标题规则不存在。")?;
        let to = from.saturating_add_signed(delta).min(app.rules.len() - 1);
        if from == to {
            return Ok(ChangeOutcome::Unchanged);
        }
        let rule = app.rules.remove(from);
        app.rules.insert(to, rule);
        self.commit(candidate, UndoAction::Preserve, persist)
    }

    /// General commits cover settings, topology and explicit structural changes.
    /// The candidate must be based on the current config revision.
    pub fn commit_config<F>(
        &mut self,
        candidate: Config,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        self.require_revision(candidate.revision)?;
        self.commit(candidate, UndoAction::Preserve, persist)
    }

    pub fn undo<F>(&mut self, persist: F) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        let undo = self.undo.clone().ok_or("本次运行还没有可撤销的更新。")?;
        if !undo_is_valid(&undo, &self.config, &self.config) {
            return Err("该预设或显示器关联已改变，无法撤销，请检查当前配置。".into());
        }
        let mut candidate = self.config.clone();
        let app = find_app_mut(&mut candidate, &undo.profile_id, &undo.app_id)?;
        match (&undo.after, &undo.before) {
            (Entry::Default(_), Some(Entry::Default(before))) => app.default = Some(before.clone()),
            (Entry::Default(_), None) => app.default = None,
            (Entry::Rule(_), Some(Entry::Rule(before))) => {
                let rule = app
                    .rules
                    .iter_mut()
                    .find(|r| r.preset.id == undo.preset_id)
                    .unwrap();
                *rule = before.clone();
            }
            (Entry::Rule(_), None) => app.rules.retain(|r| r.preset.id != undo.preset_id),
            _ => return Err("预设类型已改变，无法撤销。".into()),
        }
        if undo.created_app && app.default.is_none() && app.rules.is_empty() {
            let profile = candidate
                .profiles
                .iter_mut()
                .find(|p| p.id == undo.profile_id)
                .unwrap();
            profile.applications.retain(|a| a.app_id != undo.app_id);
        }
        self.commit(candidate, UndoAction::Clear, persist)
    }

    fn commit<F>(
        &mut self,
        mut candidate: Config,
        undo_action: UndoAction,
        persist: F,
    ) -> Result<ChangeOutcome, String>
    where
        F: FnOnce(&Config) -> Result<(), String>,
    {
        self.require_revision(candidate.revision)?;
        if candidate == self.config {
            return Ok(ChangeOutcome::Unchanged);
        }
        let revision = self
            .config
            .revision
            .checked_add(1)
            .ok_or("配置版本已达到上限，无法继续写入。")?;
        candidate.revision = revision;
        stamp_changed_presets(&mut candidate, &self.config, revision);
        candidate.validate()?;
        let next_undo = match undo_action {
            UndoAction::Clear => None,
            UndoAction::Preserve => self
                .undo
                .clone()
                .filter(|u| undo_is_valid(u, &self.config, &candidate)),
            UndoAction::Replace(intent) => {
                let after = find_entry(
                    &candidate,
                    &intent.profile_id,
                    &intent.app_id,
                    &intent.preset_id,
                )
                .ok_or("内部错误：提交目标不存在。")?;
                Some(UndoRecord {
                    profile_id: intent.profile_id,
                    app_id: intent.app_id,
                    preset_id: intent.preset_id,
                    before: intent.before,
                    after,
                    created_app: intent.created_app,
                    label: intent.label,
                })
            }
        };
        persist(&candidate)?;
        self.config = candidate;
        self.undo = next_undo;
        Ok(ChangeOutcome::Changed)
    }
}

fn check_keyword(keyword: &str) -> Result<(), String> {
    if keyword.trim().is_empty() {
        return Err("标题关键字不能为空。".into());
    }
    Ok(())
}

fn check_placement(profile: &Profile, placement: &Placement) -> Result<(), String> {
    placement.rect.validate()?;
    if !profile.display_ids.contains(&placement.display_id) {
        return Err("目标显示器不属于活动方案，请刷新显示器关联。".into());
    }
    Ok(())
}

fn ensure_app<'a>(profile: &'a mut Profile, window: &WindowSnapshot) -> &'a mut AppPresets {
    let index = match profile
        .applications
        .iter()
        .position(|a| a.app_id == window.app_id)
    {
        Some(index) => index,
        None => {
            profile.applications.push(AppPresets {
                app_id: window.app_id.clone(),
                app_name: window.app_name.clone(),
                default: None,
                rules: Vec::new(),
            });
            profile.applications.len() - 1
        }
    };
    &mut profile.applications[index]
}

fn find_app_mut<'a>(
    config: &'a mut Config,
    profile_id: &str,
    app_id: &str,
) -> Result<&'a mut AppPresets, String> {
    config
        .profiles
        .iter_mut()
        .find(|p| p.id == profile_id)
        .ok_or("方案不存在。")?
        .applications
        .iter_mut()
        .find(|a| a.app_id == app_id)
        .ok_or_else(|| "应用预设不存在。".into())
}

fn find_entry(config: &Config, profile_id: &str, app_id: &str, preset_id: &str) -> Option<Entry> {
    let app = config
        .profile(profile_id)?
        .applications
        .iter()
        .find(|a| a.app_id == app_id)?;
    if let Some(preset) = app.default.as_ref().filter(|p| p.id == preset_id) {
        return Some(Entry::Default(preset.clone()));
    }
    app.rules
        .iter()
        .find(|r| r.preset.id == preset_id)
        .map(|r| Entry::Rule(r.clone()))
}

fn stamp_changed_presets(candidate: &mut Config, previous: &Config, revision: u64) {
    for profile in &mut candidate.profiles {
        for app in &mut profile.applications {
            if let Some(preset) = &mut app.default {
                let old = find_entry(previous, &profile.id, &app.app_id, &preset.id);
                let new = Entry::Default(preset.clone());
                preset.revision = old
                    .as_ref()
                    .filter(|old| old.same_content(&new))
                    .map_or(revision, |old| old.preset().revision);
            }
            for rule in &mut app.rules {
                let old = find_entry(previous, &profile.id, &app.app_id, &rule.preset.id);
                let new = Entry::Rule(rule.clone());
                rule.preset.revision = old
                    .as_ref()
                    .filter(|old| old.same_content(&new))
                    .map_or(revision, |old| old.preset().revision);
            }
        }
    }
}

fn undo_is_valid(undo: &UndoRecord, previous: &Config, candidate: &Config) -> bool {
    let Some(entry) = find_entry(candidate, &undo.profile_id, &undo.app_id, &undo.preset_id) else {
        return false;
    };
    if entry != undo.after {
        return false;
    }
    let display_id = &undo.after.preset().placement.display_id;
    let old_display = previous.displays.iter().find(|d| &d.id == display_id);
    let new_display = candidate.displays.iter().find(|d| &d.id == display_id);
    if old_display != new_display {
        return false;
    }
    match (
        previous.profile(&undo.profile_id),
        candidate.profile(&undo.profile_id),
    ) {
        (Some(a), Some(b)) => {
            let mut a = a.display_ids.clone();
            let mut b = b.display_ids.clone();
            a.sort();
            b.sort();
            a == b
        }
        _ => false,
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
