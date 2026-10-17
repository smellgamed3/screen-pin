//! Same-user elevation uses a bounded, SID-restricted two-phase handoff.
//! The parent keeps its writer lock until the child has verified its identity.
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
struct HandoffArgs {
    parent_pid: u32,
    parent_started: u64,
    nonce: String,
    reservation_handle: usize,
}

impl HandoffArgs {
    fn parse(args: &[String]) -> Result<Option<Self>, String> {
        let mut parent_pid = None;
        let mut parent_started = None;
        let mut nonce = None;
        let mut reservation_handle = None;
        let mut index = 0;
        while index < args.len() {
            let argument = args[index].as_str();
            if !argument.starts_with("--handoff-") {
                index += 1;
                continue;
            }
            let value = args.get(index + 1).ok_or("提权交接参数不完整。")?;
            match argument {
                "--handoff-parent-pid" if parent_pid.is_none() => {
                    parent_pid = Some(value.parse::<u32>().map_err(|_| "交接父进程编号无效。")?);
                }
                "--handoff-parent-started" if parent_started.is_none() => {
                    parent_started =
                        Some(value.parse::<u64>().map_err(|_| "交接父进程身份无效。")?);
                }
                "--handoff-nonce" if nonce.is_none() => {
                    if !(16..=128).contains(&value.len())
                        || !value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
                    {
                        return Err("交接会话标识无效。".into());
                    }
                    nonce = Some(value.clone());
                }
                "--handoff-reservation-handle" if reservation_handle.is_none() => {
                    let handle = value.parse::<usize>().map_err(|_| "交接启动权句柄无效。")?;
                    if handle == 0 || handle > isize::MAX as usize {
                        return Err("交接启动权句柄无效。".into());
                    }
                    reservation_handle = Some(handle);
                }
                _ => return Err("提权交接参数未知或重复。".into()),
            }
            index += 2;
        }
        if parent_pid.is_none()
            && parent_started.is_none()
            && nonce.is_none()
            && reservation_handle.is_none()
        {
            return Ok(None);
        }
        let result = Self {
            parent_pid: parent_pid.ok_or("提权交接缺少父进程编号。")?,
            parent_started: parent_started.ok_or("提权交接缺少父进程身份。")?,
            nonce: nonce.ok_or("提权交接缺少会话标识。")?,
            reservation_handle: reservation_handle.ok_or("提权交接缺少启动权句柄。")?,
        };
        if result.parent_pid == 0
            || result.parent_pid == std::process::id()
            || result.parent_started == 0
        {
            return Err("交接父进程身份无效。".into());
        }
        Ok(Some(result))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    sid: String,
    session: u32,
    started: u64,
    executable: std::path::PathBuf,
    elevated: bool,
}

fn validate_identity(
    parent: &Identity,
    child: &Identity,
    expected_parent_started: u64,
) -> Result<(), String> {
    if parent.started != expected_parent_started {
        return Err("原实例已退出或进程编号被复用，已取消交接。".into());
    }
    if parent.sid != child.sid || parent.session != child.session {
        return Err("只支持同一用户、同一登录会话的提权；原实例继续使用原配置。".into());
    }
    if parent.executable != child.executable {
        return Err("提权进程与原实例的程序路径不一致，已取消交接。".into());
    }
    if !child.elevated {
        return Err("新实例没有管理员权限，已取消交接。".into());
    }
    Ok(())
}

/// Windows command-line quoting, including trailing slashes before the closing quote.
fn quote_argument(argument: &str) -> String {
    let mut result = String::from("\"");
    let mut slashes = 0;
    for character in argument.chars() {
        if character == '\\' {
            slashes += 1;
            continue;
        }
        if character == '"' {
            result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
        } else {
            result.extend(std::iter::repeat_n('\\', slashes));
        }
        slashes = 0;
        result.push(character);
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    ParentOwns,
    Prepared,
    Released,
    Ready,
    Committed,
    Aborting,
    ChildExited,
    Recovered,
}

struct Transfer {
    phase: Phase,
}
impl Transfer {
    fn new() -> Self {
        Self {
            phase: Phase::ParentOwns,
        }
    }
    fn advance(&mut self, next: Phase) -> Result<(), String> {
        let valid = matches!(
            (self.phase, next),
            (Phase::ParentOwns, Phase::Prepared)
                | (Phase::Prepared, Phase::Released)
                | (Phase::Released, Phase::Ready)
                | (Phase::Ready, Phase::Committed)
                | (
                    Phase::ParentOwns | Phase::Prepared | Phase::Released | Phase::Ready,
                    Phase::Aborting
                )
                | (Phase::Aborting, Phase::ChildExited)
                | (Phase::ChildExited, Phase::Recovered)
        );
        if !valid {
            return Err("交接状态已改变，已阻止不安全的实例接管。".into());
        }
        self.phase = next;
        Ok(())
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::mem::size_of;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    use windows::Win32::Foundation::{
        CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_ALREADY_EXISTS, FILETIME,
        GetLastError, HANDLE, HLOCAL, LocalFree, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SDDL_REVISION_1,
    };
    use windows::Win32::Security::{
        GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_ELEVATION,
        TOKEN_QUERY, TOKEN_USER, TokenElevation, TokenSessionId, TokenUser,
    };
    use windows::Win32::Storage::FileSystem::{FILE_NAME_NORMALIZED, GetFinalPathNameByHandleW};
    use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
    use windows::Win32::System::Threading::{
        CreateEventW, EVENT_MODIFY_STATE, GetCurrentProcess, GetProcessTimes, OpenEventW,
        OpenProcess, OpenProcessToken, PROCESS_DUP_HANDLE, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, QueryFullProcessImageNameW,
        SYNCHRONIZATION_SYNCHRONIZE, SetEvent, WaitForSingleObject,
    };
    use windows::Win32::UI::Shell::{
        SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
        ShellExecuteExW,
    };
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
    use windows::core::{PCWSTR, PWSTR, w};

    const PREPARE_TIMEOUT: Duration = Duration::from_secs(15);
    const READY_TIMEOUT: Duration = Duration::from_secs(20);
    const ACK_TIMEOUT: Duration = Duration::from_secs(10);
    const EXIT_TIMEOUT: Duration = Duration::from_secs(5);

    struct Handle(HANDLE);
    // Kernel handles remain valid across threads while their owning Arc is alive.
    unsafe impl Send for Handle {}
    unsafe impl Sync for Handle {}
    impl Drop for Handle {
        fn drop(&mut self) {
            let _ = unsafe { CloseHandle(self.0) };
        }
    }

    struct LocalAllocation(*mut core::ffi::c_void);
    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            let _ = unsafe { LocalFree(Some(HLOCAL(self.0))) };
        }
    }

    struct Events {
        prepared: Handle,
        go: Handle,
        ready: Handle,
        abort: Handle,
        ack: Handle,
    }

    impl Events {
        fn create(nonce: &str, sid: &str) -> Result<Self, String> {
            let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR(sddl.as_ptr()),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    None,
                )
            }
            .map_err(|e| format!("无法保护交接通信：{e}"))?;
            let _allocation = LocalAllocation(descriptor.0);
            let attributes = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: false.into(),
            };
            let create = |suffix: &str| -> Result<Handle, String> {
                let name = event_name(nonce, suffix);
                let handle =
                    unsafe { CreateEventW(Some(&attributes), true, false, PCWSTR(name.as_ptr())) }
                        .map_err(|e| format!("无法创建交接通信：{e}"))?;
                let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
                let handle = Handle(handle);
                if existed {
                    return Err("交接会话标识已被占用，请重试。".into());
                }
                Ok(handle)
            };
            Ok(Self {
                prepared: create("prepared")?,
                go: create("go")?,
                ready: create("ready")?,
                abort: create("abort")?,
                ack: create("ack")?,
            })
        }

        fn open(nonce: &str) -> Result<Self, String> {
            let open = |suffix: &str| -> Result<Handle, String> {
                let name = event_name(nonce, suffix);
                unsafe {
                    OpenEventW(
                        EVENT_MODIFY_STATE | SYNCHRONIZATION_SYNCHRONIZE,
                        false,
                        PCWSTR(name.as_ptr()),
                    )
                }
                .map(Handle)
                .map_err(|e| format!("交接会话不存在或无权访问：{e}"))
            };
            Ok(Self {
                prepared: open("prepared")?,
                go: open("go")?,
                ready: open("ready")?,
                abort: open("abort")?,
                ack: open("ack")?,
            })
        }
    }

    fn event_name(nonce: &str, suffix: &str) -> Vec<u16> {
        format!("Local\\ScreenPin.Handoff.{nonce}.{suffix}")
            .encode_utf16()
            .chain(Some(0))
            .collect()
    }

    fn signal(handle: &Handle) -> Result<(), String> {
        unsafe { SetEvent(handle.0) }.map_err(|e| format!("无法发送交接状态：{e}"))
    }

    fn signaled(handle: &Handle) -> Result<bool, String> {
        match unsafe { WaitForSingleObject(handle.0, 0) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err("无法确认交接进程状态。".into()),
        }
    }

    fn wait_event(
        event: &Handle,
        peer: &Handle,
        abort: &Handle,
        timeout: Duration,
        context: &str,
    ) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        loop {
            if signaled(abort)? {
                return Err("实例交接已取消。".into());
            }
            // An exited peer cannot complete ownership transfer, even if it left a signal.
            if signaled(peer)? {
                return Err(format!("{context}：另一实例已退出。"));
            }
            if signaled(event)? {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(format!("{context}超时，已取消交接。"));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn process_identity(process: HANDLE) -> Result<Identity, String> {
        let mut token = HANDLE::default();
        unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) }
            .map_err(|e| format!("无法核实实例账号：{e}"))?;
        let token = Handle(token);
        let mut required = 0;
        let _ = unsafe { GetTokenInformation(token.0, TokenUser, None, 0, &mut required) };
        if required == 0 || required > 64 * 1024 {
            return Err("无法核实实例用户身份。".into());
        }
        // u64 storage supplies native alignment for TOKEN_USER and its SID pointer.
        let mut user = vec![0u64; (required as usize).div_ceil(size_of::<u64>())];
        unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                Some(user.as_mut_ptr().cast()),
                required,
                &mut required,
            )
        }
        .map_err(|e| format!("无法核实实例用户身份：{e}"))?;
        let token_user = unsafe { &*user.as_ptr().cast::<TOKEN_USER>() };
        let mut sid_text = PWSTR::null();
        unsafe { ConvertSidToStringSidW(token_user.User.Sid, &mut sid_text) }
            .map_err(|e| format!("无法读取实例账号：{e}"))?;
        let _sid_allocation = LocalAllocation(sid_text.0.cast());
        let sid = unsafe { sid_text.to_string() }.map_err(|e| e.to_string())?;
        let mut session = 0u32;
        unsafe {
            GetTokenInformation(
                token.0,
                TokenSessionId,
                Some((&mut session as *mut u32).cast()),
                size_of::<u32>() as u32,
                &mut required,
            )
        }
        .map_err(|e| format!("无法核实实例会话：{e}"))?;
        let mut elevation = TOKEN_ELEVATION::default();
        unsafe {
            GetTokenInformation(
                token.0,
                TokenElevation,
                Some((&mut elevation as *mut TOKEN_ELEVATION).cast()),
                size_of::<TOKEN_ELEVATION>() as u32,
                &mut required,
            )
        }
        .map_err(|e| format!("无法核实提权状态：{e}"))?;
        let mut created = FILETIME::default();
        let mut exited = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user_time = FILETIME::default();
        unsafe {
            GetProcessTimes(
                process,
                &mut created,
                &mut exited,
                &mut kernel,
                &mut user_time,
            )
        }
        .map_err(|e| format!("无法核实实例进程身份：{e}"))?;
        let started = (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime);
        let mut path = vec![0u16; 32_768];
        let mut length = path.len() as u32;
        unsafe {
            QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut length,
            )
        }
        .map_err(|e| format!("无法核实实例程序路径：{e}"))?;
        let path = std::path::PathBuf::from(
            String::from_utf16(&path[..length as usize]).map_err(|e| e.to_string())?,
        );
        let executable =
            std::fs::canonicalize(path).map_err(|e| format!("无法核实实例程序文件：{e}"))?;
        Ok(Identity {
            sid,
            session,
            started,
            executable,
            elevated: elevation.TokenIsElevated != 0,
        })
    }

    fn launch_child(args: &HandoffArgs, directory: &Path) -> Result<Handle, String> {
        let executable = std::env::current_exe().map_err(|e| e.to_string())?;
        let executable: Vec<u16> = executable
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let directory = directory
            .to_str()
            .ok_or("配置目录包含无法表示的字符，无法安全交接。")?;
        let parameters = format!(
            "--config-dir {} --handoff-parent-pid {} --handoff-parent-started {} --handoff-nonce {} --handoff-reservation-handle {}",
            quote_argument(directory),
            args.parent_pid,
            args.parent_started,
            args.nonce,
            args.reservation_handle
        );
        let parameters: Vec<u16> = parameters.encode_utf16().chain(Some(0)).collect();
        let mut info = SHELLEXECUTEINFOW {
            cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            lpVerb: w!("runas"),
            lpFile: PCWSTR(executable.as_ptr()),
            lpParameters: PCWSTR(parameters.as_ptr()),
            nShow: SW_HIDE.0,
            ..Default::default()
        };
        let com = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        let result = unsafe { ShellExecuteExW(&mut info) };
        if com.is_ok() {
            unsafe { CoUninitialize() };
        }
        result.map_err(|e| format!("未完成管理员启动（可能取消了 UAC）：{e}"))?;
        if info.hProcess.is_invalid() {
            return Err("管理员进程没有返回可核实的进程句柄。".into());
        }
        Ok(Handle(info.hProcess))
    }

    pub(super) fn restart_elevated(store: &mut crate::store::ConfigStore) -> Result<(), String> {
        let parent_identity = process_identity(unsafe { GetCurrentProcess() })?;
        if parent_identity.elevated {
            return Err("当前实例已经以管理员身份运行。".into());
        }
        let args = HandoffArgs {
            parent_pid: std::process::id(),
            parent_started: parent_identity.started,
            nonce: crate::model::next_id(),
            reservation_handle: store.reservation_handle(),
        };
        let events = Events::create(&args.nonce, &parent_identity.sid)?;
        let child = launch_child(&args, store.directory())?;
        let mut transfer = Transfer::new();
        let mut hotkeys_suspended = false;
        let mut writer_released = false;
        let result: Result<(), String> = (|| {
            wait_event(
                &events.prepared,
                &child,
                &events.abort,
                PREPARE_TIMEOUT,
                "等待管理员实例准备",
            )?;
            let child_identity = process_identity(child.0)?;
            validate_identity(&parent_identity, &child_identity, args.parent_started)?;
            transfer.advance(Phase::Prepared)?;
            // Suspend hotkeys before relinquishing the only configuration writer.
            hotkeys_suspended = true;
            crate::shell::suspend_hotkeys_for_handoff()?;
            store.release_for_handoff()?;
            writer_released = true;
            transfer.advance(Phase::Released)?;
            signal(&events.go)?;
            wait_event(
                &events.ready,
                &child,
                &events.abort,
                READY_TIMEOUT,
                "等待管理员实例接管",
            )?;
            transfer.advance(Phase::Ready)?;
            signal(&events.ack)?;
            transfer.advance(Phase::Committed)?;
            Ok(())
        })();
        if result.is_ok() {
            return Ok(());
        }
        let reason = result.unwrap_err();
        transfer.advance(Phase::Aborting)?;
        let _ = signal(&events.abort);
        // The elevated child's independent watchdog observes abort even during startup.
        // Never restore writer/hotkeys merely because a wait timed out.
        if unsafe { WaitForSingleObject(child.0, EXIT_TIMEOUT.as_millis() as u32) } != WAIT_OBJECT_0
        {
            if !writer_released && !hotkeys_suspended {
                return Err(format!(
                    "{reason} 新实例尚未确认退出；原实例保留配置写入权与热键，继续可用。"
                ));
            }
            return Err(format!(
                "{reason} 新实例尚未确认退出，原实例暂不恢复写入与热键；请关闭管理员实例后重新启动。"
            ));
        }
        transfer.advance(Phase::ChildExited)?;
        if writer_released {
            store
                .resume_after_handoff()
                .map_err(|e| format!("{reason} 新实例已退出，但恢复配置锁失败：{e}"))?;
        }
        if hotkeys_suspended {
            crate::shell::resume_hotkeys_after_failed_handoff()
                .map_err(|e| format!("{reason} 配置已保留，但恢复热键失败：{e}"))?;
        }
        transfer.advance(Phase::Recovered)?;
        Err(format!("{reason} 原实例已恢复。"))
    }

    struct ChildContext {
        events: Events,
        parent: Handle,
        armed: AtomicBool,
        reservation: std::fs::File,
        directory: std::path::PathBuf,
    }

    static CHILD: OnceLock<Mutex<Option<Arc<ChildContext>>>> = OnceLock::new();

    fn duplicate_reservation(
        parent: HANDLE,
        source: usize,
        directory: &Path,
    ) -> Result<std::fs::File, String> {
        let mut target = HANDLE::default();
        unsafe {
            DuplicateHandle(
                parent,
                HANDLE(source as *mut _),
                GetCurrentProcess(),
                &mut target,
                0,
                false,
                DUPLICATE_SAME_ACCESS,
            )
        }
        .map_err(|e| format!("无法接收原实例启动权：{e}"))?;
        // The duplicated file object preserves the original exclusive share
        // reservation until both parent and child close their own handle.
        let file = unsafe { std::fs::File::from_raw_handle(target.0) };
        let mut path = vec![0u16; 32_768];
        let length = unsafe {
            GetFinalPathNameByHandleW(
                HANDLE(file.as_raw_handle()),
                &mut path,
                FILE_NAME_NORMALIZED,
            )
        } as usize;
        if length == 0 || length >= path.len() || !file.metadata().is_ok_and(|m| m.is_file()) {
            return Err("无法核实交接启动权文件。".into());
        }
        let actual = std::path::PathBuf::from(
            String::from_utf16(&path[..length]).map_err(|e| e.to_string())?,
        );
        let actual_directory = actual
            .parent()
            .ok_or("启动权文件路径无效。")?
            .canonicalize()
            .map_err(|e| e.to_string())?;
        let expected_directory = directory.canonicalize().map_err(|e| e.to_string())?;
        if actual.file_name() != Some(std::ffi::OsStr::new("launch.lock"))
            || actual_directory != expected_directory
        {
            return Err("交接启动权不属于原实例配置目录，已取消接管。".into());
        }
        Ok(file)
    }

    pub(super) fn authenticated_reservation(
        directory: &Path,
    ) -> Result<Option<std::fs::File>, String> {
        let Some(state) = CHILD.get() else {
            return Ok(None);
        };
        let context = state.lock().map_err(|_| "交接身份状态不可用。")?;
        let Some(context) = context.as_ref() else {
            return Ok(None);
        };
        if directory.canonicalize().map_err(|e| e.to_string())? != context.directory {
            return Err("交接后配置目录已改变，已阻止启动。".into());
        }
        context
            .reservation
            .try_clone()
            .map(Some)
            .map_err(|e| format!("无法保留交接启动权：{e}"))
    }

    #[cfg(test)]
    pub(super) fn duplicate_reservation_for_test(
        parent_pid: u32,
        source: usize,
        directory: &Path,
    ) -> Result<std::fs::File, String> {
        let parent = Handle(
            unsafe { OpenProcess(PROCESS_DUP_HANDLE, false, parent_pid) }
                .map_err(|e| e.to_string())?,
        );
        duplicate_reservation(parent.0, source, directory)
    }

    pub(super) fn is_preparing_child() -> bool {
        let Some(state) = CHILD.get() else {
            return false;
        };
        match state.lock() {
            Ok(context) => context
                .as_ref()
                .is_some_and(|context| context.armed.load(Ordering::Acquire)),
            // A broken handoff state must never grant configuration write access.
            Err(_) => true,
        }
    }

    pub(super) fn prepare_child(args: &[String], config_directory: &Path) -> Result<(), String> {
        let Some(args) = HandoffArgs::parse(args)? else {
            return Ok(());
        };
        // Verify the actual opened process, not just the numeric PID supplied on the command line.
        let parent = Handle(
            unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE | PROCESS_DUP_HANDLE,
                    false,
                    args.parent_pid,
                )
            }
            .map_err(|e| format!("原实例已退出或无法核实身份：{e}"))?,
        );
        let parent_identity = process_identity(parent.0)?;
        let child_identity = process_identity(unsafe { GetCurrentProcess() })?;
        validate_identity(&parent_identity, &child_identity, args.parent_started)?;
        // Refuse a changed config location before acquiring or writing its files.
        if !config_directory.is_absolute() || !config_directory.is_dir() {
            return Err("原实例配置目录无效，已取消交接。".into());
        }
        let reservation =
            duplicate_reservation(parent.0, args.reservation_handle, config_directory)?;
        let events = Events::open(&args.nonce)?;
        let context = Arc::new(ChildContext {
            events,
            parent,
            armed: AtomicBool::new(true),
            reservation,
            directory: config_directory.canonicalize().map_err(|e| e.to_string())?,
        });
        let state = CHILD.get_or_init(|| Mutex::new(None));
        let mut slot = state.lock().map_err(|_| "交接状态不可用。")?;
        if slot.is_some() {
            return Err("交接准备已执行，不能重复接管。".into());
        }
        *slot = Some(context.clone());
        drop(slot);
        let watchdog = context.clone();
        std::thread::Builder::new()
            .name("handoff-watchdog".into())
            .spawn(move || {
                while watchdog.armed.load(Ordering::Acquire) {
                    // Ack wins over parent exit: the parent may exit immediately after committing.
                    if signaled(&watchdog.events.ack).unwrap_or(false) {
                        watchdog.armed.store(false, Ordering::Release);
                        return;
                    }
                    if signaled(&watchdog.events.abort).unwrap_or(true)
                        || signaled(&watchdog.parent).unwrap_or(true)
                    {
                        std::process::exit(3);
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
            .map_err(|e| format!("无法准备交接回退监控：{e}"))?;
        signal(&context.events.prepared)?;
        wait_event(
            &context.events.go,
            &context.parent,
            &context.events.abort,
            PREPARE_TIMEOUT,
            "等待原实例交出配置",
        )?;
        // The caller may now open ConfigStore; its exclusive lock remains authoritative.
        Ok(())
    }

    pub(super) fn confirm_ready(hotkeys_ready: bool) -> Result<(), String> {
        let Some(state) = CHILD.get() else {
            return Ok(());
        };
        let context = state.lock().map_err(|_| "交接状态不可用。")?.clone();
        let Some(context) = context else {
            return Ok(());
        };
        if !hotkeys_ready {
            return Err("管理员实例未能注册全部已保存热键，已取消接管。".into());
        }
        signal(&context.events.ready)?;
        let deadline = Instant::now() + ACK_TIMEOUT;
        loop {
            // Parent may exit as soon as ack is signaled, so check ack first.
            if signaled(&context.events.ack)? {
                context.armed.store(false, Ordering::Release);
                return Ok(());
            }
            if signaled(&context.events.abort)? || signaled(&context.parent)? {
                return Err("原实例取消交接或已退出，管理员实例停止接管。".into());
            }
            if Instant::now() >= deadline {
                return Err("未收到原实例的接管确认，管理员实例停止接管。".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(windows)]
pub fn restart_elevated(store: &mut crate::store::ConfigStore) -> Result<(), String> {
    platform::restart_elevated(store)
}

#[cfg(windows)]
pub fn prepare_child(args: &[String], config_directory: &Path) -> Result<(), String> {
    platform::prepare_child(args, config_directory)
}

#[cfg(windows)]
pub fn confirm_ready(hotkeys_ready: bool) -> Result<(), String> {
    platform::confirm_ready(hotkeys_ready)
}

#[cfg(windows)]
pub(crate) fn authenticated_reservation(directory: &Path) -> Result<Option<std::fs::File>, String> {
    platform::authenticated_reservation(directory)
}

#[cfg(all(windows, test))]
pub(crate) fn duplicate_reservation_for_test(
    parent_pid: u32,
    source: usize,
    directory: &Path,
) -> Result<std::fs::File, String> {
    platform::duplicate_reservation_for_test(parent_pid, source, directory)
}

/// A handoff child cannot persist configuration until the parent has acknowledged takeover.
/// This also protects startup topology refreshes that run before the shell is ready.
pub fn is_preparing_child() -> bool {
    #[cfg(windows)]
    {
        platform::is_preparing_child()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[cfg(test)]
#[path = "lifecycle_tests.rs"]
mod tests;
