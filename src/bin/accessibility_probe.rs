//! Native UIA inspection; optional focus of a Screen Pin test window or fixture.
use serde::Deserialize;
use windows::Win32::{
    Foundation::HWND,
    System::Com::{
        CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
        CoUninitialize,
    },
    UI::{
        Accessibility::{CUIAutomation, IUIAutomation},
        WindowsAndMessaging::{
            GA_ROOT, GetAncestor, GetClassNameW, GetDlgCtrlID, GetWindowThreadProcessId,
        },
    },
};

#[derive(Deserialize)]
struct Control {
    handle: isize,
    id: u32,
    page: String,
}

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 3 && !(args.len() == 4 && args[3] == "--focus") {
        return Err(
            "usage: accessibility_probe INPUT_JSON OUTPUT_JSON EXPECTED_PID [--focus]".into(),
        );
    }
    let focus = args.len() == 4;
    let expected: u32 = args[2].parse()?;
    let controls: Vec<Control> = serde_json::from_slice(&std::fs::read(&args[0])?)?;
    if focus && controls.len() != 1 {
        return Err("focus requires exactly one explicit test control".into());
    }
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
    let _apartment = Apartment;
    let automation: IUIAutomation =
        unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }?;
    let mut result = Vec::new();
    for control in controls {
        let handle = HWND(control.handle as _);
        let mut owner = 0;
        unsafe { GetWindowThreadProcessId(handle, Some(&mut owner)) };
        if owner != expected {
            return Err("control HWND no longer belongs to the isolated app".into());
        }
        let element = unsafe { automation.ElementFromHandle(handle) }?;
        if unsafe { element.CurrentProcessId() }? as u32 != expected {
            return Err("UIA provider process does not match the isolated app".into());
        }
        if focus {
            let root = unsafe { GetAncestor(handle, GA_ROOT) };
            let mut class = [0; 128];
            let length = unsafe { GetClassNameW(root, &mut class) } as usize;
            let class = String::from_utf16_lossy(&class[..length]);
            let settings_tab = class == "ScreenPin.Settings"
                && control.id == 100
                && unsafe { GetDlgCtrlID(handle) } == 100;
            let fixture = root == handle && class.starts_with("ScreenPin.RealHotkeyFixture.");
            if !settings_tab && !fixture {
                return Err(
                    "focus is restricted to Screen Pin's first tab or a test fixture".into(),
                );
            }
            // Use the public accessibility action; the caller still verifies
            // actual foreground ownership before sending any keyboard input.
            unsafe { element.SetFocus() }?;
        }
        result.push(serde_json::json!({
            "page": control.page,
            "id": control.id,
            "name": unsafe { element.CurrentName() }?.to_string(),
            "type": unsafe { element.CurrentControlType() }?.0,
            "enabled": unsafe { element.CurrentIsEnabled() }?.as_bool(),
            "access_key": unsafe { element.CurrentAccessKey() }?.to_string(),
            "provider": unsafe { element.CurrentProviderDescription() }?.to_string(),
        }));
    }
    std::fs::write(&args[1], serde_json::to_vec_pretty(&result)?)?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("accessibility probe: {error}");
        std::process::exit(1);
    }
}
