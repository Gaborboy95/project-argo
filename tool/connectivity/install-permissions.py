#!/usr/bin/python3 -I
"""Explicit administrator provisioning; never called by Argo at runtime."""
import argparse
import grp
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import tempfile

HELPER = Path('/usr/local/libexec/argo-projection-firewall')
CONFIG = Path('/etc/argo/projection-firewall.json')
POLICY = Path('/usr/share/polkit-1/actions/org.argo.projection-firewall.policy')
RULE = Path('/etc/polkit-1/rules.d/49-argo-projection-firewall.rules')
GROUP = 'argo-connectivity'


def install(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    for parent in [path.parent, *path.parent.parents]:
        info = parent.lstat()
        if parent.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError(f'Untrusted installation directory: {parent}')
    if path.is_symlink():
        raise ValueError(f'Refusing symlink: {path}')
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        tmp = Path(output.name)
        output.write(content)
    os.chown(tmp, 0, 0)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account')
    parser.add_argument('--interface', action='append', default=[])
    parser.add_argument('--uninstall', action='store_true')
    parser.add_argument('--bluetooth-audio', action='store_true', help='Also install per-account Argo A2DP routing opt-in')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run this installer once with administrator approval (sudo)')
    if args.uninstall:
        # Stop Argo first. Guards must be explicitly removed before revoking access.
        if CONFIG.exists():
            config = json.loads(CONFIG.read_text())
            for interface in config['interfaces']:
                subprocess.run([str(HELPER), 'stop', interface], check=True)
            for account in config['accounts']:
                if account in grp.getgrnam(GROUP).gr_mem:
                    subprocess.run(['/usr/bin/gpasswd', '-d', account, GROUP], check=True)
        for path in [RULE, POLICY, CONFIG, HELPER]:
            path.unlink(missing_ok=True)
        print('Argo permission grant removed. Existing bonds/NM profiles unchanged.')
        return
    if not args.account or not args.interface:
        parser.error('--account and at least one --interface are required')
    account = pwd.getpwnam(args.account)
    if account.pw_uid == 0 or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', args.account):
        parser.error('Enroll a non-root local account')
    for interface in args.interface:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,14}', interface) or not Path('/sys/class/net', interface, 'phy80211').exists():
            parser.error('Every approved interface must be an existing Wi-Fi interface')
    if not shutil.which('nft') or not shutil.which('pkexec'):
        parser.error('Install nftables and polkit before provisioning')
    tables = json.loads(subprocess.check_output(['/usr/sbin/nft', '-j', 'list', 'tables']))
    if any(entry.get('table', {}).get('name', '').startswith('argo_projection_') for entry in tables['nftables']):
        parser.error('Stop projection and complete guard cleanup before installing/upgrading permissions')
    try:
        grp.getgrnam(GROUP)
    except KeyError:
        subprocess.run(['/usr/sbin/groupadd', '--system', GROUP], check=True)
    # Re-running with the same choices is idempotent. Additional accounts/interfaces
    # are explicit administrator enrollments, never runtime configuration.
    old = json.loads(CONFIG.read_text()) if CONFIG.exists() else {'accounts': [], 'interfaces': []}
    config = {'accounts': sorted(set(old['accounts'] + [args.account])),
              'interfaces': sorted(set(old['interfaces'] + args.interface))}
    install(CONFIG, (json.dumps(config) + '\n').encode(), 0o644)
    install(HELPER, Path(__file__).with_name('argo-projection-firewall').read_bytes(), 0o755)
    install(POLICY, f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
 <action id="org.argo.projection-firewall">
  <description>Manage administrator-approved Argo projection guards</description>
  <message>Administrator approval is required for the Argo projection guard</message>
  <defaults><allow_any>no</allow_any><allow_inactive>no</allow_inactive><allow_active>no</allow_active></defaults>
  <annotate key="org.freedesktop.policykit.exec.path">{HELPER}</annotate>
 </action>
</policyconfig>
'''.encode(), 0o644)
    install(RULE, f'''// Root-owned grant for this exact executable only; no authorization cache.
polkit.addRule(function(action, subject) {{
 if (action.id === "org.argo.projection-firewall" &&
     action.lookup("program") === "{HELPER}" &&
     subject.local && subject.active && subject.isInGroup("{GROUP}")) {{
   return polkit.Result.YES;
 }}
}});
'''.encode(), 0o644)
    subprocess.run(['/usr/sbin/usermod', '-a', '-G', GROUP, args.account], check=True)
    if args.bluetooth_audio:
        script = Path(__file__).resolve().parent.parent / 'audio/install-bluetooth-routing.py'
        subprocess.run(['/usr/sbin/runuser', '-u', args.account, '--', '/usr/bin/python3', '-I', str(script)], check=True)
    print('Installed. Log out/in to refresh group membership. No services restarted.')


if __name__ == '__main__':
    main()
