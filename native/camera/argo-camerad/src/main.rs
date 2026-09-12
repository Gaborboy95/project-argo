mod capture;
mod device;
mod ring;
use capture::{Capture, Frame, Health};
use serde::Deserialize;
use serde_json::json;
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
        },
    },
    path::PathBuf,
    time::{Duration, Instant},
};
const LIMIT: usize = 16 * 1024;
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Command {
    version: u32,
    id: u64,
    op: String,
    role: Option<String>,
    stable_id: Option<String>,
}
#[derive(Default)]
struct Decoder {
    bytes: Vec<u8>,
}
impl Decoder {
    fn feed(&mut self, bytes: &[u8]) -> io::Result<()> {
        if self.bytes.len() + bytes.len() > LIMIT + 4 {
            return Err(io::Error::other("Camera control buffer too large"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
    fn next(&mut self) -> io::Result<Option<Command>> {
        if self.bytes.len() < 4 {
            return Ok(None);
        }
        let size = u32::from_be_bytes(self.bytes[..4].try_into().unwrap()) as usize;
        if size == 0 || size > LIMIT {
            return Err(io::Error::other("Camera control message length invalid"));
        }
        if self.bytes.len() < size + 4 {
            return Ok(None);
        }
        let command: Command = serde_json::from_slice(&self.bytes[4..4 + size])?;
        self.bytes.drain(..4 + size);
        if command.version != 1 {
            return Err(io::Error::other("Camera control version mismatch"));
        }
        Ok(Some(command))
    }
}
fn send(socket: &mut UnixStream, value: serde_json::Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(&value)?;
    if bytes.len() > LIMIT {
        return Err(io::Error::other("Camera inventory exceeds control limit"));
    }
    socket.write_all(&(bytes.len() as u32).to_be_bytes())?;
    socket.write_all(&bytes)
}
fn same_user(socket: &UnixStream) -> bool {
    unsafe {
        let mut cred: libc::ucred = std::mem::zeroed();
        let mut len = std::mem::size_of_val(&cred) as libc::socklen_t;
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        ) == 0
            && cred.uid == libc::geteuid()
    }
}
fn bounded(text: &str) -> String {
    text.chars().take(240).collect()
}
fn main() {
    if let Err(e) = run() {
        eprintln!("argo-camerad: {e}");
        std::process::exit(1)
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    gstreamer::init()?;
    if std::env::args().nth(1).as_deref() == Some("--enumerate") {
        println!("{}", serde_json::to_string_pretty(&device::enumerate()?)?);
        return Ok(());
    }
    let directory = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or("Expected private runtime directory")?,
    );
    let expected = PathBuf::from(std::env::var("XDG_RUNTIME_DIR")?).join("project-argo");
    if directory.parent() != Some(expected.as_path())
        || !directory
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with("camera-"))
    {
        return Err("Invalid camera runtime directory".into());
    }
    // Application creates this fresh private directory; never remove another owner's sockets.
    let metadata = fs::symlink_metadata(&directory)?;
    use std::os::unix::fs::MetadataExt;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err("Camera directory must be owned by this account and mode 0700".into());
    }
    let control_path = directory.join("control.sock");
    let media_path = directory.join("media.sock");
    let control = UnixListener::bind(&control_path)?;
    let media = UnixListener::bind(&media_path)?;
    control.set_nonblocking(true)?;
    media.set_nonblocking(true)?;
    let mut ring = ring::Ring::new()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut owner = loop {
        match control.accept() {
            Ok((s, _)) if same_user(&s) => break s,
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e.into()),
        };
        if Instant::now() >= deadline {
            return Err("Camera owner did not connect".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    owner.set_nonblocking(true)?;
    let mut decoder = Decoder::default();
    let mut viewer: Option<UnixStream> = None;
    let mut capture: Option<Capture> = None;
    let mut selected: Option<String> = None;
    let mut role: Option<String> = None;
    let mut state = "idle";
    let mut error: Option<String> = None;
    let mut frame = Frame::default();
    let mut last_frame = None::<u64>;
    let mut health = Health::new(Instant::now());
    let mut devices = device::enumerate()?;
    let mut next_inventory = Instant::now();
    let mut next_status = Instant::now();
    let result = (|| -> io::Result<()> {
        loop {
            let now = Instant::now();
            if let Some(peer) = &viewer {
                let mut byte = 0u8;
                let count = unsafe {
                    libc::recv(
                        peer.as_raw_fd(),
                        (&mut byte as *mut u8).cast(),
                        1,
                        libc::MSG_PEEK | libc::MSG_DONTWAIT,
                    )
                };
                if count == 0
                    || (count < 0 && io::Error::last_os_error().kind() != io::ErrorKind::WouldBlock)
                {
                    viewer = None;
                }
            }
            if let Ok((s, _)) = media.accept()
                && same_user(&s)
                && viewer.is_none()
            {
                s.set_write_timeout(Some(Duration::from_millis(100)))?;
                if ring.send_fds(s.as_raw_fd()).is_ok() {
                    viewer = Some(s);
                }
            }
            let mut bytes = [0; 2048];
            match owner.read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => decoder.feed(&bytes[..n])?,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
            for _ in 0..8 {
                let Some(command) = decoder.next()? else {
                    break;
                };
                let mut failure: Option<String> = None;
                match command.op.as_str() {
                    "refresh" => next_inventory = now,
                    "stop" | "close" => {
                        ring.invalidate();
                        if let Some(c) = capture.take() {
                            c.stop().map_err(io::Error::other)?;
                        }
                        selected = None;
                        role = None;
                        state = "idle";
                        error = None;
                        frame = Frame::default();
                        last_frame = None;
                        health = Health::new(now);
                    }
                    "start" => {
                        if !matches!(
                            command.role.as_deref(),
                            Some("rear" | "front" | "left" | "right")
                        ) {
                            failure = Some("Invalid camera role".into());
                        } else if let Some(id) = command.stable_id.filter(|id| id.len() <= 512) {
                            ring.invalidate();
                            if let Some(c) = capture.take() {
                                c.stop().map_err(io::Error::other)?;
                            }
                            selected = Some(id);
                            role = command.role;
                            ring.role(match role.as_deref() {
                                Some("front") => 1,
                                Some("left") => 2,
                                Some("right") => 3,
                                _ => 0,
                            });
                            health = Health::new(now);
                            health.retry_at = Some(now);
                            state = "starting";
                            error = None;
                            frame = Frame::default();
                            last_frame = None;
                            next_inventory = now;
                        } else {
                            failure = Some("A stable camera identity is required".into())
                        }
                    }
                    _ => failure = Some("Unsupported camera command".into()),
                }
                send(
                    &mut owner,
                    json!({"version":1,"id":command.id,"error":failure}),
                )?;
                if command.op == "close" {
                    return Ok(());
                }
                next_status = now;
            }
            if now >= next_inventory {
                match device::enumerate() {
                    Ok(d) => devices = d,
                    Err(e) => {
                        error = Some(bounded(&e.to_string()));
                    }
                }
                next_inventory = now + Duration::from_millis(500);
                if let Some(id) = &selected {
                    let present = devices.iter().any(|d| &d.stable_id == id);
                    if !present {
                        ring.invalidate();
                        if let Some(c) = capture.take() {
                            c.stop().map_err(io::Error::other)?;
                        }
                        state = "disconnected";
                        frame = Frame::default();
                        last_frame = None;
                        health.retry_at = None;
                    } else if state == "disconnected" {
                        health = Health::new(now);
                        health.retry_at = Some(now);
                        state = "starting";
                        error = None;
                    }
                }
            }
            if capture.is_none() && selected.is_some() && health.retry_at.is_some_and(|t| now >= t)
            {
                health.retry_at = None;
                if let Some(d) = devices
                    .iter()
                    .find(|d| Some(&d.stable_id) == selected.as_ref())
                {
                    match Capture::start(&d.capture_path()) {
                        Ok(c) => {
                            capture = Some(c);
                            health.last = now;
                            state = "starting";
                        }
                        Err(e) => {
                            error = Some(bounded(&e));
                            state = if health.failed(now) {
                                "starting"
                            } else {
                                "failed"
                            };
                        }
                    }
                } else {
                    state = "disconnected";
                }
            }
            if let Some(c) = &capture {
                match c.frame(&mut ring) {
                    Ok(Some(f)) => {
                        frame = f;
                        last_frame = Some(ring::monotonic_ns());
                        health.last = now;
                        state = "streaming";
                        error = None;
                    }
                    Ok(None) => {
                        if health.stale(now) {
                            if state != "stale" {
                                eprintln!(
                                    "Camera stale: no frame for 750 ms; native image blanked"
                                );
                            }
                            state = "stale";
                            ring.invalidate();
                        }
                    }
                    Err(e) => {
                        eprintln!("Camera capture failure: {}", bounded(&e));
                        error = Some(bounded(&e));
                        health.last = now - capture::RESTART;
                    }
                }
                if health.restart_due(now) {
                    ring.invalidate();
                    if let Some(c) = capture.take() {
                        c.stop().map_err(io::Error::other)?;
                    }
                    error.get_or_insert("Camera produced no frame for 2 seconds".into());
                    state = if health.failed(now) {
                        "stale"
                    } else {
                        "failed"
                    };
                    eprintln!(
                        "Camera capture stopped; retry {}/3, state {state}",
                        health.retries
                    );
                }
            }
            if now >= next_status {
                send(
                    &mut owner,
                    json!({"version":1,"devices":devices,"activeRole":role,"state":state,"frame":frame,"sequence":ring.sequence(),"lastFrameAgeMs":last_frame.map(|t|(ring::monotonic_ns().saturating_sub(t))/1_000_000),"error":error}),
                )?;
                next_status = now + Duration::from_millis(250);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(())
    })();
    ring.invalidate();
    if let Some(c) = capture.take() {
        c.stop().map_err(io::Error::other)?;
    }
    drop(viewer);
    drop(owner);
    drop(control);
    drop(media);
    fs::remove_file(control_path)?;
    fs::remove_file(media_path)?;
    match result {
        Err(e)
            if !matches!(
                e.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::UnexpectedEof
            ) =>
        {
            Err(e.into())
        }
        _ => Ok(()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_fragmented_and_versioned_ipc() {
        let mut d = Decoder::default();
        let bytes = br#"{"version":1,"id":1,"op":"stop"}"#;
        let mut wire = (bytes.len() as u32).to_be_bytes().to_vec();
        wire.extend(bytes);
        for b in wire {
            d.feed(&[b]).unwrap();
        }
        assert_eq!(d.next().unwrap().unwrap().op, "stop");
        d.feed(&u32::MAX.to_be_bytes()).unwrap();
        assert!(d.next().is_err());
        let mut d = Decoder::default();
        assert!(d.feed(&vec![0; LIMIT + 5]).is_err());
    }
}
