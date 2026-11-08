"""Installer fixture; never writes system locations or changes real ownership."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
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
            self.assertEqual(install.call_args_list[0].args[1], Path(__file__).with_name('vhci-permission.py').read_bytes())
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

    def test_desktop_opt_in_installs_only_named_rule_plus_wireless_helper_and_policy(self):
        account = SimpleNamespace(pw_name='phaeton', pw_uid=1000)
        with patch.object(installer.os, 'geteuid', return_value=0), \
             patch.object(installer.pwd, 'getpwnam', return_value=account), \
             patch.object(installer, 'install') as install:
            expected_rule = installer.wireless_desktop_rule('phaeton')
            installer.main(wireless=True, wireless_desktop_user='phaeton')
        self.assertEqual([call.args[0] for call in install.call_args_list], [
            installer.VHCI_HELPER, installer.VHCI_POLICY, installer.VHCI_DESKTOP_RULE,
        ])
        self.assertEqual(install.call_args_list[2].args[2], 0o644)
        self.assertEqual(install.call_args_list[2].args[1], expected_rule)
        policy = ET.fromstring(install.call_args_list[1].args[1]).find('action')
        self.assertEqual(policy.findtext('defaults/allow_active'), 'auth_admin_keep')

    def test_desktop_opt_in_validates_before_any_system_file_write(self):
        for wireless, user, account in [
            (False, 'phaeton', SimpleNamespace(pw_name='phaeton', pw_uid=1000)),
            (True, 'root', SimpleNamespace(pw_name='root', pw_uid=0)),
            (True, 'bad"name', SimpleNamespace(pw_name='bad"name', pw_uid=1000)),
            (True, 'phaeton', SimpleNamespace(pw_name='other', pw_uid=1000)),
        ]:
            with self.subTest(wireless=wireless, user=user), \
                 patch.object(installer.os, 'geteuid', return_value=0), \
                 patch.object(installer.pwd, 'getpwnam', return_value=account), \
                 patch.object(installer, 'install') as install:
                with self.assertRaises(SystemExit):
                    installer.main(wireless=wireless, wireless_desktop_user=user)
                install.assert_not_called()
        with patch.object(installer.os, 'geteuid', return_value=0), \
             patch.object(installer.pwd, 'getpwnam', side_effect=KeyError('missing')), \
             patch.object(installer, 'install') as install:
            with self.assertRaises(SystemExit):
                installer.main(wireless=True, wireless_desktop_user='missing')
            install.assert_not_called()

    @unittest.skipUnless(shutil.which('node'), 'Policy decision fixture requires a JavaScript runtime')
    def test_desktop_rule_allows_only_selected_active_local_account_and_fixed_action(self):
        with patch.object(installer.pwd, 'getpwnam', return_value=SimpleNamespace(pw_name='phaeton', pw_uid=1000)):
            source = installer.wireless_desktop_rule('phaeton').decode()
        script = '''
const vm = require('node:vm');
const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
let rule;
vm.runInNewContext(input.source, {polkit: {
    Result: {YES: 'yes', NO: 'no'}, addRule: function(value) { rule = value; }
}});
const results = input.cases.map(function(c) {
    const action = {id: c[0], lookup: function(key) {return key === 'program' ? c[1] : undefined;}};
    const subject = {user: c[2], local: c[3], active: c[4]};
    return rule(action, subject) ?? 'unchanged';
});
process.stdout.write(JSON.stringify(results));
'''
        action = 'dev.argo.carplay.vhci'
        program = '/usr/local/libexec/argo-carplay-vhci'
        cases = [
            [action, program, 'phaeton', True, True],
            [action, program, 'phaeton', False, True],
            [action, program, 'phaeton', True, False],
            [action, program, 'other', True, True],
            [action, program, 'root', True, True],
            [action, '/usr/bin/sh', 'phaeton', True, True],
            ['dev.argo.carplay.usb-lease', program, 'phaeton', True, True],
            ['org.freedesktop.policykit.exec', '/usr/bin/sh', 'phaeton', True, True],
        ]
        result = subprocess.run([shutil.which('node'), '-e', script],
                                input=json.dumps({'source': source, 'cases': cases}),
                                text=True, capture_output=True, check=True, timeout=5)
        self.assertEqual(json.loads(result.stdout), [
            'yes', 'no', 'no', 'no', 'no', 'no', 'unchanged', 'unchanged',
        ])

if __name__ == '__main__':
    unittest.main()
