//! NetworkManager D-Bus controls; no nmcli/hostapd control subprocesses.
use super::Radio;
use crate::failure::Failure;
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
// Construct once for both the credential template and the volatile activation.
fn ap_settings(ap: &AccessPoint) -> Settings {
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
            // D-Bus differs from nmcli/libnm: the legacy cloned field is ay.
            ("assigned-mac-address", value("permanent")),
            ("band", value(ap.band.nm_band())),
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
    settings
}

fn nm_failure(action: &str, error: zbus::Error) -> Failure {
    // A remote error body may echo profile values. Retain its structured name,
    // never the body or the submitted settings (SSID/PSK/peer remain private).
    let kind = match &error {
        zbus::Error::MethodError(name, _, _) => name.as_str(),
        _ => "local D-Bus transport or encoding failure",
    };
    Failure::configuration(format!("{action}: {kind}; profile values redacted"))
}

pub struct Network {
    bus: Connection,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub enum ApBand {
    #[serde(rename = "2.4ghz")]
    Ghz2,
    #[default]
    #[serde(rename = "5ghz")]
    Ghz5,
}
impl ApBand {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "2.4ghz" => Ok(Self::Ghz2),
            "5ghz" => Ok(Self::Ghz5),
            _ => Err("AP band must be 2.4ghz or 5ghz".into()),
        }
    }
    fn label(self) -> &'static str {
        match self {
            Self::Ghz2 => "2.4 GHz",
            Self::Ghz5 => "5 GHz",
        }
    }
    fn nm_band(self) -> &'static str {
        match self {
            Self::Ghz2 => "bg",
            Self::Ghz5 => "a",
        }
    }
    pub fn frequency(self, channel: u16) -> u32 {
        match self {
            Self::Ghz2 => 2407 + u32::from(channel) * 5,
            Self::Ghz5 => 5000 + u32::from(channel) * 5,
        }
    }
}
/// Secrets deliberately have no Debug or Serialize implementation.
pub struct AccessPoint {
    pub interface: String,
    pub address: Ipv4Addr,
    pub channel: u16,
    pub band: ApBand,
    pub ssid: String,
    pub password: String,
    pub bssid: String,
    active: Option<OwnedObjectPath>,
    firewall: bool,
    activation_pending: bool,
    template_path: Option<OwnedObjectPath>,
    save_template: bool,
    peer: String,
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
                    usable: None,
                    detail: None,
                    address: None,
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
    // Read-only: no activation, secret creation or network mutation.
    pub async fn eligible(&self, interface: &str, band: ApBand) -> Result<(), String> {
        let path = self.device_path(interface).await?;
        let dev = self
            .proxy(path.as_str(), "org.freedesktop.NetworkManager.Device")
            .await?;
        let managed = dev
            .get_property::<bool>("Managed")
            .await
            .map_err(|e| e.to_string())?;
        let state = dev
            .get_property::<u32>("State")
            .await
            .map_err(|e| e.to_string())?;
        if !managed || state < 30 {
            return Err("Wi-Fi unavailable, disabled or unmanaged".into());
        }
        let active: OwnedObjectPath = dev
            .get_property("ActiveConnection")
            .await
            .map_err(|e| e.to_string())?;
        if active.as_str() != "/" {
            let connection = self
                .proxy(
                    active.as_str(),
                    "org.freedesktop.NetworkManager.Connection.Active",
                )
                .await?;
            let id = connection
                .get_property::<String>("Id")
                .await
                .map_err(|e| e.to_string())?;
            if id != format!("Argo Projection ({interface})") {
                return Err("Wi-Fi is in use by another connection".into());
            }
        }
        let wifi = self
            .proxy(
                path.as_str(),
                "org.freedesktop.NetworkManager.Device.Wireless",
            )
            .await?;
        let caps = wifi
            .get_property::<u32>("WirelessCapabilities")
            .await
            .map_err(|e| e.to_string())?;
        let required = 0x40
            | match band {
                ApBand::Ghz2 => 0x200,
                ApBand::Ghz5 => 0x400,
            };
        if caps & required != required {
            return Err(format!("No AP / {} capability", band.label()));
        }
        permitted_channel(interface, band).await?;
        Ok(())
    }
    async fn profiles(&self) -> Result<Vec<(OwnedObjectPath, Settings)>, String> {
        let root = self
            .proxy(
                "/org/freedesktop/NetworkManager/Settings",
                "org.freedesktop.NetworkManager.Settings",
            )
            .await?;
        let profiles: Vec<OwnedObjectPath> = root
            .call("ListConnections", &())
            .await
            .map_err(|e| e.to_string())?;
        if profiles.len() > 128 {
            return Err("Too many NM profiles for bounded projection lookup".into());
        }
        let mut result = Vec::new();
        for path in profiles {
            let settings: Settings = self
                .proxy(
                    path.as_str(),
                    "org.freedesktop.NetworkManager.Settings.Connection",
                )
                .await?
                .call("GetSettings", &())
                .await
                .map_err(|_| "Could not inspect NM profiles")?;
            result.push((path, settings));
        }
        Ok(result)
    }
    async fn credentials(
        &self,
        interface: &str,
        peer: &str,
    ) -> Result<(Option<OwnedObjectPath>, Option<(String, String, Ipv4Addr)>), String> {
        let mut result = None;
        let mut owned = None;
        for (path, settings) in self.profiles().await? {
            let profile = self
                .proxy(
                    path.as_str(),
                    "org.freedesktop.NetworkManager.Settings.Connection",
                )
                .await?;
            let text = |section: &str, key: &str| {
                settings
                    .get(section)
                    .and_then(|s| s.get(key))
                    .and_then(|v| <&str>::try_from(v).ok())
            };
            if text("connection", "id")
                != Some(format!("Argo Projection credentials ({interface})").as_str())
            {
                continue;
            }
            let tags: HashMap<String, String> = settings
                .get("user")
                .and_then(|s| s.get("data"))
                .and_then(|v| v.try_clone().ok())
                .and_then(|v| v.try_into().ok())
                .unwrap_or_default();
            if tags.get("org.argo.owner").map(String::as_str) != Some("projection-credentials-v1")
                || text("connection", "interface-name") != Some(interface)
            {
                return Err(
                    "Projection credential profile name conflicts with an unrelated profile".into(),
                );
            }
            if owned.is_some() {
                return Err(
                    "Multiple projection credential profiles; resolve in NetworkManager".into(),
                );
            }
            owned = Some(path.clone());
            if tags.get("org.argo.peer").map(String::as_str) != Some(peer) {
                continue;
            }
            let ssid: Vec<u8> = settings
                .get("802-11-wireless")
                .and_then(|s| s.get("ssid"))
                .and_then(|v| v.try_clone().ok())
                .and_then(|v| v.try_into().ok())
                .ok_or("Missing projection SSID")?;
            let secrets: Settings = profile
                .call("GetSecrets", &("802-11-wireless-security",))
                .await
                .map_err(|_| "NetworkManager projection credentials unavailable")?;
            let password = secrets
                .get("802-11-wireless-security")
                .and_then(|s| s.get("psk"))
                .and_then(|v| <&str>::try_from(v).ok())
                .ok_or("Missing projection PSK")?
                .to_string();
            let address: Ipv4Addr = tags
                .get("org.argo.address")
                .ok_or("Missing projection address")?
                .parse()
                .map_err(|_| "Invalid projection address")?;
            let ssid = String::from_utf8(ssid).map_err(|_| "Invalid projection SSID")?;
            validate_credentials(&ssid, &password, address)?;
            result = Some((ssid, password, address));
        }
        Ok((owned, result))
    }
    pub async fn forget_credentials(&self, peer: &str) -> Result<(), String> {
        // Revocation must also find templates for radios currently unplugged.
        // It needs no secret access and never depends on Wi-Fi inventory.
        for (path, settings) in self.profiles().await? {
            let tags: HashMap<String, String> = settings
                .get("user")
                .and_then(|s| s.get("data"))
                .and_then(|v| v.try_clone().ok())
                .and_then(|v| v.try_into().ok())
                .unwrap_or_default();
            if tags.get("org.argo.owner").map(String::as_str) != Some("projection-credentials-v1")
                || tags.get("org.argo.peer").map(String::as_str) != Some(peer)
            {
                continue;
            }
            let text = |key: &str| {
                settings
                    .get("connection")
                    .and_then(|s| s.get(key))
                    .and_then(|v| <&str>::try_from(v).ok())
            };
            let interface = text("interface-name").ok_or("Invalid owned credential interface")?;
            if text("id") != Some(format!("Argo Projection credentials ({interface})").as_str()) {
                return Err(
                    "Owned credential profile name changed; inspect NetworkManager before removal"
                        .into(),
                );
            }
            self.proxy(path.as_str(), "org.freedesktop.NetworkManager.Settings.Connection").await?
                .call::<_, _, ()>("Delete", &()).await
                .map_err(|_| "Bond removed, but owned AP credentials could not be removed; inspect NM permissions".to_string())?;
        }
        Ok(())
    }
    pub async fn prepare(
        &self,
        interface: &str,
        band: ApBand,
        peer: &str,
    ) -> Result<AccessPoint, String> {
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
        let band_cap = match band {
            ApBand::Ghz2 => 0x200,
            ApBand::Ghz5 => 0x400,
        };
        if caps & 0x40 == 0 || caps & band_cap == 0 {
            return Err(format!(
                "Selected radio lacks AP / {} support",
                band.label()
            ));
        }
        let channel = permitted_channel(interface, band).await?;
        let mut random = [0; 24];
        std::fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|e| e.to_string())?;
        let (template_path, saved) = self.credentials(interface, peer).await?;
        let save_template = saved.is_none();
        let (ssid, password, address) = saved.unwrap_or_else(|| {
            (
                format!("Argo Projection {:02X}{:02X}", random[1], random[2]),
                random[3..].iter().map(|v| format!("{v:02x}")).collect(),
                Ipv4Addr::new(10, 77, random[0], 1),
            )
        });
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
                    "Projection subnet overlaps a host route; remove the inactive owned credential profile before retrying".into(),
                );
            }
        }
        Ok(AccessPoint {
            interface: interface.into(),
            address,
            channel,
            band,
            ssid,
            password,
            bssid: String::new(),
            active: None,
            firewall: false,
            activation_pending: false,
            template_path,
            save_template,
            peer: peer.into(),
        })
    }
    pub async fn activate(&self, ap: &mut AccessPoint) -> Result<(), Failure> {
        firewall("start", &ap.interface)
            .await
            .map_err(Failure::configuration)?;
        ap.firewall = true;
        let path = self
            .device_path(&ap.interface)
            .await
            .map_err(Failure::configuration)?;
        // No profile mutations before an explicit Connect. NM removes this
        // volatile profile after deactivation and on daemon/service death.
        let settings = ap_settings(ap);
        if ap.save_template {
            let mut template = Settings::new();
            for (key, values) in &settings {
                template.insert(
                    key.clone(),
                    values
                        .iter()
                        .map(|(k, v)| {
                            Ok((
                                k.clone(),
                                v.try_clone().map_err(|_| {
                                    Failure::configuration("Cannot prepare NM credential template")
                                })?,
                            ))
                        })
                        .collect::<Result<_, Failure>>()?,
                );
            }
            template.get_mut("connection").unwrap().insert(
                "id".into(),
                value(format!("Argo Projection credentials ({})", ap.interface)),
            );
            let user = std::env::var("USER")
                .map_err(|_| Failure::configuration("Desktop account unavailable"))?;
            template
                .get_mut("connection")
                .unwrap()
                .insert("permissions".into(), value(vec![format!("user:{user}:")]));
            template.insert(
                "user".into(),
                section([(
                    "data",
                    value(HashMap::from([
                        (
                            "org.argo.owner".to_string(),
                            "projection-credentials-v1".to_string(),
                        ),
                        ("org.argo.address".to_string(), ap.address.to_string()),
                        ("org.argo.peer".to_string(), ap.peer.clone()),
                    ])),
                )]),
            );
            if let Some(path) = &ap.template_path {
                let _: HashMap<String, OwnedValue> = self
                    .proxy(
                        path.as_str(),
                        "org.freedesktop.NetworkManager.Settings.Connection",
                    )
                    .await?
                    .call(
                        "Update2",
                        &(template, 1u32, HashMap::<String, OwnedValue>::new()),
                    )
                    .await
                    .map_err(|e| nm_failure("Could not rotate owned projection credentials", e))?;
            } else {
                let (path, _): (OwnedObjectPath, HashMap<String, OwnedValue>) = self
                    .proxy(
                        "/org/freedesktop/NetworkManager/Settings",
                        "org.freedesktop.NetworkManager.Settings",
                    )
                    .await?
                    .call(
                        "AddConnection2",
                        &(template, 1u32, HashMap::<String, OwnedValue>::new()),
                    )
                    .await
                    .map_err(|e| {
                        nm_failure("Could not save NetworkManager projection credentials", e)
                    })?;
                ap.template_path = Some(path);
            }
            ap.save_template = false;
        }
        let options = section([
            ("persist", value("volatile")),
            ("bind-activation", value("dbus-client")),
        ]);
        ap.activation_pending = true;
        let result: (
            OwnedObjectPath,
            OwnedObjectPath,
            HashMap<String, OwnedValue>,
        ) = self
            .proxy(ROOT, NM)
            .await
            .map_err(Failure::configuration)?
            .call(
                "AddAndActivateConnection2",
                &(
                    settings,
                    path.clone(),
                    OwnedObjectPath::try_from("/").unwrap(),
                    options,
                ),
            )
            .await
            .map_err(|e| nm_failure("NetworkManager AP activation failed", e))?;
        ap.active = Some(result.1);
        ap.activation_pending = false;
        tokio::time::timeout(Duration::from_secs(25), async {
            loop {
                if self.ready(ap).await? {
                    break Ok::<_, Failure>(());
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        })
        .await
        .map_err(|_| Failure::timeout("AP address / DHCP readiness timed out"))??;
        let wifi = self
            .proxy(
                path.as_str(),
                "org.freedesktop.NetworkManager.Device.Wireless",
            )
            .await?;
        ap.bssid = wifi
            .get_property::<String>("HwAddress")
            .await
            .map_err(Failure::configuration)?
            .to_uppercase();
        if ap.bssid.len() != 17 {
            return Err("AP BSSID unavailable".into());
        }
        Ok(())
    }
    pub async fn ready(&self, ap: &AccessPoint) -> Result<bool, Failure> {
        let active = ap
            .active
            .as_ref()
            .ok_or_else(|| Failure::configuration("AP not activated"))?;
        let a = self
            .proxy(
                active.as_str(),
                "org.freedesktop.NetworkManager.Connection.Active",
            )
            .await
            .map_err(Failure::network)?;
        let state: u32 = a.get_property("State").await.map_err(Failure::network)?;
        if !active_state_ready(state)? {
            return Ok(false);
        }
        let ip: OwnedObjectPath = a
            .get_property("Ip4Config")
            .await
            .map_err(Failure::network)?;
        if ip.as_str() == "/" {
            return Ok(false);
        }
        let p = self
            .proxy(ip.as_str(), "org.freedesktop.NetworkManager.IP4Config")
            .await
            .map_err(Failure::network)?;
        let addresses: Vec<HashMap<String, OwnedValue>> = p
            .get_property("AddressData")
            .await
            .map_err(Failure::network)?;
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
pub(crate) fn active_state_ready(state: u32) -> Result<bool, Failure> {
    match state {
        3 | 4 => Err(Failure::network("Projection AP disconnected")),
        2 => Ok(true),
        _ => Ok(false),
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
async fn permitted_channel(interface: &str, band: ApBand) -> Result<u16, String> {
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
    choose_channel(&String::from_utf8_lossy(&output.stdout), band)
}
fn choose_channel(info: &str, band: ApBand) -> Result<u16, String> {
    // No automatic cross-band fallback. Exclude DFS and indoor-only channels
    // because this deployment does not establish indoor operation or perform CAC.
    let candidates: &[u16] = match band {
        ApBand::Ghz2 => &[1, 6, 11, 2, 3, 4, 5, 7, 8, 9, 10, 12, 13],
        ApBand::Ghz5 => &[149, 153, 157, 161, 165],
    };
    for &channel in candidates {
        if info.lines().any(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            // Match frequency too: 6 GHz reuses 2.4/5 GHz channel numbers.
            fields.first() == Some(&"*")
                && fields.get(1).and_then(|v| v.parse::<f64>().ok())
                    == Some(f64::from(band.frequency(channel)))
                && fields.get(2) == Some(&"MHz")
                && fields.get(3) == Some(&format!("[{channel}]").as_str())
                && line.contains("dBm")
                && !["disabled", "no ir", "radar", "indoor", "no 20mhz"]
                    .iter()
                    .any(|restriction| line.to_ascii_lowercase().contains(restriction))
        }) {
            return Ok(channel);
        }
    }
    Err(format!(
        "No proven permitted non-DFS {} AP channel. Regulatory settings were not changed; select another AP band if permitted.",
        band.label()
    ))
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
fn validate_credentials(ssid: &str, password: &str, address: Ipv4Addr) -> Result<(), String> {
    let octets = address.octets();
    if !ssid.starts_with("Argo Projection ")
        || ssid.len() > 32
        || !(8..=63).contains(&password.len())
        || !password.is_ascii()
        || password.bytes().any(|b| b.is_ascii_control())
        || octets[0..2] != [10, 77]
        || octets[3] != 1
    {
        return Err("Invalid owned projection credential template".into());
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;
    #[test]
    fn ap_request_uses_dbus_string_mac_policy_and_redacts_remote_errors() {
        let settings = ap_settings(&ap());
        let wifi = &settings["802-11-wireless"];
        assert_eq!(
            <&str>::try_from(&wifi["assigned-mac-address"]).unwrap(),
            "permanent"
        );
        assert!(!wifi.contains_key("cloned-mac-address"));
        let err = zbus::Error::MethodError(
            zbus::names::OwnedErrorName::try_from(
                "org.freedesktop.NetworkManager.Settings.InvalidConnection",
            )
            .unwrap(),
            Some("secret-psk-and-peer".into()),
            zbus::message::Message::method_call("/test", "Test")
                .unwrap()
                .build(&())
                .unwrap(),
        );
        let failure = nm_failure("Credential save failed", err);
        let message = failure.to_string();
        assert!(message.contains("Settings.InvalidConnection"));
        assert!(!message.contains("secret-psk-and-peer"));
        assert!(!message.contains("permissions"));
    }

    #[test]
    fn credential_template_validation_rejects_unsafe_reuse() {
        assert!(
            validate_credentials(
                "Argo Projection 1234",
                "deployment-specific-test",
                Ipv4Addr::new(10, 77, 3, 1)
            )
            .is_ok()
        );
        for (ssid, key, ip) in [
            (
                "Other network",
                "deployment-specific-test",
                Ipv4Addr::new(10, 77, 3, 1),
            ),
            ("Argo Projection 1234", "short", Ipv4Addr::new(10, 77, 3, 1)),
            (
                "Argo Projection 1234",
                "bad\npassword",
                Ipv4Addr::new(10, 77, 3, 1),
            ),
            (
                "Argo Projection 1234",
                "deployment-specific-test",
                Ipv4Addr::new(192, 168, 1, 1),
            ),
        ] {
            assert!(validate_credentials(ssid, key, ip).is_err());
        }
    }
    #[test]
    fn channels_respect_selected_band_and_regulatory_restrictions() {
        let info = "* 2412 MHz [1] (20.0 dBm) (no IR)\n* 2437.0 MHz [6] (20.0 dBm)\n* 2462 MHz [11] (disabled)\n* 5745.0 MHz [149] (13.0 dBm)\n* 5955 MHz [1] (23.0 dBm)";
        assert_eq!(choose_channel(info, ApBand::Ghz2).unwrap(), 6);
        assert_eq!(choose_channel(info, ApBand::Ghz5).unwrap(), 149);
        for restriction in [
            "no IR",
            "disabled",
            "radar detection",
            "indoor only",
            "no 20MHz",
        ] {
            let blocked = format!(
                "* 2412 MHz [1] (20.0 dBm) ({restriction})\n* 5955 MHz [1] (23.0 dBm)\n* 5745.0 MHz [149] (13.0 dBm)"
            );
            assert!(choose_channel(&blocked, ApBand::Ghz2).is_err());
        }
        assert!(choose_channel("* 2412 MHz [1] (20.0 dBm)", ApBand::Ghz5).is_err());
        assert!(ApBand::parse("auto").is_err());
        assert_eq!(ApBand::Ghz2.nm_band(), "bg");
        assert_eq!(ApBand::Ghz5.nm_band(), "a");
    }
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
            band: ApBand::Ghz5,
            ssid: "unit-test".into(),
            password: "test-only-credential".into(),
            bssid: "02:00:00:00:00:01".into(),
            active: Some(OwnedObjectPath::try_from("/owned/activation").unwrap()),
            firewall: true,
            activation_pending: false,
            template_path: None,
            save_template: true,
            peer: "test-peer".into(),
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
