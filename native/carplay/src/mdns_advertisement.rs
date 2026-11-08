//! An interface-scoped AirPlay advertisement owned through Avahi's D-Bus API.
//!
//! Each advertisement has its own bus connection and EntryGroup. Call [`Advertisement::close`]
//! before releasing the Link network interface. Dropping an unfinished publish/close operation
//! schedules bounded cleanup on the current Tokio runtime; outside a runtime, dropping the
//! private bus connection lets Avahi reclaim that client's groups. No other client's records
//! or Avahi service lifetime are changed.

use std::future::Future;
use std::io;
use std::time::Duration;

use tokio::time::{sleep, timeout};
use zbus::Connection;
use zbus::zvariant::OwnedObjectPath;

const AVAHI: &str = "org.freedesktop.Avahi";
const SERVER: &str = "org.freedesktop.Avahi.Server";
const ENTRY_GROUP: &str = "org.freedesktop.Avahi.EntryGroup";
const AIRPLAY_SERVICE: &str = "_airplay._tcp";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const PUBLISH_TIMEOUT: Duration = Duration::from_secs(8);
const FREE_TIMEOUT: Duration = Duration::from_secs(2);
const DISCONNECT_TIMEOUT: Duration = Duration::from_secs(1);
const STATE_INTERVAL: Duration = Duration::from_millis(100);
const MONITOR_INTERVAL: Duration = Duration::from_secs(1);
const MONITOR_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_TXT_BYTES: usize = 512;

/// One `_airplay._tcp` EntryGroup on the selected Link IPv4 interface.
///
/// Publishing includes a bounded wait for Avahi's established state. This is discovery
/// publication, not proof that a phone has accepted or can reach the receiver.
pub struct Advertisement {
    // The connection is deliberately private: disconnecting it reclaims only this owner.
    connection: Option<Connection>,
    group: Option<OwnedObjectPath>,
    service_owner: Option<String>,
}

impl Advertisement {
    /// Publish the receiver's existing identity, without SSID/password or other credentials.
    ///
    /// `interface_index` must identify the Link NCM interface, never a wildcard. The caller
    /// must supply the same Bluetooth MAC and pairing identity used by StartSession/AirPlay.
    pub async fn publish(
        name: &str,
        interface_index: u32,
        port: u16,
        device_id: &str,
        identity_id: &str,
        public_key: &[u8; 32],
    ) -> io::Result<Self> {
        let record = ServiceRecord::new(
            name,
            interface_index,
            port,
            device_id,
            identity_id,
            public_key,
        )?;
        let connection = within(CONNECT_TIMEOUT, "connect to system bus", async {
            Connection::system()
                .await
                .map_err(|error| dbus_error("connect to system bus", error))
        })
        .await?;
        // Retain the connection even before EntryGroupNew replies: cancellation can leave a
        // newly allocated group whose path we never received. Disconnect still reclaims it.
        let mut advertisement = Self {
            connection: Some(connection),
            group: None,
            service_owner: None,
        };
        let result = within(PUBLISH_TIMEOUT, "publish AirPlay service", async {
            advertisement.register(&record).await
        })
        .await;
        if let Err(error) = result {
            // Await cleanup on ordinary failures. Drop also covers cancellation of this await.
            let _ = advertisement.close().await;
            return Err(error);
        }
        Ok(advertisement)
    }

    async fn register(&mut self, record: &ServiceRecord) -> io::Result<()> {
        let connection = self.connection.as_ref().expect("advertisement owns bus");
        let reply = connection
            .call_method(Some(AVAHI), "/", Some(SERVER), "GetState", &())
            .await
            .map_err(|error| dbus_error("activate Avahi server", error))?;
        self.service_owner = Some(
            reply
                .header()
                .sender()
                .ok_or_else(|| io::Error::other("Avahi reply has no bus owner"))?
                .to_string(),
        );
        let destination = self.service_owner.as_deref().expect("Avahi bus owner");
        // D-Bus activation can reply while Avahi is still establishing its host A records.
        // Do not publish an SRV target before those records are ready on the NCM interface.
        wait_established(RegistrationStage::Host, || async {
            let reply = connection
                .call_method(Some(destination), "/", Some(SERVER), "GetState", &())
                .await
                .map_err(|error| dbus_error("read server state", error))?;
            reply
                .body()
                .deserialize::<i32>()
                .map_err(|error| dbus_error("decode server state", error))
        })
        .await?;
        let reply = connection
            .call_method(Some(destination), "/", Some(SERVER), "EntryGroupNew", &())
            .await
            .map_err(|error| dbus_error("allocate EntryGroup", error))?;
        self.group = Some(
            reply
                .body()
                .deserialize()
                .map_err(|error| dbus_error("decode EntryGroup path", error))?,
        );
        let group = self.group.as_ref().expect("allocated EntryGroup");
        connection
            .call_method(
                Some(destination),
                group.as_str(),
                Some(ENTRY_GROUP),
                "AddService",
                &record.arguments(),
            )
            .await
            .map_err(|error| dbus_error("add AirPlay service", error))?;
        connection
            .call_method(
                Some(destination),
                group.as_str(),
                Some(ENTRY_GROUP),
                "Commit",
                &(),
            )
            .await
            .map_err(|error| dbus_error("commit AirPlay service", error))?;
        wait_established(RegistrationStage::Service, || async {
            let reply = connection
                .call_method(
                    Some(destination),
                    group.as_str(),
                    Some(ENTRY_GROUP),
                    "GetState",
                    &(),
                )
                .await
                .map_err(|error| dbus_error("read EntryGroup state", error))?;
            reply
                .body()
                .deserialize::<i32>()
                .map_err(|error| dbus_error("decode EntryGroup state", error))
        })
        .await
    }

    /// Wait for loss of the original Avahi owner, host records or established EntryGroup.
    ///
    /// The system bus can remain connected when Avahi restarts. Owner/state checks have a
    /// two-second deadline and run every second; they never activate a replacement daemon
    /// or silently republish. The caller should cancel the phone session and close this owner.
    pub async fn wait_lost(&self) -> String {
        let (Some(connection), Some(group), Some(owner)) =
            (&self.connection, &self.group, &self.service_owner)
        else {
            return "Avahi advertisement has no active owner".into();
        };
        tokio::select! {
            _ = connection.closed() => "Avahi advertisement system bus disconnected".into(),
            reason = monitor_loss(|| async {
                let reply = connection.call_method(
                    Some("org.freedesktop.DBus"),
                    "/org/freedesktop/DBus",
                    Some("org.freedesktop.DBus"),
                    "GetNameOwner",
                    &(AVAHI,),
                ).await.map_err(|error| dbus_error("check Avahi owner", error))?;
                let current = reply.body().deserialize::<String>()
                    .map_err(|error| dbus_error("decode Avahi owner", error))?;
                require_owner(owner, &current)?;
                for (path, interface, stage) in [
                    ("/", SERVER, RegistrationStage::Host),
                    (group.as_str(), ENTRY_GROUP, RegistrationStage::Service),
                ] {
                    let reply = connection.call_method(
                        Some(owner.as_str()), path, Some(interface), "GetState", &(),
                    ).await.map_err(|error| dbus_error("monitor advertisement state", error))?;
                    let state = reply.body().deserialize::<i32>()
                        .map_err(|error| dbus_error("decode advertisement state", error))?;
                    require_established(stage, state)?;
                }
                Ok(())
            }) => reason,
        }
    }

    /// Free the owned EntryGroup and disconnect its private bus connection (at most 3 s).
    ///
    /// Disconnect is attempted even if Free fails or times out. Cancellation retains the
    /// owner until Drop can schedule the same bounded cleanup.
    pub async fn close(mut self) -> io::Result<()> {
        let result = match &self.connection {
            Some(connection) => {
                release(
                    connection,
                    self.group.as_ref(),
                    self.service_owner.as_deref(),
                )
                .await
            }
            None => Ok(()),
        };
        self.group.take();
        self.service_owner.take();
        self.connection.take();
        result
    }
}

impl Drop for Advertisement {
    fn drop(&mut self) {
        let Some(connection) = self.connection.take() else {
            return;
        };
        let group = self.group.take();
        let owner = self.service_owner.take();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = release(&connection, group.as_ref(), owner.as_deref()).await;
            });
        }
        // No runtime, or runtime shutdown: the last private Connection drops. Avahi owns
        // groups by bus client and removes them when the client's connection disappears.
    }
}

async fn release(
    connection: &Connection,
    group: Option<&OwnedObjectPath>,
    owner: Option<&str>,
) -> io::Result<()> {
    finish_cleanup(
        async {
            if let Some(group) = group {
                let owner =
                    owner.ok_or_else(|| io::Error::other("Avahi EntryGroup has no owner"))?;
                let result = connection
                    .call_method(Some(owner), group.as_str(), Some(ENTRY_GROUP), "Free", &())
                    .await;
                if let Err(error) = result
                    && !owner_disappeared(&error)
                {
                    return Err(dbus_error("free EntryGroup", error));
                }
            }
            Ok(())
        },
        async {
            connection
                .clone()
                .close()
                .await
                .map_err(|error| dbus_error("disconnect advertisement bus", error))
        },
    )
    .await
}

fn owner_disappeared(error: &zbus::Error) -> bool {
    matches!(
        error,
        zbus::Error::MethodError(name, _, _)
            if matches!(name.as_str(),
                "org.freedesktop.DBus.Error.NameHasNoOwner"
                    | "org.freedesktop.DBus.Error.ServiceUnknown")
    )
}

async fn finish_cleanup(
    free: impl Future<Output = io::Result<()>>,
    disconnect: impl Future<Output = io::Result<()>>,
) -> io::Result<()> {
    let free_result = within(FREE_TIMEOUT, "free EntryGroup", free).await;
    let disconnect_result = within(
        DISCONNECT_TIMEOUT,
        "disconnect advertisement bus",
        disconnect,
    )
    .await;
    free_result.and(disconnect_result)
}

#[derive(Clone, Copy)]
enum RegistrationStage {
    Host,
    Service,
}

fn require_owner(expected: &str, current: &str) -> io::Result<()> {
    if expected == current {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotConnected,
            "Avahi service owner changed",
        ))
    }
}

fn require_established(stage: RegistrationStage, state: i32) -> io::Result<()> {
    if state == 2 {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::NotConnected,
        match stage {
            RegistrationStage::Host => "Avahi host records are no longer established",
            RegistrationStage::Service => "Avahi AirPlay EntryGroup is no longer established",
        },
    ))
}

async fn monitor_loss<F, Fut>(mut check: F) -> String
where
    F: FnMut() -> Fut,
    Fut: Future<Output = io::Result<()>>,
{
    loop {
        if let Err(error) = within(MONITOR_TIMEOUT, "monitor AirPlay advertisement", check()).await
        {
            return error.to_string();
        }
        sleep(MONITOR_INTERVAL).await;
    }
}

async fn wait_established<F, Fut>(stage: RegistrationStage, mut get_state: F) -> io::Result<()>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = io::Result<i32>>,
{
    loop {
        match get_state().await? {
            0 if matches!(stage, RegistrationStage::Host) => sleep(STATE_INTERVAL).await,
            1 => sleep(STATE_INTERVAL).await, // AVAHI_*_REGISTERING
            2 => return Ok(()),               // SERVER_RUNNING / ENTRY_GROUP_ESTABLISHED
            3 => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    match stage {
                        RegistrationStage::Host => "Avahi host name collision",
                        RegistrationStage::Service => "Avahi AirPlay service name collision",
                    },
                ));
            }
            4 => {
                return Err(io::Error::other(match stage {
                    RegistrationStage::Host => "Avahi server failed",
                    RegistrationStage::Service => "Avahi AirPlay publication failed",
                }));
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "unexpected Avahi registration state",
                ));
            }
        }
    }
}

async fn within<T>(
    duration: Duration,
    operation: &'static str,
    future: impl Future<Output = io::Result<T>>,
) -> io::Result<T> {
    timeout(duration, future).await.map_err(|_| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            format!("Avahi {operation} timed out"),
        )
    })?
}

fn dbus_error(operation: &str, error: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!("Avahi {operation}: {error}"))
}

type AddServiceArguments<'a> = (
    i32,
    i32,
    u32,
    &'a str,
    &'static str,
    &'static str,
    &'static str,
    u16,
    &'a [Vec<u8>],
);

struct ServiceRecord {
    name: String,
    interface: i32,
    port: u16,
    txt: Vec<Vec<u8>>,
}

impl ServiceRecord {
    fn new(
        name: &str,
        interface_index: u32,
        port: u16,
        device_id: &str,
        identity_id: &str,
        public_key: &[u8; 32],
    ) -> io::Result<Self> {
        let invalid = || {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid AirPlay advertisement name, interface, port or identity",
            )
        };
        if name.trim().is_empty()
            || name.len() > 63
            || name.chars().any(char::is_control)
            || interface_index == 0
            || interface_index > i32::MAX as u32
            || port == 0
            || !hex_groups(device_id, &[2, 2, 2, 2, 2, 2], b':')
            // Pairing IDs are opaque, including existing key-derived MAC identifiers.
            // Match pairing::Identity::generate rather than imposing a UUID format.
            || identity_id.is_empty()
            || identity_id.len() > 128
            || identity_id.chars().any(char::is_control)
        {
            return Err(invalid());
        }
        let public_key = public_key
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        // Upstream LIVI bonjour.rs, bfbea31e: the same identity must appear in
        // StartSession, /info and these TXT records. Only the product model changes.
        let txt = [
            format!("deviceid={device_id}"),
            "features=0x44540380,0x61".into(),
            "flags=0x4".into(),
            "model=Argo".into(),
            format!("srcvers={}", crate::protocol::receiver::SOURCE_VERSION),
            "protovers=1.1".into(),
            format!("pi={identity_id}"),
            format!("pk={public_key}"),
        ]
        .into_iter()
        .map(String::into_bytes)
        .collect::<Vec<_>>();
        if txt.iter().any(|entry| entry.len() > 255)
            || txt.iter().map(|entry| entry.len() + 1).sum::<usize>() > MAX_TXT_BYTES
        {
            return Err(invalid());
        }
        Ok(Self {
            name: name.into(),
            interface: interface_index as i32,
            port,
            txt,
        })
    }

    fn arguments(&self) -> AddServiceArguments<'_> {
        (
            self.interface,
            0, // AVAHI_PROTO_INET: never advertise on IPv6 or another interface.
            0, // Avahi's normal service and associated address publication.
            &self.name,
            AIRPLAY_SERVICE,
            "", // Default domain.
            "", // Avahi's host name/address for this NCM interface.
            self.port,
            &self.txt,
        )
    }
}

fn hex_groups(value: &str, groups: &[usize], separator: u8) -> bool {
    let mut parts = value.as_bytes().split(|byte| *byte == separator);
    groups.iter().all(|length| {
        parts
            .next()
            .is_some_and(|part| part.len() == *length && part.iter().all(u8::is_ascii_hexdigit))
    }) && parts.next().is_none()
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::*;

    const MAC: &str = "02:12:34:56:78:9A";
    const ID: &str = "01234567-89ab-cdef-0123-456789abcdef";

    fn record() -> ServiceRecord {
        ServiceRecord::new("Argo", 7, 7000, MAC, ID, &[0xab; 32]).unwrap()
    }

    #[test]
    fn txt_and_add_service_match_airplay_wire_contract() {
        let record = record();
        let txt = record
            .txt
            .iter()
            .map(|entry| std::str::from_utf8(entry).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            txt,
            [
                "deviceid=02:12:34:56:78:9A",
                "features=0x44540380,0x61",
                "flags=0x4",
                "model=Argo",
                &format!("srcvers={}", crate::protocol::receiver::SOURCE_VERSION),
                "protovers=1.1",
                "pi=01234567-89ab-cdef-0123-456789abcdef",
                &format!("pk={}", "ab".repeat(32)),
            ]
        );
        let message = zbus::Message::method_call("/test", "AddService")
            .unwrap()
            .build(&record.arguments())
            .unwrap();
        assert_eq!(
            message.body().signature(),
            &zbus::zvariant::Signature::try_from("iiussssqaay").unwrap()
        );
        let body = message
            .body()
            .deserialize::<(
                i32,
                i32,
                u32,
                String,
                String,
                String,
                String,
                u16,
                Vec<Vec<u8>>,
            )>()
            .unwrap();
        assert_eq!((body.0, body.1, body.2), (7, 0, 0));
        assert_eq!(
            (body.3.as_str(), body.4.as_str()),
            ("Argo", AIRPLAY_SERVICE)
        );
        assert_eq!((body.5.as_str(), body.6.as_str(), body.7), ("", "", 7000));
        assert_eq!(body.8, record.txt);
    }

    #[test]
    fn existing_mac_and_other_opaque_pairing_ids_are_preserved_exactly() {
        for id in [
            "02:AB:CD:EF:12:34",
            ID,
            "opaque-pairing-id",
            &"é".repeat(64),
        ] {
            let record = ServiceRecord::new("Argo", 7, 7000, MAC, id, &[0xab; 32]).unwrap();
            assert_eq!(record.txt[6], format!("pi={id}").as_bytes());
            assert_eq!(record.txt[0], format!("deviceid={MAC}").as_bytes());
            assert_eq!(record.txt[7], format!("pk={}", "ab".repeat(32)).as_bytes());
        }
    }

    #[test]
    fn invalid_metadata_is_rejected_before_any_bus_connection() {
        for name in ["", " \t", "Argo\0", "Argo\n", &"é".repeat(32)] {
            assert!(ServiceRecord::new(name, 7, 7000, MAC, ID, &[0; 32]).is_err());
        }
        for interface in [0, i32::MAX as u32 + 1, u32::MAX] {
            assert!(ServiceRecord::new("Argo", interface, 7000, MAC, ID, &[0; 32]).is_err());
        }
        assert!(ServiceRecord::new("Argo", 7, 0, MAC, ID, &[0; 32]).is_err());
        for mac in ["2:12:34:56:78:9A", "02-12-34-56-78-9A", "02:12:34:56:78:GG"] {
            assert!(ServiceRecord::new("Argo", 7, 7000, mac, ID, &[0; 32]).is_err());
        }
        for id in [
            "",
            "pairing\0id",
            "pairing\nid",
            "pairing\u{7f}id",
            &"a".repeat(129),
            &"é".repeat(65),
        ] {
            assert!(ServiceRecord::new("Argo", 7, 7000, MAC, id, &[0; 32]).is_err());
        }
        assert!(ServiceRecord::new(&"é".repeat(31), 7, 7000, MAC, ID, &[0; 32]).is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn publication_waits_for_established_and_reports_collision_or_failure() {
        let mut states = VecDeque::from([1, 1, 2]);
        wait_established(RegistrationStage::Service, || {
            std::future::ready(Ok(states.pop_front().unwrap()))
        })
        .await
        .unwrap();
        for (state, kind) in [
            (0, io::ErrorKind::InvalidData),
            (3, io::ErrorKind::AddrInUse),
            (4, io::ErrorKind::Other),
            (99, io::ErrorKind::InvalidData),
        ] {
            let error =
                wait_established(RegistrationStage::Service, || std::future::ready(Ok(state)))
                    .await
                    .unwrap_err();
            assert_eq!(error.kind(), kind);
        }
        let error = within(
            PUBLISH_TIMEOUT,
            "publish AirPlay service",
            wait_established(RegistrationStage::Service, || std::future::ready(Ok(1))),
        )
        .await
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn dbus_activation_waits_for_host_records_before_service_registration() {
        let mut states = VecDeque::from([0, 1, 2]);
        wait_established(RegistrationStage::Host, || {
            std::future::ready(Ok(states.pop_front().unwrap()))
        })
        .await
        .unwrap();
        for (state, kind) in [(3, io::ErrorKind::AddrInUse), (4, io::ErrorKind::Other)] {
            assert_eq!(
                wait_established(RegistrationStage::Host, || std::future::ready(Ok(state)))
                    .await
                    .unwrap_err()
                    .kind(),
                kind
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn cleanup_always_disconnects_after_failed_or_timed_out_free() {
        let disconnected = AtomicBool::new(false);
        let error = finish_cleanup(
            async { Err(io::Error::other("synthetic Free failure")) },
            async {
                disconnected.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await
        .unwrap_err();
        assert_eq!(error.to_string(), "synthetic Free failure");
        assert!(disconnected.swap(false, Ordering::SeqCst));

        let started = tokio::time::Instant::now();
        let error = finish_cleanup(std::future::pending(), async {
            disconnected.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert_eq!(started.elapsed(), FREE_TIMEOUT);
        assert!(disconnected.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn liveness_detects_owner_replacement_and_non_established_states() {
        assert!(require_owner(":1.42", ":1.42").is_ok());
        let mut checks = 0;
        let started = tokio::time::Instant::now();
        let reason = monitor_loss(|| {
            checks += 1;
            std::future::ready(require_owner(
                ":1.42",
                if checks == 1 { ":1.42" } else { ":1.43" },
            ))
        })
        .await;
        assert_eq!(reason, "Avahi service owner changed");
        assert_eq!(started.elapsed(), MONITOR_INTERVAL);
        assert_eq!(checks, 2);
        for stage in [RegistrationStage::Host, RegistrationStage::Service] {
            assert!(require_established(stage, 2).is_ok());
            for state in [0, 1, 3, 4, 99] {
                assert_eq!(
                    require_established(stage, state).unwrap_err().kind(),
                    io::ErrorKind::NotConnected
                );
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn liveness_bounds_unresponsive_bus_requests() {
        let started = tokio::time::Instant::now();
        let reason = monitor_loss(std::future::pending).await;
        assert_eq!(reason, "Avahi monitor AirPlay advertisement timed out");
        assert_eq!(started.elapsed(), MONITOR_TIMEOUT);
    }

    #[test]
    fn vanished_unique_owner_is_confirmed_group_cleanup_but_other_errors_are_not() {
        for (name, expected) in [
            ("org.freedesktop.DBus.Error.NameHasNoOwner", true),
            ("org.freedesktop.DBus.Error.ServiceUnknown", true),
            ("org.freedesktop.DBus.Error.AccessDenied", false),
            ("org.freedesktop.DBus.Error.NoReply", false),
        ] {
            let message = zbus::Message::method_call("/test", "Free")
                .unwrap()
                .build(&())
                .unwrap();
            let error = zbus::Error::MethodError(name.try_into().unwrap(), None, message);
            assert_eq!(owner_disappeared(&error), expected);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn cleanup_also_bounds_disconnect() {
        let started = tokio::time::Instant::now();
        let error = finish_cleanup(async { Ok(()) }, std::future::pending())
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert_eq!(started.elapsed(), DISCONNECT_TIMEOUT);
    }
}
