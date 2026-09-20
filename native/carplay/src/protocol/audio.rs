//! Native CarPlay RTP authentication and bounded GStreamer playback.
//! PCM is S16BE on the wire. Audio never crosses Flutter IPC.
use super::{
    Error,
    airplay::{AudioCodec, AudioFormat},
    pairing,
};
use gstreamer::{self as gst, prelude::*};
use gstreamer_app as app;
use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use tokio::{
    net::UdpSocket,
    sync::{mpsc, watch},
    task::JoinHandle,
    time::Instant,
};
type Result<T> = std::result::Result<T, Error>;
fn failure<T>(_: T) -> Error {
    Error::Rejected
}

pub fn available() -> Result<()> {
    gst::init().map_err(failure)?;
    for name in [
        "appsrc",
        "rtpjitterbuffer",
        "rtpmp4gdepay",
        "aacparse",
        "avdec_aac",
        "audioconvert",
        "audioresample",
        "volume",
        "clocksync",
        "queue",
        "pulsesink",
    ] {
        if gst::ElementFactory::find(name).is_none() {
            return Err(Error::Unsupported);
        }
    }
    Ok(())
}

/// Validate an explicitly selected capture source before advertising input.
pub fn capture_available(source: &str) -> Result<()> {
    if source.is_empty()
        || source.len() > 256
        || !source
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Err(Error::Bounds);
    }
    gst::init().map_err(failure)?;
    for name in ["pulsesrc", "appsink", "webrtcdsp", "webrtcechoprobe"] {
        if gst::ElementFactory::find(name).is_none() {
            return Err(Error::Unsupported);
        }
    }
    Ok(())
}

/// 64-packet nonce replay window permits UDP reordering without replaying audio.
#[derive(Default)]
struct Replay {
    highest: Option<u64>,
    bits: u64,
}
impl Replay {
    fn accept(&mut self, counter: u64) -> Result<()> {
        match self.highest {
            None => {
                self.highest = Some(counter);
                self.bits = 1;
            }
            Some(high) if counter > high => {
                self.bits = if counter - high >= 64 {
                    1
                } else {
                    (self.bits << (counter - high)) | 1
                };
                self.highest = Some(counter);
            }
            Some(high) => {
                let behind = high - counter;
                if behind >= 64 || self.bits & (1 << behind) != 0 {
                    return Err(Error::Sequence);
                }
                self.bits |= 1 << behind;
            }
        }
        Ok(())
    }
}
struct Decoder {
    key: [u8; 32],
    replay: Replay,
}
impl Decoder {
    fn packet(&mut self, bytes: &[u8]) -> Result<(Vec<u8>, u32)> {
        if !(36..=4096).contains(&bytes.len()) || bytes[0] != 0x80 {
            return Err(Error::Malformed);
        }
        let end = bytes.len() - 8;
        let mut nonce = [0; 12];
        nonce[4..].copy_from_slice(&bytes[end..]);
        let payload = pairing::open(&self.key, &nonce, &bytes[4..12], &bytes[12..end])?;
        // Authentication precedes replay-window mutation: forged counters cannot evict packets.
        self.replay
            .accept(u64::from_le_bytes(bytes[end..].try_into().unwrap()))?;
        let sample = u32::from_be_bytes(bytes[4..8].try_into().unwrap());
        Ok(([&bytes[..12], &payload].concat(), sample))
    }
}
struct Pipeline(gst::Pipeline);
impl Drop for Pipeline {
    fn drop(&mut self) {
        let _ = self.0.set_state(gst::State::Null);
    }
}
struct Playback {
    pipeline: Pipeline,
    source: app::AppSrc,
    volume: gst::Element,
    format: AudioFormat,
    first: Option<u32>,
    started: Option<gst::ClockTime>,
    payload_type: u8,
    scheduled: gst::ClockTime,
    echo_probe: Option<String>,
}
impl Playback {
    fn open(
        format: AudioFormat,
        payload_type: u8,
        latency: u32,
        sink: Option<&str>,
        duplex: bool,
    ) -> Result<Self> {
        Self::open_with_output(
            format,
            payload_type,
            latency,
            sink,
            "pulsesink name=output sync=false",
            duplex,
        )
    }
    fn open_with_output(
        format: AudioFormat,
        payload_type: u8,
        latency: u32,
        sink: Option<&str>,
        output: &'static str,
        duplex: bool,
    ) -> Result<Self> {
        gst::init().map_err(failure)?;
        let prefix = match format.codec {
            AudioCodec::SignedPcm16 => {
                "appsrc name=input is-live=true format=time block=false max-bytes=262144 ! "
                    .to_owned()
            }
            AudioCodec::AacLc => format!(
                "appsrc name=input is-live=true format=time do-timestamp=true block=false max-bytes=262144 ! rtpjitterbuffer latency={} drop-on-latency=true ! rtpmp4gdepay ! aacparse ! avdec_aac ! ",
                latency.max(50)
            ),
            AudioCodec::Opus => return Err(Error::Unsupported),
        };
        static NEXT_PROBE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let echo_probe = duplex.then(|| {
            format!(
                "argo_echo_{}",
                NEXT_PROBE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            )
        });
        let echo_chain = echo_probe.as_ref().map(|name| format!("audio/x-raw,format=S16LE,rate=48000,layout=interleaved ! webrtcechoprobe name={name} ! ")).unwrap_or_default();
        let pipeline=gst::parse::launch(&(prefix+"audioconvert ! audioresample ! volume name=gain volume=0 ! "+&echo_chain+"queue max-size-buffers=32 max-size-bytes=262144 max-size-time=2000000000 ! clocksync sync=true ! "+output))
            .map_err(failure)?.downcast::<gst::Pipeline>().map_err(failure)?;
        let pipeline = Pipeline(pipeline);
        if let Some(sink) = sink {
            pipeline
                .0
                .by_name("output")
                .ok_or(Error::State)?
                .set_property("device", sink);
        }
        let source = pipeline
            .0
            .by_name("input")
            .ok_or(Error::State)?
            .downcast::<app::AppSrc>()
            .map_err(failure)?;
        let caps = match format.codec {
            AudioCodec::SignedPcm16 => gst::Caps::builder("audio/x-raw")
                .field("format", "S16BE")
                .field("layout", "interleaved")
                .field("rate", format.sample_rate as i32)
                .field("channels", format.channels as i32)
                .build(),
            AudioCodec::AacLc => {
                let index = if format.sample_rate == 48000 { 3 } else { 4 };
                let config = (2u16 << 11) | (index << 7) | ((format.channels as u16) << 3);
                gst::Caps::builder("application/x-rtp")
                    .field("media", "audio")
                    .field("encoding-name", "MPEG4-GENERIC")
                    .field("clock-rate", format.sample_rate as i32)
                    .field("payload", payload_type as i32)
                    .field("mode", "AAC-hbr")
                    .field("config", format!("{config:04x}"))
                    .field("sizelength", "13")
                    .field("indexlength", "3")
                    .field("indexdeltalength", "3")
                    .build()
            }
            _ => return Err(Error::Unsupported),
        };
        source.set_caps(Some(&caps));
        let volume = pipeline.0.by_name("gain").ok_or(Error::State)?;
        // Match Argo's native AA playback: network-fed appsrc must have a
        // running clock independently of the sink consuming its first samples.
        pipeline.0.use_clock(Some(&gst::SystemClock::obtain()));
        pipeline.0.set_state(gst::State::Playing).map_err(failure)?;
        Ok(Self {
            pipeline,
            source,
            volume,
            format,
            first: None,
            started: None,
            payload_type,
            scheduled: gst::ClockTime::ZERO,
            echo_probe,
        })
    }
    fn gain(&self, gain: f64) -> Result<()> {
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return Err(Error::Bounds);
        }
        self.volume.set_property("volume", gain);
        Ok(())
    }
    fn push(&mut self, rtp: &[u8], sample: u32) -> Result<()> {
        if self.source.current_level_bytes() > 262144 {
            return Err(Error::Bounds);
        }
        let bytes = match self.format.codec {
            AudioCodec::SignedPcm16 => {
                let payload = &rtp[12..];
                if payload.is_empty()
                    || !payload
                        .len()
                        .is_multiple_of(self.format.channels as usize * 2)
                {
                    return Err(Error::Malformed);
                }
                payload.to_vec()
            }
            AudioCodec::AacLc => {
                let size = rtp.len() - 12;
                if size == 0 || size > 8191 {
                    return Err(Error::Bounds);
                }
                let length = ((size as u16) << 3).to_be_bytes();
                let mut framed = [&rtp[..12], &[0, 16, length[0], length[1]], &rtp[12..]].concat();
                framed[1] = 0x80 | self.payload_type;
                framed
            }
            _ => return Err(Error::Unsupported),
        };
        let mut buffer = gst::Buffer::from_mut_slice(bytes);
        if self.format.codec == AudioCodec::SignedPcm16 {
            let initial = *self.first.get_or_insert(sample);
            let start = *self.started.get_or_insert_with(|| {
                self.pipeline
                    .0
                    .current_running_time()
                    .unwrap_or(gst::ClockTime::ZERO)
            });
            let frames = sample.wrapping_sub(initial) as u64;
            let timestamp = start
                + gst::ClockTime::from_nseconds(
                    frames * 1_000_000_000 / self.format.sample_rate as u64,
                );
            let writable = buffer.get_mut().ok_or(Error::State)?;
            self.scheduled = timestamp;
            writable.set_pts(timestamp);
            writable.set_duration(gst::ClockTime::from_nseconds(
                (rtp.len() - 12) as u64 * 1_000_000_000
                    / (self.format.channels as u64 * 2 * self.format.sample_rate as u64),
            ));
        }
        self.source.push_buffer(buffer).map_err(failure)?;
        if let Some(bus) = self.pipeline.0.bus()
            && bus.pop_filtered(&[gst::MessageType::Error]).is_some()
        {
            return Err(Error::Rejected);
        }
        Ok(())
    }
}
/// Capture is opened only for a negotiated bidirectional PCM stream.
pub struct CaptureOptions {
    pub source: String,
    pub key: [u8; 32],
    pub peer: SocketAddr,
    pub frames_per_packet: u32,
}
struct Microphone {
    lease: Option<argo_audio_ownership::MicrophoneLease>,
    bin: gst::Bin,
    parent: gst::Pipeline,
    samples: mpsc::Receiver<Vec<u8>>,
    pending: Vec<u8>,
    packet_bytes: usize,
    frames: u32,
    key: [u8; 32],
    peer: SocketAddr,
    counter: u64,
    sequence: u16,
    timestamp: u32,
    running: bool,
}
impl Microphone {
    fn open(format: AudioFormat, options: CaptureOptions, playback: &Playback) -> Result<Self> {
        Self::open_with_source(
            format,
            options,
            playback,
            "pulsesrc name=capture buffer-time=40000 latency-time=10000",
            true,
        )
    }
    fn open_with_source(
        format: AudioFormat,
        options: CaptureOptions,
        playback: &Playback,
        source: &'static str,
        device: bool,
    ) -> Result<Self> {
        if format.codec != AudioCodec::SignedPcm16
            || format.channels != 1
            || options.peer.port() == 0
            || options.source.is_empty()
            || options.source.len() > 256
        {
            return Err(Error::Unsupported);
        }
        let frames = if options.frames_per_packet == 0 {
            format.sample_rate / 50
        } else {
            options.frames_per_packet
        };
        let packet_bytes = frames as usize * 2;
        if frames == 0 || packet_bytes > 4000 {
            return Err(Error::Bounds);
        }
        let probe = playback.echo_probe.as_ref().ok_or(Error::State)?;
        // WebRTC's reference and capture must share a top-level pipeline and rate.
        // Keep the capture bin locked in NULL until its explicit microphone lease.
        let bin = gst::parse::bin_from_description(&format!("{source} ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved ! webrtcdsp probe={probe} echo-cancel=true gain-control=false ! audioconvert ! audioresample ! audio/x-raw,format=S16BE,rate={},channels=1,layout=interleaved ! appsink name=packets sync=false async=false max-buffers=4 drop=true wait-on-eos=false", format.sample_rate), false).map_err(failure)?;
        bin.set_locked_state(true);
        if device {
            bin.by_name("capture")
                .ok_or(Error::State)?
                .set_property("device", &options.source);
        }
        let sink = bin
            .by_name("packets")
            .ok_or(Error::State)?
            .downcast::<app::AppSink>()
            .map_err(failure)?;
        let (send, samples) = mpsc::channel(4);
        sink.set_callbacks(
            app::AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
                    let bytes = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
                    if bytes.len() > 4096 || !bytes.len().is_multiple_of(2) {
                        return Err(gst::FlowError::Error);
                    }
                    let _ = send.try_send(bytes.to_vec());
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        playback.pipeline.0.add(&bin).map_err(failure)?;
        Ok(Self {
            bin,
            parent: playback.pipeline.0.clone(),
            samples,
            pending: Vec::new(),
            packet_bytes,
            lease: None,
            frames,
            key: options.key,
            peer: options.peer,
            counter: 0,
            sequence: 0,
            timestamp: 0,
            running: false,
        })
    }
    fn select_source(&mut self, source: &str) -> Result<()> {
        let capture = self.bin.by_name("capture").ok_or(Error::State)?;
        if capture.property::<Option<String>>("device").as_deref() == Some(source) {
            return Ok(());
        }
        self.active(false)?;
        capture.set_property("device", source);
        Ok(())
    }
    fn active(&mut self, active: bool) -> Result<()> {
        if active == self.running {
            return Ok(());
        }
        if active {
            self.lease = Some(argo_audio_ownership::MicrophoneLease::acquire().map_err(failure)?);
        }
        if active {
            self.bin
                .set_clock(self.parent.clock().as_ref())
                .map_err(failure)?;
            self.bin
                .set_base_time(self.parent.base_time().ok_or(Error::State)?);
            self.bin.set_start_time(gst::ClockTime::NONE);
        }
        self.bin
            .set_state(if active {
                gst::State::Playing
            } else {
                gst::State::Null
            })
            .map_err(failure)?;
        self.running = active;
        if !active {
            if self.bin.current_state() != gst::State::Null {
                return Err(Error::State);
            }
            self.lease.take();
            self.pending.clear();
            while self.samples.try_recv().is_ok() {}
        }
        Ok(())
    }
    async fn send(&mut self, bytes: &[u8], socket: &UdpSocket) -> Result<()> {
        if self.pending.len() + bytes.len() > 8192 {
            return Err(Error::Bounds);
        }
        self.pending.extend_from_slice(bytes);
        while self.pending.len() >= self.packet_bytes {
            let payload: Vec<_> = self.pending.drain(..self.packet_bytes).collect();
            let packet = seal_pcm(
                &self.key,
                self.counter,
                self.sequence,
                self.timestamp,
                &payload,
            )?;
            self.counter = self.counter.checked_add(1).ok_or(Error::Bounds)?;
            self.sequence = self.sequence.wrapping_add(1);
            self.timestamp = self.timestamp.wrapping_add(self.frames);
            socket.send_to(&packet, self.peer).await.map_err(failure)?;
        }
        Ok(())
    }
}
impl Drop for Microphone {
    fn drop(&mut self) {
        if (self.bin.set_state(gst::State::Null).is_err()
            || self.bin.current_state() != gst::State::Null)
            && let Some(lease) = self.lease.take()
        {
            lease.poison();
        }
        let _ = self.parent.remove(&self.bin);
    }
}
fn seal_pcm(
    key: &[u8; 32],
    counter: u64,
    sequence: u16,
    timestamp: u32,
    payload: &[u8],
) -> Result<Vec<u8>> {
    if payload.is_empty() || payload.len() > 4000 || !payload.len().is_multiple_of(2) {
        return Err(Error::Bounds);
    }
    let mut header = [0u8; 12];
    header[0] = 0x80;
    header[1] = 100;
    header[2..4].copy_from_slice(&sequence.to_be_bytes());
    header[4..8].copy_from_slice(&timestamp.to_be_bytes());
    let mut nonce = [0; 12];
    nonce[4..].copy_from_slice(&counter.to_le_bytes());
    let sealed = pairing::seal(key, &nonce, &header[4..12], payload)?;
    Ok([header.as_slice(), &sealed, &counter.to_le_bytes()].concat())
}

#[derive(Clone, Copy, Default, serde::Serialize)]
pub struct Metrics {
    pub packets: u64,
    pub microphone_packets: u64,
    pub microphone_active: bool,
    pub pcm_peak: u16,
    pub gain: f64,
    pub queued_bytes: u64,
    pub playback_lag_ms: i64,
}

#[derive(Clone, Copy)]
pub struct Anchor {
    pub sample: u32,
    pub started: Instant,
}
pub struct Stream {
    pub data_port: u16,
    pub control_port: u16,
    pub connection: u64,
    pub kind: u16,
    pub format: AudioFormat,
    pub category: String,
    pub latency_ms: u32,
    pub anchor: Arc<Mutex<Option<Anchor>>>,
    pub metrics: Arc<Mutex<Metrics>>,
    gain: watch::Sender<(f64, bool, Option<String>)>,
    task: JoinHandle<Result<()>>,
}
impl Stream {
    #[allow(clippy::too_many_arguments)]
    pub async fn start(
        local: SocketAddr,
        peer: SocketAddr,
        key: [u8; 32],
        connection: u64,
        kind: u16,
        format: AudioFormat,
        category: String,
        latency_ms: u32,
        sink: Option<&str>,
        capture: Option<CaptureOptions>,
    ) -> Result<Self> {
        if ![100, 101, 102].contains(&kind) || latency_ms > 2000 {
            return Err(Error::Bounds);
        }
        let mut playback = Playback::open(format, kind as u8, latency_ms, sink, capture.is_some())?;
        let mut microphone = capture
            .map(|options| Microphone::open(format, options, &playback))
            .transpose()?;
        let data = UdpSocket::bind(local).await.map_err(failure)?;
        let control = UdpSocket::bind(local).await.map_err(failure)?;
        let data_port = data.local_addr().map_err(failure)?.port();
        let control_port = control.local_addr().map_err(failure)?.port();
        let (gain, mut gain_rx) = watch::channel((0.0, false, None::<String>));
        let anchor = Arc::new(Mutex::new(None));
        let stored = anchor.clone();
        let metrics = Arc::new(Mutex::new(Metrics::default()));
        let measured = metrics.clone();
        let task = tokio::spawn(async move {
            let mut decoder = Decoder {
                key,
                replay: Replay::default(),
            };
            let mut bytes = [0; 4097];
            let mut control_bytes = [0; 512];
            loop {
                tokio::select! {
                    result=gain_rx.changed()=>{result.map_err(failure)?;let (gain, muted, source)=gain_rx.borrow_and_update().clone();if let (Some(mic),Some(source))=(&mut microphone,source) {mic.select_source(&source)?;}playback.gain(gain)?;measured.lock().unwrap().gain=gain;if let Some(mic)=&mut microphone {mic.active(gain>0.0 && !muted && stored.lock().unwrap().is_some())?;measured.lock().unwrap().microphone_active=mic.running;}},
                    bytes=async {match &mut microphone {Some(mic)=>mic.samples.recv().await,None=>std::future::pending().await}}=>{let bytes=bytes.ok_or(Error::State)?;if let Some(mic)=&mut microphone && mic.running && !gain_rx.borrow().1 {mic.send(&bytes,&data).await?;measured.lock().unwrap().microphone_packets=mic.counter;}},
                    result=control.recv_from(&mut control_bytes)=>{let _=result.map_err(failure)?;},
                    result=data.recv_from(&mut bytes)=>{
                        let (size,remote)=result.map_err(failure)?;if remote.ip()!=peer.ip() || size>4096 {continue;}
                        let Ok((rtp,sample))=decoder.packet(&bytes[..size]) else {continue;};
                        if stored.lock().unwrap().is_none(){*stored.lock().unwrap()=Some(Anchor{sample,started:Instant::now()});}
                        playback.push(&rtp,sample)?;
                        {
                            let mut metrics = measured.lock().unwrap();
                            metrics.packets = metrics.packets.saturating_add(1);
                            if format.codec == AudioCodec::SignedPcm16 {
                                metrics.pcm_peak = rtp[12..].as_chunks::<2>().0.iter().map(|v| i16::from_be_bytes(*v).unsigned_abs()).max().unwrap_or(0);
                            }
                            metrics.queued_bytes = playback.source.current_level_bytes();
                            metrics.playback_lag_ms = playback.pipeline.0.current_running_time().unwrap_or(gst::ClockTime::ZERO).mseconds() as i64 - playback.scheduled.mseconds() as i64;
                        }
                        if let Some(mic)=&mut microphone {let (gain, muted, _)=gain_rx.borrow().clone();mic.active(gain>0.0 && !muted)?;measured.lock().unwrap().microphone_active=mic.running;}
                    }
                }
            }
        });
        Ok(Self {
            data_port,
            control_port,
            connection,
            kind,
            format,
            category,
            latency_ms,
            anchor,
            metrics,
            gain,
            task,
        })
    }
    pub fn set_gain(&self, value: f64) -> Result<()> {
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err(Error::Bounds);
        }
        self.gain.send_modify(|state| state.0 = value);
        Ok(())
    }
    pub fn set_microphone_source(&self, source: String) {
        self.gain.send_modify(|policy| policy.2 = Some(source));
    }
    pub fn set_microphone_muted(&self, muted: bool) {
        self.gain.send_modify(|state| state.1 = muted);
    }
    pub async fn close(mut self) {
        let metrics = *self.metrics.lock().unwrap();
        eprintln!(
            "CarPlay audio closed: type={}, output_packets={}, microphone_packets={}",
            self.kind, metrics.packets, metrics.microphone_packets
        );
        self.task.abort();
        let _ = (&mut self.task).await;
    }
    pub fn healthy(&self) -> bool {
        !self.task.is_finished()
    }
}
impl Drop for Stream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packet(counter: u64) -> Vec<u8> {
        let mut header = [0u8; 12];
        header[0] = 0x80;
        header[1] = 100;
        header[4..8].copy_from_slice(&320u32.to_be_bytes());
        let mut nonce = [0u8; 12];
        nonce[4..].copy_from_slice(&counter.to_le_bytes());
        let body = pairing::seal(&[9; 32], &nonce, &header[4..], &[0, 1, 0, 2]).unwrap();
        [header.as_slice(), &body, &counter.to_le_bytes()].concat()
    }
    #[tokio::test]
    async fn duplex_echo_processor_uses_shared_pipeline_and_outputs_bounded_pcm() {
        let format = AudioFormat::selected(0x10).unwrap();
        let mut playback = Playback::open_with_output(
            format,
            100,
            20,
            None,
            "fakesink name=output sync=false async=false",
            true,
        )
        .unwrap();
        let mut microphone = Microphone::open_with_source(
            format,
            CaptureOptions {
                source: "synthetic".into(),
                key: [0; 32],
                peer: "127.0.0.1:1234".parse().unwrap(),
                frames_per_packet: 320,
            },
            &playback,
            "audiotestsrc name=capture is-live=true samplesperbuffer=480 wave=silence",
            false,
        )
        .unwrap();
        assert_eq!(microphone.bin.current_state(), gst::State::Null);
        let dsp = microphone
            .bin
            .iterate_elements()
            .into_iter()
            .filter_map(|e| e.ok())
            .find(|e| e.factory().is_some_and(|f| f.name() == "webrtcdsp"))
            .unwrap();
        assert!(dsp.property::<bool>("echo-cancel"));
        assert_eq!(
            dsp.property::<String>("probe"),
            playback.echo_probe.clone().unwrap()
        );
        // Synthetic source only: exercise the media branch without claiming any physical microphone.
        microphone
            .bin
            .set_clock(playback.pipeline.0.clock().as_ref())
            .unwrap();
        microphone
            .bin
            .set_base_time(playback.pipeline.0.base_time().unwrap());
        microphone.bin.set_start_time(gst::ClockTime::NONE);
        microphone.bin.set_state(gst::State::Playing).unwrap();
        let rtp = vec![0; 12 + 640];
        playback.push(&rtp, 0).unwrap();
        let pcm =
            tokio::time::timeout(std::time::Duration::from_secs(2), microphone.samples.recv())
                .await
                .unwrap()
                .unwrap();
        assert!(!pcm.is_empty() && pcm.len() <= 4096 && pcm.len().is_multiple_of(2));
        microphone.bin.set_state(gst::State::Null).unwrap();
        assert_eq!(microphone.bin.current_state(), gst::State::Null);
    }

    #[test]
    fn pcm_playback_delivers_nonzero_samples_and_applies_gain_without_a_sound_device() {
        let mut playback = Playback::open_with_output(
            AudioFormat::selected(0x800).unwrap(),
            100,
            20,
            None,
            "appsink name=output sync=false async=false max-buffers=4",
            false,
        )
        .unwrap();
        let output = playback
            .pipeline
            .0
            .by_name("output")
            .unwrap()
            .downcast::<app::AppSink>()
            .unwrap();
        let mut rtp = vec![0; 12];
        for _ in 0..441 {
            rtp.extend_from_slice(&[0x10, 0, 0x10, 0]);
        }
        playback.push(&rtp, 1000).unwrap();
        let muted = output
            .try_pull_sample(gst::ClockTime::from_seconds(2))
            .expect("muted PCM must reach the sink");
        assert!(
            muted
                .buffer()
                .unwrap()
                .map_readable()
                .unwrap()
                .iter()
                .all(|b| *b == 0)
        );
        playback.gain(1.0).unwrap();
        playback.push(&rtp, 1441).unwrap();
        let audible = output
            .try_pull_sample(gst::ClockTime::from_seconds(2))
            .expect("paced PCM must reach the sink");
        assert!(
            audible
                .buffer()
                .unwrap()
                .map_readable()
                .unwrap()
                .iter()
                .any(|b| *b != 0)
        );
        assert!(audible.buffer().unwrap().pts().unwrap() > muted.buffer().unwrap().pts().unwrap());
    }

    #[test]
    fn capture_packets_roundtrip_and_reject_tampering() {
        let key = [9; 32];
        let pcm = [0x12, 0x34, 0xfe, 0xdc];
        let packet = seal_pcm(&key, 7, 65535, u32::MAX, &pcm).unwrap();
        let mut decoder = Decoder {
            key,
            replay: Replay::default(),
        };
        let (plain, timestamp) = decoder.packet(&packet).unwrap();
        assert_eq!(timestamp, u32::MAX);
        assert_eq!(&plain[12..], &pcm);
        assert_eq!(&plain[2..4], &65535u16.to_be_bytes());
        for offset in [4, 12, packet.len() - 1] {
            let mut damaged = packet.clone();
            damaged[offset] ^= 1;
            let mut decoder = Decoder {
                key,
                replay: Replay::default(),
            };
            assert!(decoder.packet(&damaged).is_err());
        }
        for size in [0, 1, 4001, 4002] {
            assert!(seal_pcm(&key, 0, 0, 0, &vec![0; size]).is_err());
        }
    }

    #[test]
    fn audio_authentication_replay_and_reordering() {
        let mut decoder = Decoder {
            key: [9; 32],
            replay: Replay::default(),
        };
        assert_eq!(decoder.packet(&packet(3)).unwrap().1, 320);
        assert!(decoder.packet(&packet(2)).is_ok());
        assert!(decoder.packet(&packet(2)).is_err());
        let mut bad = packet(100);
        bad[14] ^= 1;
        assert!(decoder.packet(&bad).is_err());
        assert!(decoder.packet(&packet(4)).is_ok());
        assert!(decoder.packet(&packet(100)).is_ok());
        assert!(decoder.packet(&packet(1)).is_err());
    }
}
