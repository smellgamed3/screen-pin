//! Messages shared by the native shell and the serial operation coordinator.
use crate::model::{Config, MonitorSnapshot, Placement, Settings, WindowSummary};

#[derive(Clone, Debug)]
pub struct DisplayBinding {
    pub display_id: String,
    pub monitor_key: String,
}

#[derive(Clone, Debug)]
pub struct View {
    pub config: Config,
    pub windows: Vec<WindowSummary>,
    pub monitors: Vec<MonitorSnapshot>,
    pub active_profile: Option<String>,
    pub bindings: Vec<DisplayBinding>,
    pub needs_association: bool,
    pub read_only: bool,
    pub config_path: String,
    pub undo_label: Option<String>,
    pub startup_warning: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Response {
    pub view: View,
    pub message: String,
    pub success: bool,
}

#[derive(Clone, Debug)]
pub enum Request {
    Refresh,
    Remember {
        handle: isize,
        pid: u32,
        token: u64,
    },
    Restore {
        handle: isize,
        pid: u32,
        token: u64,
    },
    Undo,
    CreateRule {
        handle: isize,
        pid: u32,
        token: u64,
        keyword: String,
    },
    CreateDefault {
        handle: isize,
        pid: u32,
        token: u64,
    },
    EditPreset {
        profile_id: String,
        preset_id: String,
        placement: Placement,
        keyword: Option<String>,
        expected_revision: u64,
    },
    DeletePreset {
        profile_id: String,
        preset_id: String,
        expected_revision: u64,
    },
    MoveRule {
        profile_id: String,
        preset_id: String,
        direction: i32,
        expected_revision: u64,
    },
    RebindApplication {
        profile_id: String,
        old_app_id: String,
        handle: isize,
        pid: u32,
        token: u64,
        expected_revision: u64,
    },
    UpdateSettings(Settings),
    Associate {
        profile_id: String,
        bindings: Vec<DisplayBinding>,
    },
    RecoverBackup,
    /// Explicit recovery: preserve the rejected file and start a fresh config.
    ResetConfig,
    /// Explicitly accept an ambiguous topology as a new physical environment.
    CreateEnvironment,
    RestartElevated,
}

pub trait Backend: Send + 'static {
    fn handle(&mut self, request: Request) -> Response;
}
