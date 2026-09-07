//! NetworkManager D-Bus controls; no nmcli/hostapd control subprocesses.
use super::Radio;
use std::{collections::HashMap, io::Read, net::Ipv4Addr, time::Duration};
use zbus::{
    Connection, Proxy,
    zvariant::{OwnedObjectPath, OwnedValue, Value},
};
type Settings = HashMap<String, HashMap<String, OwnedValue>>;
const NM: &str = "org.freedesktop.NetworkManager";
const ROOT: &str = "/org/freedesktop/NetworkManager";
fn value(v: impl Into<Value<'static>>) -> OwnedValue {
    v.into().try_to_owned().unwrap()
}
fn section(
    items: impl IntoIterator<Item = (&'static str, OwnedValue)>,
) -> HashMap<String, OwnedValue> {
    items.into_iter().map(|(k, v)| (k.into(), v)).collect()
}
pub struct Network {
    bus: Connection,
}
/// Secrets deliberately have no Debug or Serialize implementation.
pub struct AccessPoint {
    pub interface: String,
    pub address: Ipv4Addr,
    pub channel: u16,
    pub ssid: String,
    pub password: String,
    pub bssid: String,
    active: Option<OwnedObjectPath>,
    firewall: bool,
    activation_pending: bool,
}
impl Network {
    pub async fn open() -> Result<Self, String> {
        Ok(Self {
            bus: Connection::system().await.map_err(|e| e.to_string())?,
        })
    }
    async fn proxy<'a>(&'a self, path: &'a str, iface: &'a str) -> Result<Proxy<'a>, String> {
        Proxy::new(&self.bus, NM, path, iface)
            .await
            .map_err(|e| e.to_string())
    }
    pub async fn interfaces(&self) -> Result<Vec<Radio>, String> {
        let p = self.proxy(ROOT, NM).await?;
        let paths: Vec<OwnedObjectPath> =
            p.call("GetDevices", &()).await.map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for path in paths {
            let d = self
                .proxy(path.as_str(), "org.freedesktop.NetworkManager.Device")
                .await?;
            if d.get_property::<u32>("DeviceType")
                .await
                .map_err(|e| e.to_string())?
                == 2
            {
                let id: String = d
                    .get_property("Interface")
                    .await
                    .map_err(|e| e.to_string())?;
                result.push(Radio {
                    name: id.clone(),
                    id,
                });
            }
        }
        Ok(result)
    }
    async fn device_path(&self, interface: &str) -> Result<OwnedObjectPath, String> {
        self.proxy(ROOT, NM)
            .await?
            .call("GetDeviceByIpIface", &(interface,))
            .await
            .map_err(|e| e.to_string())
    }
    pub async fn prepare(&self, interface: &str) -> Result<AccessPoint, String> {
        if !self.interfaces().await?.iter().any(|r| r.id == interface) {
            return Err("Select an available Wi-Fi interface".into());
        }
        let path = self.device_path(interface).await?;
        let dev = self
            .proxy(path.as_str(), "org.freedesktop.NetworkManager.Device")
            .await?;
        let active: OwnedObjectPath = dev
            .get_property("ActiveConnection")
            .await
            .map_err(|e| e.to_string())?;
        if active.as_str() != "/" {
            return Err("Wi-Fi is in use. Disconnect that connection explicitly in desktop network settings first.".into());
        }
        let wifi = self
            .proxy(
                path.as_str(),
                "org.freedesktop.NetworkManager.Device.Wireless",
            )
            .await?;
        let caps: u32 = wifi
            .get_property("WirelessCapabilities")
            .await
            .map_err(|e| e.to_string())?;
        if caps & 0x40 == 0 || caps & 0x400 == 0 {
            return Err("Selected radio lacks AP / 5 GHz support".into());
        }
        let channel = permitted_channel(interface).await?;
        let mut random = [0; 24];
        std::fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|e| e.to_string())?;
        let address = Ipv4Addr::new(10, 77, random[0], 1);
        // A dedicated /24 must not overlap any existing non-default IPv4 route.
        let routes = std::fs::read_to_string("/proc/net/route").map_err(|e| e.to_string())?;
        let subnet = u32::from_le_bytes(address.octets());
        for line in routes.lines().skip(1) {
            let f: Vec<_> = line.split_whitespace().collect();
            if f.len() > 7
                && let (Ok(dest), Ok(mask)) =
                    (u32::from_str_radix(f[1], 16), u32::from_str_radix(f[7], 16))
                && mask != 0
                && subnet & mask == dest & mask
            {
                return Err(
                    "Projection subnet overlaps a host route; retry for a fresh subnet".into(),
                );
            }
        }
        Ok(AccessPoint {
            interface: interface.into(),
            address,
            channel,
            ssid: format!("Argo Projection {:02X}{:02X}", random[1], random[2]),
            password: random[3..].iter().map(|v| format!("{v:02x}")).collect(),
            bssid: String::new(),
            active: None,
            firewall: false,
            activation_pending: false,
        })
    }
    pub async fn activate(&self, ap: &mut AccessPoint) -> Result<(), String> {
        firewall("start", &ap.interface).await?;
        ap.firewall = true;
        let path = self.device_path(&ap.interface).await?;
        // No profile mutations before an explicit Connect. NM removes this
        // volatile profile after deactivation and on daemon/service death.
        let mut settings = Settings::new();
        settings.insert(
            "connection".into(),
            section([
                ("id", value(format!("Argo Projection ({})", ap.interface))),
                ("type", value("802-11-wireless")),
                ("interface-name", value(ap.interface.clone())),
                ("autoconnect", value(false)),
            ]),
        );
        settings.insert(
            "802-11-wireless".into(),
            section([
                ("ssid", value(ap.ssid.as_bytes().to_vec())),
                ("mode", value("ap")),
                ("band", value("a")),
                ("channel", value(u32::from(ap.channel))),
            ]),
        );
        settings.insert(
            "802-11-wireless-security".into(),
            section([
                ("key-mgmt", value("wpa-psk")),
                ("psk", value(ap.password.clone())),
                ("proto", value(vec!["rsn".to_string()])),
                ("pairwise", value(vec!["ccmp".to_string()])),
            ]),
        );
        let address = section([
            ("address", value(ap.address.to_string())),
            ("prefix", value(24u32)),
        ]);
        settings.insert(
            "ipv4".into(),
            section([
                ("method", value("shared")),
                ("never-default", value(true)),
                ("address-data", value(vec![address])),
            ]),
        );
        settings.insert("ipv6".into(), section([("method", value("disabled"))]));
        let options = section([
            ("persist", value("volatile")),
            ("bind-activation", value("dbus-client")),
        ]);
        ap.activation_pending = true;
        let result: (OwnedObjectPath, OwnedObjectPath, HashMap<String, OwnedValue>) = self.proxy(ROOT, NM).await?
            .call("AddAndActivateConnection2", &(settings, path.clone(), OwnedObjectPath::try_from("/").unwrap(), options)).await
            .map_err(|_| "NetworkManager AP activation failed (check NM journal; credentials are redacted)")?;
        ap.active = Some(result.1);
        ap.activation_pending = false;
        tokio::time::timeout(Duration::from_secs(25), async {
            loop {
                if self.ready(ap).await? {
                    break Ok::<_, String>(());
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        })
        .await
        .map_err(|_| "AP address / DHCP readiness timed out")??;
        let wifi = self
            .proxy(
                path.as_str(),
                "org.freedesktop.NetworkManager.Device.Wireless",
            )
            .await?;
        ap.bssid = wifi
            .get_property::<String>("HwAddress")
            .await
            .map_err(|e| e.to_string())?
            .to_uppercase();
        if ap.bssid.len() != 17 {
            return Err("AP BSSID unavailable".into());
        }
        Ok(())
    }
    pub async fn ready(&self, ap: &AccessPoint) -> Result<bool, String> {
        let active = ap.active.as_ref().ok_or("AP not activated")?;
        let a = self
            .proxy(
                active.as_str(),
                "org.freedesktop.NetworkManager.Connection.Active",
            )
            .await?;
        let state: u32 = a.get_property("State").await.map_err(|e| e.to_string())?;
        if state == 3 || state == 4 {
            return Err("Projection AP disconnected".into());
        }
        if state != 2 {
            return Ok(false);
        }
        let ip: OwnedObjectPath = a
            .get_property("Ip4Config")
            .await
            .map_err(|e| e.to_string())?;
        if ip.as_str() == "/" {
            return Ok(false);
        }
        let p = self
            .proxy(ip.as_str(), "org.freedesktop.NetworkManager.IP4Config")
            .await?;
        let addresses: Vec<HashMap<String, OwnedValue>> = p
            .get_property("AddressData")
            .await
            .map_err(|e| e.to_string())?;
        let address_ready = addresses.iter().any(|a| {
            a.get("address").and_then(|v| <&str>::try_from(v).ok())
                == Some(ap.address.to_string().as_str())
        });
        // NM ACTIVATED + usable address + DHCP server socket; activation alone
        // is not sufficient. Actual DHCP lease receipt is phone acceptance.
        let dhcp = std::fs::read_to_string("/proc/net/udp")
            .unwrap_or_default()
            .lines()
            .any(|line| {
                line.split_whitespace()
                    .nth(1)
                    .is_some_and(|v| v.ends_with(":0043"))
            });
        Ok(address_ready && dhcp && dhcp_for_address(ap.address))
    }
    pub async fn stop(&self, ap: &mut AccessPoint) -> Result<(), String> {
        cleanup(self, ap).await
    }
}
/// NM 1.52 shared-mode dnsmasq must have the owned address and a DHCP range.
/// A DHCP socket belonging to an unrelated connection is not readiness.
fn dhcp_for_address(address: Ipv4Addr) -> bool {
    let Ok(processes) = std::fs::read_dir("/proc") else {
        return false;
    };
    let listen = format!("--listen-address={address}");
    let octets = address.octets();
    let range = format!("--dhcp-range={}.{}.{}.", octets[0], octets[1], octets[2]);
    processes.flatten().take(4096).any(|entry| {
        if !entry
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|b| b.is_ascii_digit())
        {
            return false;
        }
        let Ok(file) = std::fs::File::open(entry.path().join("cmdline")) else {
            return false;
        };
        let mut bytes = Vec::new();
        if file.take(8192).read_to_end(&mut bytes).is_err() {
            return false;
        }
        let args: Vec<_> = bytes.split(|b| *b == 0).collect();
        args.first().is_some_and(|arg| arg.ends_with(b"/dnsmasq"))
            && args.contains(&listen.as_bytes())
            && args.iter().any(|arg| arg.starts_with(range.as_bytes()))
    })
}

/// Read-only regulatory inspection. Control always uses NM D-Bus. Fail closed
/// if iw output or sysfs cannot prove a non-DFS channel without NO-IR.
async fn permitted_channel(interface: &str) -> Result<u16, String> {
    let phy = std::fs::read_link(format!("/sys/class/net/{interface}/phy80211"))
        .map_err(|e| e.to_string())?;
    let phy = phy
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("No Wi-Fi phy")?;
    let output = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("/usr/sbin/iw")
            .args(["phy", phy, "info"])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| "Regulatory inspection timed out")?
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err("Cannot inspect regulatory channel permissions".into());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    // Upper channels avoid the indoor-only lower-band restriction. No country changes.
    for channel in [149u16, 153, 157, 161, 165] {
        if text.lines().any(|l| {
            l.contains(&format!("[{channel}]"))
                && l.contains("MHz")
                && l.contains("dBm")
                && !l.contains("disabled")
                && !l.contains("no IR")
                && !l.contains("radar")
                && !l.contains("indoor")
        }) {
            return Ok(channel);
        }
    }
    Err("No proven permitted non-DFS 5 GHz AP channel in 149–165. Regulatory settings were not changed.".into())
}
async fn firewall(action: &str, interface: &str) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let path = "/usr/local/libexec/argo-projection-firewall";
    let meta = std::fs::metadata(path).map_err(|_| "Install the narrowly scoped projection firewall helper (see docs/wireless.md) before Connect")?;
    if meta.uid() != 0 || meta.mode() & 0o022 != 0 {
        return Err(
            "Projection firewall helper must be root-owned and not group/world writable".into(),
        );
    }
    let status = tokio::time::timeout(
        Duration::from_secs(45),
        tokio::process::Command::new("pkexec")
            .args([path, action, interface])
            .kill_on_drop(true)
            .status(),
    )
    .await
    .map_err(|_| "Firewall authorization timed out")?
    .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("Projection firewall authorization/setup failed".into());
    }
    Ok(())
}

trait CleanupAdapter {
    async fn deactivate(&self, active: &OwnedObjectPath) -> Result<(), String>;
    async fn remove_guard(&self, interface: &str) -> Result<(), String>;
}
impl CleanupAdapter for Network {
    async fn deactivate(&self, active: &OwnedObjectPath) -> Result<(), String> {
        let nm = self.proxy(ROOT, NM).await?;
        let remaining: Vec<OwnedObjectPath> = nm
            .get_property("ActiveConnections")
            .await
            .map_err(|e| format!("Cannot verify owned AP cleanup: {e}"))?;
        if !remaining.contains(active) {
            return Ok(());
        }
        nm.call::<_, _, ()>("DeactivateConnection", &(active,))
            .await
            .map_err(|e| format!("Owned AP cleanup failed: {e}"))?;
        tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                let remaining: Vec<OwnedObjectPath> = nm
                    .get_property("ActiveConnections")
                    .await
                    .map_err(|e| e.to_string())?;
                if !remaining.contains(active) {
                    return Ok::<_, String>(());
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .map_err(|_| "Owned AP deactivation did not complete; retaining firewall")?
    }
    async fn remove_guard(&self, interface: &str) -> Result<(), String> {
        firewall("stop", interface).await
    }
}
async fn cleanup(system: &impl CleanupAdapter, ap: &mut AccessPoint) -> Result<(), String> {
    if ap.activation_pending {
        // A cancelled D-Bus call may already have activated the profile. The
        // attempt-local bus disconnect removes bind-activation=dbus-client;
        // retain the input guard until the operator has verified deactivation.
        return Err("AP activation result unknown; closing its owning D-Bus connection and retaining firewall guard".into());
    }
    if let Some(active) = ap.active.as_ref() {
        system.deactivate(active).await?;
        ap.active = None;
    }
    if ap.firewall {
        system.remove_guard(&ap.interface).await?;
        ap.firewall = false;
    }
    Ok(())
}
#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Fake {
        fail: bool,
        calls: Mutex<Vec<String>>,
    }
    impl CleanupAdapter for Fake {
        async fn deactivate(&self, active: &OwnedObjectPath) -> Result<(), String> {
            self.calls.lock().unwrap().push(active.to_string());
            if self.fail {
                Err("service lost".into())
            } else {
                Ok(())
            }
        }
        async fn remove_guard(&self, interface: &str) -> Result<(), String> {
            self.calls.lock().unwrap().push(interface.into());
            Ok(())
        }
    }
    pub(crate) fn ap() -> AccessPoint {
        AccessPoint {
            interface: "testwifi".into(),
            address: Ipv4Addr::new(10, 77, 1, 1),
            channel: 149,
            ssid: "unit-test".into(),
            password: "test-only-credential".into(),
            bssid: "02:00:00:00:00:01".into(),
            active: Some(OwnedObjectPath::try_from("/owned/activation").unwrap()),
            firewall: true,
            activation_pending: false,
        }
    }
    #[tokio::test]
    async fn cleanup_is_owned_idempotent_and_retains_guard_on_partial_failure() {
        let mut ap = ap();
        let bad = Fake {
            fail: true,
            calls: Mutex::default(),
        };
        assert!(cleanup(&bad, &mut ap).await.is_err());
        assert!(ap.active.is_some() && ap.firewall);
        assert_eq!(*bad.calls.lock().unwrap(), vec!["/owned/activation"]);
        let good = Fake {
            fail: false,
            calls: Mutex::default(),
        };
        cleanup(&good, &mut ap).await.unwrap();
        cleanup(&good, &mut ap).await.unwrap();
        assert_eq!(
            *good.calls.lock().unwrap(),
            vec!["/owned/activation", "testwifi"]
        );
        ap.activation_pending = true;
        ap.firewall = true;
        assert!(cleanup(&good, &mut ap).await.is_err());
        assert!(ap.firewall);
        assert_eq!(good.calls.lock().unwrap().len(), 2);
    }
}
