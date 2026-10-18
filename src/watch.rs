//! Bounded live observation, enabled only while the edit panel is open.
use crate::model::{Rect, WindowSummary};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;
use windows::Win32::Foundation::{HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObservedWindow {
    pub summary: WindowSummary,
    pub frame: Rect,
    pub monitor_name: String,
    pub maximized: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Update {
    Pending,
    Ready(ObservedWindow),
    Unavailable(String),
}
type Latest = Arc<Mutex<Option<Update>>>;

pub struct Watcher {
    stop: mpsc::SyncSender<Command>,
    thread: Option<std::thread::JoinHandle<()>>,
    latest: Latest,
}
enum Command {
    Target(isize),
    Stop,
}

impl Watcher {
    pub fn start(host: HWND, message: u32) -> Result<Self, String> {
        let latest: Latest = Default::default();
        let shared = latest.clone();
        let host = host.0 as isize;
        let (stop_tx, stop_rx) = mpsc::sync_channel(2);
        let thread = std::thread::Builder::new()
            .name("screen-pin-live-window".into())
            .spawn(move || {
                let publish = |update| {
                    if let Ok(mut latest) = shared.lock() {
                        *latest = Some(update);
                    }
                    unsafe {
                        let _ = PostMessageW(Some(HWND(host as _)), message, WPARAM(0), LPARAM(0));
                    }
                };
                let result = std::panic::catch_unwind(|| {
                    let mut target = 0;
                    let mut identity = None;
                    let mut previous = None;
                    loop {
                        let foreground = unsafe { GetForegroundWindow() };
                        let mut pid = 0;
                        unsafe {
                            GetWindowThreadProcessId(foreground, Some(&mut pid));
                        }
                        // Keep the last external target while our panel/dialog is active.
                        if pid != 0 && pid != std::process::id() && target != foreground.0 as isize
                        {
                            target = foreground.0 as isize;
                            identity = None;
                            previous = None;
                            publish(Update::Pending);
                        }
                        if target != 0 {
                            let fingerprint = fingerprint(target, identity);
                            if previous.as_ref() != Some(&fingerprint) {
                                let observed = fingerprint
                                    .as_ref()
                                    .map_err(Clone::clone)
                                    .and_then(|_| observe(target, identity));
                                match observed {
                                    Ok(window) => {
                                        identity = Some((window.summary.pid, window.summary.token));
                                        publish(Update::Ready(window));
                                    }
                                    Err(error) => publish(Update::Unavailable(error)),
                                }
                                previous = Some(fingerprint);
                            }
                        }
                        // No polling or surviving observer in tray/normal mode.
                        match stop_rx.recv_timeout(Duration::from_millis(120)) {
                            Ok(Command::Target(handle)) => {
                                target = handle;
                                identity = None;
                                previous = None;
                                publish(Update::Pending);
                            }
                            Err(mpsc::RecvTimeoutError::Timeout) => {}
                            Ok(Command::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        }
                    }
                });
                if result.is_err() {
                    publish(Update::Unavailable(
                        "实时识别已停止，请重新开启编辑模式。".into(),
                    ));
                }
            })
            .map_err(|e| format!("无法启动编辑模式：{e}"))?;
        Ok(Self {
            stop: stop_tx,
            thread: Some(thread),
            latest,
        })
    }

    pub fn take_update(&self) -> Option<Update> {
        self.latest.lock().ok()?.take()
    }

    pub fn retain(&self, handle: isize) {
        let _ = self.stop.try_send(Command::Target(handle));
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        // A full queue only contains earlier target selections; drain them before stopping.
        let _ = self.stop.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            // Finish sampling before lifecycle cleanup removes our window tokens.
            let _ = thread.join();
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint {
    title: Vec<u16>,
    rect: [i32; 4],
    work: [i32; 4],
    flags: [bool; 3],
    dpi: u32,
}

fn fingerprint(handle: isize, identity: Option<(u32, u64)>) -> Result<Fingerprint, String> {
    if let Some((pid, token)) = identity {
        crate::desktop::validate_window_token(handle, pid, token)?;
    }
    let hwnd = HWND(handle as _);
    let mut rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut rect) }
        .map_err(|_| "目标窗口已关闭，请重新选择。".to_string())?;
    let capacity = (unsafe { GetWindowTextLengthW(hwnd) }.max(0) as usize + 1).min(32768);
    let mut title = vec![0u16; capacity];
    let count = unsafe { GetWindowTextW(hwnd, &mut title) }.max(0) as usize;
    title.truncate(count);
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if !unsafe { GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mut info) }
        .as_bool()
    {
        return Err("无法读取窗口所在显示器，请重新激活目标窗口。".into());
    }
    Ok(Fingerprint {
        title,
        rect: [rect.left, rect.top, rect.right, rect.bottom],
        work: [
            info.rcWork.left,
            info.rcWork.top,
            info.rcWork.right,
            info.rcWork.bottom,
        ],
        flags: [
            unsafe { IsIconic(hwnd) }.as_bool(),
            unsafe { IsZoomed(hwnd) }.as_bool(),
            unsafe { IsWindowVisible(hwnd) }.as_bool(),
        ],
        dpi: unsafe { GetDpiForWindow(hwnd) },
    })
}

fn observe(handle: isize, identity: Option<(u32, u64)>) -> Result<ObservedWindow, String> {
    if let Some((pid, token)) = identity {
        crate::desktop::validate_window_token(handle, pid, token)?;
    }
    let snapshot = crate::desktop::capture(handle)?;
    if identity.is_some_and(|id| id != (snapshot.pid, snapshot.token)) {
        return Err("目标窗口已变化，请重新激活目标窗口。".into());
    }
    let frame = crate::desktop::visible_frame(handle)?;
    let monitor_name = crate::desktop::monitors()?
        .into_iter()
        .find(|monitor| monitor.key == snapshot.display_key)
        .map(|monitor| monitor.name)
        .unwrap_or_else(|| "未知显示器".into());
    crate::desktop::validate_window_token(handle, snapshot.pid, snapshot.token)?;
    Ok(ObservedWindow {
        summary: WindowSummary {
            handle: snapshot.handle,
            pid: snapshot.pid,
            token: snapshot.token,
            app_id: snapshot.app_id,
            title: snapshot.title,
            app_name: snapshot.app_name,
        },
        frame,
        monitor_name,
        maximized: snapshot.maximized,
    })
}
