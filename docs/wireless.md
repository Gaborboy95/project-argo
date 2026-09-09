# Wireless Android Auto

Wireless projection uses the same Android Auto session, video, PCM audio, input,
metadata and Home/Media services as USB. Bluetooth bootstraps a phone onto an
Argo-owned NetworkManager AP; projection then runs over TCP. Read
[setup](setup.md) for the matched application/daemon launch and
[status](status.md) for tested configurations.

## Pairing and connection

1. Open Settings → Devices. Select the Bluetooth adapter and an
   idle projection Wi-Fi interface when discovery is ambiguous.
2. Start the bounded discovery window, open the phone's Bluetooth settings and
   pair the intended device. Confirm matching device-scoped passkeys; reject
   unexpected requests. Prompts expire. Existing BlueZ bonds can be reused.
3. Select the paired phone and AP band. Disconnect USB data for wireless testing.
4. With a viable selected adapter, wireless is available automatically. Press Connect. Approve any required phone or desktop permission
   prompts. AP readiness, Bluetooth bootstrap, TCP and streaming are distinct stages.
5. Use Disconnect or Disable to stop the connection request and its retries.
   Forget revokes the device selection and removes its BlueZ bond.

Wireless availability follows read-only NetworkManager managed/radio state, AP/band
capabilities and current permitted channels. An idle viable interface is selected
automatically only when unambiguous. A card serving another network is unavailable
for projection. No environment enable flag is required. Discovery, AP creation and
connection still require explicit controls; availability alone starts none of them.
Disable stays in effect for the current application connection until enabled again.
Saved adapter/interface/phone/band choices are restored without connecting. Changed
choices remain pending for the next connection; current attempts and retries retain
their frozen selection. Bluetooth pairing/music do not depend on NM readiness.

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

On first Connect, Argo generates deployment-specific WPA2/RSN/CCMP credentials and
a non-overlapping private IPv4 /24. NetworkManager stores them in the inactive,
non-autoconnecting, account-restricted `Argo Projection credentials (<interface>)`
profile, marked `org.argo.owner=projection-credentials-v1`. This credential template
is never activated by Argo. Reconnecting the same selected phone reuses its network
and permanent radio BSSID, allowing the phone to recognize the AP. Connecting a
different phone rotates the template; Forget removes matching credentials. A removal
failure is reported separately from bond removal. The attempt's active profile
remains volatile and bound to its D-Bus owner. Credentials are delivered only over
selected authenticated bootstrap, never through IPC, logs, Argo settings or Veloce. Readiness requires NM activation,
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

The root-owned [firewall helper](../tool/connectivity/argo-projection-firewall) is
provisioned explicitly by an administrator. Stop Argo and complete AP cleanup first;
then select the discovered projection interface and enroll the desktop account:

```bash
: "${PROJECTION_INTERFACE:?Set the discovered projection Wi-Fi interface}"
sudo /usr/bin/python3 -I "$HOME/dev/argo/tool/connectivity/install-permissions.py" \
  --account "$USER" --interface "$PROJECTION_INTERFACE"
```

The idempotent installer owns `/etc/argo/projection-firewall.json`, the fixed helper,
a dedicated polkit action and a rule for the `argo-connectivity` group. Only local,
active enrolled accounts can execute that exact helper without a password. The
helper itself accepts only start/stop for administrator-approved interfaces and its
own deterministic nftables tables; runtime accounts cannot edit these files.
Log out/in after enrollment. No service restart, password storage, generic pkexec
permission, sudo cache or broad NetworkManager grant is involved.

BlueZ/NM keep their existing desktop D-Bus permissions. Inspect `nmcli general
permissions` before adding any separate policy: network control, owned profile
modification and protected shared Wi-Fi are available to the reference desktop
account. The installer adds no NM grant.

After enrollment, verify repeated Connect/Disconnect/cleanup after cached desktop
authorizations expire. `pkexec --disable-internal-agent` with an unapproved interface
must fail inside the helper; a non-enrolled account must fail polkit authorization.
These are installation/hardware checks, separate from input-validation tests.

Cleanup stops only the owned activation and input guard. The inactive credential
template survives Disconnect and daemon restart; it does not retain a hotspot. A partial activation
failure closes its attempt-local D-Bus owner. If activation/deactivation is uncertain,
the firewall guard remains and automatic replacement is blocked. Inspect the owned
profile and interface before recovery. After verifying that the owned AP is stopped,
the narrowly scoped manual guard removal is:

```bash
: "${PROJECTION_INTERFACE:?Set the verified projection interface}"
sudo /usr/local/libexec/argo-projection-firewall stop "$PROJECTION_INTERFACE"
```

After stopping Argo, uninstall the grant/helper and its owned guards explicitly:

```bash
sudo /usr/bin/python3 -I "$HOME/dev/argo/tool/connectivity/install-permissions.py" --uninstall
```

Uninstall removes enrolled group memberships but leaves the empty group, unrelated
profiles, bonds and firewall rules. To resume an older bundle, reinstall the scoped
helper before wireless use; rollback does not require restoring generic password
prompts. Complete cleanup with the old helper before first upgrading from an
ifindex-named guard; the new helper never deletes unrelated or legacy tables.

To reset the saved projection network, stop Argo and verify the activation has
completed cleanup. Inspect `nmcli -f NAME,UUID,TYPE connection show`, identify the
owned inactive credential template, then remove only its UUID:

```bash
: "${ARGO_CREDENTIAL_UUID:?Set the verified inactive Argo credential template UUID}"
nmcli connection delete uuid "$ARGO_CREDENTIAL_UUID"
```

This deletes the saved SSID/password/address; the next explicit Connect generates
new ones. Use this after a persistent subnet/route conflict or credential exposure.
No unrelated network profile or Bluetooth bond needs removal.

## Startup and session lifetime

Unavailable/disabled → available/enabled → connecting → established describes connection ownership;
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

## Active-session liveness

After validated AV START, wireless sessions enforce `WIRELESS_PEER_TIMEOUT`: ten
seconds without valid inbound AA activity. This is a development operational target,
not a protocol-mandated interval. It is separate from setup deadlines and remains
active while video is hidden or Suspended. Every session has fresh timing and
heartbeat state; the USB engine does not enforce this watchdog.

Pings continue every 1500 ms. Validated encrypted messages with a recognized channel
effect refresh responsiveness. PingResponse (`0x000c`) must echo an outstanding
PingRequest (`0x000b`) timestamp in protobuf field 1, for both supported plaintext
and encrypted responses. At most eight requests are retained; responses expire after
ten seconds and each can match only once. Timestamp uniqueness across sessions
prevents an old reply from matching a new request. Unknown or discarded messages,
malformed/incomplete frames, unmatched/replayed responses and unsolicited plaintext
requests do not renew liveness. Neither local writes/UI commands, host AP readiness,
nor stored Bluetooth pairing demonstrate phone responsiveness.

The watchdog is polled alongside the engine, including pending reads and writes.
Buffered packet processing yields to deadlines/cancellation and keeps pings running;
D-Bus health checks are polled alongside the session instead of blocking it. Expiry
ends the connection, including any partially completed write; a partial frame is
never restarted on the same byte stream. Synchronous native FFI remains subject to
its existing cleanup constraints, not preempted by an async timer.

Accepted TCP sockets retain keepalive (five-second idle and interval) and use a
Linux `TCP_USER_TIMEOUT` of 15 seconds for unacknowledged or unsent data. This is a
secondary per-socket safeguard. TCP acknowledgements and successful local writes
cannot substitute for AA responsiveness; keepalive does not guarantee ten-second
application detection. No global TCP settings are changed.

## Retry and shutdown

Internal failure kinds, not diagnostic wording, drive retry. Unexpected transport
EOF/reset, established-peer liveness expiry, recoverable network loss and selected setup timeouts may retry while the
explicit request remains authorized. There are at most three attempts, with two- and
four-second backoffs. Pairing is checked before setup and admission. Authorization
revocation, protocol/TLS rejection and configuration/permission failures do not retry.
Failed or uncertain cleanup blocks replacement even when the original loss was
retryable. Graceful session end does not start a reconnect loop.

Disconnect, Disable, Forget, application closure and daemon shutdown cancel setup
or backoff. Cancellation completes owned cleanup before the lease is released.
The initiating error and Failed session state are published before potentially blocking native media cleanup;
cleanup errors are retained separately. No timeout is assumed to interrupt synchronous
FFI, and workers are not abandoned to make shutdown appear complete.

## Security and admission

Wireless admission remains experimental even though capability detection no longer
requires an environment gate. Explicit Connect authorizes the selected paired phone,
authenticated/encrypted BlueZ RFCOMM, successful version/start exchange, credentials
delivered only to that peer, a bounded
interface/subnet-restricted TCP window and rejection of unsolicited/second candidates.

TCP association relies on possession of the selected phone's AP credentials; it is **not a
cryptographic binding to Bluetooth phone identity**. Credentials are reused for that phone across connections. A compromised credential holder
can race the intended phone. Source IP, display name and completed TLS are not proof
of phone identity. Wireless TLS verifies handshake signatures while retaining legacy
certificate-chain compatibility. The wired AttachedUsbPeer policy is unchanged.
External identity format/ownership is defined in [configuration](configuration.md#projection).

## Troubleshooting and manual validation

INFO timing logs measure preflight, AP/DHCP readiness and TCP acceptance from Connect.
They distinguish cold AP/network association from the subsequent AA handshake;
there is no deliberate post-bootstrap delay. INFO logs also distinguish HFP trigger outcome, authenticated RFCOMM,
version scalars, credential delivery, StartResponse and TCP admission. No secrets or
raw WPP payloads are logged. Check the first failure and any separate cleanup error.
With `ARGO_PROJECTION_LOG_LEVEL=debug`, established-session liveness reports at most
once every five seconds: valid receive age, most recent matched heartbeat age (if
any), and the effective deadline. RX/TX packet details remain TRACE. A liveness WARN
marks detection, not completed cleanup. Separate logs report elapsed media cleanup,
AP/firewall cleanup (which can wait for authorization), and retry/backoff. A pending
firewall prompt must not be mistaken for late detection or successful teardown.

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
5. Verify healthy playback and heartbeat-only idle Media remain connected. Then stop
   actual phone-side projection traffic without a graceful session close, using an
   approved method that preserves the management interface. Check DEBUG receive age;
   a phone settings toggle alone does not establish that AA traffic stopped.
6. Confirm a liveness failure around ten seconds after the last valid activity.
   Distinguish detection from subsequent cleanup/authorization waits and bounded
   reconnect; restore phone radios in time for a permitted retry.
7. Press Disconnect during retry/backoff and confirm retries stop.
8. Start a new explicit connection successfully.
9. Verify AA Exit → Media → Home and wired AA with wireless disabled.

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

AA session heartbeat fields (distinct from WPP Ping/Pong) follow the existing
[PingRequest timestamp](https://github.com/f1xpl/aasdk/blob/master/aasdk_proto/PingRequestMessage.proto)
and [PingResponse timestamp](https://github.com/f1xpl/aasdk/blob/master/aasdk_proto/PingResponseMessage.proto)
declarations. Correlation adds no wire fields or changes to encryption policy.

The startup/artwork comparison uses [LIVI revision b8651d7](https://github.com/f-io/LIVI/tree/b8651d795e5f84871d7454ce25e6ff6fb79e03d5).
Its dedicated-interface deployment can keep an AP ready outside NetworkManager;
Argo retains explicit activation and management-network protection. Reusing a
phone's network reduces avoidable network churn, but cold activation and phone
association remain hardware-dependent. No fixed few-second startup guarantee is made.
