# LIVI reference and Argo integration review

The exact reference is [f-io/LIVI at
a23dc0c5fcdb6d069c679eddfd73298e58f44783](https://github.com/f-io/LIVI/tree/a23dc0c5fcdb6d069c679eddfd73298e58f44783).
Its `dev` branch and `package.json` version `9.0.0` were verified after fetching
all branches/tags. HEAD equals the revision supplied with this task; there is no
intervening difference. The separate reference checkout is not a build dependency.

The [protocol source map and implementation notes](carplay-protocol-review-notes.md)
record exact reviewed areas, the experimental carkit API, USB-NCM prerequisites,
certificate pinning, media formats and the remaining AirPlay integration work.

## Component boundaries

LIVI has an Electron/TypeScript session manager, a Rust helper and native
GStreamer media workers. `CpManager` owns the common RTSP listener, associates
helper device events with individual `CpSession` instances, and handles transport
handover. `CpSession` connects the stack, projection presentation, metadata,
video planes, audio and input. The Rust helper alone is **not** a complete native
CarPlay receiver: the AirPlay control/pairing engine resides in `cp/stack`.

Argo retains Flutter, Rust, GStreamer and IHS. A separate `argo-carplayd` keeps
CarPlay failures and protocol dependencies out of `argo-projectiond`; it does not
replace the AA daemon or launch LIVI/Electron. The application-facing projection
contracts already have CarPlay protocol types. A multiple-backend facade and an
explicitly versioned encoded media contract are preferable to duplicating the
surface or silently changing AA IPC7. Flutter owns presentation and selects a
session; video reception must not acquire foreground ownership. Reverse camera
remains a higher local priority. Native audio and microphone ownership require
integration with existing focus/capture policy, not new Dart media paths.

## LIVI Link services verified in source

| Endpoint | Upstream source | Purpose |
| --- | --- | --- |
| `livi-link.local` | `livi-dongle/src/link.rs`, `livi-mdns` | Interface-specific IPv4 mDNS discovery |
| TCP 5000 | `iap2-mfi/src/{ncm,server}.rs` | Actual authentication IC certificate/sign/protocol-major operations |
| TCP 5001 | `livi-wifi/src/server.rs` | Line-oriented Wi-Fi and Bluetooth control |
| TCP 5002 | `livi-dongle/src/bt.rs` | Length-prefixed HCI traffic to Linux `/dev/vhci` |
| TCP 5003 | `bin/livi-link/src/usbproxy.rs` | Dongle USB proxy, not the preferred Linux wired topology |
| TCP 5004 | `livi-dongle/src/iap.rs` | Dongle-side Bluetooth/iAP session handoff |
| TCP 5005 | `livi-dongle/src/iap.rs` | Additional handoff accessory control |

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
opening 5002/5004 can acquire a transport; diagnostics must avoid those probes.

`LIVI-LINK.md` explicitly places the wired iPhone on the host and describes dongle
OTG support as macOS-only. Argo must not use the USB proxy as its normal Linux
path. The dongle's NCM DHCP network transports MFi requests independently of the
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
* `livi-runtime` and helper `linux_main.rs`: transport/session ownership, wired
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
* `livi-dongle`: Linux HCI-over-TCP creates a BlueZ adapter through `/dev/vhci`;
  the other handoff path lets dongle Bluetooth own iAP. These are different radio
  ownership models. No VHCI or AP ownership is needed for wired MFi diagnostics.

The source review motivates independently written bounded protocol adapters,
typed configuration, separate session ownership and shared native media. It does
not justify importing the Electron UI or asserting that upstream feature support
has already become an Argo feature. Current implementation and validation are
listed in [carplay.md](carplay.md).

## License and provenance

LIVI declares **GPL-3.0-or-later**, copyright 2025 Lasse Heitgres. Argo has no
repository-wide license declaration; the existing projection Cargo workspace
declares MIT for that workspace, which does not establish a whole-repository
license. This work does not choose a license for the rest of Argo.

No LIVI source files, translated source, test vectors, pairing records or binaries
are imported. New protocol implementations use the wire behavior researched in
the pinned source and synthetic Argo fixtures. Relevant modules identify that
reference. [CREDITS.md](../CREDITS.md) thanks f-io / Lasse Heitgres and contributors.
This is source-informed interoperability work, not a claim of a clean-room process.
If future work copies or substantially derives implementation code, it must record
each upstream file and revision, preserve notices and supply applicable GPL texts
and corresponding source. A process boundary is a technical choice; this review
makes no claim that it changes license obligations or that upstream endorses Argo.
