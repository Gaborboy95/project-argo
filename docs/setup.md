# Setup and running

Argo runs as a desktop user account. Use the existing toolchains, dependency
checkouts and installed configuration; normal application builds do not update
Flutter Engine, IHS, Veloce or system services. See [configuration](configuration.md)
for inherited environment effects and [compatibility](status.md) for tested scope.

## Reference layout and dependencies

The commands use this layout; adjust paths before running them:

```text
$HOME/dev/argo/                       Argo checkout
$HOME/dev/veloce/                     sibling Lua packages from pubspec.yaml
$HOME/dev/infotainment/               emb workspace, Flutter SDK/Engine, bundles
$HOME/dev/ivi-homescreen/              IHS source with the required local patch
$HOME/dev/ivi-build/out/usr/local/     matched IHS executable, headers and library
```

Set the shared paths in a development terminal:

```bash
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="$HOME/dev/infotainment"
export IHS_PREFIX="$HOME/dev/ivi-build/out/usr/local"
source "$FLUTTER_WORKSPACE/setup_env.sh"
cd "$ARGO"
```

The setup script supplies the workspace SDK, cache and Engine selection; it also
changes XDG_CONFIG_HOME, which affects the default settings location. Use a matching
SDK/Engine for AOT builds. `pubspec.yaml` requires Dart ^3.13.2 and sibling Veloce
core/native packages. Native Lua and SQLite libraries are required even when no
plugins are loaded. Their build instructions are in the sibling package README.

Linux projection needs the Rust toolchain, pkg-config, GStreamer core/app/video,
H.264 decode plugins and PipeWire/WirePlumber. USB uses nusb; wireless requires
BlueZ, NetworkManager, iw, polkit and nftables. The stock Flutter Linux runner
additionally needs GTK3 development packages and Flutter desktop tooling.
It does not supply IHS platform views. The
[projection build reference](../tool/projection/README.md) specifies the exact local
IHS patch, dependency revisions, build commands and native rendering requirements.

## Desktop and simulation

After installing the required SDK and sibling packages, resolve Dart dependencies
when needed, then run the shell with hardware actions disabled:

```bash
flutter pub get
export ARGO_HOST_POWER_BACKEND=disabled ARGO_AUDIO_BACKEND=disabled
export ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0
export ARGO_VEHICLE_PROFILE=generic ARGO_MODE=production
unset ARGO_VEHICLE_INTEGRATIONS_DIR ARGO_SIMULATION_SCENARIO VELOCE_CAN_INPUT
flutter run -d linux --no-enable-impeller
```

Production mode without CAN does not synthesize telemetry. For synthetic signals,
use [example integrations](../tool/vehicle_integrations/README.md). Simulation replaces
CAN with read-only in-memory input, not every host backend. Keep power explicitly
disabled. [Audio](../tool/audio/README.md) and [host-power](../tool/host_power/README.md)
workflows describe their scoped opt-ins and fake-systemctl tests.

## Projection launch

Use a staged release containing a matching IPC v5 application and daemon; Argo does
not spawn the daemon. `ARGO_WIRELESS_BUNDLE` selects it through the existing
[launcher](../tool/connectivity/run-release.sh). Its fallback path is a local
convenience; deployments should select their release explicitly from its manifest.

Stop the previous app/daemon before switching. Set ARGO_WIRELESS_BUNDLE to the
absolute directory produced by the [staging workflow](../tool/projection/README.md#daemon-build-and-safe-staging)
in **both** desktop terminals. A bundle directory is not the executable path.

Terminal 1 — identity belongs only to the daemon:

```bash
: "${ARGO_WIRELESS_BUNDLE:?Set the absolute path of the selected release bundle}"
: "${ARGO_ANDROID_AUTO_CERT_FILE:?Set the existing external PEM certificate path}"
: "${ARGO_ANDROID_AUTO_KEY_FILE:?Set the existing external PKCS#8 PEM key path}"
export ARGO_WIRELESS_BUNDLE ARGO_ANDROID_AUTO_CERT_FILE ARGO_ANDROID_AUTO_KEY_FILE
export ARGO_WIRELESS_DEVELOPMENT=1
"$HOME/dev/argo/tool/connectivity/run-release.sh" daemon
```

Terminal 2 — application and view:

```bash
: "${ARGO_WIRELESS_BUNDLE:?Select the same release directory as terminal 1}"
export ARGO_WIRELESS_BUNDLE
unset ARGO_ANDROID_AUTO_CERT_FILE ARGO_ANDROID_AUTO_KEY_FILE
"$HOME/dev/argo/tool/connectivity/run-release.sh" app
```

The launcher selects LIVE/production Android Auto, dedicated IPC/media sockets,
IHS paths, native-view and Lua libraries. It refuses a second daemon/homescreen and
requires a desktop XDG_RUNTIME_DIR. It does not provision identity, install the
firewall helper or enable wireless. Follow [pairing and connection](wireless.md#pairing-and-connection)
after launch. Credentials must already exist; Argo does not provide a phone-accepted
self-signed provisioning recipe.

For wired operation, omit/unset ARGO_WIRELESS_DEVELOPMENT in terminal 1, leave
wireless disabled and connect USB data. USB device permissions must cover both
normal and accessory modes. The launcher and session engine are otherwise shared.

## Shutdown and rollback

Close the app normally and stop the owned foreground daemon with Ctrl+C/SIGTERM.
Wireless cancellation waits for media/AP cleanup; do not interpret a pending cleanup
message as completed shutdown. An async timeout cannot interrupt synchronous native
FFI. Forced termination cannot guarantee settings flush or graceful resource release.

Keep the previous release directory and its manifest. To roll back, stop both current
processes, set ARGO_WIRELESS_BUNDLE to the previous compatible IPC v5 bundle in both
terminals, and relaunch. Older IPC v4 wired bundles require their corresponding
application/daemon workflow; never mix IPC versions. Do not overwrite loaded binaries.

Before removing a stale socket, inspect `pgrep -af argo-projectiond`,
`pgrep -a homescreen` and `ss -xlpn`; verify the exact path and absence of a live owner.
For an uncertain wireless AP/guard, use the [owned cleanup procedure](wireless.md#permissions-and-helper-installation).
Do not delete unrelated profiles or restart Bluetooth/NetworkManager as routine cleanup.

## Diagnostics

The daemon writes to stderr with ARGO_PROJECTION_LOG_LEVEL filtering. The launcher
does not automatically save a log. To capture one, pipe the foreground command through
`tee` with Bash `set -o pipefail`, using a new output path for each investigation.
The application has its own diagnostics service; Lua host-state tracing is opt-in.
The [renderer diagnostic](../tool/projection/README.md#phone-independent-native-renderer-diagnostic)
checks native presentation without a phone, independently of USB/TLS/audio acceptance.

Wireless firewall authorization is provisioned once using the explicit
[administrator enrollment](wireless.md#permissions-and-helper-installation).
Application and daemon continue running without root privileges.
