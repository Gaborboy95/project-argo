# Example vehicle integration

[Schema, permissions and extension boundaries](../../docs/vehicle-integrations.md)
are documented separately. [Setup](../../docs/setup.md) defines the SDK/native
prerequisites. Use a fresh shell or clear inherited overrides as shown.

`example-vehicle/` is a synthetic bundle demonstrating Argo's public vehicle
integration layout:

```text
example-vehicle/
├── vehicle.json
└── plugins/
    ├── can_decoder/
    │   ├── manifest.json
    │   └── main.lua
    ├── audio_policy/
    │   ├── manifest.json
    │   └── main.lua
    ├── battery_protection/
    │   ├── manifest.json
    │   └── main.lua
    └── power_policy/
        ├── manifest.json
        └── main.lua
```

The profile manifest contains only application-facing identity and capability
metadata. Veloce owns validation and execution of the plugins below `plugins/`.

From the Project Argo repository root on Linux, run the example with:

```sh
cd "$HOME/dev/argo"
unset VELOCE_PLUGIN_DIR
ARGO_AUDIO_BACKEND=disabled ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0 \
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_MODE=simulation \
ARGO_VEHICLE_INTEGRATIONS_DIR="$(pwd)/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$(pwd)/tool/simulation/veloce_can_decoder.json" \
VELOCE_TRACE_VEHICLE_KEY=engine.rpm \
flutter run -d linux --no-enable-impeller
```

Do not set `VELOCE_PLUGIN_DIR` for that demonstration; setting it explicitly
is supported and intentionally overrides the selected bundle's plugin root.

The synthetic power policy owns its 1500 ms standby delay. This development
run exercises the policy while the disabled host backend guarantees that the
computer is not suspended:

```sh
cd "$HOME/dev/argo"
unset VELOCE_PLUGIN_DIR
ARGO_AUDIO_BACKEND=disabled ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0 \
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_MODE=simulation \
ARGO_VEHICLE_INTEGRATIONS_DIR="$(pwd)/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$(pwd)/tool/simulation/power_state_cycle.json" \
flutter run -d linux --no-enable-impeller
```

The battery policy likewise owns its example-only voltage thresholds,
hysteresis, and confirmation timer. See [the power runbook](../host_power/README.md) for the
safe fake-systemctl SocketCAN suspend/resume and poweroff procedure.

## Optional host media observer

The synthetic bundle also contains `plugins/host_media` (`dev.example.host_media`).
It uses `argo_host.snapshot()` plus invalidation events, not vehicle signals/CAN,
and requires `argo.host.read.v1`, `events` and `logging`. Custom host namespaces
are provided by Argo's runtime; a plain Veloce runtime needs the corresponding
host registration/catalog before this resource can load. It creates no UI.

To run **only** this observer with Argo's generic profile, follow the
[projection host-state workflow](../projection/README.md#host-metadata-and-lua-acceptance-ipc-v3).
It uses a separate mutable plugin root and leaves the other synthetic vehicle
policies unloaded. The [native Lua exercise](../../test/integrations/veloce/argo_host_state_bridge_test.dart)
uses fake state and proves reads/permissions/reload without a phone. API fields,
unknown/disconnected results and subscribe-before-read ordering are documented in
[plugin authoring](../../docs/vehicle-integrations.md#read-only-argo-host-state-v1).
