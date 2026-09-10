//! One post-version session owns TLS, channels, native audio and video feed.
use crate::failure::{Failure, Kind};
use crate::{
    aa_channels::{Channels, Effect, Proto, Reply},
    aa_tls::AaTls,
    aa_wire::{self, Messages, PacketDecoder},
    daemon_state::{ProjectionRuntimeSnapshot, ProjectionSessionStatus},
    host_control::{Command, HostControl},
    native_playback::{AudioPlayback, SessionMedia, VideoFeed},
    session::AndroidAutoTransport,
};
use futures_util::FutureExt;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, watch};

async fn write(transport: &mut impl AndroidAutoTransport, bytes: &[u8]) -> Result<(), Failure> {
    tokio::time::timeout(Duration::from_secs(5), transport.write_all(bytes))
        .await
        .map_err(|_| {
            Failure::from(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "AA write timeout",
            ))
        })?
        .map_err(Failure::from)
}
async fn send(
    transport: &mut impl AndroidAutoTransport,
    tls: &mut AaTls,
    reply: Reply,
) -> Result<(), Failure> {
    let channel = reply.channel;
    let id = reply.id;
    let control = reply.control;

    let mut plain = id.to_be_bytes().to_vec();
    plain.extend(reply.body);

    let records = tls.encrypt(&plain)?;
    let wire = aa_wire::encrypted_frames(channel, control, &records)?;

    crate::daemon_log!(
        Trace,
        "aa-session",
        "AA TX begin: ch={} id=0x{:04x} encrypted=true control={} wire_bytes={}",
        channel,
        id,
        control,
        wire.len()
    );

    write(transport, &wire).await?;

    crate::daemon_log!(
        Trace,
        "aa-session",
        "AA TX complete: ch={} id=0x{:04x}",
        channel,
        id
    );

    Ok(())
}
async fn send_plain(
    transport: &mut impl AndroidAutoTransport,
    channel: u8,
    id: u16,
    body: &[u8],
) -> Result<(), Failure> {
    let mut payload = id.to_be_bytes().to_vec();
    payload.extend_from_slice(body);

    let wire = aa_wire::frame(channel, 0x03, &payload)?;

    crate::daemon_log!(
        Trace,
        "aa-session",
        "AA TX begin: ch={} id=0x{:04x} encrypted=false wire_bytes={}",
        channel,
        id,
        wire.len()
    );

    write(transport, &wire).await?;

    crate::daemon_log!(
        Trace,
        "aa-session",
        "AA TX complete: ch={} id=0x{:04x}",
        channel,
        id
    );

    Ok(())
}
pub async fn run(
    transport: &mut impl AndroidAutoTransport,
    control: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
    id: String,
    media: &mut SessionMedia,
    readiness: Option<&crate::readiness::Readiness>,
) -> Result<(), Failure> {
    run_with_tls_policy(
        transport,
        control,
        state,
        id,
        media,
        readiness,
        AaTls::wireless,
    )
    .await
}
// The test fixture supplies the same wireless verifier without changing process
// environment. Production always supplies the development-gated constructor.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_with_tls_policy(
    transport: &mut impl AndroidAutoTransport,
    control: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
    id: String,
    media: &mut SessionMedia,
    readiness: Option<&crate::readiness::Readiness>,
    wireless_tls: fn(&crate::identity::AndroidAutoIdentity) -> Result<AaTls, String>,
) -> Result<(), Failure> {
    let wireless = transport.wireless();
    let mut liveness = crate::liveness::Liveness::default();
    let watchdog = liveness.watchdog();
    tokio::select! { biased;
        error = watchdog, if wireless => Err(error),
        result = run_engine(transport, control, state, id, media, readiness, &mut liveness, wireless_tls) => result,
    }
}
#[allow(clippy::too_many_arguments)]
async fn run_engine(
    transport: &mut impl AndroidAutoTransport,
    control: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
    id: String,
    media: &mut SessionMedia,
    readiness: Option<&crate::readiness::Readiness>,
    liveness: &mut crate::liveness::Liveness,
    wireless_tls: fn(&crate::identity::AndroidAutoIdentity) -> Result<AaTls, String>,
) -> Result<(), Failure> {
    let selection = control.begin_session(&id);
    let config = &selection.config;
    config.display.validate().map_err(Failure::configuration)?;
    let identity=config.identity.as_ref().ok_or_else(|| Failure::configuration("AA TLS identity missing: set ARGO_ANDROID_AUTO_CERT_FILE and ARGO_ANDROID_AUTO_KEY_FILE on argo-projectiond"))?;
    let mut tls = if transport.wireless() {
        wireless_tls(identity).map_err(Failure::configuration)?
    } else {
        AaTls::new(identity).map_err(Failure::configuration)?
    };
    let mut decoder = PacketDecoder::default();
    let mut messages = Messages::default();
    let mut input = [0; 16384];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    crate::daemon_log!(
        Info,
        "aa-session",
        "AA TLS 1.2 starting with configured Argo identity"
    );
    loop {
        let pending = tls.pending()?;
        if !pending.is_empty() {
            let mut payload = 3u16.to_be_bytes().to_vec();
            payload.extend(pending);
            write(transport, &aa_wire::frame(0, 3, &payload)?).await?;
        }
        if !tls.handshaking() {
            break;
        }
        if let Some(packet) = decoder.packet()? {
            if packet.channel != 0 || packet.flags & 8 != 0 {
                return Err("unexpected encrypted/channel frame during AA TLS".into());
            }
            if let Some(body) = messages.accept(packet.channel, packet.flags, packet.bytes)? {
                if !body.starts_with(&[0, 3]) {
                    return Err("expected AA SSL_HANDSHAKE".into());
                }
                if !tls.receive(&body[2..])?.is_empty() {
                    return Err("AA application data before authentication complete".into());
                }
            }
        } else {
            let count = tokio::time::timeout_at(deadline, transport.read(&mut input))
                .await
                .map_err(|_| Failure::timeout("AA TLS handshake timeout"))?
                .map_err(Failure::from)?;
            if count == 0 {
                return Err(Failure::new(
                    Kind::TransportLoss,
                    "phone disconnected during AA TLS",
                ));
            }
            decoder.push(&input[..count])?;
        }
    }
    crate::daemon_log!(Info, "aa-session", "AA TLS 1.2 established");
    let mut auth = 4u16.to_be_bytes().to_vec();
    auth.extend(Proto::default().number(1, 0).finish());
    write(transport, &aa_wire::frame(0, 3, &auth)?).await?;
    crate::daemon_log!(
        Info,
        "aa-session",
        "AA authentication complete; awaiting service discovery"
    );
    let socket = config.media_socket.clone().ok_or_else(|| {
        Failure::configuration(
            "ARGO_PROJECTION_MEDIA_SOCKET must name the native video feed socket",
        )
    })?;
    media.video = Some(VideoFeed::open(socket).map_err(Failure::configuration)?);
    let mut channels = Channels::new(config.display.clone());
    let mut commands = control.commands.subscribe();
    let mut entertainment = control.entertainment.subscribe();
    let mut media_gain = 1.0_f64;
    control
        .entertainment_ack
        .send_replace(entertainment.borrow().0);
    let clock = Instant::now();
    let setup_deadline = tokio::time::Instant::now() + Duration::from_secs(45);

    let mut microphone = crate::voice::Credits::default();
    let mut microphone_frame = None;
    let mut awaiting_video = false;
    let mut streaming = false;
    // Scalar checkpoints only, bounded for the entire session. Do not retain
    // bodies, identities, media, or credentials for disconnect diagnostics.
    let mut discovery_sent = false;
    let mut established = false;
    let mut last_rx = None;
    let mut last_reply = None;
    let mut ping_enabled = false;

    let mut next_ping = tokio::time::Instant::now() + Duration::from_millis(1500);
    loop {
        // Buffered packets must yield to the outer watchdog/cancellation and pings.
        tokio::task::yield_now().await;
        if ping_enabled && tokio::time::Instant::now() >= next_ping {
            let payload = liveness.request();
            send_plain(transport, 0, 0x000b, &payload).await?;
            next_ping = tokio::time::Instant::now() + Duration::from_millis(1500);
        }
        // A continuously buffered video stream must not starve microphone capture.
        if microphone_frame.is_none()
            && let Some(capture) = media.microphone.as_mut()
        {
            microphone_frame = capture.frame().now_or_never();
        }
        if let Some(frame) = microphone_frame.take() {
            let frame = if microphone.expired() {
                Err("Microphone acknowledgements stalled for five seconds".into())
            } else {
                frame
            };
            match frame {
                Ok(bytes) if microphone.ready() => {
                    send(transport, &mut tls, Reply::new(9, 1, bytes)).await?;
                    microphone.sent();
                }
                Ok(_) => {} // Bounded live capture: discard while phone has no credit.
                Err(error) => {
                    microphone.stop();
                    if let Some(capture) = media.microphone.as_mut() {
                        capture.close().await.map_err(Failure::configuration)?;
                    }
                    media.microphone = None;
                    control
                        .voice
                        .state
                        .send_modify(|s| s.detail = error.clone());
                    crate::daemon_log!(Warn, "microphone", "{error}");
                    send(transport, &mut tls, Reply::new(9, 0x8002, vec![])).await?;
                }
            }
        }
        if let Some(packet) = decoder.packet()? {
            let encrypted = packet.flags & 8 != 0;

            let decoded = if encrypted {
                crate::daemon_log!(
                    Trace,
                    "aa-session",
                    "AA encrypted RX frame: ch={} flags=0x{:02x} cipher_bytes={}",
                    packet.channel,
                    packet.flags,
                    packet.bytes.len()
                );

                tls.receive(&packet.bytes)?
            } else {
                crate::daemon_log!(
                    Trace,
                    "aa-session",
                    "AA plaintext RX frame: ch={} flags=0x{:02x} bytes={}",
                    packet.channel,
                    packet.flags,
                    packet.bytes.len()
                );

                packet.bytes
            };

            let Some(body) = messages.accept(packet.channel, packet.flags, decoded)? else {
                continue;
            };

            if body.len() < 2 {
                return Err("short AA message".into());
            }

            let message_id = u16::from_be_bytes([body[0], body[1]]);
            let service_discovery = packet.channel == 0 && message_id == 0x0005;

            crate::daemon_log!(
                Trace,
                "aa-session",
                "AA RX: ch={} id=0x{:04x} bytes={} encrypted={}",
                packet.channel,
                message_id,
                body.len().saturating_sub(2),
                encrypted
            );

            if !encrypted {
                if packet.channel != 0 || !matches!(message_id, 0x000b | 0x000c) {
                    return Err(format!(
                        "unexpected plaintext AA message after authentication: \
                        ch={} id=0x{:04x}",
                        packet.channel, message_id
                    )
                    .into());
                }

                if message_id == 0x000c {
                    liveness.response(&body[2..]);
                }
                if message_id == 0x000b {
                    // Echo compatibility is retained, but unsolicited plaintext
                    // requests are not authenticated liveness evidence.
                    send_plain(transport, 0, 0x000c, &body[2..]).await?;
                }

                continue;
            }

            if packet.channel == 0 && message_id == 0x000c {
                liveness.response(&body[2..]);
                continue;
            }
            if packet.channel == 0
                && message_id == 0x000b
                && !crate::aa_channels::numbers(&body[2..])
                    .is_ok_and(|fields| fields.contains_key(&1))
            {
                continue;
            }
            let effects = channels.handle(packet.channel, message_id, &body[2..])?;
            last_rx = Some((packet.channel, message_id));
            // Unknown/ignored and rejected optional messages have no validated
            // effect. Neither they nor incomplete TLS/AA frames renew the timer.
            if effects
                .iter()
                .any(|e| !matches!(e, Effect::MicrophoneAck(_, _)))
            {
                liveness.valid();
            }
            for effect in effects {
                match effect {
                    Effect::Microphone(open, limit) => {
                        microphone_frame = None;
                        microphone.stop();
                        if let Some(mut capture) = media.microphone.take() {
                            capture.close().await.map_err(Failure::configuration)?;
                        }
                        let mut status = 0;
                        if open {
                            match crate::voice::Capture::open(&control.voice).await {
                                Ok(capture) => {
                                    media.microphone = Some(capture);
                                    match media.microphone.as_mut().unwrap().frame().await {
                                        Ok(frame) => {
                                            microphone_frame = Some(Ok(frame));
                                            microphone.start(limit);
                                        }
                                        Err(error) => {
                                            status = 1;
                                            control.voice.state.send_modify(|s| s.detail = error);
                                            media
                                                .microphone
                                                .as_mut()
                                                .unwrap()
                                                .close()
                                                .await
                                                .map_err(Failure::configuration)?;
                                            media.microphone = None;
                                        }
                                    }
                                }
                                Err(error) => {
                                    status = 1;
                                    control
                                        .voice
                                        .state
                                        .send_modify(|s| s.detail = error.clone());
                                    crate::daemon_log!(Warn, "microphone", "{error}");
                                }
                            }
                        }
                        send(
                            transport,
                            &mut tls,
                            Reply::new(
                                9,
                                0x8006,
                                Proto::default()
                                    .number(1, status)
                                    .number(2, microphone.session as u64)
                                    .finish(),
                            ),
                        )
                        .await?;
                        if open && status == 0 {
                            send(
                                transport,
                                &mut tls,
                                Reply::new(
                                    9,
                                    0x8001,
                                    Proto::default()
                                        .number(1, microphone.session as u64)
                                        .number(2, 0)
                                        .finish(),
                                ),
                            )
                            .await?;
                        }
                    }
                    Effect::MicrophoneStop => {
                        microphone.stop();
                        microphone_frame = None;
                        if let Some(capture) = media.microphone.as_mut() {
                            capture.close().await.map_err(Failure::configuration)?;
                        }
                        media.microphone = None;
                    }
                    Effect::MicrophoneAck(session, count) => {
                        if microphone.ack(session, count) {
                            liveness.valid();
                        }
                    }
                    Effect::Reply(reply) => {
                        let checkpoint = (reply.channel, reply.id);
                        send(transport, &mut tls, reply).await?;
                        last_reply = Some(checkpoint);
                        if checkpoint == (0, 6) {
                            discovery_sent = true;
                            crate::daemon_log!(
                                Debug,
                                "aa-session",
                                "AA discovery response sent: {}x{} {} FPS {} DPI; awaiting phone channel opens",
                                config.display.width,
                                config.display.height,
                                config.display.fps,
                                config.display.dpi
                            );
                        }
                    }
                    Effect::End => return Ok(()),
                    Effect::Metadata(update) => {
                        state.send_if_modified(|snapshot| snapshot.update_metadata(&id, update));
                    }
                    Effect::Media(3, bytes) => {
                        media
                            .video
                            .as_ref()
                            .ok_or("video feed closed")?
                            .push(bytes)?;
                        if awaiting_video {
                            awaiting_video = false;
                            set_visibility(&state, &id, true);
                        }
                    }
                    Effect::HostReturn => {
                        crate::daemon_log!(
                            Info,
                            "aa-focus",
                            "Phone Exit: returning presentation to Media; session retained"
                        );
                        awaiting_video = false;
                        state.send_modify(|snapshot| {
                            if snapshot.session.as_ref().is_some_and(|s| s.id == id) {
                                snapshot.host_return_revision =
                                    snapshot.host_return_revision.saturating_add(1);
                            }
                        });
                    }
                    Effect::Media(channel, bytes) => media
                        .audio
                        .get(&channel)
                        .ok_or("AA audio without playback")?
                        .push(bytes)?,
                    Effect::Audio(channel, active) => {
                        if active {
                            let playback =
                                AudioPlayback::open(channel).map_err(Failure::configuration)?;
                            if channel == 4 {
                                playback.gain(if entertainment.borrow().1 {
                                    media_gain
                                } else {
                                    0.0
                                })?;
                            }
                            media.audio.insert(channel, playback);
                        } else {
                            media.audio.remove(&channel);
                        }
                        state.send_modify(|snapshot| {
                            if snapshot.session.as_ref().is_some_and(|s| s.id == id) {
                                snapshot.audio[(channel - 4) as usize] = active;
                            }
                        });
                    }
                    Effect::Established => {
                        established = true;
                        liveness.establish();
                        if let Some(readiness) = readiness {
                            readiness.establish();
                        }
                    }
                    Effect::Video(visible) => {
                        streaming = true;
                        let visible = visible && !awaiting_video;

                        state.send_modify(|snapshot| {
                            if let Some(session) = snapshot.session.as_mut()
                                && session.id == id
                            {
                                session.state = if visible {
                                    ProjectionSessionStatus::Streaming
                                } else {
                                    ProjectionSessionStatus::Suspended
                                };
                                snapshot.video = Some((config.display.clone(), visible));
                            }
                        });
                    }
                }
            }
            if service_discovery {
                ping_enabled = true;

                let payload = liveness.request();
                send_plain(
                    transport, 0, 0x000b, // PING_REQUEST
                    &payload,
                )
                .await?;

                crate::daemon_log!(Trace, "aa-session", "AA PingRequest sent");
            }
            continue;
        }
        tokio::select! {
            frame = async {media.microphone.as_mut().expect("capture guarded").frame().await}, if media.microphone.is_some() => {microphone_frame=Some(frame);},
            _ = entertainment.changed() => {
                let (generation, audible) = *entertainment.borrow_and_update();
                if let Some(playback) = media.audio.get(&4) { playback.gain(if audible {media_gain} else {0.0})?; }
                control.entertainment_ack.send_replace(generation);
            },
            read=transport.read(&mut input)=>{
                let count=read.map_err(Failure::from)?;
                if count==0 {
                    let context = decoder.disconnect().err().unwrap_or_else(|| "Android phone transport disconnected".into());
                    let stage = if established { "established" } else { "startup" };
                    return Err(Failure::new(Kind::TransportLoss, format!("{context}; {stage}: discovery_sent={discovery_sent}, last_valid_rx={last_rx:?}, last_completed_reply={last_reply:?}, post_tls_ms={}", clock.elapsed().as_millis())));
                }
                decoder.push(&input[..count])?;
            },
            command=commands.recv()=>{
                let command=match command {Ok(c)=>c,Err(broadcast::error::RecvError::Lagged(_))=>return Err("projection control queue overflow".into()),Err(_)=>return Ok(())};
                let reply=match command {
                    Command::Disconnect(target) if target==id=>{send(transport,&mut tls,Reply::new(0,15,Proto::default().number(1,1).finish())).await?;return Ok(());},
                    Command::Touch(target,pointer,phase,x,y) if target==id=>channels.touch(pointer,phase,x,y,clock.elapsed().as_micros() as u64)?,
                    Command::Activate(target) if target==id=>{crate::daemon_log!(Debug,"aa-focus","host activation requested");channels.set_video_requested(true);awaiting_video=true;set_visibility(&state,&id,false);Some(Reply::new(3,0x8008,Proto::default().number(1,1).number(2,1).finish()))},
                    Command::Visibility(target,visible) if target==format!("{id}:main")=>{crate::daemon_log!(Debug,"aa-focus","host visibility requested: {visible}");channels.set_video_requested(visible);awaiting_video=visible;set_visibility(&state,&id,false);Some(Reply::new(3,0x8008,Proto::default().number(1,if visible{1}else{2}).number(2,1).finish()))},
                    Command::Gain(target,stream,gain) if target==id=>{let channel=match stream.as_str(){"media"=>4,"speech"=>5,"system"=>6,_=>return Err("unknown native audio stream".into())};if channel==4 {media_gain=gain as f64;}
                    if let Some(playback)=media.audio.get(&channel){playback.gain(if channel==4 && !entertainment.borrow().1 {0.0} else {gain as f64})?;}None},
                    _=>None,
                };
                if let Some(reply)=reply {send(transport,&mut tls,reply).await?;}
            },
            _ = tokio::time::sleep_until(next_ping), if ping_enabled => {},
            _=tokio::time::sleep_until(setup_deadline),if !streaming=>return Err(Failure::timeout("AA video setup timeout after TLS")),
        }
    }
}

fn set_visibility(state: &watch::Sender<ProjectionRuntimeSnapshot>, id: &str, visible: bool) {
    state.send_modify(|snapshot| {
        if let Some(session) = snapshot.session.as_mut()
            && session.id == id
            && let Some((_, focus)) = snapshot.video.as_mut()
        {
            snapshot.presentation_revision = snapshot.presentation_revision.saturating_add(1);
            *focus = visible;
            session.state = if visible {
                ProjectionSessionStatus::Streaming
            } else {
                ProjectionSessionStatus::Suspended
            };
        }
    });
}
