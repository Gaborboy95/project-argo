//! Bounded LIVI Link HCI framing for the planned Linux wireless transport.
//! Wire facts researched from pinned LIVI's livi-dongle/src/bt.rs; see CREDITS.md.
//! This module does not open a radio, /dev/vhci, or modify firmware.
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const PORT: u16 = 5002;
pub const MAX_PACKET: usize = 4096;
#[derive(Clone, Copy)]
pub enum Direction {
    ToController,
    FromController,
}

/// Validate the H4 type and its own declared payload, in addition to TCP framing.
pub fn validate(packet: &[u8], direction: Direction) -> io::Result<()> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidData, "Invalid HCI packet");
    if packet.is_empty() || packet.len() > MAX_PACKET {
        return Err(invalid());
    }
    let expected = match packet[0] {
        1 if matches!(direction, Direction::ToController) && packet.len() >= 4 => {
            4 + usize::from(packet[3])
        }
        2 if packet.len() >= 5 => 5 + usize::from(u16::from_le_bytes([packet[3], packet[4]])),
        3 if packet.len() >= 4 => 4 + usize::from(packet[3]),
        4 if matches!(direction, Direction::FromController) && packet.len() >= 3 => {
            3 + usize::from(packet[2])
        }
        5 if packet.len() >= 5 => {
            5 + usize::from(u16::from_le_bytes([packet[3], packet[4]]) & 0x3fff)
        }
        _ => return Err(invalid()),
    };
    if packet.len() != expected {
        return Err(invalid());
    }
    Ok(())
}

pub async fn receive<R: AsyncRead + Unpin>(input: &mut R) -> io::Result<Vec<u8>> {
    let size = usize::from(input.read_u16().await?);
    if !(1..=MAX_PACKET).contains(&size) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HCI frame bounds",
        ));
    }
    let mut packet = vec![0; size];
    input.read_exact(&mut packet).await?;
    validate(&packet, Direction::FromController)?;
    Ok(packet)
}
pub async fn send<W: AsyncWrite + Unpin>(output: &mut W, packet: &[u8]) -> io::Result<()> {
    validate(packet, Direction::ToController)?;
    output.write_u16(packet.len() as u16).await?;
    output.write_all(packet).await
}

/// The local kernel adapter-created notification is not forwarded to the dongle.
pub fn created_adapter(packet: &[u8]) -> io::Result<u16> {
    if packet.len() != 4 || packet[..2] != [0xff, 0] {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid VHCI creation reply",
        ));
    }
    Ok(u16::from_le_bytes([packet[2], packet[3]]))
}

/// Own the supplied nonblocking VHCI descriptor for the lifetime of a controller
/// tunnel. Only an explicit wireless owner may call this; discovery never does.
#[cfg(target_os = "linux")]
pub async fn bridge(
    device: std::fs::File,
    transport: tokio::net::TcpStream,
    mut stop: tokio::sync::watch::Receiver<bool>,
    adapter: tokio::sync::watch::Sender<Option<u16>>,
) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    use tokio::{
        io::unix::AsyncFd,
        time::{Duration, timeout},
    };
    if *stop.borrow() {
        return Ok(());
    }
    // SAFETY: File owns the live descriptor. Preserve its existing status flags.
    let flags = unsafe { libc::fcntl(device.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(device.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let device = AsyncFd::new(device)?;
    transport.set_nodelay(true)?;
    let work = async {
        device_write(&device, &[0xff, 0]).await?;
        let created = timeout(Duration::from_secs(5), device_read(&device))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "VHCI creation timed out"))??;
        adapter.send_replace(Some(created_adapter(&created)?));
        let (mut from_link, mut to_link) = transport.into_split();
        let inbound = async {
            loop {
                let packet = receive(&mut from_link).await?;
                device_write(&device, &packet).await?;
            }
            #[allow(unreachable_code)]
            Ok::<(), io::Error>(())
        };
        let outbound = async {
            loop {
                let packet = device_read(&device).await?;
                timeout(Duration::from_secs(3), send(&mut to_link, &packet))
                    .await
                    .map_err(|_| {
                        io::Error::new(io::ErrorKind::TimedOut, "HCI write timed out")
                    })??;
            }
            #[allow(unreachable_code)]
            Ok::<(), io::Error>(())
        };
        tokio::select! { result = inbound => result, result = outbound => result }
    };
    let cancelled = async {
        while !*stop.borrow_and_update() {
            if stop.changed().await.is_err() {
                break;
            }
        }
    };
    let result = tokio::select! { result = work => result, _ = cancelled => Ok(()) };
    adapter.send_replace(None);
    result
}

#[cfg(target_os = "linux")]
async fn device_read(device: &tokio::io::unix::AsyncFd<std::fs::File>) -> io::Result<Vec<u8>> {
    use std::io::Read;
    let mut packet = vec![0; MAX_PACKET + 1];
    loop {
        let mut ready = device.readable().await?;
        match ready.try_io(|device| {
            let mut file = device.get_ref();
            file.read(&mut packet)
        }) {
            Ok(Ok(size)) if size > 0 && size <= MAX_PACKET => {
                packet.truncate(size);
                return Ok(packet);
            }
            Ok(Ok(_)) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "VHCI packet bounds",
                ));
            }
            Ok(Err(error)) => return Err(error),
            Err(_) => {}
        }
    }
}
#[cfg(target_os = "linux")]
async fn device_write(
    device: &tokio::io::unix::AsyncFd<std::fs::File>,
    packet: &[u8],
) -> io::Result<()> {
    use std::io::Write;
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            let mut ready = device.writable().await?;
            match ready.try_io(|device| {
                let mut file = device.get_ref();
                file.write(packet)
            }) {
                Ok(Ok(size)) if size == packet.len() => return Ok(()),
                Ok(Ok(_)) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "Partial VHCI packet write",
                    ));
                }
                Ok(Err(error)) => return Err(error),
                Err(_) => {}
            }
        }
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "VHCI write timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn tunnel_forwards_whole_packets_and_cancellation_releases_adapter() {
        use std::os::fd::OwnedFd;
        let (device, kernel) = std::os::unix::net::UnixDatagram::pair().unwrap();
        kernel.set_nonblocking(true).unwrap();
        let kernel = tokio::net::UnixDatagram::from_std(kernel).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = tokio::net::TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut remote, _) = listener.accept().await.unwrap();
        let (stop, stopping) = tokio::sync::watch::channel(false);
        let (adapter, mut index) = tokio::sync::watch::channel(None);
        let fd: OwnedFd = device.into();
        let task = tokio::spawn(bridge(fd.into(), host, stopping, adapter));
        let mut packet = [0; 64];
        let size = kernel.recv(&mut packet).await.unwrap();
        assert_eq!(&packet[..size], &[0xff, 0]);
        kernel.send(&[0xff, 0, 7, 0]).await.unwrap();
        index.changed().await.unwrap();
        assert_eq!(*index.borrow(), Some(7));
        kernel.send(&[1, 3, 12, 0]).await.unwrap();
        let mut framed = [0; 6];
        remote.read_exact(&mut framed).await.unwrap();
        assert_eq!(framed, [0, 4, 1, 3, 12, 0]);
        remote.write_all(&[0, 3, 4, 14, 0]).await.unwrap();
        let size = kernel.recv(&mut packet).await.unwrap();
        assert_eq!(&packet[..size], &[4, 14, 0]);
        stop.send_replace(true);
        tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(*index.borrow(), None);
    }

    #[tokio::test]
    async fn fragmented_event_frames_and_outbound_commands() {
        let (mut writer, mut reader) = tokio::io::duplex(8);
        let task = tokio::spawn(async move {
            for byte in [0, 6, 4, 14, 3, 1, 3, 12] {
                writer.write_u8(byte).await.unwrap();
            }
        });
        assert_eq!(receive(&mut reader).await.unwrap(), [4, 14, 3, 1, 3, 12]);
        task.await.unwrap();
        let mut encoded = Vec::new();
        send(&mut encoded, &[1, 3, 12, 0]).await.unwrap();
        assert_eq!(encoded, [0, 4, 1, 3, 12, 0]);
    }
    #[tokio::test]
    async fn rejects_lengths_truncation_and_kernel_packets_from_network() {
        for bytes in [
            &[0, 0][..],
            &[0x10, 1],
            &[0, 3, 4, 14],
            &[0, 4, 0xff, 0, 1, 0],
            &[0, 4, 4, 14, 0, 0],
        ] {
            assert!(receive(&mut &bytes[..]).await.is_err());
        }
        assert!(validate(&[4, 14, 0], Direction::ToController).is_err());
        assert!(validate(&[1, 3, 12, 0], Direction::FromController).is_err());
        assert_eq!(created_adapter(&[0xff, 0, 2, 0]).unwrap(), 2);
        assert!(created_adapter(&[0xff, 1, 2, 0]).is_err());
    }
}
