//! Desktop-user microphone exclusion shared by Argo's native daemons.
//! The lock remains on disk; unlinking it would permit two independent owners.
use std::{
    fs::{File, OpenOptions},
    io,
    os::unix::fs::FileExt,
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawFd,
    },
    path::Path,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner { CarPlay, AndroidAuto, BluetoothCall, LocalAssistant, Unknown }
impl Owner {
    pub fn code(self) -> &'static str {
        match self { Self::CarPlay => "owned-by-carplay", Self::AndroidAuto => "owned-by-android-auto", Self::BluetoothCall => "owned-by-bluetooth-call", Self::LocalAssistant => "owned-by-local-assistant", Self::Unknown => "unavailable" }
    }
    fn parse(bytes: &[u8]) -> Self {
        [Self::CarPlay, Self::AndroidAuto, Self::BluetoothCall, Self::LocalAssistant].into_iter().find(|v| v.code().as_bytes() == bytes).unwrap_or(Self::Unknown)
    }
}
/// Read-only advisory state. Actual acquisition always uses the exclusion lock.
pub fn state() -> &'static str {
    let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") else { return "unavailable"; };
    state_in(Path::new(&runtime))
}
fn state_in(runtime: &Path) -> &'static str {
    let Ok(directory) = runtime.symlink_metadata() else { return "unavailable"; };
    if !runtime.is_absolute() || !directory.is_dir() || directory.uid() != unsafe { libc::geteuid() } || directory.mode() & 0o077 != 0 { return "failed"; }
    let file = match OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(runtime.join("argo-microphone.lock")) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return "available",
        Err(_) => return "failed",
    };
    let Ok(metadata) = file.metadata() else { return "failed"; };
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } || metadata.nlink() != 1 || metadata.mode() & 0o077 != 0 { return "failed"; }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 { return "available"; }
    if io::Error::last_os_error().raw_os_error() != Some(libc::EWOULDBLOCK) { return "failed"; }
    let mut data = [0; 64];
    match file.read_at(&mut data, 0) { Ok(n) => Owner::parse(&data[..n]).code(), Err(_) => "failed" }
}

pub struct MicrophoneLease {
    _file: File,
}
impl MicrophoneLease {
    pub fn acquire() -> io::Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or_else(|| io::Error::other("Microphone ownership requires XDG_RUNTIME_DIR"))?;
        Self::in_runtime_for(Path::new(&runtime), Owner::Unknown)
    }
    pub fn acquire_for(owner: Owner) -> io::Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| io::Error::other("Microphone ownership requires XDG_RUNTIME_DIR"))?;
        Self::in_runtime_for(Path::new(&runtime), owner)
    }
    #[cfg(test)]
    fn in_runtime(runtime: &Path) -> io::Result<Self> { Self::in_runtime_for(runtime, Owner::Unknown) }
    fn in_runtime_for(runtime: &Path, owner: Owner) -> io::Result<Self> {
        let uid = unsafe { libc::geteuid() };
        let metadata = runtime.symlink_metadata()?;
        if !runtime.is_absolute()
            || !metadata.is_dir()
            || metadata.uid() != uid
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::other(
                "Microphone runtime must be a private owned directory",
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(runtime.join("argo-microphone.lock"))?;
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != uid
            || metadata.nlink() != 1
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::other("Invalid microphone ownership file"));
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other(
                format!("Microphone contention: {}. Stop that voice session before retrying.", state_in(runtime)),
            ));
        }
        file.set_len(0)?;
        file.write_all_at(owner.code().as_bytes(), 0)?;
        Ok(Self { _file: file })
    }
    /// Retain exclusion until process exit if capture cleanup cannot be proven.
    pub fn poison(self) {
        std::mem::forget(self);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    #[test]
    fn exclusive_acquisition_release_and_unsafe_paths() {
        let root = std::env::temp_dir().join(format!(
            "argo-mic-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let first = MicrophoneLease::in_runtime_for(&root, Owner::BluetoothCall).unwrap();
        assert_eq!(state_in(&root), "owned-by-bluetooth-call");
        assert!(MicrophoneLease::in_runtime(&root).is_err());
        drop(first);
        assert_eq!(state_in(&root), "available");
        drop(MicrophoneLease::in_runtime(&root).unwrap());
        let lock = root.join("argo-microphone.lock");
        std::fs::remove_file(&lock).unwrap();
        symlink("/dev/null", &lock).unwrap();
        assert!(MicrophoneLease::in_runtime(&root).is_err());
        std::fs::remove_file(&lock).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(MicrophoneLease::in_runtime(&root).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
