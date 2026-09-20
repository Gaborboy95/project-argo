# Native projection media

The existing Android Auto `ARVW` native creation parameters and unframed
`projection-video.sock` path remain unchanged. Control IPC7 is unchanged.
`argo_projection_view_media_contract_version()` reports `1` for the additional
opt-in **ARPM/1** native video transport. The foreground CarPlay receiver selects this transport only after authenticated
stream negotiation. A real iPhone has produced visible H.264 video inside Argo/IHS
with working touch; see the ongoing acceptance record in `docs/carplay.md`.

ARPM/1 and `ARV2` are Argo contracts, not LIVI or Apple wire protocols. The
distinction between Annex-B and CarPlay avcC/hvcC configuration with
length-prefixed access units was informed by f-io / Lasse Heitgres and LIVI at
`a23dc0c5fcdb6d069c679eddfd73298e58f44783`, specifically
`src/main/services/projection/driver/cp/stack/{screenStream,nalu}.ts`.
No LIVI implementation or test vectors were imported. See
[credits](../../../CREDITS.md) and the
[architectural review](../../../docs/carplay-livi-review.md).

## Native creation

The existing `argo.projection.view` factory additionally accepts exactly 40
bytes: ASCII `ARV2`, u32 version `1`, the 24-byte description below, then u16
left/top/right/bottom crop margins. All integers in these contracts use network
byte order. The margins must leave a nonempty view area inside the frozen encoded
dimensions. Cluster descriptions are rejected by this main-view factory.
These parameters contain metadata only; encoded bytes stay native.

The CarPlay socket defaults to `$XDG_RUNTIME_DIR/argo/carplay-video.sock` and can
be overridden by trusted process environment `ARGO_CARPLAY_MEDIA_SOCKET`. A
future ARPM Android Auto producer uses `projection-video-v1.sock` and
`ARGO_PROJECTION_MEDIA_V1_SOCKET`; neither changes the legacy AA endpoint.
Absent `XDG_RUNTIME_DIR`, the prefix is `/run`. Paths must be absolute, fit Unix
`sun_path`, and have no leading/trailing whitespace or trailing slash. The native
view never obtains an endpoint from a phone message. Connection wait is bounded
at 500 ms; an unavailable source fails native creation without spawning a daemon.

## Stream description: 24 bytes

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | u8 | Protocol: 1 Android Auto, 2 CarPlay |
| 1 | u8 | Plane: 1 main, 2 cluster (reserved for a separate renderer) |
| 2 | u8 | Codec: 1 H.264, 2 H.265 |
| 3 | u8 | SDR colorimetry: 1 BT.601/SMPTE170M, 2 BT.709 |
| 4 | u8 | Range: 1 limited, 2 full |
| 5 | u8 | Framing: 1 Annex-B, 2 length-prefixed |
| 6 | u16 | Encoded width, 1–1920 |
| 8 | u16 | Encoded height, 1–1080 |
| 10 | u16 | Frame-rate numerator |
| 12 | u16 | Frame-rate denominator, 1–1001 |
| 14 | u16 | Reserved, must be zero |
| 16 | u64 | Nonzero session identity |

Frame rate must be within 1–60 fps, inclusive. Unknown enum values and HDR
colorimetry are unsupported. Description identity, framing, dimensions, codec,
frame rate and color metadata must exactly match the native creation parameters.
The codec is never inferred from the current backend or guessed from payloads.

## ARPM records

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | 4 bytes | ASCII `ARPM` |
| 4 | u16 | Version, exactly 1 |
| 6 | u8 | Kind: 1 description, 2 codec config, 3 access unit |
| 7 | u8 | AU flags: bit 0 keyframe, bit 1 discontinuity; others zero |
| 8 | u32 | Payload byte count |
| 12 | u32 | Sequence, starts at zero, increases exactly by one |
| 16 | u64 | Nanosecond presentation timestamp |

The header is exactly 24 bytes, followed immediately by its payload. One socket
contains one immutable stream: description (24 bytes), one codec configuration
(1–65536 bytes), then access units (1–4194304 bytes). Descriptor/config flags and
timestamps are zero. AU timestamps may repeat but cannot decrease or equal
`UINT64_MAX`; the receiver normalizes them to the first AU. Sequence wrapping,
reconfiguration, session replacement, malformed input or unknown versions close
the stream. Reconfiguration requires a new view/session contract.

The first AU and every discontinuity must be marked keyframe. Producers are
responsible for truthful keyframe flags and monotonic timestamps; the renderer
checks NAL structure but does not decode slice syntax for this metadata.
Config and AU payloads contain at most 1024 NAL units. H.264 parameter sets must
include SPS/PPS; H.265 requires VPS/SPS/PPS. Empty/truncated NALs and invalid NAL
headers are rejected before GStreamer. Framing-specific rules:

- Annex-B config contains only parameter sets with three/four-byte start codes.
  Each AU also uses Annex-B. Config is prepended to the first AU and each
  discontinuity before submitting a complete AU to GStreamer.
- Length-prefixed config is a bare AVCDecoderConfigurationRecord (`avcC`) or
  HEVCDecoderConfigurationRecord (`hvcC`), not an enclosing atom/sample entry.
  It becomes GStreamer `codec_data`. AU length widths are taken from that record;
  only 1, 2 and 4 bytes are supported. H.264 optional high-profile extension fields
  are validated for profiles 100, 110, 122 and 144.

The native receiver bounds allocation before payload reads. Startup records and
partial records have a two-second deadline; established idle streams can remain
connected while hidden. Socket shutdown interrupts reads. The appsrc queue blocks
at three buffers/eight MiB thresholds (at most one buffer can cross a byte
threshold), with one in-flight AU and one <=64 KiB config; appsink retains the
latest two decoded buffers and drops older ones. No arbitrary encoded delta
frame is dropped by the renderer. Its worker stops and joins when the view is
disposed. No reconnect/spawn loop is implemented here.
Locally hiding an ARPM view suppresses IHS submission while continuing to consume
and decode video, so bounded producer writes cannot disconnect a hidden session.
This preserves the dependency chain and avoids visibility changes from packets;
hidden decoding still costs CPU/GPU time. Legacy AA suspend behavior is unchanged.

The companion Rust `argo_carplay::media::VideoStream` serializes the same
description/config/AU records to one same-user native Unix socket. Its queue
holds at most three encoded AUs. Overflow discards the queued dependency chain
and requires a fresh IDR/IRAP before resuming; `NeedKeyframe` tells the native
session owner to request that picture. It never arbitrarily delivers newer
delta pictures without their references. Each write has a two-second timeout.
Explicit stop interrupts blocked writes; consumer disconnect, future cancellation
and stop release the single-consumer lease. A new connection starts sequence
zero and requires a fresh keyframe. The caller owns listener/path permissions and
must await shutdown. The foreground CarPlay receiver owns the phone and private media listener; the
Dart adapter advertises metadata and native creation parameters only. Managed
production session integration remains unfinished.

## Decode, color and limits

The selected `h264parse`/`h265parse` feeds a dimension-constrained caps filter,
`decodebin`, SDR color metadata propagation, `videoconvert`, BGRx appsink and
the existing IHS PlatformViewLayer path. Frozen color range is applied before
YUV-to-RGB conversion. Converted RGB is labelled full range for IHS. The existing
GBM mapping/copy and optional IHS software fallback remain: this is **not** a
zero-copy claim. Decoded dimensions must match the frozen description; mapped
buffer size, offsets, strides and format are checked before accessing pixels.

Available GStreamer decoder selection remains system-owned; successful software
decode tests do not establish hardware H.265 support, 60 fps performance, visible
IHS frames, correct physical-panel color or a working CarPlay session. Main-only
rendering is implemented. No AirPlay decryption, audio, microphone or cluster
presentation is performed by this library.

## Checks

Build against the same installed IHS headers/library as the application, using a
fresh build directory (do not replace an already loaded `.so`):
GStreamer 1.20 or newer is required for bounded appsrc buffer-count support.

```sh
IHS_PREFIX=/path/to/matched/ihs cmake -S native/projection/argo-projection-view \
  -B /tmp/argo-projection-media -DBUILD_TESTING=ON
cmake --build /tmp/argo-projection-media -j2
ctest --test-dir /tmp/argo-projection-media --output-on-failure
```

Tests cover legacy crop copying, bounded/versioned descriptions and records,
codec configuration, malformed/truncated NALs, session/sequence/timestamp
rejection, fragmented socket reads, partial-record timeout and idle-reader
teardown. Numeric BT.601/709 full/limited conversion checks use synthetic YUV.
The decode test generates H.264/H.265 through software encoders and decodes both
framing variants; it reports a CTest skip if those optional test codecs are
unavailable. These checks require no phone, dongle, display or GPU.

Rust producer checks run with
`cargo test --manifest-path native/carplay/Cargo.toml media::tests --lib`.
Its synthetic socket sender and the C++ receiver validate the same checked-in
`test/fixtures/arpm-v1.hex` byte fixture. That fixture contains structurally valid
minimal NAL headers, not a decodable picture or captured phone data. The separate
GStreamer decode test generates genuine synthetic encoded pictures at runtime.
