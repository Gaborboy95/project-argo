#!/usr/bin/env bash
# Run only a staged, matching pair; this script does not build or provision.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run Argo as your desktop user.' >&2; exit 1; }
argo_bundle=${ARGO_WIRELESS_BUNDLE:-"$HOME/dev/infotainment/bundle/argo-wireless-ipc5-20260907"}
argo_ihs=${IHS_PREFIX:-"$HOME/dev/ivi-build/out/usr/local"}
: "${XDG_RUNTIME_DIR:?Launch from the logged-in desktop environment}"
export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/argo-wireless-ipc5/projection.sock"
export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/argo-wireless-ipc5/video.sock"
export ARGO_MODE=production ARGO_PROJECTION_BACKEND=android-auto
unset ARGO_PROJECTION_RENDER_TEST
case ${1:-} in
  daemon)
    for argo_process in /proc/[0-9]*/exe; do
      argo_exe=$(readlink "$argo_process" 2>/dev/null || true)
      if [[ ${argo_exe##*/} == argo-projectiond ]]; then
        echo 'Stop the existing projection daemon before starting the matched release.' >&2; exit 1
      fi
    done
    : "${ARGO_ANDROID_AUTO_CERT_FILE:?Set the same daemon-owned certificate path used for working wired AA}"
    : "${ARGO_ANDROID_AUTO_KEY_FILE:?Set the same daemon-owned key path used for working wired AA}"
    exec "$argo_bundle/bin/argo-projectiond"
    ;;
  app)
    if pgrep -u "$UID" -x homescreen >/dev/null; then
      echo 'Stop the previous homescreen before launching this bundle.' >&2; exit 1
    fi
    [[ -S "$ARGO_PROJECTION_SOCKET" ]] || { echo 'Start this bundle’s daemon first.' >&2; exit 1; }
    export ARGO_PROJECTION_VIEW_LIBRARY="$argo_bundle/lib/libargo_projection_view.so"
    export VELOCE_LUA_LIBRARY="$argo_bundle/lib/libveloce_lua_native.so"
    export LD_LIBRARY_PATH="$argo_ihs/lib:$argo_bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    exec "$argo_ihs/bin/homescreen" -b "$argo_bundle" --backend wayland-egl --width=1280 --height=720
    ;;
  *) echo 'Usage: run-release.sh daemon|app (see docs/wireless.md)' >&2; exit 2;;
esac
