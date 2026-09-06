# Wired Android Auto

The user has proven AOAP, accessory re-enumeration, bulk endpoints and Android
Auto VersionResponse **1.7** on a real phone. The daemon now continues into
TLS 1.2, discovery, main H.264 video, touch, and media/speech/system audio.
**Post-version hardware acceptance is still pending.** Unit tests are not a
claim that phone UI, audio, or the production embedder have worked on hardware.

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

Keep your existing Argo-owned RSA identity. Only if one does not exist, create
your own; no project/accessory credentials are provided or required:

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

The files are parsed and checked for a matching key pair. TLS is restricted to
1.2; resumption is disabled. The AA-only USB peer verifier does **not** claim
WebPKI certificate-chain, hostname, or signature authentication: some AA peers
use legacy certificates. This permissive policy is isolated in `aa_tls.rs`,
never applied to IPC or network clients. TLS Finished verification is mandatory.
Generated RSA identities pass the in-memory TLS test; acceptance by your actual
phone still requires its TLS log. No certificate or private key is logged.

## Build the native view and Argo bundle

Use the headers, pkg-config file and library from the **same IHS build** that
will run Argo:

```bash
export ARGO="$HOME/dev/argo"
export IHS_PREFIX="$HOME/dev/ivi-build/out/usr/local"
export PKG_CONFIG_PATH="$IHS_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cmake -S "$ARGO/native/projection/argo-projection-view" \
  -B "$ARGO/native/projection/argo-projection-view/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$ARGO/native/projection/argo-projection-view/build"

cd "$FLUTTER_WORKSPACE"
emb bundle --app-path "$ARGO" --arch x86_64 --build
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
install -m 755 \
  "$ARGO/native/projection/argo-projection-view/build/libargo_projection_view.so" \
  "$BUNDLE/lib/libargo_projection_view.so"
test -f "$BUNDLE/lib/libveloce_lua_native.so"
```

The native view queries IHS capabilities, format/modifier support and the active
EGL/Vulkan device. The initial export path uses native BGRx conversion and fresh
linear RGB DMA-BUF allocations, avoiding reuse before compositor release.
IHS scales the source into the aspect-correct Flutter view. This is a correctness
path, not a zero-copy decoder claim. No EGL/Vulkan backend name is assumed.
SOFTWARE_SHM is used only if the host supplies an actual buffer; current upstream
IHS advertises that kind but its host adapter does not allocate one. A VM needs
a usable render device/GBM linear allocation or a functioning host SHM grant.
An unsupported grant produces a specific native diagnostic, not an invented
working renderer. Output renegotiation is implemented.

## One real-device workflow

Terminal 1 — start the standalone daemon **before plugging in the phone**:

```bash
export ARGO="$HOME/dev/argo"
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
export ARGO="$HOME/dev/argo"
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
export ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/project-argo/android-auto/argo.crt"
export ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/project-argo/android-auto/argo.key"
export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock"
export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/argo/projection-video.sock"

systemctl --user status pipewire wireplumber --no-pager
gst-inspect-1.0 h264parse
gst-inspect-1.0 pipewiresink

cd "$HOME/dev/ivi-build"
export LD_LIBRARY_PATH="$PWD/out/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$BUNDLE/lib:$LD_LIBRARY_PATH"

ARGO_MODE=simulation \
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_AUDIO_BACKEND=pipewire \
ARGO_PROJECTION_BACKEND=android-auto \
VELOCE_LUA_LIBRARY="$BUNDLE/lib/libveloce_lua_native.so" \
"$PWD/out/usr/local/bin/homescreen" -b "$BUNDLE" --w=1280 --h=720 \
  2>&1 | tee /tmp/argo-homescreen.log
```

Use the existing vehicle/profile/plugin environment if your normal Argo launch
requires it. Android Auto itself does not depend on a vehicle profile.
Select **Media** in Argo, unlock the phone, and plug it in. Accept any phone-side
Android Auto prompts. Then verify touch, music and a navigation announcement.
Use **Return to Argo** / **Show projection** to switch the surface. Unplug must
clear projection while leaving Argo alive; replug must create a fresh session.

Expected stages:

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
the existing Argo preferences supplied before connection select supported
800x480/1280x720/1920x1080 and 30/60 FPS. Unsupported sizes fail explicitly.
Only night/driving-status sensors are currently advertised: absent vehicle
inputs mean day mode and conservative driving restrictions, never fictitious
speed/RPM/parking-brake data. Microphone capture is not advertised or implemented.

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

Validation in the development environment: 38 Linux Rust tests passed (eight
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
[rustls](https://docs.rs/rustls/0.23.43/rustls/),
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
`<IHS prefix>/bin/homescreen --backend wayland-egl --w=1280 --h=720`.
It does not rebuild IHS or Flutter Engine, update repositories, or require root.
It refuses to stage while another launcher or the user's homescreen is running.
Runtime output goes to `/tmp/argo-renderer-test.log`; a homescreen failure remains
a failing shell exit status through `tee`.

`ARGO_PROJECTION_RENDER_TEST=1` is a process-environment flag, supported in AOT.
Unset or `0` preserves normal selection; other values are rejected. Test mode
requires the disabled projection backend (also the default); combining it with
`ARGO_PROJECTION_BACKEND=android-auto` fails before identity validation or backend
construction. No AA session or public test protocol is created. The launcher
sets simulation, generic vehicle profile, and disabled projection/audio/host
power backends. It clears inherited Argo/Veloce integration and scenario settings,
projection sockets and certificates, and uses isolated empty plugin/integration
directories and temporary settings. An explicit
`ARGO_PROJECTION_DRM_RENDER_NODE` is preserved; otherwise native device discovery
is used. No daemon, phone, USB inspection or media-socket connection is needed.

The presentation path is unchanged: `ProjectionView` creates `AndroidView` with
`argo.projection.view` and `StandardMessageCodec`, using Flutter's existing
platform-view ID, create, layout and dispose messages. In the installed Flutter
framework this is `PlatformViewsService.initAndroidView()` →
`TextureAndroidViewController` → `RenderAndroidView`/`TextureLayer` composition.
It is not switched to a hybrid/surface controller. The same dynamically loaded
`libargo_projection_view.so` registers the same IHS factory. Only native source
selection changes: `videotestsrc` feeds the existing bounded `projection_sink`
appsink, `OnSample()` and `SubmitRgb()`. All pixels remain native.

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

Validation of this diagnostic in the Linux VM: formatting, analyzer and all 30
focused projection/Media tests passed (two new checks). The C++ library built
against the installed IHS, and the launcher built/staged the release bundle and
ran the existing wayland-egl homescreen. GStreamer 1.24.2 supplied 1280×720 BGRx
samples with stride 5120; IHS granted kind 1 and accepted 2,450 submissions
with actual modifier `0x00ffffffffffffff` and no reported submission failures.
The process environment had no projection socket/certificate variables. Stopping
the launched homescreen logged native-view destruction and the final counters.
The user observed a **blank surface** on Media. This reproduces the presentation
failure without Android Auto; visible renderer acceptance has **not** passed.
