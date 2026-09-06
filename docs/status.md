# Audit, acceptance and troubleshooting

## Audited revisions and evidence

Documentation audit: 2026-09-06, Argo
`ee08a138cdadaa361706c0e46b89974fd5e8aad3`. At audit start the only untracked
content was the user's `.vscode/` directory, which was not used as a public
configuration source. The documentation and launcher consistency edits are not a release claim.

Local dependency sources inspected read-only where needed:

- Veloce `d169d4cd6d10c1f38c534f425de83a75f1192ca9` for the manifest, capability,
  API registry, assets and plugin lifecycle boundary.
- IHS `50cbfb5b29266821091dd5a15edb6fe0a8547a91` for the platform-view contract,
  compositor build option and outstanding eventfd ownership problem.
- Flutter `d3b14c876900e553bc736ca19295fc09e3853e8e`; workspace engine selection
  `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`.

Implementation audit covered bootstrap/composition/services/modules/settings,
bundle discovery, Veloce configuration/bridges, projection Dart/IPC/Rust/native
view, audio/power adapters, scripts and related tests. Source paths are linked
from [architecture](architecture.md) and [configuration](configuration.md).

| Area | Implementation / automated evidence | Supplied runtime acceptance |
|---|---|---|
| Shell/settings/vehicle boundaries | Typed registry, persistence, discovery, simulation and dependency-boundary tests exist. | No universal vehicle or OS support claim. |
| Projection composition | Layer-tree regression verifies PlatformViewLayer with matching ID, no TextureLayer; lifecycle/channel-error coverage. | User saw moving native bars inside Argo through unmodified IHS in Ubuntu VMware. |
| Wired Android Auto | USB/TLS/discovery/video/audio/input code and wire fixtures exist. | User reported live wired video/audio in the same VM. This is not full touch/reconnect/certification acceptance. |
| Gesture refinement | Outside terminal, ownership cancellation, session targeting and Rust gesture-wide CANCEL regression coverage. | Latest user reply: not tested with a phone yet. |
| Presentation comparison | Shared render/touch fit, DPR 2 and same-view expanded-layout test. | VM measured 1280×720 destination at DPR 1; user reported clean bars at 1:1. Embedded example was 1031.11×580 (0.80556×). Live-AA artifacts at 1:1 remain unassessed. |
| Audio/power backends | Capability, bridge authorization and fake-host tests exist. | No new real suspend/poweroff, physical CAN or target-hardware validation claimed. |
| Long-running projection | Current frame path has an identified host-side release-eventfd retention issue. | User reported repeated `dup(release eventfd) failed (errno=24)` after the comparison work. A subsequent local Wayland-EGL IHS fix is described below; no full endurance claim. |

Prior implementation validation recorded 38 focused Flutter tests and 38 Rust
tests passing, analyzer, Clippy and release daemon/bundle builds. These were
previous checks, not tests rerun for this documentation task. Native Lua tests
may skip when the native runtime is unavailable; inspect test output rather than
claiming all integrations from a green mock suite. No target-vehicle hardware
acceptance is recorded. Documentation validation uses local links/paths, option
inventory, shell syntax and installed CLI inspection only.

## Loading, builds and blank surfaces

Use matching IHS headers, `libihs_shared.so` and `bin/homescreen` from the same
prefix. Native-view CMake accepts `IHS_INCLUDE_DIR` and `IHS_SHARED_LIBRARY`;
`IHS_PREFIX` defaults are a runbook convention, not a guarantee of installed files.
Stage `libargo_projection_view.so` in the bundle's `lib/`; set `LD_LIBRARY_PATH`
for both IHS and bundle libraries and `VELOCE_LUA_LIBRARY` explicitly. Verify
`libapp.so`, `libflutter_engine.so`, `libveloce_lua_native.so` and `libsqlite3.so`.
Stop the previous process before overwriting any loaded library.

`BUILD_COMPOSITOR` defaults OFF in the audited IHS source. The local `ivi-build/CMakeCache.txt` has `BUILD_COMPOSITOR=ON`; another supplied IHS build
must also support the compositor/platform-view path. A GTK runner or a host
built without that contract cannot be fixed by treating the create reply as a
texture ID. Do not rebuild IHS/Engine as a routine response to Dart edits.
System GStreamer discovery must not inherit a global pkg-config sysroot intended
for a staged prefix: pass only IHS paths explicitly.

If blank, use the renderer diagnostic first and inspect native registration,
create, grant, sample and submission logs. IHS's current create channel can
acknowledge an ID despite a factory refusal; native logs are authoritative for
factory success. A submit return of zero means accepted, not displayed. The
working layer must be PlatformViewLayer. A native ID, texture name and DMA-BUF fd
are different identifiers. SHM without an actual host-provided mapping is not a
working fallback. Do not coerce modifiers or force successful return codes.

`errno=24` is per-process open-FD exhaustion. The audited IHS EGL path retains
its own per-buffer release eventfd when GL consumes a frame without the DRM
scanout retirement callback. Argo closes the returned duplicate; fresh IDs make
host retention accumulate. Restarting the owned homescreen releases descriptors
but is only temporary relief. Increasing limits or suppressing warnings does
not fix ownership. The original Argo presentation/configuration tasks left IHS unchanged. The user
subsequently authorized a targeted local IHS patch; see
[its scope and validation below](#local-ihs-wayland-egl-descriptor-fix).

## Phone connection, logs and security

USB accessory re-enumeration changes device identity; VMware forwarding and
udev permissions must cover both normal and accessory devices. Use exact
VID/PID-scoped permissions and a non-root process. Follow the
[projection runbook](../tool/projection/README.md) rather than deleting sockets
or opening broad USB access. Control/media defaults now match across app, daemon and native consumer; explicit
paths in the runbook remain useful for two-terminal verification. Check listener ownership
before removing stale sockets. Start the daemon before connecting the phone and
before Argo's initial sidecar connection; there is no automatic daemon supervisor
or robust sidecar reconnect loop. Unplug/replug handling exists, but repeated
real-device reconnect/endurance acceptance is outstanding.

Daemon `ARGO_PROJECTION_LOG_LEVEL` defaults to INFO; DEBUG shows detailed setup,
TRACE packet metadata and pings. Real failures remain WARN/ERROR. IHS has its own
logging; this variable does not silence `[ihs_pv]` warnings. Geometry and renderer
logs are independently opt-in. Share relevant stages/metadata after reviewing
for private identifiers; never share private keys or media payload dumps.

Identity ownership is now exclusively in argo-projectiond. Flutter ignores inherited
identity variables, never opens/parses a private key, and sends no identity paths
or contents through IPC v4. Missing/invalid daemon identity leaves control readiness
and capability reporting available; restart the daemon after correcting files.
TLS is 1.2 with resumption disabled. The USB-specific permissive
peer verifier does not provide WebPKI chain/hostname/signature authentication;
TLS Finished is still required. A self-generated RSA pair passing parsing or an
in-memory fixture is not real-phone acceptance or product certification. Keep
identity files external and restricted. There is no completed trusted credential
provisioning workflow or claim of a secure plugin sandbox.

## Partial and unimplemented work

The real audio adapter controls default-sink master volume/mute only. Balance,
fader, EQ, output selection and per-source routing remain unavailable there,
regardless of saved preferences or fake-backend capability coverage. AA's native
per-stream gain pipeline is a separate path; it does not imply general system
routing support.

Microphone channel 9 is currently advertised as PCM 16 kHz/16-bit/mono, with
setup/open responses and start signaling. No capture pipeline/PCM upload source
was found. Thus the older statement “microphone is not advertised” was wrong,
while “working microphone support” would also be wrong. Voice-input acceptance
and reconciliation of advertised capability with actual capture remain follow-up
work. Night/driving-status sensors exist with conservative defaults, not real
vehicle speed/parking-brake integration.

Touch cleanup handles Flutter focus/lifecycle/pointer callbacks when delivered.
The inspected IHS Wayland keyboard-leave path does not deliver every Flutter
focus/lifecycle event; missing host events cannot be claimed handled. Observed
pointer removal/mouse state can reconcile some losses. Real-phone outside-drag,
module-switch and reconnect touch acceptance still needs testing.

Wireless Android Auto, Bluetooth integration, CarPlay transport, playback controls, customization, plugin-rendered Argo tabs/settings/widgets and complete
microphone capture are future work. `wifi`/`carPlay` enums and Veloce's broader UI
APIs are scaffolding/capabilities, not present usage instructions. No such feature
or IHS/Veloce change is implied by the implemented read-only host state API.

## Remaining follow-up work

- Saved safe-inset preferences remain deliberately unsupported, without enabled
  controls or invented AA fields. Implement a mapping only with verified protocol
  evidence; source content insets and Flutter presentation are distinct.
- Reconcile microphone advertisement/open success with the absent capture path.
- Validate the separately authorized local Wayland-EGL IHS descriptor fix with
  real-phone navigation/volume and longer endurance checks. DRM/KMS fallback is
  outside that targeted fix. Argo buffer IDs/allocation/modifiers remain unchanged.
- Test latest gestures, reconnect and live-AA artifacts at measured 1:1 with a
  phone; target hardware and undelivered host focus events remain unverified.


These remaining limitations are documented rather than silently resolved or presented as
future features already available. Exact target-hardware support, tested phone
model/OS breadth, and a complete compatibility/provisioning policy remain
unestablished by the supplied acceptance.

## Documentation checks performed

Local Markdown targets/anchors and Bash syntax in all shell examples were checked,
along with the complete 26-name Argo/Veloce environment inventory against the
configuration reference. The installed `emb bundle --help` confirmed `--workspace`,
`--mode release`, `--arch`, `--build` and `--output`. Installed homescreen help
confirmed `-b`, `--backend wayland-egl`, `--width` and `--height` after supplying
IHS/bundle `LD_LIBRARY_PATH`; without it the loader failed on `libihs_shared.so.1`,
confirming why the documented search path matters. Required installed header,
executable and bundle library paths exist; pkg-config reports GStreamer core/app/
video 1.24.2. The local IHS CMake cache has compositor enabled.

No privileged examples, dependency installation, credential generation, app/phone
sessions, real builds or hardware suites were executed for this audit.
Shell parsing and existing-artifact checks do not establish a clean-machine build.

The subsequent script review corrected renderer launch arguments to
`--width=1280 --height=720` and resolves an explicitly relative IHS prefix before
changing working directories. Earlier 1920×720 window measurements are historical,
not post-change window acceptance. The fake-systemctl helper was reviewed and
retains its restricted suspend/poweroff logging behavior. Script validation uses
isolated command stubs and the fake helper, not real host power or a hardware run.

## Projection ownership/configuration update

Implementation baseline was `a373c255a57158c3724a3b40509c7b4f8725115a` (newer than
the original documentation audit). Contract commit `169e0fc` introduces IPC v2,
daemon-only identity ownership, one-client control ownership, backend capabilities,
revisioned configuration and frozen per-phone selection. The subsequent settings
UI exposes only supported video requests, read-only audio caps and explicit
current/next status. Both are local changes, not a product release claim.

Automated evidence includes a shared Dart/Rust capability fixture, credential-free
hello even with inherited obsolete paths, rejection preserving valid state,
second-client refusal, frozen current/next-session selection, stale-reply handling,
legacy settings fallback, persisted UI changes and disabled renderer-test coverage.
These checks are not phone, audible-output or visible-rendering acceptance.
The existing IHS eventfd problem and TLS compatibility policy remain unchanged.
Follow the [bounded two-terminal acceptance workflow](../tool/projection/README.md#configuration-ownership-acceptance-ipc-v4)
with driver side or DPI first. Live-phone configuration/persistence/reconnect and
unchanged picture/audio/touch for this patch are **not yet user-verified**.

Checks for this configuration pass: Flutter formatting/analyzer and 44 focused
projection/settings tests passed; the 12 IPC/backend tests were rerun after the
final readiness-error fix. Another 32 existing composition, lifecycle and dependency
boundary tests passed (overlapping the focused selection). All 40 Rust tests passed with all features, and the
standalone-session regression was rerun after extending its assertion. Strict
all-target/all-feature Clippy passed. The release daemon, native view against the
installed matching IHS prefix (GStreamer 1.24.2), and x86_64 release Argo bundle
built on this Linux VM. Markdown links and documented shell syntax were checked.
No Flutter Engine or IHS rebuild was performed.

This pass did not launch a phone or a manual renderer session. Renderer-test
independence and PlatformViewLayer composition retain automated coverage; visible
acceptance here refers only to the earlier user reports, not a new endurance run.

## Shared host media/state update

Baseline: `8cd3eee`; reception/state commit `a70f6ea` adds IPC v3 and an independently
implemented optional AA metadata reader. The user confirms Argo runs and projection
settings work. That confirmation does **not** establish live-phone next-session
configuration/reconnect correctness or renderer endurance.

Implemented: shared immutable media/phone facts, session-scoped initial/update IPC,
read-only `argo_host.snapshot()` with generation-aware permission checks, a synthetic
Lua observer and a bounded Media-page facts panel. Public schemas/reference notes
support track text, playback/application/position, optional battery and discovery
name/brand. Duration/model/charging are unknown for this AA provider; no fields have
been newly observed from the actual phone during this pass. Bluetooth/CarPlay/local
providers, controls, calls/contacts, artwork handling and microphone capture remain
unimplemented. No IHS, Veloce, TLS/identity, USB transport, AV format, rendering or
gesture implementation changes were made.

Automated evidence: 42 Rust tests and strict all-feature/all-target Clippy pass.
The shared IPC v3 hex fixture agrees across Dart/Rust. The native-Lua exercise ran
against the installed native library (not a skipped/mock substitute), covering
current reads, coalescing, permission denial, forged invalidations, reload/stale
generations and disconnect/unload cleanup; the existing synthetic Lua resource
checks also passed. The layer regression verifies an unchanged PlatformViewLayer
ID and surface rectangle across a metadata update, including small-window layout.
Flutter formatting/analyzer and 115 relevant Dart tests passed with native Lua
enabled. The six focused native-Lua/layer tests were rerun after final stale-source
and unknown-timestamp safeguards. The IPC v3 release daemon and x86_64 release Argo
bundle built in the existing Linux workspace; the unchanged native projection
library was restaged. No Flutter Engine, IHS or Veloce build/change was required.
Markdown targets/anchors, shell example syntax and the new environment option
reference were checked. No phone or manual rendering session ran in this pass.

**Subsequent user confirmation:** real wired AA reached the Lua observer as
`androidAuto/usb | Android | Without You | playing`. This verifies that reported
protocol/transport, device name, title and playing state reached Lua.

**Not yet phone-verified:** artist/battery delivery, Lua/UI agreement,
track-change and pause/resume sequencing, observer reload while connected, cleanup
on physical disconnect, and whether this phone sends battery. Target hardware and
endurance remain unverified. Use the [bounded acceptance workflow](../tool/projection/README.md#host-metadata-and-lua-acceptance-ipc-v4).


## Home / Media separation

Local implementation based on `6c1c7c3`: Home now owns fullscreen projection;
Media is native Now Playing with placeholder artwork. IPC v4 distinguishes an
explicit phone return-to-host request from a transient video stop. Home activation
uses the existing session/focus command; pages never connect/disconnect merely to
switch presentation. Hidden Home retains one native view with no platform layer
or input ownership. Old surface disposal no longer sends a stale focus loss.

Automated checks cover actual PlatformViewLayer identity, no TextureLayer,
fullscreen fitting at DPR 2, gesture cancellation, metadata retention through
host return, repeated Home activation coalescing, no automatic activation from
updates, and stale-session/activation isolation. Protocol fixtures distinguish
focus loss from AV stop and agree on the new IPC representation. Runtime results
for the new Exit/Media/Home cycle have **not yet been supplied**. The prior user
metadata and 1:1 renderer confirmations remain narrow historical acceptance;
no target hardware or endurance acceptance is added. Follow the
[bounded Home/Media workflow](../tool/projection/README.md#home--media-acceptance-ipc-v4).


Validation for this pass: formatting/analyzer, 116 relevant Dart regressions
(including the real native-Lua exercise), 42 all-feature Rust tests and strict
all-target/all-feature Clippy passed. The IPC v4 release daemon and x86_64 Argo
bundle built against the existing workspace. The unchanged native view also
built through `run_renderer_test.sh`; neither Engine nor IHS was rebuilt.
The launcher ran for 12 seconds after homescreen started, then the owned process
was interrupted (launcher status 130). Home logged one view (ID 0), a 1280×720
logical/physical destination at DPR 1, offset 0, and accepted submissions. No
release-eventfd warning appeared during that short interval. Visible bars were
not independently inspected in this run; this is not visual or endurance
acceptance. Logs: `/tmp/argo-renderer-test.log`. No phone session ran in this pass.


Presentation refinement: usable video alone now enables fullscreen Home, without
floating host controls. Waiting/no-video Home shows centered connection status
and normal shell navigation. AA Exit remains the route from active AA to Media.
Formatting/analyzer and 15 relevant widget/composition regressions passed. This
refinement has not yet been visually accepted on the phone.


## Local IHS Wayland-EGL descriptor fix

The user subsequently authorized IHS source/build/staging changes after the leak
also froze the application during volume interaction. The patch is local IHS commit `35a5f852`, based on
`50cbfb5b29266821091dd5a15edb6fe0a8547a91`, in
`shell/platform/homescreen/platform_views/platform_view_host.cc`; it is not an
upstream or released IHS fix. It gates per-buffer scanout release-eventfd creation
on the backend's GBM/DRM capability, matching the existing capability check.
Wayland EGL imports through `GetGlTextureName` and has no `OnScanoutRelease`
callback; those per-frame host descriptors otherwise remain retained. The
existing GL release-fence path remains intact. DRM/KMS behavior is unchanged,
including the need to investigate its separate GL-fallback retirement path.

The reviewed patch passed C++ syntax checking and the existing `ivi-homescreen`
target rebuilt successfully. The executable was staged at
`$HOME/dev/ivi-build/out/usr/local/bin/homescreen` with its installed RPATH, after
checking homescreen was stopped. The previous executable is backed up under
`/tmp/argo-ihs-before-eventfd-fix.iyLMRN/homescreen` for this VM session. No Flutter
Engine rebuild, daemon/configuration change, descriptor-limit increase or Argo
buffer-ID/allocation/modifier workaround was used.


Post-patch bounded result: `run_renderer_test.sh` ran for 90 seconds after
homescreen startup. Samples every ten seconds stayed at **34–35 total FDs** and
**2 eventfds**, rather than increasing per submitted frame. No descriptor
exhaustion warning occurred; the monitor stopped its owned process at the bound
(SIGINT, launcher status 130). The user confirmed **bars are moving** during the
run. This verifies visible native rendering and bounded descriptor stability for
this Wayland-EGL renderer test, not real-phone volume/Exit/Home behavior, DRM/KMS
support, or long-term endurance. The diagnostic is stopped; use the existing VM
launch command to test the phone next. Evidence is saved in
`/tmp/argo-ihs-fd-test.json`, `/tmp/argo-ihs-fd-test-renderer.log` and
`/tmp/argo-ihs-rebuild.log`. The projection daemon was neither rebuilt nor restarted.


## Repeated Exit and AA redraw follow-up

The user reports that only the AA interface redraws (no Argo connection/status
flash), and that subsequent Exit attempts can return immediately to AA. Inspection
found that the daemon granted any later phone focus/start request after Exit.
It now retains explicit host-return/host-hide ownership until an explicit Home
activation, without replacing the session or changing AV configuration. A focused
regression repeats three cycles and verifies map-drag serialization does not emit
focus messages. Numeric DEBUG focus diagnostics distinguish phone requests from
host activation in a subsequent phone reproduction. The actual redraw cause is
not conclusively established by the existing INFO logs, and real-phone acceptance
of this fix remains pending. The earlier TLS failure in the log is recorded as a
separate unresolved session failure, not silently addressed by this focus fix.

Validation for the focus follow-up: 43 Rust tests, strict all-feature/all-target
Clippy, Flutter analyzer and 24 relevant Dart regressions passed. The release
daemon rebuilt. Both `argo-release-x86_64` and `argo-fullscreen-update` contain
the same rebuilt application. No IHS, native decoder, identity or USB code changed
in this follow-up. No real-phone reproduction ran after the change.


Subsequent user acceptance: after rebuilding/restarting with the focus-ownership
fix, the user reported **“Fixed”** for the repeated Exit / AA interface-redraw
issue. This updates the pending phone result above; it is not a claim of extended
endurance, comprehensive phone compatibility, or resolution of the earlier
separate TLS error. The local IHS descriptor fix is committed as `35a5f852`.

## Appearance foundation (working tree based on Argo `3c037d7`)

Added persisted manual light/dark/system mode and accent presets in Settings,
appearance-only reset, shared Material themes and a solid native-page background.
Default remains the previous dark Material 3 appearance. Local IHS `35a5f852` is
unchanged; this work does not extend its endurance acceptance.

Focused automated coverage checks persistence/recovery/reset, actual selection
and Flutter brightness changes, and the actual PlatformViewLayer ID/geometry
across appearance changes without extra activation or connection commands.
These are application tests, not visual or phone acceptance. The installed IHS
source has no identified system-brightness forwarding; automatic desktop theme
changes remain unverified. Manual modes do not depend on that support.

Manual acceptance for this change remains pending:

1. In Settings, select light/dark and an accent; inspect Settings and Media.
2. Restart Argo and verify those preferences persist.
3. Resume Home projection; check black letterboxing, input and audio.
4. Repeat AA Exit → Media → Home and check the session remains usable.
5. Confirm native create/dispose logs show no view recreation due to appearance.

Do not infer those outcomes from widget tests. Wallpaper importing, shader
execution and vehicle-driven day/night remain unimplemented.

Validation for this working tree: Dart formatting, `flutter analyze --no-pub`,
45 focused tests across `test/app`, `test/core/settings`,
`test/features/projection`, `test/features/media` and `test/architecture` passed.
After checking preservation of the exact default Material palette, the eight
appearance/projection widget tests passed again. Documentation file links and
`git diff --check` passed. No Rust, Engine or IHS build was run for this change.
The documented `emb bundle --arch x86_64 --mode release --build` workflow
successfully assembled `$HOME/dev/infotainment/bundle/argo-release-x86_64`;
the unchanged projection-view library was staged into its `lib` directory.
Use the existing [IHS launch workflow](../tool/projection/README.md), not the
CLI's generic executable-name suggestion. No application was launched for
appearance acceptance.
