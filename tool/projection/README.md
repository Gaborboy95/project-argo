# Wired Android Auto

Current status at audited Argo revision `ee08a138`: the user reports live wired
Android Auto video/audio and visible native renderer bars on Ubuntu VMware through
unmodified IHS. Latest gesture refinement is code/test verified but not yet
phone-tested; reconnect endurance and target-hardware acceptance remain open.
See [acceptance and limitations](../../docs/status.md), including the outstanding
IHS release-eventfd exhaustion issue. This is a development runbook, not product
certification. [Setup](../../docs/setup.md) and [configuration](../../docs/configuration.md)
provide the environment and option reference.

## Build and provision once

Use the existing narrowly scoped USB permissions if already installed.
Otherwise, for the proven phone (04e8:6860), install:

```bash
sudo groupadd -f plugdev
sudo usermod -aG plugdev "$USER"
sudo tee /etc/udev/rules.d/70-project-argo-android-auto.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="04e8", ATTR{idProduct}=="6860", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d0[0-5]", GROUP="plugdev", MODE="0660", TAG+="uaccess"
EOF
sudo udevadm control --reload-rules
```

Log out/in after group changes. A different phone needs its exact normal-mode
VID/PID from `lsusb`, not broader USB access. A VM must forward both the normal
device and its Google accessory re-enumeration. Never run the daemon as root.

Install native dependencies and use Rust 1.88+:

```bash
sudo apt update
sudo apt install -y build-essential pkg-config cmake ninja-build curl \
  ca-certificates openssl usbutils libudev-dev libgbm-dev libegl1-mesa-dev \
  libvulkan-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-pipewire \
  pipewire wireplumber

# Skip this if Rust is already installed.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"
rustup component add rustfmt clippy

export ARGO="$HOME/dev/argo" # adjust to the actual checkout
cd "$ARGO/native/projection"
cargo build --release --features linux-usb,linux-media
```

Keep your existing externally stored Argo identity. For local compatibility
experiments only, if none exists, this generates a self-owned test identity. No
credentials are provided by the repository; generation is not phone acceptance
or a completed provisioning/certification workflow:

```bash
install -d -m 700 "$HOME/.config/project-argo/android-auto"
export ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/project-argo/android-auto/argo.crt"
export ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/project-argo/android-auto/argo.key"
(
  umask 077
  test ! -e "$ARGO_ANDROID_AUTO_KEY_FILE" &&
  test ! -e "$ARGO_ANDROID_AUTO_CERT_FILE" &&
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 \
    -subj '/CN=Project Argo/' -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'extendedKeyUsage=clientAuth' \
    -keyout "$ARGO_ANDROID_AUTO_KEY_FILE" -out "$ARGO_ANDROID_AUTO_CERT_FILE"
)
chmod 600 "$ARGO_ANDROID_AUTO_KEY_FILE"
```

The daemon parses the files using the existing TLS compatibility implementation;
this patch does not strengthen or replace its current identity checks. TLS is restricted to
1.2; resumption is disabled. The AA-only USB peer verifier does **not** claim
WebPKI certificate-chain, hostname, or signature authentication: some AA peers
use legacy certificates. This permissive policy is isolated in `aa_tls.rs`,
never applied to IPC or network clients. TLS Finished verification is mandatory.
Generated RSA identities pass the in-memory TLS test; acceptance by your actual
phone still requires its TLS log. No certificate or private key is logged.

## Build the native view and Argo bundle

Use headers/library from the **same IHS build** that will run Argo. Load the
installed workspace environment and require the previous homescreen to be stopped
before building or staging any native library:

```bash
set -euo pipefail
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
export IHS_PREFIX="${IHS_PREFIX:-$HOME/dev/ivi-build/out/usr/local}"
source "$FLUTTER_WORKSPACE/setup_env.sh"
export PATH="$HOME/.local/state/Dart/install/bin:$PATH"
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
if pgrep -u "$UID" -x homescreen >/dev/null; then
  echo 'Stop your previous homescreen before building/staging.' >&2
  exit 1
fi
test -x "$IHS_PREFIX/bin/homescreen"
test -f "$IHS_PREFIX/include/ihs/platform_view.h"
test -f "$IHS_PREFIX/lib/libihs_shared.so"
unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR
cmake -S "$ARGO/native/projection/argo-projection-view" \
  -B "$ARGO/build/native-projection" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DIHS_INCLUDE_DIR="$IHS_PREFIX/include" \
  -DIHS_SHARED_LIBRARY="$IHS_PREFIX/lib/libihs_shared.so"
cmake --build "$ARGO/build/native-projection"
emb bundle --app-path "$ARGO" --workspace "$FLUTTER_WORKSPACE" \
  --arch x86_64 --mode release --build --output "$BUNDLE"
install -m 755 "$ARGO/build/native-projection/libargo_projection_view.so" \
  "$BUNDLE/lib/libargo_projection_view.so"
for library in libapp.so libflutter_engine.so libargo_projection_view.so libveloce_lua_native.so libsqlite3.so; do
  test -f "$BUNDLE/lib/$library"
done
```

Do not apply a global pkg-config sysroot to normally installed GStreamer.
`BUILD_COMPOSITOR` must already be enabled in the matching IHS host build; it is
not a native-view CMake option. Ordinary app/view changes do not require an
Engine or IHS rebuild. This recipe builds/packages only Argo's components.

The native view queries IHS capabilities, format/modifier support and the active
EGL/Vulkan device. The initial export path uses native BGRx conversion and fresh
linear RGB DMA-BUF allocations, avoiding reuse before compositor release.
IHS scales the source into the aspect-correct Flutter view. This is a correctness
path, not a zero-copy decoder claim. No EGL/Vulkan backend name is assumed.
SOFTWARE_SHM is used only if the host supplies an actual buffer; the audited local
IHS advertises that kind but its host adapter does not allocate one. A VM needs
a usable render device/GBM linear allocation or a functioning host SHM grant.
An unsupported grant produces a specific native diagnostic, not an invented
working renderer. Output renegotiation is implemented.

## One real-device workflow

Terminal 1 — start the standalone daemon **before plugging in the phone**:

```bash
set -o pipefail
export ARGO="$HOME/dev/argo"
: "${XDG_RUNTIME_DIR:?Run in your desktop login session}"
export ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/project-argo/android-auto/argo.crt"
export ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/project-argo/android-auto/argo.key"
install -d -m 700 "$XDG_RUNTIME_DIR/argo"
export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock"
export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/argo/projection-video.sock"

"$ARGO/native/projection/target/release/argo-projectiond" 2>&1 \
  | tee /tmp/argo-projectiond.log
```

The standalone path requires neither Flutter nor IHS for TLS/discovery debugging.
Video is drained until the native view attaches; standalone logs are not display
acceptance. USB discovery runs concurrently with IPC. No automatic respawn/retry
loop is installed. Ctrl+C/SIGTERM cancels and closes the owned session. If a
crash leaves a socket, remove only that stale socket after confirming the daemon
is stopped; startup never unlinks another process's socket.

Terminal 2 — run the actual existing homescreen executable:

```bash
set -o pipefail
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
export IHS_PREFIX="${IHS_PREFIX:-$HOME/dev/ivi-build/out/usr/local}"
source "$FLUTTER_WORKSPACE/setup_env.sh"
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
: "${XDG_RUNTIME_DIR:?Run in your desktop login session}"
unset ARGO_ANDROID_AUTO_CERT_FILE ARGO_ANDROID_AUTO_KEY_FILE
export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock"
export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/argo/projection-video.sock"
export ARGO_PROJECTION_RENDER_TEST=0
unset ARGO_SIMULATION_SCENARIO ARGO_VEHICLE_INTEGRATIONS_DIR VELOCE_CAN_INPUT
export ARGO_VEHICLE_PROFILE=generic
export VELOCE_PLUGIN_DIR="$HOME/.local/share/project-argo/empty-plugins"
mkdir -p "$VELOCE_PLUGIN_DIR"

systemctl --user status pipewire wireplumber --no-pager
gst-inspect-1.0 h264parse
gst-inspect-1.0 pipewiresink
export LD_LIBRARY_PATH="$IHS_PREFIX/lib:$BUNDLE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ARGO_MODE=simulation \
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_AUDIO_BACKEND=pipewire \
ARGO_PROJECTION_BACKEND=android-auto \
VELOCE_LUA_LIBRARY="$BUNDLE/lib/libveloce_lua_native.so" \
"$IHS_PREFIX/bin/homescreen" -b "$BUNDLE" --backend wayland-egl --width=1280 --height=720 \
  2>&1 | tee /tmp/argo-homescreen.log
```

The example uses the generic vehicle profile and an empty plugin root. Android
Auto does not depend on a vehicle profile. Identity paths are configured **only
on the daemon**; both variables are explicitly unset for homescreen above. Argo
never opens/parses the key and IPC v3 has no client identity fields. Inherited
identity variables are ignored by Dart. Both processes resolve the same control
and media defaults from XDG_RUNTIME_DIR, or /run/argo without it; explicit paths
above make the two-terminal relationship clear. Empty/invalid overrides fail.
Select **Media** in Argo, unlock the phone, and plug it in. Accept any phone-side
Android Auto prompts. Then verify touch, music and a navigation announcement.
Use **Return to Argo** / **Show projection** to switch the surface. Unplug must
clear projection while leaving Argo alive; replug must create a fresh session.

Expected stages (use `ARGO_PROJECTION_LOG_LEVEL=debug` for detailed setup messages):

```text
AOAP protocol version 2
Android accessory detected
bulk interface claimed ...
AA VersionRequest sent
AA VersionResponse received
Android Auto version negotiation succeeded: phone protocol major=1 minor=7
AA TLS 1.2 starting with configured Argo identity
AA TLS 1.2 established
AA authentication complete; awaiting service discovery
AA service discovery response ...
AA AV setup: channel=3
AA AV start: channel=3
Native projection video consumer attached
AA AV start: channel=4     # media
AA AV start: channel=5     # speech/navigation
AA AV start: channel=6     # system; when used by the phone
```

IHS logs a native RGB DMA-BUF grant on successful rendering setup. AA media stays
entirely native: H.264 travels over the bounded local video feed; PCM uses
GStreamer appsrc and PipeWire. AV starts, stops, configuration indices and ACK
session IDs are handled explicitly. Argo's AudioService supplies per-stream
focus/duck gains via metadata IPC; it never rewrites master volume for ducking.
Existing non-projection backend routing capabilities remain unchanged.

Only H.264 and PCM are advertised. Defaults are 1280x720, 30 FPS, 160 DPI;
the daemon-validated Argo preferences queued for the next connection select supported
800x480/1280x720/1920x1080 and 30/60 FPS. Unsupported sizes fail explicitly.
Only night/driving-status sensors are currently advertised: absent vehicle
inputs mean day mode and conservative driving restrictions, never fictitious
speed/RPM/parking-brake data. Microphone channel 9 is advertised with PCM setup/open responses, but no native
capture/upload pipeline is implemented. Do not treat that scaffolding as working
voice input; see the current limitations.

If a real run fails, share both logs and the last successful stage. Do not change
unrelated protocol settings or credentials speculatively. Wired acceptance is
UI + touch + media/speech audio + clean unplug/replug, not merely a TLS message.
Wireless, CarPlay, vehicle-specific controls and power-policy changes are out
of scope.

## Validation

```bash
cd "$ARGO/native/projection"
cargo fmt --check
cargo test --all-features
cargo clippy --all-targets --all-features -- -D warnings
cd "$ARGO"
dart format lib test
flutter test
flutter analyze --no-pub
git diff --check
```

Native tests generate temporary RSA identities with OpenSSL; they do not embed
credentials or open a phone/audio device. New coverage is limited to high-risk
TLS, framing, channel, input and cleanup paths.

Historical validation before the latest refinement (not rerun for this documentation
audit): 38 Linux Rust tests passed (eight
new tests), strict all-feature Clippy and Rust formatting passed; 207 Flutter
tests passed with five existing native-Lua skips, analyzer and diff checks passed.
The native view passed C++ syntax checking against current IHS headers. A
synthetic GStreamer H.264 pipeline delivered three decoded BGRx buffers to a
discard sink (OpenH264 also printed an encoder warning). This is not an IHS
runtime, PipeWire playback, or real-phone acceptance result.

Protocol behavior was cross-checked against
[LIVI](https://github.com/f-io/LIVI) as a GPL behavioral reference only; no source,
protobuf definitions or credentials were copied into Argo. Native API references:
[IHS platform-view ABI](https://github.com/toyota-connected/ivi-homescreen/blob/main/shared/include/ihs/platform_view.h),
[rustls](https://docs.rs/rustls/0.23.22/rustls/),
[Vulkan DRM-device properties](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDrmPropertiesEXT.html).

## Phone-independent native renderer diagnostic

From the Argo checkout, with the previous test homescreen stopped, run:

```bash
tool/projection/run_renderer_test.sh
```

Select **Media**. The page must show **Native renderer test — no phone** outside
its surface, with visibly scrolling SMPTE bars **inside Argo**. The native source
is live 1280×720 BGRx, 30 fps, pixel aspect ratio 1:1. Destroying the view stops
the pipeline; recreating it restarts the pattern. Existing navigation uses an
`IndexedStack` and keeps pages mounted, so changing tabs alone does not destroy
the view. This navigation behavior is unchanged.

The launcher uses `FLUTTER_WORKSPACE` (default `$HOME/dev/infotainment`) and
`IHS_PREFIX` (default `$HOME/dev/ivi-build/out/usr/local`). It loads the workspace
environment, builds the existing native view and an x86_64 release/AOT bundle in
`<workspace>/bundle/argo-render-test`, then runs the existing
`<IHS prefix>/bin/homescreen --backend wayland-egl --width=1280 --height=720`.
The launcher now uses the installed CLI's supported `--width`/`--height` options.
The earlier `--w`/`--h` forms were forwarded as engine arguments, so the historical
comparison began at 1920×720. Native pattern dimensions remain 1280×720; geometry
logs/Compare size still establish the actual destination after window resizing.
It does not rebuild IHS or Flutter Engine, update repositories, or require root.
It refuses to stage while another launcher or the user's homescreen is running.
Runtime output goes to `/tmp/argo-renderer-test.log`; a homescreen failure remains
a failing shell exit status through `tee`.

`ARGO_PROJECTION_RENDER_TEST=1` is a process-environment flag, supported in AOT.
Unset or `0` preserves normal selection; other values are rejected. Test mode
requires the disabled projection backend (also the default); combining it with
`ARGO_PROJECTION_BACKEND=android-auto` fails before real-backend construction. Identity validation exists only in the
daemon, which test mode never contacts. No AA session or public test protocol is created. The launcher
sets simulation, generic vehicle profile, and disabled projection/audio/host
power backends. It clears inherited Argo/Veloce integration and scenario settings,
projection sockets and certificates, and uses isolated empty plugin/integration
directories and temporary settings. An explicit
`ARGO_PROJECTION_DRM_RENDER_NODE` is preserved; otherwise native device discovery
is used. No daemon, phone, USB inspection or media-socket connection is needed.

Both the renderer test and live projection use `ProjectionView` →
`IhsProjectionSurface` → `PlatformViewLink` → `PlatformViewSurface` →
`PlatformViewLayer`. The layer identifies the native `argo.projection.view`
instance; it does not reference an external texture. The same dynamically loaded
`libargo_projection_view.so` registers the same IHS factory. `videotestsrc` feeds
the existing bounded `projection_sink` appsink, `OnSample()` and `SubmitRgb()`.
All pixels remain native.

Logs include factory/create results, platform-view ID and native view pointer
(the IHS create ID is the platform-view ID; no separate native numeric ID is
exposed here), requested size, selected source, granted IHS kind, first sample
geometry/format/stride and first submit result/format/modifier. Per-view submitted
and failed counters are reported no more often than every three seconds;
failures include pre-submit drops. Destruction reports final counts. IHS kinds
are logged numerically as defined by the installed `ihs/platform_view.h`.

The committed compatibility behavior is preserved: GBM requests linear XRGB8888,
accepts LINEAR or INVALID from the existing allocation probe, and passes the
actual buffer modifier to IHS without coercion. DMA-BUF frames retain the existing
pre-`buffer_id` ABI size and release-fence handling. SOFTWARE_SHM still requires
a real host-provided mapping. No IHS results are overridden.

**Visual acceptance remains manual:** compilation, mock tests and `submit
accepted` logs cannot establish that a frame was displayed. Acceptance requires
moving native bars visibly displayed inside Argo through the existing, unmodified
ivi-homescreen executable. A blank surface with accepted submissions reproduces
the presentation problem independently of Android Auto.

Initial validation before the composition fix in the Linux VM: formatting, analyzer and all 30
focused projection/Media tests passed (two new checks). The C++ library built
against the installed IHS, and the launcher built/staged the release bundle and
ran the existing wayland-egl homescreen. GStreamer 1.24.2 supplied 1280×720 BGRx
samples with stride 5120; IHS granted kind 1 and accepted 2,450 submissions
with actual modifier `0x00ffffffffffffff` and no reported submission failures.
The process environment had no projection socket/certificate variables. Stopping
the launched homescreen logged native-view destruction and the final counters.
The user observed a **blank surface** on Media. This reproduces the presentation
failure without Android Auto in the **old texture-layer path**. It is historical;
subsequent user acceptance of moving bars is recorded below.


### Flutter/IHS composition contract

Checked against local Flutter commit `d3b14c87690` and IHS commit `50cbfb5b`
(the installed homescreen reports v3.0 at that commit):

- Flutter `packages/flutter/lib/src/widgets/platform_view.dart` constructs a
  `TextureAndroidViewController` through `initAndroidView`. In
  `services/platform_views.dart`, that controller stores the integer create
  reply as `textureId`. `RenderAndroidView` then paints a `TextureLayer`.
- IHS `shell/platform/homescreen/platform_views/platform_views_handler.cc`
  parses `id`, `viewType`, `direction`, double `width`/`height`, optional
  `left`/`top`, and encoded `params`. Its runtime-factory create reply is the
  requested **platform-view ID**, not a Flutter external-texture ID.
- `platform_view_host.cc::HostRegisterFactory` constructs `IhsPluginView`, an
  `ICompositorSurface`, and registers it with `RegisterCompositorSurface` under
  that ID after factory success. This path does **not** call Flutter external
  texture registration. Its imported GL texture belongs to the IHS compositor;
  neither that GL name nor a DMA-BUF fd is a Flutter texture identifier.
- `shell/backend/wayland_egl/wayland_egl.cc` resolves each platform-view layer's
  identifier in the compositor-surface map before calling `OnPresent` and
  sampling the surface. A Flutter texture layer does not perform that lookup.

The shared Argo widget now uses a small IHS-specific `PlatformViewController`.
`PlatformViewLink` allocates the stable ID, supplies the first nonempty logical
layout size, and owns disposal. Argo sends that ID and valid double dimensions
in `create`, preserving `StandardMessageCodec` creation parameters. It validates
the channel reply against that ID before notifying the link. `PlatformViewSurface`
then emits `PlatformViewLayer` using the **same ID**. Resize messages remain in
logical pixels; Flutter scales the layer for device pixel ratio and the native
frame dimensions remain independent. Rebuilds do not allocate another view.

Stock `initExpensiveAndroidView` was not used: its create implementation omits
size and its hybrid controller rejects `setSize`. `initSurfaceAndroidView` can
still select texture composition. A generic `PlatformViewSurface` with the IHS
controller avoids both mismatches. Input remains exclusively in ProjectionView's
existing mapped-touch listener; platform-view touch dispatch is a no-op.

Creation/resize channel failures are logged and show an unavailable surface,
including on a standard GTK runner without this IHS channel. Disposal waits for
pending creation and sends one cleanup request; late completion does not notify
an unmounted link. Native factory registration still occurs during application
composition, before the widget tree requests native creation.

**Installed-host limitation:** IHS's create handler acknowledges the requested ID
even when `CreateViaFactory` logs a factory refusal. The public channel has no
query that distinguishes this case. Argo can validate channel completion/errors
but cannot independently confirm factory success from that reply. Native factory
logs remain authoritative; this patch does not change IHS or the native factory.

Regression coverage inspects the actual Flutter layer tree for the matching
`PlatformViewLayer` and absence of `TextureLayer`, checks logical sizing at DPR 2,
resize without recreation, preserved creation parameters and single input
forwarding. One additional lifecycle test covers asynchronous creation/disposal
and an unavailable channel.

Composition-fix validation: formatting, analyzer, and 31 focused tests passed.
The unchanged renderer-test launcher rebuilt the x86_64 release bundle and ran
against the same installed homescreen and `libihs_shared.so` (SHA-256 checked
before and after). Native creation succeeded for ID 0 with logical dimensions
1031.11×580; frames remained 1280×720 BGRx, stride 5120. The layer-tree regression
verified platform-view composition rather than inferring it from a widget name
or an accepted buffer submission.
Subsequent user confirmation established visible moving bars on the corrected
path. The earlier blank-surface observation was from the old texture-layer path;
see the measured comparison result below and the current acceptance matrix.

### Gesture ownership and daemon logging

Accepted primary presses retain their original service/session/stream and last
valid content coordinates. Outside DOWN is rejected. Touch movement outside
keeps the last valid point; outside UP uses it, and CANCEL ends the entire native
Android gesture. Mouse dragging outside the content/window conservatively cancels
it. Hover and secondary-button activity never start a touch. Unsent moves are
coalesced per pointer and terminal events remove pending moves, while DOWN and
terminal ordering is retained. An already executing transport write must finish;
there is no long-press cancellation timer. Session targets are invalidated on
loss, including before reuse of the same session ID after reconnect.

The IndexedStack now explicitly marks module input ownership. Loss of module
ownership, Return to Argo, stream/session replacement and widget disposal cancel
active pointers once. Flutter lifecycle/view-focus callbacks, pointer CANCEL,
observable pointer removal, mouse exit and stale button-free mouse events also
cancel. The platform-view controller still does not forward touches.

Host limitation: this local IHS Wayland implementation sends Flutter pointer
removal on window exit. Its keyboard-focus-leave callback clears native key/IME
state but does not expose a Flutter view-focus or app-lifecycle notification.
Argo handles those supported Flutter callbacks if delivered, but cannot detect an
undelivered focus/device-removal event. A subsequent observed mouse event without
the primary button reconciles stale tracking. No GTK-specific plugin is used.

`ARGO_PROJECTION_LOG_LEVEL=error|warn|info|debug|trace` selects daemon logging at
runtime, including release builds; the default is `info`. Invalid values fail
startup. INFO reports startup/socket locations, session milestones and stream
start/stop transitions. WARN/ERROR retain actionable failures and disconnections.
DEBUG adds endpoint, channel, focus and media-consumer details. TRACE adds bounded
packet metadata, TX begin/complete and routine ping messages. No certificate,
key, PCM, video or arbitrary decrypted payload is logged; the raw focus-request
hex dump was removed. Disabled levels do not construct formatted messages.
Renderer-test diagnostics are independent and unchanged. Post-version failures
are labelled as session failures rather than failed version negotiation, and the
same propagated failure is logged once at the owning lifecycle boundary.

### Presentation-size comparison

On Media, **Compare size** expands the existing native surface without page
padding, heading, rounded Card, status bar or navigation chrome. **Back to Argo**
restores the embedded layout. Global keys retain the same native platform-view
ID across the layout change; no Android Auto session is created or renegotiated.
The renderer test uses the same controls and surface. Input is cancelled when
switching presentation geometry, and the overlay control intercepts its own taps.

Expanded layout targets source width/height divided by Flutter's reported
`devicePixelRatio`, centred on physical-pixel-aligned offsets. If the viewport is
too small, it fits the full source with preserved aspect ratio. The overlay shows
physical destination dimensions and says **1:1 physical pixels** only when both
match the source within 0.01 pixel; otherwise it says **scaled to fit**. This
measures Flutter's physical destination, not an unobservable subsequent resample
by the desktop compositor/monitor. No crop, stretch, AA DPI/resolution/bitrate,
native filtering or buffer-allocation settings change.

Enable bounded geometry logs for live projection with
`ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS=1`, or run the phone-independent comparison:

```bash
ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS=1 tool/projection/run_renderer_test.sh
```

Geometry logging is off by default and remains independent of renderer-test
logging. Each new layout reports source descriptor dimensions, viewport and
fitted logical dimensions, fitted offset, DPR, physical destination size, X/Y
scale and content/safe insets. The existing native first-sample log supplies the
actual decoded dimensions/format/stride for comparison with the descriptor.
Rendering and touch mapping use the same fit calculation. Content insets are
removed once for input normalisation; safe insets are reported as metadata and
are not subtracted again. Pointer positions are logical, so mapping does not
multiply them by DPR. The full source image remains visible.

Validation: three focused regressions cover outside terminals/subsequent input,
ownership loss without duplicate cancellation or pending-move backlog, and the
shared fitted render/touch rectangle with letterboxing, content/safe insets and
DPR 2. The comparison test exercises the actual shell, verifies chrome removal,
1:1 versus smaller-window fallback, and unchanged native creation count. Existing
Rust pointer coverage verifies gesture-wide CANCEL versus single-pointer UP.
Code/test acceptance is separate from VM mouse/focus/unplug acceptance and from
whether live-image artifacts persist at a measured 1:1 destination.

VM comparison result: the rebuilt release bundle ran through the existing IHS
executable with one native view across embedded/expanded transitions. At DPR 1,
the embedded destination measured 1031.11 × 580 pixels (0.80556× source), and
Compare size measured 1280 × 720 pixels (1:1), centred in a 1920 × 720 viewport.
The user confirmed the moving native bars look clean at 1:1. This establishes
the pattern's visual result, not live Android Auto image quality at that size.
Live-phone outside-release and module-switch gesture acceptance has not yet been
tested. The diagnostic instance was stopped after the comparison.

Validation for this change passed: analyzer, 38 focused Flutter tests, 38 Rust
tests, Clippy with warnings denied, and the release daemon build. The existing
wire fixture emitted no routine packet/ping metadata at default/INFO and restored
that metadata at TRACE. Flutter Engine and IHS were not rebuilt.

## Configuration ownership acceptance (IPC v3)

Rebuild the daemon and bundle using the commands above. Stop previous owned
processes before staging; this is an incompatible v1/v2→v3 control change. Do not
regenerate credentials. Use the **same existing identity** only in terminal 1;
terminal 2 explicitly unsets both identity variables. No phone session may have
started before the request if you want it to use Argo's saved configuration;
a standalone session already in progress keeps its initial selection.

1. Start terminal 1's daemon, then terminal 2's homescreen with identity variables
   unset. Open Settings → Android Auto / Apple CarPlay. Verify readiness and
   supported modes. With no session, Current session says none and Next connection
   shows the acknowledged default/saved values; it is not labelled active.
2. Connect the phone deliberately. Check the selected session configuration and
   actual picture/audio/touch. Use default 1280×720/30 first. Backend Ready and
   acknowledgement alone do not establish phone acceptance.
3. During projection, change **driver side** (or DPI 160→180, pressing Enter).
   Saved request and validated Next connection should change; Current session
   selected and its ID should retain the old configuration. Check that picture,
   audio and input remain on that session. There is no automatic disconnect.
4. Deliberately unplug/replug. The new session should select the acknowledged
   preference. Check phone picture/audio/touch again, not just the metadata label.
   Higher resolution/FPS is a separate phone/performance experiment.
5. Close Argo normally, restart terminal 2 with both identity variables still
   unset, and verify Saved request survived. If a standalone phone session stayed
   active, Argo must show its actual selection and queue any differing preference.
6. Stop owned homescreen/daemon processes. Run `tool/projection/run_renderer_test.sh`
   from the Argo root; it explicitly disables projection backend and clears identity
   and socket variables. Select Media and check moving native bars inside Argo.

Keep each manual rendering check short. The known IHS eventfd leak is unchanged:
if `dup(release eventfd)`/FD-exhaustion failures appear, capture the log and stop
that run immediately. Do not raise limits, hide warnings, or infer endurance from
short success. New-session settings, live input and audio acceptance for this
configuration patch remain manual; record the revision and phone/VM environment.

The Settings card reports fixed read-only native PCM formats. Safe-area saved
keys are retained but not applied; no enabled control pretends otherwise. Source
FPS/DPI, Flutter DPR, physical refresh and presentation scale have distinct labels.
Missing/invalid daemon identity still permits the control UI to report capabilities
and an actionable error. Correct daemon configuration and restart it; there is no
automatic daemon spawning/reconnect supervisor. A second control client receives
an ownership error instead of racing the first client's preferences.

## Host metadata and Lua acceptance (IPC v3)

This revision advertises read-only media status on runtime channel **10** using
service descriptor field 9. Existing video/audio/input descriptors and TLS remain
unchanged. Rebuild both Argo and daemon: IPC v3 explicitly rejects v1/v2 peers.
The earlier configuration-ownership workflow still applies with matching v3 builds.

Wire references were inspected, not copied/vendored: public
[media channel notes](https://github.com/mrmees/open-android-auto/blob/main/docs/channels/media.md),
[playback status schema](https://github.com/mrmees/open-android-auto/blob/main/oaa/media/MediaPlaybackStatusMessage.proto),
[track schema](https://github.com/mrmees/open-android-auto/blob/main/oaa/media/MediaPlaybackMetadataMessage.proto),
[battery schema](https://github.com/mrmees/open-android-auto/blob/main/oaa/control/BatteryStatusMessage.proto),
and [discovery request schema](https://github.com/mrmees/open-android-auto/blob/main/oaa/control/ServiceDiscoveryRequestMessage.proto).
These are public reverse-engineered references, not Google certification or
acceptance on this VM's phone. Argo's bounded reader is implemented independently.

| Message | Fields handled / semantics |
|---|---|
| Media channel `0x8001` | Playback enum field 1 (unknown/stopped/playing/paused/error), optional application field 2, optional position field 3 (seconds → milliseconds). Independent status patch. |
| Media channel `0x8003` | Optional title/artist/album fields 1/2/3 replace the previous track description; omitted artist/album clear old values. Artwork field 4 and unknown fields are skipped without copying into state/IPC. A changed track clears the old reported position. |
| Control `0x17` | Optional battery percentage field 1 (0..100) and critical-battery boolean field 3. Independent patches; omitted fields stay unknown or retain their last explicitly reported value within this session. Discharge-time field 2 is unused. |
| Control discovery `0x05` | Optional phone display name field 4 and brand/manufacturer field 5. Icon blobs and session-info internals are skipped. No model inferred from USB identity. |

The inspected phone-sourced schema does **not** establish duration semantics for
its unknown fields. Duration is supported as a nullable application/IPC/API value
but remains unknown for this AA provider. A duration field in a different
CarLocalMedia service must not be reused here. Model and charging also remain
unknown. Sparse positions are not interpolated. A changed known application
clears prior track details while awaiting that application's metadata. Malformed
optional messages retain the prior valid snapshot/receive time and are discarded
without failing video/audio; warnings are bounded per session/message type.

### Build and synthetic native-Lua check

First stop owned homescreen and daemon processes; do not overwrite their running
artifacts. Use the [native view/bundle build commands](#build-the-native-view-and-argo-bundle)
for the existing `argo-release-x86_64` bundle, and build the daemon:

```bash
set -euo pipefail
export ARGO="$HOME/dev/argo"
if pgrep -u "$UID" -x homescreen >/dev/null || \
   pgrep -u "$UID" -f '(^|/)argo-projectiond([[:space:]]|$)' >/dev/null; then
  echo 'Stop your existing homescreen and daemon before rebuilding/staging.' >&2
  exit 1
fi
source "$HOME/.cargo/env"
cargo build --manifest-path "$ARGO/native/projection/argo-projectiond/Cargo.toml" \
  --release --features linux-usb,linux-media --offline
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
source "$FLUTTER_WORKSPACE/setup_env.sh"
cd "$ARGO"
VELOCE_LUA_LIBRARY="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64/lib/libveloce_lua_native.so" \
  flutter test --no-pub test/integrations/veloce/argo_host_state_bridge_test.dart
```

This test uses the real isolated native Lua runtime with a fake source: immediate
current read, coalesced invalidation, forged-hint resistance, undeclared permission,
reload, stale generation and disconnect/unload cleanup. It is **not phone
acceptance**. No engine/IHS rebuild or phone is needed for that exercise.

### Real phone and observer

Start the daemon using [terminal 1](#one-real-device-workflow), keeping existing
identity files only there. With homescreen stopped, use this terminal 2 instead
of the empty-plugin example. It installs only the synthetic observer, with the
**generic** profile and no example CAN or vehicle-policy plugins:

```bash
set -euo pipefail
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
export IHS_PREFIX="${IHS_PREFIX:-$HOME/dev/ivi-build/out/usr/local}"
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
source "$FLUTTER_WORKSPACE/setup_env.sh"
: "${XDG_RUNTIME_DIR:?Run in your desktop login session}"
if pgrep -u "$UID" -x homescreen >/dev/null; then
  echo 'Stop homescreen before staging the observer.' >&2
  exit 1
fi
unset ARGO_ANDROID_AUTO_CERT_FILE ARGO_ANDROID_AUTO_KEY_FILE
unset ARGO_SIMULATION_SCENARIO ARGO_VEHICLE_INTEGRATIONS_DIR VELOCE_CAN_INPUT
export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock"
export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/argo/projection-video.sock"
export VELOCE_PLUGIN_DIR="$HOME/.local/share/project-argo/host-media-demo"
install -d -m 700 "$VELOCE_PLUGIN_DIR/host_media"
install -m 600 "$ARGO/tool/vehicle_integrations/example-vehicle/plugins/host_media/manifest.json" \
  "$VELOCE_PLUGIN_DIR/host_media/manifest.json"
install -m 600 "$ARGO/tool/vehicle_integrations/example-vehicle/plugins/host_media/main.lua" \
  "$VELOCE_PLUGIN_DIR/host_media/main.lua"
export ARGO_PROJECTION_RENDER_TEST=0 ARGO_PROJECTION_BACKEND=android-auto
export ARGO_MODE=simulation ARGO_VEHICLE_PROFILE=generic
export ARGO_HOST_POWER_BACKEND=disabled ARGO_AUDIO_BACKEND=pipewire
export ARGO_HOST_STATE_DIAGNOSTICS=1
export LD_LIBRARY_PATH="$IHS_PREFIX/lib:$BUNDLE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VELOCE_LUA_LIBRARY="$BUNDLE/lib/libveloce_lua_native.so"
"$IHS_PREFIX/bin/homescreen" -b "$BUNDLE" --backend wayland-egl --width=1280 --height=720 \
  2>&1 | tee /tmp/argo-host-media.log
```

1. Connect the phone and play a track. Compare Media's title/artist/playback with
   the explicitly enabled `[Argo host observer ...]` DEBUG summary in terminal 2.
   Wait at least three seconds per observation because diagnostic output coalesces;
   cached reads are immediate. No playback buttons are provided.
2. Change track, pause/resume and verify both consumers. Artist/album must not
   linger from the preceding track when omitted. Position may be sparse; duration
   remains unknown until a verified provider supplies it.
3. Reload only the external synthetic resource while the phone stays connected:

   ```bash
   observer_file="$HOME/.local/share/project-argo/host-media-demo/host_media/main.lua"
   printf '\n-- Synthetic observer reload check.\n' >> "$observer_file"
   ```

   Veloce's existing watcher coalesces the save and reloads its generation. The
   freshly loaded observer immediately logs current state without waiting for a
   new track. No new AA session is created.
4. Disconnect. Argo and the observer must lose obsolete live track/phone state.
   Record whether this particular phone supplied battery percentage/critical state;
   absent battery does not fail media acceptance. Charging is unknown.
5. Stop owned processes normally. Keep manual rendering short and stop immediately
   on the known IHS release-eventfd/FD-exhaustion warning; do not raise limits or
   infer endurance from successful metadata reads. The phone-independent renderer
   launcher remains `tool/projection/run_renderer_test.sh` and clears these options.

Turn off `ARGO_HOST_STATE_DIAGNOSTICS` after this deliberate check; logs can contain
private track/device text. Only explicitly installed, host-read-authorized Lua
resources can read the API; public invalidation events carry no such text.
See the [exact Lua fields/permissions](../../docs/vehicle-integrations.md#read-only-argo-host-state-v1).
