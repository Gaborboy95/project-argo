//! ARCR v1: little-endian Linux shared-memory ABI. Not a zero-copy transport.
#[cfg(target_endian = "big")]
compile_error!("ARCR v1 requires little-endian Linux");
use std::{
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    ptr,
    sync::atomic::{AtomicU64, Ordering},
};
pub const CAPACITY: usize = 1920 * 1080 * 4;
pub const HEADER: usize = 128;
pub const SLOT: usize = 64 + CAPACITY;
pub const SIZE: usize = HEADER + 3 * SLOT;
pub struct Ring {
    pub memory: OwnedFd,
    pub event: OwnedFd,
    map: *mut u8,
    sequence: u64,
}
impl Ring {
    pub fn new() -> io::Result<Self> {
        unsafe {
            let fd = libc::memfd_create(
                c"argo-camera-v1".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            );
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let memory = OwnedFd::from_raw_fd(fd);
            if libc::ftruncate(fd, SIZE as _) != 0 {
                return Err(io::Error::last_os_error());
            }
            // Size cannot change after a reader maps it.
            if libc::fcntl(
                fd,
                libc::F_ADD_SEALS,
                libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_SEAL,
            ) < 0
            {
                return Err(io::Error::last_os_error());
            }
            let event = libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK);
            if event < 0 {
                return Err(io::Error::last_os_error());
            }
            let event = OwnedFd::from_raw_fd(event);
            let map = libc::mmap(
                ptr::null_mut(),
                SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            );
            if map == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            let mut ring = Self {
                memory,
                event,
                map: map.cast(),
                sequence: 0,
            };
            ring.u32(0, 0x52435241); // ARCR
            ring.u32(4, 1);
            ring.u32(8, 3);
            ring.u32(12, CAPACITY as u32);
            Ok(ring)
        }
    }
    fn u32(&mut self, offset: usize, value: u32) {
        unsafe {
            ptr::write_unaligned(self.map.add(offset).cast::<u32>(), value.to_le());
        }
    }
    fn atomic(&self, offset: usize) -> &AtomicU64 {
        unsafe { &*self.map.add(offset).cast::<AtomicU64>() }
    }
    pub fn role(&self, role: u64) {
        self.atomic(32).store(role + 1, Ordering::Release);
    }
    pub fn sequence(&self) -> u64 {
        self.sequence
    }
    pub fn invalidate(&mut self) {
        self.atomic(24).store(0, Ordering::Release);
        self.notify();
    }
    fn notify(&self) {
        let one: u64 = 1;
        unsafe {
            libc::write(self.event.as_raw_fd(), (&one as *const u64).cast(), 8);
        }
    }
    pub fn write(
        &mut self,
        data: &[u8],
        width: u32,
        height: u32,
        stride: u32,
        fps_n: u32,
        fps_d: u32,
    ) -> io::Result<u64> {
        let bytes = stride as usize * height as usize;
        if width == 0
            || height == 0
            || width > 1920
            || height > 1080
            || stride < width * 4
            || bytes > CAPACITY
            || data.len() < bytes
        {
            return Err(io::Error::other("Camera frame exceeds ARCR bounds"));
        }
        self.sequence += 1;
        let seq = self.sequence;
        let slot = HEADER + ((seq - 1) % 3) as usize * SLOT;
        self.atomic(slot).store(seq * 2 - 1, Ordering::SeqCst);
        self.u32(slot + 8, width);
        self.u32(slot + 12, height);
        self.u32(slot + 16, stride);
        self.u32(slot + 20, fps_n);
        self.u32(slot + 24, fps_d);
        self.atomic(slot + 32)
            .store(monotonic_ns(), Ordering::Relaxed);
        unsafe {
            ptr::copy_nonoverlapping(data.as_ptr(), self.map.add(slot + 64), bytes);
        }
        self.atomic(slot).store(seq * 2, Ordering::Release);
        self.atomic(16).store(seq, Ordering::Release);
        self.atomic(24).store(1, Ordering::Release);
        self.notify();
        Ok(seq)
    }
    pub fn send_fds(&self, socket: i32) -> io::Result<()> {
        unsafe {
            let mut byte = 1u8;
            let mut iov = libc::iovec {
                iov_base: (&mut byte as *mut u8).cast(),
                iov_len: 1,
            };
            let mut control = [0usize; 8];
            let mut msg: libc::msghdr = std::mem::zeroed();
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = libc::CMSG_SPACE(8) as usize;
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(8) as usize;
            let fds = [self.memory.as_raw_fd(), self.event.as_raw_fd()];
            ptr::copy_nonoverlapping(fds.as_ptr().cast::<u8>(), libc::CMSG_DATA(cmsg), 8);
            if libc::sendmsg(socket, &msg, libc::MSG_NOSIGNAL) != 1 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }
}
impl Drop for Ring {
    fn drop(&mut self) {
        self.invalidate();
        unsafe {
            libc::munmap(self.map.cast(), SIZE);
        }
    }
}
pub fn monotonic_ns() -> u64 {
    unsafe {
        let mut t = std::mem::zeroed();
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut t);
        t.tv_sec as u64 * 1_000_000_000 + t.tv_nsec as u64
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sequence_guard_and_invalidation() {
        let mut r = Ring::new().unwrap();
        for n in 1..=7 {
            assert_eq!(r.write(&[1; 16], 2, 2, 8, 30, 1).unwrap(), n);
            assert_eq!(
                r.atomic(HEADER + ((n - 1) % 3) as usize * SLOT)
                    .load(Ordering::Acquire),
                n * 2
            );
        }
        r.invalidate();
        assert_eq!(r.atomic(24).load(Ordering::Acquire), 0);
        assert!(r.write(&[0; 8], 2, 2, 8, 30, 1).is_err());
    }
}
