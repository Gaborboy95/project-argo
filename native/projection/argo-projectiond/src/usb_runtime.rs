#![cfg(feature = "linux-usb")]

use std::time::{Duration, Instant};

use futures_lite::StreamExt;
use nusb::hotplug::HotplugEvent;
use nusb::{DeviceId, DeviceInfo};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

use crate::daemon_state::ProjectionRuntimeSnapshot;
#[cfg(test)]
use crate::session::AndroidAutoSessionEngine;
use crate::session::AndroidAutoTransport;
use crate::usb::nusb_backend::{
    UsbAaTransport, is_accessory, is_candidate, request_accessory_mode,
};
use crate::usb::{UsbConnectionState, UsbConnectionStateMachine, UsbDeviceKey};

const VERSION_RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

enum WorkResult {
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

pub async fn run(
    state_tx: watch::Sender<ProjectionRuntimeSnapshot>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), String> {
    let mut watcher = nusb::watch_devices().map_err(|error| error.to_string())?;
    let (work_tx, mut work_rx) = mpsc::channel::<WorkResult>(8);
    let mut lifecycle = UsbConnectionStateMachine::default();
    let mut active_session: Option<ActiveSession> = None;
    let mut background_tasks: Vec<JoinHandle<()>> = Vec::new();
    let mut expiry_check = tokio::time::interval(Duration::from_secs(1));
    expiry_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    println!("argo-projectiond: Linux USB hotplug watching started");
    match nusb::list_devices().await {
        Ok(devices) => {
            for info in devices {
                handle_connected(
                    info,
                    &mut lifecycle,
                    &state_tx,
                    &work_tx,
                    &mut active_session,
                    &mut background_tasks,
                );
            }
        }
        Err(error) => eprintln!("argo-projectiond: initial USB discovery failed: {error}"),
    }

    loop {
        tokio::select! {
            hotplug = watcher.next() => {
                match hotplug {
                    Some(HotplugEvent::Connected(info)) => handle_connected(
                        info,
                        &mut lifecycle,
                        &state_tx,
                        &work_tx,
                        &mut active_session,
                        &mut background_tasks,
                    ),
                    Some(HotplugEvent::Disconnected(id)) => {
                        handle_removed(id, &mut lifecycle, &state_tx, &mut active_session).await;
                    }
                    None => return Err("USB hotplug stream ended".to_owned()),
                }
            }
            result = work_rx.recv() => {
                if let Some(result) = result {
                    handle_work_result(result, &mut lifecycle, &state_tx);
                }
            }
            _ = expiry_check.tick() => {
                if lifecycle.expire_accessory_wait(Instant::now()) {
                    let reason = match lifecycle.state() {
                        UsbConnectionState::Failed { reason, .. } => reason.clone(),
                        _ => "accessory re-enumeration failed".to_owned(),
                    };
                    eprintln!("argo-projectiond: {reason}");
                    publish_failure(&state_tx, reason);
                }
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }

    if let Some(session) = active_session.take() {
        let _ = session.cancel.send(true);
        let _ = session.task.await;
    }
    for task in background_tasks {
        task.abort();
        let _ = task.await;
    }
    lifecycle.reset();
    let _ = state_tx.send(ProjectionRuntimeSnapshot::default());
    Ok(())
}

fn handle_connected(
    info: DeviceInfo,
    lifecycle: &mut UsbConnectionStateMachine,
    state_tx: &watch::Sender<ProjectionRuntimeSnapshot>,
    work_tx: &mpsc::Sender<WorkResult>,
    active_session: &mut Option<ActiveSession>,
    background_tasks: &mut Vec<JoinHandle<()>>,
) {
    if is_accessory(&info) {
        let key = device_key(&info);
        if !lifecycle.accessory_discovered(key.clone(), Instant::now()) {
            return;
        }
        println!("Android accessory detected");
        if !lifecycle.session_starting(&key.id) {
            return;
        }
        publish_connecting(state_tx, &info);
        *active_session = Some(start_session(info, key, work_tx.clone()));
        return;
    }
    if !is_candidate(&info) {
        return;
    }
    let key = device_key(&info);
    if !lifecycle.candidate_discovered(key.clone()) {
        return;
    }
    println!(
        "USB candidate detected: {:04x}:{:04x}",
        info.vendor_id(),
        info.product_id()
    );
    publish_connecting(state_tx, &info);
    let tx = work_tx.clone();
    background_tasks.push(tokio::spawn(async move {
        let result = request_accessory_mode(&info).await;
        let _ = tx.send(WorkResult::Aoap { key, result }).await;
    }));
}

fn handle_work_result(
    result: WorkResult,
    lifecycle: &mut UsbConnectionStateMachine,
    state_tx: &watch::Sender<ProjectionRuntimeSnapshot>,
) {
    match result {
        WorkResult::Aoap {
            key,
            result: Ok(version),
        } => {
            if lifecycle.accessory_switch_requested(&key.id, version, Instant::now()) {
                println!("AOAP protocol version {version}");
                println!("AOAP accessory switch requested");
            }
        }
        WorkResult::Aoap {
            key,
            result: Err(error),
        } => {
            if lifecycle.probe_failed(&key.id, error.clone()) {
                eprintln!("AOAP probe failed: {error}");
                publish_failure(state_tx, format!("AOAP probe failed: {error}"));
            }
        }
        WorkResult::Version {
            key,
            result: Ok((major, minor)),
        } => {
            if lifecycle.version_negotiated(&key.id, major, minor) {
                println!(
                    "Android Auto version negotiation succeeded: phone protocol major={major} minor={minor}"
                );
                let current = state_tx.borrow().clone().ready();
                let _ = state_tx.send(current);
            }
        }
        WorkResult::Version {
            key,
            result: Err(error),
        } => {
            if lifecycle.session_failed(&key.id, error.clone()) {
                eprintln!("Android Auto version negotiation failed: {error}");
                publish_failure(
                    state_tx,
                    format!("Android Auto version negotiation failed: {error}"),
                );
            }
        }
    }
}

async fn handle_removed(
    id: DeviceId,
    lifecycle: &mut UsbConnectionStateMachine,
    state_tx: &watch::Sender<ProjectionRuntimeSnapshot>,
    active_session: &mut Option<ActiveSession>,
) {
    let id_text = format!("{id:?}");
    let waiting = matches!(
        lifecycle.state(),
        UsbConnectionState::WaitingForAccessory { .. }
    );
    if !lifecycle.removed(&id_text) {
        return;
    }
    if waiting {
        println!("original USB device removed; waiting for Android accessory");
        return;
    }

    println!("Android Auto USB device removed");
    if let Some(session) = active_session.take()
        && session.id == id
    {
        let _ = session.cancel.send(true);
        let _ = session.task.await;
    }
    let _ = state_tx.send(ProjectionRuntimeSnapshot::default());
}

fn start_session(
    info: DeviceInfo,
    key: UsbDeviceKey,
    work_tx: mpsc::Sender<WorkResult>,
) -> ActiveSession {
    let id = info.id();
    let (cancel, mut cancelled) = watch::channel(false);
    let task = tokio::spawn(async move {
        let opened = UsbAaTransport::open(&info).await;
        let (mut transport, endpoints) = match opened {
            Ok(opened) => opened,
            Err(error) => {
                let _ = work_tx
                    .send(WorkResult::Version {
                        key,
                        result: Err(error),
                    })
                    .await;
                return;
            }
        };
        println!(
            "bulk interface claimed: interface={} alternate={} in=0x{:02x} out=0x{:02x}",
            endpoints.interface, endpoints.alternate_setting, endpoints.input, endpoints.output
        );

        let negotiation = tokio::time::timeout(
            VERSION_RESPONSE_TIMEOUT,
            crate::session::negotiate_version(&mut transport),
        );
        let result = tokio::select! {
            response = negotiation => match response {
                Ok(Ok(response)) => Ok((response.major, response.minor)),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err("timed out waiting for VersionResponse".to_owned()),
            },
            _ = cancelled.changed() => {
                let _ = transport.close().await;
                return;
            }
        };
        let negotiated = result.is_ok();
        let _ = work_tx.send(WorkResult::Version { key, result }).await;

        if negotiated {
            let _ = cancelled.changed().await;
        }
        let _ = transport.close().await;
    });
    ActiveSession { id, cancel, task }
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

fn projection_device_id(info: &DeviceInfo) -> String {
    info.serial_number()
        .filter(|serial| !serial.is_empty())
        .map(|serial| format!("android-usb:{serial}"))
        .unwrap_or_else(|| format!("android-usb:{:?}", info.id()))
}

fn publish_connecting(state_tx: &watch::Sender<ProjectionRuntimeSnapshot>, info: &DeviceInfo) {
    let display_name = info
        .product_string()
        .filter(|name| !name.is_empty())
        .unwrap_or("Android phone")
        .to_owned();
    let _ = state_tx.send(ProjectionRuntimeSnapshot::connecting(
        projection_device_id(info),
        display_name,
    ));
}

fn publish_failure(state_tx: &watch::Sender<ProjectionRuntimeSnapshot>, failure: String) {
    let current = state_tx.borrow().clone().failed(failure);
    let _ = state_tx.send(current);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_engine_is_not_advanced_to_tls_by_runtime_construction() {
        let engine = AndroidAutoSessionEngine::default();
        assert_eq!(
            engine.phase(),
            crate::session::SessionPhase::VersionNegotiation
        );
    }
}
