//! Explicit LIVI Link HCI/VHCI lease and adapter-scoped BlueZ iAP2 profiles.
//! Service UUIDs, RFCOMM channels and SDP attributes researched from LIVI
//! bfbea31ee624ddce84bfa96ce49d4663e6cdeca7 livi-runtime/src/bt.rs.
//! No host-wide Bluetooth configuration, service restart or adapter takeover.
use crate::{hci, link::LinkClient, vhci, wifi::parse_mac};
use std::{collections::HashMap, future::Future, io, os::fd::OwnedFd, time::Duration};
use tokio::{
    net::UnixStream,
    sync::{mpsc, watch},
    task::JoinHandle,
    time::timeout,
};
use zbus::{
    Connection,
    zvariant::{ObjectPath, OwnedValue, Value},
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// A caller must stop automatic replacement when ownership could not be
/// released. Independent of AirPlay features so the supervisor can classify it.
#[derive(Debug)]
pub struct ControllerCleanupUnconfirmed(pub String);

impl std::fmt::Display for ControllerCleanupUnconfirmed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Bluetooth controller cleanup is unconfirmed: {}", self.0)
    }
}
impl std::error::Error for ControllerCleanupUnconfirmed {}
const IAP_SERVER: &str = "00000000-deca-fade-deca-deafdecacaff";
const IAP_CLIENT: &str = "00000000-deca-fade-deca-deafdecacafe";
const CARPLAY: &str = "ec884348-cd41-40a2-9727-575d50bf1fd3";
const PROFILES: [(&str, &str, Option<u16>); 3] = [
    ("/org/argo/carplay/iap_server", IAP_SERVER, Some(3)),
    ("/org/argo/carplay/iap_client", IAP_CLIENT, None),
    ("/org/argo/carplay/service", CARPLAY, Some(4)),
];

pub struct Phone {
    pub stream: UnixStream,
    pub peer: [u8; 6],
}

/// Scoped disconnect for the accepted peer; never powers down the adapter/AP.
pub struct PeerDisconnector {
    connection: Connection,
    device: String,
}
impl PeerDisconnector {
    pub async fn disconnect(self) -> Result<()> {
        timeout(
            Duration::from_secs(3),
            self.connection.call_method(
                Some("org.bluez"),
                self.device.as_str(),
                Some("org.bluez.Device1"),
                "Disconnect",
                &(),
            ),
        )
        .await??;
        Ok(())
    }
}

async fn selected_phone(
    incoming: &mut mpsc::Receiver<Phone>,
    target: Option<[u8; 6]>,
) -> Result<Phone> {
    while let Some(phone) = incoming.recv().await {
        if target.is_none_or(|address| address == phone.peer) {
            return Ok(phone);
        }
        // Closing this RFCOMM descriptor rejects the other phone before any
        // credentials, authentication or AirPlay session can be prepared.
    }
    Err("Bluetooth profile closed".into())
}

async fn reconnect_selected<P, C, PF, CF>(mut paired: P, mut connect: C)
where
    P: FnMut() -> PF,
    C: FnMut() -> CF,
    PF: Future<Output = Result<bool>>,
    CF: Future<Output = Result<()>>,
{
    let _ = timeout(Duration::from_secs(60), async {
        loop {
            if matches!(
                timeout(Duration::from_secs(2), paired()).await,
                Ok(Ok(true))
            ) && matches!(timeout(Duration::from_secs(8), connect()).await, Ok(Ok(())))
            {
                return;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    })
    .await;
}

async fn dial_selected(connection: &Connection, adapter: &str, target: Option<[u8; 6]>) {
    let Some(target) = target else {
        return;
    };
    let address = target
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join("_");
    let device = format!("/org/bluez/{adapter}/dev_{address}");
    reconnect_selected(
        || async {
            let reply = connection
                .call_method(
                    Some("org.bluez"),
                    device.as_str(),
                    Some("org.freedesktop.DBus.Properties"),
                    "Get",
                    &("org.bluez.Device1", "Paired"),
                )
                .await?;
            let value: OwnedValue = reply.body().deserialize()?;
            Ok(bool::try_from(value)?)
        },
        || async {
            // Only iAP2 on this exact bonded peer. Generic Device.Connect would
            // also request unrelated audio/call profiles from the phone.
            connection
                .call_method(
                    Some("org.bluez"),
                    device.as_str(),
                    Some("org.bluez.Device1"),
                    "ConnectProfile",
                    &(IAP_CLIENT,),
                )
                .await?;
            Ok(())
        },
    )
    .await;
}

struct Profile {
    adapter: String,
    incoming: mpsc::Sender<Phone>,
}

#[zbus::interface(name = "org.bluez.Profile1")]
impl Profile {
    fn new_connection(
        &self,
        device: ObjectPath<'_>,
        fd: zbus::zvariant::OwnedFd,
        _properties: HashMap<String, OwnedValue>,
    ) -> zbus::fdo::Result<()> {
        let peer = peer_on_adapter(device.as_str(), &self.adapter)?;
        let fd: OwnedFd = fd.into();
        let stream = std::os::unix::net::UnixStream::from(fd);
        stream
            .set_nonblocking(true)
            .map_err(|_| zbus::fdo::Error::Failed("RFCOMM setup failed".into()))?;
        let stream = UnixStream::from_std(stream)
            .map_err(|_| zbus::fdo::Error::Failed("RFCOMM registration failed".into()))?;
        self.incoming
            .try_send(Phone { stream, peer })
            .map_err(|_| zbus::fdo::Error::LimitsExceeded("CarPlay receiver busy".into()))
    }
    fn request_disconnection(&self, _device: ObjectPath<'_>) {}
    fn release(&self) {}
}

fn peer_on_adapter(path: &str, adapter: &str) -> zbus::fdo::Result<[u8; 6]> {
    let value = path
        .strip_prefix(&format!("/org/bluez/{adapter}/dev_"))
        .filter(|value| !value.contains('/'))
        .ok_or_else(|| {
            zbus::fdo::Error::AccessDenied("CarPlay uses its selected controller".into())
        })?;
    parse_mac(&value.replace('_', ":"))
        .map_err(|_| zbus::fdo::Error::InvalidArgs("Invalid Bluetooth identity".into()))
}

fn record(uuid: &str, channel: u16, name: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8" ?>
<record>
<attribute id="0x0001"><sequence><uuid value="{uuid}" /></sequence></attribute>
<attribute id="0x0002"><uint32 value="0x00000000" /></attribute>
<attribute id="0x0004"><sequence><sequence><uuid value="0x0100" /></sequence><sequence><uuid value="0x0003" /><uint8 value="0x{channel:02x}" /></sequence></sequence></attribute>
<attribute id="0x0005"><sequence><uuid value="0x1002" /></sequence></attribute>
<attribute id="0x0008"><uint8 value="0xff" /></attribute>
<attribute id="0x0009"><sequence><sequence><uuid value="0x1101" /><uint16 value="0x0100" /></sequence></sequence></attribute>
<attribute id="0x0100"><text value="{name}" /></attribute>
</record>"#
    )
}

/// The lease lives across phones. Dropping it aborts its own HCI task, whose
/// owned /dev/vhci descriptor removes only the controller it created.
pub struct Controller {
    pub adapter: String,
    pub address: [u8; 6],
    incoming: mpsc::Receiver<Phone>,
    connection: Option<Connection>,
    bridge: Option<JoinHandle<io::Result<()>>>,
    bridge_stop: watch::Sender<bool>,
    stop: watch::Receiver<bool>,
}

impl Controller {
    pub fn peer_disconnector(&self, peer: [u8; 6]) -> Result<PeerDisconnector> {
        if peer == [0; 6] || peer == [255; 6] {
            return Err("Invalid selected Bluetooth peer".into());
        }
        let address = peer
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join("_");
        let device = format!("/org/bluez/{}/dev_{address}", self.adapter);
        if peer_on_adapter(&device, &self.adapter)? != peer {
            return Err("Invalid selected Bluetooth path".into());
        }
        Ok(PeerDisconnector {
            connection: self
                .connection
                .as_ref()
                .ok_or("BlueZ controller closed")?
                .clone(),
            device,
        })
    }
    pub async fn acquire(
        link: &LinkClient,
        alias: &str,
        mut stop: watch::Receiver<bool>,
    ) -> Result<Self> {
        if alias.is_empty() || alias.len() > 128 || alias.chars().any(char::is_control) {
            return Err("Invalid Bluetooth display name".into());
        }
        let device = tokio::select! {
            result = vhci::acquire() => result?,
            _ = stopped(&mut stop) => return Err("Wireless controller cancelled".into()),
        };
        let transport = tokio::select! {
            result = timeout(Duration::from_secs(5), link.connect(hci::PORT)) => result??,
            _ = stopped(&mut stop) => return Err("Wireless controller cancelled".into()),
        };
        let (bridge_stop, stopping) = watch::channel(false);
        let (index, mut registered) = watch::channel(None);
        let bridge = tokio::spawn(hci::bridge(device, transport, stopping, index));
        let (incoming, incoming_rx) = mpsc::channel(8);
        let mut controller = Self {
            adapter: String::new(),
            address: [0; 6],
            incoming: incoming_rx,
            connection: None,
            bridge: Some(bridge),
            bridge_stop,
            stop: stop.clone(),
        };
        let setup = async {
            let index = *timeout(
                Duration::from_secs(8),
                registered.wait_for(|index| index.is_some()),
            )
            .await??;
            controller.adapter = format!("hci{}", index.ok_or("LIVI Link controller not created")?);
            controller.setup(alias, incoming).await
        };
        let result = tokio::select! {
            result = timeout(Duration::from_secs(60), setup) => result.map_err(|error| -> Box<dyn std::error::Error + Send + Sync> { error.into() }).and_then(|result| result),
            _ = stopped(&mut stop) => Err("Wireless controller cancelled".into()),
        };
        if let Err(error) = result {
            // Incomplete cleanup takes precedence over a retryable setup error.
            controller.close().await?;
            return Err(error);
        }
        Ok(controller)
    }

    async fn setup(&mut self, alias: &str, incoming: mpsc::Sender<Phone>) -> Result<()> {
        let connection = timeout(Duration::from_secs(5), Connection::system()).await??;
        self.connection = Some(connection.clone());
        let adapter = format!("/org/bluez/{}", self.adapter);
        let started = tokio::time::Instant::now();
        loop {
            match timeout(
                Duration::from_secs(2),
                connection.call_method(
                    Some("org.bluez"),
                    adapter.as_str(),
                    Some("org.freedesktop.DBus.Properties"),
                    "Get",
                    &("org.bluez.Adapter1", "Address"),
                ),
            )
            .await
            {
                Ok(Ok(reply)) => {
                    let value: OwnedValue = reply.body().deserialize()?;
                    let address = String::try_from(value)?;
                    self.address = parse_mac(&address)?;
                    break;
                }
                _ if started.elapsed() < Duration::from_secs(20) => {
                    tokio::time::sleep(Duration::from_millis(200)).await
                }
                _ => return Err("BlueZ did not publish the LIVI Link controller".into()),
            }
        }
        for (path, uuid, channel) in PROFILES {
            connection
                .object_server()
                .at(
                    path,
                    Profile {
                        adapter: self.adapter.clone(),
                        incoming: incoming.clone(),
                    },
                )
                .await?;
            let mut options: HashMap<&str, Value<'_>> = HashMap::new();
            options.insert(
                "Role",
                Value::from(if channel.is_some() {
                    "server"
                } else {
                    "client"
                }),
            );
            options.insert("RequireAuthentication", Value::from(channel.is_none()));
            options.insert("RequireAuthorization", Value::from(false));
            let sdp;
            if let Some(channel) = channel {
                sdp = record(
                    uuid,
                    channel,
                    if channel == 3 {
                        "Wireless iAP"
                    } else {
                        "CarPlay"
                    },
                );
                options.insert("ServiceRecord", Value::from(sdp.as_str()));
                if channel == 3 {
                    options.insert("Channel", Value::from(channel));
                }
            } else {
                // The shared host device coordinator selects the one peer to
                // reconnect. Registering a profile must not dial every bond.
                options.insert("AutoConnect", Value::from(false));
            }
            timeout(
                Duration::from_secs(5),
                connection.call_method(
                    Some("org.bluez"),
                    "/org/bluez",
                    Some("org.bluez.ProfileManager1"),
                    "RegisterProfile",
                    &(ObjectPath::try_from(path)?, uuid, options),
                ),
            )
            .await??;
        }
        // Pairing belongs to Argo's shared connectivity agent. This transport
        // registers only adapter-scoped profiles and never auto-confirms bonds.
        for (name, value) in [
            ("Alias", Value::from(alias)),
            ("Powered", Value::from(true)),
            ("DiscoverableTimeout", Value::from(0u32)),
            ("Discoverable", Value::from(true)),
            ("Pairable", Value::from(true)),
        ] {
            set_property(
                &self.adapter,
                name,
                &mut self.stop,
                || async {
                    connection
                        .call_method(
                            Some("org.bluez"),
                            adapter.as_str(),
                            Some("org.freedesktop.DBus.Properties"),
                            "Set",
                            &("org.bluez.Adapter1", name, &value),
                        )
                        .await
                        .map(|_| ())
                },
                || async {
                    let reply = connection
                        .call_method(
                            Some("org.bluez"),
                            adapter.as_str(),
                            Some("org.freedesktop.DBus.Properties"),
                            "Get",
                            &("org.bluez.Adapter1", name),
                        )
                        .await?;
                    let actual: OwnedValue = reply.body().deserialize()?;
                    Ok(*actual == value)
                },
            )
            .await?;
        }
        Ok(())
    }

    pub async fn accept(&mut self, target: Option<[u8; 6]>) -> Result<Phone> {
        let Some(bridge) = self.bridge.as_mut() else {
            return Err("LIVI Link controller closed".into());
        };
        let Some(connection) = self.connection.as_ref() else {
            return Err("BlueZ controller closed".into());
        };
        tokio::select! {
            biased;
            _ = stopped(&mut self.stop) => Err("Wireless controller cancelled".into()),
            _ = connection.closed() => Err("BlueZ connection closed".into()),
            result = bridge => {
                self.bridge.take();
                result??;
                Err("LIVI Link controller disconnected".into())
            }
            phone = async {
                let incoming = selected_phone(&mut self.incoming, target);
                tokio::pin!(incoming);
                tokio::select! {
                    phone = &mut incoming => phone,
                    _ = dial_selected(connection, &self.adapter, target) => incoming.await,
                }
            } => phone,
        }
    }

    /// Monitor controller ownership while the returned RFCOMM phone is in use.
    /// The shared receiver uses this to cancel AirPlay on Link/BlueZ loss.
    pub async fn wait_lost(&mut self) -> String {
        let Some(bridge) = self.bridge.as_mut() else {
            return "LIVI Link controller closed".into();
        };
        let Some(connection) = self.connection.as_ref() else {
            return "BlueZ connection closed".into();
        };
        tokio::select! {
            biased;
            _ = stopped(&mut self.stop) => "Wireless controller cancelled".into(),
            _ = connection.closed() => "BlueZ connection closed".into(),
            result = bridge => {
                self.bridge.take();
                match result {
                    Ok(Ok(())) => "LIVI Link controller disconnected".into(),
                    Ok(Err(error)) => format!("LIVI Link controller transport: {}", error.kind()),
                    Err(_) => "LIVI Link controller task ended".into(),
                }
            }
        }
    }

    pub async fn close(mut self) -> Result<()> {
        // Stop the owned HCI task even while unregistering BlueZ registrations.
        // Every outcome below still awaits descriptor release before returning.
        self.bridge_stop.send_replace(true);
        let connection = self.connection.take();
        if let Some(connection) = connection.as_ref() {
            for (path, _, _) in PROFILES {
                if let Ok(path) = ObjectPath::try_from(path) {
                    let _ = timeout(
                        Duration::from_secs(1),
                        connection.call_method(
                            Some("org.bluez"),
                            "/org/bluez",
                            Some("org.bluez.ProfileManager1"),
                            "UnregisterProfile",
                            &(path,),
                        ),
                    )
                    .await;
                }
            }
        }
        finish_cleanup(
            async move {
                match connection {
                    // Successful private-bus disconnection lets BlueZ reclaim
                    // this connection's profiles even if unregister failed.
                    Some(connection) => connection.close().await.map_err(|error| error.to_string()),
                    None => Ok(()),
                }
            },
            &mut self.bridge,
        )
        .await
    }
}

/// A delayed Set reply does not mean the write failed. Verify the same absolute
/// value before retrying; never toggle or reverse a write whose result is unknown.
async fn set_property<S, SF, G, GF>(
    adapter: &str,
    name: &str,
    stop: &mut watch::Receiver<bool>,
    mut set: S,
    mut matches: G,
) -> Result<()>
where
    S: FnMut() -> SF,
    SF: std::future::Future<Output = zbus::Result<()>>,
    G: FnMut() -> GF,
    GF: std::future::Future<Output = zbus::Result<bool>>,
{
    const BUDGET: Duration = Duration::from_secs(10);
    const ATTEMPT: Duration = Duration::from_secs(2);
    const RETRY: Duration = Duration::from_millis(200);
    let deadline = tokio::time::Instant::now() + BUDGET;
    let cancelled = || {
        io::Error::new(
            io::ErrorKind::Interrupted,
            format!("BlueZ {adapter} property {name}: configuration cancelled"),
        )
    };
    let timed_out = || {
        io::Error::new(
            io::ErrorKind::TimedOut,
            format!("BlueZ {adapter} property {name}: not confirmed within 10 seconds"),
        )
    };
    let failed = |operation: &str, error: zbus::Error| {
        io::Error::other(format!(
            "BlueZ {adapter} property {name} {operation}: {error}"
        ))
    };
    let mut reported = false;
    loop {
        if *stop.borrow() {
            return Err(cancelled().into());
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(timed_out().into());
        }
        let result = tokio::select! {
            biased;
            _ = stopped(stop) => return Err(cancelled().into()),
            result = timeout(ATTEMPT.min(remaining), set()) => result,
        };
        match result {
            Ok(Ok(())) => return Ok(()),
            Ok(Err(error)) if property_busy(&error) => {}
            Ok(Err(error)) => return Err(failed("Set", error).into()),
            Err(_) => {}
        }
        if !reported {
            eprintln!(
                "CarPlay Bluetooth: {adapter} property {name} is pending; checking applied value"
            );
            reported = true;
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(timed_out().into());
        }
        let result = tokio::select! {
            biased;
            _ = stopped(stop) => return Err(cancelled().into()),
            result = timeout(ATTEMPT.min(remaining), matches()) => result,
        };
        match result {
            Ok(Ok(true)) => return Ok(()),
            Ok(Ok(false)) | Err(_) => {}
            Ok(Err(error)) if property_busy(&error) => {}
            Ok(Err(error)) => return Err(failed("Get", error).into()),
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(timed_out().into());
        }
        tokio::select! {
            biased;
            _ = stopped(stop) => return Err(cancelled().into()),
            _ = tokio::time::sleep(RETRY.min(remaining)) => {},
        }
    }
}

fn property_busy(error: &zbus::Error) -> bool {
    matches!(error, zbus::Error::MethodError(name, _, _) if name.as_str() == "org.bluez.Error.InProgress")
}

async fn finish_cleanup(
    disconnect: impl std::future::Future<Output = std::result::Result<(), String>>,
    bridge: &mut Option<JoinHandle<io::Result<()>>>,
) -> Result<()> {
    let mut failures = Vec::new();
    match timeout(Duration::from_secs(2), disconnect).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => failures.push(format!("private BlueZ bus disconnect: {error}")),
        Err(_) => failures.push("private BlueZ bus disconnect timed out".into()),
    }
    if let Some(task) = bridge.as_mut()
        && timeout(Duration::from_secs(3), &mut *task).await.is_err()
    {
        task.abort();
        if timeout(Duration::from_secs(1), &mut *task).await.is_err() {
            failures.push("owned HCI task did not finish after cancellation".into());
        }
    }
    // A completed join confirms RAII descriptor release even if the bridge
    // returned an I/O error after an ordinary physical Link disconnection.
    bridge.take();
    if failures.is_empty() {
        Ok(())
    } else {
        Err(ControllerCleanupUnconfirmed(failures.join("; ")).into())
    }
}

impl Drop for Controller {
    fn drop(&mut self) {
        self.bridge_stop.send_replace(true);
        if let Some(bridge) = self.bridge.take() {
            bridge.abort();
        }
    }
}

async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|value| *value).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };

    fn in_progress() -> zbus::Error {
        let reply = zbus::Message::method_call("/test", "Set")
            .unwrap()
            .build(&())
            .unwrap();
        zbus::Error::MethodError(
            "org.bluez.Error.InProgress".try_into().unwrap(),
            None,
            reply,
        )
    }

    #[tokio::test(start_paused = true)]
    async fn delayed_property_write_is_confirmed_without_resending_the_timed_out_set() {
        let applied = Arc::new(AtomicBool::new(false));
        let mut writes = 0;
        let (_stop, mut stop) = watch::channel(false);
        let started = tokio::time::Instant::now();
        set_property(
            "hci7",
            "Powered",
            &mut stop,
            || {
                writes += 1;
                let applied = applied.clone();
                async move {
                    // The remote write outlives the cancelled reply future.
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(2200)).await;
                        applied.store(true, Ordering::SeqCst);
                    });
                    std::future::pending().await
                }
            },
            || async {
                tokio::time::sleep(Duration::from_millis(300)).await;
                Ok(applied.load(Ordering::SeqCst))
            },
        )
        .await
        .unwrap();
        assert_eq!(writes, 1);
        assert!(applied.load(Ordering::SeqCst));
        assert_eq!(started.elapsed(), Duration::from_millis(2300));
    }

    #[tokio::test(start_paused = true)]
    async fn busy_property_with_a_different_readback_retries_the_same_set_after_backoff() {
        let mut writes = 0;
        let (_stop, mut stop) = watch::channel(false);
        let started = tokio::time::Instant::now();
        set_property(
            "hci7",
            "Powered",
            &mut stop,
            || {
                writes += 1;
                let attempt = writes;
                async move {
                    if attempt == 1 {
                        Err(in_progress())
                    } else {
                        Ok(())
                    }
                }
            },
            || async { Ok(false) },
        )
        .await
        .unwrap();
        assert_eq!(writes, 2);
        assert_eq!(started.elapsed(), Duration::from_millis(200));
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_property_set_and_readback_share_one_deadline_including_the_last_attempt() {
        let mut writes = 0;
        let mut reads = 0;
        let (_stop, mut stop) = watch::channel(false);
        let started = tokio::time::Instant::now();
        let error = set_property(
            "hci7",
            "Discoverable",
            &mut stop,
            || {
                writes += 1;
                std::future::pending()
            },
            || {
                reads += 1;
                std::future::pending()
            },
        )
        .await
        .unwrap_err();
        assert_eq!(started.elapsed(), Duration::from_secs(10));
        assert_eq!((writes, reads), (3, 2));
        assert_eq!(
            error.downcast_ref::<io::Error>().unwrap().kind(),
            io::ErrorKind::TimedOut
        );
        assert!(error.to_string().contains("hci7 property Discoverable"));
    }

    #[tokio::test(start_paused = true)]
    async fn property_configuration_cancels_during_set_readback_and_backoff_without_another_write()
    {
        for phase in 0..4 {
            let writes = Arc::new(AtomicUsize::new(0));
            let reads = Arc::new(AtomicUsize::new(0));
            let (cancel, mut stop) = watch::channel(false);
            if phase == 3 {
                cancel.send_replace(true);
            } else {
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    cancel.send_replace(true);
                });
            }
            let started = tokio::time::Instant::now();
            let error = set_property(
                "hci7",
                "Powered",
                &mut stop,
                || async {
                    writes.fetch_add(1, Ordering::SeqCst);
                    if phase == 0 {
                        std::future::pending::<()>().await;
                    }
                    Err(in_progress())
                },
                || async {
                    reads.fetch_add(1, Ordering::SeqCst);
                    if phase == 1 {
                        std::future::pending::<()>().await;
                    }
                    Ok(false)
                },
            )
            .await
            .unwrap_err();
            assert_eq!(
                error.downcast_ref::<io::Error>().unwrap().kind(),
                io::ErrorKind::Interrupted
            );
            assert!(error.to_string().contains("hci7 property Powered"));
            assert!(started.elapsed() <= Duration::from_millis(100));
            assert_eq!(writes.load(Ordering::SeqCst), usize::from(phase != 3));
            assert_eq!(
                reads.load(Ordering::SeqCst),
                usize::from(phase == 1 || phase == 2)
            );
        }
    }

    #[tokio::test]
    async fn explicit_property_denial_returns_the_named_operation_without_retrying() {
        for on_readback in [false, true] {
            let mut writes = 0;
            let mut reads = 0;
            let (_stop, mut stop) = watch::channel(false);
            let error = set_property(
                "hci7",
                "Pairable",
                &mut stop,
                || {
                    writes += 1;
                    async move {
                        if on_readback {
                            Err(in_progress())
                        } else {
                            Err(zbus::fdo::Error::AccessDenied("synthetic denial".into()).into())
                        }
                    }
                },
                || {
                    reads += 1;
                    async { Err(zbus::fdo::Error::AccessDenied("synthetic denial".into()).into()) }
                },
            )
            .await
            .unwrap_err();
            assert_eq!(writes, 1);
            assert_eq!(reads, usize::from(on_readback));
            assert!(error.to_string().contains(if on_readback {
                "hci7 property Pairable Get"
            } else {
                "hci7 property Pairable Set"
            }));
        }
    }

    #[test]
    fn incoming_rfcomm_is_confined_to_the_leased_adapter() {
        assert_eq!(
            peer_on_adapter("/org/bluez/hci7/dev_02_00_00_00_00_01", "hci7").unwrap(),
            [2, 0, 0, 0, 0, 1]
        );
        for wrong in [
            "/org/bluez/hci0/dev_02_00_00_00_00_01",
            "/org/bluez/hci70/dev_02_00_00_00_00_01",
            "/org/bluez/hci7/dev_02_00_00_00_00_01/extra",
            "/org/bluez/hci7/dev_bad",
            "/org/bluez/hci7/dev_00_00_00_00_00_00",
        ] {
            assert!(peer_on_adapter(wrong, "hci7").is_err());
        }
        assert!(record(IAP_SERVER, 3, "Wireless iAP").contains("uint8 value=\"0x03\""));
        assert!(record(CARPLAY, 4, "CarPlay").contains("uint8 value=\"0x04\""));
    }

    #[tokio::test]
    async fn selected_phone_rejects_other_peers_before_returning_a_session() {
        use tokio::io::AsyncReadExt;
        let (incoming, mut phones) = mpsc::channel(3);
        let (other, mut other_phone) = UnixStream::pair().unwrap();
        let (chosen, _chosen_phone) = UnixStream::pair().unwrap();
        let expected = [2, 0, 0, 0, 0, 2];
        incoming
            .send(Phone {
                stream: other,
                peer: [2, 0, 0, 0, 0, 1],
            })
            .await
            .unwrap();
        incoming
            .send(Phone {
                stream: chosen,
                peer: expected,
            })
            .await
            .unwrap();
        let accepted = selected_phone(&mut phones, Some(expected)).await.unwrap();
        assert_eq!(accepted.peer, expected);
        let mut byte = [0; 1];
        assert_eq!(
            timeout(Duration::from_secs(1), other_phone.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        let (new_phone, _remote) = UnixStream::pair().unwrap();
        incoming
            .send(Phone {
                stream: new_phone,
                peer: [2, 0, 0, 0, 0, 3],
            })
            .await
            .unwrap();
        assert_eq!(
            selected_phone(&mut phones, None).await.unwrap().peer,
            [2, 0, 0, 0, 0, 3]
        );
        drop(incoming);
        assert!(selected_phone(&mut phones, Some(expected)).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn selected_reconnect_waits_for_a_bond_and_retries_only_until_connected() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let checks = AtomicUsize::new(0);
        let connects = AtomicUsize::new(0);
        reconnect_selected(
            || async { Ok(checks.fetch_add(1, Ordering::SeqCst) > 0) },
            || async {
                if connects.fetch_add(1, Ordering::SeqCst) == 0 {
                    Err("Synthetic temporary profile failure".into())
                } else {
                    Ok(())
                }
            },
        )
        .await;
        assert_eq!(checks.load(Ordering::SeqCst), 3);
        assert_eq!(connects.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn selected_reconnect_never_pairs_or_dials_an_unbonded_phone_and_is_bounded() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let connects = AtomicUsize::new(0);
        let started = tokio::time::Instant::now();
        reconnect_selected(
            || async { Ok(false) },
            || async {
                connects.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
        )
        .await;
        assert_eq!(connects.load(Ordering::SeqCst), 0);
        assert_eq!(started.elapsed(), Duration::from_secs(60));
    }

    #[tokio::test]
    async fn controller_close_awaits_its_owned_bridge_release() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        struct Released(Arc<AtomicBool>);
        impl Drop for Released {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let released = Arc::new(AtomicBool::new(false));
        let flag = released.clone();
        let (bridge_stop, mut stopping) = watch::channel(false);
        let bridge = tokio::spawn(async move {
            let _owned = Released(flag);
            let _ = stopping.wait_for(|v| *v).await;
            Ok(())
        });
        let (_incoming, incoming) = mpsc::channel(1);
        let (_cancel, stop) = watch::channel(false);
        let controller = Controller {
            adapter: "hci7".into(),
            address: [2, 0, 0, 0, 0, 7],
            incoming,
            connection: None,
            bridge: Some(bridge),
            bridge_stop,
            stop,
        };
        controller.close().await.unwrap();
        assert!(released.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn failed_or_stalled_bus_close_is_fatal_but_still_awaits_bridge_release() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        struct Released(Arc<AtomicBool>);
        impl Drop for Released {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        for stalls in [false, true] {
            let released = Arc::new(AtomicBool::new(false));
            let flag = released.clone();
            let (stop, mut stopping) = watch::channel(false);
            let mut bridge = Some(tokio::spawn(async move {
                let _owned = Released(flag);
                let _ = stopping.wait_for(|value| *value).await;
                Ok(())
            }));
            stop.send_replace(true);
            let started = tokio::time::Instant::now();
            let disconnect = async move {
                if stalls {
                    std::future::pending::<()>().await;
                }
                Err("synthetic disconnect failure".into())
            };
            let error = finish_cleanup(disconnect, &mut bridge).await.unwrap_err();
            assert!(
                error
                    .downcast_ref::<ControllerCleanupUnconfirmed>()
                    .is_some()
            );
            assert!(
                released.load(Ordering::SeqCst),
                "bus failure must not skip descriptor release"
            );
            assert!(bridge.is_none());
            assert!(started.elapsed() <= Duration::from_secs(2));
            assert_eq!(
                started.elapsed(),
                if stalls {
                    Duration::from_secs(2)
                } else {
                    Duration::ZERO
                }
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_bridge_ignoring_graceful_stop_is_aborted_and_joined_before_success() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        struct Released(Arc<AtomicBool>);
        impl Drop for Released {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let released = Arc::new(AtomicBool::new(false));
        let flag = released.clone();
        let mut bridge = Some(tokio::spawn(async move {
            let _owned = Released(flag);
            std::future::pending::<io::Result<()>>().await
        }));
        tokio::task::yield_now().await;
        let started = tokio::time::Instant::now();
        finish_cleanup(async { Ok(()) }, &mut bridge).await.unwrap();
        assert_eq!(started.elapsed(), Duration::from_secs(3));
        assert!(released.load(Ordering::SeqCst));
        assert!(bridge.is_none());
    }
}
