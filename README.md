# Project Argo

Argo is a vehicle-agnostic Flutter infotainment application with Android Auto
projection, Bluetooth music and calling, native Now Playing, persistent settings and Lua vehicle integrations.
External vehicle bundles supply identity, capability metadata, decoding and policy;
the built-in `generic` profile runs without a vehicle bundle.

Flutter owns the UI and application services. The Rust `argo-projectiond` daemon
owns Android Auto USB/Wi-Fi transport, shared Bluetooth control, TLS and native audio.
An IHS platform view decodes video with GStreamer and presents it through the
ivi-homescreen compositor. Media bytes stay outside Dart control IPC. Veloce hosts
Lua plugins, normalized vehicle signals, events, storage and optional SocketCAN.

## Capabilities

- Wired and wireless Android Auto using one video/audio/input/metadata engine.
- Shared Bluetooth pairing and device selection; controlled projection AP with
  saved 2.4/5 GHz band selection, automatic capability detection and current regulatory checks.
- Bluetooth A2DP reception through PipeWire, BlueZ metadata/playback controls and
  entertainment-source selection.
- Home projection and Media/Now Playing with session-preserving AA Exit and resume.
- Album artwork from AA and optional BlueZ BIP thumbnails, with a shared Media cache.
- HFP call control through PipeWire telephony, shared USB ADC/mixed microphone input
  for Android Auto and Bluetooth calls, explicit contacts/recent-call import, and
  acknowledged Quit cleanup.
- Focused Settings sections, host volume/mute, Material 3 appearance and persistent preferences.
- Vehicle telemetry, simulation, optional SocketCAN, audio focus policy and
  explicitly enabled host power integration.
- External vehicle bundles and permission-controlled Lua host-state reads through
  `argo_host.snapshot()`.

Wireless startup has been tested on LattePanda Mu with Debian 13 and KDE Wayland.
Wired projection and native rendering have also been exercised on Linux. Wireless
admission is development-only and does not cryptographically bind TCP identity to
Bluetooth identity. Full compatibility, endurance and lifecycle hardware validation
remain limited. Bluetooth music hardware interoperability remains unverified;
HFP duplex audio and AA microphone capture require ADC/phone acceptance.
PBAP phone interoperability remains unverified. Wallpaper/shaders are not implemented.

## Documentation

- [Setup and launch](docs/setup.md): dependencies, desktop development, projection
  launch, shutdown and rollback.
- [Architecture](docs/architecture.md): ownership, lifecycle and extension boundaries.
- [Configuration](docs/configuration.md): environment, settings, defaults and timing.
- [Media sources and Bluetooth music](docs/media.md): routing, controls, setup and limits.
- [Wireless Android Auto](docs/wireless.md): pairing, AP, admission, retry and diagnosis.
- [Compatibility and limitations](docs/status.md): tested scope and unsupported work.
- [Projection build reference](tool/projection/README.md): matching SDK/IHS requirements,
  safe daemon staging, native-view build and renderer diagnostics.
- [Vehicle and Lua integrations](docs/vehicle-integrations.md): APIs, permissions and
  examples. [Contributing](CONTRIBUTING.md) covers repository conventions.

Synthetic workflows: [vehicle bundles](tool/vehicle_integrations/README.md),
[audio control](tool/audio/README.md), [host power](tool/host_power/README.md).
