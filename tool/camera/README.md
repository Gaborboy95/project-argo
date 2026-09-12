# Manual native camera

Camera is a manual dashboard destination. Open **Apps → Camera**, select a
capture device and assign it as Rear. No device is assigned implicitly. With a
present assignment, the dock Camera button opens it directly. Leaving Camera
stops capture even though the page remains in the shell's IndexedStack. A saved
Camera destination does not activate capture at application startup.

Automatic reverse/gear/PDC activation is **pass 4**, not implemented here. Parking
remains a separate destination. The core role IDs are rear/front/left/right; only
rear assignment and display are currently exposed. There are no vehicle-specific
IDs, parking guidelines, audio capture or simulated production pictures.

## Requirements and build

Use the existing matched Flutter/Engine/IHS toolchain documented in the
[projection build reference](../projection/README.md#ihs-base-and-local-patch).
Do not rebuild or patch IHS or the projection view for camera support.
The native camera view requires an IHS linear XRGB8888 DMA-BUF/GBM grant;
software-only Flutter runners cannot show it.

Debian build/runtime packages include `build-essential`, `cmake`, `pkg-config`,
`libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`, `libgbm-dev`,
`libegl-dev`, `libvulkan-dev`, `gstreamer1.0-plugins-base`,
`gstreamer1.0-plugins-good` (V4L2 and JPEG), and optionally `v4l-utils` for
inspection. Install missing packages with administrator approval. The desktop
account needs read/write permission on the selected V4L2 capture node and access
to the compositor's DRM render node, usually through desktop ACLs or `video` /
`render` groups. Do not run Argo or camerad as root or make device nodes world writable.

```bash
export ARGO="$HOME/dev/argo"
export IHS_PREFIX="$HOME/dev/ivi-build/out/usr/local"
cd "$ARGO"
cargo build --manifest-path native/camera/Cargo.toml --locked --release
cmake -S native/camera/argo-camera-view -B native/camera/argo-camera-view/build \
  -DIHS_PREFIX="$IHS_PREFIX" -DCMAKE_BUILD_TYPE=Release
cmake --build native/camera/argo-camera-view/build -j2
cargo test --manifest-path native/camera/Cargo.toml --locked
cargo clippy --manifest-path native/camera/Cargo.toml --locked --all-targets -- -D warnings
ctest --test-dir native/camera/argo-camera-view/build --output-on-failure
```

The separate Cargo lockfile uses GStreamer 0.24, consistent with projection. The
capture pipeline selects an advertised raw or MJPEG mode at or below 1920×1080
and 30 fps, preferring resolution, then framerate. It does not promise every
capture device can supply 1080p30. H.264-only capture devices are not supported
in this pass. `v4l2src → capsfilter → leaky queue → decodebin → videoconvert →
BGRx appsink` preserves negotiated dimensions, with no resize stage. Appsink has
`sync=false`, `max-buffers=1`, `drop=true`; the upstream queue retains at most two
buffers. Decoded stride and framerate are reported with each metadata snapshot.

## Enumeration and identity

```bash
"$ARGO/native/camera/target/release/argo-camerad" --enumerate
# Optional independent read-only inspection:
v4l2-ctl --list-devices
```

Only nodes with V4L2 video-capture and streaming capability are listed; metadata
nodes are excluded. A unique USB serial and by-id alias are preferred. Devices
without a unique serial use a by-path alias, then physical sysfs topology plus
capture-interface index. Identical capture devices can be distinguished by USB
port. Moving a port-bound device requires reassignment. A misleading/duplicated
hardware serial cannot guarantee permanent physical identity; ambiguous current
serials use topology instead. `/dev/videoN` is diagnostic information only.

Only `camera.rear` is persisted in SettingsService. Unplugging a device retains
its assignment and reports disconnected. No frame sequence, timestamp, active
role or negotiated mode is persisted. **Apps → Camera** remains accessible when
the dock shortcut is disabled, including to choose a replacement device.

## Native contracts and safety

CameraService launches the selected release's `bin/argo-camerad`, with no shell
interpolation and no systemd camera unit. Its private directory is
`$XDG_RUNTIME_DIR/project-argo/camera-<application-pid>` (0700). An existing directory
is treated as uncertain ownership, not silently replaced. Control-owner EOF or
reset ends the daemon and releases capture; normal shutdown requests cleanup
first. A stalled process is terminated by the application after bounded command
and exit waits, with a cleanup error rather than a success claim. Kernel resources
are process-owned; an async timeout does not interrupt synchronous GStreamer FFI.

`control.sock` uses a four-byte big-endian length followed by UTF-8 JSON, bounded
at 16 KiB, with `version:1`. Commands have an `id`, `op` (refresh/start/stop/close),
optional `role` and `stableId`; acknowledgements echo `id` and an optional error.
Snapshots contain device inventory and bounded stream metadata at most four times
per second. Commands are serialized; superseded queued navigation starts are
cancelled. No raw image bytes use control IPC or Dart.

`media.sock` admits one same-account native reader and transfers a memfd plus an
eventfd using SCM_RIGHTS. **The frame transport is shared-memory BGRx, not
zero-copy.** The native view copies a stable ring slot and then copies it into a
fresh GBM allocation for IHS submission. Old frames are dropped, never queued for
later display. Native frame dimensions are independent of Flutter logical size.
`IhsCameraSurface` uses PlatformViewLink → PlatformViewSurface → PlatformViewLayer,
aspect-fitting the negotiated frame with black letterboxing. It has no pointer
commands. Factory `argo.camera.view` is separate from projection.

ARCV creation parameters are 12 bytes: ASCII `ARCV`, little-endian u32 version 1,
and u32 role (rear=0, front=1, left=2, right=3). ARCR ring v1 is the Linux
little-endian contract in `src/ring.rs` and `argo-camera-view/src/contract.h`:

- 128-byte header: u32 magic `ARCR`, version, slot count 3, capacity 8,294,400;
  aligned u64 latest sequence at 16, active flag at 24, role+1 at 32.
- Three slots, each 64 bytes of metadata plus fixed pixel capacity. Aligned u64
  guard at 0; u32 width/height/stride/fps numerator/denominator at 8/12/16/20/24;
  u64 CLOCK_MONOTONIC frame timestamp at 32; BGRx starts at 64.
- Writer marks guard odd before copying, then publishes even `sequence*2` with
  release ordering. Reader checks the guard before and after copying and rejects
  overwritten slots, invalid dimensions, wrong roles or inactive frames. Sequence
  increases across capture restarts within the process. Ring size is sealed.

After 750 ms without a new frame, the service reports stale and the native view
independently submits black. It logs once per stale interval; local UI activity
cannot refresh frame age. New frames resume streaming. After two seconds without
a frame the daemon stops the pipeline and retries up to three times with 1/2/3
second backoff. Failures exhaust that budget until Retry or an observed removal
and reappearance of the assigned device. Stop clears the retry request. V4L2 bus
errors invalidate the ring immediately; inventory is refreshed every 500 ms for
hotplug detection. This detects missing frames, not a capture card repeatedly
transmitting an unchanged image or its own “no signal” picture.

## Release assets

A camera-capable bundle includes both `bin/argo-camerad` and
`lib/libargo_camera_view.so`, recorded as `camera_contract=1`. The ordinary bundle
hash manifest covers both. `argoctl` accepts older releases with neither asset,
but rejects partial pairs or mismatched contracts. Camera absence does not fail
application startup. Projection remains IPC7; camera control/creation/ring are v1.

After building the changed Flutter application into a fresh bundle using the
[normal build workflow](../../docs/setup.md#shutdown-updates-and-rollback), add these camera assets
and retain the unchanged matching projection daemon, projection view, Engine,
ICU and Lua/SQLite assets. Never overwrite a loaded library:

```bash
# Set this to the fresh application bundle you just built:
export ARGO_CAMERA_BUNDLE="$HOME/dev/infotainment/bundle/argo-camera-ipc7-20260913"
install -m755 "$ARGO/native/camera/target/release/argo-camerad" "$ARGO_CAMERA_BUNDLE/bin/argo-camerad"
install -m755 "$ARGO/native/camera/argo-camera-view/build/libargo_camera_view.so" "$ARGO_CAMERA_BUNDLE/lib/libargo_camera_view.so"
python3 "$ARGO/tool/deployment/record-build.py" bundle "$ARGO_CAMERA_BUNDLE" --ihs-prefix "$IHS_PREFIX"
argoctl stage "$ARGO_CAMERA_BUNDLE" --name camera-ipc7-20260913
argoctl select camera-ipc7-20260913
# Restore the previous matched release when needed:
argoctl rollback
```

Update the installed `argoctl` using the existing idempotent
[installation command](../../docs/setup.md#graphical-session-deployment)
before validating camera bundles. Selection preserves stopped/running service
state and performs owned cleanup before replacing the release. No credentials
or live preferences are copied into bundles.

## Manual Mu validation

1. Open Apps → Camera, explicitly assign Rear, and verify live content and aspect
   ratio. Check stable native-view identity while starting/retrying and on resize.
2. Leave for Home/Media: capture must stop and release the device. Reenter to start
   a new manual stream. Verify projection resumes through its existing path.
3. Remove the capture device: the old image must turn black promptly, with
   disconnected status. Reinsert on the same physical port; verify bounded
   recovery. Test a stalled source, stale blanking and eventual Retry separately.
4. Quit Argo and confirm camerad exits. Start with no camera assets or unplugged
   capture hardware: the rest of Argo must remain usable.
5. Test two identical devices on different ports and confirm selection does not
   follow `/dev/videoN` renumbering. No reverse/gear signal should activate Camera.

An isolated check can exercise actual capture, FD transfer, sequence guards and
V4L2 release without launching IHS or altering a saved assignment. It opens the
explicit device for the requested duration; do not run it while that device is
in use:

```bash
# Copy the exact stableId from --enumerate, without a /dev/videoN substitution.
export CAMERA_ID='by-path:REPLACE_WITH_ENUMERATED_ID'
python3 "$ARGO/tool/camera/validate-capture.py" \
  --daemon "$ARGO/native/camera/target/release/argo-camerad" \
  --device "$CAMERA_ID" --seconds 10
```

The Mu capture check has negotiated 1920×1080 at 30 fps and verified shared-memory
frames and explicit V4L2 release, followed by a fresh manual start. An initial decoder
`Invalid data` error has also recovered through the bounded retry path; startup
reliability remains device-dependent. This is not acceptance of the live IHS picture,
real rear-camera orientation, unplug/stall recovery on every device or endurance.
