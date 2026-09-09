# Media sources and Bluetooth music

Media displays projection and Bluetooth providers in one Now Playing page. Select
an entertainment source independently of Home/video visibility. AA Exit returns to
Media without selecting Bluetooth; Home resumes the existing AA native view and
session even while Bluetooth is the selected entertainment source.

## Setup and use

Linux Bluetooth reception uses the existing BlueZ bonds and the desktop
PipeWire/WirePlumber A2DP implementation. Argo does not register audio profiles or
implement codecs. BlueZ `MediaPlayer1` supplies track/status/position and
Play/Pause/Previous/Next. No AA certificate or enabled projection backend is needed
for pairing and Bluetooth music. NetworkManager is used only for projection APs;
its availability does not govern Bluetooth controls.

Before first use, explicitly opt in to Argo-owned reception routing. On the Mu,
provision the firewall grant and this per-account routing preference together:

```bash
: "${PROJECTION_INTERFACE:?Set the discovered projection Wi-Fi interface}"
sudo /usr/bin/python3 -I "$HOME/dev/argo/tool/connectivity/install-permissions.py" \
  --account "$USER" --interface "$PROJECTION_INTERFACE" --bluetooth-audio
```

Stop Argo and complete wireless cleanup before provisioning. Log out/in afterward
to refresh group membership and load the WirePlumber preference. The installer does
not restart services. The [wireless permission policy](wireless.md#permissions-and-helper-installation)
describes the exact root-owned helper/action/rule and rollback. Bluetooth-only
installations can opt in without any root firewall provisioning:

```bash
/usr/bin/python3 -I "$HOME/dev/argo/tool/audio/install-bluetooth-routing.py"
```

The per-account file is
`$HOME/.config/wireplumber/wireplumber.conf.d/80-argo-a2dp.conf`. It disables automatic
linking **only** for `api.bluez5.a2dp.source` receiver nodes. HFP/SCO, Bluetooth
headphone output profiles and non-Bluetooth audio are unaffected. Argo verifies the
receiver's effective `node.autoconnect=false` before routing. Existing external
routes are rejected, not duplicated or deleted. Complete logout/login before
connecting music; merely writing the file does not change an already-running
WirePlumber configuration.

1. Launch the matched daemon and application using [the normal workflow](setup.md#projection-launch).
2. Choose **Bluetooth adapter (all tasks)** under Settings → Devices & connectivity,
   then pair/confirm the actual phone. Pairing, wireless AA and music share this
   adapter. The saved hardware address survives `hciN` renumbering; an absent radio
   does not select a different card. Stop discovery and disconnect wireless/music
   before changing adapters. Bonds on the other radio remain in BlueZ.
3. In Media, select the paired music phone and press **Connect music**.
4. Select its Bluetooth entertainment source. Start playback with **play** or on
   the phone. Some phones instantiate their A2DP receiver only after first Play;
   selection can request that initial Play with AA entertainment already gated.
5. Use the offered playback controls. Unsupported remote commands report an error
   and are removed from that player's controls until a new player session appears.

For Bluetooth-only operation set `ARGO_PROJECTION_BACKEND=disabled` in both launch
terminals before starting the daemon/application. Identity exports can be unset;
the launcher no longer requires them for shared connectivity. Identity remains
mandatory on the daemon for actual AA projection. No boot-time music connection or
persistent auto-connect is enabled.

## Audibility, focus and lifecycle

Only one entertainment source is selected. Source selection waits for native
application of the audio change before confirming it in shared state. It first
pauses the previous Bluetooth player where supported and retires Argo's Bluetooth
links. A failed pause cannot leave music audible through those links. Before
Bluetooth routing is created, the AA engine acknowledges that its media channel
(channel 4) is gated. This gate multiplies the existing source gain and applies to
newly opened media streams too; navigation/speech/system channels keep their normal
focus and gain behavior. Projection has no implemented playback-command provider,
so its Media source does not expose fake transport buttons.

Bluetooth audio follows the host's selected default output, including subsequent
default-output changes. Select that output in the desktop sound controls; Argo's
existing volume/mute controls continue to operate on it. Receiver ports are matched
to output channel positions. Unsupported channel layouts fail visibly rather than
creating guessed links. At most two non-lingering `pw-link` clients own the mono/stereo
links. They run without privilege, carry an Argo ownership tag, and use a parent-death
signal. Cleanup waits for clients to exit and confirms link retirement. Uncertain
cleanup prevents replacement routing. No second loopback or media stream is added.
The existing AudioService supplies Bluetooth's entertainment gain and navigation/
system ducking; PCM remains inside PipeWire.

An explicit connection request allows at most three profile-connection attempts,
with bounded calls and backoff. Disconnect, Forget and application closure revoke
queued work immediately at the IPC boundary. A new explicit Connect establishes a
fresh request generation. Player removal invalidates its source/session; late
commands are rejected by source ID, connected-player checks and request generation.
Music player/link disappearance does not destroy a healthy Wi-Fi AA session. Reconnecting
Bluetooth does not replace projection, acquire its video view or force Home onscreen.

## Shared state and extensions

`CachedMediaSessionService.register()` returns a provider lease. A provider publishes
only its own source set with a monotonically increasing update revision. Replacing
or closing one provider does not erase another's sources. Stale leases/batches and
stale source revisions are rejected; source IDs cannot collide between providers.
Device identity, source ID and session epoch are distinct. Missing track fields and
unknown playback/position/duration remain unknown rather than being synthesized.

The existing `argo_host.snapshot()` includes Bluetooth in `media.sources` and uses
the same `argo.host.read.v1` permission. Entries include optional display name,
metadata and supported command names; Lua remains read-only. Root `available` can
be true for live Bluetooth media with projection unavailable. Projection and phone
subsections retain their own projection-specific availability. Neither pairing
credentials nor PCM enter control IPC or Lua.

A new media provider must own a lease, invalidate disconnected sessions, implement
its advertised commands, and provide a real audibility transition through the
selection coordinator. Adding a source label alone is insufficient. Reserved local
and CarPlay kinds do not imply an implemented provider.

## Verification and limits

Focused Dart/Rust tests cover provider isolation, stale targets, native gate
acknowledgement, routing plans, cancellation generations, Lua read permissions and
existing AA lifecycle/view ownership. `tool/audio/test-music-routing.py` checks link
activation and client-exit cleanup on an isolated PipeWire server with virtual
nodes; it does not exercise a phone or mutate host audio routing.

Phone acceptance remains required: Bluetooth-only music, same-phone simultaneous A2DP/AA availability, track metadata in Media
and Lua, all supported playback controls, switching between Bluetooth and AA without
overlap, navigation ducking, disconnect/reconnect, and routine wireless cleanup
after authorization caches expire. Phone AVRCP/A2DP interoperability and long-run
routing behavior are not established by the virtual-node tests. Artwork, local-file
playback, hands-free calls, contacts and phonebook remain unsupported.

## Rollback

Stop the application and daemon before selecting the preserved AA bundle. The
narrow firewall grant remains usable by the older wireless launcher/helper calls.
To restore the desktop's automatic incoming Bluetooth routing, remove only Argo's
unchanged opt-in file and log out/in:

```bash
/usr/bin/python3 -I "$HOME/dev/argo/tool/audio/install-bluetooth-routing.py" --uninstall
```

The script refuses to overwrite or remove a customized file. Firewall grant removal
is the separate administrator uninstall documented in the wireless guide; no bonds,
NM profiles, audio drivers or system services are removed.

References: [BlueZ MediaPlayer1](https://bluez.readthedocs.io/en/latest/media-api/#mediaplayer1-hierarchy)
and [WirePlumber Bluetooth configuration](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html).
