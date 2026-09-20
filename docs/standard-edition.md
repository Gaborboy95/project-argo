# Standard Edition stabilization

This milestone remains in progress. Automated behavior and local builds do not
establish physical acceptance on a phone, vehicle, capture adapter or GPU.

## Frontend compositions

`lib/main.dart` is the standard frontend. `lib/main_surround.dart` injects the
optional integration through `CameraIntegration`/`CameraFeatureContribution`.
The standard import graph excludes surround service, calibration, recording and
model-manager implementations. No dynamically downloaded Dart code is used.
The optional engine remains independently managed; removing the integration does
not delete any engine data.

Camera configuration is `basic` (default), `surround`, or `disabled`. The historical
`legacy` and `external` values remain aliases. An unknown value fails startup
configuration. Selecting surround in a standard frontend displays an unavailable
integration message; it never falls back to opening capture devices.

Both providers use the cooperative physical-device lock. Basic mode discovery
stops its capture before probing and takes that lock. A timeout does not release
another process's ownership. There is no live provider-switch UI: stop the old
provider and recording owners explicitly before changing startup configuration.
Native cleanup failure retains its lock until process exit.

The basic camera persists its exact stable assignment, selected mode and
rotation/mirror/flip. It offers a bounded set of common raw/MJPEG modes intersected
with advertised caps, up to 1920×1080 at 30 fps, plus automatic negotiation.
It does not enumerate every unusual fractional/device-specific mode. A missing
saved identity is never replaced with another device. Native frames, including
rotated full-HD frames, stay outside Dart. Capture and GPU acceptance remain open.

Reverse/PDC presentation is composed against `CameraService` for both providers.
Fresh normalized vehicle signals are required. Incoming projection updates cannot
cover a selected camera page. Navigation and reverse invalidate failed-switch
recovery; late activation is hidden instead of restoring an expired decision.
Reverse owns presentation above local modal panels, selected projection and normal
pages. Explicit navigation while reverse is active replaces the deferred return
destination; it cannot dismiss reverse. Camera configuration controls are blocked
during reverse. An ended, failed or replaced prior projection returns to the local
media page. Both phone protocols have automated reverse/failure/replacement tests;
physical vehicle/projection acceptance remains open.

## Recovery and audio

Service failures carry feature, operation, kind, summary, cause, retryability and
recovery guidance. CarPlay adapters/settings and the projection multiplexer
preserve original causes. Expandable Details retains the full cause locally.
Copied diagnostics export only allowlisted categories: arbitrary backend text,
phone content, identities, credentials, MFi and vehicle integration content are
omitted. Audio configuration and camera status also expose complete causes through shared recovery controls; some legacy integration diagnostics retain their original representation.

Failed projection switching remains closed and offers explicit Retry/Return.
The action token expires on subsequent navigation, activation or hide; ended
sessions cannot be restored. Phone duck/unduck uses separate session-owned audio
focus requests, gain clamped to 0..1 and ramps capped at two seconds. It composes
with navigation/call focus and releases on teardown without changing master volume.

Native microphone leases retain exclusion and expose bounded owner categories
for CarPlay, Android Auto, Bluetooth calls and local assistants. Owner observation
is advisory; acquisition always rechecks the lock. CarPlay currently exposes a
combined Siri/call owner, not separate Siri-versus-call ownership. Contention asks
the user to end the active session; it never force-releases another owner.

## Shared interaction and setup

Shared page, section, device-choice, status, setup-step and confirmation widgets
use common spacing, touch sizes and Material semantic colors. Theme seed, scale
and light/dark choices remain. Camera selection, microphone/CarPlay/model status,
mat forms, calibration review/storage and setup use these components. Some older
optional diagnostic views still use their original interaction layout.

Model commands are not dropped behind polling. Foreground commands serialize,
late poll results are discarded, and cancel bypasses the command queue. Removal
requires confirmation and selected models cannot be removed from this UI.
Benchmarking requires explicit parked acknowledgement and is disabled while the
camera provider has an active role. This is a conservative UI gate, not verified
stationary state. The engine rejects benchmarks with capture/recording subscriptions
or perception active. A new capture request cancels and waits for a benchmark child
to exit before granting its lease. Model readiness uses an explicitly selected
camera's lens parameters, actual mode, crop/orientation and runtime provider;
there is no first-rig-camera fallback. Download cancellation interrupts a blocked
read and removes temporary data; benchmark cancellation terminates/reaps its child
and prevents late result publication. These paths have synthetic regressions.

Front/rear mat templates show two required mat forms. Guided layout uses measured
bumper/body-to-inner-corner-row distance and centre offset; coordinates and yaw
are derived using explicitly described corner ordering. No mat dimensions are
guessed. Raw coordinates remain under Advanced. Calibration and lens-profile
import/export use an application-owned home-folder browser, bounded to 2 MiB JSON
files and 2048 directory entries. Links are excluded, export never overwrites,
and import never activates. Engine schema/hash validation remains authoritative.
The same-user filesystem and engine inbox remain trusted; this is not a sandbox
against a concurrent filesystem attacker. Per-camera states preserve independent
success/failure. Marker review includes point reset, camera reset, undo, magnifier,
previous/next and re-detection. View-owned jobs cancel on close and reject late
results; old draft generations cannot overwrite a replacement workflow.
Storage shows used/limit/protected/reclaimable MiB and retaining collections.
Confirmed removal refuses active or referenced collections; shared images stay
protected. Cleanup coordinates with session writes through a shared/exclusive lock.

The first-run assistant persists its current step, resumes and can be reopened
under Settings → System. Optional steps can be skipped. It reuses current audio,
microphone, connectivity and camera controls. PipeWire output discovery uses stable
node identities, friendly names and explicit selection. A two-second tone at 3%
amplitude respects the existing output volume/mute; setup and launch never copy
persisted volume onto a host-managed output. The native three-second microphone
meter shares the exclusive capture lease and exports levels only, with no saved
PCM. Its stop action remains available while testing. The full-screen touch check
places targets at all four viewport corners; desktop settings retain output
management. Basic camera setup previews the assigned device and offers capture,
rotation and mirror/flip controls. Leaving the step releases its preview unless
automatic presentation has taken ownership. These are implemented and automated-
tested controls, not physical display, microphone, speaker or camera acceptance.

`tool/deployment/argoctl doctor [--json] [--release PATH]` runs read-only manifest,
loader, session, GStreamer, service/process and camera-access checks without
creating deployment state or starting services. An unchecked hardware operation
is reported as unverified, never as accepted. It does not open capture devices.

## Development Debian runtime

`tool/release/standard-release.json` pins the standard runtime and public build
inputs. `tool/release/README.md` documents the builder, package and isolated tests.
The development `argo-runtime` package has passed Debian 13 install/reinstall,
upgrade/remove/purge, data-preservation, corrupt-archive, checksum and loader checks.
It needs no development toolchain on the target. User services start only through
an explicit desktop/session launch. Host deployment and graphical/physical
acceptance were not performed. Clean-container execution, independent compilation
reproducibility and publication licensing remain open; identical-input package
assembly is reproducible. See the build artifact continuation report for evidence.
