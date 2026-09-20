"""Installer fixture; never writes system locations or changes real ownership."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-permissions.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def test_installs_fixed_isolated_helper_and_admin_only_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / 'libexec/helper'
            policy = Path(directory) / 'actions/policy'
            with patch.object(installer, 'HELPER', helper), patch.object(installer, 'POLICY', policy), \
                 patch.object(installer.os, 'geteuid', return_value=0), \
                 patch.object(installer.os, 'fchown') as ownership:
                installer.main()
            self.assertTrue(helper.read_bytes().startswith(b'#!/usr/bin/python3 -I\n'))
            self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
            self.assertEqual(policy.stat().st_mode & 0o777, 0o644)
            self.assertEqual(ownership.call_count, 2)
            for call in ownership.call_args_list:
                self.assertEqual(call.args[1:], (0, 0))
            action = ET.fromstring(policy.read_text()).find('action')
            self.assertEqual(action.findtext('defaults/allow_active'), 'auth_admin_keep')
            self.assertEqual(action.findtext('defaults/allow_inactive'), 'no')
            self.assertEqual(action.findtext('annotate'), '/usr/local/libexec/argo-carplay-usb-lease')

    def test_wireless_install_writes_only_its_helper_and_policy(self):
        with patch.object(installer.os, 'geteuid', return_value=0), patch.object(installer, 'install') as install:
            installer.main(wireless=True)
            self.assertEqual([call.args[0] for call in install.call_args_list], [installer.VHCI_HELPER, installer.VHCI_POLICY])
            action = ET.fromstring(install.call_args_list[1].args[1]).find('action')
            self.assertEqual(action.attrib['id'], 'dev.argo.carplay.vhci')
            self.assertEqual(action.findtext('annotate'), '/usr/local/libexec/argo-carplay-vhci')
            self.assertEqual(action.findtext('defaults/allow_active'), 'auth_admin_keep')
            self.assertEqual(action.findtext('defaults/allow_any'), 'no')

    def test_unprivileged_install_refuses_before_writing(self):
        with patch.object(installer.os, 'geteuid', return_value=1000), patch.object(installer, 'install') as install:
            with self.assertRaises(SystemExit):
                installer.main()
            install.assert_not_called()

if __name__ == '__main__':
    unittest.main()
