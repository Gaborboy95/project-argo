//! Typed subset of the LIVI Link Wi-Fi protocol, researched in
//! livi-wifi/src/server.rs at a23dc0c5fcdb6d069c679eddfd73298e58f44783.
use crate::link::{Error, LinkClient, deadline};
use crate::protocol::csm::WirelessSecurity;
use serde::Serialize;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

const RESPONSE_MAX: usize = 16 * 1024;
const LINE_MAX: usize = 512;

#[derive(Debug, Clone, Serialize)]
pub struct WifiStatus {
    pub access_point_enabled: bool,
    pub bluetooth_enabled: bool,
    pub country: Option<String>,
    pub channel: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct AccessPointSettings {
    country: String,
    channel: u16,
}

/// An explicit wireless owner selects these credentials. Deliberately no Debug
/// or Serialize: status/UI must never expose the network secret.
pub struct WirelessAccessPointSettings {
    country: String,
    channel: u16,
    ssid: String,
    passphrase: String,
}

impl WirelessAccessPointSettings {
    pub fn new(country: &str, channel: u16, ssid: &str, passphrase: &str) -> Result<Self, Error> {
        let radio = AccessPointSettings::new(country, channel)?;
        if ssid.is_empty()
            || ssid.len() > 32
            || !(8..=63).contains(&passphrase.len())
            || [ssid, passphrase]
                .iter()
                .any(|v| v.trim() != *v || v.bytes().any(|b| b < 0x20 || b == 0x7f))
        {
            return Err(Error::Invalid("wireless network bounds"));
        }
        Ok(Self {
            country: radio.country,
            channel,
            ssid: ssid.into(),
            passphrase: passphrase.into(),
        })
    }
}

/// The control protocol does not return a passphrase. None explicitly means
/// unknown; callers cannot claim to restore an arbitrary previous AP secret.
#[derive(Clone)]
pub struct LiveAccessPoint {
    pub enabled: bool,
    pub bluetooth_enabled: bool,
    pub country: Option<String>,
    pub ssid: Option<String>,
    pub channel: Option<u16>,
    pub security: WirelessSecurity,
    pub mac: Option<[u8; 6]>,
    pub config_source: Option<String>,
    pub passphrase: Option<String>,
}
impl AccessPointSettings {
    pub fn new(country: &str, channel: u16) -> Result<Self, Error> {
        if country.len() != 2
            || !country.bytes().all(|v| v.is_ascii_alphabetic())
            || !(1..=196).contains(&channel)
        {
            return Err(Error::Invalid("country/channel bounds"));
        }
        Ok(Self {
            country: country.to_ascii_uppercase(),
            channel,
        })
    }
}

impl LinkClient {
    pub async fn wifi_access_point(&self) -> Result<LiveAccessPoint, Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            parse_access_point(&exchange(&mut connection, "status\n").await?)
        })
        .await
    }

    /// Configure the selected Link AP in one socket transaction, without save.
    /// Country comes from the caller's regulatory inventory, not a locale guess.
    pub async fn configure_wireless_access_point(
        &self,
        settings: &WirelessAccessPointSettings,
    ) -> Result<(), Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(std::time::Duration::from_secs(30), async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            for command in [
                format!("set country {}\n", settings.country),
                format!("set channel {}\n", settings.channel),
                format!("set ssid {}\n", settings.ssid),
                format!("set passphrase {}\n", settings.passphrase),
                "apply\n".into(),
            ] {
                exchange(&mut connection, &command).await?;
            }
            Ok(())
        })
        .await
    }

    /// Own only the Link controller; this never alters host adapters.
    pub async fn set_bluetooth_enabled(&self, enabled: bool) -> Result<(), Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            exchange(
                &mut connection,
                if enabled { "bt on\n" } else { "bt off\n" },
            )
            .await?;
            Ok(())
        })
        .await
    }
    pub async fn wifi_status(&self) -> Result<WifiStatus, Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            let response = exchange(&mut connection, "status\n").await?;
            parse_status(&response)
        })
        .await
    }

    /// Explicit radio ownership operation. Never called by discovery/probes/startup.
    pub async fn set_access_point_enabled(&self, enabled: bool) -> Result<(), Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            exchange(&mut connection, if enabled { "on\n" } else { "off\n" }).await?;
            Ok(())
        })
        .await
    }

    /// Apply only on an already-selected radio after checking its regulatory catalog.
    /// `apply` can start/restart the AP; callers must own radio lifetime and cleanup.
    /// Nothing is persisted: deliberately no `save` or arbitrary-command interface.
    pub async fn apply_access_point_settings(
        &self,
        settings: &AccessPointSettings,
    ) -> Result<(), Error> {
        let _guard = self.wifi_permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            exchange(
                &mut connection,
                &format!("set country {}\n", settings.country),
            )
            .await?;
            exchange(
                &mut connection,
                &format!("set channel {}\n", settings.channel),
            )
            .await?;
            exchange(&mut connection, "apply\n").await?;
            Ok(())
        })
        .await
    }
}

fn parse_access_point(lines: &[String]) -> Result<LiveAccessPoint, Error> {
    let state = parse_status(lines)?;
    let field = |name| {
        lines.iter().find_map(|v| {
            v.split_once(' ')
                .filter(|(k, _)| *k == name)
                .map(|(_, v)| v)
        })
    };
    let ssid = field("ssid").map(str::to_owned);
    if ssid.as_ref().is_some_and(|s| s.is_empty() || s.len() > 32) {
        return Err(Error::Invalid("AP SSID bounds"));
    }
    let security = match field("security") {
        None | Some("wpa2") => WirelessSecurity::Wpa2,
        Some("wpa2-wpa3") => WirelessSecurity::Wpa2Wpa3,
        Some("wpa3") => WirelessSecurity::Wpa3,
        _ => return Err(Error::Invalid("AP security mode")),
    };
    let mac = field("mac").map(parse_mac).transpose()?;
    Ok(LiveAccessPoint {
        enabled: state.access_point_enabled,
        bluetooth_enabled: state.bluetooth_enabled,
        country: state.country,
        ssid,
        channel: state.channel,
        security,
        mac,
        config_source: field("config").map(str::to_owned),
        passphrase: None,
    })
}

pub(crate) fn parse_mac(text: &str) -> Result<[u8; 6], Error> {
    if text.len() != 17 {
        return Err(Error::Invalid("Bluetooth address length"));
    }
    let mut output = [0; 6];
    let mut parts = text.split(':');
    for byte in &mut output {
        let part = parts.next().ok_or(Error::Invalid("Bluetooth address"))?;
        if part.len() != 2 || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::Invalid("Bluetooth address"));
        }
        *byte = u8::from_str_radix(part, 16).map_err(|_| Error::Invalid("Bluetooth address"))?;
    }
    if parts.next().is_some() || output == [0; 6] || output == [255; 6] {
        return Err(Error::Invalid("Bluetooth address"));
    }
    Ok(output)
}

async fn exchange(connection: &mut TcpStream, command: &str) -> Result<Vec<String>, Error> {
    connection.write_all(command.as_bytes()).await?;
    let mut lines = Vec::new();
    let mut line = Vec::with_capacity(128);
    // Byte reads use no unbounded line allocation and leave no over-read across transactions.
    for _ in 0..RESPONSE_MAX {
        let byte = connection.read_u8().await?;
        if byte == b'\n' {
            let value = std::str::from_utf8(&line).map_err(|_| Error::Invalid("Wi-Fi UTF-8"))?;
            if value == "ok" {
                return Ok(lines);
            }
            if value == "error" || value.starts_with("error ") {
                return Err(Error::Remote);
            }
            if value.is_empty() || lines.len() == 128 {
                return Err(Error::Invalid("Wi-Fi response lines"));
            }
            lines.push(value.to_owned());
            line.clear();
        } else {
            if byte < b' ' || byte == 0x7f || line.len() == LINE_MAX {
                return Err(Error::Invalid("Wi-Fi response line"));
            }
            line.push(byte);
        }
    }
    Err(Error::Invalid("Wi-Fi response size"))
}

fn parse_status(lines: &[String]) -> Result<WifiStatus, Error> {
    let mut state = None;
    let mut bluetooth = None;
    let mut country = None;
    let mut channel = None;
    let mut keys = std::collections::HashSet::new();
    for line in lines {
        let (key, value) = line
            .split_once(' ')
            .ok_or(Error::Invalid("Wi-Fi status field"))?;
        if !keys.insert(key) {
            return Err(Error::Invalid("duplicate Wi-Fi field"));
        }
        match key {
            "state" => state = Some(radio_state(value)?),
            "bt" => bluetooth = Some(radio_state(value)?),
            "country_code" => {
                if value.len() != 2
                    || !(value == "00" || value.bytes().all(|b| b.is_ascii_uppercase()))
                {
                    return Err(Error::Invalid("Wi-Fi country"));
                }
                country = Some(value.to_string());
            }
            "channel" => {
                let number = value
                    .parse::<u16>()
                    .map_err(|_| Error::Invalid("Wi-Fi channel"))?;
                if number > 196 {
                    return Err(Error::Invalid("Wi-Fi channel"));
                }
                channel = Some(number);
            }
            _ => {} // bounded future telemetry; never reflected as commands or logs
        }
    }
    Ok(WifiStatus {
        access_point_enabled: state.ok_or(Error::Invalid("missing AP state"))?,
        bluetooth_enabled: bluetooth.ok_or(Error::Invalid("missing Bluetooth state"))?,
        country,
        channel,
    })
}
fn radio_state(value: &str) -> Result<bool, Error> {
    match value {
        "on" => Ok(true),
        "off" => Ok(false),
        _ => Err(Error::Invalid("radio state")),
    }
}

#[cfg(test)]
mod wireless_tests {
    use super::*;
    use crate::{discovery::Discovery, link::LinkConfig};
    use std::net::Ipv4Addr;
    use tokio::{
        io::{AsyncBufReadExt, BufReader},
        net::TcpListener,
    };

    #[test]
    fn live_ap_keeps_regulatory_and_security_state_but_does_not_invent_a_secret() {
        let lines = "state on\nbt off\ncountry_code DE\nssid Existing AP\nchannel 149\nsecurity wpa2-wpa3\nmac 02:00:00:00:00:07\nconfig host"
            .lines().map(str::to_owned).collect::<Vec<_>>();
        let live = parse_access_point(&lines).unwrap();
        assert!(live.enabled);
        assert!(!live.bluetooth_enabled);
        assert_eq!(live.country.as_deref(), Some("DE"));
        assert_eq!(live.ssid.as_deref(), Some("Existing AP"));
        assert_eq!(live.channel, Some(149));
        assert_eq!(live.security, WirelessSecurity::Wpa2Wpa3);
        assert_eq!(live.mac, Some([2, 0, 0, 0, 0, 7]));
        assert!(live.passphrase.is_none());
        for bad in [
            "state on\nbt on\nsecurity wep",
            "state on\nbt on\nssid one\nssid two",
            "state on\nbt on\nmac not-an-address",
        ] {
            assert!(
                parse_access_point(&bad.lines().map(str::to_owned).collect::<Vec<_>>()).is_err()
            );
        }
        for (ssid, secret) in [
            ("with\ncommand", "synthetic"),
            ("Argo", "synthetic\rcommand"),
            (" Argo", "synthetic"),
            ("Argo", "short"),
        ] {
            assert!(WirelessAccessPointSettings::new("DE", 36, ssid, secret).is_err());
        }
    }

    #[tokio::test]
    async fn wireless_configuration_is_one_bounded_transaction_without_save() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let link = LinkClient::new(LinkConfig {
            discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
            wifi_port: listener.local_addr().unwrap().port(),
            ..LinkConfig::default()
        })
        .unwrap();
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = BufReader::new(stream);
            for expected in [
                "set country DE\n",
                "set channel 36\n",
                "set ssid Argo fixture\n",
                "set passphrase synthetic-secret\n",
                "apply\n",
            ] {
                let mut command = String::new();
                stream.read_line(&mut command).await.unwrap();
                assert_eq!(command, expected);
                stream.get_mut().write_all(b"ok\n").await.unwrap();
            }
            let mut extra = String::new();
            assert_eq!(
                stream.read_line(&mut extra).await.unwrap(),
                0,
                "configuration must close without save or radio toggles"
            );
        });
        let settings =
            WirelessAccessPointSettings::new("DE", 36, "Argo fixture", "synthetic-secret").unwrap();
        link.configure_wireless_access_point(&settings)
            .await
            .unwrap();
        peer.await.unwrap();
    }
}
