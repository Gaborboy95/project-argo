use crate::link::LinkClient;
use crate::wifi::WifiStatus;
use serde::Serialize;

pub const CONTROL_CONTRACT: u32 = 1;

#[derive(Clone, Debug, Serialize)]
pub struct Health {
    pub contract: u32,
    pub checked_at_unix_ms: u64,
    pub mfi_checked_at_unix_ms: u64,
    #[serde(skip)]
    mfi_error: Option<String>,
    pub implementation: &'static str,
    pub session_validated: bool,
    pub discovery: &'static str,
    pub address: Option<String>,
    pub mfi: &'static str,
    pub protocol_major: Option<u8>,
    pub certificate_bytes: Option<usize>,
    pub wifi: &'static str,
    pub wifi_status: Option<WifiStatus>,
    pub bluetooth_bridge: &'static str,
    pub iap_handoff: &'static str,
    pub error: Option<String>,
}
impl Default for Health {
    fn default() -> Self {
        Self {
            contract: CONTROL_CONTRACT,
            checked_at_unix_ms: 0,
            mfi_checked_at_unix_ms: 0,
            mfi_error: None,
            implementation: "diagnostics-only",
            session_validated: false,
            discovery: "unavailable",
            address: None,
            mfi: "unavailable",
            protocol_major: None,
            certificate_bytes: None,
            wifi: "unavailable",
            wifi_status: None,
            bluetooth_bridge: "not-probed",
            iap_handoff: "not-probed",
            error: None,
        }
    }
}

pub async fn probe(client: &LinkClient) -> Health {
    let mut health = Health {
        checked_at_unix_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64,
        ..Health::default()
    };
    match client.resolve().await {
        Ok(address) => {
            health.discovery = "resolved";
            health.address = Some(address.to_string());
        }
        Err(error) => {
            health.error = Some(error.to_string());
            return health;
        }
    }
    match client.certificate().await {
        Ok(certificate) => {
            // Public certificate bytes remain native and in memory only.
            health.certificate_bytes = Some(certificate.len());
            match client.protocol_major().await {
                Ok(major) => {
                    health.protocol_major = Some(major);
                    health.mfi = "ready";
                }
                Err(error) => {
                    health.mfi = "certificate-only";
                    health.mfi_error = Some(error.to_string());
                }
            }
        }
        Err(error) => health.mfi_error = Some(error.to_string()),
    }
    health.mfi_checked_at_unix_ms = now_ms();
    health.error = health.mfi_error.clone();
    match client.wifi_status().await {
        Ok(status) => {
            health.wifi = "ready";
            health.wifi_status = Some(status);
        }
        Err(error) => {
            if health.error.is_none() {
                health.error = Some(error.to_string());
            }
        }
    }
    health
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// The periodic monitor never touches the authentication IC. Bootstrap performs
/// the full probe before owning iAP/AirPlay; live monitoring cannot steal its MFi
/// connection or signing permit, including on old single-client Link firmware.
pub struct NetworkHealth {
    checked: u64,
    address: Option<std::net::Ipv4Addr>,
    wifi: Option<WifiStatus>,
    error: Option<String>,
}
impl NetworkHealth {
    pub fn apply(self, health: &mut Health) {
        let address = self.address.map(|a| a.to_string());
        if address.is_none() || address != health.address {
            health.mfi = "unavailable";
            health.protocol_major = None;
            health.certificate_bytes = None;
            health.mfi_checked_at_unix_ms = 0;
            health.mfi_error = None;
        }
        health.checked_at_unix_ms = self.checked;
        health.discovery = if address.is_some() {
            "resolved"
        } else {
            "unavailable"
        };
        health.address = address;
        health.wifi = if self.wifi.is_some() {
            "ready"
        } else {
            "unavailable"
        };
        health.wifi_status = self.wifi;
        health.error = self.error.or_else(|| health.mfi_error.clone());
    }
}

pub async fn probe_network(client: &LinkClient) -> NetworkHealth {
    let mut health = NetworkHealth {
        checked: now_ms(),
        address: None,
        wifi: None,
        error: None,
    };
    match client.resolve().await {
        Ok(address) => health.address = Some(address),
        Err(error) => {
            health.error = Some(error.to_string());
            return health;
        }
    }
    match client.wifi_status().await {
        Ok(status) => health.wifi = Some(status),
        Err(error) => health.error = Some(error.to_string()),
    }
    health
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn network_monitor_refreshes_radios_without_opening_the_mfi_service() {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
            time::{Duration, timeout},
        };
        let mfi = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let wifi = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client = LinkClient::new(crate::link::LinkConfig {
            discovery: crate::discovery::Discovery::Address("127.0.0.1".parse().unwrap()),
            mfi_port: mfi.local_addr().unwrap().port(),
            wifi_port: wifi.local_addr().unwrap().port(),
            deadline: Duration::from_secs(1),
        })
        .unwrap();
        let responder = tokio::spawn(async move {
            let (mut socket, _) = wifi.accept().await.unwrap();
            let mut command = [0; 7];
            socket.read_exact(&mut command).await.unwrap();
            assert_eq!(&command, b"status\n");
            socket
                .write_all(b"state on\nbt on\ncountry_code HU\nchannel 36\nok\n")
                .await
                .unwrap();
        });
        let mut cached = Health {
            address: Some("127.0.0.1".into()),
            discovery: "resolved",
            mfi: "ready",
            protocol_major: Some(3),
            certificate_bytes: Some(123),
            mfi_checked_at_unix_ms: 42,
            ..Health::default()
        };
        probe_network(&client).await.apply(&mut cached);
        responder.await.unwrap();
        assert_eq!(cached.mfi, "ready");
        assert_eq!(cached.mfi_checked_at_unix_ms, 42);
        assert_eq!(cached.wifi, "ready");
        assert!(
            timeout(Duration::from_millis(10), mfi.accept())
                .await
                .is_err()
        );
        NetworkHealth {
            checked: 99,
            address: None,
            wifi: None,
            error: Some("unplugged".into()),
        }
        .apply(&mut cached);
        assert_eq!(cached.mfi, "unavailable");
        assert_eq!(cached.mfi_checked_at_unix_ms, 0);
        assert!(cached.address.is_none());
    }
}
