#!/usr/bin/python3 -I
"""Pass one fixed VHCI descriptor to the invoking Argo process, then exit.

If the device is absent, load only the fixed hci_vhci kernel module. No firmware,
radio settings, device permissions, network connection or persistent configuration
is changed. The unprivileged recipient owns the controller's lifetime.
"""
import argparse
import array
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess

MODPROBE = Path('/usr/sbin/modprobe')
MODULE_LOAD_TIMEOUT = 5


def trusted_modprobe():
    """Accept the fixed system executable, including Debian's root-owned kmod link."""
    target = MODPROBE.resolve(strict=True)
    if MODPROBE.lstat().st_uid != 0:
        raise RuntimeError('The fixed modprobe path must be root-owned')
    for path in set(MODPROBE.parents) | set(target.parents) | {target}:
        metadata = path.stat()
        if metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise RuntimeError('The fixed modprobe executable and directories must be root-owned and not writable by other users')
    metadata = target.stat()
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise RuntimeError('The fixed modprobe target must be executable')
    return str(MODPROBE)


def open_vhci():
    flags = os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        return os.open('/dev/vhci', flags)
    except FileNotFoundError:
        pass
    # Never run a caller-selected command, inherit MODPROBE_OPTIONS, or retry on
    # permission/other device errors. The installed helper provides this on demand
    # after reboot, without a writable device rule or a modules-load configuration.
    program = trusted_modprobe()
    try:
        subprocess.run(
            [program, 'hci_vhci'],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'},
            check=True, timeout=MODULE_LOAD_TIMEOUT,
        )
    except (subprocess.SubprocessError, OSError) as error:
        raise RuntimeError('The fixed hci_vhci module could not be loaded') from error
    try:
        return os.open('/dev/vhci', flags)
    except OSError as error:
        raise RuntimeError('/dev/vhci remains unavailable after loading hci_vhci') from error


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
    # Open/load before connecting: the native receiver's bounded descriptor read
    # starts at accept, and must not include the separate module-load deadline.
    descriptor = open_vhci()
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISCHR(metadata.st_mode) or metadata.st_uid != 0:
            raise RuntimeError('Invalid VHCI device')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            peer_pid, peer_uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if (peer_pid, peer_uid) != (args.owner_pid, uid) or owner_identity(args.owner_pid, uid) != identity:
                raise RuntimeError('Owner changed during authentication')
            pass_descriptor(connection, descriptor)
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    main()
