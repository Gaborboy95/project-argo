import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
import subprocess
import shutil

loader = importlib.machinery.SourceFileLoader('guard', str(Path(__file__).with_name('argo-projection-firewall')))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)


class Scope(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'JavaScript runtime unavailable')
    def test_exact_helper_grant_in_inactive_local_session(self):
        loader = importlib.machinery.SourceFileLoader('installer', str(Path(__file__).with_name('install-permissions.py')))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        installer = importlib.util.module_from_spec(spec)
        loader.exec_module(installer)
        # Execute the actual generated rule with polkit Subject/Action fixtures.
        script = "let rule; const polkit = {Result: {YES: 'yes'}, addRule: r => rule = r};\n" + installer.firewall_rule() + r'''
const subject = {local: true, active: false, isInGroup: g => g === 'argo-connectivity'};
const action = {id: 'org.argo.projection-firewall', lookup: () => '/usr/local/libexec/argo-projection-firewall'};
if (rule(action, subject) !== 'yes') throw Error('Inactive enrolled local session denied');
for (const s of [{...subject, local: false}, {...subject, isInGroup: () => false}]) {
  if (rule(action, s) !== undefined) throw Error('Unenrolled or remote session authorized');
}
for (const a of [{...action, id: 'org.freedesktop.policykit.exec'}, {...action, lookup: () => '/usr/sbin/nft'}]) {
  if (rule(a, subject) !== undefined) throw Error('Unrelated executable/action authorized');
}
'''
        subprocess.run(['node', '-e', script], check=True, timeout=5)

    def test_only_enrolled_interfaces_and_fixed_operations(self):
        config = {'interfaces': ['wlan-test']}
        table = guard.validate('start', 'wlan-test', config)
        self.assertEqual(table, guard.validate('stop', 'wlan-test', config))
        self.assertRegex(table, r'^argo_projection_[a-f0-9]{16}$')
        for action, interface in [('flush', 'wlan-test'), ('stop', 'enp3s0'),
                                  ('start', 'wlan-test;flush ruleset'), ('start', '../wlan-test')]:
            with self.assertRaises(ValueError):
                guard.validate(action, interface, config)


if __name__ == '__main__':
    unittest.main()
