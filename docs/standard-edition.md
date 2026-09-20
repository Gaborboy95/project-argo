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
omitted. Other integrations still need migration to this failure representation.

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
mat forms and setup use these components; migration of every major screen is
not yet complete.

Model commands are not dropped behind polling. Foreground commands serialize,
late poll results are discarded, and cancel bypasses the command queue. Removal
requires confirmation and selected models cannot be removed from this UI.
Benchmarking requires explicit parked acknowledgement and is disabled while the
camera provider has an active role. This is a conservative UI gate, not verified
stationary state or complete engine-side benchmark cancellation/readiness work.

Front/rear mat templates show two required mat forms. Guided layout uses measured
bumper/body-to-inner-corner-row distance and centre offset; coordinates and yaw
are derived using explicitly described corner ordering. No mat dimensions are
guessed. Raw coordinates remain under Advanced. Calibration and lens-profile
import/export use an application-owned home-folder browser, bounded to 2 MiB JSON
files and 2048 directory entries. Links are excluded, export never overwrites,
and import never activates. Engine schema/hash validation remains authoritative.
The same-user filesystem and engine inbox remain trusted; this is not a sandbox
against a concurrent filesystem attacker. Complete manual review tools, protected
collection storage explanations and job-generation work remain open.

The first-run assistant persists its current step, resumes and can be reopened
under Settings → System. Optional steps can be skipped. It reuses current audio,
microphone, connectivity and camera assignment controls. Dedicated output
inventory/test tone, microphone level test, physical corner/display validation
and an ownership-safe in-wizard camera preview remain unfinished. Camera preview
continues through the Camera destination.

`tool/deployment/argoctl doctor [--json] [--release PATH]` runs read-only manifest,
loader, session, GStreamer, service/process and camera-access checks without
creating deployment state or starting services. An unchecked hardware operation
is reported as unverified, never as accepted. It does not open capture devices.
