# Wireless Android Auto on the Mu — development path

This path is implemented for operator testing; it is not phone-accepted yet.
It reuses `aa_session`, daemon identity, fixed session settings, native PCM/video,
input, metadata, Home/Media presentation and Veloce. No HFP call or A2DP feature
is added. Wired trust and GstSystemClock remain unchanged.

## Observed Mu preflight (2026-09-07)

Baseline `7173f2e`, initially clean. Linux 6.12.107+deb13-amd64, BlueZ 5.82,
NetworkManager 1.52.1, both services active. One powered Bluetooth controller
(`hci0`, alias PhaetonLink), not discoverable. Desktop WirePlumber owns existing
HFP AG/HS and media profiles. No AA UUID was advertised at inspection.

Discovered `wlp2s0`, MT7922 [14c3:7922], mt7921e; idle. `iw` is installed at
`/usr/sbin/iw` (outside this shell's PATH). AP mode and 2.4/5/6 GHz are reported;
interface combinations allow up to two interfaces, at most one AP/P2P-GO and
at most two channels. This feature uses one AP and requires idle Wi-Fi.
Current regulatory domain is **DE**, unchanged. 36–48 permit indoor operation;
52–144 require DFS. 149–165 are reported enabled at 13 dBm without NO-IR/DFS;
169–177 disabled. The implementation rechecks the selected phy and chooses
149–165 only, failing closed if no such non-DFS channel is proven. This is
read-only `iw` inspection, not a regulatory change. NM controls the AP via D-Bus.
No claim is made that radio capabilities prove successful AP operation.

Discovered `enp3s0` connected as “Wired connection 1”; address 10.20.252.21/24,
default route via 10.20.252.254. Neither is an application constant. NM reports
network-control, Wi-Fi scan, protected sharing and profile modification allowed
for this local user. Bluetooth/netdev groups are present. Pairing/profile
registration and AP activation still need operator verification.

## Ownership and security

The existing daemon owns one shared BlueZ session/agent and one connectivity
worker, independent of certificate readiness. Its non-default DisplayYesNo agent
handles **Argo-initiated Pair** operations. Incoming requests continue to use the
desktop default agent. No RequestDefaultAgent, Trusted=true, blanket authorization,
PIN auto-answer, bluetoothd restart, plugin change, or competing HFP registration.
The UI shows the callback's actual adapter/device reference and alias; confirmation
expires in 30 seconds. Discovery lasts 60 seconds and does not make the host
discoverable or change its power state. BlueZ owns bonds; Forget removes the
selected BlueZ device. Argo stores only requested adapter/interface/phone refs in
its existing settings file. Each launch starts wireless disabled.

Explicit Enable and Connect authorize one selected paired phone. Pairing without a comparison passkey also requires an explicit device-scoped authorization prompt. The AA profile
UUID is `4de17a00-52cb-11e6-bdf4-0800200c9a66`, RFCOMM channel 8, server role,
RequireAuthentication=true. A UUID-only SDP service class is supplied. Argo checks
the selected address, local adapter, current Paired state and link security >=
Medium before offering anything. Profile registration failures are surfaced;
no system profiles are removed. Profile authorization is performed by Argo's
selected-device admission, not by granting the device access to unrelated profiles.

The TCP listener exists only inside that owned attempt, bound to the AP's actual
IPv4 address **and SO_BINDTODEVICE**, port 5288. It rejects pre-bootstrap traffic,
out-of-network peers and second peers. Three unwanted Bluetooth requests revoke
the attempt. The phone must report successful Wi-Fi join before TCP admission.
Fresh, per-attempt WPA2/RSN/CCMP credentials are sent only on the selected
Bluetooth link. The credential holder entering within the bounded window is
associated with that bootstrap. **This is not a cryptographic binding of TCP to
the Bluetooth identity.** A compromised peer/host, leaked key or an attacker able
to join the fresh AP can race the phone. An IP address, display name or successful
TLS handshake is not proof of phone identity. Bluetooth and Wi-Fi MAC equality
is never assumed. Radio refs stay out of projection metadata/Veloce; projection
uses session-local opaque identifiers, separate from persistent BlueZ references.

Accordingly the daemon requires `ARGO_WIRELESS_DEVELOPMENT=1` and the UI explicitly
labels development admission. Wi-Fi uses a separate TLS verifier: legacy certificate
chain compatibility remains, but TLS 1.2 handshake signatures are verified using
the existing pinned rustls 0.23.22 provider. Wired AttachedUsbPeer behavior is
preserved. No certificate/identity files are changed. Phone compatibility with
this stricter signature check is an acceptance gap, not grounds to bypass it.

## Network and narrowly scoped provisioning

NetworkManager AddAndActivateConnection2 creates a dedicated **volatile** profile,
`Argo Projection (<interface>)`, bound to the chosen idle interface, with
autoconnect=false and bind-activation=dbus-client. A separate D-Bus connection owns
each attempt, so its disappearance deactivates the profile. A non-overlapping
10.77.x.0/24 is selected; address, activated state, a DHCP socket and the NM dnsmasq process bound to that address
with a matching DHCP range are required
before bootstrap. Phone DHCP receipt is still hardware acceptance.

IPv4 shared mode runs NM's DHCP/DNS service and adds forwarding/masquerading to
the host's uplink. This introduces NAT internet sharing; it is **not a bridge** to
Ethernet. IPv6 is disabled on the AP and never-default=true protects route choice.
This does not guarantee phone apps retain internet; test them on the phone.

Shared mode alone does not protect other host listeners. Before activation Argo
invokes one fixed-purpose helper through pkexec to install an nftables input
chain on **only the selected Wi-Fi interface**. It allows established traffic,
DHCP, DNS and projection TCP, dropping other incoming services. NM alone owns
forward/NAT rules. Existing firewall policy can further restrict traffic; this
helper does not override a later drop. Neither Argo nor its daemon runs as root.
No passwordless policy is installed. pkexec may request administrator confirmation
for start/cleanup; denied/timed-out requests are visible failures.

Review [the helper](../tool/connectivity/argo-projection-firewall), then explicitly
install it (the implementation does not silently install it):

```sh
sudo install -d -m 755 /usr/local/libexec
sudo install -o root -g root -m 755 \
  "$HOME/dev/argo/tool/connectivity/argo-projection-firewall" \
  /usr/local/libexec/argo-projection-firewall
```

Dependencies: BlueZ, NetworkManager, nftables, polkit/pkexec, iw, NM's shared-mode
DHCP support (dnsmasq-base), and the existing native-media runtime. No drivers,
firmware, services, country settings or default pairing agents need changing.
If pkexec has no desktop authentication agent, Connect fails explicitly.

Cleanup targets only the exact active-connection object returned by NM, then
removes the feature's input guard. If activation completion is unknown or cleanup
fails, close the attempt-owned D-Bus connection and retain the input guard rather
than exposing services; the UI reports that uncertainty. Inspect NM before a new
attempt. Do not delete arbitrary profiles or flush the firewall.

Rollback, with wireless stopped and the owned AP confirmed inactive:

```sh
# Substitute the interface discovered/selected on this deployment.
pkexec /usr/local/libexec/argo-projection-firewall stop wlp2s0
sudo rm /usr/local/libexec/argo-projection-firewall
```

The helper can affect only its reserved `inet argo_projection_<ifindex>` table,
with validated existing Wi-Fi interfaces. After a crash/radio removal a retained
guard may need explicit administrator removal of that named table; never flush
unrelated rules. Normal cleanup preserves all unrelated connections/profiles.

## Protocol references inspected

Read-only reference checkouts were kept under /tmp, never vendored. No credentials
or deployment scripts were imported.

- [LIVI c4ed3f1f7982cf10f899a92867ffd34b4269fee5](https://github.com/f-io/LIVI/tree/c4ed3f1f7982cf10f899a92867ffd34b4269fee5): actual helper `bin/livi-helperd/src/aa.rs`, `crates/livi-aa/src/wpp.rs`, runtime `bt.rs`, and aaw proto files.
- [open-android-auto 61eab61c5f9968154ff1a80faa8c0a427b208479](https://github.com/mrmees/open-android-auto/tree/61eab61c5f9968154ff1a80faa8c0a427b208479): Wi-Fi protos and wireless Bluetooth setup/channel docs. Its suggestions to auto-accept, disable plugins or stop WirePlumber are not followed.
- [aa-proxy-rs 841722019650412c8c3f1cefc7924f0b3d01c5e4](https://github.com/aa-proxy/aa-proxy-rs/blob/841722019650412c8c3f1cefc7924f0b3d01c5e4/src/bluetooth.rs): independent status/framing and version-response parser cross-check.
- [NetworkManager 1.52.1 shared DHCP source](https://github.com/NetworkManager/NetworkManager/blob/1.52.1/src/core/dnsmasq/nm-dnsmasq-manager.c) cross-checks address-specific DHCP readiness.
- BlueZ ProfileManager1/Agent1 and NetworkManager D-Bus API; locally compiled
  bluer 0.17.4 and zbus 5.19.0 expose those supported APIs.

WPP is u16 BE **body length**, u16 BE message ID, then protobuf, bounded to 4096
bytes. Version request 4 advertises 6.0 and packed channel frequencies (MHz);
response 5 is checked before Start 1 offers the actual endpoint. Start response 7
has status in **field 3**; info request 2 gets response 3 (SSID/password/BSSID,
security=8 WPA2, AP type=1 dynamic). Connection status 6 has status in field 1.
Ping 8 gets Pong 9 with the same body. No USB frame headers or AOAP occur here.
The reference version-status enum documentation is inconsistent/unverified;
this implementation currently accepts the legacy success value 0 with major 6,
and fails closed on other responses pending an actual phone trace. This specific
interoperability assumption is not claimed phone-verified.

Version response deadline 10s; bootstrap join 60s; profile rendezvous 60s; TCP
window 65s; overall setup 180s. Pre-join messages are capped at 64. RFCOMM idle
30s closes only bootstrap after a successful join; a healthy Wi-Fi session lives
on. Bounded reconnect is at most three attempts, 2s/4s backoff for transient loss.
Disconnect, Forget, Disable and application shutdown cancel the owned attempt;
AA Exit is presentation-only and never starts reconnect or reopens Home.
Session cleanup completes before releasing the shared USB/Wi-Fi ownership permit.
Selection changes during projection are pending for the next explicit connection.

## IPC and launch

**IPC v5 requires matching application and daemon.** Kind 30 is a bounded UTF-8
JSON connectivity snapshot; kind 31 is a <=2048-byte strict JSON command
`{action,target,accept,prompt}`. Commands: adapter/interface/select, discover,
pair/confirm, enable/connect/disconnect/forget. Projection control/media formats
are unchanged except the explicit v5 header and device transport=1 for Wi-Fi.
No secrets/media bytes enter the new messages. Shared v5 hex fixtures validate
both implementations. Connectivity commands work when AA identity is absent.

Wired rollback was copied before staging:
`$HOME/dev/infotainment/bundle/argo-wired-7173f2e-rollback`, including `bin/argo-projectiond`.
Original `$HOME/dev/infotainment/bundle/argo-render-test` is untouched and is LIVE,
not the renderer diagnostic. Do not use run_renderer_test.sh for this workflow.

New release: `$HOME/dev/infotainment/bundle/argo-wireless-ipc5-20260907`.
It includes its matching `bin/argo-projectiond`; the native-view library is copied
unchanged from the wired rollback. Neither Engine, IHS nor the view is rebuilt. Use separate sockets for isolated
read-only checks. Never run two hardware-enabled projection daemons together.
Stop old app/daemon before launching the new matched pair; never overwrite a
loaded executable or library. Reuse existing daemon-owned identity paths. Leave
ARGO_PROJECTION_RENDER_TEST unset and use ARGO_MODE=production,
ARGO_PROJECTION_BACKEND=android-auto. Wireless stays disabled unless explicitly
enabled. Normal wired launch does not need the development gate or helper.

Launch from two desktop terminals, after stopping the previous app/daemon:

```sh
# Terminal 1: reuse the two external identity paths from your wired launch.
# These variables are already documented by the wired runbook; do not copy keys.
export ARGO_ANDROID_AUTO_CERT_FILE=/your/existing/argo.crt
export ARGO_ANDROID_AUTO_KEY_FILE=/your/existing/argo.key
export ARGO_WIRELESS_DEVELOPMENT=1
"$HOME/dev/argo/tool/connectivity/run-release.sh" daemon

# Terminal 2 (LIVE / production, not the renderer diagnostic):
"$HOME/dev/argo/tool/connectivity/run-release.sh" app
```

For wired-only operation, omit/unset `ARGO_WIRELESS_DEVELOPMENT`, leave wireless
disabled and attach USB. For rollback, stop both new processes and use the
existing wired launcher with `argo-wired-7173f2e-rollback` and its `bin/argo-projectiond`
(IPC v4); do not point a v5 application at that daemon. New launch uses dedicated
`$XDG_RUNTIME_DIR/argo-wireless-ipc5/` sockets. A crash-left socket is never
silently unlinked; verify its process is gone before removing that specific file.

Operator sequence:

1. Open Settings → Devices & connectivity. Choose radios if ambiguous. Start
   discovery, open the phone Bluetooth screen, and Pair the actual listed phone.
   Confirm matching passkeys on both screens; reject unexpected requests.
   An already bonded phone can be selected without copying or recreating bonds.
2. Disconnect the USB **data** cable. Select the paired phone for AA; Enable,
   then Connect explicitly authorizes this attempt's protected projection AP.
   Approve pkexec if asked. Follow phone Android Auto/HFP prompts. The existing
   desktop HFP implementation may be required; no Argo hands-free calls are added.
3. Observe phone Wi-Fi joined, then actual AA streaming (not merely Bluetooth
   connected). Check picture/audio/input and `argo_host.snapshot()` reporting
   `androidAuto/wifi`, including track updates without raw media in control IPC.
4. AA Exit → Media, stay there while audio/metadata continue, then Home. Confirm
   the same projection session ID and working input. Exit must not start reconnect.
5. Explicit Disconnect, wait beyond backoff, and verify no attempt resumes.
   Deliberately Connect again. Repeat with Disable; test wired with wireless off.
6. Verify Ethernet/default route still present and open an internet-dependent
   phone app while on projection Wi-Fi. NM NAT availability alone is not proof.


## Acceptance record

Pending: real AP activation/DHCP, phone pairing and WPP/TCP/TLS, USB cable removed,
picture/audio/input, metadata and Lua `androidAuto/wifi`, Exit→Media→Home with
same session, stop-reconnect behavior and deliberate reconnection, wired fallback,
management Ethernet continuity during projection, and phone app internet access.
No open listener or mock establishes these outcomes.

Automated verification on this checkout: 50 Rust tests passed; all-target Clippy
with warnings denied passed; 224 Flutter tests passed with the bundled native Lua
library and no skips; Dart analyzer reported no issues. Both release builds passed.
Launcher/helper syntax checks passed. The input guard itself is not radio-tested.

Local runtime verification: a separate no-USB debug daemon, with identity variables
removed, registered its non-default BlueZ agent and sent an IPC v5 snapshot with
hci0, wlp2s0 and one existing paired device. No discover/pair/connect command was
sent. It was stopped cleanly. An unprivileged socket accepted SO_BINDTODEVICE;
no TCP bind/listen/traffic was performed by that permission check.

The original LIVE bundle matches the saved rollback byte-for-byte. Engine and
native projection-view hashes match the original; IHS and the audio-clock code
were untouched. Final read-only checks still show Ethernet/default route intact,
Wi-Fi idle, Bluetooth powered but not discovering/discoverable.

**Operator gate remains:** installation approval for the root-owned firewall
helper and availability for phone confirmation were requested but have not been
received. The helper is not installed, so Connect currently stops at provisioning.
No radio/AP failure has been observed: AP activation, HFP trigger compatibility,
WPP version-status compatibility, TLS with this phone and all phone acceptance
steps remain untested. This is a staged development implementation, not completed
end-to-end wireless acceptance. See the bundle's `BUILD-MANIFEST.txt` for hashes
and the final source revision.
