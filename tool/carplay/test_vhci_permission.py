"""Hardware-free descriptor handover and fixed module-loader boundaries."""
import array
import errno
import importlib.util
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('vhci_permission', Path(__file__).with_name('vhci-permission.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DescriptorTests(unittest.TestCase):
    def test_existing_device_never_loads_a_module(self):
        with patch.object(helper.os, 'open', return_value=42) as opened, \
             patch.object(helper, 'trusted_modprobe') as program, \
             patch.object(helper.subprocess, 'run') as run:
            self.assertEqual(helper.open_vhci(), 42)
        opened.assert_called_once_with('/dev/vhci', os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
        program.assert_not_called()
        run.assert_not_called()

    def test_missing_device_loads_only_fixed_module_then_retries_once(self):
        missing = FileNotFoundError(errno.ENOENT, 'synthetic missing device')
        with patch.object(helper.os, 'open', side_effect=[missing, 42]) as opened, \
             patch.object(helper, 'trusted_modprobe', return_value='/usr/sbin/modprobe'), \
             patch.object(helper.subprocess, 'run') as run:
            self.assertEqual(helper.open_vhci(), 42)
        self.assertEqual(opened.call_count, 2)
        run.assert_called_once_with(
            ['/usr/sbin/modprobe', 'hci_vhci'],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'},
            check=True, timeout=5,
        )

    def test_permission_errors_do_not_trigger_module_loading(self):
        with patch.object(helper.os, 'open', side_effect=PermissionError(errno.EACCES, 'synthetic denied')), \
             patch.object(helper.subprocess, 'run') as run:
            with self.assertRaises(PermissionError):
                helper.open_vhci()
        run.assert_not_called()

    def test_module_load_timeout_or_failure_does_not_open_or_retry_again(self):
        for error in [subprocess.TimeoutExpired('modprobe', 5), subprocess.CalledProcessError(1, 'modprobe')]:
            with self.subTest(error=type(error).__name__), \
                 patch.object(helper.os, 'open', side_effect=FileNotFoundError(errno.ENOENT, 'missing')) as opened, \
                 patch.object(helper, 'trusted_modprobe', return_value='/usr/sbin/modprobe'), \
                 patch.object(helper.subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(RuntimeError, 'could not be loaded'):
                    helper.open_vhci()
                self.assertEqual(opened.call_count, 1)

    def test_successful_loader_with_still_missing_device_fails_without_looping(self):
        with patch.object(helper.os, 'open', side_effect=FileNotFoundError(errno.ENOENT, 'missing')) as opened, \
             patch.object(helper, 'trusted_modprobe', return_value='/usr/sbin/modprobe'), \
             patch.object(helper.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'remains unavailable'):
                helper.open_vhci()
        self.assertEqual(opened.call_count, 2)
        run.assert_called_once()

    def test_module_executable_must_be_root_owned_and_not_writable_by_others(self):
        with tempfile.TemporaryDirectory() as root:
            program = Path(root) / 'modprobe'
            program.write_text('fixture, never executed')
            for uid, mode in [(1000, 0o755), (0, 0o777), (0, 0o644)]:
                metadata = SimpleNamespace(st_uid=uid, st_mode=stat.S_IFREG | mode)
                with self.subTest(uid=uid, mode=mode), \
                     patch.object(helper, 'MODPROBE', program), \
                     patch.object(Path, 'stat', return_value=metadata), \
                     patch.object(helper.subprocess, 'run') as run:
                    with self.assertRaises(RuntimeError):
                        helper.trusted_modprobe()
                    run.assert_not_called()

    def test_device_opens_before_handover_connect_and_closes_on_connect_error(self):
        events = []
        connection = MagicMock()
        connection.__enter__.return_value = connection
        connection.connect.side_effect = lambda _: events.append('connect')
        connection.getsockopt.return_value = struct.pack('3i', 1234, 1000, 1000)
        socket_metadata = SimpleNamespace(st_uid=1000, st_mode=stat.S_IFSOCK | 0o600)
        device_metadata = SimpleNamespace(st_uid=0, st_mode=stat.S_IFCHR | 0o600)
        with patch.object(sys, 'argv', ['helper', '--owner-pid', '1234']), \
             patch.dict(os.environ, {'PKEXEC_UID': '1000'}), \
             patch.object(helper.os, 'geteuid', return_value=0), \
             patch.object(helper.os, 'getppid', return_value=1234), \
             patch.object(helper, 'owner_identity', return_value='same-start'), \
             patch.object(helper, 'private_directory'), \
             patch.object(Path, 'lstat', return_value=socket_metadata), \
             patch.object(helper, 'open_vhci', side_effect=lambda: events.append('open') or 42), \
             patch.object(helper.os, 'fstat', return_value=device_metadata), \
             patch.object(helper.socket, 'socket', return_value=connection), \
             patch.object(helper, 'pass_descriptor', side_effect=lambda *_: events.append('handover')), \
             patch.object(helper.os, 'close') as close:
            helper.main()
            self.assertEqual(events, ['open', 'connect', 'handover'])
            close.assert_called_once_with(42)
            close.reset_mock()
            connection.connect.side_effect = OSError('synthetic connect failure')
            with self.assertRaises(OSError):
                helper.main()
            close.assert_called_once_with(42)

    def test_transferred_descriptor_survives_sender_close(self):
        left, right = socket.socketpair()
        read_fd, write_fd = os.pipe()
        received = None
        try:
            helper.pass_descriptor(left, read_fd)
            os.close(read_fd)
            read_fd = None
            body, messages, flags, _ = right.recvmsg(5, socket.CMSG_SPACE(array.array('i').itemsize))
            self.assertEqual(body, b'AVHC1')
            self.assertEqual(flags, 0)
            self.assertEqual(len(messages), 1)
            level, kind, data = messages[0]
            self.assertEqual((level, kind), (socket.SOL_SOCKET, socket.SCM_RIGHTS))
            values = array.array('i')
            values.frombytes(data)
            self.assertEqual(len(values), 1)
            received = values[0]
            os.write(write_fd, b'test')
            self.assertEqual(os.read(received, 4), b'test')
        finally:
            left.close()
            right.close()
            for descriptor in [read_fd, write_fd, received]:
                if descriptor is not None:
                    os.close(descriptor)

    def test_runtime_validation_rejects_symlink_and_public_directory(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            helper.private_directory(path, os.getuid())
            link = path / 'link'
            link.symlink_to(path, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                helper.private_directory(link, os.getuid())
            path.chmod(0o755)
            with self.assertRaises(RuntimeError):
                helper.private_directory(path, os.getuid())


if __name__ == '__main__':
    unittest.main()
