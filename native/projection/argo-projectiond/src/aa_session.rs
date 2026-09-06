//! One post-version session owns TLS, channels, native audio and video feed.
use crate::{
    aa_channels::{Channels, Effect, Proto, Reply},
    aa_tls::AaTls,
    aa_wire::{self, Messages, PacketDecoder},
    daemon_state::{ProjectionRuntimeSnapshot, ProjectionSessionStatus},
    host_control::{Command, HostControl},
    native_playback::{AudioPlayback, SessionMedia, VideoFeed},
    session::AndroidAutoTransport,
};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, watch};

async fn write(transport: &mut impl AndroidAutoTransport, bytes: &[u8]) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(5), transport.write_all(bytes))
        .await
        .map_err(|_| "AA write timeout")?
        .map_err(|e| e.to_string())
}
async fn send(
    transport: &mut impl AndroidAutoTransport,
    tls: &mut AaTls,
    reply: Reply,
) -> Result<(), String> {
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
fn ping_payload() -> Vec<u8> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64;

    Proto::default().number(1, timestamp).finish()
}
async fn send_plain(
    transport: &mut impl AndroidAutoTransport,
    channel: u8,
    id: u16,
    body: &[u8],
) -> Result<(), String> {
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
) -> Result<(), String> {
    let config = control.configuration.borrow().clone();
    config.display.validate()?;
    let identity=config.identity.as_ref().ok_or("AA TLS identity missing: set ARGO_ANDROID_AUTO_CERT_FILE and ARGO_ANDROID_AUTO_KEY_FILE on argo-projectiond")?;
    let mut tls = AaTls::new(identity)?;
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
                .map_err(|_| "AA TLS handshake timeout")?
                .map_err(|e| e.to_string())?;
            if count == 0 {
                return Err("phone disconnected during AA TLS".into());
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
    let socket = config
        .media_socket
        .clone()
        .ok_or("ARGO_PROJECTION_MEDIA_SOCKET must name the native video feed socket")?;
    media.video = Some(VideoFeed::open(socket)?);
    let mut channels = Channels::new(config.display.clone());
    let mut commands = control.commands.subscribe();
    let clock = Instant::now();
    let setup_deadline = tokio::time::Instant::now() + Duration::from_secs(45);

    let mut streaming = false;
    let mut ping_enabled = false;

    let mut ping_interval = tokio::time::interval(Duration::from_millis(1500));
    ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Consume interval's immediate first tick. We explicitly send the
    // first AA ping after ServiceDiscoveryResponse instead.
    ping_interval.tick().await;
    loop {
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
                    ));
                }

                if message_id == 0x000b {
                    send_plain(transport, 0, 0x000c, &body[2..]).await?;
                }

                continue;
            }

            for effect in channels.handle(packet.channel, message_id, &body[2..])? {
                match effect {
                    Effect::Reply(reply) => send(transport, &mut tls, reply).await?,
                    Effect::End => return Ok(()),
                    Effect::Media(3, bytes) => media
                        .video
                        .as_ref()
                        .ok_or("video feed closed")?
                        .push(bytes)?,
                    Effect::Media(channel, bytes) => media
                        .audio
                        .get(&channel)
                        .ok_or("AA audio without playback")?
                        .push(bytes)?,
                    Effect::Audio(channel, active) => {
                        if active {
                            media.audio.insert(channel, AudioPlayback::open(channel)?);
                        } else {
                            media.audio.remove(&channel);
                        }
                        state.send_modify(|snapshot| {
                            if snapshot.session.as_ref().is_some_and(|s| s.id == id) {
                                snapshot.audio[(channel - 4) as usize] = active;
                            }
                        });
                    }
                    Effect::Video(visible) => {
                        streaming = true;
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

                let payload = ping_payload();
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
            read=transport.read(&mut input)=>{
                let count=read.map_err(|e|e.to_string())?;
                if count==0 {decoder.disconnect()?;return Err("Android phone transport disconnected".into());}
                decoder.push(&input[..count])?;
            },
            command=commands.recv()=>{
                let command=match command {Ok(c)=>c,Err(broadcast::error::RecvError::Lagged(_))=>return Err("projection control queue overflow".into()),Err(_)=>return Ok(())};
                let reply=match command {
                    Command::Disconnect(target) if target==id=>{send(transport,&mut tls,Reply::new(0,15,Proto::default().number(1,1).finish())).await?;return Ok(());},
                    Command::Touch(target,pointer,phase,x,y) if target==id=>channels.touch(pointer,phase,x,y,clock.elapsed().as_micros() as u64)?,
                    Command::Activate(target) if target==id=>{set_visibility(&state,&id,true);Some(Reply::new(3,0x8008,Proto::default().number(1,1).number(2,1).finish()))},
                    Command::Visibility(target,visible) if target==format!("{id}:main")=>{set_visibility(&state,&id,visible);Some(Reply::new(3,0x8008,Proto::default().number(1,if visible{1}else{2}).number(2,1).finish()))},
                    Command::Gain(target,stream,gain) if target==id=>{let channel=match stream.as_str(){"media"=>4,"speech"=>5,"system"=>6,_=>return Err("unknown native audio stream".into())};if let Some(playback)=media.audio.get(&channel){playback.gain(gain as f64)?;}None},
                    _=>None,
                };
                if let Some(reply)=reply {send(transport,&mut tls,reply).await?;}
            },
            _ = ping_interval.tick(), if ping_enabled => {
                let payload = ping_payload();

                send_plain(
                    transport,
                    0,
                    0x000b,
                    &payload,
                )
                .await?;

                crate::daemon_log!(Trace, "aa-session", "AA PingRequest sent");
            },
            _=tokio::time::sleep_until(setup_deadline),if !streaming=>return Err("AA video setup timeout after TLS".into()),
        }
    }
}

fn set_visibility(state: &watch::Sender<ProjectionRuntimeSnapshot>, id: &str, visible: bool) {
    state.send_modify(|snapshot| {
        if let Some(session) = snapshot.session.as_mut()
            && session.id == id
            && let Some((_, focus)) = snapshot.video.as_mut()
        {
            *focus = visible;
            session.state = if visible {
                ProjectionSessionStatus::Streaming
            } else {
                ProjectionSessionStatus::Suspended
            };
        }
    });
}
