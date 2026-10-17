//! Windows desktop boundary. All coordinates exposed here are physical screen pixels.
//! External-window mutations are asynchronous; a timed-out request may still execute later.

use crate::model::{
    MonitorSnapshot, Placement, Rect, RestoreOutcome, WindowSnapshot, WindowSummary,
};
use std::{
    collections::{HashMap, HashSet},
    mem::size_of,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Devices::Display::*,
        Foundation::{
            CloseHandle, ERROR_INSUFFICIENT_BUFFER, FILETIME, HANDLE, HWND, LPARAM, RECT, WPARAM,
        },
        Graphics::{Dwm::*, Gdi::*},
        Storage::Packaging::Appx::{GetApplicationUserModelId, GetPackageFamilyName},
        System::{Registry::*, Threading::*},
        UI::{HiDpi::*, WindowsAndMessaging::*},
    },
    core::{PCWSTR, PWSTR},
};

type Result<T> = std::result::Result<T, String>;

struct WindowTokens {
    name: Vec<u16>,
    issued: Mutex<HashMap<isize, u64>>,
    next: AtomicU64,
}

fn token_registry() -> &'static WindowTokens {
    static REGISTRY: OnceLock<WindowTokens> = OnceLock::new();
    REGISTRY.get_or_init(|| WindowTokens {
        // The fixed namespace identifies our property; the process-session ID
        // prevents collisions with another Screen Pin process or a reused PID.
        name: wide(&format!(
            "ScreenPin.{{C5F89F7D-5953-4EA6-AF10-240546D82633}}.{}",
            crate::model::next_id()
        )),
        issued: Mutex::new(HashMap::new()),
        next: AtomicU64::new(1),
    })
}

fn property_token(handle: isize) -> u64 {
    let registry = token_registry();
    unsafe { GetPropW(HWND(handle as _), PCWSTR(registry.name.as_ptr())).0 as usize as u64 }
}

/// Pins one window generation using our own named Win32 property. This never
/// replaces application window data or changes any window style.
pub fn window_token(handle: isize) -> Result<u64> {
    let pid = eligible(HWND(handle as _))?;
    let registry = token_registry();
    let mut issued = registry
        .issued
        .lock()
        .map_err(|_| "窗口身份注册表暂不可用。".to_string())?;
    let existing = property_token(handle);
    if existing != 0 {
        if issued.get(&handle) == Some(&existing) {
            validate_target(handle, pid)?;
            return Ok(existing);
        }
        return Err("窗口身份标记冲突，请重新启动 Screen Pin 后重试。".into());
    }
    let token = registry.next.fetch_add(1, Ordering::Relaxed);
    if token == 0 || token > usize::MAX as u64 {
        return Err("窗口身份序列已耗尽，请重新启动。".into());
    }
    unsafe {
        SetPropW(
            HWND(handle as _),
            PCWSTR(registry.name.as_ptr()),
            Some(HANDLE(token as usize as _)),
        )
    }
    .map_err(|error| {
        if error.code().0 as u32 == 0x80070005 {
            "无法建立窗口身份标记：目标权限较高。请从托盘以管理员身份重新启动后重试。".to_string()
        } else {
            format!("无法建立窗口身份标记（{}），此次操作已取消。", error.code())
        }
    })?;
    issued.insert(handle, token);
    if validate_target(handle, pid).is_err() || property_token(handle) != token {
        if property_token(handle) == token {
            unsafe {
                let _ = RemovePropW(HWND(handle as _), PCWSTR(registry.name.as_ptr()));
            }
        }
        issued.remove(&handle);
        return Err("窗口在建立身份标记时已变化，请重新选择。".into());
    }
    Ok(token)
}

/// Validates a previously issued generation. Missing markers are never minted
/// here: queued commands must not silently adopt a newly reused HWND.
pub fn validate_window_token(handle: isize, pid: u32, token: u64) -> Result<()> {
    validate_target(handle, pid)?;
    if token == 0 || property_token(handle) != token {
        return Err("目标窗口已关闭、重建或身份标记已失效，请重新选择或触发热键。".into());
    }
    Ok(())
}

/// Removes only markers this process issued and whose current value still
/// matches. Marker values are integers, not allocated handles to close/free.
pub fn cleanup_window_tokens() {
    let registry = token_registry();
    let Ok(mut issued) = registry.issued.lock() else {
        return;
    };
    issued.retain(|handle, token| {
        if property_token(*handle) != *token {
            return false;
        }
        unsafe { RemovePropW(HWND(*handle as _), PCWSTR(registry.name.as_ptr())) }.is_err()
    });
}

struct DpiScope(DPI_AWARENESS_CONTEXT);
impl DpiScope {
    fn enter() -> Self {
        Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}
impl Drop for DpiScope {
    fn drop(&mut self) {
        if !self.0.0.is_null() {
            unsafe {
                SetThreadDpiAwarenessContext(self.0);
            }
        }
    }
}

struct Process(HANDLE);
impl Drop for Process {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

fn text16(text: &[u16]) -> String {
    String::from_utf16_lossy(&text[..text.iter().position(|v| *v == 0).unwrap_or(text.len())])
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn native(rect: Rect) -> RECT {
    RECT {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
    }
}
fn rect(rect: RECT) -> Rect {
    Rect {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
    }
}
fn positive(r: Rect) -> bool {
    r.right > r.left && r.bottom > r.top
}
fn shift(r: Rect, x: i32, y: i32) -> Rect {
    Rect {
        left: r.left + x,
        right: r.right + x,
        top: r.top + y,
        bottom: r.bottom + y,
    }
}
fn near(a: Rect, b: Rect, tolerance: i32) -> bool {
    [
        a.left as i64 - b.left as i64,
        a.top as i64 - b.top as i64,
        a.right as i64 - b.right as i64,
        a.bottom as i64 - b.bottom as i64,
    ]
    .iter()
    .all(|v| v.abs() <= tolerance as i64)
}
fn overlap(a: Rect, b: Rect) -> i64 {
    (a.right.min(b.right) as i64 - a.left.max(b.left) as i64).max(0)
        * (a.bottom.min(b.bottom) as i64 - a.top.max(b.top) as i64).max(0)
}

#[derive(Clone)]
struct GdiMonitor {
    device: String,
    bounds: Rect,
    work: Rect,
}

unsafe extern "system" fn enum_monitor(
    h: HMONITOR,
    _: HDC,
    _: *mut RECT,
    data: LPARAM,
) -> windows::core::BOOL {
    let result = unsafe { &mut *(data.0 as *mut Vec<GdiMonitor>) };
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    if unsafe { GetMonitorInfoW(h, &mut info.monitorInfo) }.as_bool() {
        result.push(GdiMonitor {
            device: text16(&info.szDevice).to_lowercase(),
            bounds: rect(info.monitorInfo.rcMonitor),
            work: rect(info.monitorInfo.rcWork),
        });
    }
    true.into()
}

/// Enumerates active physical targets. Mirrored targets are rejected rather than
/// assigning several physical screens to one desktop work area.
pub fn monitors() -> Result<Vec<MonitorSnapshot>> {
    let _dpi = DpiScope::enter();
    let mut gdi = Vec::<GdiMonitor>::new();
    if !unsafe {
        EnumDisplayMonitors(
            None,
            None,
            Some(enum_monitor),
            LPARAM(&mut gdi as *mut _ as isize),
        )
    }
    .as_bool()
    {
        return Err("无法枚举显示器，请稍后重试。".into());
    }
    if gdi.is_empty() {
        return Err("当前没有可用的本地显示器。".into());
    }
    let mut paths = Vec::new();
    // Buffer sizes can change during hotplug. Bounded retries never publish a partial topology.
    for _ in 0..4 {
        let (mut path_count, mut mode_count) = (0, 0);
        let status = unsafe {
            GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
        };
        if status.0 != 0 {
            return Err(format!(
                "读取显示拓扑失败（{}）；请确认是本地桌面会话。",
                status.0
            ));
        }
        if path_count > 256 || mode_count > 1024 {
            return Err("显示拓扑规模异常。".into());
        }
        let mut current = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
        let status = unsafe {
            QueryDisplayConfig(
                QDC_ONLY_ACTIVE_PATHS,
                &mut path_count,
                current.as_mut_ptr(),
                &mut mode_count,
                modes.as_mut_ptr(),
                None,
            )
        };
        if status == ERROR_INSUFFICIENT_BUFFER {
            continue;
        }
        if status.0 != 0 {
            return Err(format!("读取显示拓扑失败（{}）。", status.0));
        }
        current.truncate(path_count as usize);
        paths = current;
        break;
    }
    if paths.is_empty() {
        return Err("显示器正在变化，请稍后重试。".into());
    }
    let mut seen_sources = HashSet::new();
    let mut seen_paths = HashSet::new();
    let mut result = Vec::new();
    for path in paths {
        let mut source = DISPLAYCONFIG_SOURCE_DEVICE_NAME {
            header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
                size: size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32,
                adapterId: path.sourceInfo.adapterId,
                id: path.sourceInfo.id,
            },
            ..Default::default()
        };
        let mut target = DISPLAYCONFIG_TARGET_DEVICE_NAME {
            header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
                size: size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32,
                adapterId: path.targetInfo.adapterId,
                id: path.targetInfo.id,
            },
            ..Default::default()
        };
        if unsafe { DisplayConfigGetDeviceInfo(&mut source.header) } != 0
            || unsafe { DisplayConfigGetDeviceInfo(&mut target.header) } != 0
        {
            return Err("显示器身份尚未准备好，请稍后重试。".into());
        }
        let source_name = text16(&source.viewGdiDeviceName).to_lowercase();
        if !seen_sources.insert(source_name.clone()) {
            return Err("当前为镜像显示，首版仅支持独立扩展的本地显示器。".into());
        }
        let monitor = gdi
            .iter()
            .find(|m| m.device == source_name)
            .ok_or_else(|| "显示器正在变化，请稍后重试。".to_string())?;
        let device_path = text16(&target.monitorDevicePath).to_lowercase();
        if device_path.is_empty() || !seen_paths.insert(device_path.clone()) {
            return Err("无法明确识别物理显示器，请重新连接后重试。".into());
        }
        let mut fingerprints = vec![
            format!("path:{device_path}"),
            format!(
                "model:{:04x}:{:04x}",
                target.edidManufactureId, target.edidProductCodeId
            ),
        ];
        if let Some(edid) = monitor_edid(&device_path) {
            fingerprints.extend(edid_serials(&edid));
        }
        let name = text16(&target.monitorFriendlyDeviceName);
        result.push(MonitorSnapshot {
            key: format!("path:{device_path}"),
            name: if name.is_empty() {
                "显示器".into()
            } else {
                name
            },
            rect: monitor.bounds,
            work: monitor.work,
            fingerprints,
        });
    }
    if result.len() != gdi.len() {
        return Err("显示器正在变化，请稍后重试。".into());
    }
    // Stable ordering for UI only; physical identity never uses an enumeration index.
    result.sort_by_key(|m| (m.rect.left, m.rect.top, m.key.clone()));
    Ok(result)
}

fn monitor_edid(device_path: &str) -> Option<Vec<u8>> {
    let parts: Vec<_> = device_path.split('#').collect();
    if parts.len() < 3 || !parts[0].ends_with("display") {
        return None;
    }
    let location = wide(&format!(
        "SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\{}\\{}\\Device Parameters",
        parts[1], parts[2]
    ));
    let mut key = HKEY::default();
    if unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(location.as_ptr()),
            None,
            KEY_READ,
            &mut key,
        )
    }
    .0 != 0
    {
        return None;
    }
    let mut bytes = vec![0u8; 4096];
    let mut len = bytes.len() as u32;
    let mut kind = REG_VALUE_TYPE::default();
    let value = wide("EDID");
    let status = unsafe {
        RegQueryValueExW(
            key,
            PCWSTR(value.as_ptr()),
            None,
            Some(&mut kind),
            Some(bytes.as_mut_ptr()),
            Some(&mut len),
        )
    };
    unsafe {
        let _ = RegCloseKey(key);
    }
    if status.0 != 0 || kind != REG_BINARY || len < 128 {
        return None;
    }
    bytes.truncate(len as usize);
    if !valid_edid(&bytes) {
        return None;
    }
    Some(bytes)
}

fn valid_edid(edid: &[u8]) -> bool {
    edid.len() >= 128
        && edid[..8] == [0, 255, 255, 255, 255, 255, 255, 0]
        && edid[..128].iter().fold(0u8, |sum, b| sum.wrapping_add(*b)) == 0
}

fn edid_serials(edid: &[u8]) -> Vec<String> {
    if !valid_edid(edid) {
        return Vec::new();
    }
    let manufacturer = u16::from_be_bytes([edid[8], edid[9]]);
    let product = u16::from_le_bytes([edid[10], edid[11]]);
    let serial = u32::from_le_bytes([edid[12], edid[13], edid[14], edid[15]]);
    let mut result = Vec::new();
    if serial != 0 && serial != u32::MAX {
        result.push(format!(
            "serial:{manufacturer:04x}:{product:04x}:number:{serial:08x}"
        ));
    }
    for descriptor in edid[54..126].chunks_exact(18) {
        if descriptor[..5] == [0, 0, 0, 255, 0] {
            if !descriptor[5..]
                .iter()
                .all(|b| matches!(b, 0 | 10 | 13 | 32..=126))
            {
                continue;
            }
            let text = String::from_utf8_lossy(&descriptor[5..])
                .trim_matches(|c: char| c.is_whitespace() || c == '\0')
                .to_lowercase();
            if !text.is_empty() && text.chars().any(|c| c != '0' && c != ' ') {
                result.push(format!(
                    "serial:{manufacturer:04x}:{product:04x}:text:{text}"
                ));
            }
        }
    }
    result
}

pub fn foreground() -> isize {
    unsafe { GetForegroundWindow().0 as isize }
}

fn title(hwnd: HWND) -> String {
    // For external processes GetWindowText uses cached caption text and does not
    // synchronously send WM_GETTEXT to an unresponsive target.
    let mut buffer = vec![0u16; 32768];
    let count = unsafe { GetWindowTextW(hwnd, &mut buffer) }.max(0) as usize;
    String::from_utf16_lossy(&buffer[..count])
}

fn eligible(hwnd: HWND) -> Result<u32> {
    if hwnd.0.is_null() || !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
        return Err("目标窗口已关闭，请重新选择。".into());
    }
    let mut pid = 0;
    unsafe {
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
    }
    if pid == 0 || pid == unsafe { GetCurrentProcessId() } {
        return Err("请选择其他应用的窗口。".into());
    }
    if !unsafe { IsWindowVisible(hwnd) }.as_bool() || unsafe { GetAncestor(hwnd, GA_ROOT) } != hwnd
    {
        return Err("只支持可见的独立应用主窗口。".into());
    }
    let ex = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) } as u32;
    let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32;
    let mut class = [0u16; 256];
    unsafe {
        GetClassNameW(hwnd, &mut class);
    }
    let class = text16(&class).to_lowercase();
    if [
        "#32770",
        "#32768",
        "tooltips_class32",
        "sysshadow",
        "progman",
        "workerw",
        "shell_traywnd",
        "shell_secondarytraywnd",
        "multitaskingviewframe",
        "xamlexplorerhostislandwindow",
    ]
    .contains(&class.as_str())
        || ex & (WS_EX_TOOLWINDOW.0 | WS_EX_NOACTIVATE.0 | WS_EX_DLGMODALFRAME.0) != 0
        || style & (WS_CHILD.0 | WS_DISABLED.0) != 0
    {
        return Err("临时对话框、菜单和系统窗口不能保存布局，请切换到应用主窗口。".into());
    }
    if unsafe { GetWindow(hwnd, GW_OWNER) }.is_ok_and(|owner| !owner.0.is_null())
        && ex & WS_EX_APPWINDOW.0 == 0
    {
        return Err("此窗口依附于其他窗口，请选择应用主窗口。".into());
    }
    let mut cloaked = 0u32;
    if unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED,
            &mut cloaked as *mut _ as _,
            size_of::<u32>() as u32,
        )
    }
    .is_ok()
        && cloaked != 0
    {
        return Err("窗口当前不在可见桌面上。".into());
    }
    Ok(pid)
}

pub fn validate_target(handle: isize, pid: u32) -> Result<()> {
    if eligible(HWND(handle as _))? != pid {
        return Err("目标窗口身份已变化，请重新选择。".into());
    }
    Ok(())
}

fn process_identity(pid: u32) -> Result<(u64, String, String)> {
    let process = Process(
        unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.map_err(|e| {
            format!(
                "无法读取应用身份（{}）。管理员窗口可尝试从托盘以管理员身份重启。",
                e.code()
            )
        })?,
    );
    let mut created = FILETIME::default();
    let (mut exited, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) }
        .map_err(|e| format!("无法读取进程创建时间：{e}"))?;
    let started = (created.dwHighDateTime as u64) << 32 | created.dwLowDateTime as u64;
    let mut path = vec![0u16; 32768];
    let mut len = path.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(
            process.0,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &mut len,
        )
    }
    .map_err(|e| format!("无法读取应用路径：{e}"))?;
    let path = String::from_utf16_lossy(&path[..len as usize]);
    let app_name = path.rsplit(['\\', '/']).next().unwrap_or(&path).to_string();
    let mut aumid_len = 0;
    if unsafe { GetApplicationUserModelId(process.0, &mut aumid_len, None) }
        == ERROR_INSUFFICIENT_BUFFER
        && aumid_len > 0
        && aumid_len <= 32768
    {
        let mut aumid = vec![0u16; aumid_len as usize];
        if unsafe {
            GetApplicationUserModelId(process.0, &mut aumid_len, Some(PWSTR(aumid.as_mut_ptr())))
        }
        .0 == 0
        {
            let aumid = text16(&aumid);
            let mut family_len = 0;
            if unsafe { GetPackageFamilyName(process.0, &mut family_len, None) }
                == ERROR_INSUFFICIENT_BUFFER
                && family_len > 0
                && family_len <= 32768
            {
                let mut family = vec![0u16; family_len as usize];
                if unsafe {
                    GetPackageFamilyName(
                        process.0,
                        &mut family_len,
                        Some(PWSTR(family.as_mut_ptr())),
                    )
                }
                .0 == 0
                {
                    let family = text16(&family);
                    // Process identity APIs establish both package and manifest app,
                    // unlike an arbitrary per-window shell property.
                    if aumid.starts_with(&format!("{family}!")) && aumid.len() > family.len() + 1 {
                        return Ok((
                            started,
                            format!("package:{}", aumid.to_lowercase()),
                            app_name,
                        ));
                    }
                }
            }
        }
    }
    if [
        "applicationframehost.exe",
        "wwahost.exe",
        "conhost.exe",
        "dllhost.exe",
        "rundll32.exe",
    ]
    .contains(&app_name.to_lowercase().as_str())
    {
        return Err("无法可靠确定此宿主窗口所属应用，已跳过以免覆盖其他应用布局。".into());
    }
    Ok((
        started,
        format!(
            "exe:{}",
            path.trim_start_matches(r"\\?\")
                .replace('/', "\\")
                .to_lowercase()
        ),
        app_name,
    ))
}

unsafe extern "system" fn enum_window(hwnd: HWND, data: LPARAM) -> windows::core::BOOL {
    let result = unsafe { &mut *(data.0 as *mut Vec<WindowSummary>) };
    if let Ok(pid) = eligible(hwnd) {
        let title = title(hwnd);
        if !title.trim().is_empty()
            && let Ok((_, app_id, app_name)) = process_identity(pid)
        {
            let title = if unsafe { IsIconic(hwnd) }.as_bool() {
                format!("[已最小化，请先还原] {title}")
            } else {
                title
            };
            let Ok(token) = window_token(hwnd.0 as isize) else {
                return true.into();
            };
            if validate_window_token(hwnd.0 as isize, pid, token).is_err() {
                return true.into();
            }
            result.push(WindowSummary {
                handle: hwnd.0 as isize,
                pid,
                token,
                title,
                app_name,
                app_id,
            });
        }
    }
    true.into()
}

pub fn windows() -> Result<Vec<WindowSummary>> {
    let _dpi = DpiScope::enter();
    let mut result = Vec::<WindowSummary>::new();
    unsafe { EnumWindows(Some(enum_window), LPARAM(&mut result as *mut _ as isize)) }
        .map_err(|e| format!("无法读取窗口列表：{e}"))?;
    result.sort_by_key(|w| (w.app_name.to_lowercase(), w.title.to_lowercase()));
    Ok(result)
}

fn outer(hwnd: HWND) -> Result<Rect> {
    let mut value = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut value) }.map_err(|e| format!("无法读取窗口位置：{e}"))?;
    let value = rect(value);
    if !positive(value) {
        return Err("窗口位置无效。".into());
    }
    Ok(value)
}
fn visible(hwnd: HWND) -> Result<Rect> {
    let mut value = RECT::default();
    unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut value as *mut _ as _,
            size_of::<RECT>() as u32,
        )
    }
    .map_err(|e| format!("无法读取可见窗口边界：{e}"))?;
    let value = rect(value);
    if !positive(value) {
        return Err("窗口可见边界无效。".into());
    }
    Ok(value)
}
fn window_placement(hwnd: HWND) -> Result<WINDOWPLACEMENT> {
    let mut value = WINDOWPLACEMENT {
        length: size_of::<WINDOWPLACEMENT>() as u32,
        ..Default::default()
    };
    unsafe { GetWindowPlacement(hwnd, &mut value) }
        .map_err(|e| format!("无法读取窗口还原位置：{e}"))?;
    Ok(value)
}

/// Invisible border insets (left, top, right, bottom). For normal windows we
/// measure the real DWM frame. A maximized window's normal frame is estimated
/// without restoring it; the subsequent restore verifies and corrects real bounds.
fn insets(hwnd: HWND) -> Result<[i32; 4]> {
    if !unsafe { IsZoomed(hwnd) }.as_bool() && !unsafe { IsIconic(hwnd) }.as_bool() {
        let a = outer(hwnd)?;
        let b = visible(hwnd)?;
        return Ok([
            b.left - a.left,
            b.top - a.top,
            a.right - b.right,
            a.bottom - b.bottom,
        ]);
    }
    let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32;
    if style & WS_THICKFRAME.0 == 0 {
        return Ok([0, 0, 0, 0]);
    }
    let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96);
    let size = unsafe {
        GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
    };
    // Standard visible normal-frame thickness is one physical pixel on Win11;
    // custom-drawn frames may differ and are therefore verified after placement.
    let invisible = (size - (dpi as i32 / 96).max(1)).max(0);
    Ok([invisible, 0, invisible, invisible])
}
fn outer_to_visible(r: Rect, i: [i32; 4]) -> Rect {
    Rect {
        left: r.left + i[0],
        top: r.top + i[1],
        right: r.right - i[2],
        bottom: r.bottom - i[3],
    }
}
fn visible_to_outer(r: Rect, i: [i32; 4]) -> Rect {
    Rect {
        left: r.left - i[0],
        top: r.top - i[1],
        right: r.right + i[2],
        bottom: r.bottom + i[3],
    }
}
fn workspace_to_screen(r: Rect, monitor: &MonitorSnapshot) -> Rect {
    shift(
        r,
        monitor.work.left - monitor.rect.left,
        monitor.work.top - monitor.rect.top,
    )
}
fn screen_to_workspace(r: Rect, monitor: &MonitorSnapshot) -> Rect {
    shift(
        r,
        monitor.rect.left - monitor.work.left,
        monitor.rect.top - monitor.work.top,
    )
}

pub fn capture(handle: isize) -> Result<WindowSnapshot> {
    let _dpi = DpiScope::enter();
    let hwnd = HWND(handle as _);
    let pid = eligible(hwnd)?;
    let token = window_token(handle)?;
    validate_window_token(handle, pid, token)?;
    if unsafe { IsIconic(hwnd) }.as_bool() {
        return Err("窗口已最小化，请先还原后再记住位置。".into());
    }
    let (process_started, app_id, app_name) = process_identity(pid)?;
    let title = title(hwnd);
    if title.trim().is_empty() {
        return Err("此窗口没有可辨认的标题，请选择应用主窗口。".into());
    }
    let screens = monitors()?;
    let frame = visible(hwnd)?;
    let monitor = screens
        .iter()
        .max_by_key(|m| overlap(frame, m.rect))
        .filter(|m| overlap(frame, m.rect) > 0)
        .ok_or_else(|| "窗口完全离屏，请先移回可见区域。".to_string())?;
    let maximized = unsafe { IsZoomed(hwnd) }.as_bool();
    // Maximize comes first: an auto-hidden taskbar can make a normal maximized
    // window exactly cover the monitor and must not classify it as fullscreen.
    if !maximized
        && frame.left <= monitor.rect.left + 2
        && frame.top <= monitor.rect.top + 2
        && frame.right >= monitor.rect.right - 2
        && frame.bottom >= monitor.rect.bottom - 2
    {
        return Err("此窗口疑似全屏，请退出全屏后再操作。".into());
    }
    let normal_rect = if maximized {
        outer_to_visible(
            workspace_to_screen(rect(window_placement(hwnd)?.rcNormalPosition), monitor),
            insets(hwnd)?,
        )
    } else {
        frame
    };
    if !positive(normal_rect) {
        return Err("无法可靠读取窗口的正常还原尺寸。".into());
    }
    validate_window_token(handle, pid, token)?;
    let (now_started, now_app, _) = process_identity(pid)?;
    if now_started != process_started || now_app != app_id || title != self::title(hwnd) {
        return Err("窗口在采样期间发生变化，请重新操作。".into());
    }
    validate_window_token(handle, pid, token)?;
    Ok(WindowSnapshot {
        handle,
        pid,
        token,
        process_started,
        app_id,
        app_name,
        title,
        display_key: monitor.key.clone(),
        normal_rect,
        maximized,
    })
}

fn verify_identity(snapshot: &WindowSnapshot) -> Result<()> {
    validate_window_token(snapshot.handle, snapshot.pid, snapshot.token)?;
    let (started, app, _) = process_identity(snapshot.pid)?;
    if started != snapshot.process_started
        || app != snapshot.app_id
        || title(HWND(snapshot.handle as _)) != snapshot.title
    {
        return Err("目标窗口或标题已变化，请重新触发操作。".into());
    }
    Ok(())
}

fn intended_rect(
    p: &Placement,
    m: &MonitorSnapshot,
    screens: &[MonitorSnapshot],
) -> Result<(Rect, bool)> {
    let r = &p.rect;
    if ![r.x, r.y, r.width, r.height].iter().all(|v| v.is_finite())
        || r.width <= 0.0
        || r.height <= 0.0
    {
        return Err("预设位置或尺寸无效，请编辑预设。".into());
    }
    let w = (m.work.right - m.work.left) as f64;
    let h = (m.work.bottom - m.work.top) as f64;
    let values = [
        m.work.left as f64 + r.x * w,
        m.work.top as f64 + r.y * h,
        r.width * w,
        r.height * h,
    ];
    if !values
        .iter()
        .all(|v| v.is_finite() && v.abs() < 1_000_000.0)
    {
        return Err("预设超出支持的位置范围。".into());
    }
    let (left, top, width, height) = (
        values[0].round() as i32,
        values[1].round() as i32,
        (values[2].round() as i32).max(1),
        (values[3].round() as i32).max(1),
    );
    let r = Rect {
        left,
        top,
        right: left + width,
        bottom: top + height,
    };
    // Preserve intentionally spanning windows. Only a completely invisible or
    // unreachable caption receives a minimal correction to the target work area.
    let caption = Rect {
        left,
        top,
        right: left + width,
        bottom: top + 32.min(height),
    };
    if screens
        .iter()
        .any(|screen| overlap(caption, screen.work) >= 48.min(width) as i64 * 16.min(height) as i64)
    {
        return Ok((r, false));
    }
    let min_visible = 48.min(width);
    let fixed_left = left.clamp(
        m.work.left - width + min_visible,
        m.work.right - min_visible,
    );
    let fixed_top = top.clamp(m.work.top, m.work.bottom - 32.min(height));
    let fixed = shift(r, fixed_left - left, fixed_top - top);
    Ok((fixed, !near(r, fixed, 0)))
}

fn set_outer(hwnd: HWND, r: Rect) -> Result<()> {
    unsafe {
        SetWindowPos(
            hwnd,
            None,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS,
        )
    }
    .map_err(|e| {
        format!(
            "无法发送窗口位置请求（{}）。请检查目标权限；预设已保留。",
            e.code()
        )
    })
}

fn topology_matches(
    expected: &[MonitorSnapshot],
    current: &[MonitorSnapshot],
    target: &MonitorSnapshot,
) -> bool {
    if expected.len() != current.len() {
        return false;
    }
    let target_matches = current.iter().any(|monitor| {
        monitor.key == target.key && monitor.rect == target.rect && monitor.work == target.work
    });
    target_matches
        && expected
            .iter()
            .all(|previous| current.iter().any(|now| now == previous))
}

fn topology_unchanged(expected: &[MonitorSnapshot], target: &MonitorSnapshot) -> bool {
    monitors().is_ok_and(|current| topology_matches(expected, &current, target))
}

/// Must run on an operation worker, never the UI message-loop thread. Requests
/// don't attach input queues or call synchronous ShowWindow/SendMessage.
pub fn restore(
    snapshot: &WindowSnapshot,
    p: &Placement,
    monitor: &MonitorSnapshot,
) -> Result<RestoreOutcome> {
    let _dpi = DpiScope::enter();
    let started = Instant::now();
    let hwnd = HWND(snapshot.handle as _);
    verify_identity(snapshot)?;
    if unsafe { IsIconic(hwnd) }.as_bool() {
        return Err("目标窗口已最小化，请先还原。".into());
    }
    let screens = monitors()?;
    let current_target = screens
        .iter()
        .find(|m| m.key == monitor.key)
        .ok_or_else(|| "目标显示器已断开，请重新操作。".to_string())?;
    if current_target.rect != monitor.rect || current_target.work != monitor.work {
        return Err("显示器布局已变化，请重新触发操作。".into());
    }
    let (target, clamped) = intended_rect(p, monitor, &screens)?;
    if !p.maximized && !unsafe { IsZoomed(hwnd) }.as_bool() && near(visible(hwnd)?, target, 2) {
        return Ok(if clamped {
            RestoreOutcome::Constrained
        } else {
            RestoreOutcome::AlreadyCorrect
        });
    }
    let original = window_placement(hwnd)?;
    let target_outer = visible_to_outer(target, insets(hwnd)?);
    if p.maximized {
        let existing = workspace_to_screen(rect(original.rcNormalPosition), monitor);
        if unsafe { IsZoomed(hwnd) }.as_bool()
            && near(existing, target_outer, 2)
            && screens
                .iter()
                .max_by_key(|m| overlap(outer(hwnd).unwrap_or(snapshot.normal_rect), m.rect))
                .is_some_and(|m| m.key == monitor.key)
        {
            return Ok(if clamped {
                RestoreOutcome::Constrained
            } else {
                RestoreOutcome::AlreadyCorrect
            });
        }
    }
    verify_identity(snapshot)?;
    if !topology_unchanged(&screens, monitor) {
        return Err("显示器在操作期间已变化，此次未发送恢复请求。".into());
    }
    verify_identity(snapshot)?;
    if unsafe { IsHungAppWindow(hwnd) }.as_bool() {
        return Err("目标窗口暂时无响应，未发送恢复请求；请稍后重试。".into());
    }
    let needs_state = p.maximized != unsafe { IsZoomed(hwnd) }.as_bool();
    if needs_state || p.maximized {
        // Public Win32 maximize commands can activate a window. They are only
        // issued to the still-current foreground target; a background selection
        // must be activated by the user before using the restore hotkey.
        if foreground() != snapshot.handle {
            return Err(
                "更改最大化状态前，请切换到目标窗口并按恢复热键；此次未发送状态请求。".into(),
            );
        }
        // SetWindowPlacement preserves the saved restore rectangle for maximizing.
        // WPF_ASYNCWINDOWPLACEMENT avoids waiting for a target's message pump.
        // This check cannot atomically lock the global foreground: a subsequent
        // user focus change can race a posted Win32 state request.
        let wp = WINDOWPLACEMENT {
            length: size_of::<WINDOWPLACEMENT>() as u32,
            flags: WPF_ASYNCWINDOWPLACEMENT,
            showCmd: if p.maximized {
                SW_SHOWMAXIMIZED.0 as u32
            } else {
                SW_SHOWNOACTIVATE.0 as u32
            },
            rcNormalPosition: native(screen_to_workspace(target_outer, monitor)),
            ..original
        };
        unsafe { SetWindowPlacement(hwnd, &wp) }
            .map_err(|e| format!("无法发送窗口状态请求（{}）；预设已保留。", e.code()))?;
    } else {
        set_outer(hwnd, target_outer)?;
    }
    let mut corrections = 0;
    let mut last_frame = None;
    let mut stable_since = Instant::now();
    while started.elapsed() < Duration::from_millis(1800) {
        std::thread::sleep(Duration::from_millis(12));
        if verify_identity(snapshot).is_err() {
            return Ok(RestoreOutcome::Unconfirmed);
        }
        let maximized = unsafe { IsZoomed(hwnd) }.as_bool();
        let frame = match visible(hwnd) {
            Ok(value) => value,
            Err(_) => return Ok(RestoreOutcome::Unconfirmed),
        };
        let state_ok = maximized == p.maximized;
        let good = if p.maximized {
            let normal =
                workspace_to_screen(rect(window_placement(hwnd)?.rcNormalPosition), monitor);
            state_ok
                && near(normal, target_outer, 2)
                && overlap(frame, monitor.rect) > 0
                && screens
                    .iter()
                    .max_by_key(|m| overlap(frame, m.rect))
                    .is_some_and(|m| m.key == monitor.key)
        } else {
            state_ok && near(frame, target, 2)
        };
        if good {
            if !topology_unchanged(&screens, monitor) {
                return Ok(RestoreOutcome::Unconfirmed);
            }
            return Ok(if clamped {
                RestoreOutcome::Constrained
            } else {
                RestoreOutcome::Restored
            });
        }
        if last_frame != Some(frame) {
            last_frame = Some(frame);
            stable_since = Instant::now();
        }
        // Once DPI processing settles, correct the measured visible-frame offsets.
        // Two corrections suffice for a cross-monitor DPI transition; no endless retry.
        if !p.maximized
            && state_ok
            && corrections < 2
            && started.elapsed() > Duration::from_millis(45)
            && stable_since.elapsed() > Duration::from_millis(24)
        {
            let corrected = visible_to_outer(target, insets(hwnd)?);
            // Every additional request depends on the original whole topology,
            // not just a stale target rectangle. A hotplug must stop subsequent
            // DPI corrections, even when the initial request was already posted.
            if !topology_unchanged(&screens, monitor) || verify_identity(snapshot).is_err() {
                return Ok(RestoreOutcome::Unconfirmed);
            }
            set_outer(hwnd, corrected)?;
            corrections += 1;
            stable_since = Instant::now();
        }
        if state_ok && corrections >= 2 && stable_since.elapsed() > Duration::from_millis(100) {
            // A stale cached frame does not prove application constraints: a
            // hung target can have all posted changes waiting in its queue.
            // WM_NULL is a bounded liveness check, not a placement operation.
            let responsive = unsafe {
                SendMessageTimeoutW(
                    hwnd,
                    WM_NULL,
                    WPARAM(0),
                    LPARAM(0),
                    SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT,
                    50,
                    None,
                )
            }
            .0 != 0;
            return Ok(if responsive {
                RestoreOutcome::Constrained
            } else {
                RestoreOutcome::Unconfirmed
            });
        }
    }
    // An asynchronous placement can arrive after this result; never claim failure
    // means that a previously posted request was cancelled.
    Ok(RestoreOutcome::Unconfirmed)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn topology_revalidation_checks_entire_set_and_target_work_area() {
        let first = MonitorSnapshot {
            key: "a".into(),
            name: "a".into(),
            rect: Rect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1080,
            },
            work: Rect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040,
            },
            fingerprints: vec!["path:a".into()],
        };
        let second = MonitorSnapshot {
            key: "b".into(),
            name: "b".into(),
            rect: Rect {
                left: -1920,
                top: 0,
                right: 0,
                bottom: 1080,
            },
            work: Rect {
                left: -1920,
                top: 0,
                right: 0,
                bottom: 1040,
            },
            fingerprints: vec!["path:b".into()],
        };
        let original = vec![first.clone(), second.clone()];
        assert!(topology_matches(
            &original,
            &[second.clone(), first.clone()],
            &first
        ));
        assert!(!topology_matches(
            &original,
            std::slice::from_ref(&first),
            &first
        ));
        let mut changed_work = first.clone();
        changed_work.work.top = 48;
        assert!(!topology_matches(
            &original,
            &[changed_work, second.clone()],
            &first
        ));
        let mut changed_neighbor = second;
        changed_neighbor.rect.left -= 100;
        assert!(!topology_matches(
            &original,
            &[first.clone(), changed_neighbor],
            &first
        ));
    }
    #[test]
    fn top_and_left_taskbars_round_trip_without_creep() {
        let m = MonitorSnapshot {
            key: "test".into(),
            name: "test".into(),
            rect: Rect {
                left: -1920,
                top: 0,
                right: 0,
                bottom: 1080,
            },
            work: Rect {
                left: -1880,
                top: 48,
                right: 0,
                bottom: 1080,
            },
            fingerprints: vec![],
        };
        let screen = Rect {
            left: -1800,
            top: 100,
            right: -800,
            bottom: 700,
        };
        let placement = screen_to_workspace(screen, &m);
        assert_eq!(placement.left, -1840);
        assert_eq!(placement.top, 52);
        assert_eq!(workspace_to_screen(placement, &m), screen);
    }
    #[test]
    fn frame_insets_round_trip_without_rounding() {
        let visible = Rect {
            left: -1200,
            top: 73,
            right: -200,
            bottom: 900,
        };
        assert_eq!(
            outer_to_visible(visible_to_outer(visible, [7, 0, 7, 7]), [7, 0, 7, 7]),
            visible
        );
    }
    #[test]
    fn model_is_not_emitted_as_a_serial() {
        assert!(edid_serials(&[0u8; 128]).is_empty());
        let mut e = [0u8; 128];
        e[..8].copy_from_slice(&[0, 255, 255, 255, 255, 255, 255, 0]);
        e[8] = 0x12;
        e[9] = 0x34;
        e[10] = 0x78;
        e[11] = 0x56;
        e[12] = 42;
        e[127] = 0u8.wrapping_sub(e[..127].iter().fold(0u8, |sum, b| sum.wrapping_add(*b)));
        assert_eq!(edid_serials(&e), vec!["serial:1234:5678:number:0000002a"]);
    }
    fn edid_with_serial(serial: u32, text: Option<&[u8]>) -> [u8; 128] {
        let mut e = [0u8; 128];
        e[..8].copy_from_slice(&[0, 255, 255, 255, 255, 255, 255, 0]);
        e[8] = 0x12;
        e[9] = 0x34;
        e[10] = 0x78;
        e[11] = 0x56;
        e[12..16].copy_from_slice(&serial.to_le_bytes());
        if let Some(text) = text {
            e[57] = 255;
            e[59..72].fill(b' ');
            e[59..59 + text.len()].copy_from_slice(text);
        }
        e[127] = 0u8.wrapping_sub(e[..127].iter().fold(0u8, |sum, b| sum.wrapping_add(*b)));
        e
    }
    #[test]
    fn invalid_edid_never_provides_identity() {
        let valid = edid_with_serial(42, Some(b"Unique123\n"));
        assert!(valid_edid(&valid));
        assert_eq!(edid_serials(&valid).len(), 2);
        assert!(edid_serials(&valid[..127]).is_empty());
        let mut corrupted = valid;
        corrupted[20] ^= 1;
        assert!(edid_serials(&corrupted).is_empty());
        let mut corrupted = valid;
        corrupted[0] = 1;
        corrupted[127] = corrupted[127].wrapping_sub(1);
        assert!(edid_serials(&corrupted).is_empty());
    }
    #[test]
    fn absent_numeric_serial_can_use_valid_ascii_descriptor() {
        assert!(edid_serials(&edid_with_serial(0, None)).is_empty());
        assert!(edid_serials(&edid_with_serial(u32::MAX, Some(b"0000000"))).is_empty());
        assert_eq!(
            edid_serials(&edid_with_serial(0, Some(b"Unique123\n"))),
            vec!["serial:1234:5678:text:unique123"]
        );
        assert!(edid_serials(&edid_with_serial(0, Some(&[255, 255, 255]))).is_empty());
    }
    #[test]
    fn spanning_window_keeps_caption_visible_on_neighbor_screen() {
        let lower = MonitorSnapshot {
            key: "lower".into(),
            name: "lower".into(),
            rect: Rect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1080,
            },
            work: Rect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1040,
            },
            fingerprints: vec![],
        };
        let upper = MonitorSnapshot {
            key: "upper".into(),
            name: "upper".into(),
            rect: Rect {
                left: 0,
                top: -1080,
                right: 1920,
                bottom: 0,
            },
            work: Rect {
                left: 0,
                top: -1080,
                right: 1920,
                bottom: 0,
            },
            fingerprints: vec![],
        };
        let placement = Placement {
            display_id: "lower".into(),
            rect: crate::model::RelativeRect {
                x: 0.1,
                y: -0.1,
                width: 0.5,
                height: 0.8,
            },
            maximized: false,
        };
        let (result, clamped) = intended_rect(&placement, &lower, &[lower.clone(), upper]).unwrap();
        assert_eq!(result.top, -104);
        assert!(!clamped);
        let (result, clamped) =
            intended_rect(&placement, &lower, std::slice::from_ref(&lower)).unwrap();
        assert_eq!(result.top, 0);
        assert!(clamped);
    }
}
