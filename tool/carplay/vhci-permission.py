#!/usr/bin/python3 -I
"""Pass one fixed VHCI descriptor to the invoking Argo process, then exit.

No firmware, radio settings, device permissions, network connection or persistent
state is changed. The unprivileged recipient owns the controller's lifetime.
"""
import argparse
import array
import os
from pathlib import Path
import socket
import stat
import struct


def owner_identity(pid, uid):
    status = Path(f'/proc/{pid}/status').read_text()
    credentials = next(line.split()[1:] for line in status.splitlines() if line.startswith('Uid:'))
    if [int(value) for value in credentials] != [uid] * 4:
        raise RuntimeError('Owner must be the invoking desktop user')
    # The command name may contain spaces and parentheses; split after its final ).
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def private_directory(path, uid):
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid or metadata.st_mode & 0o077:
        raise RuntimeError('Owner runtime must be a private directory')


def pass_descriptor(connection, descriptor):
    message = array.array('i', [descriptor])
    if connection.sendmsg([b'AVHC1'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, message)]) != 5:
        raise RuntimeError('Descriptor handover failed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--owner-pid', type=int, required=True)
    args = parser.parse_args()
    uid = int(os.environ.get('PKEXEC_UID', '-1'))
    if os.geteuid() != 0 or uid <= 0 or args.owner_pid <= 1 or args.owner_pid != os.getppid():
        raise RuntimeError('Expected authenticated direct desktop child')
    identity = owner_identity(args.owner_pid, uid)
    runtime = Path(f'/run/user/{uid}')
    private_directory(runtime, uid)
    directory = runtime / 'argo'
    private_directory(directory, uid)
    path = directory / f'carplay-vhci-{args.owner_pid}.sock'
    metadata = path.lstat()
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != uid or metadata.st_mode & 0o077:
        raise RuntimeError('Invalid owner handover socket')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        peer_pid, peer_uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if (peer_pid, peer_uid) != (args.owner_pid, uid) or owner_identity(args.owner_pid, uid) != identity:
            raise RuntimeError('Owner changed during authentication')
        descriptor = os.open('/dev/vhci', os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISCHR(metadata.st_mode) or metadata.st_uid != 0:
                raise RuntimeError('Invalid VHCI device')
            pass_descriptor(connection, descriptor)
        finally:
            os.close(descriptor)


if __name__ == '__main__':
    main()
