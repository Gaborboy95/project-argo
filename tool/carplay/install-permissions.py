#!/usr/bin/python3 -I
"""Install a fixed, administrator-authorized CarPlay USB or VHCI helper."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import tempfile

HELPER = Path('/usr/local/libexec/argo-carplay-usb-lease')
POLICY = Path('/usr/share/polkit-1/actions/dev.argo.carplay.usb-lease.policy')
POLICY_TEXT = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="dev.argo.carplay.usb-lease">
    <description>Temporarily select the attached iPhone's CarPlay USB mode</description>
    <message>Administrator authentication is required to select CarPlay USB mode.</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/argo-carplay-usb-lease</annotate>
  </action>
</policyconfig>
'''

VHCI_HELPER = Path('/usr/local/libexec/argo-carplay-vhci')
VHCI_POLICY = Path('/usr/share/polkit-1/actions/dev.argo.carplay.vhci.policy')
VHCI_DESKTOP_RULE = Path('/etc/polkit-1/rules.d/49-argo-carplay-vhci.rules')
VHCI_POLICY_TEXT = POLICY_TEXT.replace('usb-lease', 'vhci').replace(
    "Temporarily select the attached iPhone's CarPlay USB mode",
    "Allow Argo to own a virtual Bluetooth controller for LIVI Link"
).replace(
    'Administrator authentication is required to select CarPlay USB mode.',
    'Administrator authentication is required to open the CarPlay virtual Bluetooth controller.'
)


def wireless_desktop_rule(username):
    if not isinstance(username, str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', username):
        raise SystemExit('Expected an existing non-root desktop account name')
    try:
        account = pwd.getpwnam(username)
    except KeyError as error:
        raise SystemExit('The wireless desktop account does not exist') from error
    if account.pw_uid <= 0 or account.pw_name != username:
        raise SystemExit('Wireless desktop authorization requires one named non-root account')
    # Fail closed for remote/inactive users and calls to any other program. Other
    # polkit actions retain their own policy; no generic pkexec privilege is granted.
    return ('''// Explicit Argo wireless desktop opt-in; remove this file to restore admin authentication.
polkit.addRule(function(action, subject) {
    if (action.id !== "dev.argo.carplay.vhci") {
        return;
    }
    if (action.lookup("program") === "/usr/local/libexec/argo-carplay-vhci" &&
            subject.user === ''' + json.dumps(username) + ''' && subject.local && subject.active) {
        return polkit.Result.YES;
    }
    return polkit.Result.NO;
});
''').encode()


def install(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
            os.fchmod(file.fileno(), mode)
            os.fchown(file.fileno(), 0, 0)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def main(wireless=False, wireless_desktop_user=None):
    if os.geteuid() != 0:
        raise SystemExit('Run this installer with sudo. Argo itself stays unprivileged.')
    if wireless_desktop_user is not None and not wireless:
        raise SystemExit('--wireless-desktop-user requires --wireless')
    desktop_rule = (wireless_desktop_rule(wireless_desktop_user)
                    if wireless_desktop_user is not None else None)
    target_helper = VHCI_HELPER if wireless else HELPER
    target_policy = VHCI_POLICY if wireless else POLICY
    policy_text = VHCI_POLICY_TEXT if wireless else POLICY_TEXT
    source_name = 'vhci-permission.py' if wireless else 'usb-configuration-lease.py'
    source = Path(__file__).resolve().with_name(source_name).read_bytes()
    if not source.startswith(b'#!/usr/bin/python3 -I\n'):
        raise SystemExit('Expected an isolated Python helper')
    compile(source, str(target_helper), 'exec')
    install(target_helper, source, 0o755)
    install(target_policy, policy_text.encode(), 0o644)
    if desktop_rule is not None:
        install(VHCI_DESKTOP_RULE, desktop_rule, 0o644)
    print('Installed the fixed ' + ('VHCI descriptor' if wireless else 'USB lease') + ' helper and administrator-authenticated polkit action.')
    print('No firmware, USB configuration, udev rules or sudoers entries were changed.')
    if wireless:
        print('The helper loads only hci_vhci with fixed /usr/sbin/modprobe if /dev/vhci is absent.')
        if desktop_rule is not None:
            print('Installed optional VHCI-only authorization for active local desktop account ' + wireless_desktop_user + '. Remote/inactive callers are denied; other actions retain their own policy.')
        else:
            print('Default policy requires administrator authentication. No desktop authorization rule was changed; an existing optional rule remains in effect.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--wireless', action='store_true', help='Install the separate VHCI descriptor helper and policy')
    parser.add_argument('--wireless-desktop-user', help='With --wireless, explicitly allow the fixed VHCI helper only for this active local non-root account')
    args = parser.parse_args()
    if args.wireless_desktop_user is not None and not args.wireless:
        parser.error('--wireless-desktop-user requires --wireless')
    main(wireless=args.wireless, wireless_desktop_user=args.wireless_desktop_user)
