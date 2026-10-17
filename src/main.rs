#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use screen_pin::{
    controller::Controller,
    desktop, lifecycle,
    protocol::{Backend, Request},
    shell, store,
};
use std::path::PathBuf;

struct WindowPropertyCleanup;
impl Drop for WindowPropertyCleanup {
    fn drop(&mut self) {
        desktop::cleanup_window_tokens();
    }
}

fn run() -> Result<(), String> {
    let _window_properties = WindowPropertyCleanup;
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--diagnose") {
        let monitors = desktop::monitors()?;
        let windows = desktop::windows()?;
        println!(
            "{}",
            serde_json::json!({
                "version": env!("CARGO_PKG_VERSION"),
                "monitors": monitors.iter().map(|m| serde_json::json!({"name":m.name,"bounds":m.rect,"work_area":m.work,"fingerprint_count":m.fingerprints.len()})).collect::<Vec<_>>(),
                "eligible_window_count": windows.len()
            })
        );
        return Ok(());
    }
    let mut directory = None;
    for (index, arg) in args.iter().enumerate() {
        if arg == "--config-dir" {
            directory = Some(PathBuf::from(
                args.get(index + 1).ok_or("--config-dir 后需要目录")?,
            ));
        }
    }
    let directory = match directory {
        Some(path) => path,
        None => store::default_directory()?,
    };
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let directory = directory.canonicalize().map_err(|e| e.to_string())?;
    lifecycle::prepare_child(&args, &directory)?;
    let config_path = directory.join("config.json").display().to_string();
    let (mut controller, first_run) = match Controller::open(directory) {
        Ok(value) => value,
        Err(error) => {
            // The independent launch reservation may belong to an instance
            // whose host is still initializing. It remains held during handoff.
            if !args
                .iter()
                .any(|argument| argument.starts_with("--handoff-"))
            {
                for _ in 0..50 {
                    if shell::activate_existing(&config_path) {
                        return Ok(());
                    }
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
            }
            return Err(error);
        }
    };
    let initial = controller.handle(Request::Refresh);
    let show = args.iter().any(|a| a == "--show")
        || (first_run && !args.iter().any(|a| a == "--background"));
    shell::run(controller, initial, show)
}

fn main() {
    if let Err(message) = run() {
        eprintln!("Screen Pin: {message}");
        // A failed handoff child must exit promptly so the original instance can recover.
        if std::env::args().any(|arg| arg.starts_with("--handoff-")) {
            std::process::exit(1);
        }
        let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
        unsafe {
            windows::Win32::UI::WindowsAndMessaging::MessageBoxW(
                None,
                windows::core::PCWSTR(text.as_ptr()),
                windows::core::w!("Screen Pin"),
                windows::Win32::UI::WindowsAndMessaging::MB_OK
                    | windows::Win32::UI::WindowsAndMessaging::MB_ICONERROR,
            );
        }
        std::process::exit(1);
    }
}
