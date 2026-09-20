//! Typed subset of the LIVI Link Wi-Fi protocol, researched in
//! livi-wifi/src/server.rs at a23dc0c5fcdb6d069c679eddfd73298e58f44783.
use crate::link::{Error, LinkClient, deadline};
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
    pub async fn wifi_status(&self) -> Result<WifiStatus, Error> {
        let _guard = self.permit.try_lock().map_err(|_| Error::Busy)?;
        deadline(self.config.deadline, async {
            let mut connection = self.connect(self.config.wifi_port).await?;
            let response = exchange(&mut connection, "status\n").await?;
            parse_status(&response)
        })
        .await
    }

    /// Explicit radio ownership operation. Never called by discovery/probes/startup.
    pub async fn set_access_point_enabled(&self, enabled: bool) -> Result<(), Error> {
        let _guard = self.permit.try_lock().map_err(|_| Error::Busy)?;
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
        let _guard = self.permit.try_lock().map_err(|_| Error::Busy)?;
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
