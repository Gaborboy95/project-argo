#!/usr/bin/env bash
# Isolated foreground CarPlay UI acceptance, using a freshly staged matched bundle.
set -euo pipefail
[[ $# == 1 && "$1" == /* && -d "$1/lib" ]] || { echo 'Usage: run-live-ui.sh /absolute/bundle' >&2; exit 2; }
[[ $EUID != 0 ]] || { echo 'Run as the desktop user.' >&2; exit 2; }
carplay_bundle=$1
carplay_ihs=${IHS_PREFIX:-"$HOME/dev/ivi-build/out/usr/local"}
carplay_state=$(mktemp -d /tmp/argo-carplay-ui.XXXXXX)
trap 'rm -rf -- "$carplay_state"' EXIT
mkdir "$carplay_state/plugins" "$carplay_state/integrations" "$carplay_state/storage"
for variable in ${!ARGO_@} ${!VELOCE_@}; do unset "$variable"; done
export ARGO_CARPLAY_ENABLED=1 ARGO_CARPLAY_DIAGNOSTICS=1 ARGO_PROJECTION_BACKEND=android-auto
export ARGO_MODE=production ARGO_HOST_POWER_BACKEND=disabled ARGO_AUDIO_BACKEND=pipewire
export ARGO_VEHICLE_PROFILE=generic ARGO_VEHICLE_INTEGRATIONS_DIR="$carplay_state/integrations"
export ARGO_SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/project-argo/settings.json"
export ARGO_STARTUP_CONNECTIONS=
export VELOCE_PLUGIN_DIR="$carplay_state/plugins" VELOCE_PLUGIN_STORAGE="$carplay_state/storage"
export VELOCE_LUA_LIBRARY="$carplay_bundle/lib/libveloce_lua_native.so"
export LD_LIBRARY_PATH="$carplay_ihs/lib:$carplay_bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$carplay_ihs/bin/homescreen" -b "$carplay_bundle" --backend wayland-egl --fullscreen
