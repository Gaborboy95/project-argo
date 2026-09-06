# External vehicle integrations and Lua plugins

Public Argo contains no real vehicle decoding bundle. Keep private manifests,
DBC content, assets and policies outside the checkout. The
[synthetic example](../tool/vehicle_integrations/example-vehicle) is executable
sample code, not a vehicle specification. Its run commands are maintained in
[tool/vehicle_integrations](../tool/vehicle_integrations/README.md).

## Discovery and vehicle.json

```text
$HOME/.local/share/project-argo/vehicles/   ARGO_VEHICLE_INTEGRATIONS_DIR
  synthetic-demo/
    vehicle.json
    plugins/
      telemetry/
        manifest.json
        main.lua
        assets/                          optional plugin assets
```

The discovery root must be absolute and exist. Argo scans immediate real child
directories, sorted by path, without following child symlinks. Each bundle must
have a regular `vehicle.json` and regular `plugins/` directory; resolved paths
must remain contained. Missing/malformed bundles produce diagnostics; selecting
a failed bundle fails bootstrap. Duplicate external profile IDs fail discovery,
and collisions with built-in profiles fail registration. `ARGO_VEHICLE_PROFILE`
selects a registered ID, default `generic`; it is not selected by directory order.
External profile metadata is discovered once at bootstrap, not watched live.

Exact current vehicle manifest fields:

| Field | Required/default | Validation |
|---|---|---|
| `schemaVersion` | Required, `1` | Must equal supported version. |
| `id` | Required string | At most 128 characters; `^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$`. |
| `displayName` | Required string | Nonempty after trimming for validation; original value retained. |
| `capabilities` | Optional, empty list | Unique nonempty strings, each at most 128 characters; `^[a-z][A-Za-z0-9_-]*(?:\.[a-z][A-Za-z0-9_-]*)+$`. |

Unknown JSON fields are ignored by the current parser; there is no plugin-path,
credential, CAN-interface, schema-extension or policy field in this schema.
Recognized capability constants are `vehicle.telemetry`, `climate.control`,
`parking.sensors`, `camera.reverse`; syntactically valid additional IDs are
accepted metadata, not dynamically implemented features. Climate/Parking remain
placeholder UI even if a bundle declares those capabilities.

Plugin-root precedence is explicit `VELOCE_PLUGIN_DIR` → selected bundle's
`plugins/` → per-user Veloce plugins directory. See [configuration](configuration.md)
for storage/default paths. Overriding the root does not make arbitrary plugins
eligible for active-bundle privileged host requests.

## Lua manifest and exposed capabilities

Veloce parses each plugin's `manifest.json` before executing its relative Lua
entrypoint. The current format has required `id` (lowercase reverse-domain),
`name` (nonempty, ≤128 characters), semantic `version`, `apiVersion` string `"1"`,
relative contained `.lua` `entrypoint`, and `permissions` array without duplicates
or unknown names. Optional `can` contains `read`/`write` filter arrays and
`maxSendRatePerSecond`; filters name a logical `bus`, `ids`, optional `mask`,
`extended`, `includeRemote` and `includeErrors` constraints (also singular `id`
instead of `ids`; no `fd` manifest field). Refer to the matching sibling
`packages/veloce_lua_core/lib/src/manifest/plugin_manifest.dart` for exact optional
CAN-field validation; use the checked-in working read-only example below.

The default capability catalog includes `app.info`, `logging`, `events`,
`vehicle.read`, `vehicle.write`, `can.read`, `can.write`, `storage`, `assets.read`,
`timer`, `ui.tabs`, `ui.render`, `ui.settings`, `ui.quick_controls`, `ui.status`,
`ui.notifications`. Each plugin must declare needed permissions. `can.write`
also needs host enablement and manifest bus/ID/rate authorization; Argo disables
it by default and always in simulation. With no configured CAN provider, a
`can.read` permission does not invent CAN input.

Argo supplies Veloce's normalized data bus, CAN provider, SQLite storage,
isolated native Lua runtime and event bridges. Veloce supports declarative UI
registrations, assets and installer APIs, but Argo currently renders **none of
the plugin UI extension registries** and does not compose a signed-package
provisioning/install workflow. Core permissions are not a claim of a secure
process sandbox; native plugins execute within the application's trust boundary.

## Lifecycle, assets and state

Argo starts PluginManager discovery and filesystem watching. Veloce loads each
plugin generation with owned callbacks/subscriptions/resources. File changes
are debounced and reload is transactional: candidate initialization/validation
must succeed before replacement; a failed candidate leaves the running generation
intact. Removal/unload cleans owned registrations. Host code can use PluginManager
lifecycle operations; Argo has no dedicated plugin-manager UI.

Register resources in `on_load(previous_state)`, optionally return structured
migration data from `on_save_state()`, and use `on_unload()` for final notification.
Host cleanup still applies. Reserved `on_suspend`/`on_resume` names are not a
promise that Argo invokes Lua hooks during system suspend; Argo's current
transport restart preserves Lua generations.

`veloce.assets` exposes permission-checked, read-only plugin assets with contained
relative paths; `veloce.storage` stores plugin-scoped structured values in
`plugins.sqlite3`. Asset permission does not grant arbitrary host filesystem
access. Neither asset nor storage availability means Argo renders a plugin image
widget. Do not put private keys or network secrets in plugin-readable settings,
assets or storage.

## Signals and host commands

Features consume normalized signals, not CAN frames. Current Argo catalog:
`engine.rpm` and `vehicle.battery.voltage` finite numeric values;
`vehicle.power.state`: `unknown/asleep/awake/active`;
`vehicle.ignition.state`: `unknown/off/accessory/on/start`;
`controls.audio.volume_up.pressed`, `volume_down.pressed`, `mute.pressed`,
`source_next.pressed`, `source_previous.pressed` under the same `controls.audio.`
prefix are booleans. See [typed definitions](../lib/core/vehicle/vehicle_signals.dart)
and [power](../lib/core/vehicle/vehicle_power_state.dart)/
[ignition](../lib/core/vehicle/vehicle_ignition_state.dart) values.

Fixed host-consumed event topics:

| Topics | Behavior |
|---|---|
| `audio.command.volume.up`, `audio.command.volume.down` | Service volume-step commands. |
| `audio.command.mute.toggle` | Toggle requested mute through AudioService. |
| `audio.command.source.next`, `audio.command.source.previous` | Cycle service sources subject to available backend capabilities. |
| `host.power.suspend.request` | Standby-gated, deduplicated host suspend request. |
| `host.power.shutdown.request` | Serialized host shutdown request. |

The bridges use Veloce event-source identity, not payload-supplied authorization.
The plugin must still be loaded/running in the current generation and its canonical
directory must be inside the selected integration's canonical plugin root.
Generic mode without an active integration cannot authorize these privileged
requests. Payloads do not expand fixed operations into arbitrary commands.
Real power remains separately gated by the opt-in host backend. The synthetic
audio policy translates rising edges into events; holding a button true does
not continuously repeat it. Vehicle power/battery timing policy lives in external
Lua rather than public feature code.

## Small synthetic example

Use this `vehicle.json` under `synthetic-demo/`:

```json
{"schemaVersion":1,"id":"synthetic-demo","displayName":"Synthetic Demo","capabilities":["vehicle.telemetry"]}
```

Under `plugins/telemetry/`, this is a reduced version of the working
[example decoder](../tool/vehicle_integrations/example-vehicle/plugins/can_decoder/main.lua):

```json
{"id":"dev.example.synthetic.telemetry","name":"Synthetic RPM","version":"1.0.0","apiVersion":"1","entrypoint":"main.lua","permissions":["can.read","vehicle.write"],"can":{"read":[{"bus":"comfort","ids":[640],"mask":2047}]}}
```

```lua
local veloce = require("veloce")
function on_load()
  veloce.can.subscribe({bus="comfort", ids={0x280}, mask=0x7FF}, function(frame)
    local d = frame.data
    if type(d) == "table" and type(d[1]) == "number" and type(d[2]) == "number" then
      veloce.vehicle.publish("engine.rpm", d[1] * 256 + d[2])
    end
  end)
end
```

`0x280` and two-byte big-endian RPM are synthetic. For a runnable scenario use
`tool/simulation/veloce_can_decoder.json` and simulation mode, or the already
configured vcan workflow in [setup](setup.md). This example needs no CAN writes,
real power, AA identity or UI extension permission. The full checked-in example
also contains `audio_policy`, `power_policy` and `battery_protection`; their
thresholds/delays are demonstration values, not vehicle safety recommendations.


## Read-only Argo host state v1

Argo adds the global Lua namespace **`argo_host`**, method **`snapshot()`**, with
zero arguments. Custom namespaces in the installed native runtime are globals:
use `argo_host.snapshot()`, **not** `require("veloce").argo_host`. Built-in logging
and events still use `require("veloce")`. This is an Argo host API, not a Veloce
vehicle signal or a portable built-in Veloce namespace.

Request **`argo.host.read.v1`** in the resource manifest. Argo enables the host
capability, but every call also requires that permission in the caller's active
Veloce generation. Undeclared reads fail; calls from unloaded/replaced generations
fail. No setters or transport commands are exposed. Defaults and existing Veloce
APIs keep their usual authorization.

The returned version-1 structured snapshot has these fields (Lua `nil` denotes
unknown; arrays are Lua sequence tables):

| Field | Meaning |
|---|---|
| `schemaVersion` | Integer `1`. |
| `epoch`, `revision` | Opaque Argo-runtime epoch and increasing cache revision. Compare as a pair; reset local observations when epoch changes. Never compare revisions across process restarts. |
| `updatedAtMs` | UTC Unix milliseconds when Argo's cached snapshot changed; not a phone clock or media playhead. |
| `available` | Projection backend availability; true is not a claim that a phone or track exists. |
| `projection.activeSessionId` | Existing selected projection ID, independent of media selection. |
| `projection.sessions[]` | Current nonfailed, nondisconnected sessions: `sessionId`, `deviceId`, `protocol`, `transport`, `state`, `deviceName`, nullable `manufacturer`, nullable `model`. Device name falls back to the existing generic device descriptor when the phone has not supplied one. |
| `media.activeSourceId` | Selected media-source ID, or nil. |
| `media.sources[]` | `sourceId`, `sourceKind`, `sessionId`, `deviceId`, `revision`, `updatedAtMs`, nullable `title`, `artist`, `album`, `application`, `positionMs`, `durationMs`, plus `playbackState`. |
| `phones[]` | Session/device IDs, nullable `batteryPercent`, `criticalBattery`, `charging`, `revision`, `updatedAtMs`. Revision/time describe the originating session-metadata snapshot, not a separate battery sample clock; time is nil before any metadata has arrived. |

Protocol values are `androidAuto`/`carPlay`, transport `usb`/`wifi`. Only wired AA
is implemented. Playback values are `unknown`, `stopped`, `playing`, `paused`,
`error`. Positions/durations are integer **milliseconds**, only reported values;
no playhead interpolation or periodic packet-frequency updates occur. The AA
source currently has no verified duration or device-model mapping, and charging
is always nil. A missing percentage is nil, never 0. Phone battery is unrelated
to vehicle battery. Source revision/time reflect the session metadata that last
changed the media source; phone-only updates need not advance the media cache.

Session IDs provide daemon epochs. IDs are opaque correlation values, not stable
hardware identifiers to store across reconnects. Metadata replacement clears an
old track's absent artist/album; status messages independently update playback/app/
position, and battery fields are independent optional patches. A changed track
clears its prior position until a new position is reported. A changed known app
clears the old app's track pending new metadata. Absent duration/model/charging
are not guessed. Disconnected/failed sessions disappear from host lists and their
live media/phone fields disappear. An unavailable backend returns `available=false`
and empty lists. State is never restored from saved settings/plugin storage.

For updates request the built-in **`events`** permission and subscribe to
**`argo.host.state.changed.v1` before the first snapshot read**. Events contain
only an empty invalidation object, at most four host notifications per second.
Veloce retains its bounded subscriber queue (64 pending, drop oldest) and removes
callbacks with the owning generation. Anyone with events permission can publish a
look-alike hint: never trust event data or use its claimed revision as host state.
Always re-read the protected snapshot and deduplicate by its epoch/revision. Read
immediately after subscribing/on reload, since events are not a history or an
initial snapshot. No private metadata is broadcast to events-only resources.

The [synthetic host observer](../tool/vehicle_integrations/example-vehicle/plugins/host_media)
requests only read/events/logging, reads on load, reacts to hints and deduplicates
its DEBUG summary. It makes no CAN calls and renders no plugin UI. Its DEBUG lines
are in Veloce's bounded log history; the optional `ARGO_HOST_STATE_DIAGNOSTICS=1`
forwards the newest observer DEBUG line at most every three seconds to the Argo
terminal, with quoting and a 1024-character bound. Enable this deliberately for
acceptance because such lines may include track/device text. Normal INFO logging
contains no track dump. [Run instructions](../tool/projection/README.md#host-metadata-and-lua-acceptance-ipc-v3)
load only this observer without selecting an example vehicle profile.
