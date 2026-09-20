"""Hardware-free tests: the helper must only transfer a supplied descriptor."""
import array
import importlib.util
import os
from pathlib import Path
import socket
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('vhci_permission', Path(__file__).with_name('vhci-permission.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DescriptorTests(unittest.TestCase):
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
