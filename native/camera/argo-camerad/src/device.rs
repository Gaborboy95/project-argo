use serde::Serialize;
use std::{
    fs, io,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
};
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub stable_id: String,
    pub display_name: String,
    pub node: String,
}
impl Device {
    /// Open through the stable alias, not an incidental videoN retained earlier.
    /// Sysfs-only devices are resolved again by enumerate() immediately before start.
    pub fn capture_path(&self) -> String {
        if let Some(alias) = self.stable_id.strip_prefix("by-id:") {
            return format!("/dev/v4l/by-id/{alias}");
        }
        if let Some(alias) = self.stable_id.strip_prefix("by-path:") {
            return format!("/dev/v4l/by-path/{alias}");
        }
        self.node.clone()
    }
}
#[repr(C)]
struct Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [u32; 3],
}
fn aliases(root: &Path, node: &Path) -> Vec<String> {
    let mut paths: Vec<_> = fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| fs::canonicalize(e.path()).ok().as_deref() == Some(node))
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    paths.sort();
    paths
}
fn identity(by_id: &[String], by_path: &[String], serial: bool, topology: &str) -> String {
    if serial && let Some(id) = by_id.first() {
        return format!("by-id:{id}");
    }
    if let Some(path) = by_path.first() {
        return format!("by-path:{path}");
    }
    format!("sysfs:{topology}")
}
pub fn enumerate() -> io::Result<Vec<Device>> {
    let mut devices = vec![];
    let root = Path::new("/sys/class/video4linux");
    if !root.exists() {
        return Ok(devices);
    }
    for entry in fs::read_dir(root)?.flatten() {
        let name = entry.file_name();
        let node = PathBuf::from("/dev").join(&name);
        let Ok(fd) = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&node)
        else {
            continue;
        };
        let mut cap: Capability = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(fd.as_raw_fd(), 0x80685600 as libc::c_ulong, &mut cap) } != 0 {
            continue;
        }
        let flags = if cap.capabilities & 0x80000000 != 0 {
            cap.device_caps
        } else {
            cap.capabilities
        };
        if flags & (1 | 0x1000) == 0 || flags & 0x04000000 == 0 {
            continue;
        }
        let physical = fs::canonicalize(entry.path().join("device"))?;
        let serial_value = physical.ancestors().find_map(|p| {
            fs::read_to_string(p.join("serial"))
                .ok()
                .filter(|v| !v.trim().is_empty())
        });
        // USB by-id links can silently retarget when devices share a serial.
        // Only prefer by-id when the serial is unique across physical devices.
        let serial = serial_value.is_some_and(|value| {
            fs::read_dir("/sys/bus/usb/devices")
                .into_iter()
                .flatten()
                .flatten()
                .filter(|e| {
                    fs::read_to_string(e.path().join("serial"))
                        .is_ok_and(|v| v.trim() == value.trim())
                })
                .count()
                == 1
        });
        let ids = aliases(Path::new("/dev/v4l/by-id"), &node);
        let paths = aliases(Path::new("/dev/v4l/by-path"), &node);
        // The per-device index differentiates multiple capture interfaces; videoN never enters identity.
        let index = fs::read_to_string(entry.path().join("index")).unwrap_or_default();
        let topology = format!(
            "{}:{}",
            physical
                .strip_prefix("/sys/devices")
                .unwrap_or(&physical)
                .display(),
            index.trim()
        );
        let stable_id = identity(&ids, &paths, serial, &topology);
        let display_name = String::from_utf8_lossy(&cap.card)
            .trim_end_matches('\0')
            .to_string();
        devices.push(Device {
            stable_id,
            display_name,
            node: node.to_string_lossy().into_owned(),
        });
    }
    // A duplicated serial is not a unique identity. Fall back to physical topology for both.
    let duplicates: Vec<_> = devices
        .iter()
        .filter(|d| {
            devices
                .iter()
                .filter(|other| other.stable_id == d.stable_id)
                .count()
                > 1
        })
        .map(|d| d.stable_id.clone())
        .collect();
    for d in &mut devices {
        if duplicates.contains(&d.stable_id) {
            let paths = aliases(Path::new("/dev/v4l/by-path"), Path::new(&d.node));
            if let Some(p) = paths.first() {
                d.stable_id = format!("by-path:{p}");
            } else {
                return Err(io::Error::other("Capture identity is ambiguous"));
            }
        }
    }
    devices.sort_by(|a, b| a.stable_id.cmp(&b.stable_id));
    Ok(devices)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stable_physical_identity_for_identical_devices() {
        let ids = vec!["identical-video-index0".into()];
        assert_ne!(
            identity(&ids, &["usb-port1-video-index0".into()], false, ""),
            identity(&ids, &["usb-port2-video-index0".into()], false, "")
        );
        assert_eq!(
            identity(&["unique-serial".into()], &[], true, ""),
            "by-id:unique-serial"
        );
    }
}
