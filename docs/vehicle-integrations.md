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
