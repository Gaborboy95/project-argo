//! Shared selected microphone and exclusive capture. PCM never enters control IPC.
use serde::Serialize;
use serde_json::{Value, json};
use std::{process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, BufReader},
    process::{Child, ChildStdout},
    sync::{OwnedSemaphorePermit, Semaphore, watch},
};

#[derive(Clone, Default, Serialize)]
pub struct Input {
    pub id: String,
    pub name: String,
}
#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    pub inputs: Vec<Input>,
    pub selected: String,
    pub muted: bool,
    pub owner: String,
    pub detail: String,
}
#[derive(Clone)]
pub struct Voice {
    pub state: watch::Sender<Snapshot>,
    lease: Arc<Semaphore>,
}
impl Default for Voice {
    fn default() -> Self {
        Self {
            state: watch::channel(Snapshot::default()).0,
            lease: Arc::new(Semaphore::new(1)),
        }
    }
}
pub async fn graph() -> Result<Vec<Value>, String> {
    crate::connectivity::music::graph().await
}
pub fn props(node: &Value) -> &Value {
    &node["info"]["props"]
}
impl Voice {
    pub async fn refresh(&self) -> Result<(), String> {
        let nodes = graph().await?;
        let inputs = nodes
            .iter()
            .filter(|n| {
                props(n)["media.class"] == "Audio/Source"
                    && props(n)["device.api"] != "bluez5"
                    && !props(n)["factory.name"]
                        .as_str()
                        .unwrap_or("")
                        .contains("bluez5")
            })
            .filter_map(|n| {
                Some(Input {
                    id: props(n)["node.name"].as_str()?.into(),
                    name: props(n)["node.description"]
                        .as_str()
                        .unwrap_or("Microphone input")
                        .into(),
                })
            })
            .take(32)
            .collect::<Vec<_>>();
        self.state.send_modify(|s| {
            if s.selected.is_empty() && inputs.len() == 1 {
                s.selected = inputs[0].id.clone();
            }
            if s.owner != "cleanup uncertain" {
                s.detail = if inputs.iter().any(|n| n.id == s.selected) {
                    "Selected input available"
                } else {
                    "Connect/select the USB ADC or its mixed PipeWire input"
                }
                .into();
            }
            s.inputs = inputs;
        });
        Ok(())
    }
    pub fn select(&self, name: &str) -> Result<(), String> {
        let s = self.state.borrow();
        if !s.owner.is_empty() {
            return Err("Stop microphone capture before changing input".into());
        }
        if name.is_empty() || name.len() > 256 || name.contains('\0') {
            return Err("Invalid microphone input reference".into());
        }
        drop(s);
        self.state.send_modify(|s| s.selected = name.into());
        Ok(())
    }
    pub async fn claim(&self, owner: &str) -> Result<Lease, String> {
        let permit = self
            .lease
            .clone()
            .try_acquire_owned()
            .map_err(|_| "Microphone is already owned by another voice session")?;
        self.refresh().await?;
        let selected = self.state.borrow().selected.clone();
        if !self.state.borrow().inputs.iter().any(|n| n.id == selected) {
            return Err("Selected microphone is unavailable".into());
        }
        self.state.send_modify(|s| s.owner = owner.into());
        Ok(Lease {
            _permit: Some(permit),
            voice: self.clone(),
            source: selected,
        })
    }
}
pub struct Lease {
    _permit: Option<OwnedSemaphorePermit>,
    voice: Voice,
    pub source: String,
}
impl Lease {
    pub(crate) fn poison(&mut self) {
        if let Some(permit) = self._permit.take() {
            permit.forget();
        }
        self.voice.state.send_modify(|s|{s.owner="cleanup uncertain".into();s.detail="Microphone cleanup could not be confirmed; restart the daemon before capturing again".into();});
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if self._permit.is_some() {
            self.voice.state.send_modify(|s| s.owner.clear());
        }
    }
}

pub fn process(program: &str) -> tokio::process::Command {
    let mut c = tokio::process::Command::new("/usr/bin/setpriv");
    c.args(["--pdeathsig", "TERM", program])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    c
}
pub struct Capture {
    child: Child,
    output: PcmReader<BufReader<ChildStdout>>,
    pub lease: Lease,
}
impl Drop for Capture {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            self.lease.poison();
        }
    }
}
impl Capture {
    pub async fn open(voice: &Voice) -> Result<Self, String> {
        let lease = voice.claim("androidAuto").await?;
        let mut child=process("pw-cat").args(["--record","--raw","--rate","16000","--channels","1","--channel-map","MONO","--format","s16","--latency","20ms","--target",&lease.source,"--properties",
            &json!({"node.name":"argo.aa.microphone","media.role":"Communication","node.dont-reconnect":true,"stream.capture.sink":false}).to_string(),"-"])
            .stdout(Stdio::piped()).spawn().map_err(|e|format!("Cannot open PipeWire microphone: {e}"))?;
        let output = BufReader::with_capacity(
            640,
            child.stdout.take().ok_or("Microphone pipe unavailable")?,
        );
        Ok(Self {
            child,
            output: PcmReader::new(output),
            lease,
        })
    }
    pub async fn frame(&mut self) -> Result<Vec<u8>, String> {
        let mut bytes = self.output.frame().await?;
        if self.lease.voice.state.borrow().muted {
            bytes.fill(0);
        }
        Ok(bytes)
    }
    pub async fn close(&mut self) -> Result<(), String> {
        if self.child.try_wait().map_err(|e| e.to_string())?.is_none() {
            self.child.start_kill().map_err(|e| e.to_string())?;
        }
        self.child.wait().await.map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// The phone grants a bounded credit window; stale acknowledgements cannot
/// open a replacement microphone stream's window.
#[derive(Default)]
pub struct Credits {
    pub session: u32,
    outstanding: u32,
    limit: u32,
    last_ack: Option<tokio::time::Instant>,
}
impl Credits {
    pub fn start(&mut self, limit: u64) {
        self.session = self.session.wrapping_add(1).max(1);
        self.outstanding = 0;
        self.limit = limit.clamp(1, 8) as u32;
        self.last_ack = None;
    }
    pub fn ready(&self) -> bool {
        self.limit > 0 && self.outstanding < self.limit
    }
    pub fn sent(&mut self) {
        if self.outstanding == 0 {
            self.last_ack = Some(tokio::time::Instant::now());
        }
        self.outstanding += 1;
    }
    pub fn ack(&mut self, session: u64, count: u64) -> bool {
        if session == self.session as u64 && count > 0 && count <= self.outstanding as u64 {
            self.last_ack = Some(tokio::time::Instant::now());
            self.outstanding -= count as u32;
            return true;
        }
        false
    }
    pub fn expired(&self) -> bool {
        self.outstanding > 0
            && self
                .last_ack
                .is_some_and(|t| t.elapsed() >= Duration::from_secs(5))
    }
    pub fn stop(&mut self) {
        self.limit = 0;
        self.outstanding = 0;
    }
}

struct PcmReader<R> {
    input: R,
    frame: [u8; 640],
    used: usize,
    deadline: tokio::time::Instant,
}
impl<R: AsyncRead + Unpin> PcmReader<R> {
    fn new(input: R) -> Self {
        Self {
            input,
            frame: [0; 640],
            used: 0,
            deadline: tokio::time::Instant::now() + Duration::from_secs(2),
        }
    }
    async fn frame(&mut self) -> Result<Vec<u8>, String> {
        // A cancelled select never discards a partially read PCM sample/frame.
        while self.used < self.frame.len() {
            let n = tokio::time::timeout_at(
                self.deadline,
                self.input.read(&mut self.frame[self.used..]),
            )
            .await
            .map_err(|_| "Microphone input stalled")?
            .map_err(|_| "Microphone disconnected")?;
            if n == 0 {
                return Err("Microphone disconnected".into());
            }
            self.used += n;
        }
        self.used = 0;
        self.deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        Ok(self.frame.to_vec())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::FutureExt;
    use tokio::io::AsyncWriteExt;
    #[tokio::test(start_paused = true)]
    async fn pcm_select_cancellation_retains_partial_samples_and_stall_is_bounded() {
        let (mut writer, reader) = tokio::io::duplex(1280);
        let mut reader = PcmReader::new(reader);
        writer.write_all(&[7; 213]).await.unwrap();
        assert!(reader.frame().now_or_never().is_none());
        writer.write_all(&[8; 427]).await.unwrap();
        let frame = reader.frame().await.unwrap();
        assert_eq!(&frame[..213], &[7; 213]);
        assert_eq!(&frame[213..], &[8; 427]);
        tokio::time::advance(Duration::from_secs(3)).await;
        assert!(reader.frame().await.is_err());
    }
    #[test]
    fn microphone_protocol_controls_bounded_credit_and_replacement() {
        use crate::aa_channels::{Channels, DisplayConfig, Effect, Proto};
        let mut channels = Channels::new(DisplayConfig::default());
        channels.handle(0, 5, &[]).unwrap();
        channels
            .handle(9, 7, &Proto::default().number(1, 0).number(2, 9).finish())
            .unwrap();
        let request = Proto::default().number(1, 1).number(4, 200).finish();
        assert!(channels.handle(9, 0x8005, &request).is_err());
        channels
            .handle(9, 0x8000, &Proto::default().number(1, 1).finish())
            .unwrap();
        let effects = channels.handle(9, 0x8005, &request).unwrap();
        let mut credit = Credits::default();
        for e in effects {
            if let Effect::Microphone(true, limit) = e {
                credit.start(limit);
            }
        }
        for _ in 0..8 {
            assert!(credit.ready());
            credit.sent();
        }
        assert!(!credit.ready());
        let old = credit.session;
        credit.ack(old as u64, 9);
        assert!(!credit.ready());
        credit.ack(old as u64, 1);
        assert!(credit.ready());
        credit.stop();
        assert!(!credit.ready());
        credit.start(1);
        credit.sent();
        credit.ack(old as u64, 1);
        assert!(!credit.ready());
        credit.ack(credit.session as u64, 1);
        assert!(credit.ready());
    }
    #[test]
    fn exclusive_input_lease_stays_closed_after_uncertain_cleanup() {
        let voice = Voice::default();
        let permit = voice.lease.clone().try_acquire_owned().unwrap();
        let mut lease = Lease {
            _permit: Some(permit),
            voice: voice.clone(),
            source: "adc.mix".into(),
        };
        assert!(voice.lease.clone().try_acquire_owned().is_err());
        lease.poison();
        drop(lease);
        assert!(voice.lease.clone().try_acquire_owned().is_err());
        assert_eq!(voice.state.borrow().owner, "cleanup uncertain");
    }
}
