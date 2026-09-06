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
| Long-running projection | Current frame path has an identified host-side release-eventfd retention issue. | User reported repeated `dup(release eventfd) failed (errno=24)` after the comparison work. Not fixed in Argo or IHS here. |

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
not fix ownership. The earlier source diagnosis has not been followed by an IHS
patch or a post-fix endurance run; this task explicitly leaves IHS unchanged.

## Phone connection, logs and security

USB accessory re-enumeration changes device identity; VMware forwarding and
udev permissions must cover both normal and accessory devices. Use exact
VID/PID-scoped permissions and a non-root process. Follow the
[projection runbook](../tool/projection/README.md) rather than deleting sockets
or opening broad USB access. Set the control/media paths explicitly in both
terminals: app and daemon control defaults differ. Check listener ownership
before removing stale sockets. Start the daemon before connecting the phone and
before Argo's initial sidecar connection; there is no automatic daemon supervisor
or robust sidecar reconnect loop. Unplug/replug handling exists, but repeated
real-device reconnect/endurance acceptance is outstanding.

Daemon `ARGO_PROJECTION_LOG_LEVEL` defaults to INFO; DEBUG shows detailed setup,
TRACE packet metadata and pings. Real failures remain WARN/ERROR. IHS has its own
logging; this variable does not silence `[ihs_pv]` warnings. Geometry and renderer
logs are independently opt-in. Share relevant stages/metadata after reviewing
for private identifiers; never share private keys or media payload dumps.

Both Dart and daemon currently require configured AA identity paths. Dart
validates and transmits paths through local IPC; daemon-only provisioning is not
implemented. TLS is 1.2 with resumption disabled. The USB-specific permissive
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

Wireless Android Auto, Bluetooth integration, CarPlay transport, new metadata
APIs, customization, plugin-rendered Argo tabs/settings/widgets and complete
microphone capture are future work. `wifi`/`carPlay` enums and Veloce's broader UI
APIs are scaffolding/capabilities, not present usage instructions. No such feature
or IHS/Veloce change is implemented by this documentation update.

## Follow-up code questions, not changes in this task

- Align Dart/daemon default control socket paths or retain explicit dual-process
  configuration as a documented requirement.
- Reconcile settings validation with daemon DPI bounds (Dart 72..640 versus
  daemon 80..640), and decide whether to wire or remove saved safe-inset
  preferences currently absent from hello IPC. Runtime stream insets are separate.
- Reconcile microphone advertisement/open success with the absent capture path.
- Correct host GL release-eventfd retirement only in a separately authorized IHS
  task, then perform an FD-count/endurance run. No workaround here changes buffer
  IDs, allocation, modifiers or fence ownership.
- Test latest gestures, reconnect and live-AA artifacts at measured 1:1 with a
  phone; target hardware and undelivered host focus events remain unverified.


These mismatches are documented rather than silently resolved or presented as
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
