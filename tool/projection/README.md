# Projection build reference

This is the authoritative build/dependency reference for the Linux AA daemon,
IHS platform view and release bundles. [Setup](../../docs/setup.md) defines the
reference layout and one current launch workflow. [Wireless](../../docs/wireless.md)
defines pairing, AP/security and lifecycle behavior.

## Toolchains and dependencies

The reference workspace uses Flutter 3.47.2 / Dart 3.13.2, Flutter revision
`d3b14c876900e553bc736ca19295fc09e3853e8e` and Engine
`a804b261645ef8c13eb3d5c44a5c2fb0340c5539`. Use its setup_env.sh and installed emb
executable; do not substitute a random SDK for an AOT build. Argo's sibling Veloce
integration requires the core/native packages from pubspec.yaml; the host namespace
contract has been exercised with Veloce `d169d4cd6d10c1f38c534f425de83a75f1192ca9`.
Keep dependency revisions and local patches with deployment build records.

Cargo uses the checked-in lockfile. The crate declares Rust 1.88+ and edition 2024;
the installed reference toolchain is Rust 1.98.1. Native development needs CMake 3.20+,
Ninja, C++20, pkg-config, IHS headers/library, GBM/EGL/Vulkan and GStreamer development
libraries. Hardware daemon builds select `linux-usb,linux-media`. Required runtime
media plugins include H.264 decoding and PipeWire audio output.

On Debian/Ubuntu, provisioning is an explicit administrator action. Typical packages
include build-essential, pkg-config, cmake, ninja-build, openssl, usbutils,
libudev-dev, libdbus-1-dev, libgbm-dev, libegl-dev, libvulkan-dev,
libgstreamer1.0-dev, libgstreamer-plugins-base1.0-dev, gstreamer1.0-tools,
gstreamer1.0-plugins-base/good/bad, gstreamer1.0-libav, gstreamer1.0-pipewire,
pipewire and wireplumber. Wireless also needs BlueZ, NetworkManager, iw, nftables
and polkit. Inspect installed packages before provisioning; ordinary builds do not
install software or restart services. [Rust toolchain installation](https://sh.rustup.rs)
is separate from an Argo build.

## IHS base and local patch

The Mu IHS source is based on
`50cbfb5b29266821091dd5a15edb6fe0a8547a91` with a local change in
`shell/platform/homescreen/platform_views/platform_view_host.cc`.
`BUILD_COMPOSITOR=ON` is required. Headers, libihs_shared.so and homescreen must
come from the same installed build.

The Mu change reconstructs the Wayland-EGL release-eventfd correction associated
with VM-local commit `35a5f852`. It is **not an upstream release and is not claimed
byte-identical to that VM commit**. In HostSubmit's EGL texture path, the unconditional
HandBackReleaseEventfd call is guarded as follows:

```cpp
BackendEglContext egl{};
Backend* backend = BackendOf(user_data);
if (backend != nullptr && backend->GetEglContext(&egl) &&
    egl.gbm_device != nullptr) {
  v->HandBackReleaseEventfd(frame->buffer_id, out_release_fence_fd);
}
```

Wayland-EGL lacks the OnScanoutRelease callback that retires those per-buffer
scanout eventfds. The guard preserves its existing GL release-fence handling and
GBM/DRM behavior. The local diff's SHA-256 at the reference setup is
`e90b3b077c3a133bcaeb685bf3f054eb1f14efeabc21e8916d4fac78c3f7d584`.
Record any subsequent dependency patch changes in the release manifest. Do not reset
or update this checkout as part of an Argo build. DRM/KMS GL-fallback retirement and
long-running projection still need separate validation.

## Daemon build and safe staging

Define the reference paths from [setup](../../docs/setup.md#reference-layout-and-dependencies).
Build only the daemon for Rust-only changes:

```bash
cd "$ARGO"
cargo fmt --manifest-path native/projection/Cargo.toml --check
cargo test --locked --offline --manifest-path native/projection/Cargo.toml --features linux-usb,linux-media
cargo clippy --locked --offline --manifest-path native/projection/Cargo.toml --all-targets --features linux-usb,linux-media -- -D warnings
cargo build --locked --offline --release --manifest-path native/projection/Cargo.toml --features linux-usb,linux-media
```

Offline builds require cached locked dependencies. Resolve missing dependencies
explicitly without updating the lockfile; do not silently upgrade the toolchain.
Tests use OpenSSL for isolated memory-TLS fixtures, not production identity provisioning.

Choose an existing compatible IPC v5 bundle and a **new, nonexistent** destination.
ARGO_BASE_BUNDLE and ARGO_RELEASE below are shell recipe variables, not application
configuration options.
The working source bundle may remain running because its files are only read:

```bash
set -euo pipefail
: "${ARGO_BASE_BUNDLE:?Set an existing compatible IPC v5 release directory}"
: "${ARGO_RELEASE:?Set a new absolute release directory}"
test -d "$ARGO_BASE_BUNDLE"
test ! -e "$ARGO_RELEASE"
cp -a "$ARGO_BASE_BUNDLE" "$ARGO_RELEASE"
install -m 755 "$ARGO/native/projection/target/release/argo-projectiond" "$ARGO_RELEASE/bin/argo-projectiond"
install -m 755 "$ARGO/tool/connectivity/run-release.sh" "$ARGO_RELEASE/run-release.sh"
export ARGO_WIRELESS_BUNDLE="$ARGO_RELEASE"
```

Run the recipe in Bash with `set -euo pipefail` so any failed check stops staging.
Verify unchanged application/native asset hashes against the source bundle. Replace
the **new directory's** copied build manifest with the source revision, IPC version,
toolchain/features, dependency/asset hashes and validation scope for this build.
Keep the previous bundle as rollback. Stop the previous processes before selecting
the new bundle through the [shared launch workflow](../../docs/setup.md#projection-launch).
No Engine, IHS, Flutter application or native-view rebuild is needed for this path.

## Build the native view and Argo bundle

Use this path only when application or view sources change. Select a new output
ARGO_RELEASE directory and matched installed IHS_PREFIX; do not replace a loaded library.

```bash
set -euo pipefail
: "${ARGO:?Set checkout path}"
: "${FLUTTER_WORKSPACE:?Set installed workspace path}"
: "${IHS_PREFIX:?Set matching installed IHS prefix}"
: "${ARGO_RELEASE:?Set a new release directory}"
test ! -e "$ARGO_RELEASE"
source "$FLUTTER_WORKSPACE/setup_env.sh"
export PATH="$HOME/.local/state/Dart/install/bin:$PATH"
test -f "$IHS_PREFIX/include/ihs/platform_view.h"
test -f "$IHS_PREFIX/lib/libihs_shared.so"
unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR
cmake -S "$ARGO/native/projection/argo-projection-view" \
  -B "$ARGO/build/native-projection" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DIHS_INCLUDE_DIR="$IHS_PREFIX/include" \
  -DIHS_SHARED_LIBRARY="$IHS_PREFIX/lib/libihs_shared.so"
cmake --build "$ARGO/build/native-projection"
emb bundle --app-path "$ARGO" --workspace "$FLUTTER_WORKSPACE" \
  --arch x86_64 --mode release --build --output "$ARGO_RELEASE"
install -m 755 "$ARGO/build/native-projection/libargo_projection_view.so" "$ARGO_RELEASE/lib/libargo_projection_view.so"
install -d "$ARGO_RELEASE/bin"
install -m 755 "$ARGO/native/projection/target/release/argo-projectiond" "$ARGO_RELEASE/bin/argo-projectiond"
install -m 755 "$ARGO/tool/connectivity/run-release.sh" "$ARGO_RELEASE/run-release.sh"
```

Build the daemon first using the preceding section. emb must already be installed;
its location above is the reference Dart executable path. Do not use a global
pkg-config sysroot for system GStreamer. Record source/dependency hashes and verify
libapp.so, libflutter_engine.so, libargo_projection_view.so, libveloce_lua_native.so
and libsqlite3.so in the bundle. No Engine or IHS rebuild is part of this recipe.

## Identity and USB permissions

Use existing external daemon identity files. The [configuration contract](../../docs/configuration.md#projection)
requires PEM certificates and a PKCS#8 `BEGIN PRIVATE KEY` PEM. No credentials or
phone-accepted self-signed generation workflow are supplied here. Wireless TLS
signature verification is distinct from the legacy USB certificate policy.

USB access must cover the phone's normal VID/PID and Google AOAP accessory IDs.
Discover the normal IDs with `lsusb`; do not grant blanket USB access. An administrator
can install narrowly scoped udev rules using mode 0660 and seat uaccess or an appropriate
local group. Reloading rules and group changes are explicit provisioning actions;
replug/logout may be required. A VM must forward both normal and accessory identities.
Do not run Argo or the daemon as root.

## Phone-independent native renderer diagnostic

From the Argo root with the reference workspace available:

```bash
cd "$ARGO"
tool/projection/run_renderer_test.sh
```

The script builds a dedicated app/view bundle, selects videotestsrc, disables real
backends and isolates inherited credentials, integrations and sockets. It writes
`/tmp/argo-renderer-test.log`. Run it only when renderer validation is needed; it is
not the LIVE AA launch command and does not validate wireless/TLS/audio.

### Flutter/IHS composition contract

Projection uses PlatformViewLayer with a stable native view ID, never Flutter
TextureLayer/AndroidView composition. GStreamer decodes/converts H.264 and exports
fresh linear RGB DMA-BUF allocations after checking the host's format/modifier and
EGL/Vulkan device capabilities. This is not zero-copy decoding. SHM requires a real
host-provided buffer; merely advertising SHM is insufficient. Source and destination
sizes are independent, and output renegotiation is supported.

### Gesture ownership and daemon logging

Input uses the single ProjectionView mapped Listener. Native controller dispatch is
a no-op. Ownership loss, resize and session replacement cancel retained gestures.
ARGO_PROJECTION_LOG_LEVEL controls bounded diagnostic detail without dumping media
or credentials. Renderer and daemon logs are separate.

### Fullscreen presentation geometry

```bash
cd "$ARGO"
ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS=1 tool/projection/run_renderer_test.sh
```

Select Home and compare the measured fitted destination against the actual window.
The launcher requests 1280×720; black letterboxing preserves source aspect ratio.
AA Exit returns to Media through session focus, not renderer teardown.

## Host metadata and Lua

The optional synthetic host_media resource demonstrates permission-controlled
`argo_host.snapshot()` reads and invalidation events. Its API contract and loading
workflow are in [plugin authoring](../../docs/vehicle-integrations.md#read-only-argo-host-state-v1)
and [the example integration](../vehicle_integrations/README.md#optional-host-media-observer).
Metadata, track changes and navigation must not replace the native view. No raw
media or AA identity is exposed to Lua.

## Technical references

- [IHS platform-view API](https://github.com/toyota-connected/ivi-homescreen/blob/main/shared/include/ihs/platform_view.h).
- [Vulkan DRM device properties](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDrmPropertiesEXT.html).
- [rustls 0.23.22](https://docs.rs/rustls/0.23.22/rustls/).
- [LIVI](https://github.com/f-io/LIVI); pinned wireless references are in the [wireless guide](../../docs/wireless.md#protocol-references).
- [AA media channels](https://github.com/mrmees/open-android-auto/blob/main/docs/channels/media.md),
  [battery](https://github.com/mrmees/open-android-auto/blob/main/oaa/control/BatteryStatusMessage.proto),
  [discovery](https://github.com/mrmees/open-android-auto/blob/main/oaa/control/ServiceDiscoveryRequestMessage.proto),
  [media metadata](https://github.com/mrmees/open-android-auto/blob/main/oaa/media/MediaPlaybackMetadataMessage.proto),
  [playback status](https://github.com/mrmees/open-android-auto/blob/main/oaa/media/MediaPlaybackStatusMessage.proto).
- [Video focus request](https://github.com/f1xpl/aasdk/blob/master/aasdk_proto/VideoFocusRequestMessage.proto) and
  [focus mode](https://github.com/f1xpl/aasdk/blob/master/aasdk_proto/VideoFocusModeEnum.proto).
