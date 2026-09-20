"""Hardware-free checks for the narrow development USB lease."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('lease', Path(__file__).with_name('usb-configuration-lease.py'))
lease = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lease)

class LeaseTests(unittest.TestCase):
    def test_waits_for_exposure_and_restores_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            phone = Path(directory)
            for name, value in [('serial', 'fixture'), ('bConfigurationValue', '4'), ('bNumConfigurations', '4')]:
                (phone / name).write_text(value)
            sleeps = 0
            def advance(_):
                nonlocal sleeps
                sleeps += 1
                if sleeps == 1:
                    self.assertEqual((phone / 'bConfigurationValue').read_text(), '4')
                    (phone / 'bNumConfigurations').write_text('6')
                else:
                    self.assertEqual((phone / 'bConfigurationValue').read_text(), '6')
                    raise KeyboardInterrupt
            with patch.object(lease, 'LOCK_PATH', str(phone / 'lease.lock')), \
                 patch.object(lease, 'phone', return_value=phone), \
                 patch.object(lease, 'process_identity', return_value=(1000, 'start')), \
                 patch.object(lease.os, 'geteuid', return_value=0), \
                 patch.dict(lease.os.environ, {'SUDO_UID': '1000'}), \
                 patch.object(lease.signal, 'signal'), \
                 patch.object(lease.time, 'sleep', side_effect=advance), \
                 patch('sys.argv', ['lease', '--owner-pid', '10']):
                lease.main()
            self.assertEqual((phone / 'bConfigurationValue').read_text(), '4')

    def test_daemon_pipe_eof_releases_lease_after_initially_missing_phone(self):
        with tempfile.TemporaryDirectory() as directory:
            phone = Path(directory)
            for name, value in [('serial', 'fixture'), ('bConfigurationValue', '4'), ('bNumConfigurations', '6')]:
                (phone / name).write_text(value)
            with patch.object(lease, 'LOCK_PATH', str(phone / 'lease.lock')), \
                 patch.object(lease, 'phone', side_effect=[RuntimeError('Exactly one locally attached iPhone is required'), phone]), \
                 patch.object(lease, 'process_identity', return_value=(1000, 'start')), \
                 patch.object(lease.os, 'geteuid', return_value=0), \
                 patch.dict(lease.os.environ, {'SUDO_UID': '1000'}), \
                 patch.object(lease.signal, 'signal'), \
                 patch.object(lease.time, 'sleep'), \
                 patch.object(lease.select, 'select', side_effect=[([],[],[]),([],[],[]),([0],[],[])]), \
                 patch.object(lease.os, 'read', return_value=b''), \
                 patch('sys.argv', ['lease', '--owner-pid', '10', '--watch-stdin']):
                lease.main()
            self.assertEqual((phone / 'bConfigurationValue').read_text(), '4')

    def test_does_not_take_or_restore_an_existing_configuration_six(self):
        with tempfile.TemporaryDirectory() as directory:
            phone = Path(directory)
            (phone / 'bConfigurationValue').write_text('6')
            with patch.object(lease, 'LOCK_PATH', str(phone / 'lease.lock')), \
                 patch.object(lease, 'phone', return_value=phone), \
                 patch.object(lease, 'process_identity', return_value=(1000, 'start')), \
                 patch.object(lease.os, 'geteuid', return_value=0), \
                 patch.dict(lease.os.environ, {'SUDO_UID': '1000'}), \
                 patch.object(lease.signal, 'signal'), \
                 patch('sys.argv', ['lease', '--owner-pid', '10']):
                with self.assertRaisesRegex(RuntimeError, 'configuration 4'):
                    lease.main()
            self.assertEqual((phone / 'bConfigurationValue').read_text(), '6')

    def test_rejects_owner_from_another_user_before_phone_access(self):
        with patch.object(lease, 'phone') as phone, \
             patch.object(lease, 'process_identity', return_value=(1001, 'start')), \
             patch.object(lease.os, 'geteuid', return_value=0), \
             patch.dict(lease.os.environ, {'SUDO_UID': '1000'}), \
             patch('sys.argv', ['lease', '--owner-pid', '10']):
            with self.assertRaisesRegex(RuntimeError, 'invoking desktop user'):
                lease.main()
            phone.assert_not_called()

if __name__ == '__main__':
    unittest.main()
