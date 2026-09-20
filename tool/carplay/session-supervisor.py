#!/usr/bin/env python3
"""Keep the USB configuration lease owner alive across explicit development retries."""
import os
from pathlib import Path
import signal
import subprocess
import sys

child = None

def stop(*_):
    global child
    if child is not None and child.poll() is None:
        child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=6)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
print(f'USB lease supervisor PID: {os.getpid()}', flush=True)
root = Path(__file__).resolve().parents[2]
for line in sys.stdin:
    if line.strip() == 'quit':
        break
    if line.strip() != 'run':
        continue
    child = subprocess.Popen([str(root / 'native/carplay/target/debug/examples/wired_session'), '1280', '720', '200', '112'])
    print(f'Receiver exited: {child.wait()}', flush=True)
    child = None
stop()
