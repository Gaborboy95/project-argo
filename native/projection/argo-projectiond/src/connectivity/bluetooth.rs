//! BlueZ owns bonds; Argo owns the visible pairing decision for every radio.
use super::{Control, Device, Prompt, Radio};
use bluer::{
    Session,
    agent::{Agent, AgentHandle, ReqError},
};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::oneshot;

pub struct Bluetooth {
    pub session: Session,
    pub control: Control,
    _agent: AgentHandle,
    pending: Pending,
}
impl Bluetooth {
    pub async fn open(control: Control) -> Result<Self, String> {
        let session = Session::new().await.map_err(|e| e.to_string())?;
        let pending = Arc::new(Mutex::new(None));
        let p = pending.clone();
        let c = control.clone();
        let s = session.clone();
        let (ap, ac, ass) = (pending.clone(), control.clone(), session.clone());
        let (sp, sc, ss) = (pending.clone(), control.clone(), session.clone());
        let agent = Agent {
            request_default: true,
            request_confirmation: Some(Box::new(move |r| {
                let (p, c, s) = (p.clone(), c.clone(), s.clone());
                Box::pin(async move {
                    ask(
                        p,
                        c,
                        s,
                        r.adapter,
                        r.device,
                        format!("Confirm matching passkey {:06}", r.passkey),
                    )
                    .await
                })
            })),
            request_authorization: Some(Box::new(move |r| {
                Box::pin(ask(
                    ap.clone(),
                    ac.clone(),
                    ass.clone(),
                    r.adapter,
                    r.device,
                    "Authorize pairing requested by this device (no comparison passkey)".into(),
                ))
            })),
            authorize_service: Some(Box::new(move |r| {
                let (p, c, s) = (sp.clone(), sc.clone(), ss.clone());
                Box::pin(async move {
                    let paired = s
                        .adapter(&r.adapter)
                        .and_then(|a| a.device(r.device))
                        .map_err(|_| ReqError::Rejected)?
                        .is_paired()
                        .await
                        .map_err(|_| ReqError::Rejected)?;
                    if repeat_service_allowed(paired, &r.service.to_string()) {
                        return Ok(());
                    }
                    ask(
                        p,
                        c,
                        s,
                        r.adapter,
                        r.device,
                        "Allow a Bluetooth service connection from this device?".into(),
                    )
                    .await
                })
            })),
            // No silent PIN fallback or automatic approval of new bonds.
            ..Default::default()
        };
        let agent = session
            .register_agent(agent)
            .await
            .map_err(|e| e.to_string())?;
        Ok(Self {
            session,
            control,
            pending,
            _agent: agent,
        })
    }
    pub fn respond(&self, id: u64, accept: bool) {
        respond_pending(&self.pending, id, accept);
    }
    pub fn device(&self, reference: &str) -> Result<bluer::Device, String> {
        let reference = device_reference(reference)?;
        let (adapter, address) = reference
            .split_once('/')
            .ok_or("Select a Bluetooth device")?;
        self.session
            .adapter(adapter)
            .map_err(|e| e.to_string())?
            .device(address.parse().map_err(|_| "Invalid Bluetooth reference")?)
            .map_err(|e| e.to_string())
    }
    pub async fn disconnect_device(&self, reference: &str) -> Result<(), String> {
        let device = self.device(reference)?;
        match device.is_connected().await {
            Ok(false) => Ok(()),
            Ok(true) => match device.disconnect().await {
                Ok(()) => Ok(()),
                Err(error) if device_gone(&error.kind) => Ok(()),
                Err(error) => Err(error.to_string()),
            },
            // The CarPlay controller may disappear as its lease closes. An
            // already removed endpoint needs no replacement controller or bond.
            Err(error) if device_gone(&error.kind) => Ok(()),
            Err(error) => Err(error.to_string()),
        }
    }
    pub async fn refresh(&self) -> Result<(), String> {
        let names = self
            .session
            .adapter_names()
            .await
            .map_err(|e| e.to_string())?;
        let mut adapters = Vec::new();
        let mut devices = Vec::new();
        for name in names.into_iter().take(8) {
            let a = self.session.adapter(&name).map_err(|e| e.to_string())?;
            adapters.push(Radio {
                usable: None,
                detail: None,
                address: Some(a.address().await.map_err(|e| e.to_string())?.to_string()),
                id: name.clone(),
                name: format!("{} ({})", a.alias().await.unwrap_or_default(), name),
            });
            for address in a
                .device_addresses()
                .await
                .map_err(|e| e.to_string())?
                .into_iter()
                .take(64)
            {
                let d = a.device(address).map_err(|e| e.to_string())?;
                if devices.len() >= 64 {
                    break;
                }
                let uuids = d.uuids().await.unwrap_or_default().unwrap_or_default();
                devices.push(Device {
                    id: format!("{name}/{address}"),
                    name: d.alias().await.unwrap_or_else(|_| address.to_string()),
                    paired: d.is_paired().await.unwrap_or(false),
                    connected: d.is_connected().await.unwrap_or(false),
                    protocols: protocols(uuids.iter().map(|u| u.to_string())),
                    audio_source: audio_source(uuids.iter().map(|u| u.to_string())),
                });
            }
        }
        self.control.state.send_modify(|s| {
            if !s.adapter_address.is_empty() {
                // Do not silently switch radios when USB enumeration changes.
                s.adapter = adapters
                    .iter()
                    .find(|a| a.address.as_deref() == Some(&s.adapter_address))
                    .map(|a| a.id.clone())
                    .unwrap_or_default();
            } else if s.adapter.is_empty() && adapters.len() == 1 {
                s.adapter = adapters[0].id.clone();
                s.adapter_address = adapters[0].address.clone().unwrap_or_default();
            }
            // BlueZ enumerates maps; polling order must not move device rows.
            adapters.sort_by(|a, b| a.address.cmp(&b.address).then(a.id.cmp(&b.id)));
            devices.sort_by(|a, b| a.id.cmp(&b.id));
            s.adapters = adapters;
            s.devices = devices;
        });
        Ok(())
    }
}

fn device_gone(kind: &bluer::ErrorKind) -> bool {
    matches!(
        kind,
        bluer::ErrorKind::NotFound | bluer::ErrorKind::DoesNotExist
    )
}

/// Exact BlueZ command target, with a canonical address. No alias or wildcard
/// can accidentally disconnect another phone or change a controller setting.
pub fn device_reference(reference: &str) -> Result<String, String> {
    let (adapter, address) = reference
        .split_once('/')
        .ok_or("Select a Bluetooth device")?;
    let number = adapter
        .strip_prefix("hci")
        .ok_or("Invalid Bluetooth adapter")?;
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Invalid Bluetooth adapter".into());
    }
    let address: bluer::Address = address.parse().map_err(|_| "Invalid Bluetooth reference")?;
    Ok(format!("{adapter}/{address}"))
}

fn protocols(uuids: impl IntoIterator<Item = String>) -> Vec<&'static str> {
    let mut android_auto = false;
    let mut carplay = false;
    for uuid in uuids {
        match uuid.to_ascii_lowercase().as_str() {
            "4de17a00-52cb-11e6-bdf4-0800200c9a66" => android_auto = true,
            "ec884348-cd41-40a2-9727-575d50bf1fd3"
            | "00000000-deca-fade-deca-deafdecacafe"
            | "00000000-deca-fade-deca-deafdecacaff" => carplay = true,
            _ => {}
        }
    }
    [
        android_auto.then_some("android-auto"),
        carplay.then_some("carplay"),
    ]
    .into_iter()
    .flatten()
    .collect()
}

fn audio_source(uuids: impl IntoIterator<Item = String>) -> bool {
    uuids
        .into_iter()
        .any(|uuid| uuid.eq_ignore_ascii_case("0000110a-0000-1000-8000-00805f9b34fb"))
}

type Pending = Arc<Mutex<Option<(u64, oneshot::Sender<bool>)>>>;

fn respond_pending(pending: &Pending, id: u64, accept: bool) {
    let mut slot = pending.lock().unwrap();
    if slot.as_ref().is_some_and(|(value, _)| *value == id)
        && let Some((_, tx)) = slot.take()
    {
        let _ = tx.send(accept);
    }
}

/// Existing bonds may reconnect only the phone services Argo uses without a
/// second pairing decision. Unknown profiles still require an explicit answer.
fn repeat_service_allowed(paired: bool, service: &str) -> bool {
    paired
        && matches!(
            service,
            "0000110a-0000-1000-8000-00805f9b34fb" | // audio source
        "0000110b-0000-1000-8000-00805f9b34fb" | // audio sink
        "0000110c-0000-1000-8000-00805f9b34fb" | // AVRCP target
        "0000110e-0000-1000-8000-00805f9b34fb" | // AVRCP
        "0000110f-0000-1000-8000-00805f9b34fb" | // AVRCP controller
        "00001108-0000-1000-8000-00805f9b34fb" | // headset
        "00001112-0000-1000-8000-00805f9b34fb" | // headset gateway
        "0000111e-0000-1000-8000-00805f9b34fb" | // handsfree
        "0000111f-0000-1000-8000-00805f9b34fb" | // handsfree gateway
        "4de17a00-52cb-11e6-bdf4-0800200c9a66" | // Android Auto
        "00000000-deca-fade-deca-deafdecacaff" | // iAP2
        "00000000-deca-fade-deca-deafdecacafe" |
        "ec884348-cd41-40a2-9727-575d50bf1fd3" // CarPlay
        )
}

async fn ask(
    p: Pending,
    c: Control,
    s: Session,
    adapter: String,
    address: bluer::Address,
    text: String,
) -> Result<(), ReqError> {
    let device = format!("{}/{}", adapter, address);
    let name = s
        .adapter(&adapter)
        .map_err(|_| ReqError::Rejected)?
        .device(address)
        .map_err(|_| ReqError::Rejected)?
        .alias()
        .await
        .unwrap_or_else(|_| device.clone());
    request_decision(p, c, device, name, text).await
}

async fn request_decision(
    p: Pending,
    c: Control,
    device: String,
    name: String,
    text: String,
) -> Result<(), ReqError> {
    if c.stopping.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(ReqError::Rejected);
    }
    let mut client_closed = c.client_closed.subscribe();
    let id = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64;
    let (tx, rx) = oneshot::channel();
    {
        let mut slot = p.lock().unwrap();
        if slot.is_some() {
            return Err(ReqError::Rejected);
        }
        *slot = Some((id, tx));
    }
    c.state.send_modify(|state| {
        state.prompt = Some(Prompt {
            id,
            device,
            name,
            text,
        })
    });
    // Drop guard also clears UI when BlueZ cancels the callback.
    struct Clear {
        p: Pending,
        c: Control,
        id: u64,
    }
    impl Drop for Clear {
        fn drop(&mut self) {
            let mut slot = self.p.lock().unwrap();
            if slot.as_ref().is_some_and(|(id, _)| *id == self.id) {
                slot.take();
            }
            self.c.state.send_modify(|s| {
                if s.prompt.as_ref().is_some_and(|p| p.id == self.id) {
                    s.prompt = None;
                }
            });
        }
    }
    let _clear = Clear { p, c, id };
    tokio::select! {
        result = tokio::time::timeout(Duration::from_secs(30), rx) => match result {
            Ok(Ok(true)) => Ok(()),
            _ => Err(ReqError::Rejected),
        },
        _ = client_closed.changed() => Err(ReqError::Canceled),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_source_requires_positive_a2dp_source_not_headset_sink_or_avrcp() {
        assert!(audio_source(
            ["0000110A-0000-1000-8000-00805F9B34FB".into()]
        ));
        assert!(!audio_source([
            "0000110b-0000-1000-8000-00805f9b34fb".into()
        ]));
        assert!(!audio_source([
            "0000110e-0000-1000-8000-00805f9b34fb".into()
        ]));
        assert!(!audio_source(Vec::new()));
        let phone = Device {
            audio_source: true,
            ..Default::default()
        };
        assert_eq!(serde_json::to_value(phone).unwrap()["audio_source"], true);
        assert_eq!(
            serde_json::to_value(Device::default()).unwrap()["audio_source"],
            false
        );
    }

    #[test]
    fn phone_protocols_require_positive_service_capabilities() {
        assert!(protocols(["0000110b-0000-1000-8000-00805f9b34fb".into()]).is_empty());
        assert_eq!(
            protocols(["4DE17A00-52CB-11E6-BDF4-0800200C9A66".into()]),
            ["android-auto"]
        );
        assert_eq!(
            protocols(["00000000-deca-fade-deca-deafdecacafe".into()]),
            ["carplay"]
        );
        assert_eq!(
            protocols([
                "ec884348-cd41-40a2-9727-575d50bf1fd3".into(),
                "4de17a00-52cb-11e6-bdf4-0800200c9a66".into(),
                "00000000-deca-fade-deca-deafdecacaff".into(),
            ]),
            ["android-auto", "carplay"]
        );
    }

    #[test]
    fn physical_device_commands_require_one_exact_adapter_and_address() {
        assert!(device_gone(&bluer::ErrorKind::NotFound));
        assert!(device_gone(&bluer::ErrorKind::DoesNotExist));
        assert!(!device_gone(&bluer::ErrorKind::NotAuthorized));
        assert_eq!(
            device_reference("hci12/aa:bb:cc:dd:ee:ff").unwrap(),
            "hci12/AA:BB:CC:DD:EE:FF"
        );
        for reference in [
            "",
            "hci0",
            "hci/AA:BB:CC:DD:EE:FF",
            "hci*/AA:BB:CC:DD:EE:FF",
            "other/AA:BB:CC:DD:EE:FF",
            "hci0/phone",
            "hci0/AA:BB:CC:DD:EE:FF/other",
        ] {
            assert!(device_reference(reference).is_err(), "{reference}");
        }
    }

    #[test]
    fn a_bond_is_required_for_known_phone_service_reconnection() {
        let carplay = "ec884348-cd41-40a2-9727-575d50bf1fd3";
        assert!(repeat_service_allowed(true, carplay));
        assert!(!repeat_service_allowed(false, carplay));
        assert!(!repeat_service_allowed(
            true,
            "00001105-0000-1000-8000-00805f9b34fb"
        ));
        assert!(!repeat_service_allowed(true, "arbitrary service"));
    }

    fn start_prompt(p: Pending, c: Control) -> tokio::task::JoinHandle<Result<(), ReqError>> {
        tokio::spawn(request_decision(
            p,
            c,
            "hci1/02:00:00:00:00:01".into(),
            "Fixture iPhone".into(),
            "Confirm matching passkey 123456".into(),
        ))
    }

    #[tokio::test]
    async fn only_the_current_prompt_can_confirm_incoming_pairing_on_another_radio() {
        let (control, _requests) = Control::new();
        control.state.send_modify(|s| s.adapter = "hci0".into());
        let pending = Arc::new(Mutex::new(None));
        let task = start_prompt(pending.clone(), control.clone());
        tokio::task::yield_now().await;
        let prompt = control.state.borrow().prompt.clone().unwrap();
        assert!(prompt.device.starts_with("hci1/"));
        respond_pending(&pending, prompt.id.wrapping_add(1), true);
        assert!(pending.lock().unwrap().is_some());
        respond_pending(&pending, prompt.id, true);
        assert!(task.await.unwrap().is_ok());
        assert!(control.state.borrow().prompt.is_none());
        assert!(pending.lock().unwrap().is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn timeout_app_disconnect_and_bluez_cancellation_withdraw_the_prompt() {
        for reason in 0..3 {
            let (control, _requests) = Control::new();
            let pending = Arc::new(Mutex::new(None));
            let task = start_prompt(pending.clone(), control.clone());
            tokio::task::yield_now().await;
            assert!(control.state.borrow().prompt.is_some());
            match reason {
                0 => tokio::time::advance(Duration::from_secs(31)).await,
                1 => control
                    .client_closed
                    .send_modify(|generation| *generation += 1),
                _ => task.abort(),
            }
            if let Ok(result) = task.await {
                assert!(result.is_err());
            }
            assert!(control.state.borrow().prompt.is_none());
            assert!(pending.lock().unwrap().is_none());
        }
    }
}
