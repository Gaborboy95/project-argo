//! Explicit PBAP reads; no persistent contacts database, dialing, or raw IPC files.
use serde::Serialize;
use std::{
    collections::HashMap, io::Read, os::unix::fs::DirBuilderExt, path::PathBuf, time::Duration,
};
use tokio::{sync::watch, task::JoinHandle};
use zbus::{
    Connection, Proxy,
    zvariant::{OwnedObjectPath, OwnedValue, Value},
};
const PAGE: u16 = 40;
const MAX_BYTES: usize = 256 * 1024;
const JSON_BUDGET: usize = 16 * 1024;
#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    pub busy: bool,
    pub kind: String,
    pub detail: String,
    pub offset: u16,
    pub more: bool,
    pub entries: Vec<Contact>,
}
#[derive(Clone, Serialize)]
pub struct Contact {
    pub name: String,
    pub numbers: Vec<String>,
}
#[derive(Default)]
pub struct Book {
    pub state: Snapshot,
    job: Option<Job>,
    blocked: bool,
}
struct Job {
    cancel: watch::Sender<bool>,
    task: JoinHandle<Outcome>,
}
struct Outcome {
    result: Result<Snapshot, String>,
    cleanup: Option<String>,
}
impl Book {
    pub async fn clear(&mut self) -> Result<(), String> {
        self.state = Default::default();
        if let Some(job) = self.job.as_mut() {
            job.cancel.send_replace(true);
            // Retain the handle if the caller is cancelled during cleanup.
            let result = (&mut job.task).await;
            self.job = None;
            let result = result.unwrap_or_else(|_| Outcome {
                result: Err("Phonebook worker failed".into()),
                cleanup: Some("Phonebook worker cleanup unconfirmed".into()),
            });
            if let Some(e) = result.cleanup {
                self.blocked = true;
                self.state = Snapshot {
                    detail: e.clone(),
                    ..Default::default()
                };
                return Err(e);
            }
        }
        self.state = Default::default();
        Ok(())
    }
    pub async fn start(
        &mut self,
        local: String,
        remote: String,
        kind: &str,
        offset: u16,
    ) -> Result<(), String> {
        if self.blocked {
            return Err(
                "Phonebook cleanup unconfirmed; restart daemon before another import".into(),
            );
        }
        if !matches!(kind, "contacts" | "recent") || offset > 1000 {
            return Err("Invalid phonebook page".into());
        }
        self.clear().await?;
        let kind = kind.to_owned();
        self.state = Snapshot {
            busy: true,
            kind: kind.clone(),
            offset,
            detail: "Waiting for phone contact/call-history sharing permission".into(),
            ..Default::default()
        };
        let (cancel, cancelled) = watch::channel(false);
        let task = tokio::spawn(async move {
            // Each job uses a dedicated D-Bus connection. BlueZ 5.82 tears down
            // even an in-flight CreateSession when this owner disconnects.
            let bus =
                match tokio::time::timeout(Duration::from_secs(2), Connection::session()).await {
                    Ok(Ok(b)) => b,
                    _ => {
                        return Outcome {
                            result: Err("OBEX D-Bus unavailable".into()),
                            cleanup: None,
                        };
                    }
                };
            import_on_bus(bus, &local, &remote, &kind, offset, cancelled).await
        });
        self.job = Some(Job { cancel, task });
        Ok(())
    }
    pub async fn poll(&mut self) {
        if self.job.as_ref().is_some_and(|j| j.task.is_finished()) {
            let job = self.job.take().unwrap();
            match job.task.await {
                Ok(Outcome {
                    cleanup: Some(e), ..
                }) => {
                    self.blocked = true;
                    self.state.entries.clear();
                    self.state.detail = e;
                }
                Ok(Outcome {
                    result: Ok(state), ..
                }) => self.state = state,
                Ok(Outcome { result: Err(e), .. }) => {
                    self.state.entries.clear();
                    self.state.detail = e;
                }
                Err(_) => {
                    self.blocked = true;
                    self.state.entries.clear();
                    self.state.detail = "Phonebook worker failed".into();
                }
            }
            self.state.busy = false;
        }
    }
}
impl Drop for Book {
    fn drop(&mut self) {
        if let Some(job) = &self.job {
            job.cancel.send_replace(true);
        }
    }
}
async fn import_on_bus(
    bus: Connection,
    local: &str,
    remote: &str,
    kind: &str,
    offset: u16,
    mut cancelled: watch::Receiver<bool>,
) -> Outcome {
    let mut session = None;
    let result = tokio::select! {biased;
        _=async { if !*cancelled.borrow() { let _ = cancelled.changed().await; } }=>Err("Phonebook import cancelled".into()),
        result=tokio::time::timeout(Duration::from_secs(35),fetch(&bus,&mut session,local,remote,kind,offset))=>result.unwrap_or_else(|_|Err("Phonebook request timed out; check sharing permission on the phone".into())),
    };
    let mut cleanup = None;
    if let Some(path) = session {
        let removal = async {
            client(&bus)
                .await?
                .call::<_, _, ()>("RemoveSession", &(path,))
                .await
                .map_err(|e| e.to_string())
        };
        if !matches!(
            tokio::time::timeout(Duration::from_secs(2), removal).await,
            Ok(Ok(()))
        ) {
            cleanup = Some(
                "OBEX session removal was not confirmed; dedicated client disconnected".into(),
            );
        }
    }
    if !matches!(
        tokio::time::timeout(Duration::from_secs(2), bus.close()).await,
        Ok(Ok(()))
    ) {
        cleanup = Some("OBEX owner cleanup was not confirmed".into());
    }
    Outcome { result, cleanup }
}
async fn client(bus: &Connection) -> Result<Proxy<'_>, String> {
    Proxy::new(
        bus,
        "org.bluez.obex",
        "/org/bluez/obex",
        "org.bluez.obex.Client1",
    )
    .await
    .map_err(|e| e.to_string())
}
struct Download(PathBuf);
impl Drop for Download {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0.join("phonebook.vcf"));
        let _ = std::fs::remove_dir(&self.0);
    }
}
async fn fetch(
    bus: &Connection,
    session: &mut Option<OwnedObjectPath>,
    local: &str,
    remote: &str,
    kind: &str,
    offset: u16,
) -> Result<Snapshot, String> {
    let path: OwnedObjectPath = client(bus)
        .await?
        .call(
            "CreateSession",
            &(
                remote,
                HashMap::from([
                    ("Source", Value::from(local)),
                    ("Target", Value::from("pbap")),
                ]),
            ),
        )
        .await
        .map_err(
            |_| "Phonebook connection unavailable; enable contact sharing for this paired device",
        )?;
    *session = Some(path.clone());
    let pb = Proxy::new(
        bus,
        "org.bluez.obex",
        path.as_str(),
        "org.bluez.obex.PhonebookAccess1",
    )
    .await
    .map_err(|e| e.to_string())?;
    pb.call::<_, _, ()>(
        "Select",
        &("int", if kind == "contacts" { "pb" } else { "cch" }),
    )
    .await
    .map_err(|_| "Phone does not share this phonebook or call history")?;
    let root = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or("Desktop runtime directory unavailable")?
        .join(format!("argo-phonebook-{}", crate::artwork::random()?));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .map_err(|e| e.to_string())?;
    let download = Download(root);
    let target = download.0.join("phonebook.vcf");
    let filters = HashMap::from([
        ("Format", Value::from("vcard30")),
        ("Fields", Value::from(vec!["FN", "N", "TEL"])),
        ("MaxCount", Value::from(PAGE)),
        ("Offset", Value::from(offset)),
    ]);
    let (transfer, _): (OwnedObjectPath, HashMap<String, OwnedValue>) = pb
        .call(
            "PullAll",
            &(target.to_str().ok_or("Invalid runtime path")?, filters),
        )
        .await
        .map_err(|_| "Phonebook transfer rejected; approve sharing on the phone")?;
    let transfer = Proxy::new(
        bus,
        "org.bluez.obex",
        transfer.as_str(),
        "org.bluez.obex.Transfer1",
    )
    .await
    .map_err(|e| e.to_string())?;
    loop {
        if std::fs::metadata(&target).is_ok_and(|m| m.len() > MAX_BYTES as u64)
            || transfer.get_property::<u64>("Size").await.unwrap_or(0) > MAX_BYTES as u64
        {
            return Err("Phonebook page exceeds 256 KiB".into());
        }
        match transfer
            .get_property::<String>("Status")
            .await
            .map_err(|e| e.to_string())?
            .as_str()
        {
            "complete" => break,
            "error" => return Err("Phonebook transfer failed or permission was denied".into()),
            _ => {}
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let mut bytes = vec![];
    std::fs::File::open(&target)
        .and_then(|f| f.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes))
        .map_err(|e| e.to_string())?;
    let (entries, count) = parse(&bytes)?;
    Ok(Snapshot {
        busy: false,
        kind: kind.into(),
        offset,
        more: count >= PAGE as usize && offset < 1000,
        detail: format!(
            "{} entries on this page; phone-provided order. Cached until disconnect or Clear.",
            entries.len()
        ),
        entries,
    })
}
fn unescape(value: &str) -> String {
    let mut out = String::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n' | 'N') => out.push(' '),
                Some(c) => out.push(c),
                None => {}
            }
        } else if !c.is_control() {
            out.push(c);
        }
    }
    out
}
pub fn telephone(value: &str) -> Option<String> {
    let value = value.strip_prefix("tel:").unwrap_or(value);
    let mut out = String::new();
    for c in value.chars() {
        if c.is_ascii_digit() || matches!(c, '*' | '#') || (c == '+' && out.is_empty()) {
            out.push(c);
        } else if !matches!(c, ' ' | '-' | '(' | ')' | '.') {
            return None;
        }
    }
    (!out.is_empty() && out.len() <= 64).then_some(out)
}
fn parse(bytes: &[u8]) -> Result<(Vec<Contact>, usize), String> {
    if bytes.len() > MAX_BYTES {
        return Err("Phonebook exceeds size bound".into());
    }
    let text = std::str::from_utf8(bytes).map_err(|_| "Phone did not return UTF-8 vCard 3.0")?;
    let mut lines: Vec<String> = vec![];
    for line in text.lines() {
        if (line.starts_with(' ') || line.starts_with('\t')) && !lines.is_empty() {
            lines.last_mut().unwrap().push_str(&line[1..]);
        } else {
            lines.push(line.into());
        }
    }
    let mut entries = vec![];
    let mut contact: Option<Contact> = None;
    let mut version = false;
    let mut count = 0;
    for line in lines {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.eq_ignore_ascii_case("BEGIN") && value.eq_ignore_ascii_case("VCARD") {
            if contact.is_some() {
                return Err("Malformed nested vCard".into());
            }
            contact = Some(Contact {
                name: String::new(),
                numbers: vec![],
            });
            version = false;
            continue;
        }
        if key.eq_ignore_ascii_case("END") && value.eq_ignore_ascii_case("VCARD") {
            let Some(mut item) = contact.take() else {
                return Err("Malformed vCard ending".into());
            };
            if !version {
                return Err("Phone did not honor requested vCard 3.0 format".into());
            }
            count += 1;
            if count > PAGE as usize {
                return Err("Phone exceeded requested contact count".into());
            }
            if item.name.is_empty() {
                item.name = "Unnamed contact".into();
            }
            entries.push(item);
            if serde_json::to_vec(&entries)
                .map_err(|e| e.to_string())?
                .len()
                > JSON_BUDGET
            {
                return Err("Phonebook page exceeds control-state budget".into());
            }
            continue;
        }
        let Some(item) = &mut contact else { continue };
        if key.to_ascii_uppercase().contains("ENCODING=") {
            return Err("Encoded vCard fields are unsupported; no numbers imported".into());
        }
        let property = key
            .split(';')
            .next()
            .unwrap_or("")
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_ascii_uppercase();
        match property.as_str() {
            "VERSION" => version = value == "3.0",
            "FN" => item.name = unescape(value).chars().take(80).collect(),
            "N" if item.name.is_empty() => {
                item.name = unescape(&value.replace(';', " "))
                    .chars()
                    .take(80)
                    .collect()
            }
            "TEL" if item.numbers.len() < 3 => {
                if let Some(number) = telephone(value)
                    && !item.numbers.contains(&number)
                {
                    item.numbers.push(number);
                }
            }
            _ => {}
        }
    }
    if contact.is_some() {
        return Err("Incomplete vCard; no contacts imported".into());
    }
    Ok((entries, count))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_vcards_unfold_names_and_preserve_only_unambiguous_numbers() {
        let (items,count)=parse(b"BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Alice\\,\r\n  Example\r\nTEL;TYPE=CELL:+36 (1) 234-567\r\nTEL:tel:+361234567;ext=12\r\nEND:VCARD\r\n").unwrap();
        assert_eq!(count, 1);
        assert_eq!(items[0].name, "Alice, Example");
        assert_eq!(items[0].numbers, vec!["+361234567"]);
        assert!(parse(b"BEGIN:VCARD\nVERSION:2.1\nTEL:123\nEND:VCARD\n").is_err());
        assert!(parse(b"BEGIN:VCARD\nVERSION:3.0\n").is_err());
        assert!(parse(&vec![0; MAX_BYTES + 1]).is_err());
        let many = "BEGIN:VCARD\nVERSION:3.0\nEND:VCARD\n".repeat(41);
        assert!(parse(many.as_bytes()).is_err());
    }
}

#[cfg(test)]
mod dbus_tests {
    use super::*;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    };
    use tokio::io::{AsyncBufReadExt, BufReader};
    const SESSION: &str = "/org/bluez/obex/client/session0";
    const TRANSFER: &str = "/org/bluez/obex/client/session0/transfer0";
    #[derive(Default)]
    struct State {
        paths: Mutex<Vec<String>>,
        removed: AtomicBool,
        complete: AtomicBool,
    }
    struct Client(Arc<State>);
    #[zbus::interface(name = "org.bluez.obex.Client1")]
    impl Client {
        fn create_session(
            &self,
            destination: &str,
            args: HashMap<String, OwnedValue>,
        ) -> OwnedObjectPath {
            assert_eq!(destination, "00:11:22:33:44:55");
            assert_eq!(
                <&str>::try_from(&args["Source"]).unwrap(),
                "AA:BB:CC:DD:EE:FF"
            );
            assert_eq!(<&str>::try_from(&args["Target"]).unwrap(), "pbap");
            self.0.removed.store(false, Ordering::SeqCst);
            OwnedObjectPath::try_from(SESSION).unwrap()
        }
        fn remove_session(&self, session: OwnedObjectPath) {
            assert_eq!(session.as_str(), SESSION);
            self.0.removed.store(true, Ordering::SeqCst);
        }
    }
    struct Phonebook(Arc<State>);
    #[zbus::interface(name = "org.bluez.obex.PhonebookAccess1")]
    impl Phonebook {
        fn select(&self, location: &str, phonebook: &str) {
            assert_eq!(location, "int");
            assert!(matches!(phonebook, "pb" | "cch"));
        }
        fn pull_all(
            &self,
            target: &str,
            filters: HashMap<String, OwnedValue>,
        ) -> (OwnedObjectPath, HashMap<String, OwnedValue>) {
            assert_eq!(<&str>::try_from(&filters["Format"]).unwrap(), "vcard30");
            assert_eq!(u16::try_from(&filters["MaxCount"]).unwrap(), PAGE);
            assert_eq!(u16::try_from(&filters["Offset"]).unwrap(), 0);
            use std::os::unix::fs::PermissionsExt;
            let parent = std::path::Path::new(target).parent().unwrap();
            assert_eq!(
                std::fs::metadata(parent).unwrap().permissions().mode() & 0o777,
                0o700
            );
            std::fs::write(
                target,
                "BEGIN:VCARD\nVERSION:3.0\nFN:Fixture\nTEL:123\nEND:VCARD\n",
            )
            .unwrap();
            self.0.paths.lock().unwrap().push(target.into());
            (OwnedObjectPath::try_from(TRANSFER).unwrap(), HashMap::new())
        }
    }
    struct Transfer(Arc<State>);
    #[zbus::interface(name = "org.bluez.obex.Transfer1")]
    impl Transfer {
        #[zbus(property)]
        fn status(&self) -> &str {
            if self.0.complete.load(Ordering::SeqCst) {
                "complete"
            } else {
                "active"
            }
        }
        #[zbus(property)]
        fn size(&self) -> u64 {
            64
        }
    }
    #[tokio::test]
    async fn pbap_import_and_cancel_use_selected_adapter_and_remove_owned_session_and_file() {
        let mut daemon = tokio::process::Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdout(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut address = String::new();
        BufReader::new(daemon.stdout.take().unwrap())
            .read_line(&mut address)
            .await
            .unwrap();
        let state = Arc::new(State::default());
        let server = zbus::connection::Builder::address(address.trim())
            .unwrap()
            .name("org.bluez.obex")
            .unwrap()
            .serve_at("/org/bluez/obex", Client(state.clone()))
            .unwrap()
            .serve_at(SESSION, Phonebook(state.clone()))
            .unwrap()
            .serve_at(TRANSFER, Transfer(state.clone()))
            .unwrap()
            .build()
            .await
            .unwrap();
        for complete in [true, false] {
            state.complete.store(complete, Ordering::SeqCst);
            state.paths.lock().unwrap().clear();
            let bus = zbus::connection::Builder::address(address.trim())
                .unwrap()
                .build()
                .await
                .unwrap();
            let (cancel, cancelled) = watch::channel(false);
            let task = tokio::spawn(import_on_bus(
                bus,
                "AA:BB:CC:DD:EE:FF",
                "00:11:22:33:44:55",
                if complete { "contacts" } else { "recent" },
                0,
                cancelled,
            ));
            if !complete {
                tokio::time::timeout(Duration::from_secs(2), async {
                    while state.paths.lock().unwrap().is_empty() {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                })
                .await
                .unwrap();
                cancel.send_replace(true);
            }
            let result = tokio::time::timeout(Duration::from_secs(3), task)
                .await
                .unwrap()
                .unwrap();
            assert!(result.cleanup.is_none(), "{:?}", result.cleanup);
            if complete {
                assert_eq!(result.result.unwrap().entries[0].numbers, vec!["123"]);
            } else {
                assert!(result.result.is_err());
            }
            assert!(state.removed.load(Ordering::SeqCst));
            for path in state.paths.lock().unwrap().iter() {
                assert!(!std::path::Path::new(path).parent().unwrap().exists());
            }
        }
        drop(server);
        daemon.kill().await.unwrap();
    }
}
