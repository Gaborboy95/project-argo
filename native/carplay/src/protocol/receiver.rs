//! Bounded native receiver for a single authenticated wired CarPlay session.
//! All listeners/tasks belong to the session and are dropped on control disconnect.
use super::{
    Error,
    airplay::{ControlDecoder, Request, ScreenHeader, ScreenKind},
    pairing::{self, ControlCipher, Identity, PairSetup, PairVerify, Peers, Verified},
};
use crate::{link::LinkClient, media};
use plist::{Dictionary, Value};
use std::{
    net::SocketAddr,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::{
        TcpListener, TcpStream, UdpSocket,
        tcp::{OwnedReadHalf, OwnedWriteHalf},
    },
    sync::{Mutex, mpsc, watch},
    task::JoinSet,
    time::{Instant, timeout},
};

impl From<std::io::Error> for Error {
    fn from(_: std::io::Error) -> Self {
        Self::Rejected
    }
}
type Result<T> = std::result::Result<T, Error>;
const MAIN_DISPLAY: &str = "20417267-6f00-4000-8000-000000000001";
const TOUCH: &str = "6172676f";

#[derive(Clone, Debug)]
pub struct Display {
    pub width: u16,
    pub height: u16,
    pub width_mm: u16,
    pub height_mm: u16,
    pub fps: u16,
    pub right_hand_drive: bool,
}
impl Display {
    pub fn validate(&self) -> Result<()> {
        if !(320..=1920).contains(&self.width)
            || !(240..=1080).contains(&self.height)
            || !(50..=1000).contains(&self.width_mm)
            || !(30..=1000).contains(&self.height_mm)
            || ![30, 60].contains(&self.fps)
        {
            return Err(Error::Bounds);
        }
        Ok(())
    }
}
#[derive(Clone)]
pub struct Video {
    pub first_frame: watch::Receiver<bool>,
    pub stream: media::VideoStream,
    pub description: media::Description,
}
#[derive(Clone, Debug)]
pub enum Command {
    AudioGain {
        connection: u64,
        gain: f64,
    },
    Touch {
        slot: u8,
        down: bool,
        x: u16,
        y: u16,
    },
    MicrophoneMute(bool),
    MicrophoneSource(String),
    ReleaseTouches,
    ReleaseAudio,
    Keyframe,
    Night(bool),
    Siri,
    SiriButton(bool),
}

fn dict(fields: impl IntoIterator<Item = (&'static str, Value)>) -> Value {
    Value::Dictionary(fields.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}
fn number(value: u64) -> Value {
    Value::Integer(value.into())
}
fn string(value: &str) -> Value {
    Value::String(value.into())
}
fn binary(value: &Value) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    value
        .to_writer_binary(&mut output)
        .map_err(|_| Error::Malformed)?;
    if output.len() > 256 * 1024 {
        return Err(Error::Bounds);
    }
    Ok(output)
}
fn uint(fields: &Dictionary, key: &str) -> Result<u64> {
    fields
        .get(key)
        .and_then(Value::as_unsigned_integer)
        .ok_or(Error::Malformed)
}
fn connection_id(fields: &Dictionary) -> Result<u64> {
    let value = fields.get("streamConnectionID").ok_or(Error::Malformed)?;
    value
        .as_unsigned_integer()
        .or_else(|| value.as_signed_integer().map(|v| v as u64))
        .ok_or(Error::Malformed)
}
/// Stream teardown may identify a type without repeating its connection ID.
/// Validate the selector before applying it; malformed selectors never match all.
#[cfg(feature = "linux-audio")]
fn teardown_selector(fields: &Dictionary) -> Result<(Option<u64>, Option<u64>)> {
    let kind = fields
        .contains_key("type")
        .then(|| uint(fields, "type"))
        .transpose()?;
    let connection = fields
        .contains_key("streamConnectionID")
        .then(|| connection_id(fields))
        .transpose()?;
    if kind.is_none() && connection.is_none() {
        return Err(Error::Malformed);
    }
    if kind.is_some_and(|kind| ![100, 101, 102].contains(&kind)) {
        return Err(Error::Unsupported);
    }
    Ok((kind, connection))
}

fn parse(body: &[u8]) -> Result<Dictionary> {
    super::usbmux::decode(body).map_err(|_| Error::Malformed)
}

/// HID descriptor built with typed short items. Two stable finger slots; absolute content coordinates.
fn touch_descriptor(display: &Display) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut item = |tag: u8, value: u16, wide: bool| {
        bytes.push(tag | if wide { 2 } else { 1 });
        bytes.push(value as u8);
        if wide {
            bytes.push((value >> 8) as u8);
        }
    };
    item(0x04, 0x0d, false);
    item(0x08, 4, false);
    item(0xa0, 1, false);
    for _ in 0..2 {
        item(0x04, 0x0d, false);
        item(0x08, 0x22, false);
        item(0xa0, 2, false);
        item(0x14, 0, false);
        item(0x24, 1, false);
        item(0x08, 0x38, false);
        item(0x74, 8, false);
        item(0x94, 1, false);
        item(0x80, 2, false);
        item(0x08, 0x33, false);
        item(0x74, 1, false);
        item(0x80, 2, false);
        item(0x94, 7, false);
        item(0x80, 3, false);
        item(0x04, 1, false);
        item(0x74, 16, false);
        item(0x94, 1, false);
        item(0x24, display.width, true);
        item(0x08, 0x30, false);
        item(0x80, 2, false);
        item(0x24, display.height, true);
        item(0x08, 0x31, false);
        item(0x80, 2, false);
        // EndCollection has no payload. Undo short-item encoding below.
        item(0xc0, 0, false);
    }
    let mut result = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0xc1 {
            result.push(0xc0);
            i += 2;
        } else {
            let size = (bytes[i] & 3) as usize;
            result.extend_from_slice(&bytes[i..i + 1 + size]);
            i += 1 + size;
        }
    }
    result.push(0xc0);
    result
}
/// AirPlay compatibility version used by the pinned LIVI 9.0.0 default config.
/// This is a protocol advertisement, not Argo's application version.
pub const SOURCE_VERSION: &str = "950.7.1";

fn info(display: &Display, identity: &Identity, audio: bool, microphone: bool) -> Value {
    // Native UI initially owns the screen, but no native audio is playing.
    // Do not permanently take mainAudio on startup. Resource ownership follows
    // actual use: https://developer.apple.com/videos/play/wwdc2016/723/.
    let resources = [1, 2].map(|id| {
        dict([
            ("resourceID", number(id)),
            ("transferType", number(if id == 2 { 2 } else { 1 })),
            ("transferPriority", number(100)),
            ("takeConstraint", number(100)),
            ("borrowConstraint", number(100)),
            ("unborrowConstraint", number(100)),
        ])
    });
    let mut result = dict([
        ("sourceVersion", string(SOURCE_VERSION)),
        (
            "features",
            number(if audio {
                0x615653aee2
            } else {
                0x615653aee2 & !0x10004540a00
            }),
        ),
        ("statusFlags", number(4)),
        ("model", string("Argo")),
        ("manufacturer", string("Argo")),
        ("deviceID", string(&identity.identifier)),
        ("name", string("Argo")),
        ("rightHandDrive", Value::Boolean(display.right_hand_drive)),
        ("keepAliveLowPower", Value::Boolean(false)),
        (
            "modes",
            dict([
                ("resources", Value::Array(resources.into())),
                (
                    "appStates",
                    Value::Array(vec![
                        dict([
                            ("appStateID", number(1)),
                            ("speechMode", Value::Integer((-1).into())),
                        ]),
                        dict([("appStateID", number(2)), ("state", Value::Boolean(false))]),
                        dict([("appStateID", number(3)), ("state", Value::Boolean(false))]),
                    ]),
                ),
            ]),
        ),
        (
            "displays",
            Value::Array(vec![dict([
                ("uuid", string(MAIN_DISPLAY)),
                ("type", number(110)),
                ("widthPixels", number(display.width as u64)),
                ("heightPixels", number(display.height as u64)),
                ("widthPhysical", number(display.width_mm as u64)),
                ("heightPhysical", number(display.height_mm as u64)),
                ("maxFPS", number(display.fps as u64)),
                ("features", number(8)),
                ("primaryInputDevice", number(1)),
            ])]),
        ),
        (
            "hidDevices",
            Value::Array(vec![dict([
                ("uuid", string(TOUCH)),
                ("name", string("Argo Touchscreen")),
                ("displayUUID", string(MAIN_DISPLAY)),
                ("hidVendorID", number(2)),
                ("hidProductID", number(1)),
                ("hidCountryCode", number(0)),
                ("hidDescriptor", Value::Data(touch_descriptor(display))),
            ])]),
        ),
    ]);
    if audio {
        let fields = result.as_dictionary_mut().unwrap();
        let mut formats = Vec::new();
        let mut latencies = Vec::new();
        for (kind, category, mask) in [
            (100, "compatibility", 0xc3fc),
            (101, "compatibility", 0xc3fc),
            (100, "media", 0xcc00),
            (100, "default", 0xc3fc),
            (100, "telephony", 0x4154),
            (100, "speechRecognition", 0x4154),
            (100, "alert", 0xc3fc),
            (101, "default", 0xc3fc),
            (102, "media", 0xc00000),
        ] {
            let mut format = dict([
                ("type", number(kind)),
                ("audioType", string(category)),
                ("audioOutputFormats", number(mask)),
            ]);
            if microphone
                && kind == 100
                && ["compatibility", "default", "telephony", "speechRecognition"]
                    .contains(&category)
            {
                format
                    .as_dictionary_mut()
                    .unwrap()
                    .insert("audioInputFormats".into(), number(0x10));
            }
            formats.push(format);
            latencies.push(dict([
                ("type", number(kind)),
                ("audioType", string(category)),
                ("inputLatencyMicros", number(0)),
                ("outputLatencyMicros", number(0)),
            ]));
        }
        // Stream-wide latency entries are separate from format categories.
        for kind in [100, 101] {
            latencies.push(dict([
                ("type", number(kind)),
                ("inputLatencyMicros", number(0)),
                ("outputLatencyMicros", number(0)),
            ]));
        }
        latencies.push(dict([
            ("type", number(102)),
            ("audioType", string("default")),
            ("inputLatencyMicros", number(0)),
            ("outputLatencyMicros", number(0)),
        ]));
        fields.insert("audioFormats".into(), Value::Array(formats));
        fields.insert("audioLatencies".into(), Value::Array(latencies));
    }
    result
}

struct Wire {
    input: Incoming,
    output: Outgoing,
}
struct Incoming {
    io: BufReader<OwnedReadHalf>,
    decoder: ControlDecoder,
    cipher: Option<ControlCipher>,
}
struct Outgoing {
    io: OwnedWriteHalf,
    cipher: Option<ControlCipher>,
}
impl Wire {
    fn new(stream: TcpStream) -> Self {
        let (read, write) = stream.into_split();
        Self {
            input: Incoming {
                io: BufReader::new(read),
                decoder: ControlDecoder::default(),
                cipher: None,
            },
            output: Outgoing {
                io: write,
                cipher: None,
            },
        }
    }
    async fn respond(&mut self, request: &Request, body: &[u8], content_type: &str) -> Result<()> {
        self.output.respond(request, body, content_type).await
    }
}
impl Incoming {
    async fn receive(&mut self) -> Result<Request> {
        loop {
            if let Some(request) = self.decoder.next_request()? {
                return Ok(request);
            }
            if let Some(cipher) = &mut self.cipher {
                let mut header = [0; 2];
                self.io.read_exact(&mut header).await?;
                let size = u16::from_le_bytes(header) as usize;
                if size > 16384 {
                    return Err(Error::Bounds);
                }
                let mut frame = vec![0; size + 18];
                frame[..2].copy_from_slice(&header);
                self.io.read_exact(&mut frame[2..]).await?;
                self.decoder.push(&cipher.decrypt(&frame)?)?;
            } else {
                // BufReader avoids syscalls per byte and keeps post-verify ciphertext out of the RTSP parser.
                let byte = self.io.read_u8().await?;
                self.decoder.push(&[byte])?;
            }
        }
    }
}
impl Outgoing {
    async fn send(&mut self, bytes: &[u8]) -> Result<()> {
        timeout(Duration::from_secs(3), async {
            if let Some(cipher) = &mut self.cipher {
                for part in bytes.chunks(16384) {
                    self.io.write_all(&cipher.encrypt(part)?).await?;
                }
            } else {
                self.io.write_all(bytes).await?;
            }
            Ok(())
        })
        .await
        .map_err(|_| Error::Timeout)?
    }
    async fn respond(&mut self, request: &Request, body: &[u8], content_type: &str) -> Result<()> {
        let sequence = request.headers.get("cseq").ok_or(Error::Malformed)?;
        if sequence.len() > 10 || !sequence.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Error::Malformed);
        }
        let header = format!(
            "{} 200 OK\r\nCSeq: {}\r\nContent-Type: {}\r\nContent-Length: {}\r\n\r\n",
            request.protocol,
            sequence,
            content_type,
            body.len()
        );
        self.send(&[header.as_bytes(), body].concat()).await
    }
}

/// Run after successful wired iAP2/MFi authentication, bound to the owned phone network.
/// State is shared between connections so a paired phone can reconnect to this owner.
#[derive(Clone, Default)]
pub struct AudioOptions {
    pub sink: Option<String>,
    pub input: Option<String>,
}

#[derive(Clone, Default, serde::Serialize)]
pub struct SessionInfo {
    pub name: String,
    pub recorded: bool,
    pub audio_available: bool,
    pub host_return_revision: u64,
    pub audio: Vec<AudioInfo>,
    pub phone_duck: Option<PhoneDuck>,
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct PhoneDuck {
    pub gain: f64,
    pub ramp_ms: u32,
}
fn phone_duck(command: &plist::Dictionary, unduck: bool) -> PhoneDuck {
    let params = command.get("params").and_then(Value::as_dictionary);
    let number = |key| {
        params
            .and_then(|p| p.get(key))
            .and_then(|v| {
                v.as_real()
                    .or_else(|| v.as_signed_integer().map(|n| n as f64))
            })
            .filter(|v| v.is_finite())
    };
    let db = number("volume").unwrap_or(0.0).clamp(-80.0, 0.0);
    PhoneDuck {
        gain: if unduck { 1.0 } else { 10.0f64.powf(db / 20.0) },
        ramp_ms: number("durationMs").unwrap_or(0.0).clamp(0.0, 2000.0) as u32,
    }
}
#[derive(Clone, serde::Serialize)]
pub struct AudioInfo {
    pub connection: String,
    pub category: String,
    pub rate: u32,
    pub channels: u8,
    pub active: bool,
    #[cfg(feature = "linux-audio")]
    pub metrics: super::audio::Metrics,
}

pub struct Receiver {
    pub information: watch::Sender<SessionInfo>,
    pub pairing_directory: Option<std::path::PathBuf>,
    pub audio: Option<AudioOptions>,
    pub display: Display,
    pub identity: Arc<Identity>,
    pub peers: Arc<Mutex<Peers>>,
    pub link: LinkClient,
}
impl Receiver {
    pub async fn run(
        &self,
        socket: TcpStream,
        session: u64,
        video: watch::Sender<Option<Video>>,
        mut commands: mpsc::Receiver<Command>,
    ) -> Result<()> {
        self.display.validate()?;
        if self.audio.is_some() && !cfg!(feature = "linux-audio") {
            return Err(Error::Unsupported);
        }
        #[cfg(feature = "linux-audio")]
        if self.audio.is_some() {
            super::audio::available()?;
            if let Some(source) = self.audio.as_ref().and_then(|a| a.input.as_deref()) {
                super::audio::capture_available(source)?;
            }
        }
        #[cfg(feature = "linux-audio")]
        let mut audio: Vec<super::audio::Stream> = Vec::new();
        self.information
            .send_modify(|s| s.audio_available = self.audio.is_some());
        let clock = Arc::new(std::sync::Mutex::new(SessionClock::new()));
        #[cfg_attr(
            not(feature = "linux-audio"),
            allow(unused_variables, unused_assignments)
        )]
        let mut microphone_muted = false;
        #[cfg_attr(
            not(feature = "linux-audio"),
            allow(unused_variables, unused_assignments)
        )]
        let mut microphone_source = self.audio.as_ref().and_then(|a| a.input.clone());
        let mut screen_started = false;
        let local = socket.local_addr()?;
        let peer = socket.peer_addr()?;
        let mut wire = Wire::new(socket);
        let mut setup = PairSetup::default();
        let mut verify = PairVerify::default();
        let mut verified: Option<Verified> = None;
        let mut verify_started = false;
        let mut authenticated = false;
        let mut session_setup = false;
        let mut tasks = JoinSet::new();
        let (events_tx, events_rx) = mpsc::channel(32);
        let mut events_rx = Some(events_rx);
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut active = false;
        let result = async {
            loop {
                let request = {
                    let input = timeout(if active {Duration::from_secs(15)} else {deadline.saturating_duration_since(Instant::now())}, wire.input.receive());
                    tokio::pin!(input);
                    loop {
                        tokio::select! {
                            request = &mut input => break request.map_err(|_| Error::Timeout)??,
                            command = commands.recv() => {
                                match command.ok_or(Error::State)? {
                                    Command::AudioGain {connection, gain} => {
                                        #[cfg(feature = "linux-audio")]
                                        if let Some(stream) = audio.iter().find(|s| s.connection == connection) { stream.set_gain(gain)?; }
                                        #[cfg(not(feature = "linux-audio"))]
                                        let _ = (connection, gain);
                                    }
                                    Command::MicrophoneSource(source) => {
                                        microphone_source=Some(source.clone());
                                        #[cfg(feature = "linux-audio")]
                                        for stream in &audio {stream.set_microphone_source(source.clone());}
                                    }
                                    Command::MicrophoneMute(muted) => {
                                        microphone_muted = muted;
                                        #[cfg(feature = "linux-audio")]
                                        for stream in &audio { stream.set_microphone_muted(muted); }
                                    }
                                    command if active => { events_tx.try_send(command).map_err(|_| Error::Bounds)?; }
                                    _ => {}
                                }
                            }
                            Some(result) = tasks.join_next(), if !tasks.is_empty() => { result.map_err(|_| Error::Rejected)??; return Err(Error::Rejected); },
                        }
                    }
                };
                let path = request.target.as_str();
                if path != "/feedback" { eprintln!("CarPlay control: {} {}", request.method, match path { "/pair-setup"|"/pair-verify"|"/auth-setup"|"/info"|"/feedback"|"/command" => path, _ => "session" }); }
                let mut body = Vec::new(); let mut kind = "application/x-apple-binary-plist";
                let mut activate_cipher = false;
                match (request.method.as_str(), path) {
                    ("POST", "/pair-setup") if verified.is_none() => {
                        let mut peers = self.peers.lock().await;
                        body = setup.handle(&request.body, &self.identity, &mut peers)?;
                        if pairing::decode_tlv(&body)?.get(&6).map(Vec::as_slice) == Some(&[6]) && let Some(directory) = &self.pairing_directory { peers.save(directory)?; }
                        kind = "application/pairing+tlv8";
                    }
                    ("POST", "/pair-verify") if verified.is_none() => {
                        body = if !verify_started { verify_started = true; verify.start(&request.body, &self.identity)? }
                            else { let (response, keys) = verify.finish(&request.body, &*self.peers.lock().await)?; verified = Some(keys); activate_cipher = true; response };
                        kind = "application/pairing+tlv8";
                    }
                    ("POST", "/auth-setup") if verified.is_some() && !authenticated => {
                        body = pairing::auth_setup(&request.body, &self.link).await?;
                        authenticated = true; kind = "application/octet-stream";
                    }
                    ("GET"|"POST", "/info") => {
                        let capabilities = info(&self.display, &self.identity, self.audio.is_some(), self.audio.as_ref().is_some_and(|a|a.input.is_some()));
                        let formats = capabilities.as_dictionary().and_then(|d|d.get("audioFormats")).and_then(Value::as_array);
                        let inputs = formats.map_or(0, |formats| formats.iter().filter(|format| format.as_dictionary().is_some_and(|f| f.contains_key("audioInputFormats"))).count());
                        eprintln!("CarPlay capabilities: version={}, audio={}, output_entries={}, input_entries={}", SOURCE_VERSION, self.audio.is_some(), formats.map_or(0,Vec::len), inputs);
                        body = binary(&capabilities)?;
                    }
                    ("OPTIONS", _) => {}
                    ("SETUP", _) if authenticated => {
                        let fields = parse(&request.body)?;
                        if let Some(streams) = fields.get("streams").and_then(Value::as_array) {
                            if !session_setup || streams.is_empty() || streams.len() > 4 { return Err(Error::State); }
                            let mut replies = Vec::new();
                            for stream in streams {
                                let fields = stream.as_dictionary().ok_or(Error::Malformed)?;
                                let kind = uint(fields, "type")?;
                                eprintln!("CarPlay stream SETUP: type={kind}, format={:?}", fields.get("audioFormat").and_then(Value::as_unsigned_integer));
                                let connection = connection_id(fields)?;
                                let key = pairing::derive_key(&verified.as_ref().ok_or(Error::State)?.secret, &format!("DataStream-Salt{connection}"), "DataStream-Output-Encryption-Key")?;
                                if kind == 110 {
                                    if screen_started { return Err(Error::State); }
                                    let listener = TcpListener::bind(with_port(local, 0)).await?;
                                    let port = listener.local_addr()?.port();
                                    let display = self.display.clone(); let video = video.clone(); let events = events_tx.clone();
                                    tasks.spawn(async move { let result = screen(listener, peer, key, display, session, video, events).await; if let Err(e) = &result { eprintln!("CarPlay screen ended: {e}"); } result });
                                    screen_started = true;
                                    replies.push(dict([("type", number(110)), ("dataPort", number(port as u64))]));
                                } else {
                                    #[cfg(feature = "linux-audio")]
                                    {
                                        let options = self.audio.as_ref().ok_or(Error::Unsupported)?;
                                        if audio.len() >= 4 || audio.iter().any(|s|s.connection == connection) { return Err(Error::Bounds); }
                                        let format = super::airplay::AudioFormat::selected(uint(fields,"audioFormat")?)?;
                                        let category = fields.get("audioType").and_then(Value::as_string).unwrap_or("default");
                                        if !["media","default","compatibility","alert","telephony","speechRecognition"].contains(&category) { return Err(Error::Unsupported); }
                                        let microphone_port=fields.get("dataPort").and_then(Value::as_unsigned_integer).unwrap_or(0);
                                        let capture=if microphone_port != 0 {
                                            if kind!=100 || format.codec!=super::airplay::AudioCodec::SignedPcm16 || format.sample_rate!=16000 || format.channels!=1 {return Err(Error::Unsupported);}
                                            Some(super::audio::CaptureOptions {
                                                source:microphone_source.clone().ok_or(Error::Unsupported)?,
                                                key:pairing::derive_key(&verified.as_ref().ok_or(Error::State)?.secret,&format!("DataStream-Salt{connection}"),"DataStream-Input-Encryption-Key")?,
                                                peer:with_port(peer,u16::try_from(microphone_port).map_err(|_|Error::Bounds)?),
                                                frames_per_packet:u32::try_from(fields.get("framesPerPacket").and_then(Value::as_unsigned_integer).unwrap_or(0)).map_err(|_|Error::Bounds)?,
                                            })
                                        } else {None};
                                        let latency = fields.get("audioLatencyMs").and_then(Value::as_unsigned_integer).unwrap_or(if kind == 102 {1000} else {20});
                                        let stream = super::audio::Stream::start(with_port(local,0), peer, key, connection, u16::try_from(kind).map_err(|_|Error::Bounds)?, format, category.into(), u32::try_from(latency).map_err(|_|Error::Bounds)?, options.sink.as_deref(),capture).await?;
                                        replies.push(dict([("type",number(kind)),("dataPort",number(stream.data_port as u64)),("controlPort",number(stream.control_port as u64)),("streamConnectionID",Value::Integer((connection as i64).into()))]));
                                        stream.set_microphone_muted(microphone_muted);
                                        audio.push(stream);
                                    }
                                    #[cfg(not(feature = "linux-audio"))]
                                    return Err(Error::Unsupported);
                                }
                            }
                            body = binary(&dict([("streams", Value::Array(replies))]))?;
                        } else {
                            if session_setup { return Err(Error::State); }
                            if let Some(name) = fields.get("name").and_then(Value::as_string) && !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control) { self.information.send_modify(|s|s.name=name.to_owned()); }
                            let timing_port = u16::try_from(uint(&fields, "timingPort")?).map_err(|_| Error::Bounds)?;
                            if timing_port == 0 { return Err(Error::Bounds); }
                            let udp = UdpSocket::bind(with_port(local, 0)).await?;
                            let timing_bound = udp.local_addr()?.port();
                            tasks.spawn(timing(udp, with_port(peer, timing_port), clock.clone()));
                            let listener = TcpListener::bind(with_port(local, 0)).await?;
                            let event_port = listener.local_addr()?.port();
                            let secret = verified.as_ref().ok_or(Error::State)?.secret.clone();
                            let events = events_rx.take().ok_or(Error::State)?;
                            tasks.spawn(async move { let result=event_channel(listener, peer, secret, events).await; if let Err(e)=&result {eprintln!("CarPlay events ended: {e}");} result });
                            body = binary(&dict([("timingPort", number(timing_bound as u64)), ("eventPort", number(event_port as u64))]))?;
                            session_setup = true;
                        }
                    }
                    ("RECORD", _) if authenticated && session_setup => { active = true; self.information.send_modify(|s|s.recorded=true); }
                    ("POST", "/feedback") if authenticated => {
                        #[cfg(feature = "linux-audio")]
                        {
                            let mut streams = Vec::new();
                            for stream in &audio {
                                if !stream.healthy() { return Err(Error::Rejected); }
                                let mut fields = dict([("type", number(stream.kind as u64)),("sampleRate", number(stream.format.sample_rate as u64)),("streamConnectionID",number(stream.connection))]);
                                if let Some(anchor) = *stream.anchor.lock().unwrap() {
                                    let elapsed = anchor.started.elapsed().saturating_sub(Duration::from_millis(stream.latency_ms as u64));
                                    let sample = anchor.sample.wrapping_add((elapsed.as_secs_f64()*stream.format.sample_rate as f64) as u32);
                                    let fields = fields.as_dictionary_mut().unwrap(); fields.insert("sampleTime".into(),number(sample as u64)); fields.insert("timestamp".into(),number(clock.lock().unwrap().now()));
                                }
                                streams.push(fields);
                            }
                            body = audio_feedback(streams)?;
                        }
                    }
                    ("POST", "/command") if authenticated => {
                        let command = parse(&request.body)?;
                        match command.get("type").and_then(Value::as_string) {
                            Some("modesChanged") => {
                                if let Some(resources) = command.get("params").and_then(Value::as_dictionary).and_then(|p|p.get("resources")).and_then(Value::as_array) {
                                    for resource in resources.iter().take(4) {
                                        if let Some(resource)=resource.as_dictionary() {
                                            eprintln!("CarPlay resource: id={:?} entity={:?}", resource.get("resourceID").and_then(Value::as_signed_integer),resource.get("entity").and_then(Value::as_signed_integer));
                                        }
                                    }
                                }
                            }
                            Some(kind @ ("duckAudio"|"unduckAudio")) => {
                                let duck = phone_duck(&command, kind == "unduckAudio");
                                self.information.send_modify(|s| s.phone_duck = Some(duck));
                            },
                            _ => {}
                        }
                        if command.get("type").and_then(Value::as_string) == Some("requestUI") { self.information.send_modify(|s|s.host_return_revision=s.host_return_revision.saturating_add(1)); }
                    }
                    ("TEARDOWN", _) if authenticated => {
                        if !request.body.is_empty() && let Some(streams) = parse(&request.body)?.get("streams").and_then(Value::as_array) {
                            #[cfg(feature = "linux-audio")]
                            for stream in streams {
                                let fields = stream.as_dictionary().ok_or(Error::Malformed)?;
                                let (kind, connection) = teardown_selector(fields)?;
                                eprintln!("CarPlay audio TEARDOWN: type={kind:?}, connection_present={}", connection.is_some());
                                while let Some(index) = audio.iter().position(|s| kind.is_none_or(|kind| u64::from(s.kind) == kind) && connection.is_none_or(|connection| s.connection == connection)) { audio.remove(index).close().await; }
                            }
                            #[cfg(not(feature = "linux-audio"))]
                            let _ = streams;
                        } else { wire.respond(&request,&[],kind).await?; return Ok(()); }
                    }
                    _ => return Err(Error::Unsupported),
                }
                #[cfg(feature = "linux-audio")]
                self.information.send_modify(|state| state.audio = audio.iter().map(|stream| AudioInfo {connection:stream.connection.to_string(),category:stream.category.clone(),rate:stream.format.sample_rate,channels:stream.format.channels,active:stream.anchor.lock().unwrap().is_some(),metrics:*stream.metrics.lock().unwrap()}).collect());
                wire.respond(&request, &body, kind).await?;
                if activate_cipher { let keys = verified.as_ref().unwrap(); wire.input.cipher = Some(ControlCipher::new(keys.read)); wire.output.cipher = Some(ControlCipher::new(keys.write)); }
            }
        }.await;
        #[cfg(feature = "linux-audio")]
        for stream in audio.drain(..) {
            stream.close().await;
        }
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        if let Some(video) = video.send_replace(None) {
            video.stream.stop();
        }
        self.information.send_modify(|s| {
            s.recorded = false;
            s.audio.clear();
            s.phone_duck = None;
        });
        result
    }
}

#[cfg(feature = "linux-audio")]
fn audio_feedback(streams: Vec<Value>) -> Result<Vec<u8>> {
    // With no negotiated stream, acknowledge the keepalive without a media-clock
    // report. An empty stream-list report is not a playback position.
    if streams.is_empty() {
        return Ok(Vec::new());
    }
    binary(&dict([("streams", Value::Array(streams))]))
}

fn with_port(mut address: SocketAddr, port: u16) -> SocketAddr {
    address.set_port(port);
    address
}

async fn accept(listener: TcpListener, peer: SocketAddr) -> Result<TcpStream> {
    let (socket, remote) = timeout(Duration::from_secs(15), listener.accept())
        .await
        .map_err(|_| Error::Timeout)??;
    if remote.ip() != peer.ip() {
        return Err(Error::Rejected);
    }
    Ok(socket)
}
async fn screen(
    listener: TcpListener,
    peer: SocketAddr,
    key: [u8; 32],
    display: Display,
    session: u64,
    video: watch::Sender<Option<Video>>,
    events: mpsc::Sender<Command>,
) -> Result<()> {
    let mut socket = accept(listener, peer).await?;
    let mut counter = 0u64;
    let (first_frame, _) = watch::channel(false);
    let mut output: Option<media::VideoStream> = None;
    let mut configuration: Option<Vec<u8>> = None;
    let mut nalu_length = 0usize;
    let started = Instant::now();
    let mut last_keyframe_request = started - Duration::from_secs(1);
    loop {
        let mut header = [0; 128];
        timeout(Duration::from_secs(15), socket.read_exact(&mut header))
            .await
            .map_err(|_| Error::Timeout)??;
        let parsed = ScreenHeader::parse(&header).inspect_err(|_| {
            eprintln!(
                "Screen header rejected: opcode={}, length={}",
                header[4],
                u32::from_le_bytes(header[..4].try_into().unwrap())
            );
        })?;
        let mut body = vec![0; parsed.body_length];
        timeout(Duration::from_secs(3), socket.read_exact(&mut body))
            .await
            .map_err(|_| Error::Timeout)??;
        match parsed.kind {
            ScreenKind::Ignore => continue,
            ScreenKind::CodecConfiguration => {
                let config = canonical_avcc(avcc(&body)?)?;
                if let Some(previous) = &configuration {
                    if previous == &config {
                        continue;
                    }
                    return Err(Error::Unsupported);
                }
                configuration = Some(config.clone());
                nalu_length = usize::from((config[4] & 3) + 1);
                let description = media::Description {
                    protocol: media::Protocol::CarPlay,
                    plane: media::Plane::Main,
                    codec: media::Codec::H264,
                    colorimetry: media::Colorimetry::Bt709,
                    range: media::ColorRange::Full,
                    framing: media::Framing::LengthPrefixed,
                    width: display.width,
                    height: display.height,
                    fps_num: display.fps,
                    fps_den: 1,
                    session,
                };
                let stream =
                    media::VideoStream::new(description, &config).map_err(|_| Error::Malformed)?;
                video.send_replace(Some(Video {
                    first_frame: first_frame.subscribe(),
                    stream: stream.clone(),
                    description,
                }));
                output = Some(stream);
            }
            ScreenKind::EncryptedAccessUnit => {
                let stream = output.as_ref().ok_or(Error::State)?;
                if counter == u64::MAX {
                    return Err(Error::Bounds);
                }
                let mut nonce = [0; 12];
                nonce[4..].copy_from_slice(&counter.to_le_bytes());
                let plain = pairing::open(&key, &nonce, &header, &body)?;
                counter += 1;
                let keyframe = is_keyframe(&plain, nalu_length)?;
                let outcome = stream
                    .publish(&plain, started.elapsed().as_nanos() as u64, keyframe)
                    .map_err(|_| Error::Malformed)?;
                if !matches!(outcome, media::PublishOutcome::NeedKeyframe) {
                    first_frame.send_replace(true);
                }
                if matches!(outcome, media::PublishOutcome::NeedKeyframe)
                    && last_keyframe_request.elapsed() >= Duration::from_millis(250)
                {
                    events
                        .try_send(Command::Keyframe)
                        .map_err(|_| Error::Bounds)?;
                    last_keyframe_request = Instant::now();
                }
            }
        }
    }
}
fn avcc(body: &[u8]) -> Result<&[u8]> {
    if body.first() == Some(&1) && body.len() >= 9 && body[4] & 0xfc == 0xfc {
        return Ok(body);
    }
    for offset in 4..body.len().saturating_sub(4) {
        if &body[offset..offset + 4] == b"avcC" {
            let size = u32::from_be_bytes(body[offset - 4..offset].try_into().unwrap()) as usize;
            if size < 17 || size > body.len() - (offset - 4) {
                return Err(Error::Bounds);
            }
            return Ok(&body[offset + 4..offset - 4 + size]);
        }
    }
    Err(Error::Unsupported)
}
fn canonical_avcc(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() < 7 || bytes[0] != 1 {
        return Err(Error::Malformed);
    }
    let mut config = bytes.to_vec();
    let mut position = 6;
    let mut skip = |count: usize| -> Result<()> {
        for _ in 0..count {
            let length = config.get(position..position + 2).ok_or(Error::Bounds)?;
            let length = u16::from_be_bytes(length.try_into().unwrap()) as usize;
            position = position.checked_add(2 + length).ok_or(Error::Bounds)?;
            if length == 0 || position > config.len() {
                return Err(Error::Bounds);
            }
        }
        Ok(())
    };
    skip((config[5] & 31) as usize)?;
    let count = *config.get(position).ok_or(Error::Bounds)? as usize;
    position += 1;
    for _ in 0..count {
        let length = config.get(position..position + 2).ok_or(Error::Bounds)?;
        let length = u16::from_be_bytes(length.try_into().unwrap()) as usize;
        position = position.checked_add(2 + length).ok_or(Error::Bounds)?;
        if length == 0 || position > config.len() {
            return Err(Error::Bounds);
        }
    }
    if position < config.len() {
        if ![100, 110, 122, 144].contains(&config[1]) || config.len() - position < 4 {
            return Err(Error::Malformed);
        }
        // Real iOS sends these reserved fields as zero. Canonicalize only the
        // reserved bits; preserve every negotiated chroma/depth/NAL byte.
        for (offset, mask) in [(0, 0xfc), (1, 0xf8), (2, 0xf8)] {
            let value = &mut config[position + offset];
            if *value & mask != 0 && *value & mask != mask {
                return Err(Error::Malformed);
            }
            *value |= mask;
        }
    }
    Ok(config)
}

fn is_keyframe(mut bytes: &[u8], length: usize) -> Result<bool> {
    if ![1, 2, 4].contains(&length) {
        return Err(Error::Malformed);
    }
    let mut key = false;
    let mut count = 0;
    while !bytes.is_empty() {
        count += 1;
        if count > 1024 {
            return Err(Error::Bounds);
        }
        let size = bytes
            .get(..length)
            .ok_or(Error::Bounds)?
            .iter()
            .fold(0usize, |v, b| (v << 8) | *b as usize);
        bytes = &bytes[length..];
        if size == 0 || size > bytes.len() {
            return Err(Error::Bounds);
        }
        key |= bytes[0] & 31 == 5;
        bytes = &bytes[size..];
    }
    Ok(key)
}

fn siri_button(pressed: bool) -> Value {
    dict([
        ("type", string("requestSiri")),
        (
            "params",
            dict([("siriAction", number(if pressed { 2 } else { 3 }))]),
        ),
    ])
}

async fn event_channel(
    listener: TcpListener,
    peer: SocketAddr,
    secret: Vec<u8>,
    mut commands: mpsc::Receiver<Command>,
) -> Result<()> {
    let socket = accept(listener, peer).await?;
    let mut wire = Wire::new(socket);
    wire.input.cipher = Some(ControlCipher::new(pairing::derive_key(
        &secret,
        "Events-Salt",
        "Events-Read-Encryption-Key",
    )?));
    wire.output.cipher = Some(ControlCipher::new(pairing::derive_key(
        &secret,
        "Events-Salt",
        "Events-Write-Encryption-Key",
    )?));
    let mut contacts = [0u8; 12];
    contacts[6] = 1;
    let mut sequence = 0u32;
    loop {
        let next = wire.input.receive();
        tokio::pin!(next);
        loop {
            tokio::select! {
                command = commands.recv() => {
                    let command = command.ok_or(Error::State)?;
                    let click = matches!(command, Command::Siri);
                    let payload = match command {
                        Command::AudioGain { .. } | Command::MicrophoneMute(_) | Command::MicrophoneSource(_) => return Err(Error::State),
                        Command::Touch {slot, down, x, y} => {
                            if slot > 1 { return Err(Error::Bounds); }
                            let i = slot as usize * 6; contacts[i+1] = u8::from(down);
                            contacts[i+2..i+4].copy_from_slice(&x.to_le_bytes()); contacts[i+4..i+6].copy_from_slice(&y.to_le_bytes());
                            dict([("type", string("hidSendReport")), ("uuid", string(TOUCH)), ("hidReport", Value::Data(contacts.to_vec()))])
                        }
                        Command::ReleaseTouches => { contacts[1] = 0; contacts[7] = 0; dict([("type", string("hidSendReport")), ("uuid", string(TOUCH)), ("hidReport", Value::Data(contacts.to_vec()))]) }
                        Command::ReleaseAudio => dict([("type",string("changeModes")),("params",dict([("resources",Value::Array(vec![dict([("resourceID",number(2)),("transferType",number(2))])]))]))]),
                        Command::Keyframe => dict([("type", string("forceKeyFrame")), ("params", dict([("uuid", string(MAIN_DISPLAY))]))]),
                        Command::Night(value) => dict([("type", string("setNightMode")), ("params", dict([("nightMode", Value::Boolean(value))]))]),
                        Command::Siri => siri_button(true),
                        Command::SiriButton(pressed) => siri_button(pressed),
                    };
                    let payloads = if click { vec![payload, siri_button(false)] } else { vec![payload] };
                    for payload in payloads {
                    let body = binary(&payload)?; sequence = sequence.checked_add(1).ok_or(Error::Bounds)?;
                    let header = format!("POST /command RTSP/1.0\r\nCSeq: {sequence}\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: {}\r\n\r\n", body.len());
                    wire.output.send(&[header.as_bytes(), &body].concat()).await?;
                    }
                }
                request = &mut next => { let request = request?; if !request.method.starts_with("RTSP/") && !request.method.starts_with("HTTP/") { wire.output.respond(&request, &[], "application/x-apple-binary-plist").await?; } else if request.target != "200" { eprintln!("CarPlay event response status: {:?}",request.target.parse::<u16>().ok()); return Err(Error::Rejected); } break; }
            }
        }
    }
}
fn ntp() -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    ((now.as_secs() + 2_208_988_800) << 32) | (((now.subsec_nanos() as u64) << 32) / 1_000_000_000)
}
/// A monotonic host clock steered into the phone's NTP domain. Timing packets
/// and audio feedback must use the same clock, including after host wall changes.
struct SessionClock {
    origin: Instant,
    base: u64,
    adjustment: i128,
    synchronized: bool,
}
impl SessionClock {
    fn new() -> Self {
        Self {
            origin: Instant::now(),
            base: ntp(),
            adjustment: 0,
            synchronized: false,
        }
    }
    fn now(&self) -> u64 {
        let elapsed = self.origin.elapsed();
        let ticks = ((elapsed.as_secs() as i128) << 32)
            + ((elapsed.subsec_nanos() as i128) << 32) / 1_000_000_000;
        (self.base as i128 + ticks + self.adjustment) as u64
    }
    fn observe(&mut self, sent: u64, received: u64, remote_receive: u64, remote_send: u64) -> bool {
        let (t1, t2, t3, t4) = (
            sent as i128,
            remote_receive as i128,
            remote_send as i128,
            received as i128,
        );
        let delay = (t4 - t1) - (t3 - t2);
        if t3 < t2 || !(0..(1i128 << 32)).contains(&delay) {
            return false;
        }
        let correction = ((t2 - t1) + (t3 - t4)) / 2;
        let first = !self.synchronized;
        self.adjustment += if first || correction.abs() > (1i128 << 29) {
            correction
        } else {
            correction / 8
        };
        self.synchronized = true;
        if first {
            eprintln!("CarPlay timing synchronized");
        }
        true
    }
}
async fn timing(
    socket: UdpSocket,
    peer: SocketAddr,
    clock: Arc<std::sync::Mutex<SessionClock>>,
) -> Result<()> {
    socket.connect(peer).await?;
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut pending = None;
    let mut buffer = [0; 64];
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let mut packet = [0;32]; packet[..4].copy_from_slice(&[0x80,210,0,7]);
                let sent = clock.lock().unwrap().now();
                pending = Some(sent); packet[24..32].copy_from_slice(&sent.to_be_bytes()); socket.send(&packet).await?;
            }
            received = socket.recv(&mut buffer) => {
                if received? != 32 || buffer[0] != 0x80 || buffer[2..4] != [0,7] { continue; }
                let now = clock.lock().unwrap().now();
                match buffer[1] {
                    210 => { let mut response = [0;32]; response[..4].copy_from_slice(&[0x80,211,0,7]); response[8..16].copy_from_slice(&buffer[24..32]); response[16..24].copy_from_slice(&now.to_be_bytes()); response[24..32].copy_from_slice(&clock.lock().unwrap().now().to_be_bytes()); socket.send(&response).await?; }
                    211 => {
                        let echoed = u64::from_be_bytes(buffer[8..16].try_into().unwrap());
                        if pending != Some(echoed) { continue; }
                        pending = None;
                        let t2 = u64::from_be_bytes(buffer[16..24].try_into().unwrap());
                        let t3 = u64::from_be_bytes(buffer[24..32].try_into().unwrap());
                        clock.lock().unwrap().observe(echoed, now, t2, t3);
                    }
                    _ => {}
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn phone_duck_is_bounded_and_unduck_restores_unity() {
        let mut params = plist::Dictionary::new();
        params.insert("volume".into(), Value::Real(-20.0));
        params.insert("durationMs".into(), Value::Integer(9000.into()));
        let mut command = plist::Dictionary::new();
        command.insert("params".into(), Value::Dictionary(params));
        let duck = phone_duck(&command, false);
        assert!((duck.gain - 0.1).abs() < 0.000001);
        assert_eq!(duck.ramp_ms, 2000);
        assert_eq!(phone_duck(&command, true).gain, 1.0);
        assert_eq!(phone_duck(&plist::Dictionary::new(), false).gain, 1.0);
    }

    use super::*;
    fn display() -> Display {
        Display {
            width: 1280,
            height: 720,
            width_mm: 200,
            height_mm: 112,
            fps: 30,
            right_hand_drive: false,
        }
    }
    #[cfg(feature = "linux-audio")]
    #[test]
    fn feedback_before_audio_setup_is_an_empty_acknowledgement() {
        assert!(audio_feedback(Vec::new()).unwrap().is_empty());
        let body = audio_feedback(vec![dict([
            ("type", number(100)),
            ("sampleRate", number(48000)),
        ])])
        .unwrap();
        let fields = parse(&body).unwrap();
        assert_eq!(fields["streams"].as_array().unwrap().len(), 1);
    }

    #[cfg(feature = "linux-audio")]
    #[test]
    fn audio_teardown_accepts_type_without_connection_and_rejects_empty_selector() {
        let by_type = dict([("type", number(102))]);
        assert_eq!(
            teardown_selector(by_type.as_dictionary().unwrap()).unwrap(),
            (Some(102), None)
        );
        let both = dict([
            ("type", number(100)),
            ("streamConnectionID", Value::Integer((-1i64).into())),
        ]);
        assert_eq!(
            teardown_selector(both.as_dictionary().unwrap()).unwrap(),
            (Some(100), Some(u64::MAX))
        );
        assert_eq!(teardown_selector(&Dictionary::new()), Err(Error::Malformed));
        let bad = dict([("type", string("102"))]);
        assert_eq!(
            teardown_selector(bad.as_dictionary().unwrap()),
            Err(Error::Malformed)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn audio_clock_uses_phone_domain_and_advances_monotonically() {
        let mut clock = SessionClock::new();
        clock.base = 1000u64 << 32;
        let sent = clock.now();
        tokio::time::advance(Duration::from_millis(20)).await;
        let received = clock.now();
        let remote = (50u64 << 32) + (1u64 << 32) / 100;
        assert!(clock.observe(sent, received, remote, remote));
        assert!(clock.synchronized);
        let corrected = clock.now();
        assert!(corrected.abs_diff((50u64 << 32) + (1u64 << 32) / 50) <= 2);
        let adjustment = clock.adjustment;
        assert!(!clock.observe(sent, received, remote + 1, remote));
        assert_eq!(clock.adjustment, adjustment);
        tokio::time::advance(Duration::from_secs(2)).await;
        assert_eq!(clock.now().wrapping_sub(corrected), 2u64 << 32);
    }

    #[test]
    fn siri_button_edges_use_dedicated_button_actions() {
        for (pressed, expected) in [(true, 2), (false, 3)] {
            let fields = parse(&binary(&siri_button(pressed)).unwrap()).unwrap();
            assert_eq!(fields["type"].as_string(), Some("requestSiri"));
            assert_eq!(
                uint(fields["params"].as_dictionary().unwrap(), "siriAction").unwrap(),
                expected
            );
        }
    }

    #[test]
    fn output_capabilities_advertise_only_implemented_formats() {
        let identity = Identity::generate("fixture".into()).unwrap();
        let disabled = info(&display(), &identity, false, false);
        assert!(
            !disabled
                .as_dictionary()
                .unwrap()
                .contains_key("audioFormats")
        );
        let enabled = info(&display(), &identity, true, false);
        let fields = enabled.as_dictionary().unwrap();
        let formats = fields["audioFormats"].as_array().unwrap();
        assert_eq!(formats.len(), 9);
        for format in formats {
            let format = format.as_dictionary().unwrap();
            assert!(!format.contains_key("audioInputFormats"));
            let mask = uint(format, "audioOutputFormats").unwrap();
            for bit in 0..64 {
                let value = 1u64 << bit;
                if mask & value != 0 {
                    let selected = super::super::airplay::AudioFormat::selected(value).unwrap();
                    assert_ne!(selected.codec, super::super::airplay::AudioCodec::Opus);
                }
            }
        }
        let latencies = fields["audioLatencies"].as_array().unwrap();
        assert!(latencies.iter().any(|value| {
            let value = value.as_dictionary().unwrap();
            uint(value, "type").unwrap() == 102
                && value.get("audioType").and_then(Value::as_string) == Some("default")
        }));
    }

    #[test]
    fn capture_capability_is_limited_to_explicit_pcm_voice_support() {
        let identity = Identity::generate("fixture".into()).unwrap();
        let enabled = info(&display(), &identity, true, true);
        let formats = enabled.as_dictionary().unwrap()["audioFormats"]
            .as_array()
            .unwrap();
        let mut inputs = 0;
        for value in formats {
            let format = value.as_dictionary().unwrap();
            if format.contains_key("audioInputFormats") {
                inputs += 1;
                assert_eq!(uint(format, "type").unwrap(), 100);
                let selected = super::super::airplay::AudioFormat::selected(
                    uint(format, "audioInputFormats").unwrap(),
                )
                .unwrap();
                assert_eq!(
                    selected.codec,
                    super::super::airplay::AudioCodec::SignedPcm16
                );
                assert_eq!((selected.sample_rate, selected.channels), (16000, 1));
            }
        }
        assert_eq!(inputs, 4);
    }

    #[tokio::test]
    async fn setup_before_pairing_is_rejected_without_mfi_or_media() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut phone = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        let (video, view) = watch::channel(None);
        let (_commands, commands_rx) = mpsc::channel(2);
        let receiver = Receiver {
            information: watch::channel(SessionInfo::default()).0,
            pairing_directory: None,
            audio: None,
            display: display(),
            identity: Arc::new(Identity::generate("fixture".into()).unwrap()),
            peers: Arc::new(Mutex::new(Peers::default())),
            link: LinkClient::new(crate::link::LinkConfig::default()).unwrap(),
        };
        let task = tokio::spawn(async move { receiver.run(socket, 1, video, commands_rx).await });
        phone
            .write_all(b"SETUP /session RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();
        assert_eq!(task.await.unwrap(), Err(Error::Unsupported));
        assert!(view.borrow().is_none());
        assert_eq!(phone.read(&mut [0; 1]).await.unwrap(), 0);
    }
    #[tokio::test]
    async fn interleaved_touch_does_not_cancel_partial_event_ciphertext() {
        timeout(Duration::from_secs(2), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let secret = vec![7; 32];
            let peer = "127.0.0.1:9".parse().unwrap();
            let (commands, commands_rx) = mpsc::channel(4);
            let task = tokio::spawn(event_channel(listener, peer, secret.clone(), commands_rx));
            let mut phone = TcpStream::connect(address).await.unwrap();
            let mut sender = ControlCipher::new(
                pairing::derive_key(&secret, "Events-Salt", "Events-Read-Encryption-Key").unwrap(),
            );
            let mut receiver = ControlCipher::new(
                pairing::derive_key(&secret, "Events-Salt", "Events-Write-Encryption-Key").unwrap(),
            );
            let request = sender
                .encrypt(b"POST /command RTSP/1.0\r\nCSeq: 3\r\n\r\n")
                .unwrap();
            phone.write_all(&request[..4]).await.unwrap();
            commands
                .send(Command::Touch {
                    slot: 1,
                    down: true,
                    x: 300,
                    y: 400,
                })
                .await
                .unwrap();
            let mut header = [0; 2];
            phone.read_exact(&mut header).await.unwrap();
            let mut frame = vec![0; u16::from_le_bytes(header) as usize + 18];
            frame[..2].copy_from_slice(&header);
            phone.read_exact(&mut frame[2..]).await.unwrap();
            let plain = receiver.decrypt(&frame).unwrap();
            assert!(plain.starts_with(b"POST /command"));
            phone.write_all(&request[4..]).await.unwrap();
            phone.read_exact(&mut header).await.unwrap();
            let mut frame = vec![0; u16::from_le_bytes(header) as usize + 18];
            frame[..2].copy_from_slice(&header);
            phone.read_exact(&mut frame[2..]).await.unwrap();
            assert!(
                receiver
                    .decrypt(&frame)
                    .unwrap()
                    .starts_with(b"RTSP/1.0 200 OK")
            );
            let response = sender
                .encrypt(b"RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
                .unwrap();
            phone.write_all(&response).await.unwrap();
            commands.send(Command::ReleaseTouches).await.unwrap();
            phone.read_exact(&mut header).await.unwrap();
            let mut frame = vec![0; u16::from_le_bytes(header) as usize + 18];
            frame[..2].copy_from_slice(&header);
            phone.read_exact(&mut frame[2..]).await.unwrap();
            assert!(
                receiver
                    .decrypt(&frame)
                    .unwrap()
                    .starts_with(b"POST /command")
            );
            task.abort();
            let _ = task.await;
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn screen_requires_authenticated_payload_before_native_publication() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (video, mut video_rx) = watch::channel(None);
        let (events, _) = mpsc::channel(2);
        let task = tokio::spawn(screen(
            listener,
            "127.0.0.1:1".parse().unwrap(),
            [8; 32],
            display(),
            5,
            video,
            events,
        ));
        let mut phone = TcpStream::connect(address).await.unwrap();
        let config = [1, 66, 0, 30, 255, 225, 0, 2, 0x67, 1, 1, 0, 2, 0x68, 1];
        let mut header = [0u8; 128];
        header[..4].copy_from_slice(&(config.len() as u32).to_le_bytes());
        header[4] = 1;
        phone.write_all(&header).await.unwrap();
        phone.write_all(&config).await.unwrap();
        let stream = video_rx
            .wait_for(|v| v.is_some())
            .await
            .unwrap()
            .as_ref()
            .unwrap()
            .stream
            .clone();
        let (host, mut viewer) = tokio::net::UnixStream::pair().unwrap();
        let media = tokio::spawn(async move { stream.send_to(host).await });
        let mut prefix = vec![0; 24 + 24 + 24 + config.len()];
        viewer.read_exact(&mut prefix).await.unwrap();
        header[4] = 0;
        header[..4].copy_from_slice(&22u32.to_le_bytes());
        let mut bad = pairing::seal(&[8; 32], &[0; 12], &header, &[0, 0, 0, 2, 0x65, 1]).unwrap();
        *bad.last_mut().unwrap() ^= 1;
        phone.write_all(&header).await.unwrap();
        phone.write_all(&bad).await.unwrap();
        assert_eq!(task.await.unwrap(), Err(Error::Rejected));
        assert!(
            timeout(Duration::from_millis(20), viewer.read(&mut [0; 1]))
                .await
                .is_err()
        );
        media.abort();
        let _ = media.await;
    }
}
