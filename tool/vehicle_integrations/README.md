# Example vehicle integration

`example-vehicle/` is a synthetic bundle demonstrating Argo's public vehicle
integration layout:

```text
example-vehicle/
├── vehicle.json
└── plugins/
    ├── can_decoder/
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
ARGO_MODE=simulation \
ARGO_VEHICLE_INTEGRATIONS_DIR="$(pwd)/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$(pwd)/tool/simulation/power_state_cycle.json" \
ARGO_HOST_POWER_BACKEND=disabled \
flutter run -d linux --no-enable-impeller
```

The battery policy likewise owns its example-only voltage thresholds,
hysteresis, and confirmation timer. See `tool/host_power/README.md` for the
safe fake-systemctl SocketCAN suspend/resume and poweroff procedure.
