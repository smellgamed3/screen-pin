//! Real Windows API probe. Only the child fixture window created here is moved.
use screen_pin::{
    desktop,
    model::{Placement, RelativeRect, RestoreOutcome},
};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{HANDLE, HWND, LPARAM, LRESULT, WPARAM},
        System::LibraryLoader::GetModuleHandleW,
        UI::{HiDpi::*, WindowsAndMessaging::*},
    },
    core::w,
};

unsafe extern "system" fn fixture_proc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    static REBUILDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    static MIN_WIDTH: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
    static MIN_HEIGHT: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
    if m == WM_APP + 42 {
        std::thread::sleep(Duration::from_millis(w.0.min(5000) as u64));
        return LRESULT(0);
    }
    if m == WM_APP + 43 {
        MIN_WIDTH.store(w.0.min(4000) as i32, std::sync::atomic::Ordering::Relaxed);
        MIN_HEIGHT.store(
            l.0.clamp(0, 4000) as i32,
            std::sync::atomic::Ordering::Relaxed,
        );
        return LRESULT(0);
    }
    if m == WM_WINDOWPOSCHANGING && l.0 != 0 {
        let position = unsafe { &mut *(l.0 as *mut WINDOWPOS) };
        if position.flags.0 & SWP_NOSIZE.0 == 0 {
            position.cx = position
                .cx
                .max(MIN_WIDTH.load(std::sync::atomic::Ordering::Relaxed));
            position.cy = position
                .cy
                .max(MIN_HEIGHT.load(std::sync::atomic::Ordering::Relaxed));
        }
    }
    if m == WM_APP + 41 {
        REBUILDING.store(true, std::sync::atomic::Ordering::Relaxed);
        unsafe {
            let _ = DestroyWindow(h);
            if let Ok(instance) = GetModuleHandleW(None)
                && let Ok(replacement) = CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    w!("ScreenPinDesktopProbeFixture"),
                    w!("Screen Pin isolated desktop probe"),
                    WS_OVERLAPPEDWINDOW,
                    120,
                    120,
                    700,
                    500,
                    None,
                    None,
                    Some(instance.into()),
                    None,
                )
            {
                let _ = ShowWindow(replacement, SW_SHOWNOACTIVATE);
            }
        }
        REBUILDING.store(false, std::sync::atomic::Ordering::Relaxed);
        return LRESULT(0);
    }
    if m == WM_CLOSE {
        unsafe {
            let _ = DestroyWindow(h);
        }
        return LRESULT(0);
    }
    if m == WM_DESTROY {
        if REBUILDING.load(std::sync::atomic::Ordering::Relaxed) {
            return LRESULT(0);
        }
        unsafe {
            PostQuitMessage(0);
        }
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(h, m, w, l) }
}
fn fixture(hung: bool, title: Option<&str>) -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class = WNDCLASSW {
            lpfnWndProc: Some(fixture_proc),
            hInstance: instance.into(),
            lpszClassName: w!("ScreenPinDesktopProbeFixture"),
            ..Default::default()
        };
        if RegisterClassW(&class) == 0 {
            return Err("RegisterClassW failed".into());
        }
        let title: Vec<u16> = title
            .unwrap_or("Screen Pin isolated desktop probe")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("ScreenPinDesktopProbeFixture"),
            windows::core::PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW,
            120,
            120,
            700,
            500,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .map_err(|e| e.to_string())?;
        let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
        println!("{}", window.0 as isize);
        std::io::stdout().flush().map_err(|e| e.to_string())?;
        if hung {
            std::thread::sleep(Duration::from_secs(60));
            return Ok(());
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Ok(())
}
struct Fixture {
    process: Child,
    handle: isize,
}
impl Fixture {
    fn start(hung: bool) -> Result<Self, String> {
        use std::os::windows::process::CommandExt;
        let mut cmd = Command::new(std::env::current_exe().map_err(|e| e.to_string())?);
        cmd.arg("--fixture");
        if hung {
            cmd.arg("--hung");
        }
        let mut process = cmd
            .creation_flags(0x08000000)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        let mut line = String::new();
        BufReader::new(process.stdout.take().ok_or("child stdout missing")?)
            .read_line(&mut line)
            .map_err(|e| e.to_string())?;
        let handle = line
            .trim()
            .parse::<isize>()
            .map_err(|e| format!("Fixture handle invalid: {line:?}, {e}"))?;
        std::thread::sleep(Duration::from_millis(100));
        Ok(Self { process, handle })
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}
fn place(handle: isize, x: i32, y: i32, w: i32, h: i32) -> Result<(), String> {
    unsafe {
        SetWindowPos(
            HWND(handle as _),
            None,
            x,
            y,
            w,
            h,
            SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS,
        )
    }
    .map_err(|e| e.to_string())?;
    std::thread::sleep(Duration::from_millis(50));
    Ok(())
}
fn run() -> Result<serde_json::Value, String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let monitors = desktop::monitors()?;
    let fixture = Fixture::start(false)?;
    let before = desktop::foreground();
    let snapshot = desktop::capture(fixture.handle)?;
    let monitor = monitors
        .iter()
        .find(|m| m.key == snapshot.display_key)
        .ok_or("fixture monitor missing")?;
    let w = (monitor.work.right - monitor.work.left) as f64;
    let h = (monitor.work.bottom - monitor.work.top) as f64;
    let desired = snapshot.normal_rect;
    let mut placement = Placement {
        display_id: monitor.key.clone(),
        rect: RelativeRect {
            x: (desired.left - monitor.work.left) as f64 / w,
            y: (desired.top - monitor.work.top) as f64 / h,
            width: (desired.right - desired.left) as f64 / w,
            height: (desired.bottom - desired.top) as f64 / h,
        },
        maximized: false,
    };
    let mut samples = Vec::new();
    let mut max_error = 0i32;
    let mut changed_focus = false;
    for n in 0..50 {
        place(
            fixture.handle,
            monitor.work.left + 250 + (n % 3) * 10,
            monitor.work.top + 160,
            640,
            440,
        )?;
        let captured = desktop::capture(fixture.handle)?;
        let start = Instant::now();
        let outcome = desktop::restore(&captured, &placement, monitor)?;
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
        if !matches!(
            outcome,
            RestoreOutcome::Restored | RestoreOutcome::AlreadyCorrect
        ) {
            return Err(format!("normal restore not confirmed: {outcome:?}"));
        }
        let result = desktop::capture(fixture.handle)?;
        max_error = max_error
            .max((desired.left - result.normal_rect.left).abs())
            .max((desired.top - result.normal_rect.top).abs())
            .max((desired.right - result.normal_rect.right).abs())
            .max((desired.bottom - result.normal_rect.bottom).abs());
        changed_focus |= desktop::foreground() != before;
    }
    let normal_focus_changed = changed_focus;
    let pre_max_foreground = desktop::foreground();
    let same = desktop::capture(fixture.handle)?;
    let already_correct = format!("{:?}", desktop::restore(&same, &placement, monitor)?);
    placement.maximized = true;
    let background_state_rejected = desktop::restore(&same, &placement, monitor).is_err();
    let background_rejection_preserved_focus = desktop::foreground() == pre_max_foreground;
    // The test explicitly activates its own fixture to exercise the hotkey's
    // foreground state-change path. This is an intentional test setup action.
    unsafe {
        let mut wp = WINDOWPLACEMENT {
            length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
            ..Default::default()
        };
        GetWindowPlacement(HWND(fixture.handle as _), &mut wp).map_err(|e| e.to_string())?;
        wp.flags = WPF_ASYNCWINDOWPLACEMENT;
        wp.showCmd = SW_SHOWMAXIMIZED.0 as u32;
        SetWindowPlacement(HWND(fixture.handle as _), &wp).map_err(|e| e.to_string())?;
        std::thread::sleep(Duration::from_millis(70));
        wp.showCmd = SW_SHOWNOACTIVATE.0 as u32;
        SetWindowPlacement(HWND(fixture.handle as _), &wp).map_err(|e| e.to_string())?;
    }
    std::thread::sleep(Duration::from_millis(70));
    if desktop::foreground() != fixture.handle {
        return Err("Could not activate isolated fixture for the foreground maximize test".into());
    }
    let start = Instant::now();
    let maximum = desktop::restore(&same, &placement, monitor)?;
    let max_ms = start.elapsed().as_secs_f64() * 1000.0;
    let max_capture = desktop::capture(fixture.handle)?;
    let maximum_capture_state = max_capture.maximized;
    let maximized_normal_error = [
        desired.left - max_capture.normal_rect.left,
        desired.top - max_capture.normal_rect.top,
        desired.right - max_capture.normal_rect.right,
        desired.bottom - max_capture.normal_rect.bottom,
    ]
    .iter()
    .map(|v| v.abs())
    .max()
    .unwrap_or(0);
    let max_foreground = desktop::foreground();
    changed_focus |= max_foreground != fixture.handle;
    placement.maximized = false;
    let restored_normal = desktop::restore(&max_capture, &placement, monitor)?;
    changed_focus |= desktop::foreground() != fixture.handle;
    let final_snapshot = desktop::capture(fixture.handle)?;
    let windows = desktop::windows()?;
    let listed = windows.iter().any(|w| w.handle == fixture.handle);
    // Reuse rejection checks PID as well as HWND. This never targets another window.
    let wrong_pid_rejected =
        desktop::validate_target(fixture.handle, fixture.process.id() + 1).is_err();
    let hung = Fixture::start(true)?;
    let hung_snapshot = desktop::capture(hung.handle)?;
    let mut hung_placement = placement.clone();
    hung_placement.rect.x += 0.2;
    let start = Instant::now();
    let hung_result = desktop::restore(&hung_snapshot, &hung_placement, monitor);
    let hung_ms = start.elapsed().as_secs_f64() * 1000.0;
    let hung_bounded = hung_ms <= 2000.0
        && (matches!(hung_result, Ok(RestoreOutcome::Unconfirmed)) || hung_result.is_err());
    let responsive_after_hung = matches!(
        desktop::restore(&final_snapshot, &placement, monitor),
        Ok(RestoreOutcome::AlreadyCorrect)
    );
    let fixture_pid = fixture.process.id();
    let original_token = desktop::window_token(fixture.handle)?;
    let capture_keeps_token = original_token == final_snapshot.token;
    let wrong_token_rejected =
        desktop::validate_window_token(fixture.handle, fixture_pid, original_token + 1).is_err();
    unsafe {
        SetPropW(
            HWND(fixture.handle as _),
            w!("ScreenPin.Probe.Unrelated"),
            Some(HANDLE(77usize as _)),
        )
        .map_err(|e| e.to_string())?;
    }
    desktop::cleanup_window_tokens();
    let cleanup_removed =
        desktop::validate_window_token(fixture.handle, fixture_pid, original_token).is_err();
    let unrelated_preserved = unsafe {
        GetPropW(HWND(fixture.handle as _), w!("ScreenPin.Probe.Unrelated")).0 as usize == 77
    };
    unsafe {
        let _ = RemovePropW(HWND(fixture.handle as _), w!("ScreenPin.Probe.Unrelated"));
    }
    let reminted = desktop::window_token(fixture.handle)?;
    let remint_changes_generation = reminted != original_token
        && desktop::validate_window_token(fixture.handle, fixture_pid, original_token).is_err();
    unsafe {
        PostMessageW(
            Some(HWND(fixture.handle as _)),
            WM_APP + 41,
            WPARAM(0),
            LPARAM(0),
        )
        .map_err(|e| e.to_string())?;
    }
    let rebuild_start = Instant::now();
    let rebuilt = loop {
        std::thread::sleep(Duration::from_millis(20));
        if let Some(new) = desktop::windows()?
            .into_iter()
            .find(|window| window.pid == fixture_pid && window.token != reminted)
        {
            break new;
        }
        if rebuild_start.elapsed() > Duration::from_secs(1) {
            return Err("Fixture did not recreate its window in the same process".into());
        }
    };
    let old_generation_rejected =
        desktop::validate_window_token(rebuilt.handle, fixture_pid, reminted).is_err()
            && desktop::validate_window_token(fixture.handle, fixture_pid, reminted).is_err();
    let actual_hwnd_value_reused = rebuilt.handle == fixture.handle;
    desktop::cleanup_window_tokens();
    let rebuilt_cleanup_removed =
        desktop::validate_window_token(rebuilt.handle, fixture_pid, rebuilt.token).is_err();
    let mut sorted = samples.clone();
    sorted.sort_by(f64::total_cmp);
    let p95 = sorted[47];
    Ok(
        serde_json::json!({"scope":"Only isolated child fixture windows were moved; no user windows were moved.",
        "monitor_count":monitors.len(),"monitors":monitors.iter().map(|m|serde_json::json!({"key":m.key,"name":m.name,"rect":m.rect,"work":m.work,"fingerprints":m.fingerprints})).collect::<Vec<_>>(),"normal_restore_samples_ms":samples,"normal_restore_p95_ms":p95,
        "normal_max_edge_error_px":max_error,"already_correct":already_correct,"maximized_result":format!("{maximum:?}"),
        "maximized_capture_state":maximum_capture_state,"maximized_normal_edge_error_px":maximized_normal_error,
        "maximize_ms":max_ms,"normal_after_maximize":format!("{restored_normal:?}"),"final_rect":final_snapshot.normal_rect,
        "background_state_rejected":background_state_rejected,"background_rejection_preserved_focus":background_rejection_preserved_focus,
        "hung_result":format!("{hung_result:?}"),"hung_ms":hung_ms,"hung_bounded":hung_bounded,"responsive_after_hung":responsive_after_hung,
        "capture_keeps_window_token":capture_keeps_token,"wrong_window_token_rejected":wrong_token_rejected,
        "cleanup_removed_own_marker":cleanup_removed,"cleanup_preserved_unrelated_property":unrelated_preserved,
        "remint_changes_generation_on_same_hwnd":remint_changes_generation,
        "same_process_destroy_recreate_old_generation_rejected":old_generation_rejected,
        "actual_hwnd_value_reused_by_os":actual_hwnd_value_reused,"rebuilt_window_cleanup_removed":rebuilt_cleanup_removed,
        "foreground_changed":changed_focus,"normal_focus_changed":normal_focus_changed,"foreground_before":before,"foreground_before_max":pre_max_foreground,"foreground_after_max":max_foreground,"fixture_handle":fixture.handle,"listed":listed,"wrong_pid_rejected":wrong_pid_rejected,
        "passed":max_error<=2&&p95<=300.0&&!changed_focus&&maximum_capture_state&&maximized_normal_error<=2&&listed&&wrong_pid_rejected&&background_state_rejected&&background_rejection_preserved_focus&&hung_bounded&&responsive_after_hung&&capture_keeps_token&&wrong_token_rejected&&cleanup_removed&&unrelated_preserved&&remint_changes_generation&&old_generation_rejected&&rebuilt_cleanup_removed}),
    )
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--fixture") {
        let title = args
            .iter()
            .position(|a| a == "--title")
            .and_then(|index| args.get(index + 1))
            .map(String::as_str);
        if let Err(e) = fixture(args.iter().any(|a| a == "--hung"), title) {
            eprintln!("{e}");
            std::process::exit(1)
        }
        return;
    }
    match run() {
        Ok(report) => {
            let output = serde_json::to_string_pretty(&report).unwrap();
            if let Some(index) = args.iter().position(|a| a == "--output")
                && let Some(path) = args.get(index + 1)
            {
                std::fs::write(path, &output).unwrap();
            }
            println!("{output}");
            if !report["passed"].as_bool().unwrap_or(false) {
                std::process::exit(2);
            }
        }
        Err(e) => {
            eprintln!("Desktop probe failed: {e}");
            std::process::exit(1);
        }
    }
}
