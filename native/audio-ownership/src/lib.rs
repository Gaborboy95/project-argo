//! Desktop-user microphone exclusion shared by Argo's native daemons.
//! The lock remains on disk; unlinking it would permit two independent owners.
use std::{
    fs::{File, OpenOptions},
    io,
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawFd,
    },
    path::Path,
};

pub struct MicrophoneLease {
    _file: File,
}
impl MicrophoneLease {
    pub fn acquire() -> io::Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or_else(|| io::Error::other("Microphone ownership requires XDG_RUNTIME_DIR"))?;
        Self::in_runtime(Path::new(&runtime))
    }
    fn in_runtime(runtime: &Path) -> io::Result<Self> {
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
                "Microphone is owned by another Argo voice session",
            ));
        }
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
        let first = MicrophoneLease::in_runtime(&root).unwrap();
        assert!(MicrophoneLease::in_runtime(&root).is_err());
        drop(first);
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
