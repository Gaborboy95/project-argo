# Wired Android Auto checkpoint

Milestone 14.1 stops immediately after a phone returns a valid Android Auto
`VersionResponse`. It does not send TLS, service-discovery, media, audio, or
input bytes. The daemon can prove this checkpoint without Flutter or
ivi-homescreen running.

Project Argo does not contain Android Auto credentials. Certificate/key
validation remains on the Flutter IPC path for the later TLS checkpoint; the
standalone USB/version proof does not need an identity because it never starts
TLS.

## Automated validation

From the Argo repository:

```bash
cd native/projection
cargo fmt --check
cargo test
cargo test --all-features
cargo clippy --all-targets --all-features -- -D warnings

cd ../..
dart format lib test
flutter test
flutter analyze --no-pub
git diff --check
```

The native tests use fake USB/control and byte-stream transports. No USB
device is opened. They cover the AOAP request order, failed probes,
re-enumeration/unplug state, endpoint selection, bounded incremental framing,
split and coalesced `VersionResponse` input, malformed lengths, disconnects,
and the deliberate stop before TLS.

## Debian / Ubuntu build

Install a native compiler, udev headers/tools, and Rust:

```bash
sudo apt update
sudo apt install -y build-essential ca-certificates curl pkg-config libudev-dev usbutils

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"
rustup component add clippy rustfmt

cd "$HOME/dev/argo/native/projection"
cargo build --release --features linux-usb
```

`nusb` uses Linux usbfs directly. The daemon must be able to open the phone's
`/dev/bus/usb/...` node, but it should not run permanently as root.

## Identify the phone and install a narrow udev rule

Connect the unlocked phone in its normal USB mode and note its exact VID/PID:

```bash
lsusb
lsusb -t
```

For example, a line ending in `ID 18d1:4ee7` means `PHONE_VID=18d1` and
`PHONE_PID=4ee7`. Replace those two values below with the values from the real
phone. The rule deliberately grants access only to that normal-mode VID/PID
and the six standard Google accessory PIDs:

```bash
PHONE_VID=18d1
PHONE_PID=4ee7

sudo groupadd -f plugdev
sudo usermod -aG plugdev "$USER"

sudo tee /etc/udev/rules.d/70-project-argo-android-auto.rules >/dev/null <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="$PHONE_VID", ATTR{idProduct}=="$PHONE_PID", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d00", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d01", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d02", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d03", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d04", GROUP="plugdev", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d05", GROUP="plugdev", MODE="0660", TAG+="uaccess"
EOF

sudo udevadm control --reload-rules
```

Log out and back in if `id -nG` does not yet include `plugdev`, then unplug the
phone. Avoid a broad all-USB permission rule.

## Standalone first-phone test

Flutter and ivi-homescreen are unnecessary for this checkpoint:

```bash
install -d -m 700 "$XDG_RUNTIME_DIR/argo"
cd "$HOME/dev/argo/native/projection"

ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock" \
  RUST_BACKTRACE=1 \
  target/release/argo-projectiond 2>&1 \
  | tee /tmp/argo-projectiond-version.log
```

Now unlock the Android phone, ensure Android Auto is enabled, and connect it
directly rather than through an unpowered hub. In another terminal, observe
the normal and accessory identities if useful:

```bash
watch -n 0.5 lsusb
```

The required daemon proof is this complete sequence (numeric values vary):

```text
USB candidate detected: vvvv:pppp
AOAP protocol version N
AOAP accessory switch requested
original USB device removed; waiting for Android accessory
Android accessory detected
bulk interface claimed: interface=N alternate=N in=0x.. out=0x..
AA VersionRequest sent
AA VersionResponse received
Android Auto version negotiation succeeded: phone protocol major=X minor=Y
```

At that point the session is parked in `WaitingForTls`; no TLS bytes are sent.
Stop the daemon with Ctrl+C. To inspect or share the bounded checkpoint log:

```bash
sed -n '/USB candidate detected/,$p' /tmp/argo-projectiond-version.log
```

Unplug at any earlier point must remove the current attempt without exiting
the daemon. A later replug starts a fresh attempt; failed probes are not retried
aggressively while the same USB enumeration remains present.

## Optional Argo IPC observation

The USB runtime and IPC listener run concurrently, so waiting for Flutter can
never block phone handling. A Flutter connection receives the current generic
`Android phone / USB / connecting|ready|failed` snapshot. The existing IPC
identity validation still requires a legitimate certificate/key pair even
though Milestone 14.1 does not consume it for TLS:

```bash
cd "$FLUTTER_WORKSPACE"
emb bundle --app-path "$HOME/dev/argo" --arch x86_64 --build

cd "$HOME/dev/argo"
ARGO_MODE=production \
ARGO_PROJECTION_BACKEND=android-auto \
ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo/projection.sock" \
ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/project-argo/android-auto.crt" \
ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/project-argo/android-auto.key" \
ivi-homescreen \
  -b "$FLUTTER_WORKSPACE/bundle/argo-release-x86_64" \
  --w=1280 --h=720
```

Do not use credentials copied from LIVI, another open-source project, or a
commercial accessory. The next checkpoint is TLS only after the real-phone
log above has been captured.
