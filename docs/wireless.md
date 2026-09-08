# Wireless Android Auto

Wireless projection uses the same Android Auto session, video, PCM audio, input,
metadata and Home/Media services as USB. Bluetooth bootstraps a phone onto an
Argo-owned NetworkManager AP; projection then runs over TCP. Read
[setup](setup.md) for the matched application/daemon launch and
[status](status.md) for tested configurations.

## Pairing and connection

1. Open Settings → Devices & connectivity. Select the Bluetooth adapter and an
   idle projection Wi-Fi interface when discovery is ambiguous.
2. Start the bounded discovery window, open the phone's Bluetooth settings and
   pair the intended device. Confirm matching device-scoped passkeys; reject
   unexpected requests. Prompts expire. Existing BlueZ bonds can be reused.
3. Select the paired phone and AP band. Disconnect USB data for wireless testing.
4. Enable wireless, then Connect. Approve any required phone or desktop permission
   prompts. AP readiness, Bluetooth bootstrap, TCP and streaming are distinct stages.
5. Use Disconnect or Disable to stop the connection request and its retries.
   Forget revokes the device selection and removes its BlueZ bond.

Wireless is disabled at each launch. The development gate permits enablement but
neither starts an AP nor connects a phone. Saved adapter/interface/phone/band choices
are restored without connecting. Changed choices remain pending for the next explicit
connection; each current attempt and its retries keep the frozen selection.

Argo registers one non-default BlueZ pairing agent for Argo-initiated pairing.
Incoming desktop pairing continues through the desktop agent. Argo does not replace
the default agent, auto-accept passkeys, set blanket trust or authorize unrelated
profiles. Generic pairing/readiness works without an AA certificate or live session.

## Projection network

NetworkManager owns the dedicated `Argo Projection (<interface>)` profile. It is
volatile, bound to the selected interface, non-autoconnecting and tied to the
attempt's D-Bus client lifetime. No hostapd process competes for the interface.
An existing station connection must be released explicitly before Connect; Argo
will not take it over. A separate management connection is required if that station
was the only management path. Concurrent AP+station operation is not required.

Band selection is explicit; there is no automatic cross-band fallback. Argo checks
AP/band capabilities and the selected phy's current `iw` channel flags. For 2.4 GHz,
it prefers channels 1/6/11 then other permitted channels in 1–13. For 5 GHz, it uses
149/153/157/161/165. Disabled, NO-IR, radar/DFS, indoor-only and prohibited 20 MHz
channels are excluded. This deliberately conservative policy does not cover all
legally possible deployments. Regulatory country, power, drivers and firmware are
not changed. The active AP configuration frequency is shown separately from the
saved band choice; `iw dev` can independently inspect actual radio configuration.

Each attempt generates fresh WPA2/RSN/CCMP credentials and a non-overlapping private
IPv4 /24. Credentials are sent only over selected authenticated bootstrap, never
through ordinary IPC, logs, settings or Veloce. Readiness requires NM activation,
the assigned AP address and its DHCP service, not merely an activation request.

NM IPv4 shared mode runs DHCP/DNS and adds forwarding/masquerading through the host
uplink. This is NAT, not an Ethernet bridge. IPv6 is disabled and `never-default`
protects management route selection. Joining the AP does not guarantee phone app
internet access; test that separately.

Before activation, a fixed-purpose helper installs an input guard on only the
projection interface, permitting established traffic, DHCP, DNS and projection TCP.
Other incoming host services are dropped. NM owns forwarding/NAT; the helper does
not override unrelated firewall drops. Argo runs as the desktop account, not root.

### Permissions and helper installation

Use read-only preflight before changing a deployment:

```bash
bluetoothctl list
nmcli --version
nmcli general permissions
nmcli device status
ip route
/usr/sbin/iw dev
/usr/sbin/iw reg get
```

Inspect the discovered phy with `iw phy <phy-name> info`. These CLIs are inspection
tools; BlueZ and NM D-Bus interfaces are the production control APIs.

The [firewall helper](../tool/connectivity/argo-projection-firewall) must be reviewed
and installed by an administrator. Installation is explicit and privileged:

```bash
sudo install -d -m 755 /usr/local/libexec
sudo install -o root -g root -m 755 "$HOME/dev/argo/tool/connectivity/argo-projection-firewall" \
  /usr/local/libexec/argo-projection-firewall
```

Connect/cleanup invoke the fixed helper via pkexec. No blanket passwordless rule
is required. BlueZ/NM operations also need the desktop account's D-Bus/polkit
permissions. Denial is reported rather than bypassed.

Cleanup stops only the owned activation and input guard. A partial activation
failure closes its attempt-local D-Bus owner. If activation/deactivation is uncertain,
the firewall guard remains and automatic replacement is blocked. Inspect the owned
profile and interface before recovery. After verifying that the owned AP is stopped,
the narrowly scoped manual guard removal is:

```bash
: "${PROJECTION_INTERFACE:?Set the verified projection interface}"
sudo /usr/local/libexec/argo-projection-firewall stop "$PROJECTION_INTERFACE"
```

Removing the installed helper after disabling wireless and completing cleanup is
an administrator rollback action. Keep unrelated profiles, bonds and firewall rules.

## Startup and session lifetime

Disabled → enabled → connecting → established describes connection ownership;
video visibility is a separate state. One session lease arbitrates USB and Wi-Fi
before AP/listener/media resources are created. An incoming wireless request cannot
replace wired projection. Explicit switching waits for old cleanup.

The AP and interface-bound TCP listener must be ready before Bluetooth advertises
connection details. The selected phone's Audio Gateway profile (`111f`) is requested
through the existing desktop Hands-Free implementation (`111e`). HFP is a bootstrap
trigger dependency, not a complete Argo calling feature. No competing HFP stack is
registered. UUID/channel conflicts are errors; bluetoothd is not restarted.

Authenticated RFCOMM negotiates WPP version, delivers Wi-Fi credentials and receives
a successful StartResponse. One in-subnet TCP candidate may wait for that acceptance.
ConnectionStatus is processed when supplied but is not a prerequisite for TCP AA:
some phones do not report it before the AA handshake begins. TCP uses the existing
version/TLS/channel engine; Wi-Fi never performs AOAP.

A usable session is established at the engine's validated video AV START on channel
3 (`0x8001`, after AV setup and configuration validation). This latches attempt-local
readiness. AP activation, TCP acceptance, version negotiation and TLS alone do not
establish projection. The 180-second overall setup deadline is permanently disarmed
at that event, even if presentation immediately becomes Suspended. Each replacement
gets a fresh latch. Stage-specific timeouts remain bounded independently.

AA Exit returns to Media and hides video; session/audio/metadata remain available.
Home resumes the same session through the existing focus path. Hiding video never
rearms setup or triggers reconnect. Later RFCOMM closure/idle expiry does not end a
healthy Wi-Fi session; explicit protocol failure still terminates it.

## Retry and shutdown

Internal failure kinds, not diagnostic wording, drive retry. Unexpected transport
EOF/reset, recoverable network loss and selected setup timeouts may retry while the
explicit request remains authorized. There are at most three attempts, with two- and
four-second backoffs. Pairing is checked before setup and admission. Authorization
revocation, protocol/TLS rejection and configuration/permission failures do not retry.
Failed or uncertain cleanup blocks replacement even when the original loss was
retryable. Graceful session end does not start a reconnect loop.

Disconnect, Disable, Forget, application closure and daemon shutdown cancel setup
or backoff. Cancellation completes owned cleanup before the lease is released.
The initiating error is published before potentially blocking native media cleanup;
cleanup errors are retained separately. No timeout is assumed to interrupt synchronous
FFI, and workers are not abandoned to make shutdown appear complete.

## Security and admission

`ARGO_WIRELESS_DEVELOPMENT=1` explicitly enables the development admission policy.
It requires a selected paired phone, authenticated/encrypted BlueZ RFCOMM, successful
version/start exchange, fresh credentials delivered only to that peer, a bounded
interface/subnet-restricted TCP window and rejection of unsolicited/second candidates.

TCP association relies on possession of fresh AP credentials; it is **not a
cryptographic binding to Bluetooth phone identity**. A compromised credential holder
can race the intended phone. Source IP, display name and completed TLS are not proof
of phone identity. Wireless TLS verifies handshake signatures while retaining legacy
certificate-chain compatibility. The wired AttachedUsbPeer policy is unchanged.
External identity format/ownership is defined in [configuration](configuration.md#projection).

## Troubleshooting and manual validation

INFO logs distinguish AP/DHCP readiness, HFP trigger outcome, authenticated RFCOMM,
version scalars, credential delivery, StartResponse and TCP admission. No secrets or
raw WPP payloads are logged. Check the first failure and any separate cleanup error.

- AP failure: inspect capabilities, regulatory flags, interface use and polkit/NM
  permissions. Do not change country settings to bypass a refusal.
- Waiting for Bluetooth: check the selected bond, phone prompts, HFP trigger result
  and AA profile/channel conflicts.
- Accepted start but no TCP: check AP association/DHCP and interface firewall policy.
- TCP admitted but no projection: inspect AA version/TLS/channel errors. Do not replace
  working identity files or weaken signature checks as a generic troubleshooting step.
- Cleanup pending: resolve the owned AP/guard state before another connection.

Mu lifecycle validation:

1. Connect wireless AA and start music.
2. Before three minutes elapse, use AA Exit to return to Media.
3. Stay on Media until at least four minutes after Connect.
4. Confirm session/audio/metadata remain available; press Home and resume the same session.
5. Deliberately interrupt only the projection connection with an approved controlled
   method; restore it and check bounded retry. Preserve the management interface.
6. Press Disconnect during retry/backoff and confirm retries stop.
7. Start a new explicit connection successfully.
8. Verify wired AA with wireless disabled.

The [status reference](status.md) distinguishes automated coverage from hardware
acceptance. Also check phone app internet access and metadata/Lua transport reporting.

## Protocol references

Implementation is independent; no reference implementation or deployment credentials
are vendored. WPP frames are u16 BE body length, u16 BE message ID, then bounded protobuf.
The AA UUID is `4de17a00-52cb-11e6-bdf4-0800200c9a66`, RFCOMM channel 8. Version request/
response are 4/5; Start 1/7; Wi-Fi info 2/3; status 6; Ping/Pong 8/9. Start status is
field 3; ConnectionStatus uses field 1. Version 6.0/status 0 has phone coverage.

- [LIVI pinned reference](https://github.com/f-io/LIVI/tree/c4ed3f1f7982cf10f899a92867ffd34b4269fee5), including its
  [wireless session path](https://github.com/f-io/LIVI/blob/c4ed3f1f7982cf10f899a92867ffd34b4269fee5/native/livi-helperd/bin/livi-helperd/src/aa.rs).
- [open-android-auto](https://github.com/mrmees/open-android-auto/tree/61eab61c5f9968154ff1a80faa8c0a427b208479).
- [aa-proxy-rs framing/status reference](https://github.com/aa-proxy/aa-proxy-rs/blob/841722019650412c8c3f1cefc7924f0b3d01c5e4/src/bluetooth.rs).
- [BlueZ Device1](https://bluez.readthedocs.io/en/latest/device-api/).
- [NM wireless settings](https://www.networkmanager.dev/docs/api/latest/settings-802-11-wireless.html),
  [D-Bus capabilities](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nm-dbus-types.html), and
  [shared DHCP implementation](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/dnsmasq/nm-dnsmasq-manager.c).
