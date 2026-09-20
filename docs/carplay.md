# Native CarPlay development

**Wired CarPlay is under physical acceptance testing; it is not complete.**
A real iPhone has completed iAP2/MFi and AirPlay authentication using the prepared
LIVI Link. The shared wired receiver decrypts H.264 and the native renderer decodes 1280×720
frames through IHS. On 2026-09-20 the user confirmed that the CarPlay picture is
visible inside Argo, app-icon/app-grid touch works, and returning from an Argo
page through Home restores picture and touch. Automatic physical replug has also been confirmed. With a selected Corsair
microphone, the phone now sends a 44.1 kHz stereo music stream to the native
receiver. The user confirmed Spotify through Dzsibilee and pause/resume after
the native playback pacing fix. This is not full CarPlay completion.

## Implemented scope

| Component | Current scope |
| --- | --- |
| `argo-carplayctl` | Read-only mDNS/MFi/Wi-Fi status and IC protocol major |
| `argo-carplayd` | Unprivileged diagnostics plus opt-in supervised `--wired` receiver |
| Link library | Bounded persistent MFi connection, same-connection public certificate cache for authentication, no signing retry |
| Wired control | Trusted carkit, direct USB mux, real MFi, typed iAP2 identification and StartSession |
| USB network | Userspace NCM, temporary NetworkManager TAP, narrow administrator USB configuration lease |
| AirPlay receiver | SRP pairing, pair verification, real MFi auth-setup, encrypted control/events, authenticated H.264 main screen |
| Native media | ARPM/1 into existing GStreamer/GBM/IHS surface; shared library also supports synthetic H.265 fixtures |
| Flutter adapter | Private metadata/input IPC, session selection, visibility, presentation revisions, normalized two-contact touch |
| Audio | PCM Spotify playback through Dzsibilee and pause/resume physically confirmed with Corsair input configured; Siri and clear two-way calls with music restoration confirmed; echo processing and shared microphone mute/unmute physically confirmed; AAC acceptance pending |
| Wireless | Typed Wi-Fi controls, tested HCI/VHCI and dongle iAP handoff foundations; complete wireless CarPlay is not integrated |

The managed application, AA daemon and CarPlay daemon now start and stop cleanly
on this host. CarPlay settings and shared microphone selection are implemented.
Fresh USB authorization, wireless sessions, metadata, cluster and long-running
physical coexistence acceptance remain separate limitations. Unsupported features
must not be described as usable based on the reference implementation.

## Topology and ownership

The iPhone belongs on a LattePanda USB port. Its usbmux/lockdown carkit stream
carries iAP2; a separate phone USB-NCM path carries AirPlay. The prepared LIVI Link
is a network accessory providing the real MFi authentication IC. Its NCM network
is independent of the phone's USB network. Normal Linux wired operation does not
use the dongle USB proxy. The upstream reference explicitly describes dongle OTG
as macOS-only.

No flashing, provisioning, updating, restoring, repartitioning, key extraction
or MFi emulation is performed. No LIVI/Electron application is launched. The new
Rust process isolates development from AA transport/audio/connectivity; Flutter
receives metadata only. The existing native view uses GStreamer, GBM buffer
mapping/copy and IHS PlatformViewLayer; zero-copy is not claimed.

Radio ownership is independent of MFi use. Diagnostics never enable/disable AP or
Bluetooth and never open HCI/handoff transport ports, which can acquire ownership.
An already-running dongle AP is reported without being claimed by Argo. Future
wireless operation must own the selected radio and release it after session cleanup.

## Build and read-only checks

From Argo:

```bash
cargo test --locked --offline --manifest-path native/carplay/Cargo.toml
cargo clippy --locked --offline --manifest-path native/carplay/Cargo.toml --all-targets -- -D warnings
cargo build --locked --offline --release --manifest-path native/carplay/Cargo.toml
native/carplay/target/release/argo-carplayctl link status
native/carplay/target/release/argo-carplayctl mfi probe
```

Resolve missing locked dependencies online once if needed, without updating the
lockfile. Add `--features linux-usbmuxd` to build/test the optional attachment
library (OpenSSL development files are required); it does not start phone sessions.

For an explicitly requested attachment test, connect exactly one unlocked iPhone
directly to the host, accept its Trust prompt, and run:

```bash
cargo run --locked --offline --manifest-path native/carplay/Cargo.toml \
  --features linux-usbmuxd --example wired_probe -- --open-carkit
```

The probe lists local USB devices, opens the trusted carkit service and immediately
closes it. It prints no phone identifiers or pairing credentials and does not send
iAP2 authentication or CarPlay StartSession. Success establishes USB/trust/service
attachment only. Debian's installed usbmuxd udev rule normally starts the system
service on iPhone attach. If Untrusted appears before the system has finished
saving an accepted pairing, wait for trust to settle and retry.

Both CLI commands send only certificate/protocol queries to TCP 5000 and `status`
to TCP 5001. They do not sign test challenges, write dongle files, persist its
certificate or print authentication bytes. The library sign API is for a real
phone's challenge; tests use synthetic TCP peers. Exit is nonzero if MFi is unavailable.

Ensure the prepared Link's host NCM Ethernet connection is active. Inspect
`lsusb`, `ip -brief address`, `nmcli device status` and `ip -4 route`. Activate the
appropriate existing Ethernet connection if needed, preserving the normal default
route. Do not assume interface names/addresses. Argo queries `livi-link.local` via
IPv4 mDNS across up to 16 active interfaces, using bounded unicast replies,
independently of NSS configuration.

`ARGO_LIVI_LINK_ADDRESS=<trusted IPv4>` overrides discovery for CLI/foreground
diagnostics only. It is not a Flutter field or managed deployment setting; remove
it to restore mDNS. Ports are verified against the pinned source, not phone input.
The protocol is local plaintext and mDNS does not authenticate the remote service;
use the trusted direct NCM network. `mfi: ready` means certificate/major transactions
succeeded, not that an iPhone accepted authentication. The major is the dongle's
result, which may be inferred from certificate size. `session_validated` stays false.

## Service and Devices UI

Run `native/carplay/target/release/argo-carplayd` as the desktop user. Launch the
matched Argo app with `ARGO_CARPLAY_DIAGNOSTICS=1` to show the health card.
`XDG_RUNTIME_DIR` is required. The daemon creates private `project-argo/carplay.sock`
(directory 0700, socket 0600), refuses root and excludes a second owner.

Only `status\n` is accepted, returning one JSON line of at most 4096 bytes,
`contract: 1`, `implementation: diagnostics-only`. At most eight clients have
two-second deadlines. The worker waits five seconds after each probe. Each Link
transaction has a total five-second timeout including discovery/connect/read;
requests re-resolve each time. `checked_at_unix_ms` identifies probe time (zero
before the first probe). Concurrent library operations return Busy, without a queue.

The optional Linux UI polls cached health every five seconds after completion,
with a two-second whole-request timeout. It neither spawns processes nor connects
to dongle ports. App shutdown cancels polling. Daemon readiness is independent of
Link health. SIGTERM/Ctrl+C cancels owned tasks and sockets; managed clean markers
are written only after cleanup. No audio, mic, USB, AP or VHCI resource is started.

## Managed release integration

Build a **new** bundle using the [matched SDK/IHS recipes](../tool/projection/README.md).
Retain its newly built Dart assets; copy unchanged AA, camera, Veloce, SQLite and
Engine components only from a verified compatible base. Rebuild the projection
view with ARPM support, preserving external camera API/mode. Never overwrite a
loaded binary/library.

With `ARGO_RELEASE` naming that new bundle and `IHS_PREFIX` the matched IHS build:

```bash
install -m 755 native/carplay/target/release/argo-carplayd "$ARGO_RELEASE/bin/argo-carplayd"
install -m 755 native/carplay/target/release/argo-carplayctl "$ARGO_RELEASE/bin/argo-carplayctl"
python3 tool/deployment/record-build.py bundle "$ARGO_RELEASE" \
  --ihs-prefix "$IHS_PREFIX" --camera-mode external --projection-media-contract 1
tool/deployment/argoctl stage "$ARGO_RELEASE" --name carplay-diagnostics-development
```

Select `--camera-mode` for the actual camera assets. The media-contract flag is
only for a rebuilt ARPM-capable view. Install updated argoctl/user units using the
existing setup workflow before `argoctl select <unique-release-name>`.

`carplay_control=1` requires both executable CarPlay tools. Its optional user
service has `PartOf=argo.target`, no surround-camerad dependency, five-second
failure restart delay, three starts per 90 seconds and eight-second stop limit.
Older releases still validate and the unit's file condition skips them. Selection
and rollback include the optional service without coupling its crash to AA.
Bundles containing diagnostics enable the health card by default; managed common
environment `ARGO_CARPLAY_DIAGNOSTICS=0` hides it.

## Remaining implementation and permissions

The shared `wired_runtime` is now used by both the example and `argo-carplayd
--wired`. The daemon retries failed sessions with a delay of 2–30 seconds, resets
backoff after a minute-long session, and stores pairing under
`$XDG_STATE_HOME/argo-carplay` (default `~/.local/state/argo-carplay`). It owns one
receiver at a time and cleans up session resources before retrying. Explicit user
Disconnect suppresses automatic reconnect until wired mode is restarted; a
remembered-device Connect action is still needed.

The daemon has authenticated with the real phone and served negotiated H.264 to
the Argo consumer. A physical replug automatically restored authentication and
video transport, but the user initially saw a waiting screen. Home now activates
an unselected replacement session when it becomes ready, without activation on
other pages. A second replug exposed an empty screen configuration message; that
exact message is ignored without consuming a frame nonce or authorizing video.
After restarting the patched daemon, the user confirmed visible CarPlay and
working touch without another cable change. The user subsequently confirmed automatic physical replug restores picture and
touch with both fixes and the installed USB lease.

A live SIGTERM test exited in about 41 ms, removed both session sockets and the
temporary NetworkManager connection. An isolated diagnostic test also confirmed
owner exclusion and socket cleanup. The installed polkit USB lease now replaces the manual sudo terminal on this
host. Long-running and managed-service permission acceptance remain pending.

Native PCM/AAC playback and per-stream gain plumbing exist. The phone opened
a PCM music stream after enabling an explicitly selected microphone input. Explicit phone duck/unduck commands
are currently logged rather than applied. Optional PCM microphone capture exists,
and dedicated Siri button press/release semantics are implemented. The user
confirmed Siri recognized a Corsair microphone request and answered through
Dzsibilee. Clear two-way calls and music restoration are also confirmed. Shared microphone selection now reaches the active CarPlay receiver and future sessions. Touch HID delivery is
implemented and physically confirmed.

CarPlay has a dedicated settings destination with persistent enable, auto-connect,
resolution, 30/60 fps and driver-side preferences, plus connect/reconnect,
disconnect and active-session selection. Display changes apply on reconnect.
A remembered-device catalog and forgetting pairings remain unfinished.
Phone HEVC negotiation and physical 60 fps acceptance remain unfinished. Synthetic H.265 decoder tests do not establish phone HEVC support.

CarPlay metadata/artwork/navigation and forwarding of typed fresh vehicle/GPS
signals remain unimplemented. No data is fabricated. Cluster is a separate reserved
plane, rejected by the main-view factory rather than composited into its frame.
Physical reverse-camera coverage/restoration, automatic replug, long-running
resource/performance checks and Android Auto coexistence acceptance remain pending.

Wireless CarPlay is not implemented. The upstream Linux bridge uses TCP 5002 and
`/dev/vhci`; dongle-side iAP handoff is 5004 with extra control on 5005. Argo does
not attach VHCI or claim those endpoints are ready. Current diagnostics need only
ordinary user sockets, no root, USB permissions, firewall changes or provisioning.
Future USB/VHCI access must use narrow 0660/device-group or seat ACL rules, never
world-writable devices. The installed permission helper covers wired USB configuration only; it grants
no wireless/VHCI access.

## Physical validation

On Debian 13 Mu the prepared Link enumerated as USB `1314:1520`. Activating its
existing host Ethernet profile obtained `10.10.10.100/24`, retaining the Wi-Fi
default route. Argo mDNS resolved `10.10.10.1`; certificate read returned 945 bytes,
remote major 2. Wi-Fi status reported AP/Bluetooth on, HU/channel 36. Neither radio
state nor dongle firmware/persistent configuration was modified.

Later repeated MFi probes timed out while mDNS and Wi-Fi status still succeeded.
A separate bounded read-only check connected to TCP 5000 promptly and received
the protocol-query header, but a certificate query took about 6.2 seconds and
returned an implausible 40,113-byte length. Argo rejects lengths above 4096 and
uses a five-second transaction deadline. No certificate contents were logged.
The cause in the prepared service/IC was not established, and no firmware operation
was attempted. Initial success does **not** establish sustained MFi readiness.

No iPhone was present during the initial Link checks. In a subsequent guided
test, a real iPhone enumerated directly on the host, started system usbmuxd, and
completed the trusted carkit open/close probe. After the user unplugged/replugged
the phone, it re-enumerated, retained trust and passed the same probe again. An
initial Untrusted result was followed by success without re-pairing. The phone used USB
configuration 4 with an `ipheth` network function; this does not establish the
required CarPlay USB-NCM transport. MFi probes still timed out until the user
power-cycled only LIVI Link. Its network reconnected automatically and the next
probe returned the expected 945-byte certificate and protocol major 2. The next
serial probe (with at least five seconds between requests) timed out again, and
further polling was stopped. Recovery is temporary; sustained MFi readiness and
real phone authentication remain unvalidated. These observations do not yet
distinguish a chip/service issue from a connection-lifetime interoperability issue.

Subsequent live work established that retaining the healthy MFi connection and
reusing its public certificate allows repeated real phone authentication. The
phone then completed AirPlay pairing, verification, auth-setup, SETUP and RECORD.
The first NCM function and a direct USB mux are required in configuration 6 because
system usbmuxd no longer enumerates the phone there. Session crypto has decrypted
real H.264 pictures; the native library logged a decoded 1280×720 BGRx sample and
successful IHS submission. The user reported a waiting screen, revealing a missing
presentation revision in the new Dart/native control adapter. That fix has an
automated regression check, and the user subsequently confirmed visible video
and correct app-icon/app-grid touch in Argo.

The phone subsequently re-enumerated and the initial configuration lease exited.
The test helper now follows the same phone across reconnects while its original
unprivileged supervisor lives, restoring normal configuration on owner exit.
The user identified an unstable cable during the disconnect tests. With a steady
connection, the user confirmed switching from CarPlay to an Argo dock page and
returning through Home restores the picture and working touch.

Earlier output-only tests failed on the iPhone XS running iOS 18 with Apple Music
Radio and Spotify: playback stays on the phone, no CarPlay destination appears in its output
picker, and no audio SETUP arrives at the receiver. The receiver advertises nine
format entries and observes main-audio ownership changes, which alone do not
establish an audio stream. Dzsibilee was paired using the host's existing BlueZ
controller, and the user confirmed an independently generated test tone through
that speaker. Thus host playback is verified separately from CarPlay audio.
Both 44.1 kHz and 48 kHz music formats are now advertised. A fresh authenticated
session with both rates still played on the iPhone; this did not resolve routing.
The user subsequently connected Corsair for the audio-negotiation comparison
and confirmed Siri and two-way call audio, including music restoration after
hang-up. Input remains disabled unless explicitly configured.

Camera-cover and wireless acceptance remain pending;
automatic physical replug with picture and touch has been confirmed. No attach-to-frame, CPU/GPU, drop or underrun numbers are claimed.
Automated AA regression is separate from physical AA acceptance.

Synthetic tests cover Link transactions, malformed/truncated/oversized replies,
deadlines, concurrency/cancellation, reconnection and Wi-Fi serialization; wired
fixtures combine carkit IO with the real client and a synthetic MFi server. Native
checks decode generated H.264/H.265 in both framings and check numeric SDR range
conversion. Daemon checks include repeated start/status/stop, owner exclusion,
socket cleanup and managed clean markers. None establishes iPhone/panel acceptance.

## Attribution

Heavily informed by **f-io / Lasse Heitgres — LIVI**, revision
`a23dc0c5fcdb6d069c679eddfd73298e58f44783`, version `9.0.0`.
See [CREDITS.md](../CREDITS.md) and the [architecture/license review](carplay-livi-review.md).
No upstream endorsement or imported implementation is implied.


## Supervised wired development mode

Build the daemon with the transport and audio features:

```bash
cargo build --locked --manifest-path native/carplay/Cargo.toml --all-features --bin argo-carplayd
native/carplay/target/debug/argo-carplayd --wired 1280 720 200 112 --audio YOUR_PULSE_SINK
```

Use the actual configured pixel and physical dimensions and an enumerated sink.
Omit `--audio` for video-only development. This mode uses the same live runtime as
`wired_session`, preserves pairing across process restarts, handles SIGTERM, and
keeps the existing diagnostics socket available. Diagnostics are sampled before
the session worker starts, then cached with their original timestamp: repeated
MFi health probes do not compete with authentication. Live session state remains
on the separate private projection control socket.

For a freshly built matched release, `record-build.py bundle` accepts
`--carplay-wired --projection-media-contract 1`. It verifies the daemon reports
wired capability. `argoctl` reads `~/.config/project-argo/carplay.json`:

```json
{
  "enabled": true,
  "width": 1280,
  "height": 720,
  "width_mm": 200,
  "height_mm": 112,
  "audio_sink": "YOUR_PULSE_SINK"
}
```

All fields are validated; the audio sink is optional. A wired-capable release uses
these arguments for the daemon and enables the CarPlay adapter in the app. Older
releases ignore this opt-in configuration, preserving rollback behavior. No
managed release has been selected as part of this development test. This does not
itself install USB permissions; use the automatic lease integration below.


## Automatic USB configuration lease

A reviewed, fixed helper can replace the manual PID-based sudo terminal. Install
its two system files once:

```bash
sudo python3 tool/carplay/install-permissions.py
```

The installer writes root-owned `/usr/local/libexec/argo-carplay-usb-lease` (0755)
and `/usr/share/polkit-1/actions/dev.argo.carplay.usb-lease.policy` (0644).
It changes no firmware, trust records, udev rules or sudoers entries. The helper
runs isolated Python, verifies the owner process belongs to the invoking user,
serializes leases, and only switches one locally enumerated eligible iPhone from
configuration 4 to already-exposed configuration 6. It waits for attachment and
follows that same phone across re-enumeration. Multiple phones or a different
replacement phone are not silently selected. Normal configuration is restored
when the daemon closes its private stdin pipe or its process exits.

Add `--usb-lease` at the end of the daemon's wired command, or set `"usb_lease":
true` in `carplay.json`. The desktop polkit agent asks for administrator
authentication (which polkit may cache). Denial or helper failure ends this daemon
invocation; it is not silently treated as a working lease. Stop any earlier
manual lease first and let it restore configuration 4.

The CarPlay systemd unit permits this authenticated `pkexec` child by setting
`NoNewPrivileges=no`; the daemon still runs as the desktop user, and other Argo
services are unchanged. No root helper command or filesystem path comes from
Flutter or the phone. Updated user units are needed for managed use.

Hardware-free helper/installer tests pass. The user installed the fixed helper
and policy; a live run selected configuration 6, and SIGTERM restored
configuration 4 in about 130 ms. Tokio child monitoring is regression-tested to
retain stdin until explicit release. Following a Link power-cycle to recover an
MFi timeout, the new automatic lease completed real authentication and resumed
video. The user confirmed that unplugging/reconnecting the iPhone automatically restored
picture and touch with no manual sudo lease. Full managed-service and long-running
reconnect acceptance remain pending.
To remove the integration, first stop wired CarPlay and then remove the two fixed
system files above; disable `usb_lease` in the configuration.


Audio feedback now uses the same monotonic, phone-adjusted clock as the timing
exchange. Before any audio stream has been negotiated, feedback is an empty
acknowledgement, matching the pinned reference's behavior. These changes have
synthetic regression checks. A live session confirmed timing synchronization, but
the user still heard Apple Music Radio on the iPhone. A subsequent Spotify test
also played on the iPhone, ruling out a Radio-only failure. These changes did not
resolve the missing audio route.


### Audio input capability comparison

With the Corsair microphone explicitly selected through
`ARGO_CARPLAY_MICROPHONE=YOUR_PULSE_SOURCE`, the same receiver advertised four
PCM input entries alongside its nine output entries. The iPhone then negotiated
stream type 100, format `0x800` (44.1 kHz stereo PCM), category `media`; authenticated
packets arrived and the native playback stream targeted Dzsibilee. The phone
then displayed CarPlay as an audio destination. The microphone is not implicitly selected from
camera capture devices or a speaker monitor. This result does not establish Siri
or call microphone acceptance, nor that every iOS version requires an input.

The comparison also exposed a teardown interoperability bug: iOS can identify an
audio stream by `type` without repeating `streamConnectionID`. Argo now accepts
that selector, releases only matching audio streams, and rejects malformed or
empty selectors. Regression tests cover type-only teardown and signed connection
IDs. The all-features suite passes 69 tests; clippy passes with warnings denied.

Negotiation exposed a second problem: nonzero samples reached a full-gain stream,
but its PulseAudio output remained silent. Bluetooth initially also failed an
independent test tone; reconnecting Dzsibilee restored that tone, but music stayed
silent. Selecting `GstSystemClock` alone did not fix music. Adding explicit
`clocksync` pacing before a nonsynchronizing PulseAudio sink produced nonzero
speaker-monitor samples, and the user then confirmed Spotify and pause/resume
working. The bounded pipeline retains system-clock timing and per-stream gain.
A hardware-free GStreamer test verifies muted/unmuted PCM reaching the output
with advancing timestamps. Diagnostics expose packet count, sample peak, gain,
queue bytes and timing lag, without recording audio content.

For this tested iOS 18 setup, keep a real input explicitly configured as well as
the output. For a foreground development run:

```bash
ARGO_CARPLAY_MICROPHONE=YOUR_PULSE_SOURCE \
  native/carplay/target/debug/argo-carplayd \
  --wired 1280 720 200 112 --audio YOUR_PULSE_SINK --usb-lease
```

The initial test used an explicit Corsair source and Dzsibilee sink. The later
managed release integrates selection with Sound settings, as described below.


### Siri, microphone policy and ownership

The dedicated Siri control sends button-down action 2 and button-up action 3;
the legacy local click command emits both edges. These actions follow the pinned
LIVI `cpStack.ts::invokeSiri` interoperability reference. A real iPhone recognized
“What time is it?” through Corsair and answered through Dzsibilee, then returned
to music. This is Siri acceptance for the tested PCM input, not wireless/Opus.

`--microphone PULSE_SOURCE` now selects a validated source with `--audio`; managed
`carplay.json` accepts the corresponding `audio_source` field. The development
environment variable remains a fallback. The shared Sound input selector now updates the live capture source and saves it
for future sessions. Capture stops and clears pending samples before changing
the native source, then reacquires the shared microphone lease.
The updated Flutter adapter forwards the existing shared microphone mute state to
the matched receiver. Mute stops capture and clears pending PCM; the playback gain
remains independent. During a real CarPlay call, the user confirmed that the
Calls page’s “Mute microphone” switch stopped the other person hearing them,
and that unmuting restored their voice.

The new `native/audio-ownership` library holds a private, nonblocking desktop-user
file lock for microphone capture. Updated AA/HFP and CarPlay capture paths use the
same lock and release it only after stopping capture. Uncertain cleanup retains
exclusion until process exit. **Both daemons must be rebuilt/deployed** for this
cross-process exclusion; an older AA binary does not participate. The selected
`carplay-settings-v7` release contains both updated daemons. No root permission
or device rule is added for microphone ownership.


The user subsequently confirmed a clear two-way CarPlay call through Corsair and
Dzsibilee, with Spotify resuming after hang-up, but reported echo. A follow-up
build now adds WebRTC echo processing to the PCM duplex path. Playback reference
and microphone DSP share one top-level GStreamer pipeline at 48 kHz; capture is
resampled back to the phone's negotiated PCM rate. A locked capture bin remains
NULL until the microphone lease and policy permit capture. The synthetic duplex
test checks reference association and bounded PCM output. In a repeat call with the Bluetooth speaker near the Corsair microphone, the
user reported the result was good when asked about remote echo and voice clarity.
This confirms the tested setup; no quantitative echo reduction is claimed, and
this does not cancel unrelated audio produced outside the CarPlay stream.

The echo path follows the installed plugin's documented requirements:
[GStreamer webrtcdsp](https://gstreamer.freedesktop.org/documentation/webrtcdsp/webrtcdsp.html).
`webrtcdsp` and `webrtcechoprobe` are required when configuring microphone input.

Validation after the echo-processing change: 76 native CarPlay tests pass with
all features enabled; nine USB/VHCI helper and installer tests pass. Wireless
HCI framing and descriptor-handover modules remain unintegrated foundations,
not a working wireless session. The optional VHCI permission helper has not
been installed or exercised against the real controller.


### Managed UI and settings acceptance (2026-09-20)

`carplay-settings-v7` is the selected release. The user units and installed
`argoctl` were updated. All three units became active, all wrote `clean` on an
explicit managed stop, and all restarted successfully. The previous camera
renderer and external camera integration remain in the matched bundle.

Settings now opens the CarPlay destination when CarPlay is configured. The live
1600×1200 screenshot and the 1280×720 widget check both show the CarPlay section;
Android Auto preferences have a separate destination. The obsolete “sessions are
not implemented” message is gone. System volume controls use PipeWire.

The private `project-argo/carplay-settings.sock` remains available without a phone.
Configuration is bounded and validated, saved atomically with mode 0600 in
`$XDG_STATE_HOME/argo-carplay/settings.json` (default `~/.local/state`). CLI/deployment
configuration supplies first-run defaults. Explicit disconnect pauses retries;
Connect resumes them. Display edits wait for reconnect. Shared source selection
is saved for subsequent sessions and delivered to active native capture by
session-scoped IPC. No media samples or Wi-Fi secrets pass through Flutter.

On this host, an unrelated Corsair output emits malformed `audio.position` JSON
in `pw-dump`. Microphone enumeration falls back to the bounded PulseAudio source
inventory, excluding monitors and Bluetooth inputs. Bluetooth route cleanup reads
only PipeWire Link objects, so unrelated malformed node properties cannot falsely
report an owned-route leak. Two earlier failed-start/cleanup records were inspected
and archived in `~/.local/state/project-argo/recovery-*`; no failed result was
rewritten as clean. The subsequent real managed stop recorded clean results.

Unattended startup checks USB authorization without displaying a password prompt.
If it is missing, the settings page reports “USB permission required”. An explicit
Connect action can launch the existing narrow polkit USB lease. This does not
install a permanent passwordless grant. At the final check, all services were running and the receiver was disconnected.
The fresh USB authorization requirement had been shown during startup. No new
phone/panel acceptance is claimed for the final disconnected state.

Validation: 325 Flutter tests passed, seven skipped; 78 native CarPlay tests;
88 AA daemon tests; 16 deployment tests and nine permission-helper tests. Flutter
analysis and native Clippy checks pass. Real managed configuration save/readback,
invalid-setting rejection, restart persistence and clean lifecycle were exercised.

### Wireless work still outstanding

The prepared Link accepts a TCP connection to its dongle-side iAP control service
(5005). The independently implemented `dongle_iap` module bounds the 5004 handoff
header, validates the phone/controller identities, and preserves the first iAP2
byte. This provides an alternative to owning the controller through `/dev/vhci`;
it is not an integrated wireless receiver. Neither this endpoint nor the HCI
bridge is opened by diagnostics or normal wired operation.

The explicit `wireless_controller --controller-only` example can exercise the
HCI bridge after installing its separate VHCI permission helper. That helper is
not installed on this host; noninteractive administrator authorization is not
available. The prepared firmware was not changed.

Complete wireless operation still needs AP credential ownership/restoration,
wireless identification and Wi-Fi configuration exchange, handoff lifecycle,
AirPlay listener admission, pairing/reconnect UI, and a real wireless phone test.
The dongle-owned handoff path can avoid host VHCI privilege, but does not remove
these implementation and physical-pairing requirements. Wireless is therefore
reported as unavailable in the product UI rather than offered as a working mode.
