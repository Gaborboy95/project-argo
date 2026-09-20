#!/usr/bin/python3 -I
"""Install the fixed, administrator-authorized CarPlay USB lease helper."""
import argparse
import os
from pathlib import Path
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
VHCI_POLICY_TEXT = POLICY_TEXT.replace('usb-lease', 'vhci').replace(
    "Temporarily select the attached iPhone's CarPlay USB mode",
    "Allow Argo to own a virtual Bluetooth controller for LIVI Link"
).replace(
    'Administrator authentication is required to select CarPlay USB mode.',
    'Administrator authentication is required to open the CarPlay virtual Bluetooth controller.'
)


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


def main(wireless=False):
    if os.geteuid() != 0:
        raise SystemExit('Run this installer with sudo. Argo itself stays unprivileged.')
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
    print('Installed the fixed ' + ('VHCI descriptor' if wireless else 'USB lease') + ' helper and administrator-authenticated polkit action.')
    print('No firmware, USB configuration, udev rules or sudoers entries were changed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--wireless', action='store_true', help='Install only the separate VHCI descriptor helper and policy')
    main(wireless=parser.parse_args().wireless)
