//! Private, stable Wi-Fi credentials for explicitly selected wireless CarPlay.
//! These never enter the Flutter settings/status contract or diagnostic logs.
use serde::{Deserialize, Serialize};
use std::{
    io::{self, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

#[derive(Clone)]
pub struct WirelessNetwork {
    pub ssid: String,
    pub passphrase: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u8,
    ssid: String,
    passphrase: String,
}

impl WirelessNetwork {
    pub fn load_or_create(directory: &Path) -> io::Result<Self> {
        let metadata = directory.symlink_metadata()?;
        if !directory.is_absolute()
            || !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::other(
                "Unsafe wireless CarPlay settings directory",
            ));
        }
        let path = directory.join("wireless-network.json");
        match path.symlink_metadata() {
            Ok(metadata) => {
                if !metadata.is_file()
                    || metadata.uid() != unsafe { libc::geteuid() }
                    || metadata.mode() & 0o077 != 0
                    || metadata.len() > 2048
                {
                    return Err(io::Error::other("Unsafe wireless CarPlay credentials"));
                }
                let stored: Stored = serde_json::from_slice(&std::fs::read(path)?)?;
                if stored.version != 1
                    || stored.ssid.is_empty()
                    || stored.ssid.len() > 32
                    || stored.ssid.bytes().any(|b| b < 32 || b == 127)
                    || !(8..=63).contains(&stored.passphrase.len())
                    || !stored.passphrase.bytes().all(|b| (32..127).contains(&b))
                {
                    return Err(io::Error::other("Invalid wireless CarPlay credentials"));
                }
                return Ok(Self {
                    ssid: stored.ssid,
                    passphrase: stored.passphrase,
                });
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let mut random = [0; 23];
        openssl::rand::rand_bytes(&mut random).map_err(io::Error::other)?;
        let stored = Stored {
            version: 1,
            ssid: format!(
                "Argo-CarPlay-{:02X}{:02X}{:02X}",
                random[0], random[1], random[2]
            ),
            passphrase: random[3..].iter().map(|b| format!("{b:02x}")).collect(),
        };
        // A session owner serializes creation. Refuse replacement rather than
        // silently changing the credentials remembered by an existing iPhone.
        let mut output = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        if let Err(error) = (|| {
            output.write_all(&serde_json::to_vec(&stored)?)?;
            output.sync_all()
        })() {
            let _ = std::fs::remove_file(&path);
            return Err(error);
        }
        Ok(Self {
            ssid: stored.ssid,
            passphrase: stored.passphrase,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn reconnects_keep_the_same_private_network_and_refuse_public_credentials() {
        let directory =
            std::env::temp_dir().join(format!("argo-wireless-network-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let first = WirelessNetwork::load_or_create(&directory).unwrap();
        let next = WirelessNetwork::load_or_create(&directory).unwrap();
        assert!(first.ssid.starts_with("Argo-CarPlay-"));
        assert!(first.ssid == next.ssid && first.passphrase == next.passphrase);
        let path = directory.join("wireless-network.json");
        assert_eq!(path.metadata().unwrap().mode() & 0o777, 0o600);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(WirelessNetwork::load_or_create(&directory).is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
