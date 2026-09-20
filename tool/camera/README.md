# Camera adapters

Surround-enabled releases can use the independent [surround-camera client](../../docs/configuration.md#surround-camera-client). The external native factory keeps immutable sealed frame allocations until its CPU copy completes, then explicitly releases each frame. Each native subscription has independent delivery state and 750 ms stale blanking. It copies final BGRx into GBM for IHS; this is not a zero-copy claim. Build the optional adapter with `-DARGO_WITH_SURROUND=ON`; the standard library excludes it. RapidJSON headers are required only for that adapter; set `RAPIDJSON_ROOT` to an existing checkout when they are not installed.

External calibration/model job polling has a five-minute total deadline,
including worker startup and status calls. Timeout remains distinct from user
cancellation even if the best-effort cancel request fails. Cleanup waits at most
two seconds. Each run owns its job ID; late replies cannot complete a cancelled
run or cancel a newer run. Starting another job on the same helper while one is
running reports busy. Backend solver messages remain intact. These are client
lifecycle guarantees, not acceptance of a physical calibration result.

The standard frontend defaults to the maintained `camera_contract=1` basic provider. See [Standard Edition](../../docs/standard-edition.md) for provider selection and compile-time editions.

## Basic camera

Camera is a dashboard destination with manual preview and generic reverse activation. Open **Apps → Camera**, select a
capture device and assign it as Rear. No device is assigned implicitly. With a
present assignment, the dock Camera button opens it directly. Leaving Camera
stops capture even though the page remains in the shell's IndexedStack. A saved
Camera destination does not activate capture at application startup.

Automatic reverse/PDC activation uses the shared fresh-signal presentation policy for basic and surround providers. Without fresh signals only manual activation is available. Parking remains a separate destination. The core role IDs are rear/front/left/right; only
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
  -DIHS_PREFIX="$IHS_PREFIX" -DARGO_WITH_SURROUND=OFF -DCMAKE_BUILD_TYPE=Release
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

## External calibration workflow

With the external service connected, Camera → Calibrate camera rig opens the
seven-stage wizard. Enter measured vehicle/target dimensions; assign optical
views to stable capture adapters; collect diverse checkerboard observations or
import an exact OpenCV-fisheye profile; tap surveyed ground targets and solve
pose; inspect a captured candidate preview; collect separate measured validation
points; then activate the candidate or roll back an immutable revision.

Observations and solver jobs live in the standalone engine. The session ID can
resume observation collection. Printed targets require actual-size printing and
physical scale-bar verification. Native previews display pixels; Flutter carries
only corner locations, quality metadata and measured coordinates. Frozen
calibration previews are labelled as captures. Metric geometry validation does
not validate a depth model. Missing cameras may be saved as incomplete coverage.

### Physical capture ownership across rollout

Current source builds of legacy camerad and surround-camerad acquire the same
uid-private `$XDG_RUNTIME_DIR/surround-camera-device-locks/<rdev>.lock` flock
before opening a physical capture pipeline. The lock follows the opened device
number only for the current process lifetime; assignments still use stable IDs.
This rejects simultaneous old/new capture ownership without stopping either
service. Historical pre-lock binaries cannot participate: stop legacy capture
before selecting external mode or rolling back. V4L2 rejection remains an
additional guard, not a substitute for coordinated release selection.

## External scene presentation and replay

The native adapter accepts completed private PNG frames from the standalone
renderer and presents them through the same PlatformViewLayer. The current Argo
surround branch uses the software reference renderer, snapshots and atomic PNG
publication; it is a functional fallback with CPU copies, file I/O and image
conversion, not an accelerated or zero-copy path. Capture dimensions remain
independent from the measured physical viewport used for output. The engine
also supplies separately selectable GL/libxcam paths; their host acceptance is
documented in the standalone backend matrix.

Live rendering retains each contributing source timestamp and independently
blanks at 750 ms in native code. Rendering a vehicle model does not renew camera
age. Captured calibration previews and intentionally paused recorded replay are
labelled separately and retain their own timeline. Direct rear media subscription
remains available if calibration or surround processing fails.

Static native previews decode once per selected image revision, including failed
decode attempts. They submit once, then reuse cached pixels only for an explicit
resize, renegotiation or resume refresh. Suspended views do not consume that
refresh or submit buffers. Non-replay images transition to black once on expiry;
replay images remain visible. Failed submissions wait for a lifecycle refresh
rather than repeatedly allocating GBM buffers. Returning to live positioning
releases the single cached image and reconnects the normal media subscription.
Physical acceptance requires leaving a frozen preview visible for at least
30 seconds, checking stable memory across further captures, and verifying return
to live positioning on the LattePanda Mu; native decision tests alone cannot
establish compositor buffer reclamation.

Run the actual Rust/Dart protocol integration with explicitly synthetic sources:

```bash
SURROUND_TEST_DAEMON="$HOME/dev/surround-camera/target/debug/surround-camerad" \
SURROUND_ROOT="$HOME/dev/surround-camera" \
SURROUND_PYTHON="$HOME/dev/surround-camera/.venv/bin/python3" \
flutter test test/core/camera/surround_camera_test.dart
```

This opens an isolated test daemon and verifies discovery, numeric leases,
snapshot production, a calibration collection session and recorder status. It
does not open physical devices or establish visible-frame acceptance.

## Recording and parking results

Camera → Camera recordings provides explicit destination and quota selection,
per-camera track selection, recording start/stop/status, protected 10-second
pre-event / 20-second post-event marking, session browsing, individual/surround
replay, play/pause/seek/speed and original or H.264 Matroska export. Recording
continues when the page is closed; only its explicit Stop button stops it.
Playback uses the recording's immutable calibration and never writes to the
live vehicle bus. Playback and export run as independent bounded engine jobs.
Recording defaults to original encoded packet preservation. The explicit Budgeted MJPEG option
recompresses individual tracks at selected quality (30–90) and maximum frame rate
(1–15 fps) while retaining source resolution/timing. Its isolated encoder uses
one thread, a 32 MiB queue, 80 million input pixels/second admission and a 750 ms
per-frame timeout; exhaustion affects recording, not live display. This option
adds decode/re-encode work and is not passthrough.

The parking perception card starts or stops the selected engine-managed model; Settings → AI & Models manages downloads and selection. It shows units, input age, source sequence,
model/calibration revision and reported coverage/uncertainty. Relative depth is
never labelled metres. Results expire independently of camera imagery, including
when provider status polling stalls. Missing weights remain unavailable.

## Independent release staging

Fresh external-camera bundles use `camera_mode: external`,
`camera_view_contract: 2` and explicit `camera_api` 1.0 compatibility in
`argo-release.json`. Build with the existing matched Flutter/Engine/IHS toolchain,
include `lib/libargo_camera_view.so`, omit `bin/argo-camerad`, and record with:

```bash
python3 tool/deployment/record-build.py bundle "$ARGO_NEW_BUNDLE" \
  --ihs-prefix "$IHS_PREFIX" --camera-mode external
python3 -m unittest discover -s tool/deployment -p 'test_*.py'
```

`argoctl` validates these bundles and continues to accept historical
`camera_contract: 1` paired bundles and camera-less releases. Its managed units
remain the existing Argo application and projection daemon; it does not start,
stop or restart the independent surround recorder. New release directories are
staged for review. Selecting a live Mu release or installing the optional
`surround-camerad.service` requires deployment authorization. The standalone
[deployment runbook](/home/phaeton/dev/surround-camera/docs/deployment.md) records
build, run, stage, stop/disable, update and rollback commands.

## Lens profiles, checkerboard mats and AI & Models

**Camera → Calibrate 360°** now opens the installed-rig workflow rather than the
combined engineering wizard. Check role assignments and the original multi-camera
live grid, select a reusable optical profile, enter retained vehicle dimensions and
your actual checkerboard-mat measurements, detect/review anchors, solve fixed-intrinsic
poses, preview and save/activate. Checkerboards need an explicit point-1/direction
check. Drag/select anchors, magnify a native crop, reset or disable points, and reset
only the affected camera. Manual anchors must be placed before solving. Capture-set
skew above 250 ms is rejected; this is not hardware synchronization.

**Advanced → Bench lens calibration** supports an unassigned spare camera without
changing vehicle role bindings. The camera stays fixed while the board moves/tilts.
The engine resumes the collection, maintains a 12-region coverage map, rejects bad
observations and supports view/remove/undo/clear and Save as lens profile. New optics
use OpenCV Mei (`opencv_omnidir`); legacy fisheye remains available. Profiles validate
resolution/format/orientation/crop when applied across checked cameras. A shared
profile assumes equivalent hardware; manufacturing tolerances still need checking.

**Advanced → Metric validation / diagnostics** retains surveyed target tooling.
Rows show pixel, measured vehicle coordinate, source camera and purpose; they have
show/edit/remove, undo and clear actions. The dedicated entry loads active camera
geometry. Metric validation remains separate from a useful visual surround fit.

Drafts, captures, profiles, import/export inboxes and immutable rigs belong to the
standalone engine. Normal screens do not require session IDs or absolute-path input.
Full rig exports include referenced profiles. Imports remain inactive until an
explicit activation. Capture cleanup retains referenced/recent images. Completed
previews go through the existing native IHS path; thumbnails/rectification math and
model network I/O do not run inside Dart widgets. Configuration-step transitions
stop the live contact-grid renderer. No decoded full-resolution collection is held
in Flutter.

**Settings → AI & Models** uses a registered `ParkingModelService`, separate focused
model-manager widget, and engine-owned catalog/download/selection/benchmark state.
Camera parking controls show the selected model and Start/Stop/Manage models.
Relative depth is not metres, unknown coverage is not clear, and no output actuates
the vehicle. The downloadable Small model's measured Intel N100 CPU median inference
was 1668 ms, so a responsive parking-overlay claim would be incorrect. See the engine
[workflow guide](/home/phaeton/dev/surround-camera/docs/calibration-workflows.md) and
[verified artifact/benchmark](/home/phaeton/dev/surround-camera/docs/model-manager.md).

Validation commands for this change (matched Flutter SDK; no IHS/Engine rebuild):

```sh
FLUTTER=/home/phaeton/dev/infotainment/flutter/bin/flutter
"$FLUTTER" analyze --no-pub
"$FLUTTER" test --no-pub test/core/camera test/features/camera test/features/settings
SURROUND_TEST_DAEMON=/home/phaeton/dev/surround-camera/target/debug/surround-camerad \
  "$FLUTTER" test --no-pub test/core/camera/surround_camera_test.dart
"$FLUTTER" build bundle --no-pub --target-platform linux-x64
cmake --build native/camera/argo-camera-view/build -j2
ctest --test-dir native/camera/argo-camera-view/build --output-on-failure
python3 -m unittest discover -s tool/deployment -p 'test_*.py'
```

The real Mu must still pass the ≥30-second frozen-preview memory test, additional
captures, return to live, native loupe/touch alignment, camera-role checks and
physical mat calibration. Synthetic/widget/native state tests do not establish
those physical outcomes. No live deployment or push is part of this code change.

Calibration configuration pages fit the native viewport to current live or captured
image dimensions, including changes between camera, grid and loupe aspect ratios.
The native adapter intentionally rejects mismatched viewport shapes rather than
stretching imagery. A rejected multi-camera admission releases partial display
leases and reports the failure so individual-camera preview remains available.
Four default 1080p30 streams require about 1.99 GB/s under the conservative broker
accounting; the default 1.5 GB/s admission budget cannot admit all four. Configure
an explicit host-validated budget (2.5 GB/s on the tested four-adapter setup) or
lower supported capture modes; admission is not a measurement of USB bandwidth.
