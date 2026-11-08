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
| `argo-carplayd` | Unprivileged diagnostics plus opt-in supervised USB/wireless `--receiver` (`--wired` alias) |
| Link library | Bounded persistent MFi connection, same-connection public certificate cache for authentication, no signing retry |
| Wired control | Trusted carkit, direct USB mux, real MFi, typed iAP2 identification and StartSession |
| USB network | Userspace NCM, temporary NetworkManager TAP, narrow administrator USB configuration lease |
| AirPlay receiver | SRP pairing, pair verification, real MFi auth-setup, encrypted control/events, authenticated H.264 main screen |
| Native media | ARPM/1 into existing GStreamer/GBM/IHS surface; shared library also supports synthetic H.265 fixtures |
| Flutter adapter | Private metadata/input IPC, session selection, visibility, presentation revisions, normalized two-contact touch |
| Audio | PCM Spotify playback through Dzsibilee and pause/resume physically confirmed with Corsair input configured; Siri and clear two-way calls with music restoration confirmed; echo processing and shared microphone mute/unmute physically confirmed; AAC acceptance pending |
| Wireless | Current LIVI Link HCI/VHCI, selected-controller BlueZ iAP2, Wi-Fi bootstrap, interface-scoped AirPlay advertisement and the shared native receiver; physical acceptance is recorded separately |

The managed application, AA daemon and CarPlay daemon have explicit startup,
readiness and owned-cleanup contracts. CarPlay settings and shared microphone
selection are implemented.
Fresh USB authorization, wireless sessions, metadata, cluster and long-running
physical coexistence acceptance remain separate limitations. Unsupported features
must not be described as usable based on the reference implementation.

### Shared audio selection and wireless codecs

Before connecting a phone, CarPlay synchronizes the confirmed shared output from
Sound settings. Polling updates preferences for the next connection without
restarting an existing session. A fresh microphone inventory confirms the selected
input; an unplugged input is removed from CarPlay's advertised capabilities while
its remembered application selection is retained for reconnection. Unknown or
failed inventory never selects another input or a speaker monitor.

The native receiver supports PCM and AAC-LC music, plus mono Opus speech, calls
and alerts at negotiated 16, 24 or 48 kHz. Opus RTP timestamps and feedback use a
48 kHz clock. Microphone Opus encoding shares the existing echo-processing and
capture-ownership path. Synthetic GStreamer tests cover decoding, encrypted
uplink packets, frame bounds, timing and cleanup; wireless audio still requires
physical acceptance on the target phone and output.

## Topology and ownership

For wired CarPlay, the iPhone belongs on a host USB port. Its usbmux/lockdown carkit stream
carries iAP2; a separate phone USB-NCM path carries AirPlay. The prepared LIVI Link
is a network accessory providing the real MFi authentication IC. Its NCM network
is independent of the phone's USB network. Normal Linux wired operation does not
use the dongle USB proxy. The upstream reference explicitly describes dongle OTG
as macOS-only.

The CarPlay runtime never flashes, provisions, restores or repartitions the Link,
extracts keys or emulates MFi. Device firmware maintenance is a separate operation
using the official model-matched updater and a verified backup. No LIVI application
is launched. The native
Rust process isolates development from AA transport/audio/connectivity; Flutter
receives metadata only. The existing native view uses GStreamer, GBM buffer
mapping/copy and IHS PlatformViewLayer; zero-copy is not claimed.

Radio ownership is independent of MFi use. Diagnostics never enable/disable AP or
Bluetooth and never open HCI/handoff transport ports, which can acquire ownership.
An already-running dongle AP is reported without being claimed by diagnostics.
Explicit wireless mode owns the Link radio lifecycle and releases its controller
after session cleanup; it does not take over the host's internal AA controller.

Wireless discovery uses the native `mdns_advertisement::Advertisement` owner and
the installed Avahi daemon's system D-Bus API. Host policy must allow the desktop
user to create an EntryGroup; D-Bus may activate an installed Avahi service.
Publication is restricted to the caller-selected Link NCM interface and IPv4,
with Avahi's default host/address records on that interface. The service name is
at most 63 UTF-8 bytes; the port and interface index must be nonzero. Its AirPlay
TXT records use the same Bluetooth MAC, persistent pairing identifier and public
key as the receiver handshake, the receiver's source version, and model `Argo`.
The pairing identifier is an opaque nonempty string of at most 128 UTF-8 bytes
without control characters; existing key-derived MAC identifiers are preserved.
No network password is advertised.

Bus connection has a three-second limit and publication has an eight-second
limit, including the wait for Avahi's host records and EntryGroup established
state. Collision and failure
states fail publication. Callers must await `close()` before releasing the
network interface. It frees only its own EntryGroup and always attempts to
disconnect its private bus connection, including after a Free error; cleanup
takes at most three seconds. Cancellation/drop schedules the same bounded
cleanup on Tokio, with client-disconnection cleanup when no runtime remains.
This discovery adapter does not establish wireless phone acceptance.
`wait_lost()` checks the original Avahi bus owner and host/EntryGroup readiness
every second, with a two-second check limit. Loss ends the owned wireless
session so the runtime can rebuild discovery. Group operations, including Free,
remain pinned to the original unique bus owner across an Avahi restart.

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
are written only after cleanup. Diagnostics-only mode starts no audio, microphone, USB, AP or VHCI resource.
The complete receiver has a separate settings/control contract and explicit
transport selection. Its network health is refreshed every five seconds without
touching the MFi connection during authentication; certificate/protocol checks
run before session bootstrap. Health includes a separate MFi check timestamp.

The Devices hub owns phone connection intent through DeviceConnectionService.
Each physical phone appears once, with a CarPlay, Android Auto or Bluetooth type
and device Connect, Disconnect and Forget actions. Add iPhone explicitly prepares
the configured USB or wireless receiver for pairing. Unknown phones require a
type choice; matching aliases never merge them. Wireless CarPlay identity is
joined to the matching Bluetooth address using the native address-derived ID.
A USB identity can be linked to its saved Bluetooth phone through explicit user
confirmation in Devices. CarPlay settings configure the receiver without separate
Connect, Reconnect or Disconnect buttons.

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
failure restart delay, three starts per 90 seconds and a 35-second stop limit.
Older releases still validate and the unit's file condition skips them. Selection
and rollback include the optional service without coupling its crash to AA.
Bundles containing diagnostics enable the health card by default; managed common
environment `ARGO_CARPLAY_DIAGNOSTICS=0` hides it.


## Wireless CarPlay with current LIVI Link

The receiver supports **USB cable** and **Wireless · LIVI Link** in CarPlay settings.
Changing the method stops and cleans up the preceding session. Connect the phone
again from Devices to use the selected method; changing this preference alone
does not launch the receiver. The connection choice is persisted separately in
`connection.json`, so the older wired `settings.json` remains readable on rollback.
The managed launcher selects the complete `--receiver` entry point for releases
with `carplay_wireless=1`; `--wired` remains a compatible entry-point alias.

Wireless uses Link TCP 5002 HCI over a dedicated `/dev/vhci` descriptor. BlueZ
publishes iAP2/CarPlay profiles; callbacks accept only the created Link adapter.
The transport registers no separate pairing agent. In the managed Argo stack, the shared
BlueZ agent held by `argo-projectiond` owns incoming pairing/authorization and
shows the request in Argo's global Flutter overlay, including while using
CarPlay. Keep the shared connectivity daemon and app running for those prompts;
a standalone CarPlay process relies on whichever default agent is already present.
The user pairs **Argo CarPlay** in iPhone Bluetooth settings and accepts CarPlay.
The removed dongle-owned TCP 5004/5005 handoff is not used with current firmware.

The host needs BlueZ, Avahi's system D-Bus service, a working Link NCM route,
and kernel `hci_vhci` support. Install the separate, root-owned VHCI helper and
polkit action once; this does not install firmware or change device permissions:

```bash
sudo python3 tool/carplay/install-permissions.py --wireless
```

The helper opens only `/dev/vhci`. If it is absent after boot, it invokes only
the verified root-owned `/usr/sbin/modprobe hci_vhci`, with a five-second limit,
then retries open once. It loads before the bounded descriptor handover begins.
There is no broad udev rule, shell command, module argument or executable path
supplied by the receiver. The kernel module must be available on the host.

By default, opening this controller requires administrator authorization through
the desktop polkit agent; a cached authorization is not a permanent reboot grant.
An administrator can explicitly allow only the intended active local desktop
account to open its own virtual controller without a repeated prompt:

```bash
sudo python3 tool/carplay/install-permissions.py --wireless \
  --wireless-desktop-user YOUR_DESKTOP_USER
```

Replace the account placeholder with an existing non-root account name. This
adds root-owned `/etc/polkit-1/rules.d/49-argo-carplay-vhci.rules` (0644), scoped
to the fixed helper, VHCI action and named active local account. Remote/inactive
callers and other accounts are denied that action; USB and other polkit actions
keep their own policy. This grants that account's local processes access to a
private virtual Bluetooth controller, not arbitrary root execution. The helper
still validates its direct parent, private socket peer and owner start time.
Verify the actual managed process's authorization and a real reboot separately;
session classification must fail closed when the caller is not active and local.
Reinstalling without this option leaves an existing rule unchanged. Remove that
fixed optional rule to return to the administrator-authentication default.

The host retains one private, stable `wireless-network.json` (0600) with a unique
Argo-CarPlay SSID and random passphrase. It applies this explicitly selected
CarPlay network to the Link without `save`, preserving the current reported
country and channel. The firmware's disk fallback is unchanged. On exit Argo
restores the previous AP/Bluetooth **power states**; it cannot restore an unknown
previous live passphrase. Credentials are passed natively to iAP2 and never enter
Flutter status or logs. Display fitting and input retain the same shared native
pipeline as wired CarPlay.

The reliable Bluetooth iAP2 engine is vendored from LIVI with its GPL license,
additional attribution notice, upstream tests and exact revision provenance.
**Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).** Native release
bundles contain its notices and a corresponding-source archive. This is explicit
source reuse, not a claim of a clean-room implementation.

On 2026-11-07 the attached i.MX6ULL/IW416 Link was updated with the official
10.4.0 / `199cbec5` bundle after a complete, remotely checksum-verified 16 MiB
partition backup and successful dry runs. The resulting status reports target
`imx6ul_iw416`, kernel 7.3.1 and a ready MFi protocol-2 coprocessor. USB ID
1314:1520 alone does not distinguish this hardware from other Link targets.
This device update is not part of application startup or a blanket firmware
update recipe for other dongles.

## Remaining implementation and permissions

The shared `wired_runtime` is now used by both the example and `argo-carplayd
--wired`. The daemon retries failed sessions with a delay of 2–30 seconds, resets
backoff after a minute-long session, and stores pairing under
`$XDG_STATE_HOME/argo-carplay` (default `~/.local/state/argo-carplay`). It owns one
receiver at a time and cleans up session resources before retrying.
The native receiver advertises its implemented two-contact touch HID. Siri uses
its dedicated press/release commands. Rotary and other generic projection buttons
are unsupported and return an explicit error; they do not report silent success.

Native control admission is bounded. Activation reserves both keyframe and audio
release commands before changing presentation state. A rejected touch-down does
not allocate a contact; a rejected show request retains the previous visibility.
If an accepted contact cannot be released (up, cancel or hide), the session is
cancelled through its independent watch channel and requires reconnection.
Disconnect uses that same path even when the input queue is full or closed.
Stale session IDs and new commands after cancellation are rejected. These queue
failure paths have automated coverage; phone-side teardown still needs physical
acceptance under load.

Device Disconnect stops that phone's receiver, pauses its retries and disconnects
the Bluetooth endpoints belonging to its row. Other devices remain connected.
The native manager starts passively after every restart, including when enabled
and its retry preference are saved. One shared Devices startup switch may request
only the selected known phone; enabling CarPlay alone does not connect it.
The CarPlay auto-connect preference controls retries after an interrupted selected
connection, rather than creating a separate login-time request. Switching phones
waits for confirmed cleanup before starting the replacement.

The daemon has authenticated with the real phone and served negotiated H.264 to
the Argo consumer. A physical replug automatically restored authentication and
video transport, but the user initially saw a waiting screen. Home now activates
an unselected replacement session when it becomes ready, without activation on
other pages. A second replug exposed an empty screen configuration message; that
exact message is ignored without consuming a frame nonce or authorizing video.
The native screen receiver allows 30 seconds after accepting the screen connection
for its first authenticated usable keyframe. Empty/control packets, repeated codec
configuration and delta frames cannot extend this deadline; partial header/body
reads keep the same deadline. Expiry ends the owned session through normal cleanup
before the daemon retries. Once a usable keyframe arrives, only the existing
15-second header and three-second body inactivity limits apply. These paths have
synthetic asynchronous regression coverage; they still require phone acceptance.
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

CarPlay has a dedicated configuration destination with persistent enable,
interrupted-connection retry, resolution, 30/60 fps and driver-side preferences.
Connection actions belong to the physical-phone row in Devices. Display changes
apply when that phone is connected again.
The managed receiver snapshots the latest viewport and preferences when the
phone's AirPlay connection arrives after USB preparation, then freezes them for
that connected session.
The shell forwards the same safe-area-aware dashboard measurement to both AA and
CarPlay. CarPlay negotiates a balanced View Area inside the selected encoded tier,
including taller content on a 3:4 host. Its Safe Area reserves the closed media
controls without cropping map pixels. Native ARV2 metadata removes only negotiated
view margins, and touch adds the view origin back to the full-display HID axes.
Resizing an active connection aspect-fits its frozen content; reconnect applies
new geometry without an automatic phone disconnect.

The private settings socket advertises `viewport_supported: true` and accepts
`{"action":"viewport","viewport":{"width":600,"height":680,"overlay_height":64}}`.
These logical-pixel measurements are runtime hints, debounced by the client for
150 ms and restored after daemon restart. Width/height must be finite in
1–65536; overlay height must be finite, nonnegative and less than height.
They never persist settings, enable CarPlay or restart a session. Older daemons
continue without automatic fitting and the settings page reports the update needed.
`next_view_insets` and `next_safe_insets` in status describe the next negotiation,
in encoded pixels. Native `settings.json` optionally stores manual
`view_insets` / `safe_insets` arrays in left/top/right/bottom order (default all zero,
omitted when zero so ordinary settings updates remain readable by older releases);
safe margins are relative to the view. AirPlay advertises their absolute rectangle
origins. Invalid margins must leave at least two view pixels per axis and a
nonempty safe rectangle; the whole patch is rejected before persistence.

The shared Devices catalog remembers physical phones, protocol types and confirmed
projection identities. Forget removes the phone's catalog entry and available
Bluetooth bonds; a missing controller must return before its bonds can be removed.
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

Heavily informed by **f-io / Lasse Heitgres — LIVI**. Initial protocol research
used `a23dc0c5fcdb6d069c679eddfd73298e58f44783` (9.0.0); the vendored reliable
iAP2 engine is from `bfbea31ee624ddce84bfa96ce49d4663e6cdeca7`.
See [CREDITS.md](../CREDITS.md) and the [architecture/license review](carplay-livi-review.md).
Its GPL license, attribution notice and corresponding source accompany native
distribution. No upstream endorsement is implied.


## Supervised wired development mode

Build the daemon with the transport and audio features:

```bash
cargo build --locked --manifest-path native/carplay/Cargo.toml --all-features --bin argo-carplayd
native/carplay/target/debug/argo-carplayd --wired 1280 720 200 112 --audio YOUR_PULSE_SINK
```

Use the actual configured pixel and physical dimensions and an enumerated sink.
Omit `--audio` for video-only development. This mode uses the same live runtime as
`wired_session`, preserves pairing across process restarts, handles SIGTERM, and
keeps the existing diagnostics socket available. MFi diagnostics are sampled
before session bootstrap and cached with their check timestamp; network status
continues refreshing without competing with authentication. Live session state remains
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
managed release selection is performed by this foreground command. This does not
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
cross-process exclusion; an older AA binary does not participate. The earlier
`carplay-settings-v7` deployment included both updated daemons. No root permission
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

Synthetic duplex tests cover echo-reference association and bounded microphone
output. Wireless now uses the integrated HCI/VHCI, BlueZ and shared receiver
path described above; wired echo acceptance does not establish wireless audio
or complete wireless phone acceptance.


### Managed UI and settings acceptance (2026-09-20)

During that acceptance run, `carplay-settings-v7` was selected. The user units and installed
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

### Wireless physical acceptance

Wireless mode uses the current Link HCI service and host BlueZ profiles. The
legacy `dongle_iap` codec is retained for historical research but is not an
alternative transport offered by the current receiver. Diagnostics and wired
operation do not acquire the HCI bridge.

On 2026-11-08 a real iPhone completed Bluetooth iAP2/MFi authentication, Wi-Fi
handover, AirPlay pairing/authentication and H.264 video through LIVI Link. The
user confirmed the picture, taps and map dragging on the portrait display, and
confirmed that the Devices inventory remains stable.

Two actual blockers were isolated: the phone's valid 127-packet link window had
been rejected, and the updated Link's physical MFi register reads returned a
corrupt certificate length after the first long read. The compatibility service
in [native/link-mfid](../native/link-mfid) primes an immutable register before
reselecting and reading the target. The stock firmware failed the second read
after a power cycle; the patched service passed eight consecutive PKCS#7 checks
and the phone accepted a real hardware signature. The underlying I2C/kernel cause
is not established by this workaround.

The initial acceptance used the RAM prototype. The `argo-mfi-prime-20261108-4`
image was subsequently installed with the official rescue updater and verified
after reboot: `/usr/bin/argo-mfid-prime` 0.1.1 started automatically, wrote the
real Gen2 status marker, and passed another eight consecutive PKCS#7 checks.
The phone then completed Wi-Fi/AirPlay setup again and negotiated 1280×720 video.
The official kernel and original LIVI multicall binary are unchanged; full
corresponding source and attribution are included in the firmware.

The user deferred wireless audio output testing to another audio source. Calls
and long-running coexistence remain separate acceptance items. The final host
release also separates Wi-Fi monitoring from the MFi operation lock, retains
the controller across phone reconnects, and displays actual connection progress.
