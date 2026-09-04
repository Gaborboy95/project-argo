# Projection development and wired Android Auto validation

Project Argo does not contain Android Auto credentials. The two files supplied
below must be a legitimately provisioned, compatible head-unit identity; never
use credentials copied from another open-source project or accessory.

## Non-hardware validation

From the Argo repository:

```bash
flutter test test/core/projection test/integrations/projection \
  test/app/projection_composition_test.dart test/features/projection
flutter analyze --no-pub

cd native/projection
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

The Rust tests use a fake USB control transport. They assert the exact AOAP
operation order (`GET_PROTOCOL`, six `SEND_STRING` operations, then `START`),
the re-enumeration lifecycle, bounded IPC, malformed-frame rejection, and
bounded media queues. No USB device or host audio device is touched.

## Build on the Linux target

Install the target's development packages for PipeWire, GStreamer, libusb and
the current `ihs_shared` SDK. Package names vary by distribution. Then:

```bash
cd "$HOME/dev/argo/native/projection"
cargo build --release --features linux-usb

cmake -S argo-projection-view -B build/view \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$IHS_INSTALL_PREFIX"
cmake --build build/view --parallel

install -Dm755 target/release/argo-projectiond \
  "$HOME/.local/bin/argo-projectiond"
install -Dm755 build/view/libargo_projection_view.so \
  "$HOME/.local/lib/libargo_projection_view.so"
```

The view queries the active IHS capabilities. It does not infer EGL, Vulkan,
DRM or Wayland from a backend name. A compatible DMA-BUF texture is preferred,
then a compatible DRM plane, with RGB software shared memory as the universal
fallback. Output changes invoke per-view renegotiation.

## Identity and sidecar

```bash
install -m 600 /secure/provisioning/argo-aa-client.key \
  "$HOME/.config/project-argo/android-auto.key"
install -m 644 /secure/provisioning/argo-aa-client.crt \
  "$HOME/.config/project-argo/android-auto.crt"

install -d -m 700 "$XDG_RUNTIME_DIR/argo"
ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock" \
  "$HOME/.local/bin/argo-projectiond"
```

In a second terminal, build and launch Argo through the production embedder:

```bash
cd "$FLUTTER_WORKSPACE"
emb bundle \
  --app-path "$HOME/dev/argo" \
  --arch x86_64 \
  --build

cd "$HOME/dev/argo"
LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
ARGO_MODE=production \
ARGO_PROJECTION_BACKEND=android-auto \
ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock" \
ARGO_PROJECTION_VIEW_LIBRARY="$HOME/.local/lib/libargo_projection_view.so" \
ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/project-argo/android-auto.crt" \
ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/project-argo/android-auto.key" \
ARGO_AUDIO_BACKEND=pipewire \
ivi-homescreen \
  -b "$FLUTTER_WORKSPACE/bundle/argo-release-x86_64" \
  --w=1280 --h=720
```

Only after both processes are ready, unlock an Android phone, enable Android
Auto, and connect it directly over USB. `lsusb` may be used for observation,
but Argo never shells out to it; AOAP and bulk endpoint discovery use `nusb`.

Expected acceptance sequence:

```text
phone candidate discovered
AOAP accessory mode requested
phone re-enumerated with accessory bulk endpoints
version negotiation and authenticated TLS complete
main H.264 stream appears in the generic Projection page
touch maps only inside the negotiated phone content area
media/speech/system audio routes natively through PipeWire
unplug removes the session; replug creates a fresh session
```

## Current external acceptance gate

The repository intentionally includes no Android Auto certificate/private key.
Without independently provisioned compatible credentials, selection fails
before USB/session startup with an identity diagnostic. Unit tests and fake USB
validation do not prove acceptance with a real phone.

The checked-in sidecar establishes the versioned IPC, credential validation,
AOAP request seam, hotplug/re-enumeration model, endpoint discovery, bounded
queues, and modular session/channel state. The proprietary on-wire Android Auto
service discovery/channel message implementation is not copied from LIVI and
is not claimed as hardware-complete here. A real-phone run must therefore be
treated as blocked until that independently implemented protocol engine and a
legitimate identity are available; do not bypass either requirement.
