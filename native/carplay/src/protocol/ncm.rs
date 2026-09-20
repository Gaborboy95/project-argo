//! Local iPhone USB-NCM transport. No Link USB proxy or firmware operations.
//! NetworkManager owns a temporary user TAP; only the iPhone's configuration
//! switch may need the separate administrator helper when usbmuxd owns USB.
use super::Error;
use nusb::{
    Device, DeviceInfo, Interface,
    transfer::{Buffer, Bulk, ControlIn, ControlType, In, Out, Recipient},
};
use std::{
    io,
    net::{Ipv6Addr, SocketAddrV6},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    time::Duration,
};
use tokio::{io::unix::AsyncFd, process::Command, task::JoinSet, time::timeout};

type Result<T> = std::result::Result<T, Error>;
fn failed<T>(_: T) -> Error {
    Error::Rejected
}

pub async fn one_phone() -> Result<DeviceInfo> {
    let mut devices = nusb::list_devices()
        .await
        .map_err(failed)?
        .filter(|d| d.vendor_id() == 0x05ac && (0x1290..=0x12ff).contains(&d.product_id()));
    let phone = devices.next().ok_or(Error::Rejected)?;
    if devices.next().is_some() {
        return Err(Error::State);
    }
    Ok(phone)
}
pub async fn expose_carplay() -> Result<()> {
    let phone = one_phone().await?;
    let device = phone.open().await.map_err(failed)?;
    if device
        .configurations()
        .any(|c| c.configuration_value() == 6)
    {
        return Ok(());
    }
    device
        .control_in(
            ControlIn {
                control_type: ControlType::Vendor,
                recipient: Recipient::Device,
                request: 0x52,
                value: 0,
                index: 4,
                length: 1,
            },
            Duration::from_secs(1),
        )
        .await
        .map_err(failed)?;
    Ok(())
}
pub async fn select_carplay() -> Result<()> {
    let phone = one_phone().await?;
    let device = phone.open().await.map_err(failed)?;
    if device
        .active_configuration()
        .map_err(failed)?
        .configuration_value()
        == 6
    {
        return Ok(());
    }
    device.set_configuration(6).await.map_err(failed)
}

fn u16le(bytes: &[u8], index: usize) -> Result<usize> {
    Ok(u16::from_le_bytes(
        bytes
            .get(index..index + 2)
            .ok_or(Error::Bounds)?
            .try_into()
            .unwrap(),
    ) as usize)
}
pub fn ethernet_frames(bytes: &[u8]) -> Result<Vec<&[u8]>> {
    if bytes.len() < 12 || &bytes[..4] != b"NCMH" || u16le(bytes, 4)? != 12 {
        return Err(Error::Malformed);
    }
    let length = u16le(bytes, 8)?;
    if !(12..=32768).contains(&length) || length > bytes.len() {
        return Err(Error::Bounds);
    }
    let bytes = &bytes[..length];
    let mut offset = u16le(bytes, 10)?;
    let mut tables = vec![(0usize, 12usize)];
    let mut ranges = Vec::new();
    while offset != 0 {
        if offset < 12 || offset % 4 != 0 || tables.len() > 8 {
            return Err(Error::Bounds);
        }
        if bytes.get(offset..offset + 4) != Some(b"NCM0") {
            return Err(Error::Unsupported);
        }
        let size = u16le(bytes, offset + 4)?;
        if size < 12 || size % 4 != 0 || offset + size > bytes.len() {
            return Err(Error::Bounds);
        }
        if tables
            .iter()
            .any(|&(start, end)| offset < end && offset + size > start)
        {
            return Err(Error::Malformed);
        }
        tables.push((offset, offset + size));
        let mut terminated = false;
        for entry in (offset + 8..offset + size).step_by(4) {
            let start = u16le(bytes, entry)?;
            let size = u16le(bytes, entry + 2)?;
            if start == 0 && size == 0 {
                terminated = true;
                break;
            }
            if start < 12
                || !(14..=4096).contains(&size)
                || start + size > bytes.len()
                || ranges.len() >= 32
            {
                return Err(Error::Bounds);
            }
            if ranges.iter().any(|&(a, b)| start < b && start + size > a) {
                return Err(Error::Malformed);
            }
            ranges.push((start, start + size));
        }
        if !terminated {
            return Err(Error::Malformed);
        }
        offset = u16le(bytes, offset + 6)?;
    }
    for &(start, end) in &ranges {
        if tables.iter().any(|&(a, b)| start < b && end > a) {
            return Err(Error::Malformed);
        }
    }
    Ok(ranges.into_iter().map(|(a, b)| &bytes[a..b]).collect())
}
pub fn ntb(frame: &[u8], sequence: u16) -> Result<Vec<u8>> {
    if !(14..=4096).contains(&frame.len()) {
        return Err(Error::Bounds);
    }
    let length = frame.len() + 28;
    let mut out = vec![0; length + usize::from(length.is_multiple_of(512))];
    out[..4].copy_from_slice(b"NCMH");
    out[12..16].copy_from_slice(b"NCM0");
    for (index, value) in [
        (4, 12),
        (6, sequence),
        (8, length as u16),
        (10, 12),
        (16, 16),
        (20, 28),
        (22, frame.len() as u16),
    ] {
        out[index..index + 2].copy_from_slice(&value.to_le_bytes());
    }
    out[28..length].copy_from_slice(frame);
    Ok(out)
}
async fn nmcli(args: &[&str]) -> Result<()> {
    let status = timeout(
        Duration::from_secs(10),
        Command::new("nmcli")
            .args(["--wait", "7"])
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| Error::Timeout)?
    .map_err(failed)?;
    if !status.status.success() {
        eprintln!(
            "Temporary CarPlay network setup failed: {}",
            String::from_utf8_lossy(&status.stderr)
        );
        return Err(Error::Rejected);
    }
    Ok(())
}
struct Profile(String);
impl Drop for Profile {
    fn drop(&mut self) {
        // Bounded cleanup also runs if startup is cancelled. Never touch another connection.
        let _ = std::process::Command::new("nmcli")
            .args(["--wait", "5", "connection", "delete", "id", &self.0])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}
pub struct Bridge {
    pub address: SocketAddrV6,
    pub interface: String,
    pub usb_interface: u8,
    tasks: JoinSet<Result<()>>,
    _control: Interface,
    _data: Interface,
    _profile: Profile,
}
impl Bridge {
    pub async fn start() -> Result<Self> {
        let phone = one_phone().await?;
        let device = phone.open().await.map_err(failed)?;
        let config = device.active_configuration().map_err(failed)?;
        if config.configuration_value() != 6 {
            return Err(Error::State);
        }
        let mut control = None;
        let mut data = None;
        let mut mux = None;
        for descriptor in config.interface_alt_settings() {
            if control.is_none() && descriptor.class() == 2 && descriptor.subclass() == 13 {
                control = Some(descriptor.interface_number());
            }
            if descriptor.class() == 0xff && descriptor.subclass() == 0xfe {
                mux = Some(descriptor.interface_number());
            }
            if data.is_none()
                && control.is_some()
                && descriptor.class() == 10
                && descriptor.alternate_setting() == 1
            {
                let endpoints: Vec<_> = descriptor
                    .endpoints()
                    .filter(|e| e.transfer_type() == nusb::descriptors::TransferType::Bulk)
                    .map(|e| e.address())
                    .collect();
                if endpoints.len() == 2 {
                    let input = *endpoints
                        .iter()
                        .find(|e| **e & 128 != 0)
                        .ok_or(Error::Malformed)?;
                    let output = *endpoints
                        .iter()
                        .find(|e| **e & 128 == 0)
                        .ok_or(Error::Malformed)?;
                    if data
                        .replace((descriptor.interface_number(), input, output))
                        .is_some()
                    {
                        return Err(Error::Unsupported);
                    }
                }
            }
        }
        let _mux_interface = mux.ok_or(Error::Unsupported)?;
        let control_number = control.ok_or(Error::Unsupported)?;
        let (data_number, input, output) = data.ok_or(Error::Unsupported)?;
        let mac = mac_address(&device, config.as_bytes(), control_number).await?;
        let control = device
            .claim_interface(control_number)
            .await
            .map_err(failed)?;
        let data = device.claim_interface(data_number).await.map_err(failed)?;
        data.set_alt_setting(1).await.map_err(failed)?;
        let mut input = data.endpoint::<Bulk, In>(input).map_err(failed)?;
        let mut output = data.endpoint::<Bulk, Out>(output).map_err(failed)?;
        let interface = format!("arcp{}", std::process::id());
        let profile = format!("argo-carplay-{}", std::process::id());
        if std::path::Path::new("/sys/class/net")
            .join(&interface)
            .exists()
        {
            return Err(Error::State);
        }
        let uid = unsafe { libc::geteuid() }.to_string();
        nmcli(&[
            "connection",
            "add",
            "save",
            "no",
            "type",
            "tun",
            "mode",
            "tap",
            "ifname",
            &interface,
            "con-name",
            &profile,
            "owner",
            &uid,
            "pi",
            "no",
            "vnet-hdr",
            "no",
            "connection.autoconnect",
            "no",
            "ipv4.method",
            "disabled",
            "ipv6.method",
            "link-local",
            "ipv6.addr-gen-mode",
            "eui64",
            "802-3-ethernet.cloned-mac-address",
            &mac,
        ])
        .await?;
        let profile = Profile(profile);
        nmcli(&["--wait", "0", "connection", "up", "id", &profile.0]).await?;
        let tap = timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(tap) = open_tap(&interface) {
                    break tap;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .map_err(|_| Error::Timeout)?;
        let tap = std::sync::Arc::new(tap);
        let address = timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(address) = interface_address(&interface).await {
                    break address;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .map_err(|_| Error::Timeout)?;
        let mut tasks = JoinSet::new();
        let incoming = tap.clone();
        tasks.spawn(async move {
            loop {
                input.submit(Buffer::new(32768));
                let completion = input.next_complete().await;
                completion.status.map_err(failed)?;
                for frame in ethernet_frames(&completion.buffer)? {
                    loop {
                        let mut ready = incoming.writable().await.map_err(failed)?;
                        if let Ok(result) = ready.try_io(|fd| {
                            let n = unsafe {
                                libc::write(fd.as_raw_fd(), frame.as_ptr().cast(), frame.len())
                            };
                            if n < 0 {
                                Err(io::Error::last_os_error())
                            } else if n as usize != frame.len() {
                                Err(io::Error::other("short TAP write"))
                            } else {
                                Ok(())
                            }
                        }) {
                            result.map_err(failed)?;
                            break;
                        }
                    }
                }
            }
        });
        tasks.spawn(async move {
            let mut bytes = [0u8; 4096];
            let mut sequence = 0u16;
            loop {
                let size = loop {
                    let mut ready = tap.readable().await.map_err(failed)?;
                    if let Ok(result) = ready.try_io(|fd| {
                        let n = unsafe {
                            libc::read(fd.as_raw_fd(), bytes.as_mut_ptr().cast(), bytes.len())
                        };
                        if n < 0 {
                            Err(io::Error::last_os_error())
                        } else {
                            Ok(n as usize)
                        }
                    }) {
                        break result.map_err(failed)?;
                    }
                };
                let packet = ntb(&bytes[..size], sequence)?;
                sequence = sequence.wrapping_add(1);
                let mut buffer = Buffer::new(packet.len());
                buffer.extend_from_slice(&packet);
                output.submit(buffer);
                timeout(Duration::from_secs(3), output.next_complete())
                    .await
                    .map_err(|_| Error::Timeout)?
                    .status
                    .map_err(failed)?;
            }
        });
        Ok(Self {
            address,
            interface,
            usb_interface: control_number,
            tasks,
            _control: control,
            _data: data,
            _profile: profile,
        })
    }
    pub async fn ended(&mut self) -> Result<()> {
        self.tasks
            .join_next()
            .await
            .ok_or(Error::State)?
            .map_err(failed)?
    }
    pub async fn close(mut self) {
        self.tasks.abort_all();
        while self.tasks.join_next().await.is_some() {}
    }
}
fn open_tap(name: &str) -> Result<AsyncFd<OwnedFd>> {
    let raw = unsafe {
        libc::open(
            c"/dev/net/tun".as_ptr(),
            libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        return Err(Error::Rejected);
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut request: libc::ifreq = unsafe { std::mem::zeroed() };
    if name.len() >= request.ifr_name.len() {
        return Err(Error::Bounds);
    }
    for (dest, byte) in request.ifr_name.iter_mut().zip(name.bytes()) {
        *dest = byte as libc::c_char;
    }
    request.ifr_ifru.ifru_flags = (libc::IFF_TAP | libc::IFF_NO_PI) as libc::c_short;
    if unsafe { libc::ioctl(fd.as_raw_fd(), 0x400454ca as libc::c_ulong, &request) } < 0 {
        return Err(Error::Rejected);
    }
    AsyncFd::new(fd).map_err(failed)
}
async fn interface_address(interface: &str) -> Result<SocketAddrV6> {
    let output = timeout(
        Duration::from_secs(3),
        Command::new("ip")
            .args(["-j", "-6", "address", "show", "dev", interface])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| Error::Timeout)?
    .map_err(failed)?;
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).map_err(failed)?;
    let entry = value.get(0).ok_or(Error::Malformed)?;
    let scope =
        u32::try_from(entry["ifindex"].as_u64().ok_or(Error::Malformed)?).map_err(failed)?;
    let addresses = entry["addr_info"].as_array().ok_or(Error::Malformed)?;
    for entry in addresses {
        if entry["scope"] == "link" {
            let ip: Ipv6Addr = entry["local"]
                .as_str()
                .ok_or(Error::Malformed)?
                .parse()
                .map_err(failed)?;
            let address = SocketAddrV6::new(ip, 0, 0, scope);
            let _probe = tokio::net::UdpSocket::bind(address).await.map_err(failed)?;
            return Ok(address);
        }
    }
    Err(Error::State)
}
async fn mac_address(device: &Device, descriptors: &[u8], control: u8) -> Result<String> {
    let mut offset = 0;
    let mut selected = false;
    let mut index = None;
    while offset + 2 <= descriptors.len() {
        let size = descriptors[offset] as usize;
        if size < 2 || offset + size > descriptors.len() {
            return Err(Error::Malformed);
        }
        let item = &descriptors[offset..offset + size];
        if item[1] == 4 && size >= 9 {
            selected = item[2] == control;
        }
        if selected && size >= 4 && item[1..3] == [0x24, 0x0f] {
            index = Some(item[3]);
            break;
        }
        offset += size;
    }
    let index = index.ok_or(Error::Malformed)?;
    let bytes = device
        .control_in(
            ControlIn {
                control_type: ControlType::Standard,
                recipient: Recipient::Device,
                request: 6,
                value: 0x300 | index as u16,
                index: 0x409,
                length: 64,
            },
            Duration::from_secs(1),
        )
        .await
        .map_err(failed)?;
    if bytes.len() < 26 || bytes[0] != 26 || bytes[1] != 3 {
        return Err(Error::Malformed);
    }
    let characters: Vec<u16> = bytes[2..26]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .collect();
    let text = String::from_utf16(&characters).map_err(failed)?;
    if text.len() != 12 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::Malformed);
    }
    Ok((0..12)
        .step_by(2)
        .map(|i| text[i..i + 2].to_ascii_lowercase())
        .collect::<Vec<_>>()
        .join(":"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ntb_roundtrip_padding_and_malformed_tables() {
        for size in [14, 484, 1514, 4096] {
            let frame = vec![12; size];
            let packet = ntb(&frame, 65535).unwrap();
            assert_ne!(packet.len() % 512, 0);
            assert_eq!(ethernet_frames(&packet).unwrap(), vec![frame.as_slice()]);
        }
        let valid = ntb(&[1; 64], 1).unwrap();
        for size in 0..valid.len() {
            assert!(ethernet_frames(&valid[..size]).is_err());
        }
        let mut cycle = valid.clone();
        cycle[18..20].copy_from_slice(&12u16.to_le_bytes());
        assert!(ethernet_frames(&cycle).is_err());
        let mut overlap = valid.clone();
        overlap[20..22].copy_from_slice(&12u16.to_le_bytes());
        assert!(ethernet_frames(&overlap).is_err());
        let mut oversize = valid;
        oversize[22..24].copy_from_slice(&65535u16.to_le_bytes());
        assert!(ethernet_frames(&oversize).is_err());
    }
}
