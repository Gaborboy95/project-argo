#!/usr/bin/python3 -I
"""Opt in to Argo-owned A2DP reception links; run as the desktop account."""
from pathlib import Path
import argparse
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--uninstall', action='store_true')
args = parser.parse_args()
if os.geteuid() == 0:
    parser.error('Run as the desktop account, not root')
config = Path.home() / '.config/wireplumber/wireplumber.conf.d/80-argo-a2dp.conf'
content = '''# Argo owns reception links only. WirePlumber still owns Bluetooth profiles.
monitor.bluez.rules = [
  {
    matches = [ { factory.name = "api.bluez5.a2dp.source" } ]
    actions = { update-props = { node.autoconnect = false argo.music.managed = true } }
  }
]
'''
if config.exists() and config.read_text() != content:
    parser.error(f'Refusing to overwrite customized configuration: {config}')
if args.uninstall:
    config.unlink(missing_ok=True)
else:
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(content)
print('Bluetooth routing preference updated. Log out/in to apply. No service restarted.')
