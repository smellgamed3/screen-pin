use crate::model::Config;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_ID: AtomicU64 = AtomicU64::new(0);
const MAX_CONFIG_BYTES: usize = 8 * 1024 * 1024;

pub enum LoadState {
    New(Config),
    Ready(Config),
    ReadOnly {
        reason: String,
        backup: Option<Config>,
    },
}

pub struct ConfigStore {
    directory: PathBuf,
    writable: bool,
    lock: Option<File>,
    // Held for the whole instance lifetime, including writer handoff. An
    // authenticated child duplicates this same file object before parent exit.
    reservation: File,
}

impl ConfigStore {
    pub fn open(directory: PathBuf) -> Result<(Self, LoadState), String> {
        fs::create_dir_all(&directory).map_err(|e| format!("无法创建配置目录：{e}"))?;
        #[cfg(windows)]
        let reservation = match crate::lifecycle::authenticated_reservation(&directory)? {
            Some(reservation) => reservation,
            None => acquire_reservation(&directory)?,
        };
        #[cfg(not(windows))]
        let reservation = acquire_reservation(&directory)?;
        Self::open_reserved(directory, reservation)
    }

    // Private: production callers can only arrive through normal reservation
    // acquisition or the already-authenticated lifecycle child context above.
    fn open_reserved(directory: PathBuf, reservation: File) -> Result<(Self, LoadState), String> {
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        let lock = options
            .open(directory.join("instance.lock"))
            .map_err(|e| format!("配置正在被其他实例使用，或目录不可写：{e}"))?;
        let mut store = Self {
            directory,
            writable: true,
            lock: Some(lock),
            reservation,
        };
        let state = if !store.path().exists() {
            LoadState::New(Config::default())
        } else {
            match read_config(&store.path()) {
                Ok(config) => LoadState::Ready(config),
                Err(reason) => {
                    store.writable = false;
                    LoadState::ReadOnly {
                        reason,
                        backup: read_config(&store.backup_path()).ok(),
                    }
                }
            }
        };
        Ok((store, state))
    }

    pub fn path(&self) -> PathBuf {
        self.directory.join("config.json")
    }
    pub fn backup_path(&self) -> PathBuf {
        self.directory.join("config.backup.json")
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    pub fn is_writable(&self) -> bool {
        self.writable && self.lock.is_some()
    }

    #[cfg(windows)]
    pub(crate) fn reservation_handle(&self) -> usize {
        use std::os::windows::io::AsRawHandle;
        self.reservation.as_raw_handle() as usize
    }

    pub fn release_for_handoff(&mut self) -> Result<(), String> {
        if self.lock.take().is_none() {
            return Err("当前实例没有配置写入权".into());
        }
        Ok(())
    }

    pub fn resume_after_handoff(&mut self) -> Result<(), String> {
        if self.lock.is_some() {
            return Ok(());
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        self.lock = Some(
            options
                .open(self.directory.join("instance.lock"))
                .map_err(|e| format!("未能重新取得唯一配置写入权：{e}"))?,
        );
        Ok(())
    }

    pub fn save(&mut self, config: &Config) -> Result<(), String> {
        #[cfg(windows)]
        if crate::lifecycle::is_preparing_child() {
            return Err("管理员实例交接尚未确认，初始化期间不写入配置".into());
        }
        if !self.is_writable() {
            return Err("配置处于保护状态，请先恢复备份或明确新建配置".into());
        }
        config.validate()?;
        let data = encode_config(config)?;
        let primary = self.path();
        if primary.exists() {
            // Only a validated, supported configuration can replace the last good backup.
            let (_, bytes) = read_config_snapshot(&primary)?;
            replace_file(&self.backup_path(), &bytes)?;
        }
        replace_file(&primary, &data)
    }

    pub fn recover_backup(&mut self) -> Result<Config, String> {
        let (backup, bytes) = read_config_snapshot(&self.backup_path())?;
        self.replace_protected(&backup, &bytes)?;
        Ok(backup)
    }

    pub fn reset_explicitly(&mut self) -> Result<Config, String> {
        let config = Config::default();
        let bytes = encode_config(&config)?;
        self.replace_protected(&config, &bytes)?;
        Ok(config)
    }

    fn replace_protected(&mut self, config: &Config, bytes: &[u8]) -> Result<(), String> {
        // Recovery may bypass the damaged-config flag, but never the writer lock.
        // A failed handoff can leave this parent alive without ownership while
        // another process still owns the same configuration directory.
        if self.lock.is_none() {
            return Err("当前实例未持有唯一配置写入权，不能恢复或新建配置".into());
        }
        #[cfg(windows)]
        if crate::lifecycle::is_preparing_child() {
            return Err("管理员实例交接尚未确认，暂不能替换配置".into());
        }
        config.validate()?;
        if bytes.len() > MAX_CONFIG_BYTES {
            return Err("配置超过 8 MiB，未保存；请减少配置内容后重试。".into());
        }
        if self.path().exists() {
            self.preserve_rejected_original()?;
        }
        replace_file(&self.path(), bytes)?;
        self.writable = true;
        Ok(())
    }

    fn preserve_rejected_original(&self) -> Result<(), String> {
        // A PID may be reused after a previous run. Never replace an existing
        // preserved original, even when the process-local counter restarts.
        for _ in 0..128 {
            let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let preserved = self
                .directory
                .join(format!("config.preserved-{}-{id}.json", std::process::id()));
            match preserve_original(&self.path(), &preserved) {
                Ok(()) => return Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(format!("无法保留原配置：{error}")),
            }
        }
        Err("无法保留原配置：已有保留文件名冲突过多，请重试；原件保持不变".into())
    }
}

fn preserve_original(source: &Path, destination: &Path) -> std::io::Result<()> {
    let mut source = File::open(source)?;
    let mut destination = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?;
    std::io::copy(&mut source, &mut destination)?;
    destination.sync_all()
}

fn acquire_reservation(directory: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0);
    }
    options
        .open(directory.join("launch.lock"))
        .map_err(|e| format!("已有实例正在启动、运行或交接，当前配置的启动权暂不可用：{e}"))
}

fn read_config(path: &Path) -> Result<Config, String> {
    let file = File::open(path).map_err(|e| format!("无法读取 {}：{e}", path.display()))?;
    // Refuse oversized or future files before deserializing into a narrower schema.
    if file.metadata().map_err(|e| e.to_string())?.len() > MAX_CONFIG_BYTES as u64 {
        return Err("配置超过 8 MiB，已暂停写入以保留原文件".into());
    }
    decode_config(file)
}

fn read_config_snapshot(path: &Path) -> Result<(Config, Vec<u8>), String> {
    let file = File::open(path).map_err(|e| format!("无法读取 {}：{e}", path.display()))?;
    if file.metadata().map_err(|e| e.to_string())?.len() > MAX_CONFIG_BYTES as u64 {
        return Err("配置超过 8 MiB，已暂停写入以保留原文件".into());
    }
    // Validate the same bounded bytes that will be copied, including a file
    // which grows after metadata was read. Never reformat a valid backup.
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("无法读取 {}：{e}", path.display()))?;
    if bytes.len() > MAX_CONFIG_BYTES {
        return Err("配置超过 8 MiB，已暂停写入以保留原文件".into());
    }
    let config = decode_config(bytes.as_slice())?;
    Ok((config, bytes))
}

fn encode_config(config: &Config) -> Result<Vec<u8>, String> {
    struct LimitedBuffer {
        bytes: Vec<u8>,
        exceeded: bool,
    }
    impl Write for LimitedBuffer {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > MAX_CONFIG_BYTES - self.bytes.len() {
                self.exceeded = true;
                return Err(std::io::Error::other("configuration size limit"));
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut output = LimitedBuffer {
        bytes: Vec::new(),
        exceeded: false,
    };
    match serde_json::to_writer_pretty(&mut output, config) {
        Ok(()) => return Ok(output.bytes),
        Err(error) if !output.exceeded => return Err(error.to_string()),
        Err(_) => {}
    }
    // Formatting alone must not make an otherwise supported config unwritable.
    // Reuse the bounded allocation and retain every field in compact JSON.
    output.bytes.clear();
    output.exceeded = false;
    if let Err(error) = serde_json::to_writer(&mut output, config) {
        return Err(if output.exceeded {
            "配置超过 8 MiB，未保存；请减少配置内容后重试。".into()
        } else {
            error.to_string()
        });
    }
    Ok(output.bytes)
}

fn decode_config(reader: impl Read) -> Result<Config, String> {
    // serde_json does not buffer Read: a bare File causes one OS read per byte.
    // Buffer before decoding so supported large files do not stall startup.
    let value: serde_json::Value = serde_json::from_reader(BufReader::new(reader))
        .map_err(|e| format!("配置 JSON 损坏：{e}"))?;
    let version = value
        .get("schema_version")
        .and_then(|v| v.as_u64())
        .ok_or("配置缺少有效格式版本")?;
    if version != 1 {
        return Err(format!("不支持的配置格式版本 {version}，原文件已保留"));
    }
    let config: Config = serde_json::from_value(value).map_err(|e| format!("配置字段无效：{e}"))?;
    config.validate()?;
    Ok(config)
}

fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let temporary = path.with_extension(format!("tmp-{}-{id}", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|e| format!("无法写入临时配置：{e}"))?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("无法保存配置：{e}"))?;
        drop(file);
        fs::rename(&temporary, path).map_err(|e| format!("无法替换配置，原配置保留：{e}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub fn default_directory() -> Result<PathBuf, String> {
    let local = std::env::var_os("LOCALAPPDATA").ok_or("未找到当前用户本地应用数据目录")?;
    Ok(PathBuf::from(local).join("ScreenPin"))
}

#[cfg(test)]
mod tests {
    use super::*;
    struct TestDir(PathBuf);
    impl TestDir {
        fn new() -> Self {
            let n = TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("screen-pin-store-{}-{n}", std::process::id()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn configuration_decoder_batches_underlying_file_reads() {
        struct CountedFile<'a> {
            file: File,
            calls: &'a std::cell::Cell<usize>,
        }
        impl Read for CountedFile<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                self.calls.set(self.calls.get() + 1);
                self.file.read(buffer)
            }
        }

        let dir = TestDir::new();
        let expected = Config::default();
        let mut bytes = serde_json::to_vec(&expected).unwrap();
        bytes.resize(32 * 1024, b' ');
        let path = dir.0.join("config.json");
        fs::write(&path, bytes).unwrap();
        let calls = std::cell::Cell::new(0);
        let reader = CountedFile {
            file: File::open(path).unwrap(),
            calls: &calls,
        };
        assert_eq!(decode_config(reader).unwrap(), expected);
        assert!(
            calls.get() <= 16,
            "32 KiB configuration issued {} underlying file reads",
            calls.get()
        );
    }

    #[test]
    fn write_size_rejection_preserves_existing_primary_and_backup() {
        let dir = TestDir::new();
        let (mut store, _) = ConfigStore::open(dir.0.clone()).unwrap();
        let mut saved = Config::default();
        store.save(&saved).unwrap();
        saved.revision = 1;
        store.save(&saved).unwrap();
        let primary = fs::read(store.path()).unwrap();
        let backup = fs::read(store.backup_path()).unwrap();
        let mut oversized = saved.clone();
        oversized.displays.push(crate::model::DisplayRecord {
            id: "screen".into(),
            name: "x".repeat(8 * 1024 * 1024),
            fingerprints: Vec::new(),
        });
        oversized.validate().unwrap();
        let result = store.save(&oversized);
        assert!(
            result.is_err(),
            "oversized save returned {result:?}; reload result: {:?}",
            read_config(&store.path()).err()
        );
        assert_eq!(fs::read(store.path()).unwrap(), primary);
        assert_eq!(fs::read(store.backup_path()).unwrap(), backup);
        assert_eq!(read_config(&store.path()).unwrap(), saved);
        assert!(store.is_writable());
    }

    fn compact_config_at_limit() -> Config {
        let mut config = Config::default();
        config.displays.push(crate::model::DisplayRecord {
            id: "screen".into(),
            name: "x".into(),
            fingerprints: Vec::new(),
        });
        let small = serde_json::to_vec(&config).unwrap().len();
        config.displays[0].name = "x".repeat(8 * 1024 * 1024 - small + 1);
        assert_eq!(serde_json::to_vec(&config).unwrap().len(), 8 * 1024 * 1024);
        assert!(serde_json::to_vec_pretty(&config).unwrap().len() > 8 * 1024 * 1024);
        config
    }

    #[test]
    fn write_size_accepts_compact_limit_and_keeps_backup_readable() {
        let dir = TestDir::new();
        let original = compact_config_at_limit();
        let bytes = serde_json::to_vec(&original).unwrap();
        fs::write(dir.0.join("config.json"), &bytes).unwrap();
        let (mut store, state) = ConfigStore::open(dir.0.clone()).unwrap();
        assert!(matches!(state, LoadState::Ready(_)));
        let mut changed = original.clone();
        changed.revision = 1;
        store.save(&changed).unwrap();
        assert_eq!(read_config(&store.path()).unwrap(), changed);
        assert_eq!(read_config(&store.backup_path()).unwrap(), original);
        assert_eq!(fs::read(store.backup_path()).unwrap(), bytes);
        assert!(fs::metadata(store.path()).unwrap().len() <= 8 * 1024 * 1024);
    }

    #[test]
    fn write_size_recovery_preserves_supported_compact_backup_bytes() {
        let dir = TestDir::new();
        let expected = compact_config_at_limit();
        let bytes = serde_json::to_vec(&expected).unwrap();
        fs::write(dir.0.join("config.backup.json"), &bytes).unwrap();
        fs::write(dir.0.join("config.json"), b"{truncated").unwrap();
        let (mut store, state) = ConfigStore::open(dir.0.clone()).unwrap();
        assert!(matches!(state, LoadState::ReadOnly { .. }));
        assert_eq!(store.recover_backup().unwrap(), expected);
        assert_eq!(read_config(&store.path()).unwrap(), expected);
        assert_eq!(fs::read(store.path()).unwrap(), bytes);
        assert_eq!(fs::read(store.backup_path()).unwrap(), bytes);
        assert!(store.is_writable());
        let preserved = fs::read_dir(&dir.0)
            .unwrap()
            .filter_map(Result::ok)
            .find(|p| {
                p.file_name()
                    .to_string_lossy()
                    .starts_with("config.preserved-")
            })
            .unwrap();
        assert_eq!(fs::read(preserved.path()).unwrap(), b"{truncated");
    }

    #[test]
    fn persists_and_keeps_last_valid_backup() {
        let dir = TestDir::new();
        let (mut store, state) = ConfigStore::open(dir.0.clone()).unwrap();
        assert!(matches!(state, LoadState::New(_)));
        let mut config = Config::default();
        store.save(&config).unwrap();
        config.revision += 1;
        store.save(&config).unwrap();
        assert_eq!(read_config(&store.path()).unwrap().revision, 1);
        assert_eq!(read_config(&store.backup_path()).unwrap().revision, 0);
    }

    #[test]
    fn future_format_and_corruption_never_become_empty_configuration() {
        for contents in [
            br#"{"schema_version":999,"secret_new_field":"keep"}"#.as_slice(),
            b"{broken",
        ] {
            let dir = TestDir::new();
            fs::write(dir.0.join("config.json"), contents).unwrap();
            let (mut store, state) = ConfigStore::open(dir.0.clone()).unwrap();
            assert!(matches!(state, LoadState::ReadOnly { .. }));
            assert!(store.save(&Config::default()).is_err());
            assert_eq!(fs::read(store.path()).unwrap(), contents);
        }
    }

    #[test]
    fn backup_recovery_preserves_damaged_original() {
        let dir = TestDir::new();
        fs::write(dir.0.join("config.json"), "broken").unwrap();
        let valid = Config::default();
        fs::write(
            dir.0.join("config.backup.json"),
            serde_json::to_vec(&valid).unwrap(),
        )
        .unwrap();
        let (mut store, _) = ConfigStore::open(dir.0.clone()).unwrap();
        store.recover_backup().unwrap();
        assert!(store.is_writable());
        assert_eq!(read_config(&store.path()).unwrap(), valid);
        assert!(
            fs::read_dir(&dir.0)
                .unwrap()
                .filter_map(Result::ok)
                .any(|p| p
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.preserved-"))
        );
    }

    #[test]
    fn original_preservation_never_overwrites_a_previous_recovery_copy() {
        let dir = TestDir::new();
        let source = dir.0.join("config.json");
        let preserved = dir.0.join("config.preserved-collision.json");
        fs::write(&source, b"{new damaged original").unwrap();
        fs::write(&preserved, b"older preserved original").unwrap();
        assert!(preserve_original(&source, &preserved).is_err());
        assert_eq!(fs::read(&preserved).unwrap(), b"older preserved original");
        assert_eq!(fs::read(&source).unwrap(), b"{new damaged original");
        let next = dir.0.join("config.preserved-fresh.json");
        preserve_original(&source, &next).unwrap();
        assert_eq!(fs::read(next).unwrap(), b"{new damaged original");
    }

    #[test]
    fn repeated_load_save_and_recovery_preserve_full_placement_precision() {
        let dir = TestDir::new();
        let config: Config = serde_json::from_value(serde_json::json!({
            "schema_version": 1, "revision": 0,
            "settings": crate::model::Settings::default(),
            "displays": [{"id": "screen", "name": "Test", "fingerprints": []}],
            "profiles": [{
                "id": "profile", "name": "Test", "display_ids": ["screen"],
                "applications": [{
                    "app_id": "test.exe", "app_name": "Test", "rules": [],
                    "default": {"id": "preset", "revision": 0, "placement": {
                        "display_id": "screen", "maximized": false,
                        "rect": {"x": -0.11328125, "y": 145.0 / 1392.0,
                            "width": 0.27109375, "height": 459.0 / 1392.0}
                    }}
                }]
            }]
        }))
        .unwrap();
        let (mut store, _) = ConfigStore::open(dir.0.clone()).unwrap();
        store.save(&config).unwrap();
        let original = fs::read(store.path()).unwrap();
        for _ in 0..20 {
            let loaded = read_config(&store.path()).unwrap();
            assert_eq!(loaded, config);
            store.save(&loaded).unwrap();
            assert_eq!(fs::read(store.path()).unwrap(), original);
        }
        drop(store);
        fs::write(dir.0.join("config.json"), "{truncated").unwrap();
        let (mut store, state) = ConfigStore::open(dir.0.clone()).unwrap();
        assert!(matches!(state, LoadState::ReadOnly { .. }));
        assert_eq!(store.recover_backup().unwrap(), config);
        assert_eq!(fs::read(store.path()).unwrap(), original);
    }

    #[test]
    fn denied_replacement_leaves_primary_and_removes_temporary() {
        let dir = TestDir::new();
        let (mut store, _) = ConfigStore::open(dir.0.clone()).unwrap();
        store.save(&Config::default()).unwrap();
        let original = fs::read(store.path()).unwrap();
        let mut access = OpenOptions::new();
        access.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            access.share_mode(1);
        }
        let _held = access.open(store.path()).unwrap();
        let changed = Config {
            revision: 7,
            ..Default::default()
        };
        #[cfg(windows)]
        {
            assert!(store.save(&changed).is_err());
            assert_eq!(fs::read(store.path()).unwrap(), original);
            assert!(
                !fs::read_dir(&dir.0)
                    .unwrap()
                    .filter_map(Result::ok)
                    .any(|f| f
                        .path()
                        .extension()
                        .is_some_and(|e| e.to_string_lossy().starts_with("tmp-")))
            );
        }
    }

    #[test]
    fn released_writer_cannot_reset_or_recover_while_another_writer_owns_configuration() {
        let dir = TestDir::new();
        let (mut original, _) = ConfigStore::open(dir.0.clone()).unwrap();
        let mut config = Config::default();
        original.save(&config).unwrap();
        config.revision = 1;
        original.save(&config).unwrap();
        let primary_before = fs::read(original.path()).unwrap();
        let backup_before = fs::read(original.backup_path()).unwrap();
        original.release_for_handoff().unwrap();
        // Only this private test path simulates the authenticated child's
        // duplicated reservation; a normal open must remain blocked.
        let child_reservation = original.reservation.try_clone().unwrap();
        let (current_writer, _) =
            ConfigStore::open_reserved(dir.0.clone(), child_reservation).unwrap();

        assert!(!original.is_writable());
        assert!(original.reset_explicitly().is_err());
        assert!(original.recover_backup().is_err());
        assert_eq!(fs::read(original.path()).unwrap(), primary_before);
        assert_eq!(fs::read(original.backup_path()).unwrap(), backup_before);
        assert!(
            !fs::read_dir(&dir.0)
                .unwrap()
                .filter_map(Result::ok)
                .any(|file| {
                    file.file_name()
                        .to_string_lossy()
                        .starts_with("config.preserved-")
                })
        );

        #[cfg(windows)]
        assert!(original.resume_after_handoff().is_err());
        drop(current_writer);
        original.resume_after_handoff().unwrap();
        assert_eq!(original.recover_backup().unwrap().revision, 0);
    }

    #[test]
    #[cfg(windows)]
    fn second_writer_cannot_open_same_directory() {
        let dir = TestDir::new();
        let (_store, _) = ConfigStore::open(dir.0.clone()).unwrap();
        assert!(ConfigStore::open(dir.0.clone()).is_err());
    }

    #[test]
    #[cfg(windows)]
    fn reservation_process_helper() {
        let Some(directory) = std::env::var_os("SCREEN_PIN_TEST_RESERVATION_DIR") else {
            return;
        };
        let directory = PathBuf::from(directory);
        let mode = std::env::var("SCREEN_PIN_TEST_RESERVATION_MODE").unwrap();
        let gate = directory.join(format!("ready-{}", std::process::id()));
        fs::write(gate, "ready").unwrap();
        let wait_for = |name: &str| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while !directory.join(name).exists() {
                assert!(
                    std::time::Instant::now() < deadline,
                    "helper timed out waiting for {name}"
                );
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        };
        if mode == "race" {
            wait_for("start");
        }
        let opened = if mode == "duplicate" {
            let parent = std::env::var("SCREEN_PIN_TEST_PARENT_PID")
                .unwrap()
                .parse()
                .unwrap();
            let source = std::env::var("SCREEN_PIN_TEST_RESERVATION_HANDLE")
                .unwrap()
                .parse()
                .unwrap();
            let reservation =
                crate::lifecycle::duplicate_reservation_for_test(parent, source, &directory)
                    .unwrap();
            ConfigStore::open_reserved(directory.clone(), reservation)
        } else {
            ConfigStore::open(directory.clone())
        };
        let Ok((_store, _)) = opened else {
            std::process::exit(2);
        };
        fs::write(
            directory.join(format!("acquired-{}", std::process::id())),
            "acquired",
        )
        .unwrap();
        if mode == "race" || mode == "duplicate" {
            wait_for("finish");
        }
        std::process::exit(0);
    }

    #[cfg(windows)]
    fn reservation_child(directory: &Path, mode: &str) -> std::process::Command {
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "store::tests::reservation_process_helper",
                "--nocapture",
            ])
            .env("SCREEN_PIN_TEST_RESERVATION_DIR", directory)
            .env("SCREEN_PIN_TEST_RESERVATION_MODE", mode)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        command
    }

    #[cfg(windows)]
    fn wait_for_file(path: &Path) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !path.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "missing {}",
                path.display()
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    #[cfg(windows)]
    fn third_launch_is_blocked_during_handoff_and_failed_child_leaves_parent_reservation_intact() {
        let dir = TestDir::new();
        let (mut parent, _) = ConfigStore::open(dir.0.clone()).unwrap();
        parent.release_for_handoff().unwrap();
        assert_eq!(
            reservation_child(&dir.0, "try").status().unwrap().code(),
            Some(2)
        );
        parent.resume_after_handoff().unwrap();
        assert!(parent.is_writable());
        let other = TestDir::new();
        assert_eq!(
            reservation_child(&other.0, "try").status().unwrap().code(),
            Some(0)
        );
    }

    #[test]
    #[cfg(windows)]
    fn duplicated_reservation_survives_parent_drop_and_keeps_third_process_out() {
        let dir = TestDir::new();
        let (mut parent, _) = ConfigStore::open(dir.0.clone()).unwrap();
        parent.release_for_handoff().unwrap();
        let mut child = reservation_child(&dir.0, "duplicate")
            .env("SCREEN_PIN_TEST_PARENT_PID", std::process::id().to_string())
            .env(
                "SCREEN_PIN_TEST_RESERVATION_HANDLE",
                parent.reservation_handle().to_string(),
            )
            .spawn()
            .unwrap();
        wait_for_file(&dir.0.join(format!("acquired-{}", child.id())));
        drop(parent);
        assert_eq!(
            reservation_child(&dir.0, "try").status().unwrap().code(),
            Some(2)
        );
        fs::write(dir.0.join("finish"), "finish").unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(
            reservation_child(&dir.0, "try").status().unwrap().code(),
            Some(0)
        );
    }

    #[test]
    #[cfg(windows)]
    fn concurrent_first_launches_have_exactly_one_reservation_owner() {
        let dir = TestDir::new();
        let mut first = reservation_child(&dir.0, "race").spawn().unwrap();
        let mut second = reservation_child(&dir.0, "race").spawn().unwrap();
        wait_for_file(&dir.0.join(format!("ready-{}", first.id())));
        wait_for_file(&dir.0.join(format!("ready-{}", second.id())));
        fs::write(dir.0.join("start"), "start").unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let a = first.try_wait().unwrap();
            let b = second.try_wait().unwrap();
            if let Some(exited) = a.or(b) {
                assert_eq!(exited.code(), Some(2));
                assert!(a.is_none() || b.is_none(), "both first launches failed");
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "first launch race did not settle"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        fs::write(dir.0.join("finish"), "finish").unwrap();
        let mut codes = [
            first.wait().unwrap().code().unwrap(),
            second.wait().unwrap().code().unwrap(),
        ];
        codes.sort();
        assert_eq!(codes, [0, 2]);
    }
}
