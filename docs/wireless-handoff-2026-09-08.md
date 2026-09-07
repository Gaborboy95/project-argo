# Project Argo wireless Android Auto handoff — 2026-09-08

## Current outcome

Worktree: `/home/phaeton/dev/argo`, LattePanda Mu. Wired baseline `7173f2e`
includes the working native audio clock fix. The operator confirmed the final
wireless release works (“It works!”), after previously confirming selectable
AP bands work. This is real-phone startup confirmation, not mock acceptance.
The complete original acceptance checklist has not been individually signed off.

Current matched release:
`/home/phaeton/dev/infotainment/bundle/argo-wireless-start-ipc5-20260908`.
Control IPC remains **5**. Use its application and daemon together. The source
launcher `tool/connectivity/run-release.sh` selects this release by default.
The staged manifest and SOURCE-CHANGES.patch describe the build before the
operator's success report; this handoff records the subsequent acceptance.

## Implemented architecture

- Shared BlueZ pairing/device state and NetworkManager networking in the existing
  Rust daemon, consumed by Settings. BlueZ owns bonds; NM owns profiles. Argo
  stores selections and AP band, not their secret databases.
- Explicit pairing/discovery, phone selection, Enable/Connect/Disconnect and
  2.4/5 GHz selection. Wireless starts disabled. Active attempts freeze settings.
- Dedicated volatile NM AP, random credentials, legal channel checks, DHCP/address
  readiness and narrowly scoped firewall helper. No silent station takeover.
- Authenticated selected-peer BlueZ RFCOMM bootstrap, WPP version/start/Wi-Fi
  exchange and TCP into the existing AA engine. USB/Wi-Fi session arbitration,
  bounded attempts/cancellation, cleanup and generic androidAuto/wifi models.
- Reuses existing video/audio/input/metadata/Home/Media rather than a second engine.
  GstSystemClock, PipeWire synchronization, bounded queues, daemon identity,
  frozen projection settings, PlatformViewLayer/native view ownership, local IHS
  descriptor fix, appearance preferences and shared media/Lua snapshot remain.

## Hardware debugging and final fixes

1. AP was hardcoded to 5 GHz. Added saved band selection through UI/preferences,
   IPC, NM `bg`/`a`, legal channel selection and the WPP frequency. Frequency
   parsing accepts this Mu's decimal `iw` output and distinguishes overlapping
   channel numbers in different bands.
2. Bluetooth trigger requested the phone's Hands-Free UUID `111e`. The paired
   phone advertises Audio Gateway `111f`, which is the remote service required
   by BlueZ ConnectProfile. Corrected it, using desktop PipeWire/WirePlumber,
   and stopped discarding failures. Added secret-free stage/error diagnostics.
3. Logs then confirmed authenticated RFCOMM, WPP 6.0/status 0, delivered Wi-Fi
   information, accepted StartResponse and an incoming TCP connection. Argo
   rejected TCP before a Bluetooth ConnectionStatus message.
4. Holding one TCP candidate while waiting for ConnectionStatus still stalled
   on both bands: the phone joined the AP but later reset RFCOMM.
5. Final admission requires credentials delivered over the authenticated selected
   Bluetooth link **and successful StartResponse**, then one in-subnet TCP peer
   on the interface-bound listener within the original deadline. ConnectionStatus
   is processed if sent but is not an AA-handshake prerequisite. Explicit protocol
   failures still stop setup/session; later RFCOMM closure need not stop Wi-Fi.
   Wi-Fi state becomes connected on TCP admission, not merely Bluetooth acceptance.
   The operator confirmed wireless AA works after this correction.

## Security and ownership limits

`ARGO_WIRELESS_DEVELOPMENT=1` remains required. TCP association relies on possession
of fresh AP credentials disclosed only through selected authenticated bootstrap;
it is not a cryptographic binding of TCP to the phone's Bluetooth identity.
A credential holder could race the intended phone. IP, name and completed TLS
are not proof of identity. Keep the gate and document this limitation.

Listener interface/subnet restrictions, attempt deadlines, second-peer rejection,
pairing recheck, cancellation, and TLS handshake-signature verification remain.
Do not loosen TLS or change working identity files to troubleshoot further.
No new HFP implementation or full call support was added.

## Verification and remaining acceptance

Latest daemon: **54 Rust tests**, Clippy with `-D warnings`, and release build pass.
Tests include both TCP/start orderings, incomplete bootstrap rejection, no required
ConnectionStatus before authorization, preserved AA bytes, deadlines, cancellation,
second-peer rejection, existing wired/session/media/IPC regressions.

Band/UI release: Flutter analyzer and full **225-test** suite passed, followed by
three connectivity widget/persistence tests after the saved-band regression was
added. Later connection corrections change only Rust and launch/documentation;
the previously built app and all native assets are copied unchanged and hash-checked.
No Flutter Engine, IHS or native projection-view rebuild was performed.

Phone verified: AP band selection and final wireless AA startup work, per operator.
Still record individually: USB data disconnected; picture/audio/input; metadata and
`argo_host.snapshot()` reporting androidAuto/wifi; AA Exit → Media → Home retaining
the same session; explicit Disconnect/Disable suppressing retries; deliberate new
connection; phone app internet access; wired AA with wireless disabled.

Last read-only networking observation: onboard `wlp2s0` available for projection;
a second adapter `wlxe0ad473015ce` carries P-Home/management. Ethernet `enp3s0` is
unavailable, so Ethernet-connected acceptance is not met. These names are discovery
results, not application constants. No live networking or processes were changed
by the agent during these connection fixes; the operator performed retries.

## Launch and rollback

Stop the old app and daemon first. From desktop terminals:

```bash
# Terminal 1
export ARGO_ANDROID_AUTO_CERT_FILE="$HOME/.config/argo-cert/argo.crt"
export ARGO_ANDROID_AUTO_KEY_FILE="$HOME/.config/argo-cert/argo.key"
export ARGO_WIRELESS_DEVELOPMENT=1
"$HOME/dev/argo/tool/connectivity/run-release.sh" daemon

# Terminal 2
"$HOME/dev/argo/tool/connectivity/run-release.sh" app
```

Select an idle projection interface and the paired phone, choose AP band, explicitly
Enable/Connect, and approve phone prompts. The root-owned mode-755 firewall helper
was already installed at `/usr/local/libexec/argo-projection-firewall`; no blanket
passwordless policy was added. Do not silently re-pair or restart system services.

Preserved bundles under `/home/phaeton/dev/infotainment/bundle/`:

- `argo-render-test`: original working LIVE wired bundle, not renderer diagnostic.
- `argo-wired-7173f2e-rollback`: wired rollback plus daemon, **IPC 4**.
- `argo-wireless-ipc5-20260907`: initial wireless implementation.
- `argo-wireless-bands-ipc5-20260908`: selectable bands.
- `argo-wireless-connect-ipc5-20260908`: correct Bluetooth profile and diagnostics.
- `argo-wireless-admission-ipc5-20260908`: superseded wait-for-join experiment.
- `argo-wireless-start-ipc5-20260908`: operator-confirmed working release.

Never mix IPC 4/5 binaries or overwrite loaded executables/libraries. Use the
existing wired workflow for IPC 4 rollback. Full references, permissions, cleanup
and historical acceptance details: [wireless runbook](wireless.md).
