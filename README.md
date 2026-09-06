# Project Argo

Project Argo is a Flutter infotainment development application. Its public code
is vehicle-agnostic: external vehicle bundles supply identity, capability
metadata and Lua decoding/policy plugins. The built-in `generic` profile needs
no vehicle bundle. Synthetic examples in `tool/` are not real vehicle protocols.

Flutter owns UI and application services. Veloce runs Lua plugins and mediates
normalized vehicle signals, CAN, events and plugin storage. On Linux, the
separate Rust `argo-projectiond` handles wired Android Auto USB/TLS/protocol and
native audio delivery. The IHS projection-view library decodes video with
GStreamer and submits native frames to the existing ivi-homescreen compositor.
Video and PCM do not pass through Dart. AA credentials are loaded only by the
daemon; the Flutter client reports readiness and selected/pending configuration
through IPC v2.

## Current scope

Implemented: module navigation, typed persistent settings (including next-session projection preferences), normalized vehicle
telemetry/power state, external bundle discovery, Veloce plugin lifecycle,
simulation scenarios, opt-in SocketCAN, audio policy with default-sink
volume/mute through `wpctl`, and opt-in systemd host power control. Media contains
wired Android Auto and the phone-independent native renderer diagnostic. Climate
and Parking are placeholders; their navigation entries are not working controls.

Projection remains experimental. The user has verified visible native bars and
live wired Android Auto video/audio on Ubuntu VMware through unmodified IHS.
The latest gesture fixes have automated coverage but have not yet been tested
with a phone. Expanded presentation reached 1280 × 720 physical pixels at DPR 1;
the user reported clean bars at that size. Target-vehicle hardware acceptance,
reconnect endurance and live-AA quality at 1:1 are not established. An outstanding
IHS release-eventfd leak limits long-running EGL projection; no IHS fix is included.

Wireless Android Auto, Bluetooth integration, working microphone capture,
CarPlay, new metadata APIs, customization and plugin-rendered application tabs
or settings are not completed features. Some protocol enums and microphone
channel scaffolding exist; they do not establish end-to-end support.

## Documentation

- [Setup and running](docs/setup.md): desktop, VM, bundles and existing runbooks.
- [Architecture and extension points](docs/architecture.md): ownership and boundaries.
- [Configuration reference](docs/configuration.md): runtime variables and typed settings.
- [External integrations and Lua plugins](docs/vehicle-integrations.md).
- [Acceptance, troubleshooting and limitations](docs/status.md).
- [Contributor guidance](CONTRIBUTING.md).

Implementation audited at `ee08a138cdadaa361706c0e46b89974fd5e8aad3` on
2026-09-06. These documents describe that checkout, not a released product.
Dependency revisions and the distinction between code, tests and user acceptance
are recorded in the [audit status](docs/status.md).
