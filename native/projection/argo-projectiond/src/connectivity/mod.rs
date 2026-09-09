//! Shared, protocol-neutral connectivity state. BlueZ and NM retain secrets.
pub mod bluetooth;
pub mod music;
pub mod network;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};

#[derive(Clone, Default, Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub paired: bool,
    pub connected: bool,
}
#[derive(Clone, Default, Serialize)]
pub struct Radio {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    pub id: String,
    pub name: String,
}
#[derive(Clone, Serialize)]
pub struct Prompt {
    pub id: u64,
    pub device: String,
    pub name: String,
    pub text: String,
}
#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub music: Option<music::Snapshot>,
    pub adapters: Vec<Radio>,
    pub networks: Vec<Radio>,
    pub devices: Vec<Device>,
    pub adapter: String,
    #[serde(skip)]
    pub adapter_address: String,
    pub interface: String,
    pub selected: String,
    pub enabled: bool,
    pub discovering: bool,
    pub prompt: Option<Prompt>,
    pub phase: String,
    pub detail: String,
    pub wifi_connected: bool,
    pub cleanup_error: String,
    pub band: network::ApBand,
    pub ap_frequency_mhz: Option<u32>,
}
impl Snapshot {
    pub fn require_selected_adapter(&self, device: &str) -> Result<(), String> {
        if self.adapter.is_empty() || !self.adapters.iter().any(|a| a.id == self.adapter) {
            return Err("Select an available Bluetooth adapter in Settings".into());
        }
        if device.split_once('/').map(|(a, _)| a) != Some(self.adapter.as_str()) {
            return Err("Device belongs to a different Bluetooth adapter; use the shared Settings selection".into());
        }
        Ok(())
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    #[serde(skip)]
    pub generation: u64,
    pub action: String,
    #[serde(default)]
    pub target: String,
    #[serde(default)]
    pub accept: bool,
    #[serde(default)]
    pub prompt: u64,
}
#[derive(Clone)]
pub struct Control {
    pub music_cancel: watch::Sender<u64>,
    pub client_closed: watch::Sender<u64>,
    pub state: watch::Sender<Snapshot>,
    pub requests: mpsc::Sender<Request>,
}
impl Control {
    pub fn new() -> (Self, mpsc::Receiver<Request>) {
        let (state, _) = watch::channel(Snapshot {
            phase: "disabled".into(),
            detail: "Wireless is disabled".into(),
            ..Default::default()
        });
        let (requests, rx) = mpsc::channel(16);
        (
            Self {
                music_cancel: watch::channel(0).0,
                state,
                requests,
                client_closed: watch::channel(0).0,
            },
            rx,
        )
    }
    pub fn message(&self) -> crate::ipc::Message {
        crate::ipc::Message {
            kind: 30,
            payload: serde_json::to_vec(&*self.state.borrow()).expect("connectivity snapshot"),
        }
    }
    pub fn request(&self, bytes: &[u8]) -> Result<(), String> {
        if bytes.len() > 2048 {
            return Err("Connectivity request too large".into());
        }
        let mut r: Request =
            serde_json::from_slice(bytes).map_err(|_| "Malformed connectivity request")?;
        if r.action == "clientClosed" {
            return Err("Reserved connectivity action".into());
        }
        if r.target.len() > 256 {
            return Err("Connectivity reference too long".into());
        }
        if r.action == "musicDisconnect"
            || (r.action == "forget"
                && self
                    .state
                    .borrow()
                    .music
                    .as_ref()
                    .is_some_and(|m| m.device == r.target))
        {
            self.music_cancel.send_modify(|generation| *generation += 1);
        }
        r.generation = *self.music_cancel.borrow();
        self.requests
            .try_send(r)
            .map_err(|_| "Connectivity is busy or unavailable".into())
    }
    pub fn progress(&self, phase: &str, detail: impl Into<String>) {
        self.state.send_modify(|s| {
            if phase == "unavailable" {
                s.adapters.clear();
                s.networks.clear();
                s.devices.clear();
                s.enabled = false;
                s.prompt = None;
                s.discovering = false;
            }
            s.phase = phase.into();
            s.detail = detail.into();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn music_stop_revokes_queued_work_before_radio_worker_runs() {
        let (control, mut requests) = Control::new();
        control
            .request(br#"{"action":"musicConnect","target":"hci0/00:11:22:33:44:55"}"#)
            .unwrap();
        let queued = requests.try_recv().unwrap();
        control.request(br#"{"action":"musicDisconnect"}"#).unwrap();
        assert_ne!(queued.generation, *control.music_cancel.borrow());
        requests.try_recv().unwrap();
        control
            .request(br#"{"action":"musicConnect","target":"hci0/00:11:22:33:44:55"}"#)
            .unwrap();
        assert_eq!(
            requests.try_recv().unwrap().generation,
            *control.music_cancel.borrow()
        );
        control.state.send_modify(|s| {
            s.music = Some(music::Snapshot {
                device: "hci0/00:11:22:33:44:55".into(),
                ..Default::default()
            })
        });
        let generation = *control.music_cancel.borrow();
        control
            .request(br#"{"action":"forget","target":"hci0/00:11:22:33:44:55"}"#)
            .unwrap();
        assert!(*control.music_cancel.borrow() > generation);
    }
    #[test]
    fn bounded_secret_free_ipc_and_device_scoped_confirmation() {
        let (control, mut requests) = Control::new();
        control.state.send_modify(|s| {
            s.prompt = Some(Prompt {
                id: 42,
                device: "hci0/02:00:00:00:00:01".into(),
                name: "Test phone".into(),
                text: "Confirm matching passkey 123456".into(),
            })
        });
        let encoded = crate::ipc::encode(&control.message())
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        assert_eq!(
            encoded,
            include_str!("../../../../../test/fixtures/projection/ipc_v5_connectivity.hex").trim()
        );
        assert!(
            control
                .request(br#"{"action":"confirm","prompt":42,"accept":false}"#)
                .is_ok()
        );
        assert!(!requests.try_recv().unwrap().accept);
        assert!(
            control
                .request(br#"{"action":"connect","password":"forbidden"}"#)
                .is_err()
        );
        assert!(control.request(&vec![b' '; 2049]).is_err());
    }
}

#[cfg(test)]
mod adapter_tests {
    use super::*;
    #[test]
    fn shared_adapter_admission_rejects_other_and_missing_radios() {
        let mut state = Snapshot {
            adapter: "hci1".into(),
            adapters: vec![
                Radio {
                    id: "hci0".into(),
                    ..Default::default()
                },
                Radio {
                    id: "hci1".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert!(
            state
                .require_selected_adapter("hci1/00:11:22:33:44:55")
                .is_ok()
        );
        assert!(
            state
                .require_selected_adapter("hci0/00:11:22:33:44:55")
                .is_err()
        );
        state.adapters.pop();
        assert!(
            state
                .require_selected_adapter("hci1/00:11:22:33:44:55")
                .is_err()
        );
    }
}
