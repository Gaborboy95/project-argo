# Native CarPlay protocol review

This technical source map supplements [the LIVI review](carplay-livi-review.md)
and [the CarPlay guide](carplay.md). The reference is **f-io / Lasse Heitgres —
LIVI**, commit **a23dc0c5fcdb6d069c679eddfd73298e58f44783**, package version
**9.0.0**, reviewed from the separately cloned development tree. References below
are relative to that exact upstream revision, never moving build dependencies.

## Architectural findings

LIVI's Rust helper is not its complete native CarPlay implementation. The helper
owns local USB/usbmux/lockdown, iAP2 link/control sessions, real MFi requests,
radio integration and iAP2 metadata. The Electron main-process TypeScript
`CpManager`, `CpSession` and `cp/stack` code owns AirPlay negotiation, pairing,
encrypted control/events, session-level stream setup, display capabilities,
touch/HID and orchestration. Native GStreamer receiver code owns the production
media data path. Launching only `livi-helperd` cannot produce a CarPlay picture.

Argo's separate `argo-carplayd` boundary keeps this work outside the established
Android Auto daemon and IPC7 engine. Argo must eventually implement the missing
AirPlay owner in Rust and route encoded media into its existing IHS projection
renderer. The current protocol library is transport independent and has no
Electron or LIVI executable dependency. Sharing an encoded-media description
does not by itself implement a phone session.

## Reviewed upstream source map

| Area | Pinned upstream sources | Relevant behavior |
|---|---|---|
| Prepared Link | `LIVI-LINK.md`; `livi-dongle/src/link.rs` | USB network accessory addressed as `livi-link.local`; prepared hardware is not a generic projection dongle. |
| MFi | `iap2-mfi/src/{lib,ncm,server,linux}.rs`; `livi-runtime/src/mfi_async.rs` | Real coprocessor interface, remote transactions and shared ownership; no private key export operation. |
| USB/wired | `iap2-usbmux/src/{linux,mux,backend,ncm,ntb}.rs`; `iap2-wired/src/{carkit,usbmuxd}.rs`; `bin/livi-helperd/src/wired.rs` | Local iPhone configuration, usbmux, trusted lockdown carkit stream, separate USB-NCM media network, unplug cancellation. |
| iAP2 | `iap2-link/src/lib.rs`; `iap2-csm/src/lib.rs`; `iap2-csm/src/messages/{identification,authentication,car_play,wifi}.rs` | Checksummed link frames, synchronization, sequence/retransmission policy, nested typed CSM fields. |
| Bring-up | `livi-runtime/src/{driver,ident,bringup,framing,state}.rs` | Identification, MFi challenge exchange, availability and StartSession, per-phone session ownership. |
| Wireless | `livi-runtime/src/{bt,reconnect,bonjour,wifi_ap}.rs`; `livi-dongle/src/{bt,iap,ap}.rs`; helper `linux_main.rs` | BlueZ iAP profiles, HCI/VHCI bridge, mDNS, Link AP settings and alternate dongle-side iAP handoff. |
| AirPlay | `cp/stack/{cpStack,rtspMessage,pairSetup,pairVerify,srp,authSetup,controlCipher,crypto,bplist,tlv8}.ts` | RTSP/HTTP framing, binary plist, pairing and encrypted setup; MFiSAP is additional to iAP2 authentication. |
| Video | `cp/stack/{screenStream,nalu,getInfo}.ts`; `GstVideo.ts`; `gstHost.ts`; `native/livi-gst-video` | Separate main/cluster receivers, selected codec configuration, encrypted screen transport and native GStreamer rendering. |
| Audio/mic | `cp/stack/cpStack.ts`; `CpSession.ts`; `GstVideo.ts`; `gstHost.ts` | Negotiated audio streams, LPCM/AAC-LC/Opus, media/calls/speech/prompts, bidirectional microphone and native ownership. |
| Input | `cp/stack/hid.ts`; `cpStack.ts` | Descriptor-bound multitouch reports and Siri/media/telephony event commands. |
| Metadata | `iap2-csm/src/messages/{now_playing,route_guidance,power,communications,location,vehicle_status}.rs`; `livi-runtime/src/{events,file_transfer}.rs` | Structured updates, separate artwork transfer, device-scoped routing; optional vehicle/location requests. |
| Lifecycle | `CpManager.ts`; `CpSession.ts`; `cpStack.ts`; helper `wired.rs`; `livi-runtime/src/{state,reconnect}.rs` | Shared listener/signer with per-phone sessions; handover, stream-specific teardown, session teardown and unplug. |

Paths in the table under Rust crates are rooted at `native/livi-helperd/crates/`;
TypeScript CarPlay paths are rooted at
`src/main/services/projection/driver/cp/`. Media services are rooted at
`src/main/services/video/`.

## Verified Link services

| TCP port | Service | Source and Argo use |
|---|---|---|
| 5000 | Remote MFi | `iap2-mfi/src/{ncm,server}.rs`; used by Argo's real coprocessor client. |
| 5001 | AP/radio line control | `livi-dongle/src/ap.rs`; typed status/configuration client; no arbitrary command channel. |
| 5002 | Bluetooth HCI | `livi-dongle/src/bt.rs`; not opened for ordinary health checks because a connection can claim controller ownership. |
| 5003 | USB proxy | `iap2-usbmux/src/remote.rs`; not used by Argo's preferred local wired topology. |
| 5004 | Dongle-side Bluetooth/iAP handoff | `livi-dongle/src/iap.rs`; not an AirPlay receiver and not used by current wired code. |
| 5005 | Dongle-side iAP control | `livi-dongle/src/iap.rs`; additional pinned service absent from the initial approximate port list; not implemented in Argo. |

The MFi protocol has one-byte operation codes: certificate `1`, sign `2`,
generation `3`. Signing includes a big-endian 16-bit challenge length. Replies
carry status and a big-endian 16-bit payload length. Generation is a one-byte
major version. Argo bounds certificate/signature sizes, serializes concurrent
operations and uses fresh sockets; transport failure does not implicitly replay
a signing request. Reading a certificate is not a successful phone-authentication
test. The certificate contains public identity; the private MFi key stays in the
actual chip.

## Wired topology and practical limits

The phone belongs on the LattePanda USB host. Its iAP2 control channel is the
lockdown service `com.apple.carkit.service`, reached through usbmux. The phone's
USB-NCM network carries AirPlay audio/video; Link's network connection supplies
MFi independently. A reachable Link does not establish the phone's USB network.

The pinned upstream Linux implementation requests Apple's CarPlay USB
configuration set, selects configuration 6, establishes its own usbmux transport,
and looks for a kernel `cdc_ncm` interface. Where the kernel does not expose that
function, upstream implements NCM in userspace and attaches a TAP interface.
These changes and their privileged network/device operations were **not** copied
or executed. Argo does not assume `ipheth` tethering equals the required CarPlay
NCM function. No dongle OTG USB-proxy workaround is selected.

Argo's optional `linux-usbmuxd` library adapter instead connects only to the local
system `/var/run/usbmuxd`, lists USB devices, retrieves an existing system trust
record in memory, verifies an iPhone product type, starts a trusted lockdown
session and opens carkit. It does not pair the phone, write pairing records,
switch USB configurations, claim USB interfaces or configure a TAP/NCM network.
This is a testable attachment primitive, not automatic wired CarPlay bring-up.
Some devices/configurations may require the missing USB/NCM owner before this
route is usable.

The adapter bounds plist bodies and retained expanded event data to 256 KiB,
expanded events to 4096 and nesting to 16. Repeated binary-plist references count
toward the expanded data limit. Each open has a 20-second total deadline;
inventory has five seconds.
It uses OpenSSL with TLS 1.2 or later and pins the phone's leaf certificate to
the existing local trust record. The carkit service follows its lockdown-provided
TLS requirement. Plaintext service transport is accepted only when that
authenticated local lockdown response declares it; network usbmux endpoints
are unavailable. Raw pairing data and host private keys are not logged or saved.

`idevice` 0.1.65 (MIT, the version in LIVI's lockfile) was evaluated but not added:
its general plist receive path allocates the peer's length before an Argo bound,
and its Rust TLS configuration does not verify the peer certificate/signature.
Argo uses its own bounded message exchange with `plist`, OpenSSL and
`tokio-openssl`; no `idevice` source is included. The exact `plist` version is
pinned because its event-stream API is explicitly unstable. `Cargo.lock` records
all dependency versions.

## Implemented control library

`native/carplay/src/protocol/` contains independently written wire codecs and an
experimental async wired control owner. It accepts an already-open carkit stream
and a real `LinkClient`. The owner negotiates iAP2 control version 2 with zero-ACK
parameters on the reliable stream, sends a minimal configurable wired identity,
answers MFi certificate/challenge requests through Link, waits for explicit
phone authentication success and wired availability, then emits StartSession.
It owns the stream until cancellation, unplug/EOF or rejection. Authentication
has a 15-second budget and complete startup 30 seconds. Cancellation drops owned
I/O with no detached workers, retries or queues.

StartSession contains the host-selected wired media address, port and accessory
identity/public key. Its wireless serializer has typed WPA/WPA2 fields but is
not a wireless connection engine. The daemon must only invoke wired control
after a genuine AirPlay listener and media interface exist. `StartSessionSent`
explicitly means control progress; it is never a visible-video or connected
projection state. No default daemon path currently starts this experimental
control owner or advertises a functioning AirPlay receiver.

The iAP2 library additionally validates checksums, incremental record boundaries,
synchronization and a bounded cumulative-ACK send window with sequence wraparound,
duplicate ACK handling, retransmission limits and explicit clearing. That send
window is for reliable-protocol development outside zero-ACK carkit mode; a full
wireless EAK/reordering engine is not implemented.

## AirPlay, media and input findings

AirPlay control includes pair setup/verification, encrypted RTSP events, MFiSAP
`auth-setup`, binary-plist GetInfo/SETUP/RECORD, timing and feedback. iAP2 MFi
success cannot replace those steps. The helper's MFi interface is reused during
AirPlay authentication; Link does not terminate the main video stream.

Main screen type 110 and alternate/cluster screen type 111 have independent
receivers. Screen transport has a 128-byte header, little-endian body length,
clear codec-configuration records and authenticated encrypted frame records.
The pinned TypeScript fallback recognizes avcC/hvcC and forwards length-prefixed
NAL units. They are not Android Auto Annex-B packets. Argo's parsers reject
undersized encrypted video, excessive control bodies and ambiguous HTTP lengths;
they do not decrypt frames or claim to implement AirPlay. Negotiated codec,
dimensions, color range and framing belong in the separate native media contract.
HEVC, full range and zero-copy require actual phone/Mu validation.

Audio stream types 100/101/102 are independent of screen streams. The pinned
implementation distinguishes wired signed 16-bit LPCM, AAC-LC entertainment and
Opus low-latency mono formats. Argo validates a single selected audio-format bit
and derives rate/channels; no CarPlay audio receiver, decoder, focus/ducking or
PipeWire stream is integrated yet. Upstream mic upload belongs to bidirectional
main audio and is released during stream teardown. Argo still needs its existing
native microphone selection/lease wired to negotiated CarPlay capture.

LIVI's touchscreen advertises two fixed HID contact slots. Reports bind stable
slots to absolute 16-bit pixel coordinates; the encrypted event channel carries
`hidSendReport`. Argo must reuse its existing fitted viewport/touch mapper, then
encode negotiated HID coordinates once. The current protocol library does not
send touch, cancel reports or Siri events. Cluster transport should remain a
separate plane, not be composited into the main image.

## Wireless, metadata and ownership

On Linux, pinned Link HCI transport feeds `/dev/vhci`, producing a controller
managed by host BlueZ. An alternative port 5004 path hands off an iAP session
owned by dongle Bluetooth. These are deliberate alternatives, not services to
claim opportunistically. Argo has not implemented either path and needs no
VHCI/device permission changes now. Future implementation needs an explicit
controller lease, narrow device permissions and cancellation-aware packet pumps.
AP activation must follow selected wireless connection intent and end with its
owner; the current daemon does not enable another AP automatically.

Upstream `CpManager` routes identities and metadata across per-phone sessions,
while `CpSession` bridges to projection/audio contracts. Main audio, microphone,
timing, encrypted events, iAP tunnels and both video planes are released on
session teardown; stream-specific teardown must release only the named streams.
Argo's future runtime must keep session connection ownership separate from local
presentation. Home/hide cannot destroy the connection or allow incoming packets
to take foreground away from reverse camera.

Metadata should retain CarPlay/session provenance in Argo's existing media and
navigation models. Optional location and vehicle components are omitted from
the current accessory identity: no engine type, range, GPS or stale CAN values
are fabricated. Artwork, now-playing subscriptions and route guidance are not
currently implemented by Argo's control library.

## Provenance and verification boundary

LIVI is GPL-3.0-or-later. Its architecture and interoperable wire fields materially
informed this implementation; attribution to **f-io / Lasse Heitgres and LIVI**
is required and appears in [CREDITS](../CREDITS.md), the review and source module
headers. No LIVI implementation files, translated bodies, test vectors, icons or
assets are imported. Tests use synthetic Argo fixtures. This is not a claim of
clean-room development or a legal conclusion about process separation. Future
source imports require file-level provenance, retained copyright/license notices
and applicable source/license texts before integration.

The native tests exercise fragmentation and malformed lengths, iAP2 checksums
and sequence wraparound, bounded retry exhaustion, minimal identity and
StartSession fields, real `LinkClient` transactions against a synthetic TCP
coprocessor, authentication ordering, cancel/timeout/unplug cleanup, local mux
packet bounds, plist expansion limits and TLS certificate-pin acceptance and
rejection. They cannot establish physical iPhone authentication, NCM networking,
AirPlay decoding, visible IHS video, audio, touch or reconnect acceptance.

```bash
cargo test --manifest-path native/carplay/Cargo.toml
cargo test --manifest-path native/carplay/Cargo.toml --features linux-usbmuxd
```

The optional Linux build needs OpenSSL development headers and `pkg-config`.
No firmware provisioning, USB configuration change, AP enable or host permission
change is needed to run these tests.


## Additional audio interoperability research

The live audio investigation also consulted Apple's
[Developing CarPlay Systems, Part 2 (WWDC 2016)](https://developer.apple.com/videos/play/wwdc2016/723/)
for main-audio ownership and the author's
[CPC200 protocol observations](https://github.com/lvalen91/CPC200-CCPA_resources/blob/main/documentation/02_Protocol_Reference/usb_protocol.md)
for mode-transfer enum values. Its
[audio observations](https://github.com/lvalen91/CPC200-CCPA_resources/blob/main/documentation/02_Protocol_Reference/audio_protocol.md)
helped identify a bidirectional-capability compatibility hypothesis. No source or
fixtures were imported from that repository. These observations are not an Apple
specification, and neither releasing main audio nor adding microphone support has
been established as a fix for the physical iOS 18 audio failure. The microphone
path remains opt-in and has not been tested with a physical microphone.


The audio timing follow-up also reviewed pinned LIVI
`cp/stack/timingServer.ts` and `cpStack.ts`: receiver timing and playback feedback
share the phone's clock domain, and feedback before audio setup has no stream
report body. Argo's monotonic clock and synthetic checks are independently
implemented. No upstream timing algorithm body or fixture was imported.


## Audio comparison against pinned LIVI defaults

The direct comparison also includes `src/main/shared/types/DefaultConfig.ts`,
`cp/CpSession.ts::_buildStackConfig`, `cp/stack/getInfo.ts`, and
`cpStack.ts::_setupAudio`. The reference defaults to 48 kHz entertainment audio
and source version `950.7.1`; Argo previously hardcoded `320.17`. Argo now shares
one source-version constant between iAP2 StartSession and AirPlay `/info`.

Other differences remain explicit: LIVI advertises bidirectional PCM/Opus voice
capabilities, whereas Argo advertises PCM input only with a configured source and
has no Opus implementation. LIVI publishes a Bluetooth controller identifier,
additional HID devices and optional iAP data-stream features; Argo does not claim
those unimplemented capabilities. Audio output SETUP in both uses the verified
session secret, direction-specific DataStream key, negotiated format and matching
stream connection ID. These comparisons do not themselves prove which difference
causes the physical phone to withhold an audio stream.

The physical iPhone XS/iOS 18 retest with `950.7.1` still played Spotify on the
iPhone, and the receiver had no audio streams. Updating the version alone is
therefore not an audio fix. The next controlled comparison is the existing
opt-in PCM input capability with an explicitly selected physical microphone;
the camera capture inputs must not be selected implicitly.

With a real Corsair input selected, the phone negotiated main audio with stereo
PCM at 44.1 kHz and delivered authenticated packets. Source version and output
configuration were unchanged from the preceding failed test. The phone exposed the CarPlay audio route. Reviewing `cpStack.ts::_handleTeardown` also identified type-only
stream selectors; Argo independently implements bounded audio selector validation
and cleanup, covered by synthetic tests. No source body or fixture was imported.

The follow-up native playback comparison includes
`native/livi-gst-video/rust/audioplayer/src/lib.rs`: explicit clock pacing is
separate from the nonsynchronizing PulseAudio sink. Argo now uses its own bounded
pipeline with a system clock and a pacing element before that sink, preserving
RTP-derived PCM timestamps and its own gain policy. The prior synchronized-sink
path yielded a silent output monitor despite nonzero authenticated samples;
the revised path yielded nonzero monitor samples and user-confirmed Spotify
playback with pause/resume. A synthetic GStreamer PCM/gain test was added. This
is source-informed pipeline design, not an imported or translated upstream body.


Dedicated Siri button semantics were checked against pinned
`cpStack.ts::invokeSiri`: action 2 is button-down and action 3 is button-up.
Argo independently serializes these edges and regression-tests the plist and
Flutter commands. The microphone ownership library is Argo-owned integration
shared with existing AA/HFP capture; it does not import upstream implementation.

The optional dongle-owned Bluetooth handoff framing was reviewed in pinned
`livi-dongle/src/iap.rs`: bounded newline header, `peer`/`local` Bluetooth identities,
blank-line terminator followed immediately by iAP bytes on TCP 5004. Argo's
`dongle_iap.rs` is independently implemented with synthetic framing tests; no
upstream implementation body or fixture was imported. This transport foundation
is not yet wired into wireless session admission.
