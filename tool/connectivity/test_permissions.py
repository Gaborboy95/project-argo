import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader('guard', str(Path(__file__).with_name('argo-projection-firewall')))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)


class Scope(unittest.TestCase):
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
