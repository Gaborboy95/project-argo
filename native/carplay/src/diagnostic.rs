use crate::link::LinkClient;
use crate::wifi::WifiStatus;
use serde::Serialize;

pub const CONTROL_CONTRACT: u32 = 1;

#[derive(Clone, Debug, Serialize)]
pub struct Health {
    pub contract: u32,
    pub checked_at_unix_ms: u64,
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
                    health.error = Some(error.to_string());
                }
            }
        }
        Err(error) => health.error = Some(error.to_string()),
    }
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
