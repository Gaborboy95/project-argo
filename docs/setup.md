# Setup and running

Read [configuration](configuration.md) before reusing a terminal with old exports.
Examples deliberately disable host power. Installing dependencies is a separate
administrator action; run Argo, homescreen and the daemon as your desktop user.

## Environments and dependencies

The exercised environment is Ubuntu 24.04 in VMware, x86_64, Wayland/EGL IHS,
GStreamer 1.24.2 and PipeWire. Windows/Codex can edit Dart/Rust/C++ and run suitable
Dart tests with a matching SDK; it does not validate Linux USB, SocketCAN,
PipeWire, GBM or the IHS native library. No Windows projection acceptance or
real target-vehicle hardware acceptance is recorded. The standard Flutter Linux
GTK runner is useful for shell/simulation work, but does not provide IHS's custom
platform-view contract.

Established layout:

```text
$HOME/dev/
  argo/                       this checkout
  veloce/                     pubspec path dependencies, independently maintained
  infotainment/               emb workspace, Flutter SDK, engine and bundles
  ivi-homescreen/              IHS source, not an Argo fork
  ivi-build/out/usr/local/     matching IHS headers, libihs_shared.so, bin/homescreen
```

`pubspec.yaml` requires Dart `^3.13.2` and sibling Veloce core/native packages.
Use the workspace Flutter SDK paired with its engine; do not substitute a random
stable SDK when compiling an AOT bundle. The locally installed SDK reports Flutter 3.47.2 / Dart 3.13.2. The audited Flutter revision is
`d3b14c876900e553bc736ca19295fc09e3853e8e`; workspace setup selects engine
`a804b261645ef8c13eb3d5c44a5c2fb0340c5539`. Dependency setup/provisioning is outside
this repository; do not download/update them as an ordinary Argo build step.
Veloce's native Lua library and SQLite must be available even with an empty plugin
root. The sibling package's build instructions are in
`../veloce/packages/veloce_lua_native/README.md` relative to the Argo checkout.

The ordinary Linux desktop runner also requires the Flutter Linux compiler/tooling
and GTK3 development package (`libgtk-3-dev`); `linux/CMakeLists.txt` resolves
`gtk+-3.0` through pkg-config. This is separate from IHS bundle execution.

For the native projection view: CMake 3.20+, Ninja, a C++20 compiler, pkg-config,
matching IHS headers/library, GBM/EGL/Vulkan development libraries and GStreamer
core/app/video development packages. For the daemon: Rust 1.88+ (edition 2024),
Cargo, OpenSSL for identity validation/test tooling, and optional Linux USB/media
features. The [projection runbook](../tool/projection/README.md) lists Ubuntu
packages and exact native build commands. Do not rebuild Flutter Engine or IHS
for ordinary Dart or native-view changes. An existing IHS build must have the
compositor/platform-view support required by Argo, including `BUILD_COMPOSITOR`.

## Desktop and simulation

Start a fresh Bash shell and define paths. Loading workspace setup can change
`PATH`, `PUB_CACHE`, `XDG_CONFIG_HOME` and the effective default settings location.

```bash
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
source "$FLUTTER_WORKSPACE/setup_env.sh"
cd "$ARGO"
flutter pub get
export ARGO_HOST_POWER_BACKEND=disabled ARGO_AUDIO_BACKEND=disabled
export ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0
export ARGO_VEHICLE_PROFILE=generic
unset ARGO_VEHICLE_INTEGRATIONS_DIR ARGO_SIMULATION_SCENARIO VELOCE_CAN_INPUT
export ARGO_MODE=production
flutter run -d linux --no-enable-impeller
```

Normal mode without CAN fails closed for CAN I/O; it does not generate telemetry.
To exercise synthetic signals and decoder plugins, use the
[example integration workflow](../tool/vehicle_integrations/README.md).
`ARGO_MODE=simulation` selects in-memory CAN with writes disabled even if a
SocketCAN variable was inherited. A scenario may contain CAN frames and/or
normalized signals; see the checked-in [scenarios](../tool/simulation).

For vcan, use an already provisioned `vcan0` interface and installed `can-utils`.
Select `ARGO_MODE=production`, `VELOCE_CAN_INPUT=socketcan`,
`VELOCE_SOCKETCAN_INTERFACE=vcan0`, `VELOCE_CAN_BUS=comfort`, and
`VELOCE_CAN_WRITE_ENABLED=false`; retain disabled host power. Running
`cansend vcan0 280#0BB8` with the example decoder represents synthetic 3000 RPM.
Argo does not create network interfaces. The [power runbook](../tool/host_power/README.md)
contains an explicit fake-systemctl suspend/resume exercise, not a requirement
for routine simulation. Never substitute a real vehicle bus into synthetic examples.

## Release bundle and IHS

Use the [native view and bundle workflow](../tool/projection/README.md#build-the-native-view-and-argo-bundle)
for explicit emb output, native-library staging and matching IHS paths. It is
also the packaging workflow for a non-projection IHS run; disable projection at
launch. The executable is `$HOME/dev/ivi-build/out/usr/local/bin/homescreen`.
There is no assumed globally installed `ivi-homescreen` command.

Check and stop your previous homescreen before staging: replacing a loaded
`.so` in place is unsafe. Keep IHS include files, shared library and executable
from the same build. Do not set global `PKG_CONFIG_SYSROOT_DIR` for system-installed
GStreamer; pass staged IHS include/library paths directly to CMake.

## Projection workflows

- [Standalone daemon and complete wired launch](../tool/projection/README.md#one-real-device-workflow):
  separate terminals, matching socket resolution and identity paths only in the
  daemon terminal. Start homescreen with both identity variables explicitly unset.
  Argo connects to the daemon; it does not spawn or supervise it.
- [Phone-independent renderer](../tool/projection/README.md#phone-independent-native-renderer-diagnostic):
  from the Argo root run `tool/projection/run_renderer_test.sh`. It builds a
  dedicated release bundle, clears inherited integrations/sockets/credentials,
  disables real backends and captures `/tmp/argo-renderer-test.log`.
- [Measured size comparison](../tool/projection/README.md#presentation-size-comparison):
  run `ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS=1 tool/projection/run_renderer_test.sh`,
  then Media → Compare size. The label reports actual physical dimensions. The
  launcher requests a 1280×720 window using the installed CLI's supported flags;
  use the measured destination after any desktop/window resizing.

A standalone protocol success does not test presentation; bars do not test TLS,
USB or audio. Neither substitutes for phone acceptance.

## Logs and shutdown

Use `set -o pipefail` when piping a foreground command through `tee`. Daemon logs
are normally `/tmp/argo-projectiond.log`, complete-launch IHS output
`/tmp/argo-homescreen.log`; choose different paths if preserving an earlier run.
Application diagnostics also feed the in-process diagnostics service; plugin
signal tracing is separately opt-in. See [log configuration](configuration.md).

Close the app normally or use Ctrl+C/SIGTERM on the owned foreground process.
The daemon handles Ctrl+C/SIGTERM and closes its session/sockets. Application
cleanup is coordinated on supported shutdown callbacks; forced kills cannot
promise settings flush. Before deleting a suspected stale socket, inspect
`pgrep -af argo-projectiond`, `pgrep -a homescreen` and `ss -xlpn`, confirm its
path, owner and absence of a live listener. Never delete a live process's socket
or kill every similarly named process. See [known failures](status.md).
