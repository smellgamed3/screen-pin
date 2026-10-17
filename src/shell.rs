//! Native, event-driven Windows shell. All external operations run on one worker.
use crate::model::{Hotkey, Preset, Settings};
use crate::protocol::{Backend, DisplayBinding, Request, Response, View};
use std::cell::RefCell;
use std::collections::HashMap;
use std::mem::size_of;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    COLOR_BTNFACE, ClientToScreen, CreateFontIndirectW, DEFAULT_GUI_FONT, DeleteObject,
    GetMonitorInfoW, GetStockObject, HBRUSH, HFONT, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MonitorFromWindow,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::SetScrollInfo;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, HOT_KEY_MODIFIERS, MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
};
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

pub const HOST_CLASS: PCWSTR = w!("ScreenPin.Host");
pub const SHOW_MESSAGE: u32 = WM_APP + 1;
const WORKER_MESSAGE: u32 = WM_APP + 2;
const TRAY_MESSAGE: u32 = WM_APP + 3;
const HANDOFF_SUSPEND: u32 = WM_APP + 4;
const HANDOFF_RESUME: u32 = WM_APP + 5;
const TOPOLOGY_TIMER: usize = 1;
const IDENTIFY_TIMER: usize = 2;
const TOAST_TIMER: usize = 3;
const PAGE_MAIN: i32 = 1;
const PAGE_SETTINGS: i32 = 2;
const PAGE_ASSOCIATE: i32 = 3;

const ID_PAGE_MAIN: i32 = 100;
const ID_PAGE_SETTINGS: i32 = 101;
const ID_PAGE_ASSOCIATE: i32 = 102;
const ID_INTRO: i32 = 103;
const ID_PROFILE_LABEL: i32 = 104;
const ID_PROFILE: i32 = 105;
const ID_ENV: i32 = 106;
const ID_WINDOWS_LABEL: i32 = 107;
const ID_WINDOWS: i32 = 108;
const ID_REFRESH: i32 = 109;
const ID_MATCH: i32 = 110;
const ID_REMEMBER: i32 = 111;
const ID_RESTORE: i32 = 112;
const ID_RULE_LABEL: i32 = 113;
const ID_RULE: i32 = 114;
const ID_CREATE_RULE: i32 = 115;
const ID_PRESETS_LABEL: i32 = 116;
const ID_PRESETS: i32 = 117;
const ID_EDITOR_HEADING: i32 = 118;
const ID_DISPLAY_LABEL: i32 = 119;
const ID_DISPLAY: i32 = 120;
const ID_X_LABEL: i32 = 121;
const ID_X: i32 = 122;
const ID_Y_LABEL: i32 = 123;
const ID_Y: i32 = 124;
const ID_WIDTH_LABEL: i32 = 125;
const ID_WIDTH: i32 = 126;
const ID_HEIGHT_LABEL: i32 = 127;
const ID_HEIGHT: i32 = 128;
const ID_MAXIMIZED: i32 = 129;
const ID_EDIT_KEYWORD_LABEL: i32 = 130;
const ID_EDIT_KEYWORD: i32 = 131;
const ID_SAVE_PRESET: i32 = 132;
const ID_DELETE: i32 = 133;
const ID_UP: i32 = 134;
const ID_DOWN: i32 = 135;
const ID_UNDO: i32 = 136;
const ID_RESULT_LABEL: i32 = 137;
const ID_RESULT: i32 = 138;
const ID_NEW_RULE_PREVIEW: i32 = 139;
const ID_REBIND: i32 = 140;
const ID_REBIND_HINT: i32 = 141;
const ID_CREATE_DEFAULT: i32 = 142;
const ID_SETTINGS_TITLE: i32 = 200;
const ID_RESTORE_KEY_LABEL: i32 = 201;
const ID_RESTORE_KEY: i32 = 202;
const ID_REMEMBER_KEY_LABEL: i32 = 203;
const ID_REMEMBER_KEY: i32 = 204;
const ID_KEY_HELP: i32 = 205;
const ID_AUTOSTART: i32 = 206;
const ID_SAVE_SETTINGS: i32 = 207;
const ID_KEY_STATUS: i32 = 208;
const ID_CONFIG_LABEL: i32 = 209;
const ID_CONFIG_PATH: i32 = 210;
const ID_RECOVER: i32 = 211;
const ID_SETTINGS_HINT: i32 = 212;
const ID_RESET_CONFIG: i32 = 213;
const ID_STARTUP_WARNING: i32 = 214;
const ID_ASSOC_TITLE: i32 = 300;
const ID_ASSOC_PROFILE_LABEL: i32 = 301;
const ID_ASSOC_PROFILE: i32 = 302;
const ID_IDENTIFY: i32 = 303;
const ID_ASSOC_OLD_LABEL: i32 = 304;
const ID_ASSOC_OLD: i32 = 305;
const ID_ASSOC_NEW_LABEL: i32 = 306;
const ID_ASSOC_NEW: i32 = 307;
const ID_ASSOC_SET: i32 = 308;
const ID_ASSOC_PREVIEW: i32 = 309;
const ID_ASSOC_APPLY: i32 = 310;
const ID_ASSOC_HELP: i32 = 311;
const ID_CREATE_ENVIRONMENT: i32 = 312;
const ID_MENU_OPEN: usize = 400;
const ID_MENU_UNDO: usize = 401;
const ID_MENU_ELEVATE: usize = 402;
const ID_MENU_EXIT: usize = 403;

thread_local! {
    // Control messages may synchronously reenter the window procedure. Skipping
    // nested state access avoids aliasing mutable references across those calls.
    static SHELL: RefCell<Option<Shell>> = const { RefCell::new(None) };
}

struct Control {
    id: i32,
    hwnd: HWND,
    page: i32,
}
struct Registration {
    key: Hotkey,
    id: i32,
}
struct PendingSettings {
    settings: Settings,
    added_ids: Vec<i32>,
}
#[derive(Clone)]
struct PresetRow {
    profile_id: String,
    app_id: String,
    preset: Preset,
    keyword: Option<String>,
    base_revision: u64,
}
enum WorkerReply {
    Done(Box<Response>),
    Panicked,
}

struct Shell {
    host: HWND,
    window: HWND,
    controls: Vec<Control>,
    view: View,
    selected_profile: Option<String>,
    rows: Vec<PresetRow>,
    editor: Option<PresetRow>,
    original_percent: [String; 4],
    display_choices: Vec<String>,
    requests: SyncSender<Request>,
    replies: Receiver<WorkerReply>,
    busy: bool,
    exiting: bool,
    worker_failed: bool,
    registrations: Vec<Registration>,
    next_hotkey_id: i32,
    active_settings: Settings,
    pending_settings: Option<PendingSettings>,
    pending_restart: bool,
    hotkeys_suspended: bool,
    last_result: String,
    last_toast: String,
    last_toast_at: Option<Instant>,
    taskbar_created: u32,
    page: i32,
    scroll: i32,
    content_height: i32,
    scale: f64,
    row: i32,
    font: HFONT,
    owned_font: bool,
    association: HashMap<String, String>,
    association_profile: Option<String>,
    identifiers: Vec<HWND>,
    toast_window: Option<HWND>,
    tray_ready: bool,
}

/// Called after the lifecycle layer verifies that the owner is this user/session.
pub fn activate_existing(config_path: &str) -> bool {
    unsafe {
        match FindWindowW(HOST_CLASS, PCWSTR(wide(config_path).as_ptr())) {
            Ok(host) => PostMessageW(Some(host), SHOW_MESSAGE, WPARAM(0), LPARAM(0)).is_ok(),
            Err(_) => false,
        }
    }
}

pub fn suspend_hotkeys_for_handoff() -> Result<(), String> {
    handoff_message(HANDOFF_SUSPEND)
}
pub fn resume_hotkeys_after_failed_handoff() -> Result<(), String> {
    handoff_message(HANDOFF_RESUME)
}
fn handoff_message(message: u32) -> Result<(), String> {
    // The lifecycle worker belongs to this process; find its own host instead of
    // an unrelated process using another configuration directory.
    let mut host = HWND::default();
    unsafe extern "system" fn find(hwnd: HWND, data: LPARAM) -> windows::core::BOOL {
        let mut pid = 0;
        unsafe {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
        if pid == std::process::id() {
            let mut class = [0u16; 64];
            let count = unsafe { GetClassNameW(hwnd, &mut class) } as usize;
            if String::from_utf16_lossy(&class[..count]) == "ScreenPin.Host" {
                unsafe {
                    *(data.0 as *mut HWND) = hwnd;
                }
                return false.into();
            }
        }
        true.into()
    }
    unsafe {
        let _ = EnumWindows(Some(find), LPARAM((&mut host as *mut HWND) as isize));
    }
    if host.is_invalid() {
        return Err("未找到当前实例的热键宿主。".into());
    }
    let mut result = 0;
    let delivered = unsafe {
        SendMessageTimeoutW(
            host,
            message,
            WPARAM(0),
            LPARAM(0),
            SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT,
            1500,
            Some(&mut result),
        )
    };
    if delivered.0 == 0 || result != 1 {
        Err("热键交接未完成，原实例将继续可用。".into())
    } else {
        Ok(())
    }
}

pub fn run(backend: impl Backend, initial: Response, show: bool) -> Result<(), String> {
    unsafe { run_native(backend, initial, show) }
}

unsafe fn run_native(
    mut backend: impl Backend,
    initial: Response,
    show: bool,
) -> Result<(), String> {
    let instance = unsafe { GetModuleHandleW(None) }.map_err(|e| e.to_string())?;
    let cursor = unsafe { LoadCursorW(None, IDC_ARROW) }.map_err(|e| e.to_string())?;
    for class in [HOST_CLASS, w!("ScreenPin.Settings")] {
        let wc = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance.into(),
            hCursor: cursor,
            hbrBackground: HBRUSH((COLOR_BTNFACE.0 + 1) as *mut _),
            lpszClassName: class,
            ..Default::default()
        };
        if unsafe { RegisterClassW(&wc) } == 0 {
            return Err(format!(
                "无法注册窗口类：{}",
                windows::core::Error::from_win32()
            ));
        }
    }
    let host_title = wide(&initial.view.config_path);
    let host = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            HOST_CLASS,
            PCWSTR(host_title.as_ptr()),
            WINDOW_STYLE::default(),
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance.into()),
            None,
        )
    }
    .map_err(|e| e.to_string())?;
    let window = unsafe {
        CreateWindowExW(
            WS_EX_CONTROLPARENT,
            w!("ScreenPin.Settings"),
            w!("Screen Pin — 窗口位置"),
            WS_OVERLAPPEDWINDOW | WS_VSCROLL,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1100,
            800,
            None,
            None,
            Some(instance.into()),
            None,
        )
    }
    .map_err(|e| e.to_string())?;
    let (request_tx, request_rx) = mpsc::sync_channel(1);
    let (reply_tx, reply_rx) = mpsc::channel();
    let mut shell = Shell {
        host,
        window,
        controls: Vec::new(),
        active_settings: initial.view.config.settings.clone(),
        selected_profile: initial.view.active_profile.clone(),
        view: initial.view,
        rows: Vec::new(),
        editor: None,
        original_percent: Default::default(),
        display_choices: Vec::new(),
        requests: request_tx,
        replies: reply_rx,
        busy: false,
        exiting: false,
        worker_failed: false,
        registrations: Vec::new(),
        next_hotkey_id: 1,
        pending_settings: None,
        pending_restart: false,
        hotkeys_suspended: false,
        last_result: initial.message,
        last_toast: String::new(),
        last_toast_at: None,
        taskbar_created: unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) },
        page: PAGE_MAIN,
        scroll: 0,
        content_height: 0,
        scale: (unsafe { GetDpiForWindow(window) }.max(96) as f64) / 96.0,
        row: 30,
        font: HFONT::default(),
        owned_font: false,
        association: HashMap::new(),
        association_profile: None,
        identifiers: Vec::new(),
        toast_window: None,
        tray_ready: false,
    };
    unsafe {
        ChangeWindowMessageFilterEx(host, SHOW_MESSAGE, MSGFLT_ALLOW, None)
            .map_err(|e| format!("无法准备已有实例的显示入口：{e}"))?;
        if shell.taskbar_created != 0 {
            ChangeWindowMessageFilterEx(host, shell.taskbar_created, MSGFLT_ALLOW, None)
                .map_err(|e| format!("无法准备托盘重建消息：{e}"))?;
        }
    }
    shell.make_font();
    shell.create_controls()?;
    shell.register_initial();
    shell.refresh_controls();
    if let Err(error) = shell.tray_add() {
        shell.result(&error, false);
    }
    shell.fit_initial_window();
    if show || !shell.tray_ready {
        shell.show();
    }
    let hotkeys_ready = [
        shell.active_settings.restore,
        shell.active_settings.remember,
    ]
    .iter()
    .all(|key| shell.registrations.iter().any(|r| &r.key == key));
    SHELL.with(|state| *state.borrow_mut() = Some(shell));
    let host_handle = host.0 as isize;
    std::thread::Builder::new()
        .name("screen-pin-operations".into())
        .spawn(move || {
            while let Ok(request) = request_rx.recv() {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    backend.handle(request)
                }));
                let panicked = result.is_err();
                let reply = match result {
                    Ok(response) => WorkerReply::Done(Box::new(response)),
                    Err(_) => WorkerReply::Panicked,
                };
                if reply_tx.send(reply).is_err() {
                    break;
                }
                unsafe {
                    let _ = PostMessageW(
                        Some(HWND(host_handle as *mut _)),
                        WORKER_MESSAGE,
                        WPARAM(0),
                        LPARAM(0),
                    );
                }
                if panicked {
                    break;
                }
            }
        })
        .map_err(|e| e.to_string())?;
    let ready = if crate::lifecycle::is_preparing_child()
        && SHELL.with(|state| state.borrow().as_ref().is_some_and(|s| !s.tray_ready))
    {
        Err("管理员实例未能创建托盘入口，已取消接管。".into())
    } else {
        crate::lifecycle::confirm_ready(hotkeys_ready)
    };
    if let Err(error) = ready {
        SHELL.with(|state| {
            state.borrow_mut().take();
        });
        unsafe {
            let _ = DestroyWindow(window);
            let _ = DestroyWindow(host);
        }
        return Err(error);
    }
    SHELL.with(|state| {
        if let Some(shell) = state.borrow_mut().as_mut() {
            shell.submit(Request::Refresh);
        }
    });
    let mut message = MSG::default();
    loop {
        let result = unsafe { GetMessageW(&mut message, None, 0, 0) };
        if result.0 <= 0 {
            break;
        }
        if !unsafe { IsDialogMessageW(window, &message) }.as_bool() {
            unsafe {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        if matches!(message.message, WM_KEYDOWN | WM_SYSCHAR) {
            SHELL.with(|state| {
                if let Ok(mut state) = state.try_borrow_mut()
                    && let Some(shell) = state.as_mut()
                {
                    shell.ensure_focus_visible();
                }
            });
        }
    }
    SHELL.with(|state| {
        state.borrow_mut().take();
    });
    unsafe {
        let _ = DestroyWindow(window);
        let _ = DestroyWindow(host);
    }
    Ok(())
}

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let handled = SHELL.with(|cell| {
        let Ok(mut state) = cell.try_borrow_mut() else {
            return None;
        };
        state
            .as_mut()
            .and_then(|shell| shell.message(hwnd, message, wp, lp))
    });
    handled.unwrap_or_else(|| unsafe { DefWindowProcW(hwnd, message, wp, lp) })
}

impl Shell {
    fn hwnd(&self, id: i32) -> HWND {
        self.controls
            .iter()
            .find(|c| c.id == id)
            .map(|c| c.hwnd)
            .unwrap_or_default()
    }
    fn text(&self, id: i32, value: &str) {
        unsafe {
            let _ = SetWindowTextW(self.hwnd(id), PCWSTR(wide(value).as_ptr()));
        }
    }
    fn value(&self, id: i32) -> String {
        unsafe {
            let hwnd = self.hwnd(id);
            let len = GetWindowTextLengthW(hwnd).max(0) as usize;
            let mut buf = vec![0; len + 1];
            let used = GetWindowTextW(hwnd, &mut buf) as usize;
            String::from_utf16_lossy(&buf[..used])
        }
    }
    fn send(&self, id: i32, msg: u32, wp: usize, lp: isize) -> isize {
        unsafe { SendMessageW(self.hwnd(id), msg, Some(WPARAM(wp)), Some(LPARAM(lp))).0 }
    }
    fn enable(&self, id: i32, enabled: bool) {
        unsafe {
            let _ = EnableWindow(self.hwnd(id), enabled);
        }
    }
    fn list_add(&self, id: i32, message: u32, value: &str) {
        self.send(id, message, 0, wide(value).as_ptr() as isize);
        if message == LB_ADDSTRING {
            let current = self.send(id, LB_GETHORIZONTALEXTENT, 0, 0);
            let extent = (value
                .chars()
                .map(|c| if c.is_ascii() { 0.52 } else { 1.0 })
                .sum::<f64>()
                * f64::from(self.row - 12)
                * self.scale
                + 24.0)
                .ceil() as isize;
            if extent > current {
                self.send(id, LB_SETHORIZONTALEXTENT, extent as usize, 0);
            }
        }
    }
    fn selection(&self, id: i32, combo: bool) -> Option<usize> {
        let index = self.send(id, if combo { CB_GETCURSEL } else { LB_GETCURSEL }, 0, 0);
        (index >= 0).then_some(index as usize)
    }
    fn check(&self, id: i32, value: bool) {
        self.send(id, BM_SETCHECK, usize::from(value), 0);
    }
    fn checked(&self, id: i32) -> bool {
        self.send(id, BM_GETCHECK, 0, 0) == 1
    }
    fn selected_window(&self) -> Option<(isize, u32, u64)> {
        self.selection(ID_WINDOWS, false)
            .and_then(|i| self.view.windows.get(i))
            .map(|w| (w.handle, w.pid, w.token))
    }
    fn editable(&self) -> bool {
        !self.view.read_only
            && self.selected_profile == self.view.active_profile
            && self.view.active_profile.is_some()
    }

    fn create_controls(&mut self) -> Result<(), String> {
        let button = WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32);
        let label = WINDOW_STYLE(0); // SS_LEFT
        let edit = WS_TABSTOP | WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32);
        let combo = WS_TABSTOP | WS_VSCROLL | WINDOW_STYLE(CBS_DROPDOWNLIST as u32);
        let list = WS_TABSTOP
            | WS_BORDER
            | WS_VSCROLL
            | WS_HSCROLL
            | WINDOW_STYLE(LBS_NOTIFY as u32 | LBS_NOINTEGRALHEIGHT as u32);
        let check = WS_TABSTOP | WINDOW_STYLE(BS_AUTOCHECKBOX as u32);
        let entries = [
            (ID_PAGE_MAIN, 0, "BUTTON", "窗口与预设(&W)", button),
            (ID_PAGE_SETTINGS, 0, "BUTTON", "设置(&S)", button),
            (ID_PAGE_ASSOCIATE, 0, "BUTTON", "关联显示器(&D)", button),
            (
                ID_INTRO,
                1,
                "STATIC",
                "① 摆好目标窗口  →  ② 记住位置  →  ③ 移动后恢复。关闭界面后仍在托盘运行。",
                label,
            ),
            (ID_PROFILE_LABEL, 1, "STATIC", "查看方案(&P)", label),
            (ID_PROFILE, 1, "COMBOBOX", "", combo),
            (ID_ENV, 1, "STATIC", "", label),
            (ID_WINDOWS_LABEL, 1, "STATIC", "已打开的窗口(&L)", label),
            (ID_WINDOWS, 1, "LISTBOX", "", list),
            (ID_REFRESH, 1, "BUTTON", "刷新窗口列表(&F)", button),
            (ID_MATCH, 1, "STATIC", "选择窗口以查看匹配结果。", label),
            (ID_REMEMBER, 1, "BUTTON", "记住所选窗口(&M)", button),
            (ID_RESTORE, 1, "BUTTON", "恢复所选窗口(&R)", button),
            (
                ID_RULE_LABEL,
                1,
                "STATIC",
                "特定窗口：标题包含关键字(&K)",
                label,
            ),
            (ID_RULE, 1, "EDIT", "", edit),
            (ID_CREATE_RULE, 1, "BUTTON", "捕获为特定规则(&C)", button),
            (ID_NEW_RULE_PREVIEW, 1, "STATIC", "", label),
            (
                ID_CREATE_DEFAULT,
                1,
                "BUTTON",
                "另存为应用默认（同应用窗口共用）(&O)",
                button,
            ),
            (
                ID_PRESETS_LABEL,
                1,
                "STATIC",
                "预设（特定规则按列表顺序优先匹配）(&E)",
                label,
            ),
            (ID_PRESETS, 1, "LISTBOX", "", list),
            (
                ID_EDITOR_HEADING,
                1,
                "STATIC",
                "编辑所选预设 — 以下百分比以目标屏可用工作区为基准",
                label,
            ),
            (ID_DISPLAY_LABEL, 1, "STATIC", "目标显示器(&T)", label),
            (ID_DISPLAY, 1, "COMBOBOX", "", combo),
            (ID_X_LABEL, 1, "STATIC", "左侧位置 %(&X)", label),
            (ID_X, 1, "EDIT", "", edit),
            (ID_Y_LABEL, 1, "STATIC", "顶部位置 %(&Y)", label),
            (ID_Y, 1, "EDIT", "", edit),
            (ID_WIDTH_LABEL, 1, "STATIC", "宽度 %(&B)", label),
            (ID_WIDTH, 1, "EDIT", "", edit),
            (ID_HEIGHT_LABEL, 1, "STATIC", "高度 %(&H)", label),
            (ID_HEIGHT, 1, "EDIT", "", edit),
            (
                ID_MAXIMIZED,
                1,
                "BUTTON",
                "恢复时最大化（同时保留正常还原位置）(&A)",
                check,
            ),
            (
                ID_EDIT_KEYWORD_LABEL,
                1,
                "STATIC",
                "标题关键字（应用默认留空）(&J)",
                label,
            ),
            (ID_EDIT_KEYWORD, 1, "EDIT", "", edit),
            (ID_SAVE_PRESET, 1, "BUTTON", "保存预设(&V)", button),
            (ID_UP, 1, "BUTTON", "规则上移(&U)", button),
            (ID_DOWN, 1, "BUTTON", "规则下移(&N)", button),
            (ID_DELETE, 1, "BUTTON", "删除所选预设(&Q)", button),
            (
                ID_REBIND,
                1,
                "BUTTON",
                "将该应用预设关联到所选应用(&G)",
                button,
            ),
            (ID_REBIND_HINT, 1, "STATIC", "", label),
            (ID_UNDO, 0, "BUTTON", "撤销最近一次更新(&Z)", button),
            (ID_RESULT_LABEL, 0, "STATIC", "最近结果", label),
            (
                ID_RESULT,
                0,
                "EDIT",
                "",
                WS_TABSTOP
                    | WS_BORDER
                    | WS_VSCROLL
                    | WINDOW_STYLE(
                        ES_READONLY as u32 | ES_MULTILINE as u32 | ES_AUTOVSCROLL as u32,
                    ),
            ),
            (
                ID_SETTINGS_TITLE,
                2,
                "STATIC",
                "两个全局热键均可修改；新组合注册并保存成功后才替换旧热键。",
                label,
            ),
            (ID_RESTORE_KEY_LABEL, 2, "STATIC", "恢复位置热键(&R)", label),
            (ID_RESTORE_KEY, 2, "EDIT", "", edit),
            (
                ID_REMEMBER_KEY_LABEL,
                2,
                "STATIC",
                "记住位置热键(&M)",
                label,
            ),
            (ID_REMEMBER_KEY, 2, "EDIT", "", edit),
            (
                ID_KEY_HELP,
                2,
                "STATIC",
                "格式示例：Ctrl+Alt+F9、Win+Shift+P；字母、数字、F1–F24、Space、Tab、Enter、Esc。",
                label,
            ),
            (
                ID_AUTOSTART,
                2,
                "BUTTON",
                "登录 Windows 后自动启动（普通权限）(&A)",
                check,
            ),
            (ID_SAVE_SETTINGS, 2, "BUTTON", "保存设置(&V)", button),
            (ID_STARTUP_WARNING, 2, "STATIC", "", label),
            (ID_KEY_STATUS, 2, "STATIC", "", label),
            (ID_CONFIG_LABEL, 2, "STATIC", "配置文件（升级保留）", label),
            (
                ID_CONFIG_PATH,
                2,
                "EDIT",
                "",
                edit | WINDOW_STYLE(ES_READONLY as u32),
            ),
            (ID_RECOVER, 2, "BUTTON", "恢复有效备份(&B)", button),
            (
                ID_RESET_CONFIG,
                2,
                "BUTTON",
                "保留原件并新建配置(&N)",
                button,
            ),
            (
                ID_SETTINGS_HINT,
                2,
                "STATIC",
                "关闭窗口继续在托盘运行；从托盘退出。管理员窗口可尝试托盘中的“以管理员身份重新启动”。",
                label,
            ),
            (
                ID_ASSOC_TITLE,
                3,
                "STATIC",
                "显示器身份不明确时，请将原方案中的屏幕与当前实际屏幕逐一关联。",
                label,
            ),
            (
                ID_ASSOC_PROFILE_LABEL,
                3,
                "STATIC",
                "要关联的原方案(&P)",
                label,
            ),
            (ID_ASSOC_PROFILE, 3, "COMBOBOX", "", combo),
            (ID_IDENTIFY, 3, "BUTTON", "识别屏幕编号(&I)", button),
            (
                ID_ASSOC_OLD_LABEL,
                3,
                "STATIC",
                "原方案中的显示器(&O)",
                label,
            ),
            (ID_ASSOC_OLD, 3, "COMBOBOX", "", combo),
            (
                ID_ASSOC_NEW_LABEL,
                3,
                "STATIC",
                "当前连接的显示器(&N)",
                label,
            ),
            (ID_ASSOC_NEW, 3, "COMBOBOX", "", combo),
            (ID_ASSOC_SET, 3, "BUTTON", "加入对应关系(&M)", button),
            (
                ID_ASSOC_PREVIEW,
                3,
                "EDIT",
                "",
                WS_TABSTOP
                    | WS_BORDER
                    | WS_VSCROLL
                    | WINDOW_STYLE(ES_READONLY as u32 | ES_MULTILINE as u32),
            ),
            (
                ID_ASSOC_APPLY,
                3,
                "BUTTON",
                "检查并应用全部关联(&V)",
                button,
            ),
            (
                ID_ASSOC_HELP,
                3,
                "STATIC",
                "每台原屏幕须对应不同的当前屏幕。此页草稿仅在点击应用后保存；切换方案会清空草稿。",
                label,
            ),
            (
                ID_CREATE_ENVIRONMENT,
                3,
                "BUTTON",
                "作为新环境配置(&C)",
                button,
            ),
        ];
        for (id, page, class, title, style) in entries {
            let hwnd = unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(wide(class).as_ptr()),
                    PCWSTR(wide(title).as_ptr()),
                    WS_CHILD | style,
                    0,
                    0,
                    0,
                    0,
                    Some(self.window),
                    Some(HMENU(id as *mut _)),
                    None,
                    None,
                )
            }
            .map_err(|e| format!("创建控件失败：{e}"))?;
            unsafe {
                SendMessageW(
                    hwnd,
                    WM_SETFONT,
                    Some(WPARAM(self.font.0 as usize)),
                    Some(LPARAM(0)),
                );
            }
            self.controls.push(Control { id, hwnd, page });
        }
        Ok(())
    }

    fn make_font(&mut self) {
        if self.owned_font {
            unsafe {
                let _ = DeleteObject(self.font.into());
            }
        }
        let mut metrics = NONCLIENTMETRICSW {
            cbSize: size_of::<NONCLIENTMETRICSW>() as u32,
            ..Default::default()
        };
        let available = unsafe {
            SystemParametersInfoW(
                SPI_GETNONCLIENTMETRICS,
                metrics.cbSize,
                Some((&mut metrics as *mut NONCLIENTMETRICSW).cast()),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS::default(),
            )
        }
        .is_ok();
        self.font = if available {
            // Metrics queried in this PMv2 thread are at the system DPI; scale to this window.
            let system_dpi = unsafe { windows::Win32::UI::HiDpi::GetDpiForSystem() }.max(96);
            metrics.lfMessageFont.lfHeight =
                (f64::from(metrics.lfMessageFont.lfHeight) * self.scale * 96.0
                    / f64::from(system_dpi))
                .round() as i32;
            self.row = ((metrics.lfMessageFont.lfHeight.abs() as f64 / self.scale).ceil() as i32
                + 12)
                .max(30);
            unsafe { CreateFontIndirectW(&metrics.lfMessageFont) }
        } else {
            HFONT::default()
        };
        self.owned_font = !self.font.is_invalid();
        if !self.owned_font {
            self.font = HFONT(unsafe { GetStockObject(DEFAULT_GUI_FONT) }.0);
        }
        for control in &self.controls {
            unsafe {
                SendMessageW(
                    control.hwnd,
                    WM_SETFONT,
                    Some(WPARAM(self.font.0 as usize)),
                    Some(LPARAM(1)),
                );
            }
        }
    }

    fn fit_initial_window(&self) {
        let mut work = RECT::default();
        if unsafe {
            SystemParametersInfoW(
                SPI_GETWORKAREA,
                0,
                Some((&mut work as *mut RECT).cast()),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS::default(),
            )
        }
        .is_ok()
        {
            let width = (1100.0 * self.scale).round() as i32;
            let height = (800.0 * self.scale).round() as i32;
            unsafe {
                let _ = SetWindowPos(
                    self.window,
                    None,
                    work.left + 16,
                    work.top + 16,
                    width.min(work.right - work.left - 32),
                    height.min(work.bottom - work.top - 32),
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
        }
    }

    fn register_initial(&mut self) {
        for key in [self.active_settings.restore, self.active_settings.remember] {
            if let Err(error) = self.register(key) {
                self.last_result = format!("{}\r\n{error}", self.last_result);
            }
        }
    }
    fn register(&mut self, key: Hotkey) -> Result<i32, String> {
        if let Some(item) = self.registrations.iter().find(|r| r.key == key) {
            return Ok(item.id);
        }
        let id = self.next_hotkey_id;
        self.next_hotkey_id += 1;
        unsafe {
            RegisterHotKey(
                Some(self.host),
                id,
                HOT_KEY_MODIFIERS(key.modifiers) | MOD_NOREPEAT,
                key.key,
            )
        }
        .map_err(|e| {
            format!(
                "{} 注册失败：可能已被其他程序占用。请选择其他组合。({e})",
                key.label()
            )
        })?;
        self.registrations.push(Registration { key, id });
        Ok(id)
    }
    fn prepare_settings(&mut self, settings: Settings) -> Result<(), String> {
        if self.busy || self.worker_failed || self.exiting {
            return Err("正在处理上一项操作，请稍后重试。".into());
        }
        settings.validate()?;
        let mut added_ids = Vec::new();
        for key in [settings.restore, settings.remember] {
            if !self.registrations.iter().any(|r| r.key == key) {
                match self.register(key) {
                    Ok(id) => added_ids.push(id),
                    Err(error) => {
                        self.unregister_ids(&added_ids);
                        return Err(error);
                    }
                }
            }
        }
        self.pending_settings = Some(PendingSettings {
            settings: settings.clone(),
            added_ids,
        });
        self.submit(Request::UpdateSettings(settings));
        Ok(())
    }
    fn unregister_ids(&mut self, ids: &[i32]) {
        for id in ids {
            unsafe {
                let _ = UnregisterHotKey(Some(self.host), *id);
            }
        }
        self.registrations.retain(|r| !ids.contains(&r.id));
    }
    fn finish_settings(&mut self, success: bool, actual: &Settings) {
        if let Some(pending) = self.pending_settings.take() {
            if success && pending.settings == *actual {
                self.active_settings = pending.settings;
                let obsolete: Vec<_> = self
                    .registrations
                    .iter()
                    .filter(|r| {
                        r.key != self.active_settings.restore
                            && r.key != self.active_settings.remember
                    })
                    .map(|r| r.id)
                    .collect();
                self.unregister_ids(&obsolete);
            } else {
                self.unregister_ids(&pending.added_ids);
            }
        }
    }

    fn submit(&mut self, request: Request) {
        if self.busy || self.worker_failed || self.exiting {
            self.result("正在处理上一项操作，请稍后重试。", false);
            return;
        }
        let restart = matches!(request, Request::RestartElevated);
        match self.requests.try_send(request) {
            Ok(()) => {
                self.busy = true;
                self.pending_restart = restart;
                self.text(ID_RESULT, "正在处理…");
                self.update_enabled();
            }
            Err(TrySendError::Full(_)) => self.result("正在处理上一项操作，请稍后重试。", false),
            Err(TrySendError::Disconnected(_)) => {
                self.worker_failed = true;
                self.result("后台操作线程已停止，请退出后重新启动。", false);
            }
        }
    }
    fn worker_ready(&mut self) {
        while let Ok(reply) = self.replies.try_recv() {
            self.busy = false;
            match reply {
                WorkerReply::Done(response) => {
                    let response = *response;
                    let restarted = self.pending_restart && response.success;
                    self.pending_restart = false;
                    self.finish_settings(response.success, &response.view.config.settings);
                    let old_selection = self.selected_window();
                    if self.selected_profile == self.view.active_profile {
                        self.selected_profile = response.view.active_profile.clone();
                    }
                    self.view = response.view;
                    self.refresh_controls();
                    if let Some((hwnd, pid, token)) = old_selection
                        && let Some(index) = self
                            .view
                            .windows
                            .iter()
                            .position(|w| w.handle == hwnd && w.pid == pid && w.token == token)
                    {
                        self.send(ID_WINDOWS, LB_SETCURSEL, index, 0);
                    }
                    self.match_preview();
                    self.result(&response.message, true);
                    if restarted {
                        self.exiting = true;
                    }
                }
                WorkerReply::Panicked => {
                    self.worker_failed = true;
                    self.result("后台操作意外停止。原配置保留，请退出后重新启动。", true);
                }
            }
            if self.exiting {
                unsafe {
                    PostQuitMessage(0);
                }
            }
        }
    }

    fn refresh_controls(&mut self) {
        if self
            .selected_profile
            .as_ref()
            .is_none_or(|id| self.view.config.profile(id).is_none())
        {
            self.selected_profile = self
                .view
                .active_profile
                .clone()
                .or_else(|| self.view.config.profiles.first().map(|p| p.id.clone()));
        }
        self.send(ID_PROFILE, CB_RESETCONTENT, 0, 0);
        self.send(ID_ASSOC_PROFILE, CB_RESETCONTENT, 0, 0);
        for (i, profile) in self.view.config.profiles.iter().enumerate() {
            let suffix = if Some(&profile.id) == self.view.active_profile.as_ref() {
                "（当前活动）"
            } else {
                "（未连接／仅查看）"
            };
            self.list_add(
                ID_PROFILE,
                CB_ADDSTRING,
                &format!("{} {suffix}", profile.name),
            );
            self.list_add(
                ID_ASSOC_PROFILE,
                CB_ADDSTRING,
                &format!("{}（{} 屏）", profile.name, profile.display_ids.len()),
            );
            if Some(&profile.id) == self.selected_profile.as_ref() {
                self.send(ID_PROFILE, CB_SETCURSEL, i, 0);
            }
            if Some(&profile.id) == self.association_profile.as_ref() {
                self.send(ID_ASSOC_PROFILE, CB_SETCURSEL, i, 0);
            }
        }
        if self.association_profile.is_none() && !self.view.config.profiles.is_empty() {
            let index = self
                .view
                .active_profile
                .as_ref()
                .and_then(|id| self.view.config.profiles.iter().position(|p| &p.id == id))
                .unwrap_or(0);
            self.send(ID_ASSOC_PROFILE, CB_SETCURSEL, index, 0);
            self.association_profile = Some(self.view.config.profiles[index].id.clone());
        }
        let env = if !self.tray_ready {
            "托盘图标尚不可用；点击刷新可重试。关闭此窗口将退出程序。".to_string()
        } else if self.view.read_only {
            "配置只读：请在设置页查看恢复入口。".to_string()
        } else if self.view.needs_association {
            "需要确认显示器关联；请打开“关联显示器”。".to_string()
        } else if self.view.active_profile.is_none() {
            "正在识别显示器，请稍后刷新。".to_string()
        } else if self.selected_profile != self.view.active_profile {
            "正在查看未连接的方案，无法修改；热键始终使用当前活动方案。".to_string()
        } else {
            let missing = [self.active_settings.restore, self.active_settings.remember]
                .iter()
                .any(|key| !self.registrations.iter().any(|r| &r.key == key));
            format!(
                "恢复：{}  ·  记住：{}{}",
                self.active_settings.restore.label(),
                self.active_settings.remember.label(),
                if missing {
                    "；部分热键不可用，请到设置页修改。"
                } else {
                    ""
                }
            )
        };
        self.text(ID_ENV, &env);
        self.send(ID_WINDOWS, LB_RESETCONTENT, 0, 0);
        for window in &self.view.windows {
            self.list_add(
                ID_WINDOWS,
                LB_ADDSTRING,
                &format!("{} — {}", window.app_name, window.title),
            );
        }
        self.rebuild_presets();
        self.text(ID_RESTORE_KEY, &self.active_settings.restore.label());
        self.text(ID_REMEMBER_KEY, &self.active_settings.remember.label());
        self.check(ID_AUTOSTART, self.view.config.settings.autostart);
        self.text(
            ID_STARTUP_WARNING,
            self.view.startup_warning.as_deref().unwrap_or(""),
        );
        self.text(
            ID_SAVE_SETTINGS,
            if self.view.startup_warning.is_some() && self.view.config.settings.autostart {
                "保存并修复开机启动路径(&V)"
            } else {
                "保存设置(&V)"
            },
        );
        self.text(ID_CONFIG_PATH, &self.view.config_path);
        self.text(ID_RESULT, &self.last_result);
        self.key_status();
        self.rebuild_association();
        self.update_enabled();
        self.layout();
    }

    fn rebuild_presets(&mut self) {
        let selected_id = self.editor.as_ref().map(|e| e.preset.id.clone());
        self.rows.clear();
        self.send(ID_PRESETS, LB_RESETCONTENT, 0, 0);
        if let Some(profile) = self
            .selected_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
        {
            for app in &profile.applications {
                for (i, rule) in app.rules.iter().enumerate() {
                    self.list_add(
                        ID_PRESETS,
                        LB_ADDSTRING,
                        &format!("{} · {}. 标题包含「{}」", app.app_name, i + 1, rule.keyword),
                    );
                    self.rows.push(PresetRow {
                        profile_id: profile.id.clone(),
                        app_id: app.app_id.clone(),
                        preset: rule.preset.clone(),
                        keyword: Some(rule.keyword.clone()),
                        base_revision: self.view.config.revision,
                    });
                }
                if let Some(default) = &app.default {
                    self.list_add(
                        ID_PRESETS,
                        LB_ADDSTRING,
                        &format!("{} · 应用默认（同应用共用）", app.app_name),
                    );
                    self.rows.push(PresetRow {
                        profile_id: profile.id.clone(),
                        app_id: app.app_id.clone(),
                        preset: default.clone(),
                        keyword: None,
                        base_revision: self.view.config.revision,
                    });
                }
            }
        }
        let index = selected_id.and_then(|id| self.rows.iter().position(|r| r.preset.id == id));
        if let Some(index) = index {
            self.send(ID_PRESETS, LB_SETCURSEL, index, 0);
        }
        self.load_editor();
    }

    fn load_editor(&mut self) {
        self.editor = self
            .selection(ID_PRESETS, false)
            .and_then(|i| self.rows.get(i))
            .cloned();
        self.display_choices.clear();
        self.send(ID_DISPLAY, CB_RESETCONTENT, 0, 0);
        if let Some(profile) = self
            .selected_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
        {
            for display_id in &profile.display_ids {
                let name = self
                    .view
                    .config
                    .displays
                    .iter()
                    .find(|d| &d.id == display_id)
                    .map(|d| d.name.as_str())
                    .unwrap_or("未知显示器");
                let connected = self
                    .view
                    .bindings
                    .iter()
                    .any(|b| &b.display_id == display_id);
                self.list_add(
                    ID_DISPLAY,
                    CB_ADDSTRING,
                    &format!("{}{}", name, if connected { "" } else { "（待关联）" }),
                );
                self.display_choices.push(display_id.clone());
            }
        }
        if let Some(editor) = &self.editor {
            let placement = &editor.preset.placement;
            if let Some(i) = self
                .display_choices
                .iter()
                .position(|id| id == &placement.display_id)
            {
                self.send(ID_DISPLAY, CB_SETCURSEL, i, 0);
            }
            let values = [
                placement.rect.x,
                placement.rect.y,
                placement.rect.width,
                placement.rect.height,
            ];
            self.original_percent = values.map(|v| format!("{:.4}", v * 100.0));
            for (i, id) in [ID_X, ID_Y, ID_WIDTH, ID_HEIGHT].iter().enumerate() {
                self.text(*id, &self.original_percent[i]);
            }
            self.check(ID_MAXIMIZED, placement.maximized);
            self.text(ID_EDIT_KEYWORD, editor.keyword.as_deref().unwrap_or(""));
        } else {
            for id in [ID_X, ID_Y, ID_WIDTH, ID_HEIGHT, ID_EDIT_KEYWORD] {
                self.text(id, "");
            }
            self.check(ID_MAXIMIZED, false);
        }
        self.rebind_hint();
        self.update_enabled();
        self.layout();
    }

    fn match_preview(&mut self) {
        let Some(index) = self.selection(ID_WINDOWS, false) else {
            self.text(ID_MATCH, "选择窗口以查看匹配结果。");
            return;
        };
        let Some(window) = self.view.windows.get(index) else {
            return;
        };
        let matched = self
            .view
            .active_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
            .and_then(|p| p.applications.iter().find(|a| a.app_id == window.app_id));
        let (preview, button) = if let Some(app) = matched {
            let title = window.title.to_lowercase();
            if let Some(rule) = app
                .rules
                .iter()
                .find(|r| title.contains(&r.keyword.to_lowercase()))
            {
                (
                    format!(
                        "匹配特定规则：标题包含「{}」。首条匹配规则优先。",
                        rule.keyword
                    ),
                    "更新特定规则位置(&M)",
                )
            } else if app.default.is_some() {
                (
                    "匹配应用默认：同应用的窗口共用此预设；可撤销最近一次更新。".into(),
                    "更新应用默认位置(&M)",
                )
            } else {
                (
                    "尚未配置。记住位置将创建应用默认预设。".into(),
                    "记住为应用默认(&M)",
                )
            }
        } else {
            (
                "尚未配置。记住位置将创建应用默认预设。".into(),
                "记住为应用默认(&M)",
            )
        };
        self.text(ID_MATCH, &preview);
        self.text(ID_REMEMBER, button);
        self.new_rule_preview();
        self.rebind_hint();
        self.update_enabled();
        self.layout();
    }

    fn new_rule_preview(&self) {
        let preview = self
            .selection(ID_WINDOWS, false)
            .and_then(|i| self.view.windows.get(i))
            .map(|window| {
                let app = self
                    .view
                    .active_profile
                    .as_ref()
                    .and_then(|id| self.view.config.profile(id))
                    .and_then(|p| p.applications.iter().find(|a| a.app_id == window.app_id));
                preview_new_rule(app, &window.title, &self.value(ID_RULE))
            })
            .unwrap_or_else(|| "请先选择窗口，再输入标题关键字以预览匹配结果。".into());
        self.text(ID_NEW_RULE_PREVIEW, &preview);
    }

    fn can_create_default(&self) -> bool {
        self.selection(ID_WINDOWS, false)
            .and_then(|i| self.view.windows.get(i))
            .and_then(|window| {
                self.view
                    .active_profile
                    .as_ref()
                    .and_then(|id| self.view.config.profile(id))
                    .and_then(|p| p.applications.iter().find(|a| a.app_id == window.app_id))
            })
            .is_some_and(|app| app.default.is_none() && !app.rules.is_empty())
    }

    fn rebind_hint(&self) {
        let message = if let Some(editor) = &self.editor {
            let app = self
                .view
                .config
                .profile(&editor.profile_id)
                .and_then(|p| p.applications.iter().find(|a| a.app_id == editor.app_id));
            if let Some(app) = app {
                format!(
                    "应用路径改变时：迁移「{}」在此方案中的应用默认及全部 {} 条标题规则。先在窗口列表选择新应用。",
                    app.app_name,
                    app.rules.len()
                )
            } else {
                String::new()
            }
        } else {
            String::new()
        };
        self.text(ID_REBIND_HINT, &message);
    }

    fn rebind_application(&mut self) -> Result<(), String> {
        if !self.editable() {
            return Err("未连接方案仅供查看。".into());
        }
        let editor = self.editor.clone().ok_or("请先选择旧应用的任意预设。")?;
        let window = self
            .selection(ID_WINDOWS, false)
            .and_then(|i| self.view.windows.get(i))
            .cloned()
            .ok_or("请在窗口列表选择新应用。")?;
        let profile = self
            .view
            .config
            .profile(&editor.profile_id)
            .ok_or("方案已变化，请刷新。")?;
        if window.app_id == editor.app_id {
            return Err("所选窗口仍属于同一应用，无需迁移。".into());
        }
        if profile
            .applications
            .iter()
            .any(|a| a.app_id == window.app_id)
        {
            return Err(
                "目标应用在此方案中已有预设。为避免覆盖，请先明确处理目标应用预设；本次不会合并。"
                    .into(),
            );
        }
        let app = profile
            .applications
            .iter()
            .find(|a| a.app_id == editor.app_id)
            .ok_or("旧应用预设已变化，请刷新。")?;
        let description = format!(
            "将方案「{}」中「{}」的应用默认及全部 {} 条标题规则迁移到「{}」。\n\n原应用：{}\n新应用：{}\n\n这些规则之后将按新应用匹配。确定迁移？",
            profile.name,
            app.app_name,
            app.rules.len(),
            window.app_name,
            app.app_id.strip_prefix("exe:").unwrap_or(&app.app_id),
            window.app_id.strip_prefix("exe:").unwrap_or(&window.app_id)
        );
        let confirm = unsafe {
            MessageBoxW(
                Some(self.window),
                PCWSTR(wide(&description).as_ptr()),
                w!("迁移应用预设"),
                MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2,
            )
        };
        if confirm == IDYES {
            self.submit(Request::RebindApplication {
                profile_id: editor.profile_id,
                old_app_id: editor.app_id,
                handle: window.handle,
                pid: window.pid,
                token: window.token,
                expected_revision: editor.base_revision,
            });
        }
        Ok(())
    }

    fn key_status(&self) {
        let status = |key: Hotkey| {
            if self.registrations.iter().any(|r| r.key == key) {
                "已注册"
            } else {
                "不可用，请修改"
            }
        };
        self.text(
            ID_KEY_STATUS,
            &format!(
                "实际注册状态：\r\n恢复 {}：{}\r\n记住 {}：{}",
                self.active_settings.restore.label(),
                status(self.active_settings.restore),
                self.active_settings.remember.label(),
                status(self.active_settings.remember)
            ),
        );
    }

    fn update_enabled(&self) {
        let available = !self.busy && !self.worker_failed && !self.exiting;
        let target = self.selected_window().is_some();
        let editable = self.editable() && available;
        for id in [ID_REMEMBER, ID_CREATE_RULE] {
            self.enable(id, editable && target);
        }
        self.enable(
            ID_RESTORE,
            available && target && self.view.active_profile.is_some(),
        );
        self.enable(ID_REFRESH, available);
        self.enable(
            ID_UNDO,
            available && !self.view.read_only && self.view.undo_label.is_some(),
        );
        self.text(
            ID_UNDO,
            &format!(
                "撤销：{}(&Z)",
                self.view.undo_label.as_deref().unwrap_or("暂无可撤销更新")
            ),
        );
        for id in [
            ID_DISPLAY,
            ID_X,
            ID_Y,
            ID_WIDTH,
            ID_HEIGHT,
            ID_MAXIMIZED,
            ID_SAVE_PRESET,
            ID_DELETE,
        ] {
            self.enable(id, editable && self.editor.is_some());
        }
        let rule = self.editor.as_ref().is_some_and(|e| e.keyword.is_some());
        for id in [ID_UP, ID_DOWN, ID_EDIT_KEYWORD] {
            self.enable(id, editable && rule);
        }
        self.enable(ID_REBIND, editable && target && self.editor.is_some());
        self.enable(
            ID_CREATE_DEFAULT,
            editable && target && self.can_create_default(),
        );
        self.enable(ID_SAVE_SETTINGS, available && !self.view.read_only);
        self.enable(ID_RECOVER, available && self.view.read_only);
        self.enable(ID_RESET_CONFIG, available && self.view.read_only);
        self.enable(ID_ASSOC_APPLY, available && !self.view.read_only);
    }

    fn save_editor(&mut self) -> Result<(), String> {
        let editor = self.editor.clone().ok_or("请先选择预设。")?;
        if !self.editable() {
            return Err("未连接方案仅供查看。".into());
        }
        let mut placement = editor.preset.placement.clone();
        let values = [
            placement.rect.x,
            placement.rect.y,
            placement.rect.width,
            placement.rect.height,
        ];
        let mut updated = values;
        for (i, id) in [ID_X, ID_Y, ID_WIDTH, ID_HEIGHT].iter().enumerate() {
            let text = self.value(*id);
            // Preserve the exact saved value if this field was not edited.
            if text != self.original_percent[i] {
                updated[i] = text
                    .trim()
                    .parse::<f64>()
                    .map_err(|_| "请输入有效的百分比数值。")?
                    / 100.0;
            }
        }
        placement.rect.x = updated[0];
        placement.rect.y = updated[1];
        placement.rect.width = updated[2];
        placement.rect.height = updated[3];
        placement.rect.validate()?;
        placement.display_id = self
            .selection(ID_DISPLAY, true)
            .and_then(|i| self.display_choices.get(i))
            .cloned()
            .ok_or("请选择目标显示器。")?;
        placement.maximized = self.checked(ID_MAXIMIZED);
        let keyword = if editor.keyword.is_some() {
            let keyword = self.value(ID_EDIT_KEYWORD).trim().to_string();
            if keyword.is_empty() {
                return Err("特定规则的标题关键字不能为空。".into());
            }
            Some(keyword)
        } else {
            None
        };
        self.submit(Request::EditPreset {
            profile_id: editor.profile_id,
            preset_id: editor.preset.id,
            placement,
            keyword,
            expected_revision: editor.base_revision,
        });
        Ok(())
    }

    fn rebuild_association(&mut self) {
        self.send(ID_ASSOC_OLD, CB_RESETCONTENT, 0, 0);
        self.send(ID_ASSOC_NEW, CB_RESETCONTENT, 0, 0);
        if let Some(profile) = self
            .association_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
        {
            for (i, id) in profile.display_ids.iter().enumerate() {
                let name = self
                    .view
                    .config
                    .displays
                    .iter()
                    .find(|d| &d.id == id)
                    .map(|d| d.name.as_str())
                    .unwrap_or("未知显示器");
                self.list_add(
                    ID_ASSOC_OLD,
                    CB_ADDSTRING,
                    &format!("原屏 {}：{}", i + 1, name),
                );
            }
            self.send(ID_ASSOC_OLD, CB_SETCURSEL, 0, 0);
            self.association
                .retain(|id, _| profile.display_ids.contains(id));
        }
        for (i, monitor) in self.view.monitors.iter().enumerate() {
            self.list_add(
                ID_ASSOC_NEW,
                CB_ADDSTRING,
                &format!(
                    "屏幕 {}：{} · {}×{} · ({},{})",
                    i + 1,
                    monitor.name,
                    monitor.rect.width(),
                    monitor.rect.height(),
                    monitor.rect.left,
                    monitor.rect.top
                ),
            );
        }
        self.send(ID_ASSOC_NEW, CB_SETCURSEL, 0, 0);
        self.association_preview();
    }
    fn association_preview(&self) {
        let mut lines = Vec::new();
        if let Some(profile) = self
            .association_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
        {
            for (i, id) in profile.display_ids.iter().enumerate() {
                let name = self
                    .view
                    .config
                    .displays
                    .iter()
                    .find(|d| &d.id == id)
                    .map(|d| d.name.as_str())
                    .unwrap_or("未知显示器");
                let target = self
                    .association
                    .get(id)
                    .and_then(|key| self.view.monitors.iter().position(|m| &m.key == key))
                    .map(|i| format!("当前屏幕 {}", i + 1))
                    .unwrap_or("尚未选择".into());
                lines.push(format!("原屏 {} {} → {}", i + 1, name, target));
            }
            let count = profile
                .applications
                .iter()
                .map(|a| a.rules.len() + usize::from(a.default.is_some()))
                .sum::<usize>();
            lines.push(format!("\r\n应用后影响本方案中的 {count} 个预设。"));
        }
        self.text(ID_ASSOC_PREVIEW, &lines.join("\r\n"));
    }

    fn add_association(&mut self) -> Result<(), String> {
        let profile = self
            .association_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
            .ok_or("请选择原方案。")?;
        let id = self
            .selection(ID_ASSOC_OLD, true)
            .and_then(|i| profile.display_ids.get(i))
            .cloned()
            .ok_or("请选择原显示器。")?;
        let key = self
            .selection(ID_ASSOC_NEW, true)
            .and_then(|i| self.view.monitors.get(i))
            .map(|m| m.key.clone())
            .ok_or("请选择当前显示器。")?;
        if self
            .association
            .iter()
            .any(|(other, target)| other != &id && target == &key)
        {
            return Err("此屏幕已关联其他原显示器，请先重新选择对应关系。".into());
        }
        self.association.insert(id, key);
        self.association_preview();
        Ok(())
    }
    fn apply_association(&mut self) -> Result<(), String> {
        let profile = self
            .association_profile
            .as_ref()
            .and_then(|id| self.view.config.profile(id))
            .ok_or("请选择原方案。")?;
        if profile.display_ids.len() != self.view.monitors.len()
            || profile
                .display_ids
                .iter()
                .any(|id| !self.association.contains_key(id))
        {
            return Err("请将方案中所有显示器与当前屏幕一对一关联；显示器数量必须一致。".into());
        }
        let bindings = profile
            .display_ids
            .iter()
            .map(|id| DisplayBinding {
                display_id: id.clone(),
                monitor_key: self.association[id].clone(),
            })
            .collect();
        self.submit(Request::Associate {
            profile_id: profile.id.clone(),
            bindings,
        });
        Ok(())
    }

    fn identify(&mut self) {
        self.clear_identifiers();
        for (index, monitor) in self.view.monitors.iter().enumerate() {
            if let Ok(hwnd) = unsafe {
                CreateWindowExW(
                    WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                    w!("STATIC"),
                    PCWSTR(wide(&format!("屏幕 {}\r\n{}", index + 1, monitor.name)).as_ptr()),
                    WS_POPUP | WS_BORDER | WINDOW_STYLE(1),
                    monitor.work.left + 32,
                    monitor.work.top + 32,
                    (360.0 * self.scale) as i32,
                    (110.0 * self.scale) as i32,
                    Some(self.host),
                    None,
                    None,
                    None,
                )
            } {
                unsafe {
                    SendMessageW(
                        hwnd,
                        WM_SETFONT,
                        Some(WPARAM(self.font.0 as usize)),
                        Some(LPARAM(0)),
                    );
                    let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                }
                self.identifiers.push(hwnd);
            }
        }
        unsafe {
            SetTimer(Some(self.host), IDENTIFY_TIMER, 3000, None);
        }
    }
    fn clear_identifiers(&mut self) {
        for hwnd in self.identifiers.drain(..) {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
        }
        unsafe {
            let _ = KillTimer(Some(self.host), IDENTIFY_TIMER);
        }
    }

    fn show(&mut self) {
        unsafe {
            // A hidden launcher may set STARTF_USESHOWWINDOW. Its first
            // ShowWindow call consumes that startup hint; explicit --show and
            // subsequent tray activation must still make our own UI visible.
            let _ = ShowWindow(self.window, SW_SHOW);
            let _ = ShowWindow(self.window, SW_RESTORE);
            let _ = SetForegroundWindow(self.window);
        }
        self.layout();
    }
    fn result(&mut self, message: &str, toast: bool) {
        self.last_result = message.to_string();
        self.text(ID_RESULT, message);
        self.update_enabled();
        if toast
            && (self.last_toast != message
                || self
                    .last_toast_at
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(3)))
        {
            self.last_toast = message.to_string();
            self.last_toast_at = Some(Instant::now());
            self.show_toast(message);
        }
    }
    fn show_toast(&mut self, message: &str) {
        self.clear_toast();
        let mut monitor = MONITORINFO {
            cbSize: size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let foreground = unsafe { GetForegroundWindow() };
        if !unsafe {
            GetMonitorInfoW(
                MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST),
                &mut monitor,
            )
        }
        .as_bool()
        {
            return;
        }
        let scale = unsafe { GetDpiForWindow(foreground) }.max(96) as f64 / 96.0;
        let width = (480.0 * scale).round() as i32;
        let width = width
            .min(monitor.rcWork.right - monitor.rcWork.left - 32)
            .max(80);
        let height = (120.0 * scale).round() as i32;
        let title = wide(&format!("  Screen Pin\r\n\r\n  {message}"));
        if let Ok(hwnd) = unsafe {
            CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                w!("STATIC"),
                PCWSTR(title.as_ptr()),
                WS_POPUP | WS_BORDER,
                monitor.rcWork.right - width - 16,
                monitor.rcWork.bottom - height - 16,
                width,
                height,
                Some(self.host),
                None,
                None,
                None,
            )
        } {
            unsafe {
                SendMessageW(
                    hwnd,
                    WM_SETFONT,
                    Some(WPARAM(self.font.0 as usize)),
                    Some(LPARAM(0)),
                );
                let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                SetTimer(
                    Some(self.host),
                    TOAST_TIMER,
                    if message.starts_with("已恢复") || message.starts_with("已符合") {
                        1400
                    } else {
                        3000
                    },
                    None,
                );
            }
            self.toast_window = Some(hwnd);
        }
    }
    fn clear_toast(&mut self) {
        if let Some(hwnd) = self.toast_window.take() {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
        }
        unsafe {
            let _ = KillTimer(Some(self.host), TOAST_TIMER);
        }
    }
    fn tray_data(&self) -> NOTIFYICONDATAW {
        let mut icon = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.host,
            uID: 1,
            ..Default::default()
        };
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = TRAY_MESSAGE;
        icon.hIcon = unsafe { LoadIconW(None, IDI_APPLICATION) }.unwrap_or_default();
        copy_wide(
            &mut icon.szTip,
            &format!(
                "Screen Pin · 恢复 {} · 记住 {}",
                self.active_settings.restore.label(),
                self.active_settings.remember.label()
            ),
        );
        icon
    }
    fn tray_add(&mut self) -> Result<(), String> {
        let icon = self.tray_data();
        self.tray_ready = unsafe { Shell_NotifyIconW(NIM_ADD, &icon) }.as_bool();
        if self.tray_ready {
            Ok(())
        } else {
            Err("无法创建托盘图标。请保持此界面打开，点击刷新重试；关闭窗口将退出。".into())
        }
    }
    fn tray_menu(&mut self) {
        let Ok(menu) = (unsafe { CreatePopupMenu() }) else {
            return;
        };
        unsafe {
            let _ = AppendMenuW(menu, MF_STRING, ID_MENU_OPEN, w!("打开 Screen Pin"));
            let undo = format!(
                "撤销：{}",
                self.view.undo_label.as_deref().unwrap_or("暂无可撤销更新")
            );
            let flags = MF_STRING
                | if self.view.undo_label.is_some() && !self.busy && !self.view.read_only {
                    MENU_ITEM_FLAGS(0)
                } else {
                    MF_GRAYED
                };
            let _ = AppendMenuW(menu, flags, ID_MENU_UNDO, PCWSTR(wide(&undo).as_ptr()));
            let recent = format!(
                "最近：{}",
                self.last_result
                    .replace(['\r', '\n'], " ")
                    .chars()
                    .take(100)
                    .collect::<String>()
            );
            let _ = AppendMenuW(
                menu,
                MF_STRING | MF_GRAYED,
                0,
                PCWSTR(wide(&recent).as_ptr()),
            );
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            let _ = AppendMenuW(menu, MF_STRING, ID_MENU_ELEVATE, w!("以管理员身份重新启动"));
            let _ = AppendMenuW(menu, MF_STRING, ID_MENU_EXIT, w!("退出"));
            let mut point = POINT::default();
            let _ = GetCursorPos(&mut point);
            let _ = SetForegroundWindow(self.host);
            let selected = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                Some(0),
                self.host,
                None,
            )
            .0 as usize;
            let _ = PostMessageW(Some(self.host), WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            match selected {
                ID_MENU_OPEN => self.show(),
                ID_MENU_UNDO => self.submit(Request::Undo),
                ID_MENU_ELEVATE => self.submit(Request::RestartElevated),
                ID_MENU_EXIT => self.exit(),
                _ => {}
            }
        }
    }
    fn exit(&mut self) {
        if self.busy {
            self.exiting = true;
            self.result("正在完成当前操作，完成后退出。", false);
        } else {
            unsafe {
                PostQuitMessage(0);
            }
        }
    }

    fn command(&mut self, id: i32, notification: u16) {
        if id == ID_RULE && notification == EN_CHANGE as u16 {
            self.new_rule_preview();
            self.layout();
            return;
        }
        if notification == 0 {
            match id as usize {
                ID_MENU_EXIT => {
                    self.exit();
                    return;
                }
                ID_MENU_OPEN => {
                    self.show();
                    return;
                }
                ID_MENU_UNDO => {
                    self.submit(Request::Undo);
                    return;
                }
                ID_MENU_ELEVATE => {
                    self.submit(Request::RestartElevated);
                    return;
                }
                _ => {}
            }
        }
        if notification == CBN_SELCHANGE as u16 && matches!(id, ID_PROFILE | ID_ASSOC_PROFILE) {
            match id {
                ID_PROFILE => {
                    self.selected_profile = self
                        .selection(id, true)
                        .and_then(|i| self.view.config.profiles.get(i))
                        .map(|p| p.id.clone());
                    self.refresh_controls();
                    self.match_preview();
                }
                ID_ASSOC_PROFILE => {
                    self.association_profile = self
                        .selection(id, true)
                        .and_then(|i| self.view.config.profiles.get(i))
                        .map(|p| p.id.clone());
                    self.association.clear();
                    self.rebuild_association();
                }
                _ => {}
            }
            return;
        }
        if notification == LBN_SELCHANGE as u16 {
            if id == ID_WINDOWS {
                self.match_preview();
            } else if id == ID_PRESETS {
                self.load_editor();
            }
            return;
        }
        if notification != BN_CLICKED as u16 {
            return;
        }
        let result: Result<(), String> = match id {
            ID_PAGE_MAIN | ID_PAGE_SETTINGS | ID_PAGE_ASSOCIATE => {
                self.page = if id == ID_PAGE_MAIN {
                    PAGE_MAIN
                } else if id == ID_PAGE_SETTINGS {
                    PAGE_SETTINGS
                } else {
                    PAGE_ASSOCIATE
                };
                self.scroll = 0;
                self.layout();
                Ok(())
            }
            ID_REFRESH => {
                if !self.tray_ready
                    && let Err(error) = self.tray_add()
                {
                    self.result(&error, false);
                }
                self.submit(Request::Refresh);
                Ok(())
            }
            ID_REMEMBER | ID_RESTORE => {
                if let Some((handle, pid, token)) = self.selected_window() {
                    self.submit(if id == ID_REMEMBER {
                        Request::Remember { handle, pid, token }
                    } else {
                        Request::Restore { handle, pid, token }
                    });
                    Ok(())
                } else {
                    Err("请先选择目标窗口。".into())
                }
            }
            ID_CREATE_RULE => {
                let keyword = self.value(ID_RULE).trim().to_string();
                if keyword.is_empty() {
                    Err("请输入标题关键字。".into())
                } else if let Some((handle, pid, token)) = self.selected_window() {
                    self.submit(Request::CreateRule {
                        handle,
                        pid,
                        token,
                        keyword,
                    });
                    Ok(())
                } else {
                    Err("请先选择目标窗口。".into())
                }
            }
            ID_CREATE_DEFAULT => {
                if let Some((handle, pid, token)) = self.selected_window() {
                    self.submit(Request::CreateDefault { handle, pid, token });
                    Ok(())
                } else {
                    Err("请先选择目标窗口。".into())
                }
            }
            ID_UNDO => {
                self.submit(Request::Undo);
                Ok(())
            }
            ID_SAVE_PRESET => self.save_editor(),
            ID_REBIND => self.rebind_application(),
            ID_DELETE | ID_UP | ID_DOWN => {
                if let Some(editor) = self.editor.clone() {
                    if id == ID_DELETE {
                        self.submit(Request::DeletePreset {
                            profile_id: editor.profile_id,
                            preset_id: editor.preset.id,
                            expected_revision: editor.base_revision,
                        });
                    } else {
                        self.submit(Request::MoveRule {
                            profile_id: editor.profile_id,
                            preset_id: editor.preset.id,
                            direction: if id == ID_UP { -1 } else { 1 },
                            expected_revision: editor.base_revision,
                        });
                    }
                    Ok(())
                } else {
                    Err("请先选择预设。".into())
                }
            }
            ID_SAVE_SETTINGS => match (
                parse_hotkey(&self.value(ID_RESTORE_KEY)),
                parse_hotkey(&self.value(ID_REMEMBER_KEY)),
            ) {
                (Ok(restore), Ok(remember)) => self.prepare_settings(Settings {
                    restore,
                    remember,
                    autostart: self.checked(ID_AUTOSTART),
                }),
                (Err(error), _) | (_, Err(error)) => Err(error),
            },
            ID_RECOVER => {
                self.submit(Request::RecoverBackup);
                Ok(())
            }
            ID_RESET_CONFIG => {
                let confirm = unsafe {
                    MessageBoxW(
                        Some(self.window),
                        w!(
                            "将保留当前无法读取的配置原件，并为当前显示器新建空配置。原有预设不会自动导入。\n\n确定新建？"
                        ),
                        w!("新建配置"),
                        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
                    )
                };
                if confirm == IDYES {
                    self.submit(Request::ResetConfig);
                }
                Ok(())
            }
            ID_CREATE_ENVIRONMENT => {
                let confirm = unsafe {
                    MessageBoxW(
                        Some(self.window),
                        w!(
                            "将当前连接的显示器视为新环境，并创建空方案。已有方案和预设继续保留。\n\n如果这些是以前用过的屏幕，请优先关联旧方案。继续创建？"
                        ),
                        w!("新环境"),
                        MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2,
                    )
                };
                if confirm == IDYES {
                    self.submit(Request::CreateEnvironment);
                }
                Ok(())
            }
            ID_IDENTIFY => {
                self.identify();
                Ok(())
            }
            ID_ASSOC_SET => self.add_association(),
            ID_ASSOC_APPLY => self.apply_association(),
            _ => Ok(()),
        };
        if let Err(error) = result {
            self.result(&error, false);
        }
    }

    fn message(&mut self, hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
        // Explorer broadcasts this message to every top-level window. Only the
        // owner may recreate the shared tray icon: a second NIM_ADD fails even
        // though the first recreation succeeded.
        if hwnd == self.host && message == self.taskbar_created && self.taskbar_created != 0 {
            if let Err(error) = self.tray_add() {
                self.show();
                self.result(&error, false);
            }
            return Some(LRESULT(0));
        }
        match message {
            SHOW_MESSAGE => {
                self.show();
                Some(LRESULT(0))
            }
            WORKER_MESSAGE => {
                self.worker_ready();
                Some(LRESULT(0))
            }
            HANDOFF_SUSPEND => {
                let mut failed = false;
                self.registrations.retain(|r| {
                    let keep = unsafe { UnregisterHotKey(Some(self.host), r.id) }.is_err();
                    failed |= keep;
                    keep
                });
                self.hotkeys_suspended = true;
                self.key_status();
                Some(LRESULT(isize::from(!failed)))
            }
            HANDOFF_RESUME => {
                let mut failed = false;
                for key in [self.active_settings.restore, self.active_settings.remember] {
                    if self.register(key).is_err() {
                        failed = true;
                    }
                }
                self.hotkeys_suspended = false;
                self.key_status();
                if failed {
                    self.result(
                        "管理员交接取消后，部分热键恢复失败。请在设置页重新设置不可用组合。",
                        true,
                    );
                }
                Some(LRESULT(isize::from(!failed)))
            }
            WM_COMMAND => {
                self.command((wp.0 & 0xffff) as i32, ((wp.0 >> 16) & 0xffff) as u16);
                Some(LRESULT(0))
            }
            WM_HOTKEY => {
                if let Some(key) = self
                    .registrations
                    .iter()
                    .find(|r| r.id == wp.0 as i32)
                    .map(|r| r.key)
                {
                    let target = unsafe { GetForegroundWindow() };
                    let mut pid = 0;
                    unsafe {
                        GetWindowThreadProcessId(target, Some(&mut pid));
                    }
                    let handle = target.0 as isize;
                    let token = match crate::desktop::window_token(handle) {
                        Ok(token) => token,
                        Err(error) => {
                            self.result(&error, true);
                            return Some(LRESULT(0));
                        }
                    };
                    if key == self.active_settings.restore {
                        self.submit(Request::Restore { handle, pid, token });
                    } else if key == self.active_settings.remember {
                        self.submit(Request::Remember { handle, pid, token });
                    }
                }
                Some(LRESULT(0))
            }
            TRAY_MESSAGE => {
                match lp.0 as u32 {
                    WM_LBUTTONUP | WM_LBUTTONDBLCLK => self.show(),
                    WM_RBUTTONUP | WM_CONTEXTMENU => self.tray_menu(),
                    _ => {}
                }
                Some(LRESULT(0))
            }
            WM_CLOSE if hwnd == self.window => {
                if self.tray_ready {
                    unsafe {
                        let _ = ShowWindow(self.window, SW_HIDE);
                    }
                } else {
                    self.exit();
                }
                Some(LRESULT(0))
            }
            WM_SIZE if hwnd == self.window => {
                self.layout();
                Some(LRESULT(0))
            }
            WM_GETMINMAXINFO if hwnd == self.window && lp.0 != 0 => {
                let info = unsafe { &mut *(lp.0 as *mut MINMAXINFO) };
                info.ptMinTrackSize.x = (720.0 * self.scale) as i32;
                info.ptMinTrackSize.y = (440.0 * self.scale) as i32;
                Some(LRESULT(0))
            }
            WM_DPICHANGED if hwnd == self.window => {
                self.scale = (wp.0 & 0xffff) as f64 / 96.0;
                self.make_font();
                self.scroll = 0;
                if lp.0 != 0 {
                    let rect = unsafe { &*(lp.0 as *const RECT) };
                    unsafe {
                        let _ = SetWindowPos(
                            self.window,
                            None,
                            rect.left,
                            rect.top,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            SWP_NOZORDER | SWP_NOACTIVATE,
                        );
                    }
                }
                self.layout();
                Some(LRESULT(0))
            }
            WM_VSCROLL if hwnd == self.window => {
                self.scroll_message((wp.0 & 0xffff) as u32);
                Some(LRESULT(0))
            }
            WM_MOUSEWHEEL if hwnd == self.window => {
                let delta = ((wp.0 >> 16) as u16) as i16;
                self.scroll = (self.scroll - i32::from(delta) * self.row * 3 / 120).max(0);
                self.layout();
                Some(LRESULT(0))
            }
            WM_DISPLAYCHANGE => {
                unsafe {
                    SetTimer(Some(self.host), TOPOLOGY_TIMER, 800, None);
                }
                Some(LRESULT(0))
            }
            WM_SETTINGCHANGE => {
                self.make_font();
                self.layout();
                unsafe {
                    SetTimer(Some(self.host), TOPOLOGY_TIMER, 800, None);
                }
                Some(LRESULT(0))
            }
            WM_TIMER if wp.0 == TOPOLOGY_TIMER => {
                unsafe {
                    let _ = KillTimer(Some(self.host), TOPOLOGY_TIMER);
                }
                if !self.busy {
                    self.submit(Request::Refresh);
                } else {
                    unsafe {
                        SetTimer(Some(self.host), TOPOLOGY_TIMER, 300, None);
                    }
                }
                Some(LRESULT(0))
            }
            WM_TIMER if wp.0 == IDENTIFY_TIMER => {
                self.clear_identifiers();
                Some(LRESULT(0))
            }
            WM_TIMER if wp.0 == TOAST_TIMER => {
                self.clear_toast();
                Some(LRESULT(0))
            }
            WM_QUERYENDSESSION => Some(LRESULT(1)),
            WM_ENDSESSION if wp.0 != 0 => {
                unsafe {
                    PostQuitMessage(0);
                }
                Some(LRESULT(0))
            }
            _ => None,
        }
    }

    fn scroll_message(&mut self, code: u32) {
        let mut info = SCROLLINFO {
            cbSize: size_of::<SCROLLINFO>() as u32,
            fMask: SIF_ALL,
            ..Default::default()
        };
        let _ = unsafe { GetScrollInfo(self.window, SB_VERT, &mut info) };
        match SCROLLBAR_COMMAND(code as i32) {
            SB_LINEUP => self.scroll -= self.row,
            SB_LINEDOWN => self.scroll += self.row,
            SB_PAGEUP => self.scroll -= info.nPage as i32,
            SB_PAGEDOWN => self.scroll += info.nPage as i32,
            SB_THUMBTRACK | SB_THUMBPOSITION => self.scroll = info.nTrackPos,
            SB_TOP => self.scroll = 0,
            SB_BOTTOM => self.scroll = self.content_height,
            _ => {}
        }
        self.layout();
    }

    fn ensure_focus_visible(&mut self) {
        let focus = unsafe { GetFocus() };
        if !self.controls.iter().any(|c| c.hwnd == focus) {
            return;
        }
        let mut rect = RECT::default();
        let mut client = RECT::default();
        if unsafe { GetWindowRect(focus, &mut rect) }.is_err()
            || unsafe { GetClientRect(self.window, &mut client) }.is_err()
        {
            return;
        }
        let mut origin = POINT { x: 0, y: 0 };
        unsafe {
            let _ = ClientToScreen(self.window, &mut origin);
        }
        let top = rect.top - origin.y;
        let bottom = rect.bottom - origin.y;
        let delta = if top < 0 {
            (top as f64 / self.scale).floor() as i32 - 8
        } else if bottom > client.bottom {
            ((bottom - client.bottom) as f64 / self.scale).ceil() as i32 + 8
        } else {
            0
        };
        if delta != 0 {
            self.scroll += delta;
            self.layout();
        }
    }

    fn layout(&mut self) {
        let mut client = RECT::default();
        if unsafe { GetClientRect(self.window, &mut client) }.is_err() {
            return;
        }
        let width = ((client.right - client.left) as f64 / self.scale).floor() as i32;
        let height = ((client.bottom - client.top) as f64 / self.scale).floor() as i32;
        let margin = 16;
        let gap = 12;
        let row = self.row;
        let width = (width - 2 * margin).max(360);
        let has_editor = self.editor.is_some();
        let has_rule_preview = !self.value(ID_RULE).trim().is_empty();
        let rule_preview_height = if has_rule_preview { row * 2 + 8 } else { 0 };
        let has_explicit_default = self.can_create_default();
        let preview_height = rule_preview_height + if has_explicit_default { row + 8 } else { 0 };
        let startup_height = if self.view.startup_warning.is_some() {
            row * 2 + 8
        } else {
            0
        };
        let end = if self.page == PAGE_MAIN {
            row + 24
                + if has_editor {
                    row * 26 + 62 + preview_height
                } else {
                    row * 16 + 24 + preview_height
                }
        } else if self.page == PAGE_SETTINGS {
            row + 24 + row * 16 + 64 + startup_height
        } else {
            row + 24 + row * 18 + 72
        };
        let bottom = end + row * 5 + 24;
        self.content_height = bottom;
        self.scroll = self.scroll.clamp(0, (bottom - height).max(0));
        let info = SCROLLINFO {
            cbSize: size_of::<SCROLLINFO>() as u32,
            // Retain the scrollbar width when no scrolling is required. Hiding
            // it here would synchronously resize the client during this layout.
            fMask: SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL,
            nMin: 0,
            nMax: bottom - 1,
            nPage: height.max(0) as u32,
            nPos: self.scroll,
            ..Default::default()
        };
        unsafe {
            SetScrollInfo(self.window, SB_VERT, &info, true);
        }
        for c in &self.controls {
            unsafe {
                let _ = ShowWindow(
                    c.hwnd,
                    if c.page == 0 || c.page == self.page {
                        SW_SHOW
                    } else {
                        SW_HIDE
                    },
                );
            }
        }
        if self.page == PAGE_MAIN && !has_editor {
            for id in [
                ID_EDITOR_HEADING,
                ID_DISPLAY_LABEL,
                ID_DISPLAY,
                ID_X_LABEL,
                ID_X,
                ID_Y_LABEL,
                ID_Y,
                ID_WIDTH_LABEL,
                ID_WIDTH,
                ID_HEIGHT_LABEL,
                ID_HEIGHT,
                ID_MAXIMIZED,
                ID_EDIT_KEYWORD_LABEL,
                ID_EDIT_KEYWORD,
                ID_SAVE_PRESET,
                ID_UP,
                ID_DOWN,
                ID_DELETE,
                ID_REBIND,
                ID_REBIND_HINT,
            ] {
                unsafe {
                    let _ = ShowWindow(self.hwnd(id), SW_HIDE);
                }
            }
        }
        if !has_rule_preview {
            unsafe {
                let _ = ShowWindow(self.hwnd(ID_NEW_RULE_PREVIEW), SW_HIDE);
            }
        }
        if !has_explicit_default {
            unsafe {
                let _ = ShowWindow(self.hwnd(ID_CREATE_DEFAULT), SW_HIDE);
            }
        }
        if self.view.startup_warning.is_none() {
            unsafe {
                let _ = ShowWindow(self.hwnd(ID_STARTUP_WARNING), SW_HIDE);
            }
        }
        let third = (width - 2 * gap) / 3;
        self.place(ID_PAGE_MAIN, margin, 12, third, row);
        self.place(ID_PAGE_SETTINGS, margin + third + gap, 12, third, row);
        self.place(
            ID_PAGE_ASSOCIATE,
            margin + 2 * (third + gap),
            12,
            third,
            row,
        );
        let y = row + 24;
        if self.page == PAGE_MAIN {
            self.place(ID_INTRO, margin, y, width, row * 2);
            self.place(ID_PROFILE_LABEL, margin, y + row * 2, 100, row);
            self.place(ID_PROFILE, margin + 110, y + row * 2, width - 110, row * 7);
            self.place(ID_ENV, margin, y + row * 3 + 4, width, row * 2);
            let left = (width - gap) / 2;
            let right = margin + left + gap;
            self.place(ID_WINDOWS_LABEL, margin, y + row * 5, left, row);
            self.place(ID_PRESETS_LABEL, right, y + row * 5, left, row);
            self.place(ID_WINDOWS, margin, y + row * 6, left, row * 4);
            self.place(ID_PRESETS, right, y + row * 6, left, row * 4);
            self.place(ID_REFRESH, margin, y + row * 10 + 6, left, row);
            self.place(ID_MATCH, margin, y + row * 11 + 12, width, row * 2);
            let half = (width - gap) / 2;
            self.place(ID_REMEMBER, margin, y + row * 13 + 8, half, row);
            self.place(ID_RESTORE, margin + half + gap, y + row * 13 + 8, half, row);
            self.place(ID_RULE_LABEL, margin, y + row * 14 + 16, half, row);
            self.place(ID_RULE, margin, y + row * 15 + 16, half, row);
            self.place(
                ID_CREATE_RULE,
                margin + half + gap,
                y + row * 15 + 16,
                half,
                row,
            );
            self.place(
                ID_NEW_RULE_PREVIEW,
                margin,
                y + row * 16 + 24,
                width,
                row * 2,
            );
            self.place(
                ID_CREATE_DEFAULT,
                margin,
                y + row * 16 + 24 + rule_preview_height,
                width,
                row,
            );
            let editor_y = y + preview_height;
            self.place(
                ID_EDITOR_HEADING,
                margin,
                editor_y + row * 16 + 24,
                width,
                row,
            );
            self.place(ID_DISPLAY_LABEL, margin, editor_y + row * 17 + 24, 110, row);
            self.place(
                ID_DISPLAY,
                margin + 120,
                editor_y + row * 17 + 24,
                width - 120,
                row * 7,
            );
            let cell = (width - 3 * gap) / 4;
            for (i, (label, edit)) in [
                (ID_X_LABEL, ID_X),
                (ID_Y_LABEL, ID_Y),
                (ID_WIDTH_LABEL, ID_WIDTH),
                (ID_HEIGHT_LABEL, ID_HEIGHT),
            ]
            .iter()
            .enumerate()
            {
                let x = margin + i as i32 * (cell + gap);
                self.place(*label, x, editor_y + row * 18 + 30, cell, row);
                self.place(*edit, x, editor_y + row * 19 + 30, cell, row);
            }
            self.place(ID_MAXIMIZED, margin, editor_y + row * 20 + 36, width, row);
            self.place(
                ID_EDIT_KEYWORD_LABEL,
                margin,
                editor_y + row * 21 + 40,
                half,
                row,
            );
            self.place(
                ID_EDIT_KEYWORD,
                margin + half + gap,
                editor_y + row * 21 + 40,
                half,
                row,
            );
            let b = (width - 3 * gap) / 4;
            for (i, id) in [ID_SAVE_PRESET, ID_UP, ID_DOWN, ID_DELETE]
                .iter()
                .enumerate()
            {
                self.place(
                    *id,
                    margin + i as i32 * (b + gap),
                    editor_y + row * 22 + 46,
                    b,
                    row,
                );
            }
            self.place(ID_REBIND, margin, editor_y + row * 23 + 54, width, row);
            self.place(
                ID_REBIND_HINT,
                margin,
                editor_y + row * 24 + 62,
                width,
                row * 2,
            );
        } else if self.page == PAGE_SETTINGS {
            self.place(ID_SETTINGS_TITLE, margin, y, width, row * 2);
            self.place(ID_RESTORE_KEY_LABEL, margin, y + row * 2, 180, row);
            self.place(ID_RESTORE_KEY, margin + 190, y + row * 2, width - 190, row);
            self.place(ID_REMEMBER_KEY_LABEL, margin, y + row * 3 + 8, 180, row);
            self.place(
                ID_REMEMBER_KEY,
                margin + 190,
                y + row * 3 + 8,
                width - 190,
                row,
            );
            self.place(ID_KEY_HELP, margin, y + row * 4 + 16, width, row * 2);
            self.place(ID_AUTOSTART, margin, y + row * 6 + 16, width, row);
            self.place(ID_STARTUP_WARNING, margin, y + row * 7 + 24, width, row * 2);
            let settings_y = y + startup_height;
            self.place(
                ID_SAVE_SETTINGS,
                margin,
                settings_y + row * 7 + 24,
                320,
                row,
            );
            self.place(
                ID_KEY_STATUS,
                margin,
                settings_y + row * 8 + 32,
                width,
                row * 3,
            );
            self.place(
                ID_CONFIG_LABEL,
                margin,
                settings_y + row * 11 + 40,
                width,
                row,
            );
            self.place(
                ID_CONFIG_PATH,
                margin,
                settings_y + row * 12 + 40,
                width,
                row,
            );
            self.place(ID_RECOVER, margin, settings_y + row * 13 + 48, 200, row);
            self.place(
                ID_RESET_CONFIG,
                margin + 212,
                settings_y + row * 13 + 48,
                (width - 212).min(320),
                row,
            );
            self.place(
                ID_SETTINGS_HINT,
                margin,
                settings_y + row * 14 + 56,
                width,
                row * 2,
            );
        } else {
            self.place(ID_ASSOC_TITLE, margin, y, width, row * 2);
            self.place(ID_ASSOC_PROFILE_LABEL, margin, y + row * 2, 180, row);
            self.place(
                ID_ASSOC_PROFILE,
                margin + 190,
                y + row * 2,
                width - 190,
                row * 7,
            );
            self.place(ID_IDENTIFY, margin, y + row * 3 + 8, 200, row);
            self.place(ID_ASSOC_OLD_LABEL, margin, y + row * 4 + 16, width, row);
            self.place(ID_ASSOC_OLD, margin, y + row * 5 + 16, width, row * 7);
            self.place(ID_ASSOC_NEW_LABEL, margin, y + row * 6 + 24, width, row);
            self.place(ID_ASSOC_NEW, margin, y + row * 7 + 24, width, row * 7);
            self.place(ID_ASSOC_SET, margin, y + row * 8 + 32, 200, row);
            self.place(ID_ASSOC_PREVIEW, margin, y + row * 9 + 40, width, row * 5);
            self.place(ID_ASSOC_APPLY, margin, y + row * 14 + 48, 280, row);
            self.place(ID_ASSOC_HELP, margin, y + row * 15 + 56, width, row * 2);
            self.place(ID_CREATE_ENVIRONMENT, margin, y + row * 17 + 64, 280, row);
        }
        self.place(ID_UNDO, margin, end, width, row);
        self.place(ID_RESULT_LABEL, margin, end + row + 8, width, row);
        self.place(ID_RESULT, margin, end + row * 2 + 8, width, row * 3);
    }
    fn place(&self, id: i32, x: i32, y: i32, width: i32, height: i32) {
        unsafe {
            let _ = SetWindowPos(
                self.hwnd(id),
                None,
                (x as f64 * self.scale).round() as i32,
                ((y - self.scroll) as f64 * self.scale).round() as i32,
                (width.max(1) as f64 * self.scale).round() as i32,
                (height.max(1) as f64 * self.scale).round() as i32,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }
}

impl Drop for Shell {
    fn drop(&mut self) {
        self.clear_toast();
        self.clear_identifiers();
        for r in &self.registrations {
            unsafe {
                let _ = UnregisterHotKey(Some(self.host), r.id);
            }
        }
        let icon = self.tray_data();
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &icon);
            if self.owned_font {
                let _ = DeleteObject(self.font.into());
            }
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn copy_wide<const N: usize>(dest: &mut [u16; N], value: &str) {
    for (slot, value) in dest
        .iter_mut()
        .take(N.saturating_sub(1))
        .zip(value.encode_utf16())
    {
        *slot = value;
    }
}

fn preview_new_rule(app: Option<&crate::model::AppPresets>, title: &str, keyword: &str) -> String {
    let keyword = keyword.trim();
    if keyword.is_empty() {
        return "输入标题关键字以预览新规则；新规则加入列表末尾。".into();
    }
    let normalized = keyword.to_lowercase();
    if app.is_some_and(|app| {
        app.rules
            .iter()
            .any(|r| r.keyword.to_lowercase() == normalized)
    }) {
        return format!(
            "已存在相同关键字「{keyword}」（忽略大小写），请修改关键字。不会重复创建。"
        );
    }
    let title = title.to_lowercase();
    let existing = app.and_then(|app| {
        app.rules
            .iter()
            .enumerate()
            .find(|(_, r)| title.contains(&r.keyword.to_lowercase()))
    });
    let new_matches = title.contains(&normalized);
    match (existing, new_matches) {
        (Some((index, rule)), true) => format!(
            "存在重叠：当前标题也匹配新关键字「{keyword}」。新规则加入末尾后，仍由第 {} 条「{}」胜出；可保存后调整顺序。",
            index + 1,
            rule.keyword
        ),
        (Some((index, rule)), false) => format!(
            "新关键字不匹配当前窗口。加入末尾后，当前窗口仍由第 {} 条「{}」胜出。",
            index + 1,
            rule.keyword
        ),
        (None, true) => format!("新关键字匹配当前窗口。加入末尾后，新规则「{keyword}」胜出。"),
        (None, false) => format!(
            "新关键字不匹配当前窗口。加入末尾后，当前窗口{}。",
            if app.is_some_and(|a| a.default.is_some()) {
                "继续使用应用默认"
            } else {
                "仍无匹配预设"
            }
        ),
    }
}

pub fn parse_hotkey(value: &str) -> Result<Hotkey, String> {
    let mut modifiers = 0;
    let mut key = None;
    for part in value.split('+').map(|p| p.trim().to_ascii_uppercase()) {
        let flag = match part.as_str() {
            "CTRL" | "CONTROL" => Some(2),
            "ALT" => Some(1),
            "SHIFT" => Some(4),
            "WIN" => Some(8),
            _ => None,
        };
        if let Some(flag) = flag {
            if modifiers & flag != 0 {
                return Err("热键包含重复的修饰键。".into());
            }
            modifiers |= flag;
            continue;
        }
        let code = if part.len() == 1 && part.as_bytes()[0].is_ascii_alphanumeric() {
            Some(part.as_bytes()[0] as u32)
        } else if let Some(number) = part
            .strip_prefix('F')
            .and_then(|n| n.parse::<u32>().ok())
            .filter(|n| (1..=24).contains(n))
        {
            Some(0x6f + number)
        } else {
            match part.as_str() {
                "SPACE" => Some(0x20),
                "TAB" => Some(9),
                "ENTER" => Some(13),
                "ESC" | "ESCAPE" => Some(27),
                _ => None,
            }
        };
        if code.is_none() || key.is_some() {
            return Err("热键格式无效，例如 Ctrl+Alt+F9 或 Win+Shift+P。".into());
        }
        key = code;
    }
    let hotkey = Hotkey {
        modifiers,
        key: key.ok_or("热键需要一个普通按键。")?,
    };
    hotkey.validate()?;
    Ok(hotkey)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn test_shell(host: HWND, window: HWND, settings: Settings) -> (Shell, Receiver<Request>) {
        let (requests, received) = mpsc::sync_channel(1);
        let (_, replies) = mpsc::channel();
        let view = View {
            config: crate::model::Config::default(),
            windows: vec![],
            monitors: vec![],
            active_profile: None,
            bindings: vec![],
            needs_association: false,
            read_only: false,
            config_path: String::new(),
            undo_label: None,
            startup_warning: None,
        };
        (
            Shell {
                host,
                window,
                controls: vec![],
                view,
                selected_profile: None,
                rows: vec![],
                editor: None,
                original_percent: Default::default(),
                display_choices: vec![],
                requests,
                replies,
                busy: false,
                exiting: false,
                worker_failed: false,
                registrations: vec![],
                next_hotkey_id: 1,
                active_settings: settings,
                pending_settings: None,
                pending_restart: false,
                hotkeys_suspended: false,
                last_result: String::new(),
                last_toast: String::new(),
                last_toast_at: None,
                taskbar_created: 0,
                page: 1,
                scroll: 0,
                content_height: 0,
                scale: 1.0,
                row: 30,
                font: HFONT::default(),
                owned_font: false,
                association: HashMap::new(),
                association_profile: None,
                identifiers: vec![],
                toast_window: None,
                tray_ready: false,
            },
            received,
        )
    }
    #[test]
    fn hotkey_parser_accepts_documented_forms() {
        assert_eq!(
            parse_hotkey(" ctrl + ALT + f9 ").unwrap(),
            Hotkey {
                modifiers: 3,
                key: 0x78
            }
        );
        assert_eq!(
            parse_hotkey("Win+Shift+P").unwrap(),
            Hotkey {
                modifiers: 12,
                key: 0x50
            }
        );
        assert_eq!(parse_hotkey("Ctrl+F24").unwrap().key, 0x87);
    }
    #[test]
    fn invalid_hotkeys_are_rejected() {
        for value in [
            "F9",
            "Ctrl+Ctrl+P",
            "Ctrl+A+B",
            "Ctrl+F25",
            "Ctrl+",
            "Ctrl+Alt",
            "Ctrl+☃",
        ] {
            assert!(parse_hotkey(value).is_err(), "{value}");
        }
    }

    #[test]
    fn keyword_preview_reports_append_priority_and_case_insensitive_duplicates() {
        use crate::model::{AppPresets, Placement, RelativeRect, WindowRule};
        let preset = Preset {
            id: "preview".into(),
            revision: 0,
            placement: Placement {
                display_id: "display".into(),
                rect: RelativeRect {
                    x: 0.0,
                    y: 0.0,
                    width: 0.5,
                    height: 1.0,
                },
                maximized: false,
            },
        };
        let app = AppPresets {
            app_id: "app".into(),
            app_name: "editor".into(),
            default: Some(preset.clone()),
            rules: vec![
                WindowRule {
                    keyword: "screen".into(),
                    preset: preset.clone(),
                },
                WindowRule {
                    keyword: "screen-pin".into(),
                    preset,
                },
            ],
        };
        let overlapping = preview_new_rule(Some(&app), "SCREEN-PIN — editor", "PIN");
        assert!(overlapping.contains("存在重叠"));
        assert!(overlapping.contains("第 1 条「screen」胜出"));
        assert!(preview_new_rule(Some(&app), "screen-pin", "ScReEn").contains("已存在相同关键字"));
        assert!(preview_new_rule(Some(&app), "document", "other").contains("继续使用应用默认"));
        assert!(preview_new_rule(None, "EDITOR", "editor").contains("新规则「editor」胜出"));
        assert!(preview_new_rule(None, "editor", "other").contains("仍无匹配预设"));
    }

    #[test]
    fn native_hotkey_transaction_preserves_old_bindings_on_conflict_and_save_failure() {
        unsafe {
            let host = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("STATIC"),
                w!("Screen Pin hotkey test"),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                None,
                None,
            )
            .unwrap();
            let blocker = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("STATIC"),
                w!("Screen Pin conflict test"),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                None,
                None,
            )
            .unwrap();
            let keys: Vec<_> = (0x7c..=0x87)
                .filter_map(|key| {
                    let hotkey = Hotkey { modifiers: 7, key };
                    if RegisterHotKey(Some(blocker), 900, HOT_KEY_MODIFIERS(7) | MOD_NOREPEAT, key)
                        .is_ok()
                    {
                        let _ = UnregisterHotKey(Some(blocker), 900);
                        Some(hotkey)
                    } else {
                        None
                    }
                })
                .take(3)
                .collect();
            assert_eq!(keys.len(), 3, "need three free test combinations");
            let settings = Settings {
                restore: keys[0],
                remember: keys[1],
                autostart: false,
            };
            let (mut shell, received) = test_shell(host, host, settings.clone());
            shell.register_initial();
            assert_eq!(shell.registrations.len(), 2);
            RegisterHotKey(
                Some(blocker),
                901,
                HOT_KEY_MODIFIERS(7) | MOD_NOREPEAT,
                keys[2].key,
            )
            .unwrap();
            let candidate = Settings {
                restore: keys[2],
                ..settings.clone()
            };
            assert!(shell.prepare_settings(candidate.clone()).is_err());
            assert_eq!(shell.registrations.len(), 2);
            assert_eq!(shell.active_settings, settings);
            assert!(
                RegisterHotKey(
                    Some(blocker),
                    902,
                    HOT_KEY_MODIFIERS(7) | MOD_NOREPEAT,
                    settings.restore.key
                )
                .is_err()
            );
            UnregisterHotKey(Some(blocker), 901).unwrap();
            shell.prepare_settings(candidate.clone()).unwrap();
            assert!(matches!(
                received.recv().unwrap(),
                Request::UpdateSettings(_)
            ));
            assert_eq!(shell.registrations.len(), 3);
            assert_eq!(shell.active_settings, settings);
            shell.finish_settings(false, &settings);
            shell.busy = false;
            assert_eq!(shell.registrations.len(), 2);
            assert_eq!(shell.active_settings, settings);
            RegisterHotKey(
                Some(blocker),
                903,
                HOT_KEY_MODIFIERS(7) | MOD_NOREPEAT,
                keys[2].key,
            )
            .unwrap();
            UnregisterHotKey(Some(blocker), 903).unwrap();
            let swapped = Settings {
                restore: settings.remember,
                remember: settings.restore,
                autostart: false,
            };
            shell.prepare_settings(swapped.clone()).unwrap();
            let _ = received.recv().unwrap();
            assert_eq!(shell.registrations.len(), 2);
            shell.finish_settings(true, &swapped);
            shell.busy = false;
            assert_eq!(shell.active_settings, swapped);
            shell.prepare_settings(candidate.clone()).unwrap();
            let _ = received.recv().unwrap();
            shell.finish_settings(true, &candidate);
            assert_eq!(shell.active_settings, candidate);
            assert_eq!(shell.registrations.len(), 2);
            RegisterHotKey(
                Some(blocker),
                904,
                HOT_KEY_MODIFIERS(7) | MOD_NOREPEAT,
                settings.restore.key,
            )
            .unwrap();
            UnregisterHotKey(Some(blocker), 904).unwrap();
            drop(shell);
            let _ = DestroyWindow(host);
            let _ = DestroyWindow(blocker);
        }
    }

    #[test]
    fn explorer_broadcast_recreates_own_tray_once_for_both_window_delivery_orders() {
        unsafe {
            let instance = GetModuleHandleW(None).unwrap();
            let class = w!("ScreenPin.TrayRebuildRegression");
            let window_class = WNDCLASSW {
                lpfnWndProc: Some(window_proc),
                hInstance: instance.into(),
                lpszClassName: class,
                ..Default::default()
            };
            assert_ne!(RegisterClassW(&window_class), 0);
            let create = || {
                CreateWindowExW(
                    WS_EX_NOACTIVATE,
                    class,
                    w!("Screen Pin isolated tray rebuild test"),
                    WINDOW_STYLE::default(),
                    0,
                    0,
                    0,
                    0,
                    Some(HWND_MESSAGE),
                    None,
                    Some(instance.into()),
                    None,
                )
                .unwrap()
            };
            let host = create();
            let settings = create();
            let (mut shell, _received) = test_shell(host, settings, Settings::default());
            shell.taskbar_created = RegisterWindowMessageW(w!("TaskbarCreated"));
            assert_ne!(shell.taskbar_created, 0);
            let message = shell.taskbar_created;
            shell.tray_add().unwrap();
            let icon = shell.tray_data();
            SHELL.with(|state| {
                assert!(state.borrow().is_none());
                *state.borrow_mut() = Some(shell);
            });
            for order in [[settings, host], [host, settings]] {
                assert!(
                    Shell_NotifyIconW(NIM_DELETE, &icon).as_bool(),
                    "remove only this test's icon to simulate Explorer losing it"
                );
                SHELL.with(|state| state.borrow_mut().as_mut().unwrap().tray_ready = false);
                for hwnd in order {
                    SendMessageW(hwnd, message, Some(WPARAM(0)), Some(LPARAM(0)));
                }
                SHELL.with(|state| {
                    let state = state.borrow();
                    let shell = state.as_ref().unwrap();
                    assert!(
                        shell.tray_ready,
                        "the Settings delivery must not turn a successful recreation into failure"
                    );
                    assert!(
                        shell.last_result.is_empty(),
                        "no false tray failure should be reported"
                    );
                });
                assert!(
                    Shell_NotifyIconW(NIM_MODIFY, &icon).as_bool(),
                    "the recreated icon must actually exist"
                );
            }
            SHELL.with(|state| {
                drop(state.borrow_mut().take());
            });
            assert!(
                !Shell_NotifyIconW(NIM_MODIFY, &icon).as_bool(),
                "drop removes the test's own icon"
            );
            let _ = DestroyWindow(settings);
            let _ = DestroyWindow(host);
            let _ = UnregisterClassW(class, Some(instance.into()));
        }
    }
}
