# Compatibility and limitations

## Implemented functionality

| Area | Current behavior |
|---|---|
| Application | Retained module navigation, typed persistent settings, diagnostics and lifecycle cleanup. |
| Voice/calls | PipeWire HFP call control and owned duplex routes; shared selected microphone, mute and AA PCM capture. Explicit PBAP contacts/recent-call import. Physical ADC and PBAP phone acceptance pending. |
| Appearance | Material 3 light/dark/system modes and seed color; shared native-page background. |
| Projection | Wired AOAP/USB and wireless Bluetooth bootstrap/TCP into the same Android Auto engine. |
| Media | Native video/PCM, touch, AA and Bluetooth metadata, bounded AA artwork and optional BlueZ BIP covers, Bluetooth playback controls, provider-owned source selection and read-only Lua state. |
| Presentation | AA Exit returns to Media without ending the session; Home requests video focus on that same session. |
| Connectivity | Shared BlueZ pairing, selected-phone admission, NM-owned AP, selectable 2.4/5 GHz band, bounded retries and explicit stop. |
| Vehicle | Generic/external profiles, synthetic scenarios, normalized signals and opt-in Linux SocketCAN. |
| Host audio/power | Default-sink volume/mute via wpctl; policy and capability reporting; opt-in systemd power backend. |

## Tested configurations

Wireless Android Auto startup and AP band selection have been tested on the
LattePanda Mu running Debian 13, KDE Wayland, BlueZ 5.82 and NetworkManager 1.52.1,
with the MediaTek MT7922/mt7921e radio. The phone completed authenticated RFCOMM,
WPP 6.0 negotiation and projection startup. Device/interface names are discovered;
they are not fixed application constants.

Wired Android Auto picture/audio and native renderer output have been exercised
on Linux, including Ubuntu 24.04 VMware with Wayland/EGL IHS and GStreamer 1.24.2.
Wired operation on the Mu uses the native GstSystemClock audio selection. Wired
metadata has reached the Lua host snapshot. These results do not establish every
phone/OS combination or all optional metadata fields.

The local Wayland-EGL IHS descriptor correction has bounded renderer stability
coverage. Its exact source requirement is in the
[build reference](../tool/projection/README.md#ihs-base-and-local-patch).
A short renderer run is not long-term phone/media endurance validation.

## Experimental and untested behavior

Bluetooth music has automated provider/control/gate coverage and an isolated
PipeWire link-lifetime check. The inspected reference desktop uses BlueZ 5.82,
PipeWire 1.4.2 and WirePlumber 0.5.8. Actual phone reception, command support,
AA/Bluetooth audibility switching and focus require hardware acceptance. The
installation-time polkit grant also requires deployed verification after cached
authorizations expire; source validation tests do not establish installed policy.
AA artwork, Bluetooth BIP artwork and network-credential reuse need phone
verification. No new startup-latency result is established by automated tests.
BlueZ experimental artwork APIs are disabled in the inspected installation.
See [Media sources](media.md) for the opt-in and limitations.


Wireless availability is detected automatically; admission remains experimental. See the canonical
[security policy](wireless.md#security-and-admission) for its identity-binding
limitation and the [network policy](wireless.md#projection-network) for NAT and
firewall behavior. External AA identity is required; format and ownership are in
[configuration](configuration.md#projection).

Established wireless AA has survived Exit → Media beyond the setup deadline on the
Mu, and Home has resumed that same session. The wireless receive-liveness watchdog
has controlled-time regression coverage, including a real loopback TCP peer that
keeps draining requests without replying or closing, heartbeat-only suspended
operation, and cancellation/replacement. Hardware silent-loss detection and cleanup
latency remain unverified. The corrected Exit input path and multi-touch gestures have phone coverage. Reconnect endurance, phone app
internet access and fresh wired regression remain hardware acceptance work. Management Ethernet was unavailable
in the latest wireless setup; a separate Wi-Fi adapter carried management traffic.
Do not infer Ethernet-connected acceptance from projection success.

Hardware-dependent gaps include DRM/KMS fallback retirement, zero-copy decode,
SHM hosts without real buffer grants, keyboard-leave gesture cancellation and
broad GPU/phone interoperability. Windows/macOS are not validated native AA hosts;
the stock Flutter GTK runner lacks the IHS platform-view contract.

## Unsupported features

- Persistent contacts/history storage, SIM selection and conference control.
- CarPlay and a general local-media player.
- Wallpaper/shaders and automatic vehicle day/night appearance policy.
- Argo-rendered Lua UI extension registries; host-state reads do not create UI.
- Portable PipeWire balance/fader/EQ/output-routing mutations in the wpctl backend.
- Vehicle-specific protocols, production power policy, boot-time wireless
  auto-connect or an unlimited connection supervisor.

AA microphone capture is implemented; physical ADC mixing and HFP duplex audio are
not yet hardware-verified. See [voice input](media.md#shared-microphone-and-usb-adc). Declared vehicle
capabilities do not install hardware backends. CAN reception cannot continue while
host suspend quiesces its transport; physical wake is a platform responsibility.
