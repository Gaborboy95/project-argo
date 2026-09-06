//! Minimal AA channel messages. Wire field numbers are interoperability facts;
//! no generated/vendor protocol implementation or credentials are included.
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default, Clone)]
pub struct Proto(Vec<u8>);
impl Proto {
    fn var(&mut self, mut value: u64) {
        while value >= 128 {
            self.0.push(value as u8 | 128);
            value >>= 7;
        }
        self.0.push(value as u8);
    }
    pub fn number(mut self, field: u32, value: u64) -> Self {
        self.var((field as u64) << 3);
        self.var(value);
        self
    }
    pub fn bytes(mut self, field: u32, value: &[u8]) -> Self {
        self.var(((field as u64) << 3) | 2);
        self.var(value.len() as u64);
        self.0.extend(value);
        self
    }
    pub fn nested(self, field: u32, value: Self) -> Self {
        self.bytes(field, &value.0)
    }
    pub fn finish(self) -> Vec<u8> {
        self.0
    }
}
pub fn numbers(bytes: &[u8]) -> Result<BTreeMap<u32, u64>, String> {
    fn var(bytes: &mut &[u8]) -> Result<u64, String> {
        let mut value = 0;
        for shift in (0..70).step_by(7) {
            let (&byte, rest) = bytes.split_first().ok_or("truncated protobuf varint")?;
            *bytes = rest;
            if shift == 63 && byte > 1 {
                return Err("protobuf integer overflow".into());
            }
            value |= ((byte & 127) as u64) << shift;
            if byte < 128 {
                return Ok(value);
            }
        }
        Err("protobuf integer overflow".into())
    }
    let mut input = bytes;
    let mut fields = BTreeMap::new();
    let mut count = 0;
    while !input.is_empty() {
        count += 1;
        if count > 1024 {
            return Err("protobuf field limit".into());
        }
        let tag = var(&mut input)?;
        let field = tag >> 3;
        if field == 0 || field > 0x1fff_ffff {
            return Err("invalid protobuf tag".into());
        }
        let size = match tag & 7 {
            0 => {
                fields.insert(field as u32, var(&mut input)?);
                continue;
            }
            1 => 8,
            5 => 4,
            2 => usize::try_from(var(&mut input)?).map_err(|_| "protobuf length overflow")?,
            _ => return Err("unsupported protobuf wire type".into()),
        };
        input = input.get(size..).ok_or("truncated protobuf field")?;
    }
    Ok(fields)
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DisplayConfig {
    pub width: u16,
    pub height: u16,
    pub dpi: u16,
    pub fps: u8,
    pub right_driver: bool,
}
impl Default for DisplayConfig {
    fn default() -> Self {
        Self {
            width: 1280,
            height: 720,
            dpi: 160,
            fps: 30,
            right_driver: false,
        }
    }
}
impl DisplayConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(
            (self.width, self.height),
            (800, 480) | (1280, 720) | (1920, 1080)
        ) || !matches!(self.fps, 30 | 60)
            || !(80..=640).contains(&self.dpi)
        {
            return Err(
                "AA display requires 800x480, 1280x720 or 1920x1080, 30/60 FPS and 80..640 DPI"
                    .into(),
            );
        }
        Ok(())
    }
}
pub fn discovery(display: &DisplayConfig) -> Vec<u8> {
    let ping = Proto::default()
        .number(1, 5000) // timeout_ms
        .number(2, 1500) // interval_ms
        .number(3, 500) // high_latency_threshold_ms
        .number(4, 5); // tracked_ping_count

    let connection = Proto::default().nested(1, ping);

    let headunit_info = Proto::default()
        .bytes(1, b"Project Argo") // make
        .bytes(2, b"Universal") // model
        .bytes(3, b"2026") // year
        .bytes(4, b"argo-001") // vehicle_id
        .bytes(5, b"Project Argo") // head_unit_make
        .bytes(6, b"Argo Head Unit") // head_unit_model
        .bytes(7, b"1") // software build
        .bytes(8, b"1.0"); // software version

    let mut response = Proto::default()
        // Deprecated identity fields — retained for compatibility.
        .bytes(2, b"Project Argo")
        .bytes(3, b"Universal")
        .bytes(4, b"2026")
        .bytes(5, b"argo-001")
        // DriverPosition is zero-based:
        // LEFT=0, RIGHT=1.
        .number(6, if display.right_driver { 1 } else { 0 })
        .bytes(7, b"Project Argo")
        .bytes(8, b"Argo Head Unit")
        .bytes(9, b"1")
        .bytes(10, b"1.0")
        // can_play_native_media_during_vr
        .number(11, 1)
        // display_name
        .bytes(14, b"Project Argo")
        // probe_for_support = false
        .number(15, 0)
        // Modern AA configuration.
        .nested(16, connection)
        .nested(17, headunit_info);
    let mut sensors = Proto::default();
    for sensor in [10, 13] {
        sensors = sensors.nested(1, Proto::default().number(1, sensor));
    }
    response = response.nested(1, Proto::default().number(1, 1).nested(2, sensors));
    let video = Proto::default()
        .number(
            1,
            match display.width {
                800 => 1,
                1920 => 3,
                _ => 2,
            },
        )
        .number(2, if display.fps == 60 { 1 } else { 2 })
        .number(3, 0)
        .number(4, 0)
        .number(5, display.dpi as u64)
        .number(8, 10000)
        .number(10, 3);
    response = response.nested(
        1,
        Proto::default().number(1, 3).nested(
            3,
            Proto::default()
                .number(1, 3) // H.264
                .nested(4, video)
                .number(5, 1) // available_while_in_call = true
                .number(7, 0), // MAIN display
        ),
    );
    for (channel, role, rate, channels) in [(4, 3, 48000, 2), (5, 1, 16000, 1), (6, 2, 16000, 1)] {
        let config = Proto::default()
            .number(1, rate)
            .number(2, 16)
            .number(3, channels);
        response = response.nested(
            1,
            Proto::default().number(1, channel).nested(
                3,
                Proto::default()
                    .number(1, 1)
                    .number(2, role)
                    .nested(3, config)
                    .number(5, 1),
            ),
        );
    }
    let mic_config = Proto::default()
        .number(1, 16000) // sampling_rate
        .number(2, 16) // bits
        .number(3, 1); // mono

    response = response.nested(
        1,
        Proto::default().number(1, 9).nested(
            5, // MediaSourceService
            Proto::default()
                .number(1, 1) // PCM
                .nested(2, mic_config)
                .number(3, 1), // available_while_in_call
        ),
    );
    let touch = Proto::default()
        .number(1, display.width as u64)
        .number(2, display.height as u64);

    response
        .nested(
            1,
            Proto::default()
                .number(1, 8)
                .nested(4, Proto::default().nested(2, touch)),
        )
        .finish()
}
pub struct Reply {
    pub channel: u8,
    pub id: u16,
    pub control: bool,
    pub body: Vec<u8>,
}
impl Reply {
    pub fn new(channel: u8, id: u16, body: Vec<u8>) -> Self {
        Self {
            channel,
            id,
            control: matches!(id,7..=9|0x18..=0x1a),
            body,
        }
    }
}
pub enum Effect {
    Reply(Reply),
    Video(bool),
    Audio(u8, bool),
    Media(u8, Vec<u8>),
    End,
}
pub struct Channels {
    display: DisplayConfig,
    open: BTreeSet<u8>,
    setup: BTreeSet<u8>,
    sessions: BTreeMap<u8, u64>,
    pointers: BTreeMap<u16, (u32, u32)>,
    discovered: bool,
}
impl Channels {
    pub fn new(display: DisplayConfig) -> Self {
        Self {
            display,
            open: BTreeSet::new(),
            setup: BTreeSet::new(),
            sessions: BTreeMap::new(),
            pointers: BTreeMap::new(),
            discovered: false,
        }
    }
    pub fn handle(&mut self, channel: u8, id: u16, body: &[u8]) -> Result<Vec<Effect>, String> {
        let reply = |ch, id, body| Effect::Reply(Reply::new(ch, id, body));
        if id <= 1 && (3..=6).contains(&channel) {
            let session = *self
                .sessions
                .get(&channel)
                .ok_or("AA media before stream start")?;
            let data = if id == 0 {
                body.get(8..).ok_or("short timestamped AA media")?
            } else {
                body
            };
            if data.len() > 4 * 1024 * 1024 {
                return Err("AA media size limit".into());
            }
            return Ok(vec![
                Effect::Media(channel, data.to_vec()),
                reply(
                    channel,
                    0x8004,
                    Proto::default().number(1, session).number(2, 1).finish(),
                ),
            ]);
        }
        let fields = numbers(body)?;
        let number = |field| fields.get(&field).copied();
        if id == 7 {
            let target = number(2).ok_or("channel open missing service")?;
            println!(
                "AA channel open request: service={} via_ch={}",
                target, channel
            );
            let supported = self.discovered && matches!(target, 1 | 3..=6 | 8 | 9);
            println!(
                "AA channel open response: service={} supported={}",
                target, supported
            );
            if supported {
                self.open.insert(target as u8);
            }
            return Ok(vec![reply(
                channel,
                8,
                Proto::default()
                    .number(1, if supported { 0 } else { 1 })
                    .finish(),
            )]);
        }
        if channel == 0 && id == 0x0012 {
            println!(
                "AA AudioFocusRequest raw={}",
                body.iter().map(|b| format!("{b:02x}")).collect::<String>()
            );
        }
        if channel == 0 {
            return Ok(match id {
                5 => {
                    self.discovered = true;
                    println!(
                        "AA service discovery response: input, H.264, media/speech/system audio, microphone, night/driving sensors"
                    );
                    vec![reply(0, 6, discovery(&self.display))]
                }
                11 => vec![reply(0, 12, body.to_vec())],
                13 => vec![reply(0, 14, Proto::default().number(1, 1).finish())],
                15 => vec![reply(0, 16, Vec::new()), Effect::End],
                18 => {
                    let focus_type = number(1).unwrap_or(0);

                    let focus_state = match focus_type {
                        1 => 1, // GAIN -> GAIN
                        2 => 2, // GAIN_TRANSIENT -> GAIN_TRANSIENT
                        3 => 2, // MAY_DUCK -> GAIN_TRANSIENT
                        4 => 3, // RELEASE -> LOSS
                        _ => 3, // unknown -> LOSS
                    };

                    println!(
                        "AA AudioFocusResponse: request={} response={}",
                        focus_type, focus_state
                    );

                    vec![reply(
                        0,
                        19,
                        Proto::default().number(1, focus_state).finish(),
                    )]
                }
                4 | 12 | 17 | 23 => vec![],
                _ => vec![],
            });
        }
        if !self.open.contains(&channel) {
            return Err(format!("AA message for unopened channel {channel}"));
        }
        if channel == 1 && id == 0x8001 {
            let kind = number(1).ok_or("sensor request missing type")?;
            if !matches!(kind, 10 | 13) {
                return Ok(vec![reply(
                    1,
                    0x8002,
                    Proto::default().number(1, 1).finish(),
                )]);
            }
            // Without normalized inputs, retain conservative restrictions. No
            // fake speed/RPM/parking-brake data is advertised.
            return Ok(vec![
                reply(1, 0x8002, Proto::default().number(1, 0).finish()),
                reply(
                    1,
                    0x8003,
                    Proto::default()
                        .nested(
                            kind as u32,
                            Proto::default().number(1, if kind == 13 { 31 } else { 0 }),
                        )
                        .finish(),
                ),
            ]);
        }
        if channel == 8 && matches!(id, 0x8002 | 0x19) {
            return Ok(vec![reply(
                8,
                if id == 0x19 { 0x1a } else { 0x8003 },
                Proto::default().number(1, 0).finish(),
            )]);
        }
        if channel == 9 {
            return Ok(match id {
                // AVChannelSetupRequest
                0x8000 => {
                    if number(1) != Some(1) {
                        return Err("AA requested unsupported microphone codec".into());
                    }

                    self.setup.insert(9);

                    println!("AA microphone setup");

                    vec![reply(
                        9,
                        0x8003,
                        Proto::default()
                            .number(1, 2) // OK
                            .number(2, 1) // max_unacked
                            .number(3, 0) // config index 0
                            .finish(),
                    )]
                }

                // AV_INPUT_OPEN_REQUEST / MicrophoneRequest
                0x8005 => {
                    let open = number(1).unwrap_or(0) != 0;

                    println!("AA microphone open={open}");

                    let mut effects = vec![reply(
                        9,
                        0x8006,
                        Proto::default()
                            .number(1, 0) // status OK
                            .number(2, 1) // session id
                            .finish(),
                    )];

                    if open {
                        // HU is the sender on microphone/media-source channels.
                        effects.push(reply(
                            9,
                            0x8001,
                            Proto::default()
                                .number(1, 1) // session id
                                .number(2, 0) // config index
                                .finish(),
                        ));
                    }

                    effects
                }

                // STOP_INDICATION / ACK — nothing required yet.
                0x8002 | 0x8004 => vec![],

                _ => vec![],
            });
        }
        if (3..=6).contains(&channel) {
            return Ok(match id {
                0x8000 => {
                    let expected = if channel == 3 { 3 } else { 1 };
                    if number(1) != Some(expected) {
                        return Err("AA requested an unadvertised media codec".into());
                    }
                    self.setup.insert(channel);
                    println!("AA AV setup: channel={channel}");
                    vec![reply(
                        channel,
                        0x8003,
                        Proto::default()
                            .number(1, 2)
                            .number(2, 4)
                            .number(3, 0)
                            .finish(),
                    )]
                }
                0x8001 => {
                    if !self.setup.contains(&channel) || number(2).unwrap_or(0) != 0 {
                        return Err("AA invalid stream configuration".into());
                    }
                    self.sessions
                        .insert(channel, number(1).ok_or("AA stream session missing")?);
                    println!("AA AV start: channel={channel}");
                    if channel == 3 {
                        vec![
                            Effect::Video(true),
                            reply(
                                3,
                                0x8008,
                                Proto::default().number(1, 1).number(2, 0).finish(),
                            ),
                        ]
                    } else {
                        vec![Effect::Audio(channel, true)]
                    }
                }
                0x8002 => {
                    self.sessions.remove(&channel);
                    if channel == 3 {
                        vec![Effect::Video(false)]
                    } else {
                        vec![Effect::Audio(channel, false)]
                    }
                }
                0x8007 if channel == 3 => {
                    let focused = number(2) == Some(1);
                    vec![
                        reply(
                            3,
                            0x8008,
                            Proto::default()
                                .number(1, if focused { 1 } else { 2 })
                                .number(2, 0)
                                .finish(),
                        ),
                        Effect::Video(focused),
                    ]
                }
                _ => vec![],
            });
        }
        Ok(vec![])
    }
    pub fn touch(
        &mut self,
        pointer: u16,
        phase: u8,
        x: f32,
        y: f32,
        timestamp: u64,
    ) -> Result<Option<Reply>, String> {
        if !self.open.contains(&8) {
            return Ok(None);
        }
        if !x.is_finite()
            || !y.is_finite()
            || !(0.0..=1.0).contains(&x)
            || !(0.0..=1.0).contains(&y)
            || phase > 3
        {
            return Err("invalid projection touch".into());
        }
        let point = (
            (x * (self.display.width - 1) as f32).round() as u32,
            (y * (self.display.height - 1) as f32).round() as u32,
        );
        if phase == 0 {
            if self.pointers.len() >= 10 || self.pointers.contains_key(&pointer) {
                return Ok(None);
            }
        } else if !self.pointers.contains_key(&pointer) {
            return Ok(None);
        }
        self.pointers.insert(pointer, point);
        let mut touch = Proto::default();
        let mut index = 0;
        for (i, (&id, &(x, y))) in self.pointers.iter().enumerate() {
            if id == pointer {
                index = i;
            }
            touch = touch.nested(
                1,
                Proto::default()
                    .number(1, x as u64)
                    .number(2, y as u64)
                    .number(3, id as u64),
            );
        }
        let action = match phase {
            0 if self.pointers.len() > 1 => 5,
            0 => 0,
            1 => 2,
            2 if self.pointers.len() > 1 => 6,
            2 => 1,
            _ => 3,
        };
        touch = touch.number(2, index as u64).number(3, action);
        if phase >= 2 {
            self.pointers.remove(&pointer);
        }
        Ok(Some(Reply::new(
            8,
            0x8001,
            Proto::default()
                .number(1, timestamp)
                .nested(3, touch)
                .finish(),
        )))
    }
}
