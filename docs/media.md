# Media, Bluetooth calls and voice input

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

1. Launch the matched daemon and application using [the normal workflow](setup.md#graphical-session-deployment).
2. Choose **Bluetooth adapter (all tasks)** under Settings → Devices,
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

## Artwork and output volume

AA's media-playback metadata (`0x8003`) supplies embedded album art in field 4 and
optional duration in seconds in field 6. Argo uses both. Title/artist/album/art
follow track replacement; a missing image clears the prior track's cover. Idle
Media and hidden projection retain the current session's metadata.

Bluetooth covers use BlueZ's optional experimental BIP API: MediaPlayer1.ObexPort,
a user-session `org.bluez.obex` client with target `bip-avrcp`, the current Track
ImgHandle and Image1.GetThumbnail. One cancellable transfer is permitted per track,
with a 12-second bound. Track/player changes invalidate the transfer and cached
image. Missing support produces a concise artwork status; music and AVRCP controls
continue normally. No alternate Bluetooth audio profile is registered.

The reference BlueZ 5.82 installation has OBEX running but does not enable
experimental bluetoothd APIs. Bluetooth covers therefore require administrator
provisioning of experimental BlueZ/OBEX BIP support and a phone offering AVRCP cover
art before hardware verification. Argo does not edit bluetoothd configuration or
restart services to enable it. Merely having AVRCP track text does not establish
cover-art support. [LIVI's Bluetooth bridge](https://github.com/f-io/LIVI/blob/b8651d795e5f84871d7454ce25e6ff6fb79e03d5/native/livi-helperd/crates/livi-runtime/src/bt.rs)
exposes empty MPRIS metadata; its
CarPlay file-transfer artwork is not an A2DP artwork mechanism.

Artwork accepts bounded PNG/JPEG headers (at most 1 MiB encoded and 2048 pixels per
side); the UI handles decode failures with a music placeholder. The daemon owns
private runtime cache files, retiring them with their last metadata owner. A crash
may leave files until the runtime directory is cleared at logout. IPC v6 carries
only an opaque local cache reference, never embedded image bytes or phone URLs.
The UI rejects references outside the private cache pattern. Lua receives only
`hasArtwork`, not filesystem paths, images or retrieval permissions.

The release launcher defaults to `ARGO_AUDIO_BACKEND=pipewire`; explicit `disabled`
is still respected. Settings → Sound controls the actual default output's volume
and mute. Volume follows the drag and commits once on release. Host failures are
visible. Balance/fader/EQ appear only when the backend implements them.

References: [LIVI AA metadata at b8651d7](https://github.com/f-io/LIVI/blob/b8651d795e5f84871d7454ce25e6ff6fb79e03d5/src/main/services/projection/driver/aa/stack/channels/MediaInfoChannel.ts),
[BlueZ 5.82 MediaPlayer](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.MediaPlayer.rst),
[OBEX Image](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.obex.Image.rst) and
[OBEX Client](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.obex.Client.rst).

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
routing behavior are not established by the virtual-node tests. AA covers/duration and
Bluetooth BIP transfers still require phone verification. Local-file playback remains unsupported. HFP and microphone acceptance limits are described below.

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


## Bluetooth calls

The Calls page uses the shared paired-device list and selected Bluetooth adapter.
Press **Connect calls** for the chosen paired phone, then use **Call**, **Answer**
or **Hang up / reject**. Call controls wait for the native operation result;
unsupported phone commands remain errors. Dial/answer/hangup are never retried
automatically. Dial accepts the returned D-Bus call object path. PipeWire 1.4.2's
implementation returns this path even though its introspection XML omits the output
argument; interpreting it as an empty reply incorrectly reports failure after dialing.
If a command times out, check the phone before repeating it. Argo logs operation
IDs, actions and acceptance status, without dialed numbers or contact names.

The installed `Dial(number)` API exposes no SIM inventory or selection argument.
Single-SIM and dual-SIM phones use their own calling-subscription policy. Configure
the default calling SIM on the phone, or respond to any phone-side selection prompt.
Argo neither guesses a SIM from call objects nor retries dialing on another SIM.
There is no conference management or emergency-calling assurance.

The native controller uses the session-bus service `org.pipewire.Telephony`,
provided by WirePlumber's PipeWire Bluetooth backend. `AudioGateway1`, `Call1` and
`AudioGatewayTransport1` supply dialing, call state, answer/hangup and SCO
activation. This API is available in the inspected PipeWire 1.4.2/WirePlumber 0.5.8
installation. Argo does not run oFono, register a competing HFP profile, or change
system Bluetooth roles. Pairing and calling do not need AA identity or a live
projection session. NetworkManager is outside the call path.

HFP connection setup/recovery permits at most three profile requests per explicit
Connect, with increasing five-second backoff. Disconnect, Forget and app closure
revoke that request. A new Connect resets the budget. An unavailable phone does
not retain live caller state. Calls are scoped to the selected adapter/device,
PipeWire service owner and an object lifetime revision; ambiguous links through
another adapter are rejected. ObjectManager removals invalidate old call targets.

Argo activates the existing SCO transport and creates two owned `pw-loopback`
processes: phone receive → default host output, selected microphone → phone
transmit. PipeWire's audio-gateway profile can expose A2DP and SCO together; Argo
does not force profile changes. Existing SCO links owned by another audio client
are a visible conflict, not permission to add duplicate playback. Route readiness
requires observed PipeWire links. Route setup has three attempts; **Retry call
audio** is available after correcting a missing input or route conflict.

Calls acquire communication focus in the existing AudioService. This applies the
normal ducking policy without selecting Bluetooth entertainment, disconnecting AA
or rebuilding its view. The wpctl backend currently uses the desktop default
output; change that output through desktop audio settings. Stream processes are
terminated and reaped before releasing microphone ownership. Uncertain microphone
cleanup fails closed until daemon restart.

## Contacts and recent calls

After **Connect calls**, use **Import contacts** or **Import recent calls** on
Calls. Approve Bluetooth contact/call-history sharing on the phone if prompted.
Argo uses the installed BlueZ OBEX session-bus service (`org.bluez.obex`), its
`PhonebookAccess1` PBAP interface, and the same selected adapter and paired phone
as call control. It requests the phone's internal address book (`int/pb`) or
combined history (`int/cch`). SIM phonebooks and SIM attribution are not exposed.
Phone support and sharing permissions determine availability; HFP call control
does not require PBAP to succeed.

Imports are explicit, with no background synchronization or automatic retry.
Pages contain at most 40 records, browsable through offset 1000. Search filters the
current page. Only vCard 3.0 names and up to three unambiguous telephone numbers
per record are retained; photos, extensions, encoded fields and non-UTF-8 cards
are unsupported. Selecting a number fills the dial field; **Call** is separate.
Recent calls retain the phone-provided order. Argo does not infer timestamps,
direction or SIM identity, and does not maintain its own historical call log.

Each import has a 35-second bound. **Cancel import**, **Clear**, Disconnect,
Forget, loss of the call connection and Quit clear the memory cache and stop owned
OBEX work. A private runtime directory holds the downloaded page only while it is
processed; normal completion and cancellation remove it. Downloads are limited
to 256 KiB per page and serialized entries to 16 KiB inside the existing bounded
IPC6 control snapshot. Contacts are not published to Lua or diagnostic logs.
Daemon crashes can leave a private temporary directory under `$XDG_RUNTIME_DIR`;
it contains personal data and can be removed after the daemon has stopped.
Unconfirmed OBEX cleanup blocks further imports until daemon restart.

PBAP interoperability and phone-side permission behavior still require hardware
acceptance. A previous phone call may appear after importing recent calls if the
phone shares its history; terminal diagnostics do not reconstruct that history.

## Shared microphone and USB ADC

Attach the USB ADC and select its source, or its prepared mix source, under
**Settings → Sound → Voice input** or on **Calls**. The preferred PipeWire
`node.name` is saved as `connectivity.microphoneInput`. A missing preferred input
never silently falls back to another microphone. With no saved selection, a sole
available non-Bluetooth input can be selected automatically. Microphone mute is
session-local and applies to both providers. Input changes require capture to stop.

The AA microphone descriptor retains `available_while_in_call=true`, matching the
established discovery contract and the pinned LIVI reference. This protocol
advertisement does not grant concurrent access to the host input: capture requests
still require the selected input and the shared native lease.
A single native lease prevents simultaneous AA/HFP capture. For multichannel ADCs,
PipeWire performs mono conversion for the selected source. Choose a dedicated mix
node when channel weights, AUX channel mapping or pre-processing are needed;
Argo does not configure the ADC or infer its wiring. Verify the intended channels
on the real ADC before use. Argo does not add acoustic echo cancellation, noise
suppression or beamforming. A prepared PipeWire input may provide that processing.

AA uses channel 9, 16 kHz mono signed 16-bit PCM and 20 ms frames. An open request
succeeds only after capture produces a complete frame. The native session sends
OPEN response/START and encrypted audio through the existing serialized AA
transport. A bounded credit window follows the phone's acknowledgements, drops
live capture frames when no credit exists, and closes stalled capture after five
seconds without acknowledgements. Partial reads survive cancellation; missing PCM
has a separate two-second bound. STOP closes capture, without ending projection.
Mute sends silence. USB and wireless use the same path; media is never carried in
control IPC or exposed to Lua. The microphone is advertised as unavailable while
an HFP call owns it.

For HFP, mute removes the owned microphone transmit route; receive audio remains
available after routing updates. Disconnect/Forget, phone/player disappearance
and Quit stop owned capture. Neither AA Exit nor hiding video is a microphone
or call disconnect command.

Physical ADC capture, channel mix, echo behavior, HFP codec interoperability and
full-duplex audio need hardware acceptance. The inspected Mu had no input source
attached. Automated PCM and private D-Bus tests do not establish microphone levels,
phone speech recognition or actual call audio.

Protocol references: BlueZ 5.82 [PBAP API](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.obex.PhonebookAccess.rst)
and [OBEX session ownership](https://github.com/bluez/bluez/blob/5.82/obexd/client/session.c); PipeWire [telephony implementation](https://github.com/PipeWire/pipewire/blob/1.4.2/spa/plugins/bluez5/telephony.c)
and [audio-gateway nodes](https://github.com/PipeWire/pipewire/blob/1.4.2/spa/plugins/bluez5/bluez5-device.c),
revision `1.4.2`; LIVI microphone channel/protobuf definitions at revision
`b8651d795e5f84871d7454ce25e6ff6fb79e03d5`. Implementations and credentials are not vendored.

## Android Auto video codecs

H.264 is the default offer. Set `ARGO_ANDROID_AUTO_HEVC=1` in the daemon terminal
before launch to additionally offer HEVC/H.265. H.264 remains configuration index 0
and HEVC index 1; Argo validates the phone's codec and configuration selection and
reports it in the existing IPC6 video descriptor. The selected codec is fixed for the AA session, including stream stops and
presentation suspension. A different codec requires a new connection. This does not implement automatic reconnection in a different
codec after rejection; disable the offer and start a new explicit connection to
return to the H.264-only path.

Use the matching native-view library from the release: its GStreamer `parsebin`
identifies H.264/H.265 before `decodebin`, followed by the existing bounded BGRx
presentation path. The daemon checks for an H.265 parser and known decoder factory
before advertising HEVC. Factory availability is not proof that every profile,
resolution or driver works. On the reference Mu, synthetic 1280×720/30 H.265 Main
and H.264 streams decoded through this path; H.265 selected Intel `vah265dec`.
Phone-selected HEVC and on-screen HEVC projection still require acceptance.

The video feed caches bounded parameter sets: SPS/PPS for H.264 and VPS/SPS/PPS
for HEVC, replayed in order to a recreated native consumer. Cache and codec state
are owned by one session and discarded before a replacement. Presentation, native
view identity, audio clocks and audio formats are unchanged. HEVC is not a promise
of 1080p60 interoperability or zero-copy presentation.

Codec fields/configuration-index behavior follow the pinned LIVI
[discovery builder](https://github.com/f-io/LIVI/blob/b8651d795e5f84871d7454ce25e6ff6fb79e03d5/src/main/services/projection/driver/aa/stack/session/ServiceDiscoveryBuilder.ts)
and [session handler](https://github.com/f-io/LIVI/blob/b8651d795e5f84871d7454ce25e6ff6fb79e03d5/src/main/services/projection/driver/aa/stack/session/Session.ts).

AA wire negotiation defaults to 1.1 for compatibility. The optional
`ARGO_ANDROID_AUTO_PROTOCOL_VERSION=1.7` requests the publicly referenced newer
wire version; the daemon logs the phone's returned major/minor. A higher protocol
number does not itself add channels or UI features. Phone-app and AndroidX Car App
SDK release numbers use separate version schemes. Wire versions beyond 1.7 are
not implemented from unverified assumptions.

## Dashboard strip and volume

The dock's Media shortcut shows/hides a reserved thin strip containing the selected
MediaSessionService source's artwork, title/artist and supported playback commands.
Unsupported commands are omitted; unknown artwork/metadata stays unavailable. Use
Apps → Media for source selection and the full Now Playing page. The strip toggle
is independent of AA Exit, which navigates to Media while retaining the session.
Selecting Home resumes that session; showing a strip or climate sheet does not
change the selected entertainment source or projection focus.

Tap the dock volume control to mute, or drag vertically from its current level for
live relative adjustment. Its floating indicator disappears on release/cancel;
changes already heard are retained. Accessibility increase/decrease adjusts five
percentage points. AudioService and the selected host output own volume capability;
the control is disabled when that backend is unavailable.
