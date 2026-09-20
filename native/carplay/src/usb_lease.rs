//! Fixed administrator-authorized USB configuration lease. No arbitrary command.
use std::{io, os::unix::fs::MetadataExt, path::Path, process::Stdio, time::Duration};
use tokio::{
    process::{Child, Command},
    time::timeout,
};

const HELPER: &str = "/usr/local/libexec/argo-carplay-usb-lease";

pub struct UsbLease(Child);
impl UsbLease {
    /// Startup never prompts an unattended desktop. Explicit Connect may prompt.
    pub async fn authorized() -> io::Result<bool> {
        let status = timeout(
            Duration::from_secs(3),
            Command::new("/usr/bin/pkcheck")
                .args([
                    "--action-id",
                    "dev.argo.carplay.usb-lease",
                    "--process",
                    &std::process::id().to_string(),
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .status(),
        )
        .await
        .map_err(|_| io::Error::other("USB authorization check timed out"))??;
        Ok(status.success())
    }
    pub fn start() -> io::Result<Self> {
        for path in [Path::new(HELPER), Path::new("/usr/local/libexec")] {
            let metadata = std::fs::symlink_metadata(path)?;
            if metadata.uid() != 0
                || metadata.mode() & 0o022 != 0
                || (path == Path::new(HELPER) && !metadata.is_file())
                || (path != Path::new(HELPER) && !metadata.is_dir())
            {
                return Err(io::Error::other(
                    "USB lease helper must be installed and owned by root",
                ));
            }
        }
        let child = Command::new("/usr/bin/pkexec")
            .args([
                HELPER,
                "--owner-pid",
                &std::process::id().to_string(),
                "--watch-stdin",
            ])
            .stdin(Stdio::piped())
            // On parent exit the pipe closes; SIGKILL would prevent restoration.
            .kill_on_drop(false)
            .spawn()?;
        Ok(Self(child))
    }
    pub async fn ended(&mut self) -> io::Result<std::process::ExitStatus> {
        // Child::wait closes stdin; that would release a live lease. Poll exit
        // without consuming the control pipe until release() is requested.
        loop {
            if let Some(status) = self.0.try_wait()? {
                return Ok(status);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    pub async fn release(&mut self) -> io::Result<()> {
        drop(self.0.stdin.take());
        let status = timeout(Duration::from_secs(2), self.0.wait())
            .await
            .map_err(|_| io::Error::other("USB lease restoration not confirmed"))??;
        if !status.success() {
            return Err(io::Error::other("USB lease helper failed"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn monitoring_does_not_close_the_lease_control_pipe() {
        let child = Command::new("/bin/sh")
            .args(["-c", "cat >/dev/null"])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        let mut lease = UsbLease(child);
        assert!(
            timeout(Duration::from_millis(150), lease.ended())
                .await
                .is_err()
        );
        assert!(lease.0.try_wait().unwrap().is_none());
        lease.release().await.unwrap();
        assert!(lease.0.try_wait().unwrap().unwrap().success());
    }
}
