use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SCHEMA_VERSION: u32 = 1;

pub fn next_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{timestamp:032x}-{:08x}-{serial:016x}", std::process::id())
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub schema_version: u32,
    pub revision: u64,
    pub settings: Settings,
    pub displays: Vec<DisplayRecord>,
    pub profiles: Vec<Profile>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            revision: 0,
            settings: Settings::default(),
            displays: Vec::new(),
            profiles: Vec::new(),
        }
    }
}

impl Config {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != SCHEMA_VERSION {
            return Err(format!(
                "不支持配置版本 {}（当前支持 {}），原文件应保留。",
                self.schema_version, SCHEMA_VERSION
            ));
        }
        self.settings.validate()?;
        let mut display_ids = HashSet::new();
        for display in &self.displays {
            nonempty(&display.id, "显示器 ID")?;
            nonempty(&display.name, "显示器名称")?;
            if !display_ids.insert(display.id.as_str()) {
                return Err("显示器 ID 重复。".into());
            }
            let mut fingerprints = HashSet::new();
            for fingerprint in &display.fingerprints {
                nonempty(fingerprint, "显示器识别证据")?;
                if !fingerprints.insert(fingerprint) {
                    return Err("同一显示器的识别证据重复。".into());
                }
            }
        }
        let mut profile_ids = HashSet::new();
        let mut combinations = HashSet::new();
        let mut preset_ids = HashSet::new();
        for profile in &self.profiles {
            nonempty(&profile.id, "方案 ID")?;
            nonempty(&profile.name, "方案名称")?;
            if !profile_ids.insert(profile.id.as_str()) {
                return Err("方案 ID 重复。".into());
            }
            if profile.display_ids.is_empty() {
                return Err("方案至少需要一台显示器。".into());
            }
            let mut combination = profile.display_ids.clone();
            combination.sort();
            combination.dedup();
            if combination.len() != profile.display_ids.len() {
                return Err("方案中的显示器重复。".into());
            }
            if !combinations.insert(combination) {
                return Err("同一显示器组合只能有一个方案。".into());
            }
            for id in &profile.display_ids {
                if !display_ids.contains(id.as_str()) {
                    return Err("方案引用了不存在的显示器。".into());
                }
            }
            let mut app_ids = HashSet::new();
            for app in &profile.applications {
                nonempty(&app.app_id, "应用身份")?;
                nonempty(&app.app_name, "应用名称")?;
                if !app_ids.insert(app.app_id.as_str()) {
                    return Err("同一方案中应用身份重复。".into());
                }
                let mut keywords = HashSet::new();
                for rule in &app.rules {
                    nonempty(&rule.keyword, "标题关键字")?;
                    if !keywords.insert(rule.keyword.to_lowercase()) {
                        return Err("同一应用的标题关键字重复（忽略大小写）。".into());
                    }
                }
                for preset in app
                    .default
                    .iter()
                    .chain(app.rules.iter().map(|r| &r.preset))
                {
                    nonempty(&preset.id, "预设 ID")?;
                    if !preset_ids.insert(preset.id.as_str()) {
                        return Err("预设 ID 重复。".into());
                    }
                    if preset.revision > self.revision {
                        return Err("预设版本不能高于配置版本。".into());
                    }
                    preset.placement.rect.validate()?;
                    if !profile.display_ids.contains(&preset.placement.display_id) {
                        return Err("预设的目标显示器不属于该方案。".into());
                    }
                }
            }
        }
        Ok(())
    }

    pub fn profile(&self, id: &str) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.id == id)
    }
}

fn nonempty(value: &str, label: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{label}不能为空。"));
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub restore: Hotkey,
    pub remember: Hotkey,
    pub autostart: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            restore: Hotkey {
                modifiers: 3,
                key: 0x78,
            },
            remember: Hotkey {
                modifiers: 3,
                key: 0x79,
            },
            autostart: false,
        }
    }
}

impl Settings {
    pub fn validate(&self) -> Result<(), String> {
        self.restore.validate()?;
        self.remember.validate()?;
        if self.restore == self.remember {
            return Err("恢复位置和记住位置不能使用同一热键。".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(deny_unknown_fields)]
pub struct Hotkey {
    pub modifiers: u32,
    pub key: u32,
}

impl Hotkey {
    pub fn validate(self) -> Result<(), String> {
        if self.modifiers == 0 || self.modifiers & !0x0f != 0 {
            return Err("热键至少包含一个 Ctrl、Alt、Shift 或 Win 修饰键。".into());
        }
        if !(0x08..=0xfe).contains(&self.key)
            || matches!(self.key, 0x10..=0x12 | 0x5b..=0x5c | 0xa0..=0xa5)
        {
            return Err("热键需要一个有效的非修饰按键。".into());
        }
        Ok(())
    }

    pub fn label(self) -> String {
        let mut parts: Vec<String> = Vec::new();
        for (flag, label) in [(2, "Ctrl"), (1, "Alt"), (4, "Shift"), (8, "Win")] {
            if self.modifiers & flag != 0 {
                parts.push(label.into());
            }
        }
        let key = match self.key {
            0x70..=0x87 => format!("F{}", self.key - 0x6f),
            0x30..=0x39 | 0x41..=0x5a => char::from_u32(self.key).unwrap().to_string(),
            0x20 => "Space".into(),
            0x09 => "Tab".into(),
            0x0d => "Enter".into(),
            0x1b => "Esc".into(),
            _ => format!("VK {:02X}", self.key),
        };
        parts.push(key);
        parts.join("+")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DisplayRecord {
    pub id: String,
    pub name: String,
    pub fingerprints: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub display_ids: Vec<String>,
    pub applications: Vec<AppPresets>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AppPresets {
    pub app_id: String,
    pub app_name: String,
    pub default: Option<Preset>,
    pub rules: Vec<WindowRule>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Preset {
    pub id: String,
    pub revision: u64,
    pub placement: Placement,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WindowRule {
    pub keyword: String,
    pub preset: Preset,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Placement {
    pub display_id: String,
    pub rect: RelativeRect,
    pub maximized: bool,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RelativeRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl RelativeRect {
    pub fn validate(self) -> Result<(), String> {
        if ![self.x, self.y, self.width, self.height]
            .iter()
            .all(|n| n.is_finite())
            || self.width <= 0.0
            || self.height <= 0.0
            || !(self.x + self.width).is_finite()
            || !(self.y + self.height).is_finite()
        {
            return Err("位置和大小必须是有限数值，宽度和高度必须大于零。".into());
        }
        Ok(())
    }

    pub fn from_rect(rect: Rect, work: Rect) -> Result<Self, String> {
        rect.validate()?;
        work.validate()?;
        let width = f64::from(work.width());
        let height = f64::from(work.height());
        let result = Self {
            x: (f64::from(rect.left) - f64::from(work.left)) / width,
            y: (f64::from(rect.top) - f64::from(work.top)) / height,
            width: f64::from(rect.width()) / width,
            height: f64::from(rect.height()) / height,
        };
        result.validate()?;
        Ok(result)
    }

    pub fn to_rect(self, work: Rect) -> Result<Rect, String> {
        self.validate()?;
        work.validate()?;
        let convert = |value: f64| -> Result<i32, String> {
            let rounded = value.round();
            if !rounded.is_finite() || rounded < i32::MIN as f64 || rounded > i32::MAX as f64 {
                return Err("窗口坐标超出 Windows 支持范围。".into());
            }
            Ok(rounded as i32)
        };
        let width = f64::from(work.width());
        let height = f64::from(work.height());
        let result = Rect {
            left: convert(f64::from(work.left) + self.x * width)?,
            top: convert(f64::from(work.top) + self.y * height)?,
            right: convert(f64::from(work.left) + (self.x + self.width) * width)?,
            bottom: convert(f64::from(work.top) + (self.y + self.height) * height)?,
        };
        result.validate()?;
        Ok(result)
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub fn validate(self) -> Result<(), String> {
        let width = i64::from(self.right) - i64::from(self.left);
        let height = i64::from(self.bottom) - i64::from(self.top);
        if width <= 0 || height <= 0 || width > i64::from(i32::MAX) || height > i64::from(i32::MAX)
        {
            return Err("矩形尺寸无效或超出 Windows 支持范围。".into());
        }
        Ok(())
    }

    pub fn width(self) -> i32 {
        self.right.saturating_sub(self.left)
    }
    pub fn height(self) -> i32 {
        self.bottom.saturating_sub(self.top)
    }

    pub fn intersection_area(self, other: Self) -> i64 {
        let width =
            (i64::from(self.right.min(other.right)) - i64::from(self.left.max(other.left))).max(0);
        let height =
            (i64::from(self.bottom.min(other.bottom)) - i64::from(self.top.max(other.top))).max(0);
        width.saturating_mul(height)
    }

    pub fn approximately_eq(self, other: Self, tolerance: i32) -> bool {
        let tolerance = i64::from(tolerance.max(0));
        [
            (self.left, other.left),
            (self.top, other.top),
            (self.right, other.right),
            (self.bottom, other.bottom),
        ]
        .iter()
        .all(|(a, b)| (i64::from(*a) - i64::from(*b)).abs() <= tolerance)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorSnapshot {
    pub key: String,
    pub name: String,
    pub rect: Rect,
    pub work: Rect,
    pub fingerprints: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSnapshot {
    pub handle: isize,
    pub pid: u32,
    pub token: u64,
    pub process_started: u64,
    pub app_id: String,
    pub app_name: String,
    pub title: String,
    pub display_key: String,
    pub normal_rect: Rect,
    pub maximized: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSummary {
    pub handle: isize,
    pub pid: u32,
    pub token: u64,
    pub app_id: String,
    pub title: String,
    pub app_name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestoreOutcome {
    AlreadyCorrect,
    Restored,
    Constrained,
    Unconfirmed,
}
