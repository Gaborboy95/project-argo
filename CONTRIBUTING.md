# Contributing to Project Argo

Start with [architecture](docs/architecture.md), [configuration](docs/configuration.md)
and the [audited status](docs/status.md). Implementation is the authority when
older runbooks disagree; update public behavior documentation with the code.

- Keep public code vehicle-agnostic. Private decoding, DBCs, assets, thresholds
  and policies belong in external vehicle bundles, never fixtures copied from a
  real private integration. Use synthetic examples.
- Compose dependencies in `lib/app/`, contracts/models in `lib/core/`, platform
  adapters in `lib/integrations/`, and injected presentation in `lib/features/`.
  ServiceRegistry does not own cleanup; register lifecycle release explicitly.
- Keep media bytes native. Preserve IHS PlatformViewLayer composition, stable
  native-view ownership and single touch dispatch. Do not fork or modify IHS or
  Veloce by default to compensate for an unverified Argo issue.
- Preserve regression coverage. Add focused tests for meaningful behavior and
  failure/lifecycle boundaries, not a target test count. Reuse existing fakes.
- Document new public configuration/API names, defaults, prerequisites, timing,
  capability limits and safe examples with their implementation. Separate future
  plans from working commands and saved settings from actual applied behavior.
- Keep credentials and secrets external. Development examples disable real host
  power; real suspend/poweroff and CAN writes require deliberate opt-in.
- Stop owned processes before staging shared libraries; inspect socket ownership
  before cleanup. Never run the application as root or rebuild Engine/IHS for
  routine Dart work.

For code changes, format touched Dart/Rust, run analyzer and relevant tests.
For native changes, build against the matched local dependencies when supported.
The [projection](tool/projection/README.md), [audio](tool/audio/README.md) and
[power](tool/host_power/README.md) runbooks contain scoped validation workflows.
Documentation-only work needs link/path/configuration and command-syntax checks,
not hardware tests or privileged example execution.

Report exactly which checks ran, skips and unavailable environments. Mock tests,
compilation and accepted native submissions cannot establish phone, visible-frame
or target-hardware acceptance. Record the revision and user-confirmed environment
for runtime results; do not describe uncommitted changes as released.
