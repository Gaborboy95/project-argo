# Argo audio development checks

Argo controls the system output through WirePlumber's `wpctl`; PCM remains in
PipeWire. The default backend is `disabled`, so development and tests cannot
change host audio unless `ARGO_AUDIO_BACKEND=pipewire` is explicitly selected.

The current `wpctl` backend implements default-sink volume and mute. It reports
balance, fader, EQ, output selection, and per-source routing unavailable because
`wpctl` does not expose a portable mutation API for those graph operations.
Argo's backend-neutral policy and fake backend implement and test these features;
a production-configured PipeWire filter graph can add them without changing UI
or vehicle integrations.

## Linux desktop / VM

Verify PipeWire and WirePlumber first:

```bash
systemctl --user status pipewire wireplumber
wpctl get-volume @DEFAULT_AUDIO_SINK@
```

Run Argo with the example external integration and no CAN input:

```bash
cd "$HOME/dev/argo"
unset VELOCE_PLUGIN_DIR
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0 \
ARGO_MODE=simulation \
ARGO_VEHICLE_INTEGRATIONS_DIR="$PWD/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$PWD/tool/simulation/audio_controls.json" \
ARGO_AUDIO_BACKEND=pipewire \
flutter run -d linux --no-enable-impeller
```

Open Settings. Moving Volume or changing Mute must change the value reported by:

```bash
wpctl get-volume @DEFAULT_AUDIO_SINK@
```

The scenario performs two normalized volume-up button presses and one mute
press. No CAN frame is involved. Expected path:

```text
VehicleDataBus normalized boolean
  -> dev.example.vehicle.audio_policy rising edge
  -> audio.command.*
  -> VehicleAudioControlBridge
  -> AudioService
  -> wpctl / PipeWire default sink
```

Expected diagnostics include accepted fixed command topics from
`dev.example.vehicle.audio_policy`. Holding `true` does not repeat; another
command is emitted only after `false -> true`.

## ivi-homescreen / emb

Follow the shared [bundle build/staging workflow](../projection/README.md#build-the-native-view-and-argo-bundle)
first, stopping the previous homescreen before replacing libraries. Then launch
with explicit paths and disabled host power/projection:

```bash
set -o pipefail
export ARGO="$HOME/dev/argo"
export FLUTTER_WORKSPACE="${FLUTTER_WORKSPACE:-$HOME/dev/infotainment}"
export IHS_PREFIX="${IHS_PREFIX:-$HOME/dev/ivi-build/out/usr/local}"
source "$FLUTTER_WORKSPACE/setup_env.sh"
export BUNDLE="$FLUTTER_WORKSPACE/bundle/argo-release-x86_64"
export LD_LIBRARY_PATH="$IHS_PREFIX/lib:$BUNDLE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset VELOCE_PLUGIN_DIR
ARGO_MODE=simulation \
ARGO_HOST_POWER_BACKEND=disabled \
ARGO_PROJECTION_BACKEND=disabled ARGO_PROJECTION_RENDER_TEST=0 \
ARGO_VEHICLE_INTEGRATIONS_DIR="$ARGO/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$ARGO/tool/simulation/audio_controls.json" \
ARGO_AUDIO_BACKEND=pipewire \
VELOCE_LUA_LIBRARY="$BUNDLE/lib/libveloce_lua_native.so" \
"$IHS_PREFIX/bin/homescreen" -b "$BUNDLE" --backend wayland-egl --width=1280 --height=720 \
  2>&1 | tee /tmp/argo-audio-check.log
```

Repeat the `wpctl get-volume` check above. AA already has native daemon playback;
it is separate from system master control. Argo has no general local-media player
here, and this workflow does not require adding an audioplayers plugin to IHS.

Balance/fader and EQ are never silently applied by this initial production
backend. Their controls stay disabled until an installed PipeWire topology/DSP
backend advertises those capabilities.
