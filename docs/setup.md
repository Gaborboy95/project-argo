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

## Graphical-session deployment

Argo uses unprivileged systemd **user** services on KDE Wayland. `argo.target`
controls `argo-app.service` and `argo-projectiond.service`. Installation does not
start Argo or enable autostart. Existing firewall/polkit enrollment remains
separate; see [permissions](wireless.md#permissions-and-helper-installation).

From this checkout, install the self-contained launcher and units once:

```bash
python3 "$HOME/dev/argo/tool/deployment/argoctl" install \
  --ihs-prefix "$HOME/dev/ivi-build/out/usr/local"
```

The installed command is `$HOME/.local/bin/argoctl`. It runs without this checkout.
Re-running installation preserves settings, identity references and enablement.
No root, lingering, desktop autologin or system service changes are involved.
KDE must have imported `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` into `systemctl --user show-environment`. Run from the
logged-in desktop; do not source the build workspace's `setup_env.sh` at runtime.
The target requires an already active `graphical-session.target`.

Select an existing **managed-compatible IPC6 bundle** with `argo-release.json`:

```bash
export ARGO_WIRELESS_BUNDLE="/absolute/path/to/the/matched/bundle"
export ARGO_RELEASE_NAME="my-argo-release"
"$HOME/.local/bin/argoctl" stage "$ARGO_WIRELESS_BUNDLE" --name "$ARGO_RELEASE_NAME"
"$HOME/.local/bin/argoctl" select "$ARGO_RELEASE_NAME"
```

This copies the bundle to `$HOME/.local/share/project-argo/releases/NAME` and
atomically selects it with `$HOME/.config/project-argo/current-release`.
Selection does not rebuild anything. Required assets, recorded IPC/control
contracts, file hashes and matched installed IHS executable/library/header hashes
must validate before selection. Older bundles lacking the managed Quit endpoint
must use their original foreground launcher; a manifest alone cannot add support.

Configure existing external identity files **only for the daemon**:

```bash
"$HOME/.local/bin/argoctl" identity \
  --certificate "$HOME/.config/argo-cert/argo.crt" \
  --key "$HOME/.config/argo-cert/argo.pk8.key"
```

These paths describe the reference layout; use your actual existing files. The key
must be PKCS#8 PEM. This command does not generate a phone-accepted identity.
Bluetooth remains usable without an AA identity. The app never reads `daemon.json`
or inherits its certificate/key variables. See [deployment configuration](configuration.md#deployment-configuration).

Enable graphical-login autostart, or start only for this login:

```bash
systemctl --user enable --now argo.target
# Alternatively, without enabling login autostart:
systemctl --user start argo.target

systemctl --user stop argo.target
systemctl --user restart argo.target
systemctl --user disable --now argo.target
```

Autostart means **graphical login**, not machine boot. Desktop autologin is a
separate KDE/SDDM administrator decision; this installer never configures it.
Logging out stops Argo. Quit does not disable future graphical-login autostart;
it stops the target for this session. `argoctl quit` invokes the same acknowledged
application Quit path.

The managed app requests Wayland fullscreen by default; it does not enlarge a
fixed small window to the output. Configure an explicit development window or
output index in [display configuration](configuration.md#managed-display-configuration).
Appearance → Control size adjusts host controls without altering projection geometry.

Individual service control and journal access:

```bash
systemctl --user status argo.target argo-projectiond.service argo-app.service
systemctl --user start argo-projectiond.service
systemctl --user start argo-app.service
systemctl --user stop argo-app.service
systemctl --user restart argo-projectiond.service
journalctl --user -b -u argo-projectiond.service -u argo-app.service
journalctl --user -f -u argo-projectiond.service -u argo-app.service
```

The app orders after the daemon's bounded IPC readiness probe; its own readiness
requires an IPC-connected client and a rendered Flutter frame. A readiness probe
does not acquire the application's projection lease. A daemon restart also
restarts the app; stopping the daemon stops its app first. Manual stop and
successful Quit do not restart either process. Failures have a three-second delay
and at most three starts in a 90-second window. `systemctl --user reset-failed
argo-app.service argo-projectiond.service` clears a start-rate limit after the
underlying problem is corrected.

## Shutdown, updates and rollback

**Settings → Application → Quit Argo** waits for the daemon's `stopAll`
acknowledgement, saves preferences and shuts down application services. In managed
mode it also stops `argo.target`. Service stop invokes the same cleanup endpoint
before terminating the app, then signals the daemon and waits for its workers.
Both services record invocation-specific cleanup results. The journal distinguishes
completed cleanup from failures/timeouts. A pending permission prompt is not
completed cleanup. Service stop is bounded (app 45 seconds, daemon 50 seconds);
forced termination kills remaining cgroup processes and reports failure. It cannot
guarantee graceful completion of blocked native FFI or external resources.

For updates, stage an existing compatible bundle under a new name, then select it:

```bash
"$HOME/.local/bin/argoctl" list
"$HOME/.local/bin/argoctl" stage "$ARGO_WIRELESS_BUNDLE" --name next-release
"$HOME/.local/bin/argoctl" select next-release
"$HOME/.local/bin/argoctl" rollback
```

An active switch stops both services and confirms cleanup before changing selection.
Only previously running services are restarted; enabling/disabling is unchanged.
If one service was individually stopped, the other is restarted individually and
the target remains inactive, so its Wants cannot launch the stopped service.
Startup failure restores the previous selection and restarts it if failed-start
cleanup is confirmed. Otherwise services remain stopped with a diagnostic.
`rollback` selects the previous managed release; after the first installation
there is no previous managed selection yet. Keep pre-systemd working bundles and
use their own `run-release.sh` with an explicit `ARGO_WIRELESS_BUNDLE` if needed.
Never mix app/daemon IPC versions or overwrite a loaded binary/library.

For a daemon-only update, build just the daemon as described in the
[build reference](../tool/projection/README.md#daemon-build-and-safe-staging),
record the resulting binary, and copy unchanged app/native assets into a new release:

```bash
export ARGO_DAEMON="$HOME/dev/argo/native/projection/target/release/argo-projectiond"
python3 "$HOME/dev/argo/tool/deployment/record-build.py" daemon "$ARGO_DAEMON"
"$HOME/.local/bin/argoctl" stage \
  "$HOME/.config/project-argo/current-release" --name daemon-update \
  --daemon "$ARGO_DAEMON"
"$HOME/.local/bin/argoctl" select daemon-update
```

`record-build.py` records a completed matching source build; it does not verify
that an arbitrary old executable implements the current source. A full managed
app build is recorded with `record-build.py bundle BUNDLE --ihs-prefix PREFIX`
after assembling the matched app/daemon/native assets. The machine-readable
manifest is authoritative for IPC and IHS compatibility; retain build provenance.

A retained `$HOME/.local/state/project-argo/firewall-owned.json` means a managed
attempt's guard cleanup is unconfirmed. It records only the interface, never AP
credentials. A killed daemon's NetworkManager activation is bound to its D-Bus
client, but its firewall guard may remain. Automatic replacement is blocked until
owned cleanup is inspected. Follow the [owned cleanup procedure](wireless.md#permissions-and-helper-installation),
confirm the recorded interface has no active projection AP and its Argo guard has
been removed, and only then remove that record. After inspecting failed cleanup,
remove only the failed `app.json`/`daemon.json` result records in that same state
directory and reset the failed units before starting. Do not clear records to hide
an unresolved cleanup failure. No unrelated profile or management connection is
part of this recovery.

Foreground debugging uses the same installed selection and configuration:

```bash
# Stop managed services before running these in two desktop terminals.
systemctl --user stop argo.target
"$HOME/.local/bin/argoctl" foreground daemon
"$HOME/.local/bin/argoctl" foreground app
```

Standalone Quit retains its behavior: clean up the application, then stop the
foreground daemon with Ctrl+C/SIGTERM. The repository's legacy
[release launcher](../tool/connectivity/run-release.sh) also recognizes the shared
selector when `ARGO_WIRELESS_BUNDLE` is unset; an explicit override still wins.

Uninstall deployment tools/units after cleanup:

```bash
"$HOME/.local/bin/argoctl" uninstall
```

This disables and removes user units and the launcher. Releases, application
preferences, external identity and separately installed permission grants remain.
Uninstall does not proceed past uncertain cleanup.

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

Bluetooth music uses the same matched release and launcher, including when projection
is disabled. Apply the explicit [Bluetooth routing opt-in](media.md#setup-and-use)
before connecting music. No Engine, IHS or native-view rebuild is needed for an
application/daemon-only release; preserve those compatible native assets from the
working bundle while replacing the application build and daemon.
