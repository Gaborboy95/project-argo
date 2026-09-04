# Safe host-power and vcan verification

The example integration contains synthetic protocols and policies only. Its
11.5 V low threshold, 12.0 V recovery threshold, and 2000 ms confirmation
delay are demonstration values, not production battery recommendations.

Argo cannot receive CAN while the host CPU is suspended and its transport is
quiesced. A physical wake source is platform responsibility (for example a
GPIO, MCU/power controller, USB remote wake, ignition input, or another
platform-specific source). After `systemctl suspend` returns, Argo recreates
only the underlying SocketCAN transport; Flutter, Veloce, Lua generations,
logical CAN subscriptions, and the current UI session remain alive.

## Fake systemctl

Install the repository fake ahead of the real `systemctl` in this process's
`PATH`. It records the requested operation and never changes host power:

```sh
mkdir -p /tmp/argo-fake-systemctl
cp tool/host_power/fake-systemctl /tmp/argo-fake-systemctl/systemctl
chmod +x /tmp/argo-fake-systemctl/systemctl
: > /tmp/argo-systemctl.log
```

With an already configured `vcan0`, launch Argo from the repository root:

```sh
PATH="/tmp/argo-fake-systemctl:$PATH" \
ARGO_FAKE_SYSTEMCTL_LOG=/tmp/argo-systemctl.log \
ARGO_MODE=production \
ARGO_VEHICLE_INTEGRATIONS_DIR="$(pwd)/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_HOST_POWER_BACKEND=linux-systemd \
VELOCE_CAN_INPUT=socketcan \
VELOCE_SOCKETCAN_INTERFACE=vcan0 \
VELOCE_CAN_BUS=comfort \
VELOCE_CAN_WRITE_ENABLED=false \
flutter run -d linux --no-enable-impeller
```

In another terminal, verify suspend recovery first:

```sh
cansend vcan0 500#02
cansend vcan0 280#0BB8
cansend vcan0 500#01
sleep 2
cansend vcan0 500#02
cansend vcan0 280#0DAC
```

The UI should first show 3000 RPM, then—after the fake suspend and transport
recreation—3500 RPM. Diagnostics should include CAN transport quiescing,
quiesced, resuming, and resumed, together with host suspend requested and
completed:

```text
Host suspend requested by plugin dev.example.vehicle.power_policy.
CAN transport quiescing.
CAN transport quiesced.
Host suspend requested.
Host suspend completed.
CAN transport resuming.
CAN transport resumed.
```

`/tmp/argo-systemctl.log` should contain:

```text
suspend
```

Keep the example vehicle awake and run the battery/poweroff check last because
a successfully accepted poweroff intentionally leaves transport quiesced:

```sh
cansend vcan0 500#02
cansend vcan0 501#2C88
sleep 3
```

`2C88` is the synthetic big-endian representation of 11400 mV. Diagnostics
should show the authorized shutdown request, transport quiesce, host shutdown
request, and completion:

```text
Host shutdown requested by plugin dev.example.vehicle.battery_protection.
CAN transport quiescing.
CAN transport quiesced.
Host shutdown requested.
Host shutdown completed.
```

The final command log should be exactly:

```text
suspend
poweroff
```
