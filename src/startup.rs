use std::path::Path;
use windows::Win32::System::Registry::*;
use windows::core::PCWSTR;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Return the previous bytes so a failed configuration transaction can roll back.
pub fn set(enabled: bool, config_directory: &Path) -> Result<Option<Vec<u8>>, String> {
    let previous = read()?;
    let next = if enabled {
        let command = expected_command(config_directory)?;
        Some(
            wide(&command)
                .iter()
                .flat_map(|n| n.to_le_bytes())
                .collect(),
        )
    } else {
        None
    };
    restore(next)?;
    Ok(previous)
}

fn expected_command(config_directory: &Path) -> Result<String, String> {
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok(format!(
        "{} --background --config-dir {}",
        quote(&executable.to_string_lossy()),
        quote(&config_directory.to_string_lossy())
    ))
}

pub fn warning(enabled: bool, config_directory: &Path) -> Option<String> {
    if !enabled {
        return None;
    }
    match (expected_command(config_directory), read()) {
        (Ok(command), Ok(Some(bytes))) => {
            let expected: Vec<u8> = wide(&command)
                .iter()
                .flat_map(|n| n.to_le_bytes())
                .collect();
            (bytes != expected).then(|| "开机启动项与当前程序路径不一致，请保存设置修复".into())
        }
        (Ok(_), Ok(None)) => Some("开机启动项缺失，请保存设置修复".into()),
        (Err(error), _) | (_, Err(error)) => Some(format!("无法检测开机启动：{error}")),
    }
}

pub fn restore(value: Option<Vec<u8>>) -> Result<(), String> {
    unsafe {
        let subkey = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
        let name = wide("ScreenPin");
        let mut key = HKEY::default();
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            None,
            None,
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut key,
            None,
        )
        .ok()
        .map_err(|e| e.to_string())?;
        let result = match value {
            Some(bytes) => RegSetValueExW(key, PCWSTR(name.as_ptr()), None, REG_SZ, Some(&bytes))
                .ok()
                .map_err(|e| e.to_string()),
            None => {
                let status = RegDeleteValueW(key, PCWSTR(name.as_ptr()));
                if status.0 == 0 || status.0 == 2 {
                    Ok(())
                } else {
                    Err(format!("无法更新开机启动：{}", status.0))
                }
            }
        };
        let _ = RegCloseKey(key);
        result
    }
}

fn read() -> Result<Option<Vec<u8>>, String> {
    unsafe {
        let subkey = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
        let name = wide("ScreenPin");
        let mut size = 0;
        let status = RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            None,
            Some(&mut size),
        );
        if status.0 == 2 {
            return Ok(None);
        }
        status
            .ok()
            .map_err(|e| format!("无法读取开机启动设置：{e}"))?;
        let mut bytes = vec![0u8; size as usize];
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            Some(bytes.as_mut_ptr().cast()),
            Some(&mut size),
        )
        .ok()
        .map_err(|e| e.to_string())?;
        bytes.truncate(size as usize);
        Ok(Some(bytes))
    }
}

fn quote(argument: &str) -> String {
    let mut result = String::from("\"");
    let mut slashes = 0;
    for ch in argument.chars() {
        match ch {
            '\\' => slashes += 1,
            '"' => {
                result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
                result.push('"');
                slashes = 0;
            }
            _ => {
                result.extend(std::iter::repeat_n('\\', slashes));
                result.push(ch);
                slashes = 0;
            }
        }
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn startup_argument_quoting_preserves_spaces_quotes_and_trailing_backslash() {
        assert_eq!(
            quote("C:\\Program Files\\Screen Pin\\screen-pin.exe"),
            "\"C:\\Program Files\\Screen Pin\\screen-pin.exe\""
        );
        assert_eq!(quote("D:\\"), "\"D:\\\\\"");
        assert_eq!(quote("a\"b"), "\"a\\\"b\"");
    }
}
