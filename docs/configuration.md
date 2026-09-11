# Configuration reference

These are runtime process environment
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
| `ARGO_ANDROID_AUTO_HEVC` | `0` | Daemon startup: `1` offers H.265 alongside H.264 after parser/decoder preflight. Requires the matching HEVC-capable native view. Phone selects the codec; restart the daemon to change the offer. |
| `ARGO_ANDROID_AUTO_PROTOCOL_VERSION` | `1.1` | Daemon startup: explicitly supports `1.1` or experimental `1.7` wire negotiation. This is not the phone app or AndroidX Car App version. Negotiated response is logged; no implicit downgrade/retry with another version. |
| `ARGO_PROJECTION_DRM_RENDER_NODE` | Native EGL/Vulkan device discovery | Native view allocator setup; optional DRM render-node path. Use a locally verified node; leave unset for safe default discovery, never assume renderD128 on every host. Renderer launcher preserves explicit override. |
| `ARGO_PROJECTION_SOCKET` | Explicit path, otherwise `$XDG_RUNTIME_DIR/argo/projection.sock`, otherwise `/run/argo/projection.sock` | Same resolution in app and daemon at startup. Example `$XDG_RUNTIME_DIR/argo/projection.sock`. Explicit empty, relative, surrounding-whitespace, NUL or ≥108-byte Unix paths are rejected. New daemon-owned parent directories are private; live sockets are never automatically deleted. |
| `ARGO_PROJECTION_MEDIA_SOCKET` | Explicit path, otherwise `$XDG_RUNTIME_DIR/argo/projection-video.sock`, otherwise `/run/argo/projection-video.sock` | Same resolution in daemon and native view; same explicit-path validation as control. Ignored by renderer-test source. Example `$XDG_RUNTIME_DIR/argo/projection-video.sock`. |
| `ARGO_ANDROID_AUTO_CERT_FILE` | No default | **Daemon only**, startup validation and session TLS loading; external readable PEM certificate, e.g. `$HOME/.config/project-argo/android-auto/argo.crt`. Missing/invalid identity is reported through control readiness without disabling the rest of Argo. Restart daemon after correcting files. |
| `ARGO_ANDROID_AUTO_KEY_FILE` | No default | **Daemon only**; unencrypted PKCS#8 PEM with `BEGIN PRIVATE KEY` / `END PRIVATE KEY` markers (not a PKCS#1 `RSA PRIVATE KEY` file), e.g. `$HOME/.config/project-argo/android-auto/argo.key`. Keep permissions restricted and files outside repository/plugin/settings directories. Dart ignores inherited identity variables and never opens/parses/transmits keys or identity paths. |
| `ARGO_HOST_STATE_DIAGNOSTICS` | Off; exactly `1` enables | Argo/Veloce startup; forwards DEBUG logs from explicitly loaded host-read-capable resources, newest line at most every 3 seconds, truncated/quoted. May contain track/device text; development-only opt-in. Example `1` during the synthetic observer check. No CAN dependency. |
| `ARGO_PROJECTION_LOG_LEVEL` | `info`; `error`, `warn`, `info`, `debug`, `trace` | Daemon startup, release supported; invalid value fails startup. Example `debug`. INFO transitions/socket locations; WARN/ERROR failures; DEBUG setup/focus/consumer detail and bounded wireless liveness/cleanup timing; TRACE RX/TX/ping metadata without media/credential dumps. Independent of renderer logging. |

Identity must already be available externally. The loader parses certificates and
PKCS#8 key material; its structural readiness check is not certification or a
complete identity-provisioning workflow. Use the working daemon identity rather
than generating replacement keys to troubleshoot transport failures. The current
compatibility loader does not establish a trusted phone certificate chain. Wireless
handshake signatures are checked separately; see [wireless security](wireless.md#security-and-admission).

| Connectivity/launcher variable | Default and application timing |
|---|---|
| `ARGO_WIRELESS_BUNDLE` | Optional absolute staged release directory selected by `tool/connectivity/run-release.sh`; its local fallback is defined in the script. Set explicitly in both terminals for deployment. |
| `IHS_PREFIX` | Launcher/build convention, default `$HOME/dev/ivi-build/out/usr/local`; must contain matched executable/library/header assets. |

The release launcher fixes control/media socket paths beneath
`$XDG_RUNTIME_DIR/argo-wireless-ipc6/`, defaults host audio to PipeWire (explicit
`ARGO_AUDIO_BACKEND=disabled` is respected), selects production/android-auto, and clears
the renderer-test flag. Direct daemon/app launches instead use the socket resolution
rules in the table. It sets native-view/Lua library and loader paths from the bundle.
It does not read identity into the application or perform pairing/provisioning.

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
| `connectivity.autoConnectPhone` | Boolean `true` | Settings → Devices: one bounded startup request for the remembered paired phone; disabling cancels pending startup actions for this run. |
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
| `projection.display.viewInset.left`, `.top`, `.right`, `.bottom` | Each integer `0`, 0..1000 | Additional encoded-pixel margins, combined with measured aspect fitting; next connection. |
| `projection.display.safeInset.left`, `.top`, `.right`, `.bottom` | Each integer `0`, 0..1000 | Minimum content-pixel safe insets; bottom also reserves the collapsed floating media slot; next connection. |

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

### View Area and Safe Area

The encoded video tier stays unchanged. Argo measures the actual region above the
dock and adds balanced View Area margins so the remaining content fits that aspect
ratio, rounded to even content dimensions. Settings expose additional margins in
encoded pixels. The native view removes only these negotiated margin pixels during
its existing row copy; there is no extra resampling stage. Touch uses the same
remaining content rectangle. Do not use margins to crop arbitrary controls from an
already negotiated picture.

Safe Area is separate: `UiConfig.content_insets` and `stable_content_insets` request
that AA keep important UI clear of the host overlay. Its minimum bottom inset covers
the closed media panel plus its gap above the dock, even when the strip is hidden.
Settings → Projection → Calculate automatically clears manual margin overrides
and uses this measured fit, preserving resolution, FPS and DPI. The page displays
the available viewport and media clearance in logical pixels; negotiated insets
are converted to source pixels. Maps may render beneath
it; individual phone applications must honor the layout hint for this to work.
Expanded panels remain modal overlays, not new safe-area negotiations.

Manual values are persisted; measured margins are runtime requests. The first
measured layout and subsequent viewport changes are debounced. The daemon freezes
both areas when a session begins. A phone connected before the first application
layout keeps its prior geometry; reconnect to apply the measured fit. Resizing an
active session aspect-fits its frozen content until the next connection. Media
visibility, panel expansion and Control size do not change the reserved geometry.
Invalid combinations that leave no content are rejected. Renderer-test source stays
1280×720 with no phone-negotiated crop. See [wireless setup](wireless.md).

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

IPC v7 is incompatible with v1–v6: rebuild/restart both client and daemon together.
Session/video messages include session-scoped presentation revisions; AV stops
are distinct from explicit host-return intent. Hello has no configuration or identity payload. One client owns control for the
lifetime of its connection; a second receives an explicit ownership error and
must reconnect after the first closes. There is no observer takeover or automatic
supervisor. Capabilities/readiness work even with identity missing or invalid.
Validated requests are revisioned, held in daemon memory and frozen when a phone
session starts. An already-started standalone session keeps its selected defaults
when Argo attaches; different saved preferences become pending for its next
connection. The daemon has no user-settings database; restart restores daemon
defaults until Argo sends its saved request. See the [wire contract](architecture.md).


Host media/phone state is live, not a setting. Track, playback and phone state are not persisted in Argo settings. Artwork is an ephemeral private runtime cache; NetworkManager alone retains the
owned AP credential template. Backend DEBUG emits bounded revision-only
metadata diagnostics; packet metadata remains TRACE. The optional host diagnostic
switch only exposes observer DEBUG lines; it does not grant Lua read permission.
Read access requires `argo.host.read.v1`; see [the host API](vehicle-integrations.md#read-only-argo-host-state-v1).
The generic profile does not automatically install the synthetic observer.

## Appearance preferences

Settings → Appearance applies immediately after the existing settings store
successfully saves a change; preferences survive restart. No environment flag or
additional settings file is used.

| Typed key | Default | Accepted persisted value |
|---|---|---|
| `appearance.themeMode` | `dark` | String: `light`, `dark`, `system` |
| `appearance.controlSize` | `1.0` | Number: `1.0` (Standard), `1.15` (Large), `1.3` (Extra large); live host sizing only |
| `appearance.seedColor` | `#6750A4` | Opaque six-digit RGB string `#RRGGBB`; case-insensitive input, normalized uppercase in memory |

The default accent retains Flutter's existing Material 3 palette. Other seeds
produce light/dark Material ColorSchemes. The UI offers Purple (default), Teal
(`#006A6A`), Blue (`#005AC1`) and Amber (`#895100`). Seed colours are not exact
foreground colours: Material derives readable surface/foreground pairs.
Malformed stored values produce the existing settings diagnostic and fall back
to the corresponding default. Reset appearance removes only these three overrides;
audio, projection preferences and the selected module remain intact.

“System” follows the brightness preference reported to Flutter, using
MaterialApp's ThemeMode.system. Live desktop brightness-preference propagation through the reference IHS build
is not verified; system mode depends on host forwarding. Manual light/dark selection works
independently. This setting does not control physical display brightness,
headlights, vehicle night mode or Android Auto's day/night mode.
The projection region remains opaque black, including letterboxing. Wallpaper,
shaders and vehicle-driven day/night selection remain future work.

## Connectivity requests

Settings → Devices saves `connectivity.bluetoothAdapter`,
`connectivity.projectionInterface`, and `connectivity.projectionPhone` as bounded
string references (default empty). BlueZ owns bonds and NM owns AP profiles; no
secrets are saved in these preferences. `connectivity.projectionBand` stores
`2.4ghz` or `5ghz` (default `5ghz`); the daemon validates it and uses only permitted
channels in that band, without automatic cross-band fallback. Selection changes during a session apply
on the next connection. Wireless capability is enabled automatically when a selected
managed Wi-Fi interface supports AP mode and a permitted channel in that band.
A card used by another connection is unavailable. If exactly one candidate is viable
and no interface was chosen, it is selected; ambiguity requires selection. Disable
persists for the application connection until explicitly enabled again. Capability detection itself does not connect or start discovery. The separate
saved startup preference can request a connection to the remembered paired phone.
The former `ARGO_WIRELESS_DEVELOPMENT` flag is no longer read.
See [security, permissions, launch and rollback](wireless.md).

## Bluetooth music and media ownership

Bluetooth music uses the same IPC v7 connectivity envelope with an optional `music`
capability/state object, generation-scoped requests and operation acknowledgements.
Use a matched release: an older daemon without this object has no music controller.
There is no new media payload channel or Lua write permission.

`ARGO_PROJECTION_BACKEND=disabled` selects a connectivity-only client on Linux and
disables native projection admission; shared pairing/music remain available. The
normal launcher respects this setting. With `android-auto`, absent/invalid daemon
identity prevents AA startup but does not disable Bluetooth. Music connection requires a manual or saved startup request. Selected
entertainment source and bounded connection intent remain session-local; the
startup preference does not select music or begin playback.

Administrator-approved firewall interfaces/accounts are stored only in root-owned
`/etc/argo/projection-firewall.json`; the runtime cannot edit the helper or polkit
grant. The per-account A2DP routing opt-in requires logout/login and does not change
Bluetooth roles or codecs. See [Media setup](media.md#setup-and-use) and the
[permission installer](wireless.md#permissions-and-helper-installation).

The shared Bluetooth adapter choice is saved by its hardware address (older `hciN`
choices migrate when that adapter is available). Pairing, wireless bootstrap and
music admission use that same adapter. Settings and Media list its devices only;
other adapters and bonds remain available to the desktop. A missing preferred
adapter does not authorize a fallback. Change adapters while discovery, pairing,
wireless projection and music are idle.


## Microphone selection

`connectivity.microphoneInput` stores a PipeWire source `node.name` (empty by
default, maximum 256 characters). The shared input is selected in Settings → Sound
or Calls. Its absence prevents capture rather than selecting a different input.
Selection changes take effect only without a capture owner. Microphone mute and
Connect calls are runtime actions. The separate deployment startup preference may request the call profile at graphical application startup; it does not initiate a call or capture.
The daemon requires `pw-dump`, `pw-cat`, `pw-loopback` and `setpriv` on PATH
(`setpriv` is invoked at `/usr/bin/setpriv`). No microphone environment variable,
AA identity in Flutter, root execution or additional Bluetooth profile is needed.
See [voice routing and limitations](media.md#shared-microphone-and-usb-adc).

## Deployment configuration

Managed deployment uses `$HOME/.config/project-argo/`:

- `current-release`: the atomic shared release symlink; change it with `argoctl select`.
- `previous-release.json`: the previous managed selection used by `argoctl rollback`.
- `deployment.json`: absolute `ihs_prefix`, common `environment` map and default-off
  `connect` booleans (`wireless`, `music`, `calls`) and optional `display` options.
- `daemon.json`: daemon-only identity paths and optional AA wire/codec opt-ins.
- `settings.json`: existing application preferences; release switches never replace it.

`deployment.json` accepts these common environment keys: `ARGO_AUDIO_BACKEND`,
`ARGO_PROJECTION_BACKEND`, `ARGO_PROJECTION_LOG_LEVEL`, `ARGO_HOST_POWER_BACKEND`,
`ARGO_MODE`, `ARGO_VEHICLE_PROFILE`, `ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS` and
`ARGO_PROJECTION_RENDER_TEST`. The renderer test requires the disabled projection
backend and must not be used for normal phone operation. Defaults are production mode, Android Auto,
PipeWire and disabled host power. Use the option values documented above.
Unknown keys are rejected. The launcher strips ambient ARGO, Veloce and dynamic
loader overrides, then supplies matched view/Lua libraries and private runtime
sockets below `$XDG_RUNTIME_DIR/project-argo`. It preserves the graphical-session
Wayland/bus environment and ordinary XDG preference locations.

`daemon.json` accepts `ARGO_ANDROID_AUTO_CERT_FILE`, `ARGO_ANDROID_AUTO_KEY_FILE`,
`ARGO_ANDROID_AUTO_HEVC` and `ARGO_ANDROID_AUTO_PROTOCOL_VERSION`. It starts empty;
AA requires configured external identity, while Bluetooth does not. The `identity`
command writes only external paths into this private file. Never add identity to
common environment settings, the user manager environment, bundles or application
preferences. `daemon.json` is loaded exclusively when executing the daemon.

All deployment option changes take effect on the next corresponding process start;
they do not mutate a live session. The installed CLI saves opt-in connection choices:

```bash
"$HOME/.local/bin/argoctl" autoconnect wireless on
"$HOME/.local/bin/argoctl" autoconnect music on
"$HOME/.local/bin/argoctl" autoconnect calls on
# Each can be independently disabled:
"$HOME/.local/bin/argoctl" autoconnect wireless off
```

Settings → Devices → **Auto-connect phone** is saved in application preferences
and defaults to **on**. No discovery budget is spent while the app waits for the
daemon connection, connectivity availability, adapter inventory and completion of
saved adapter/interface restoration. Once these prerequisites hold, a bounded
90-second window waits for the exact remembered phone to appear paired and selected,
then for controller readiness. Argo never substitutes another paired phone.

With projection configured (`ARGO_PROJECTION_BACKEND=android-auto`), the generic
phone request waits for wireless availability and enablement; transient missing
Wi-Fi/NetworkManager inventory does not fall back to music. Only an explicitly
projection-disabled application configuration permits the generic request to use
Bluetooth music. Disabling projection during the wait cancels the pending request.
No valid remembered paired phone leaves the ordinary disconnected UI after expiry.
INFO lifecycle messages report arming, adapter/phone waiting, restoration, wireless
waiting, request issuance, cancellation and expiry once per run without device
identifiers or credentials.
The deployment options above can additionally request specific profiles (each
remains off by default), but the application setting is the master switch for all
startup phone requests. Calls are not automatically requested by the default alone.

Each ready profile request is consumed before sending, and an already connecting
or connected controller is not started again. Existing controllers retain their
bounded retry policy. Explicit Connect consumes its pending startup request;
Disconnect or Disable cancels all remaining startup requests for the run. Forget
clears the matching remembered phone, while selection changes or Quit also cancel
pending requests. Turning the setting on again does not rearm the current run;
a later application start creates a fresh window. Manual Connect still works when
auto-connect is off. AA Exit changes presentation only. Music connection does not
select its source or start playback; use Media for source selection. Calls retain
the existing shared microphone/audio ownership.

### Managed display configuration

The default is `"display": {"fullscreen": true}`. IHS requests fullscreen from
Wayland; the compositor supplies the surface size and output scale. Argo does not
force a resolution, display index or pixel ratio. For a development window, merge
`"display": {"fullscreen": false, "width": 960, "height": 720}` into
`deployment.json`; dimensions are required positive integers. Optional
`"output_index": 0` selects an IHS output index when explicitly configured.
Changing these options requires an app restart. Application control size remains
independent of window size and desktop scaling.

`ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS=1` logs source size, fitted logical/physical
rectangles, view DPR and Flutter physical size only when they change. During startup, IHS may
publish view metrics before Flutter's display list; an empty list is reported
without guessing display identity. Native target verification
uses the IHS/Wayland diagnostics in the [renderer guide](../tool/projection/README.md#fullscreen-presentation-geometry).
