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

Build a release bundle with the current `emb` CLI, then run it through the
production embedder rather than Flutter's GTK runner:

```bash
cd "$FLUTTER_WORKSPACE"
emb bundle \
  --app-path "$HOME/dev/argo" \
  --arch x86_64 \
  --build

cd "$HOME/dev/argo"
ARGO_MODE=simulation \
ARGO_VEHICLE_INTEGRATIONS_DIR="$PWD/tool/vehicle_integrations" \
ARGO_VEHICLE_PROFILE=example-vehicle \
ARGO_SIMULATION_SCENARIO="$PWD/tool/simulation/audio_controls.json" \
ARGO_AUDIO_BACKEND=pipewire \
ivi-homescreen -b "$FLUTTER_WORKSPACE/bundle/argo-release-x86_64" \
  --w=1280 --h=720
```

If the local bundle name differs, use the directory printed by `emb bundle`.
Repeat the `wpctl get-volume` check above. Argo does not yet add a media-player
dependency; future GStreamer playback should use the opt-in
`BUILD_PLUGIN_AUDIOPLAYERS_LINUX` integration supplied by
`ivi-homescreen-plugins`, independently from this system master-control path.

Balance/fader and EQ are never silently applied by this initial production
backend. Their controls stay disabled until an installed PipeWire topology/DSP
backend advertises those capabilities.
