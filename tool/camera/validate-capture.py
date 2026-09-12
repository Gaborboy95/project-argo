#!/usr/bin/env python3
"""Explicit-device capture check: private camerad, metadata and ARCR guards only."""
import argparse
import array
import json
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--daemon', required=True, type=Path)
    parser.add_argument('--device', required=True, help='Exact stableId from --enumerate')
    parser.add_argument('--seconds', type=int, default=5)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error('--seconds must be 1–60')
    root = Path(os.environ['XDG_RUNTIME_DIR']) / 'project-argo'
    root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='camera-check-', dir=root) as directory:
        child = subprocess.Popen([str(args.daemon.resolve()), directory])
        control = socket.socket(socket.AF_UNIX)
        control.settimeout(5)
        media = socket.socket(socket.AF_UNIX)
        media.settimeout(5)
        memory = None
        fds = []
        try:
            deadline = time.monotonic() + 5
            while not (Path(directory) / 'control.sock').exists():
                if time.monotonic() > deadline or child.poll() is not None:
                    raise RuntimeError('Camera daemon did not become ready')
                time.sleep(.02)
            control.connect(directory + '/control.sock')
            media.connect(directory + '/media.sock')
            data, ancillary, flags, _ = media.recvmsg(1, socket.CMSG_SPACE(8))
            assert data == b'\x01' and not flags & socket.MSG_CTRUNC
            for level, kind, payload in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    values = array.array('i'); values.frombytes(payload); fds.extend(values)
            assert len(fds) == 2
            memory = mmap.mmap(fds[0], 0, access=mmap.ACCESS_READ)
            assert struct.unpack_from('<4I', memory) == (0x52435241, 1, 3, 1920*1080*4)

            def send(op, number):
                data = json.dumps({'version': 1, 'id': number, 'op': op,
                                   'role': 'rear', 'stableId': args.device}).encode()
                control.sendall(struct.pack('>I', len(data)) + data)

            def receive():
                def read(size):
                    data = b''
                    while len(data) < size:
                        chunk = control.recv(size-len(data))
                        if not chunk: raise RuntimeError('Camera control ended')
                        data += chunk
                    return data
                size, = struct.unpack('>I', read(4))
                assert 0 < size <= 16384
                return json.loads(read(size))

            send('start', 1)
            deadline = time.monotonic() + args.seconds + 5
            first = None
            last_sequence = 0
            stable_frames = 0
            while time.monotonic() < deadline:
                value = receive()
                if value.get('state') in ('failed', 'disconnected'):
                    raise RuntimeError(value)
                if value.get('state') != 'streaming': continue
                sequence, active, role = struct.unpack_from('<3Q', memory, 16)
                assert active == 1 and role == 1
                slot = 128 + ((sequence-1) % 3)*(64+1920*1080*4)
                guard, = struct.unpack_from('<Q', memory, slot)
                width, height, stride = struct.unpack_from('<3I', memory, slot+8)
                timestamp, = struct.unpack_from('<Q', memory, slot+32)
                assert width <= 1920 and height <= 1080 and stride >= width*4
                pixels = memory[slot+64:slot+64+stride*height]
                after, = struct.unpack_from('<Q', memory, slot)
                if guard != after or guard != sequence*2: continue  # overwrite detected
                assert len(pixels) == stride*height
                assert time.monotonic_ns()-timestamp < 750_000_000
                assert sequence > last_sequence
                last_sequence = sequence
                stable_frames += 1
                if first is None:
                    first = time.monotonic()
                    print('Negotiated:', json.dumps(value['frame']))
                if time.monotonic()-first >= args.seconds: break
            assert stable_frames >= 2, 'No sustained real capture'
            send('stop', 2)
            while (value := receive()).get('id') != 2: pass
            assert value.get('error') is None
            assert struct.unpack_from('<Q', memory, 24)[0] == 0
            open_nodes = []
            for fd in Path(f'/proc/{child.pid}/fd').iterdir():
                try:
                    target = os.readlink(fd)
                    if target.startswith('/dev/video'): open_nodes.append(target)
                except FileNotFoundError: pass
            assert not open_nodes, 'Stopped camera still owns V4L2 descriptor'
            print(f'{stable_frames} stable shared-memory samples; latest sequence {last_sequence}; stop invalidated ring and released V4L2')
            send('start', 3)
            restart_deadline = time.monotonic() + 8
            while time.monotonic() < restart_deadline:
                value = receive()
                if value.get('state') == 'streaming' and value['sequence'] > last_sequence:
                    print('New manual start: fresh sequence', value['sequence'])
                    break
            else:
                raise RuntimeError('New manual stream did not become ready')
            # Lose the owner during active capture: kernel capture FDs must close.
            control.close()  # Owner loss, without a close command, must exit.
            assert child.wait(timeout=5) == 0
            print('Owner disconnect: daemon exited cleanly')
        finally:
            control.close(); media.close()
            if memory: memory.close()
            for fd in fds: os.close(fd)
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)


if __name__ == '__main__':
    main()
