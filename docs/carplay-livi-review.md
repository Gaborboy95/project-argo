# LIVI reference and Argo integration review

The current reference is [f-io/LIVI at
bfbea31ee624ddce84bfa96ce49d4663e6cdeca7](https://github.com/f-io/LIVI/tree/bfbea31ee624ddce84bfa96ce49d4663e6cdeca7),
the `main` revision reviewed on 2026-11-07. Its Rust workspace declares version
`10.5.0` in development; the latest stable release is `10.4.0`. Repository
metadata, the source tree and commit diffs were read through GitHub and an
isolated source checkout. Argo vendors the standalone iAP2 link engine from this
revision; the complete LIVI application is not a build dependency.

The original interoperability research used [LIVI 9.0.0 at
a23dc0c5fcdb6d069c679eddfd73298e58f44783](https://github.com/f-io/LIVI/tree/a23dc0c5fcdb6d069c679eddfd73298e58f44783).
Existing module provenance references that revision unless stated otherwise.

The [protocol source map and implementation notes](carplay-protocol-review-notes.md)
record exact reviewed areas, the experimental carkit API, USB-NCM prerequisites,
certificate pinning, media formats and the remaining AirPlay integration work.

## Component boundaries

Current LIVI uses a Rust workspace under `native/crates` and a Slint UI.
`livi-core` owns application projection state and policy, `livi-cp` owns CarPlay
management, AirPlay control/pairing, event channels and streams, `livi-aa` owns
AA transport, and `livi-aa-stack` owns its channels and negotiation. Shared
`livi-runtime`, iAP2, audio and video crates provide native services.

The older 9.0.0 architecture used an Electron/TypeScript session manager around
a Rust helper and native GStreamer workers. Historical references below to
`CpManager`, `CpSession` and `cp/stack` describe that pinned version; their
current counterparts are `livi-cp/src/manager.rs`, `livi-core/src/projection`
and `livi-cp/src/stack`.

Argo retains Flutter, Rust, GStreamer and IHS. A separate `argo-carplayd` keeps
CarPlay failures and protocol dependencies out of `argo-projectiond`; it does not
replace the AA daemon or launch LIVI/Electron. The application-facing projection
contracts already have CarPlay protocol types. A multiple-backend facade and an
explicitly versioned encoded media contract are preferable to duplicating the
surface or silently changing AA IPC7. Flutter owns presentation and selects a
session; video reception must not acquire foreground ownership. Reverse camera
remains a higher local priority. Native audio and microphone ownership require
integration with existing focus/capture policy, not new Dart media paths.

## Current Rust review and applicable changes

| Area | Pinned upstream evidence | Argo implication |
| --- | --- | --- |
| CarPlay safe/view geometry | [safe-area fix `e053cfd`](https://github.com/f-io/LIVI/commit/e053cfd76939c9c7a91deb943e6a691525d5fe07), `native/crates/livi-cp/src/info.rs` | Advertise actual stream dimensions and `viewAreas`; every absolute safe inset must be at least its corresponding view inset. The nested safe rectangle uses display coordinates. Merely cropping Flutter cannot change the phone's layout. |
| Physical display orientation | [projection fix `5bf2d6d`](https://github.com/f-io/LIVI/commit/5bf2d6da471dff4f83d5ec4afc39780e8cb17bc4), `native/crates/livi-core/src/carplay.rs` | Physical millimetres must have the same orientation as the negotiated projection. Upstream's landscape default on a portrait panel is a default policy, not evidence that portrait negotiation is unsupported. |
| AA portrait content | [`livi-aa-stack/src/config.rs`](https://github.com/f-io/LIVI/blob/f6bcc810236cd2e0a3d338f51d923149f96c3ae4/native/crates/livi-aa-stack/src/config.rs) | Keep a supported encoded video tier; fit the requested content aspect inside it using centered margins plus view insets. Use the same resulting content rectangle for rendering and input. View/safe fields have different purposes and cannot add pixels outside the encoded frame. |
| AA input timestamp origin | [LIVI `protocol.rs` at `bfbea31`](https://github.com/f-io/LIVI/blob/bfbea31ee624ddce84bfa96ce49d4663e6cdeca7/native/crates/livi-aa-stack/src/protocol.rs), [OpenAuto `InputService.cpp`](https://github.com/f1xpl/openauto/blob/833cc43e9e8f27c131cbb00348b1913f8e40a1cc/src/autoapp/Service/InputService.cpp), specifically reviewed on 2026-11-07 | Both send epoch-based microseconds for input reports. Argo uses this clock for touch/media-key reports, while retaining monotonic session clocks for timeouts and pings. Matching enum values and a self-consistent serializer test alone cannot verify the runtime timestamp origin; the memory-TLS session regression checks an actual report against an independent epoch bracket. This protocol difference alone does not establish physical gesture acceptance. |
| AA microphone startup order | [LIVI `channels/mic.rs` at `bfbea31`](https://github.com/f-io/LIVI/blob/bfbea31ee624ddce84bfa96ce49d4663e6cdeca7/native/crates/livi-aa-stack/src/channels/mic.rs) and its fresh-channel open test | Microphone requests need not follow AV setup. Argo accepts them on an admitted channel using its sole advertised PCM format; unavailable host capture receives a microphone failure response without tearing down video. The memory-TLS regression verifies early open/close, occupied capture and continued video acknowledgements without opening hardware. |
| OPPO wired discovery | [USB fix `a9aa9cf`](https://github.com/f-io/LIVI/commit/a9aa9cf4d7b3a2ca1fbe1d2ea7b893759e172cee) | Argo now recognizes vendor `0x22d9` through its existing MTP candidate filter. ADB remains the other explicit candidate path; the vendor addition does not probe arbitrary USB peripherals. `GET_PROTOCOL` still decides AOAP support. |
| Stalled wired startup | [recovery fix `ab133cd`](https://github.com/f-io/LIVI/commit/ab133cdaf73e2434682d319844709a79459befb0), current `livi-cp/src/manager.rs` | Upstream waits for main video before showing projection, limits start retries and resets a stuck phone's USB once. Argo already retains connection UI until video is ready and has bounded startup deadlines. A physical USB reset is not adopted: it needs integration with Argo's separate privileged USB lease and cleanup ownership. |
| UI input ownership | [focus fix `c33e4fb`](https://github.com/f-io/LIVI/commit/c33e4fb3a8ae3e59c6eacc2e74817bbeb120647d), `livi-ui/src/main.rs` | Navigation and modals must explicitly transfer input ownership. Existing Argo gesture cancellation and stable native view ownership remain the integration boundary. |
| Wireless Link topology | [dongle accessory removal `c85b50f`](https://github.com/f-io/LIVI/commit/c85b50f80ce503fedfee1728f17756358c839c8a), `livi-helper/src/bluez.rs`, `livi-runtime/src/bt.rs` | Current Linux wireless CarPlay uses HCI on TCP5002, a host VHCI adapter and BlueZ iAP2 profiles. The old TCP5004/5005 handoff services have been removed; production startup must not depend on them. |
| Reliable Bluetooth iAP2 | [`iap2-link/src/lib.rs`](https://github.com/f-io/LIVI/blob/bfbea31ee624ddce84bfa96ce49d4663e6cdeca7/native/crates/iap2-link/src/lib.rs), `livi-runtime/src/livi_sock.rs` | Bluetooth uses acknowledgement windows, retries and sequence recovery. Argo vendors this engine and uses it for wireless bring-up; its wired zero-ACK control path stays separate. |
| HCI loss detection | [tunnel sharing `2562d3d`](https://github.com/f-io/LIVI/commit/2562d3d52a5e7996d67edff2d9cc7e6dccbcaba7), `livi-net/src/tunnel.rs` | Argo's HCI tunnel enables short TCP keepalive and a three-second TCP user timeout so a vanished Link can release its virtual controller. No host-wide Bluetooth restart is required. |

The CarPlay geometry wire contract is `displays[].viewAreas[]` with
`widthPixels`, `heightPixels`, `originXPixels`, `originYPixels` and a nested
`safeArea` containing the same rectangle fields and optional
`drawUIOutsideSafeArea`. `viewAreaStatusBarEdge` is optional. View insets remove
unavailable video edges; safe insets reserve host overlays inside the remaining
view. Argo's new geometry integration is independently implemented against that
contract; no upstream implementation or test vectors are imported.

Upstream also has multi-session handover, additional audio/video codecs, wireless
CarPlay, cluster streams, CarPlay Ultra vehicle state, rotary UI navigation and
Android support. Those require separately implemented Argo capabilities and
hardware acceptance; this review does not present them as shipped Argo support.

## LIVI Link services verified in source

| Endpoint | Upstream source | Purpose |
| --- | --- | --- |
| `livi-link.local` | `livi-link-host/src/link.rs`, `livi-mdns` | Interface-specific IPv4 mDNS discovery |
| TCP 5000 | `iap2-mfi/src/{ncm,server}.rs` | Actual authentication IC certificate/sign/protocol-major operations |
| TCP 5001 | `livi-wifid/src/server.rs` | Line-oriented Wi-Fi and Bluetooth control |
| TCP 5002 | `livi-link-host/src/bt.rs`, `livi-btd/src/linux.rs` | Length-prefixed HCI traffic to Linux `/dev/vhci` |
| TCP 5003 | Absent from current `livi-net/src/port.rs` | Historical USB proxy, not a current Linux transport |
| TCP 5004/5005 | Removed by `c85b50f` | Historical dongle-owned iAP/accessory services; not a current wireless bootstrap path |

MFi operations are one-byte opcodes 1 (certificate), 2 (sign), 3 (protocol
generation). Sign appends a big-endian u16 length and 1–128 challenge bytes.
Replies contain status:u8, length:u16 big-endian, then data; status zero succeeds.
Protocol generation is one byte. CP2.x/CP3 refer to the returned major; the dongle
may infer that major from public certificate size if its IC register is unreliable.
This is reported as a remote result, not independent chip identification. The host
never receives or extracts the chip's private key.

Wi-Fi replies terminate with `ok` or `error …`. `set` values are connection-local
pending configuration, so a typed apply transaction must retain one connection.
`save` persists dongle configuration and is not needed for diagnostics or wired
CarPlay. A reachable TCP port does not prove protocol readiness. In particular,
opening 5002 acquires a controller transport; diagnostics must avoid that probe.
Status does not return the AP passphrase, so it cannot establish a complete
previous-network restore configuration. Explicit wireless setup uses private,
stable Argo credentials without `save`, preserves the reported country, and
tracks the selected Link radio power state separately. It must not claim that
unknown previous credentials can be reconstructed from status.

The current Linux Bluetooth profile set is the iAP server UUID
`00000000-deca-fade-deca-deafdecacaff` on RFCOMM3, the iAP client UUID ending
`cafe`, and CarPlay's `ec884348-cd41-40a2-9727-575d50bf1fd3` SDP service on
RFCOMM4. Profiles must reject connections from other host adapters. After MFi
authentication, the Bluetooth control channel answers Wi-Fi configuration
requests `0x5702` with `0x5703` and starts CarPlay with wireless attributes in
`0x4301`. Wi-Fi configuration security value2 and StartSession's optional
security field are different enums: WPA2 omits the latter, WPA2/WPA3 transition
uses3, and WPA3-only uses4. `_airplay._tcp` discovery must use the same persistent
identity, public key, device identifier and port as the actual receiver.

Argo retains one controller, AP power lease, AirPlay listener and Avahi
advertisement while wireless CarPlay is running. Ordinary phone session ends
reuse that owner with a cancellable retry delay of 2–30 seconds; they do not
request a new privileged VHCI descriptor. Each phone gets new native IPC,
session ID and media/control tasks, and the latest display/audio options are
read only when its AirPlay connection is accepted. Idle TCP connections are
discarded before a new phone's StartSession. A manual connection with
`auto_connect=false` gets one attempt; changing the setting stops further
attempts after the current session. Explicit Disconnect, disable, transport
change and daemon stop release the owner. Link/HCI, BlueZ or Avahi ownership
loss also ends it; a replacement then requires normal acquisition and may
require authorization again. Unconfirmed cleanup remains fatal rather than
starting a competing owner.

Wireless negotiation/identification has a 30-second deadline, followed by a
separate 15-second MFi authentication limit. After authentication, the phone
has up to 90 seconds to report availability so a person can accept its Use
CarPlay prompt. The wireless AirPlay listener allows 120 seconds from the
RFCOMM session start; wired operation retains its 40-second accept limit.
Cancellation still ends every wait. Managed settings receive runtime progress
through a watch channel, including controller preparation, waiting for a phone,
authentication, iPhone approval, video connection and retry. Connected is
reported when the receiver publishes authenticated video, rather than when
the controller or TCP listener merely becomes ready.

In managed operation, Argo's shared BlueZ agent in `argo-projectiond` owns the
host-wide default role and routes incoming pairing/authorization requests to the
global Flutter prompt,
including requests on the Link controller. A standalone CarPlay process relies
on an existing default agent. The CarPlay controller registers no private agent.
Controller cleanup allows one second per profile unregister, then requires confirmed private
D-Bus disconnection within two seconds. It always stops and awaits the owned
HCI task, allowing three seconds before abort and one further second to join.
An unconfirmed bus disconnect or unfinished task returns
`ControllerCleanupUnconfirmed`; automatic replacement must stop in that case.

The original 9.0.0 `LIVI-LINK.md` placed the wired iPhone on the host and described
dongle OTG support as macOS-only. The current Link exposes MFi, Wi-Fi AP and
Bluetooth services, without that historical USB proxy. Argo keeps the wired
iPhone on the Linux host. The dongle's NCM DHCP network transports MFi requests independently of the
iPhone's local USB/NCM transport. Wi-Fi and Bluetooth are optional separate uses;
neither should activate as a side effect of reading status.

## Protocols reviewed and implementation implications

* `iap2-link`: detection, checksummed frames, synchronization/session identifiers,
  acknowledgement/retransmission and teardown. A bounded framing implementation
  alone does not provide the USB transport or an interoperable session.
* `iap2-csm`: typed accessory identity, MFi challenge exchange, CarPlay status and
  StartSession, metadata subscriptions, and optional vehicle/location data.
  Only capabilities backed by actual Argo functionality should be advertised.
* `iap2-wired`, `iap2-usbmux`, helper `wired.rs`: Linux local USB inventory,
  usbmux/lockdown pairing and `com.apple.carkit.service`, iAP2 over that stream,
  and a separate NCM network path. Phone trust/pairing and kernel/USB ownership
  are prerequisites; raw iAP2 frame parsing does not substitute for them.
* `livi-runtime` and helper `embedded.rs`/`bluez.rs`: transport/session ownership, wired
  and wireless handover, iAP2 control, BlueZ integration and reconnect policy.
* `cp/stack`: RTSP framing, binary plist, SRP setup, pair verification, MFi
  auth-setup and encrypted control/event channels. Screen stream 110 and cluster
  111 are distinct; video packet/configuration framing must be converted and
  validated before native decoding. Argo should preserve a separate cluster plane.
* `CpSession` and `cpStack`: negotiated audio categories distinguish media,
  telephony, speech recognition and navigation; wired LPCM and wireless compressed
  audio require native stream-format validation, clocking and focus. Microphone
  uplink starts only when requested and must end with stream teardown.
* HID reports travel on the negotiated event channel. Argo's fitted projection
  rectangle, source coordinates and existing gesture cancellation should remain
  the sole UI-side transformation. New native transport must carry the reports.
* Projection services associate media and navigation metadata with a device/session;
  Argo must preserve source and session provenance, bounded artwork and freshness.
* `livi-link-host`: Linux HCI-over-TCP creates a BlueZ adapter through `/dev/vhci`.
  Current firmware leaves iAP2 ownership to the host. No VHCI or AP ownership is
  needed for wired MFi diagnostics.

The source review motivates independently written bounded protocol adapters,
typed configuration, separate session ownership and shared native media. It does
not justify importing the Electron UI or asserting that upstream feature support
has already become an Argo feature. Current implementation and validation are
listed in [carplay.md](carplay.md).

## License and provenance

LIVI declares **GPL-3.0-or-later**, copyright 2025–2026 Lasse Heitgres. Its current
[`NOTICE`](https://github.com/f-io/LIVI/blob/bfbea31ee624ddce84bfa96ce49d4663e6cdeca7/NOTICE)
also requires attribution in appropriate legal notices and documentation for
works containing LIVI source, object code or translations. Argo has no
repository-wide license declaration; the existing projection Cargo workspace
declares MIT for that workspace, which does not establish a whole-repository
license. This work does not choose a license for the rest of Argo.

`native/carplay/vendor/livi-iap2-link` contains the unchanged upstream
`native/crates/iap2-link/src/lib.rs` and `tests/engine.rs` from `bfbea31`, with
their SPDX notices and full `LICENSE`/`NOTICE`. Its local README records the full
revision and the small Cargo manifest adaptation. The `argo-carplay` package now
declares GPL-3.0-or-later and includes those license/notice texts. Argo's other
wireless adapters use the researched protocol and synthetic fixtures. The physical
Link compatibility service in `native/link-mfid` additionally adapts upstream
`iap2-mfi` and `livi-net` from the same revision. It includes GPL/NOTICE, patch
provenance and a complete source archive in the custom firmware; the unused file
authentication backend and its synthetic key/certificate fixtures are omitted.
No phone
pairing records or firmware blobs are imported by this integration.

Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).

[CREDITS.md](../CREDITS.md), legal notices and the corresponding native source
accompany distribution. This is source-informed interoperability and explicit
source reuse, not a clean-room claim. A process boundary is a technical choice;
this review makes no claim that it changes license obligations or that upstream
endorses Argo.
