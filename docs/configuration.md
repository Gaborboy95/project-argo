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
running process. Use the same socket paths in both launch terminals. Identity paths belong only
to the daemon; explicitly unset both identity variables when starting Argo.

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
| `ARGO_PROJECTION_BACKEND` | `disabled`; `disabled`, `android-auto` | App bootstrap; native view also checks test conflicts. AA requires Linux, a configured daemon and IHS for display; only the daemon loads identity. Example `disabled`. No wireless/test backend value. |
| `ARGO_PROJECTION_RENDER_TEST` | Unset or `0`: off; exactly `1`: on | App bootstrap and native view/factory; other values rejected by Dart. Requires disabled projection backend, native library/IHS/videotestsrc. Example `1` via launcher. No phone/daemon/credentials needed. |
| `ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS` | Off; exactly `1` enables | App bootstrap; logs geometry changes, not frames. Example `1` for measured comparison. Other values leave it off. |
| `ARGO_PROJECTION_VIEW_LIBRARY` | `libargo_projection_view.so` | Dart registry loader at bootstrap when AA/test selected; dynamic library path. Example `$HOME/dev/infotainment/bundle/argo-render-test/lib/libargo_projection_view.so`. Matching IHS ABI required. |
| `ARGO_PROJECTION_DRM_RENDER_NODE` | Native EGL/Vulkan device discovery | Native view allocator setup; optional DRM render-node path. Use a locally verified node; leave unset for safe default discovery, never assume renderD128 on every host. Renderer launcher preserves explicit override. |
| `ARGO_PROJECTION_SOCKET` | Explicit path, otherwise `$XDG_RUNTIME_DIR/argo/projection.sock`, otherwise `/run/argo/projection.sock` | Same resolution in app and daemon at startup. Example `$XDG_RUNTIME_DIR/argo/projection.sock`. Explicit empty, relative, surrounding-whitespace, NUL or ≥108-byte Unix paths are rejected. New daemon-owned parent directories are private; live sockets are never automatically deleted. |
| `ARGO_PROJECTION_MEDIA_SOCKET` | Explicit path, otherwise `$XDG_RUNTIME_DIR/argo/projection-video.sock`, otherwise `/run/argo/projection-video.sock` | Same resolution in daemon and native view; same explicit-path validation as control. Ignored by renderer-test source. Example `$XDG_RUNTIME_DIR/argo/projection-video.sock`. |
| `ARGO_ANDROID_AUTO_CERT_FILE` | No default | **Daemon only**, startup validation and session TLS loading; external readable PEM certificate, e.g. `$HOME/.config/project-argo/android-auto/argo.crt`. Missing/invalid identity is reported through control readiness without disabling the rest of Argo. Restart daemon after correcting files. |
| `ARGO_ANDROID_AUTO_KEY_FILE` | No default | **Daemon only**; private-key PEM, e.g. `$HOME/.config/project-argo/android-auto/argo.key`. Keep permissions restricted and files outside repository/plugin/settings directories. Dart ignores inherited identity variables and never opens/parses/transmits keys or identity paths. |
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
| `projection.display.width` | Integer `1280`, 640..3840 | Validated next-session request; daemon supports only paired sizes below. |
| `projection.display.height` | Integer `720`, 360..2160 | Same; changing preference does not resize a negotiated live stream. |
| `projection.display.dpi` | Integer `160`, 80..640 | Validated next-session request, not desktop DPR. |
| `projection.display.framesPerSecond` | Integer `30`, 30 or 60 | Next-session negotiation request. |
| `projection.display.driverSide` | String `left`, `left` or `right` | Next-session negotiation request. |
| `projection.display.safeInset.left`, `.top`, `.right`, `.bottom` | Each integer `0`, 0..1000 | Stored compatibility keys only: configuration IPC does not transmit these preferences. Runtime stream insets come from the daemon descriptor. |

The daemon advertises supported resolution **pairs** 800×480, 1280×720 and
1920×1080, 30/60 FPS, DPI 80..640, left/right driver, and fixed audio formats.
Settings scalar bounds remain compatible for width/height, but ProjectionPreferences
and daemon request validation require a catalog pair. Unsupported older stored
pairs recover to 1280×720/30/160/left with a diagnostic and persisted defaults;
invalid scalar values follow SettingsService's existing default recovery.

Settings → **Android Auto / Apple CarPlay** edits these preferences using the
connected daemon's catalog, not a widget-owned mode list. CarPlay remains
unimplemented. DPI saves on Enter; menus save on selection. The page separately
shows saved request, daemon-validated next connection, and current session-selected
parameters. Rejections retain the daemon's previous valid configuration. While
the daemon is unavailable, saved values remain visible but editing is disabled;
reset can save defaults locally with an explicit unvalidated notice. Acknowledgement
is not phone acceptance. All negotiation-sensitive changes apply on the **next
phone connection**, without automatic disconnection.

Safe-inset keys remain compatible storage but have no applied AA mapping and no
enabled controls. Runtime stream content/safe insets remain independent metadata;
rendering/touch fit and physical presentation are unchanged. Compare size does
not renegotiate source resolution, DPI or FPS. Renderer-test source stays fixed
at 1280×720/30. Model enum values `wifi`/`carPlay` are not implemented backends.

Native playback reports fixed PCM formats: media 48 kHz/16-bit/stereo;
speech/navigation and system 16 kHz/16-bit/mono. They share the daemon's discovery,
playback and session-metadata descriptor; there are no arbitrary audio-format
controls. Per-stream gain is separate from system master volume. Microphone
startup signaling remains partial scaffolding with no capture/upload pipeline.
Selected caps and source descriptors are not observations of decoded video,
physical refresh rate, Flutter DPR, or the host audio device's output format.

Credentials, network secrets and vehicle private data do not belong in this
settings document or plugin storage. There is no completed provisioning UI.

## IPC compatibility and ownership

IPC v2 is incompatible with v1: rebuild/restart both client and daemon together.
Hello has no configuration or identity payload. One client owns control for the
lifetime of its connection; a second receives an explicit ownership error and
must reconnect after the first closes. There is no observer takeover or automatic
supervisor. Capabilities/readiness work even with identity missing or invalid.
Validated requests are revisioned, held in daemon memory and frozen when a phone
session starts. An already-started standalone session keeps its selected defaults
when Argo attaches; different saved preferences become pending for its next
connection. The daemon has no user-settings database; restart restores daemon
defaults until Argo sends its saved request. See the [wire contract](architecture.md).
