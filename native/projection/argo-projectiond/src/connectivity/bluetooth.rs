//! BlueZ owns bonds. Our non-default agent handles only app-initiated pairing.
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
        let agent = Agent {
            request_default: false,
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
            // No blanket service authorization or PIN fallback.
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
        let mut slot = self.pending.lock().unwrap();
        if slot.as_ref().is_some_and(|(value, _)| *value == id)
            && let Some((_, tx)) = slot.take()
        {
            let _ = tx.send(accept);
        }
    }
    pub fn device(&self, reference: &str) -> Result<bluer::Device, String> {
        let (adapter, address) = reference
            .split_once('/')
            .ok_or("Select a Bluetooth device")?;
        self.session
            .adapter(adapter)
            .map_err(|e| e.to_string())?
            .device(address.parse().map_err(|_| "Invalid Bluetooth reference")?)
            .map_err(|e| e.to_string())
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
                devices.push(Device {
                    id: format!("{name}/{address}"),
                    name: d.alias().await.unwrap_or_else(|_| address.to_string()),
                    paired: d.is_paired().await.unwrap_or(false),
                    connected: d.is_connected().await.unwrap_or(false),
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
            s.adapters = adapters;
            s.devices = devices;
        });
        Ok(())
    }
}

type Pending = Arc<Mutex<Option<(u64, oneshot::Sender<bool>)>>>;
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
    match tokio::time::timeout(Duration::from_secs(30), rx).await {
        Ok(Ok(true)) => Ok(()),
        _ => Err(ReqError::Rejected),
    }
}
