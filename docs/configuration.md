# Configuration reference

Audited against [this revision](status.md). These are runtime process environment
options, including release/AOT builds, not `--dart-define` settings. All are
optional unless a prerequisite below makes them required. App selections are
read at bootstrap and require restart; native options are read at library/view
creation; daemon options are read at startup. No environment hot reload exists.
Path examples use shell expansion; putting `$HOME` literally into JSON or an IDE
configuration does not necessarily expand it.

Exports affect only that shell and subsequently launched children. Exporting a
certificate or socket in terminal 1 does not configure terminal 2 or an already
running process. Use the same explicit paths in both launch terminals.

## Application and test helper

| Variable | Default / accepted values | Reader, timing, prerequisites and safe example |
|---|---|---|
| `ARGO_MODE` | `production`; `production`, `simulation` (trimmed, case-insensitive) | App bootstrap; simulation replaces CAN input with read-only in-memory input, not all host backends. Example `simulation` with power/audio explicitly disabled. |
| `ARGO_VEHICLE_PROFILE` | `generic`; registered profile ID | App bootstrap; external ID requires valid discovered bundle. Example `generic`. Unknown selection fails. |
| `ARGO_VEHICLE_INTEGRATIONS_DIR` | Unset: no external discovery | App bootstrap; absolute existing parent directory of bundles. Example `$HOME/.local/share/project-argo/vehicles`. |
| `ARGO_SIMULATION_SCENARIO` | Unset/blank: no scenario | App bootstrap, only in simulation; readable scenario JSON. Example `$HOME/dev/argo/tool/simulation/veloce_can_decoder.json`. |
| `ARGO_SETTINGS_FILE` | Per-user `project-argo/settings.json` | App bootstrap; optional file path, writable parent needed for saves. Example `$HOME/.config/project-argo/development.json`. |
| `ARGO_AUDIO_BACKEND` | `disabled`; `disabled`, `pipewire` | App bootstrap; Linux, running PipeWire/WirePlumber and `wpctl` for real control. Safe example `disabled`. |
| `ARGO_HOST_POWER_BACKEND` | `disabled`; `disabled`, `linux-systemd` | App bootstrap; Linux/systemctl and host authorization for suspend/poweroff. Safe example `disabled`. Real operations require deliberate opt-in. |
| `ARGO_FAKE_SYSTEMCTL_LOG` | `/tmp/argo-systemctl.log`; file path | Only `tool/host_power/fake-systemctl`, each invocation. Not a production setting. Example `/tmp/argo-power-check.log`; fake must be installed ahead of systemctl in PATH. |

Settings default base: Linux `XDG_CONFIG_HOME` or `$HOME/.config`; Windows
`APPDATA` then `LOCALAPPDATA`; macOS `$HOME/Library/Application Support`.
The runtime native integrations are not all supported merely because a settings
path exists on an OS.

## Projection

| Variable | Default / accepted values | Reader, timing, prerequisites and safe example |
|---|---|---|
| `ARGO_PROJECTION_BACKEND` | `disabled`; `disabled`, `android-auto` | App bootstrap; native view also checks test conflicts. AA requires Linux, daemon, identity and IHS for display. Example `disabled`. No wireless/test backend value. |
| `ARGO_PROJECTION_RENDER_TEST` | Unset or `0`: off; exactly `1`: on | App bootstrap and native view/factory; other values rejected by Dart. Requires disabled projection backend, native library/IHS/videotestsrc. Example `1` via launcher. No phone/daemon/credentials needed. |
| `ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS` | Off; exactly `1` enables | App bootstrap; logs geometry changes, not frames. Example `1` for measured comparison. Other values leave it off. |
| `ARGO_PROJECTION_VIEW_LIBRARY` | `libargo_projection_view.so` | Dart registry loader at bootstrap when AA/test selected; dynamic library path. Example `$HOME/dev/infotainment/bundle/argo-render-test/lib/libargo_projection_view.so`. Matching IHS ABI required. |
| `ARGO_PROJECTION_DRM_RENDER_NODE` | Native EGL/Vulkan device discovery | Native view allocator setup; optional DRM render-node path. Use a locally verified node; leave unset for safe default discovery, never assume renderD128 on every host. Renderer launcher preserves explicit override. |
| `ARGO_PROJECTION_SOCKET` | **App:** `/run/argo/projection.sock`; **daemon:** `$XDG_RUNTIME_DIR/argo/projection.sock`, falling back to `/run/argo/projection.sock` | App connect and daemon bind at startup; set both explicitly to `$XDG_RUNTIME_DIR/argo/projection.sock`. Requires writable private parent, available Unix socket path. App trims blank to default; daemon treats supplied value literally. |
| `ARGO_PROJECTION_MEDIA_SOCKET` | No default | Daemon configuration and native view creation; required for live native video, ignored in test. Set both to `$XDG_RUNTIME_DIR/argo/projection-video.sock`. Do not supply blank. |
| `ARGO_ANDROID_AUTO_CERT_FILE` | No default | **Both app and daemon** for AA; readable PEM certificate path, example `$HOME/.config/project-argo/android-auto/argo.crt`. App validates and sends identity paths in control IPC; standalone daemon reads its own environment. |
| `ARGO_ANDROID_AUTO_KEY_FILE` | No default | Both app and daemon for AA; matching private-key PEM, example `$HOME/.config/project-argo/android-auto/argo.key`. Keep outside repository/plugin/settings directories, restrict file permissions. |
| `ARGO_PROJECTION_LOG_LEVEL` | `info`; `error`, `warn`, `info`, `debug`, `trace` | Daemon startup, release supported; invalid value fails startup. Example `debug`. INFO transitions/socket locations; WARN/ERROR failures; DEBUG setup/focus/consumer detail; TRACE RX/TX/ping metadata without media/credential dumps. Independent of renderer logging. |

The renderer launcher consumes `FLUTTER_WORKSPACE` (default
`$HOME/dev/infotainment`) and `IHS_PREFIX` (default
`$HOME/dev/ivi-build/out/usr/local`), preserves only explicit DRM-node and geometry
options among inherited Argo/Veloce variables, then sets its isolated configuration.
`LD_LIBRARY_PATH`, `PATH`, `XDG_RUNTIME_DIR`, `PKG_CONFIG_PATH`, and the workspace
engine environment also affect loading/builds; they are not Argo feature flags.
The launcher sets `VELOCE_LUA_LIBRARY` and IHS/bundle library search paths.

## Veloce integration

These `VELOCE_*` options are read by **Argo's Dart integration at bootstrap**,
not by a separate Veloce daemon. All are optional.

| Variable | Default / accepted values | Prerequisites and safe development example |
|---|---|---|
| `VELOCE_PLUGIN_DIR` | Explicit path overrides selected bundle's `plugins/`, then per-user `plugins/` fallback | Directory of immediate plugin directories; example `$HOME/.local/share/project-argo/empty-plugins` (create empty directory). Override does not grant privileged bundle provenance. |
| `VELOCE_PLUGIN_STORAGE` | Per-user `storage/` | Directory, not database filename; app appends `plugins.sqlite3`. Writable. Example `$HOME/.local/share/project-argo/dev-plugin-storage`. |
| `VELOCE_LUA_LIBRARY` | Platform loader name: Linux `libveloce_lua_native.so`, Windows `veloce_lua_native.dll` | Matching built native library. Example `$HOME/dev/infotainment/bundle/argo-render-test/lib/libveloce_lua_native.so`. |
| `VELOCE_TRACE_VEHICLE_KEY` | Unset/blank: off; one normalized signal key | Terminal/developer log subscription. Example `engine.rpm` with synthetic input; do not trace private vehicle data in shared logs. |
| `VELOCE_CAN_INPUT` | Unset: unavailable; trimmed case-insensitive `socketcan` selects Linux CAN; other strings also leave it unavailable | Only production mode uses selection. Safe example unset; use `socketcan` only with preconfigured vcan for development. |
| `VELOCE_SOCKETCAN_INTERFACE` | `can0`; nonempty interface name under 16 characters, no slash/NUL | Only SocketCAN selection; existing Linux interface. Example `vcan0`. |
| `VELOCE_CAN_BUS` | `comfort`; 1–64 letters/digits/underscore/hyphen | Logical name used by plugin filters, not interface name. Example `comfort`. |
| `VELOCE_CAN_WRITE_ENABLED` | `false`; true: `1/true/yes/on`; false: `0/false/no/off` (case-insensitive) | Only SocketCAN selection; invalid boolean fails. Example `false`. Writes additionally need plugin `can.write` permission/filter/rate grants. Simulation always disables writes. |

Per-user Veloce base is `project-argo/veloce` under Linux `XDG_DATA_HOME` or
`$HOME/.local/share`, Windows `LOCALAPPDATA`, or macOS Application Support.
Missing required user-directory resolution fails startup. Optional path overrides
are trimmed and made absolute relative to the working directory; use absolute
paths to avoid ambiguity. Vehicle integration discovery specifically requires
an absolute path.

## Typed saved settings

The JSON document has `schemaVersion: 1` and a `values` object keyed below.
`SettingsService` validates typed values, falls back on malformed values, preserves
unknown fields and serializes writes. Corrupt documents are preserved when
possible. Edit with the application stopped; external edits are not watched.
The service's `set`/`reset` is the supported in-app change path.

| Key | Type, default and accepted values | Effect |
|---|---|---|
| `app.navigation.lastModule` | String `home`, nonempty | Last selection; shell resolves registered modules and falls back for unavailable IDs. |
| `audio.master.volume` | Number `0.5`, 0..1 | Requested master volume; real backend applies supported operation. |
| `audio.master.muted` | Boolean `false` | Requested mute. |
| `audio.output.balance` | Number `0`, -1..1 | Saved preference; current wpctl backend cannot apply. |
| `audio.output.fader` | Number `0`, -1..1 | Saved preference; current wpctl backend cannot apply. |
| `audio.equalizer.bassDb`, `audio.equalizer.midDb`, `audio.equalizer.trebleDb` | Each number `0`, -12..12 | Saved EQ preferences; current wpctl backend cannot apply. |
| `audio.output.preferred` | String `""` | Requested output; current wpctl backend has no output selection mutation. |
| `projection.display.width` | Integer `1280`, 640..3840 | Bootstrap preference sent before connection; daemon supports only paired sizes below. |
| `projection.display.height` | Integer `720`, 360..2160 | Same; changing preference does not resize a negotiated live stream. |
| `projection.display.dpi` | Integer `160`, 72..640 | Bootstrap/negotiation request, not desktop DPR. |
| `projection.display.framesPerSecond` | Integer `30`, 30 or 60 | Bootstrap/negotiation request. |
| `projection.display.driverSide` | String `left`, `left` or `right` | Bootstrap/negotiation request. |
| `projection.display.safeInset.left`, `.top`, `.right`, `.bottom` | Each integer `0`, 0..1000 | Saved/bootstrap model only: current hello IPC does not transmit these preferences. Runtime stream insets come from the daemon descriptor. |

The daemon's supported size pairs are 800×480, 1280×720 and 1920×1080; unsupported
pairs fail even if each saved integer passes settings validation. The daemon also
requires DPI 80..640, narrower than Dart's 72..640 setting range. Safe-inset
preferences are loaded into ProjectionPreferences but not sent in hello IPC;
they do not currently change AA negotiation. Presentation
Compare size changes only the fitted destination, not AA resolution/DPI/FPS.
The renderer pattern is fixed at 1280×720/30 independently of saved preferences.
Only wired USB Android Auto is implemented as a real backend; `wifi`/`carPlay`
model enum values are not selectable implementations.

Audio policy/focus state and backend capabilities determine applied behavior;
a stored value or fake-backend test is not proof of a system mutation. Settings
UI currently exposes audio controls, not an editor for every schema key.
Credentials, network secrets and vehicle private data do not belong in this
settings document or plugin storage. There is no completed provisioning UI.
