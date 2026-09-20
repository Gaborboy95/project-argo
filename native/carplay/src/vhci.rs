//! Fixed polkit descriptor handover for the optional LIVI Link controller.
use std::{
    fs::File,
    io,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::{MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{net::UnixListener, process::Command, time::timeout};
const HELPER: &str = "/usr/local/libexec/argo-carplay-vhci";
struct SocketPath(PathBuf);
impl Drop for SocketPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Called only by explicitly enabled wireless operation, never by diagnostics.
pub async fn acquire() -> io::Result<File> {
    let uid = unsafe { libc::geteuid() };
    if uid == 0 {
        return Err(io::Error::other("Run CarPlay as the desktop user"));
    }
    for (path, file) in [
        (Path::new(HELPER), true),
        (Path::new("/usr/local/libexec"), false),
    ] {
        let metadata = path.symlink_metadata()?;
        if metadata.uid() != 0
            || metadata.mode() & 0o022 != 0
            || if file {
                !metadata.is_file()
            } else {
                !metadata.is_dir()
            }
        {
            return Err(io::Error::other("Install the root-owned VHCI helper first"));
        }
    }
    let directory = PathBuf::from(format!("/run/user/{uid}/argo"));
    let metadata = directory.symlink_metadata()?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::other("Invalid CarPlay runtime directory"));
    }
    let path = directory.join(format!("carplay-vhci-{}.sock", std::process::id()));
    let listener = UnixListener::bind(&path)?;
    let _path = SocketPath(path.clone());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let mut child = Command::new("/usr/bin/pkexec")
        .args([HELPER, "--owner-pid", &std::process::id().to_string()])
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let pid = child
        .id()
        .ok_or_else(|| io::Error::other("VHCI helper did not start"))?;
    eprintln!("Wireless CarPlay controller requires administrator authorization.");
    let accepted = async {
        tokio::select! {
            result = listener.accept() => result,
            status = child.wait() => {
                if !status?.success() { return Err(io::Error::other("VHCI authorization denied or helper failed")); }
                timeout(Duration::from_secs(3), listener.accept()).await.map_err(|_| io::Error::other("VHCI helper exited without handover"))?
            }
        }
    };
    let (socket, _) = timeout(Duration::from_secs(120), accepted)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "VHCI authorization timed out"))??;
    let credentials = socket.peer_cred()?;
    if credentials.uid() != 0 || credentials.pid() != Some(pid as i32) {
        return Err(io::Error::other("Unexpected VHCI descriptor sender"));
    }
    let socket = socket.into_std()?;
    socket.set_nonblocking(false)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let descriptor = tokio::task::spawn_blocking(move || receive_descriptor(&socket))
        .await
        .map_err(io::Error::other)??;
    let result = timeout(Duration::from_secs(5), child.wait())
        .await
        .map_err(|_| io::Error::other("VHCI helper did not exit"))??;
    if !result.success() {
        return Err(io::Error::other("VHCI helper failed"));
    }
    Ok(descriptor)
}

fn receive_descriptor(socket: &std::os::unix::net::UnixStream) -> io::Result<File> {
    let mut body = [0u8; 6];
    let mut control = [0usize; 16]; // Aligned, bounded ancillary buffer.
    let mut vector = libc::iovec {
        iov_base: body.as_mut_ptr().cast(),
        iov_len: body.len(),
    };
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = std::mem::size_of_val(&control);
    // SAFETY: all message buffers are live and sized above; kernel validates the
    // ancillary headers. Every received descriptor is immediately RAII-owned.
    let count = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, libc::MSG_CMSG_CLOEXEC) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut descriptors = Vec::new();
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let size = (*header)
                    .cmsg_len
                    .saturating_sub(libc::CMSG_LEN(0) as usize);
                let bytes = std::slice::from_raw_parts(libc::CMSG_DATA(header), size);
                for fd in bytes.as_chunks::<4>().0 {
                    descriptors.push(OwnedFd::from_raw_fd(i32::from_ne_bytes(*fd)));
                }
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    if count != 5
        || &body[..5] != b"AVHC1"
        || message.msg_flags & (libc::MSG_CTRUNC | libc::MSG_TRUNC) != 0
        || descriptors.len() != 1
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid VHCI descriptor reply",
        ));
    }
    Ok(descriptors.pop().unwrap().into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    fn transfer(socket: &std::os::unix::net::UnixStream, body: &[u8], fd: &File) {
        let mut control = [0usize; 8];
        let mut vector = libc::iovec {
            iov_base: body.as_ptr().cast_mut().cast(),
            iov_len: body.len(),
        };
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = unsafe { libc::CMSG_SPACE(4) } as usize;
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&message);
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(4) as usize;
            std::ptr::copy_nonoverlapping(
                fd.as_raw_fd().to_ne_bytes().as_ptr(),
                libc::CMSG_DATA(header),
                4,
            );
            assert_eq!(
                libc::sendmsg(socket.as_raw_fd(), &message, 0),
                body.len() as isize
            );
        }
    }
    #[test]
    fn handover_owns_received_fd_and_rejects_wrong_protocol() {
        let (sender, receiver) = std::os::unix::net::UnixStream::pair().unwrap();
        let (read, mut write) = std::os::unix::net::UnixStream::pair().unwrap();
        let owned: OwnedFd = read.into();
        let source = File::from(owned);
        transfer(&sender, b"AVHC1", &source);
        let mut received = receive_descriptor(&receiver).unwrap();
        drop(source);
        write.write_all(b"owned").unwrap();
        let mut bytes = [0; 5];
        received.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"owned");
        let flags = unsafe { libc::fcntl(received.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        transfer(&sender, b"wrong", &received);
        assert!(receive_descriptor(&receiver).is_err());
    }
}
