#!/usr/bin/python3 -I
"""Temporarily select one iPhone's CarPlay USB function, restoring it on owner exit.

Run through sudo for development or the installed polkit action. This helper only writes bConfigurationValue
for the already-exposed Apple iPhone device; it never opens the LIVI Link.
No firmware, trust record, driver or persistent USB setting changes.
"""
import argparse
import fcntl
import select
import os
from pathlib import Path
import signal
import time


LOCK_PATH = '/run/argo-carplay-usb-lease.lock'


def phone():
    matches = []
    for path in Path('/sys/bus/usb/devices').iterdir():
        try:
            if (path / 'idVendor').read_text().strip() == '05ac' and 0x1290 <= int((path / 'idProduct').read_text().strip(), 16) <= 0x12ff:
                matches.append(path)
        except (OSError, ValueError):
            continue
    if len(matches) != 1:
        raise RuntimeError('Exactly one locally attached iPhone is required')
    return matches[0]


def process_identity(pid):
    root = Path('/proc') / str(pid)
    stat = (root / 'stat').read_text()
    return root.stat().st_uid, stat[stat.rindex(')') + 2:].split()[19]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-pid', type=int, required=True)
    parser.add_argument('--watch-stdin', action='store_true', help='Release when the daemon closes stdin')
    args = parser.parse_args()
    if os.geteuid() != 0 or args.owner_pid <= 1:
        raise RuntimeError('Administrator authorization and a live unprivileged owner are required')
    owner = process_identity(args.owner_pid)
    invoking = int(os.environ.get('SUDO_UID', os.environ.get('PKEXEC_UID', '-1')))
    if owner[0] == 0 or owner[0] != invoking:
        raise RuntimeError('Owner must belong to the invoking desktop user')
    # One privileged configuration owner, including across daemon restarts.
    lock_fd = os.open(LOCK_PATH,
                      os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock_fd)
        raise RuntimeError('Another CarPlay USB lease is active')
    path = None
    identity = None
    original = '4'
    owned = False
    def stop(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        selected = False
        print('Waiting for the receiver to expose CarPlay USB mode.', flush=True)
        while True:
            try:
                if process_identity(args.owner_pid) != owner:
                    break
            except (OSError, ValueError):
                break
            try:
                if args.watch_stdin and select.select([0], [], [], 0)[0]:
                    if not os.read(0, 1):
                        break
                    raise RuntimeError('Unexpected lease control input')
                candidate = phone()
                if identity is None:
                    if (candidate / 'bConfigurationValue').read_text().strip() != '4':
                        raise RuntimeError('Expected normal USB configuration 4 before taking a lease')
                    identity = (candidate / 'serial').read_text()
                if (candidate / 'serial').read_text() != identity:
                    raise RuntimeError('A different iPhone was attached; ending the lease')
                path = candidate
                current = (path / 'bConfigurationValue').read_text().strip()
                configurations = int((path / 'bNumConfigurations').read_text())
                if current == original and configurations >= 6:
                    owned = True
                    (path / 'bConfigurationValue').write_text('6')
                    current = (path / 'bConfigurationValue').read_text().strip()
                    if current != '6':
                        raise RuntimeError('CarPlay USB configuration selection failed')
                if current == '6' and not selected:
                    print('CarPlay USB configuration 6 selected; restoration is tied to the owner process.', flush=True)
                    selected = True
            except OSError:
                selected = False  # Same phone may re-enumerate while this owner lives.
            except RuntimeError as error:
                if str(error) != 'Exactly one locally attached iPhone is required':
                    raise
                selected = False
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            if owned and path is not None and (path / 'serial').read_text() == identity and (path / 'bConfigurationValue').read_text().strip() == '6':
                (path / 'bConfigurationValue').write_text(original)
                print('Restored original iPhone USB configuration.', flush=True)
        except OSError as error:
            if path is not None and path.exists():
                raise RuntimeError('Could not restore iPhone USB configuration') from error
            # Physical unplug already released this device.
        finally:
            os.close(lock_fd)


if __name__ == '__main__':
    main()
