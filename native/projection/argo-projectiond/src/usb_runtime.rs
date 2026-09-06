#![cfg(feature = "linux-usb")]

use std::collections::HashSet;
use std::time::{Duration, Instant};

use futures_lite::StreamExt;
use nusb::hotplug::HotplugEvent;
use nusb::{DeviceId, DeviceInfo};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::{AbortHandle, JoinHandle, JoinSet};

use crate::daemon_state::ProjectionRuntimeSnapshot;
use crate::host_control::HostControl;
#[cfg(test)]
use crate::session::AndroidAutoSessionEngine;
use crate::session::{AndroidAutoTransport, negotiate_version};
use crate::usb::nusb_backend::{
    UsbAaTransport, is_accessory, is_candidate, request_accessory_mode,
};
use crate::usb::{UsbConnectionState, UsbConnectionStateMachine, UsbDeviceKey};

const SETUP_TIMEOUT: Duration = Duration::from_secs(10);

enum WorkResult {
    BeforeStart {
        key: UsbDeviceKey,
        version: u16,
        acknowledged: oneshot::Sender<bool>,
    },
    Aoap {
        key: UsbDeviceKey,
        result: Result<u16, String>,
    },
    Version {
        key: UsbDeviceKey,
        result: Result<(u16, u16), String>,
    },
}

struct ActiveSession {
    id: DeviceId,
    cancel: watch::Sender<bool>,
    task: JoinHandle<()>,
}

impl ActiveSession {
    async fn stop(self) {
        self.cancel.send_replace(true);
        let _ = self.task.await;
    }
}

/// Owns all attempts and transfers. Only hotplug events trigger discovery;
/// the one deadline below bounds an expected accessory re-enumeration.
pub async fn run(
    state_tx: watch::Sender<ProjectionRuntimeSnapshot>,
    mut shutdown: watch::Receiver<bool>,
    control: HostControl,
) -> Result<(), String> {
    let mut watcher = nusb::watch_devices().map_err(|error| error.to_string())?;
    let (work_tx, mut work_rx) = mpsc::channel(8);
    let mut lifecycle = UsbConnectionStateMachine::default();
    let mut active_session = None;
    let mut probes = JoinSet::new();
    let mut probe: Option<(DeviceId, AbortHandle)> = None;
    // Failed enumerations stay parked even if another phone is subsequently
    // tried. Removal clears the entry; no retry timer can issue AOAP requests.
    let mut attempted = HashSet::new();

    crate::daemon_log!(
        Info,
        "usb-runtime",
        "argo-projectiond: Linux USB hotplug watching started"
    );
    let initial = tokio::select! {
        value = nusb::list_devices() => value,
        _ = shutdown.changed() => return Ok(()),
    };
    match initial {
        Ok(devices) => {
            for info in devices {
                connected(
                    info,
                    &mut lifecycle,
                    &state_tx,
                    &work_tx,
                    &mut active_session,
                    &mut probes,
                    &mut probe,
                    &mut attempted,
                    &control,
                );
            }
        }
        Err(error) => crate::daemon_log!(
            Error,
            "usb-runtime",
            "argo-projectiond: initial USB discovery failed: {error}"
        ),
    }

    let result = loop {
        let deadline = match lifecycle.state() {
            UsbConnectionState::WaitingForAccessory { deadline, .. } => Some(*deadline),
            _ => None,
        };
        tokio::select! {
            biased;
            _ = shutdown.changed() => break Ok(()),
            event = watcher.next() => match event {
                Some(HotplugEvent::Connected(info)) => connected(
                    info, &mut lifecycle, &state_tx, &work_tx, &mut active_session,
                    &mut probes, &mut probe, &mut attempted, &control),
                Some(HotplugEvent::Disconnected(id)) => {
                    attempted.remove(&id);
                    let waiting = matches!(lifecycle.state(), UsbConnectionState::WaitingForAccessory { .. });
                    if lifecycle.removed(&format!("{id:?}")) {
                        if waiting {
                            crate::daemon_log!(Debug, "usb-runtime", "original USB device removed; waiting for Android accessory");
                        } else {
                            if probe.as_ref().is_some_and(|(current, _)| *current == id)
                                && let Some((_, handle)) = probe.take() { handle.abort(); }
                            if active_session.as_ref().is_some_and(|session| session.id == id)
                                && let Some(session) = active_session.take() { session.stop().await; }
                            state_tx.send_replace(ProjectionRuntimeSnapshot::default());
                            crate::daemon_log!(Info, "usb-runtime", "Android Auto USB device removed; session cleared");
                        }
                    }
                }
                None => break Err("USB hotplug stream ended".to_owned()),
            },
            Some(result) = work_rx.recv() => handle_work_result(result, &mut lifecycle, &state_tx),
            _ = probes.join_next(), if !probes.is_empty() => {},
            _ = wait_for_deadline(deadline) => {
                if lifecycle.expire_accessory_wait(Instant::now()) {
                    let reason = "timed out waiting for Android accessory re-enumeration";
                    crate::daemon_log!(Error, "usb-runtime", "argo-projectiond: {reason}");
                    if matches!(lifecycle.state(), UsbConnectionState::Disconnected) {
                        state_tx.send_replace(ProjectionRuntimeSnapshot::default());
                    } else { publish_failure(&state_tx, reason.to_owned()); }
                }
            },
        }
    };

    // Stop producers before awaiting them so a pending result cannot block
    // shutdown on a full channel. Every endpoint is dropped on all exits.
    work_rx.close();
    probes.shutdown().await;
    if let Some(session) = active_session {
        session.stop().await;
    }
    state_tx.send_replace(ProjectionRuntimeSnapshot::default());
    result
}

async fn wait_for_deadline(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline.into()).await,
        None => std::future::pending().await,
    }
}

#[allow(clippy::too_many_arguments)] // One loop owns these resources, not a global manager.
fn connected(
    info: DeviceInfo,
    lifecycle: &mut UsbConnectionStateMachine,
    state_tx: &watch::Sender<ProjectionRuntimeSnapshot>,
    work_tx: &mpsc::Sender<WorkResult>,
    active_session: &mut Option<ActiveSession>,
    probes: &mut JoinSet<()>,
    probe: &mut Option<(DeviceId, AbortHandle)>,
    attempted: &mut HashSet<DeviceId>,
    control: &HostControl,
) {
    if attempted.contains(&info.id()) {
        return;
    }
    let key = device_key(&info);
    if is_accessory(&info) {
        if !lifecycle.accessory_discovered(key.clone(), Instant::now()) {
            return;
        }
        attempted.insert(info.id());
        crate::daemon_log!(Info, "usb-runtime", "Android accessory detected");
        lifecycle.session_starting(&key.id);
        publish_connecting(state_tx, &info);
        *active_session = Some(start_session(
            info,
            key,
            work_tx.clone(),
            control.clone(),
            state_tx.clone(),
        ));
    } else if is_candidate(&info) && lifecycle.candidate_discovered(key.clone()) {
        attempted.insert(info.id());
        crate::daemon_log!(
            Info,
            "usb-runtime",
            "USB candidate detected: {:04x}:{:04x}",
            info.vendor_id(),
            info.product_id()
        );
        publish_connecting(state_tx, &info);
        let tx = work_tx.clone();
        let id = info.id();
        let handle = probes.spawn(async move {
            let request_key = key.clone();
            let before_tx = tx.clone();
            let operation = request_accessory_mode(&info, move |version| async move {
                let (acknowledged, response) = oneshot::channel();
                if before_tx
                    .send(WorkResult::BeforeStart {
                        key: request_key,
                        version,
                        acknowledged,
                    })
                    .await
                    .is_err()
                {
                    return false;
                }
                response.await.unwrap_or(false)
            });
            let result = tokio::time::timeout(Duration::from_secs(20), operation)
                .await
                .unwrap_or_else(|_| Err("AOAP setup timed out".to_owned()));
            let _ = tx.send(WorkResult::Aoap { key, result }).await;
        });
        *probe = Some((id, handle));
    }
}

fn handle_work_result(
    result: WorkResult,
    lifecycle: &mut UsbConnectionStateMachine,
    state_tx: &watch::Sender<ProjectionRuntimeSnapshot>,
) {
    match result {
        WorkResult::BeforeStart {
            key,
            version,
            acknowledged,
        } => {
            let allowed = lifecycle.accessory_switch_requested(&key.id, version, Instant::now());
            let _ = acknowledged.send(allowed);
        }
        WorkResult::Aoap {
            key,
            result: Err(error),
        } => {
            // Re-enumeration may already have completed by the time START's
            // transfer completes. Never downgrade the new accessory session.
            if matches!(lifecycle.state(), UsbConnectionState::WaitingForAccessory { original, .. } if original.id == key.id)
            {
                crate::daemon_log!(
                    Warn,
                    "usb-runtime",
                    "AOAP START completion: {error}; retaining bounded accessory wait"
                );
            } else if lifecycle.probe_failed(&key.id, error.clone()) {
                crate::daemon_log!(Error, "usb-runtime", "AOAP probe/switch failed: {error}");
                publish_failure(state_tx, format!("AOAP probe/switch failed: {error}"));
            }
        }
        WorkResult::Aoap { result: Ok(_), .. } => {}
        WorkResult::Version {
            key,
            result: Ok((major, minor)),
        } => {
            if lifecycle.version_negotiated(&key.id, major, minor) {
                crate::daemon_log!(
                    Info,
                    "usb-runtime",
                    "Android Auto version negotiation succeeded: phone protocol major={major} minor={minor}"
                );
                // TLS/session work continues inside the same transport owner.
            }
        }
        WorkResult::Version {
            key,
            result: Err(error),
        } => {
            if lifecycle.session_failed(&key.id, error.clone()) {
                crate::daemon_log!(
                    Error,
                    "usb-runtime",
                    "Android Auto connection failed: {error}"
                );
                publish_failure(state_tx, format!("Android Auto connection failed: {error}"));
            }
        }
    }
}

fn start_session(
    info: DeviceInfo,
    key: UsbDeviceKey,
    work_tx: mpsc::Sender<WorkResult>,
    control: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
) -> ActiveSession {
    let id = info.id();
    let (cancel, mut cancelled) = watch::channel(false);
    let task = tokio::spawn(async move {
        let opened = tokio::select! {
            biased;
            _ = cancelled.changed() => return,
            value = tokio::time::timeout(SETUP_TIMEOUT, UsbAaTransport::open(&info)) =>
                value.unwrap_or_else(|_| Err("accessory interface setup timed out".to_owned())),
        };
        let (mut transport, endpoints) = match opened {
            Ok(value) => value,
            Err(error) => {
                let _ = work_tx.try_send(WorkResult::Version {
                    key,
                    result: Err(error),
                });
                return;
            }
        };
        crate::daemon_log!(
            Debug,
            "usb-runtime",
            "bulk interface claimed: interface={} alternate={} in=0x{:02x} out=0x{:02x}",
            endpoints.interface,
            endpoints.alternate_setting,
            endpoints.input,
            endpoints.output
        );
        let session_id = state
            .borrow()
            .session
            .as_ref()
            .map(|s| s.id.clone())
            .unwrap_or_default();
        #[cfg(unix)]
        let mut media = crate::native_playback::SessionMedia::default();
        let mut version_complete = false;
        let session = async {
            let response = tokio::time::timeout(SETUP_TIMEOUT, negotiate_version(&mut transport))
                .await
                .map_err(|_| "VersionResponse timeout".to_owned())?
                .map_err(|e| e.to_string())?;
            version_complete = true;
            let _ = work_tx.try_send(WorkResult::Version {
                key: key.clone(),
                result: Ok((response.major, response.minor)),
            });
            #[cfg(unix)]
            {
                crate::aa_session::run(
                    &mut transport,
                    control,
                    state.clone(),
                    session_id.clone(),
                    &mut media,
                )
                .await
            }
            #[cfg(not(unix))]
            {
                let _ = (control, session_id);
                Err::<(), String>("AA native session requires Linux".into())
            }
        };
        let result =
            tokio::select! { biased; _=cancelled.changed()=>Ok(()), result=session=>result };
        let ended_normally = result.is_ok();
        if let Err(error) = result {
            let stage = if version_complete {
                "post-version session"
            } else {
                "version negotiation"
            };
            let failure = format!("{stage}: {error}");
            if work_tx
                .try_send(WorkResult::Version {
                    key,
                    result: Err(failure.clone()),
                })
                .is_err()
            {
                // Normally the lifecycle owner reports it once. Retain the
                // failure even if its notification queue is already closed/full.
                crate::daemon_log!(
                    Error,
                    "usb-runtime",
                    "Android Auto connection failed: {failure}"
                );
            }
        } else {
            crate::daemon_log!(Info, "usb-runtime", "Android Auto session disconnected");
        }
        #[cfg(unix)]
        media.close().await;
        if let Err(error) = transport.close().await {
            crate::daemon_log!(Warn, "usb-runtime", "AA transport cleanup: {error}");
        }
        state.send_modify(|snapshot| {
            snapshot.video = None;
            snapshot.audio = [false; 3];
            if ended_normally {
                snapshot.session = None;
                snapshot.device = None;
            }
        });
    });
    ActiveSession { id, cancel, task }
}

/// Also exercised with a fake transport: cancellation closes the same owned
/// transport both during a read and while parked after VersionResponse.
#[cfg(test)]
async fn run_checkpoint(
    mut transport: impl AndroidAutoTransport,
    mut cancelled: watch::Receiver<bool>,
    report: impl FnOnce(Result<(u16, u16), String>),
) {
    let mut engine = AndroidAutoSessionEngine::default();
    let result = if *cancelled.borrow() {
        None
    } else {
        tokio::select! {
            biased;
            _ = cancelled.changed() => None,
            response = tokio::time::timeout(SETUP_TIMEOUT, negotiate_version(&mut transport)) => Some(match response {
                Ok(Ok(response)) => Ok((response.major, response.minor)),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err("timed out waiting for VersionResponse".to_owned()),
            }),
        }
    };
    if let Some(result) = result {
        let success = result.is_ok();
        if success {
            engine.version_accepted();
        }
        report(result);
        if success && !*cancelled.borrow() {
            let _ = cancelled.changed().await;
        }
    }
    engine.disconnect();
    if let Err(error) = transport.close().await {
        crate::daemon_log!(
            Error,
            "usb-runtime",
            "AA USB transport close failed: {error}"
        );
    }
}

fn device_key(info: &DeviceInfo) -> UsbDeviceKey {
    UsbDeviceKey {
        id: format!("{:?}", info.id()),
        serial: info
            .serial_number()
            .filter(|serial| !serial.is_empty())
            .map(str::to_owned),
    }
}

fn publish_connecting(state_tx: &watch::Sender<ProjectionRuntimeSnapshot>, info: &DeviceInfo) {
    let id = format!("android-usb:{:?}", info.id());
    let mut snapshot = ProjectionRuntimeSnapshot::connecting(id, "Android phone".to_owned());
    if let Some(session) = snapshot.session.as_mut() {
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        session.id.push_str(&format!(":{epoch}"));
    }
    state_tx.send_replace(snapshot);
}

fn publish_failure(state_tx: &watch::Sender<ProjectionRuntimeSnapshot>, failure: String) {
    let current = state_tx.borrow().clone().failed(failure);
    state_tx.send_replace(current);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;
    use std::io;
    use std::pin::Pin;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Trace {
        writes: Vec<Vec<u8>>,
        closes: usize,
    }

    struct FakeTransport {
        response: Option<Vec<u8>>,
        trace: Arc<Mutex<Trace>>,
        reading: Option<oneshot::Sender<()>>,
    }

    impl AndroidAutoTransport for FakeTransport {
        fn read<'a>(
            &'a mut self,
            bytes: &'a mut [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<usize>> + Send + 'a>> {
            Box::pin(async move {
                if let Some(reading) = self.reading.take() {
                    let _ = reading.send(());
                }
                if let Some(response) = self.response.take() {
                    bytes[..response.len()].copy_from_slice(&response);
                    Ok(response.len())
                } else {
                    std::future::pending().await
                }
            })
        }
        fn write_all<'a>(
            &'a mut self,
            bytes: &'a [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>> {
            Box::pin(async move {
                self.trace.lock().unwrap().writes.push(bytes.to_vec());
                Ok(())
            })
        }
        fn close(&mut self) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + '_>> {
            Box::pin(async move {
                self.trace.lock().unwrap().closes += 1;
                Ok(())
            })
        }
    }

    #[tokio::test]
    async fn unplug_cancels_pending_read_and_replug_sends_only_a_fresh_version_request() {
        // The first enumeration disappears during its pending read; the next
        // returns a real response and stays parked without sending TLS bytes.
        for response in [None, Some(vec![0, 3, 0, 8, 0, 2, 0, 1, 0, 7, 0, 0])] {
            let succeeds = response.is_some();
            let trace = Arc::new(Mutex::new(Trace::default()));
            let (cancel, cancelled) = watch::channel(false);
            let (reading, read_started) = oneshot::channel();
            let (reported, report) = oneshot::channel();
            let task = tokio::spawn(run_checkpoint(
                FakeTransport {
                    response,
                    trace: trace.clone(),
                    reading: Some(reading),
                },
                cancelled,
                move |result| {
                    let _ = reported.send(result);
                },
            ));
            tokio::time::timeout(Duration::from_secs(1), read_started)
                .await
                .unwrap()
                .unwrap();
            if succeeds {
                assert_eq!(
                    tokio::time::timeout(Duration::from_secs(1), report)
                        .await
                        .unwrap()
                        .unwrap(),
                    Ok((1, 7))
                );
                assert!(!task.is_finished());
            }
            cancel.send_replace(true);
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap();
            let trace = trace.lock().unwrap();
            assert_eq!(trace.closes, 1);
            assert_eq!(trace.writes, vec![vec![0, 3, 0, 6, 0, 1, 0, 1, 0, 1]]);
        }
    }

    #[tokio::test]
    async fn start_is_acknowledged_only_after_the_handover_state_is_installed() {
        let key = UsbDeviceKey {
            id: "original".into(),
            serial: Some("phone".into()),
        };
        let mut lifecycle = UsbConnectionStateMachine::default();
        assert!(lifecycle.candidate_discovered(key.clone()));
        let (state, _) = watch::channel(ProjectionRuntimeSnapshot::default());
        let (acknowledged, response) = oneshot::channel();
        handle_work_result(
            WorkResult::BeforeStart {
                key: key.clone(),
                version: 2,
                acknowledged,
            },
            &mut lifecycle,
            &state,
        );
        assert!(response.await.unwrap());
        assert!(lifecycle.removed(&key.id));
        assert!(matches!(
            lifecycle.state(),
            UsbConnectionState::WaitingForAccessory {
                original_removed: true,
                ..
            }
        ));
        handle_work_result(
            WorkResult::Aoap {
                key,
                result: Err("device disconnected completing START".into()),
            },
            &mut lifecycle,
            &state,
        );
        let accessory = UsbDeviceKey {
            id: "new-enumeration".into(),
            serial: Some("phone".into()),
        };
        assert!(lifecycle.accessory_discovered(accessory, Instant::now()));
    }
}
