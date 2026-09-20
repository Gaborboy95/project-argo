#!/usr/bin/env python3
"""Exercise packages only inside a disposable Debian root through PRoot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['root', 'proot', 'proot-library', 'previous', 'package', 'log']:
        p.add_argument('--' + name, type=Path, required=True)
    a = p.parse_args()
    for key, value in vars(a).items(): setattr(a, key, value.resolve())
    if a.root == Path('/') or 'VERSION_ID="13"' not in (a.root / 'etc/os-release').read_text():
        p.error('A disposable Debian 13 root is required')
    env = {**os.environ, 'LD_LIBRARY_PATH': str(a.proot_library)}
    command = [str(a.proot), '-0', '-r', str(a.root), '-w', '/',
               '-b', '/etc/resolv.conf', '-b', '/dev/null', '-b', '/dev/urandom',
               '/usr/bin/env', '-u', 'LD_LIBRARY_PATH', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin',
               'HOME=/root', 'DEBIAN_FRONTEND=noninteractive']
    (a.root / 'tmp').mkdir(exist_ok=True)
    for file, name in [(a.previous, 'previous.deb'), (a.package, 'current.deb')]:
        shutil.copy2(file, a.root / 'tmp' / name)
    readonly = ['bwrap', '--unshare-all', '--ro-bind', str(a.root), '/', '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--die-with-parent', '--new-session', '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'HOME=/home/argo-test']
    # Debian slim normally excludes documentation. Include this package's docs
    # in the disposable test root so integrity checks cover its license payload.
    (a.root / 'etc/dpkg/dpkg.cfg.d/zz-argo-lifecycle-docs').write_text('path-include /usr/share/doc/argo-runtime/*\n')
    results = []
    with a.log.open('w') as log:
        def run(label, args, success=True, read_only=False):
            r = subprocess.run((readonly if read_only else command) + args, env=({k:v for k,v in os.environ.items() if k != 'LD_LIBRARY_PATH'} if read_only else env), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            log.write(label + '\n' + r.stdout + '\n'); log.flush()
            if (r.returncode == 0) != success: raise RuntimeError(label + ' failed; inspect ' + str(a.log))
            results.append({'check': label, 'passed': True, 'exit': r.returncode})
            return r.stdout
        run('clean initial package state', ['dpkg', '--purge', 'argo-runtime'])
        run('fresh install previous package', ['dpkg', '-i', '/tmp/previous.deb'])
        state = a.root / 'home/argo-test/.config/project-argo'
        state.mkdir(parents=True, exist_ok=True)
        marker = state / 'lifecycle-preserve.json'
        marker.write_text('{"settings":"preserve","pairing":"fixture-only"}\n')
        digest = hashlib.sha256(marker.read_bytes()).hexdigest()
        for label, args in [
            ('reinstall', ['dpkg', '-i', '/tmp/previous.deb']),
            ('upgrade', ['dpkg', '-i', '/tmp/current.deb']),
            ('remove', ['dpkg', '--remove', 'argo-runtime']),
            ('install again', ['dpkg', '-i', '/tmp/current.deb']),
            ('purge preserves user state', ['dpkg', '--purge', 'argo-runtime']),
            ('final install', ['dpkg', '-i', '/tmp/current.deb']),
        ]:
            run(label, args)
            assert hashlib.sha256(marker.read_bytes()).hexdigest() == digest
        broken = a.root / 'tmp/corrupt.deb'
        broken.write_bytes(a.package.read_bytes()[:4096])
        run('corrupt archive rejected', ['dpkg', '-i', '/tmp/corrupt.deb'], success=False)
        integrity = run('package integrity after rejected archive', ['dpkg', '--verify', 'argo-runtime'], read_only=True)
        if integrity.strip(): raise RuntimeError('Installed files do not match package checksums: ' + integrity)
        for binary in ['argo-carplayd', 'argo-carplayctl']:
            run('load ' + binary, ['/usr/lib/argo/runtime/bin/' + binary, '--version'], read_only=True)
        # This checks every ELF and dynamically loaded native asset, not only launchers.
        output = run('loader closure', ['/bin/sh', '-c', 'set -e; for f in /usr/lib/argo/runtime/bin/* /usr/lib/argo/runtime/lib/*.so*; do ldd "$f"; done'], read_only=True)
        if 'not found' in output: raise RuntimeError('Unresolved runtime dependency')
        run('no compiler on runtime target', ['/bin/sh', '-c', '! command -v cargo && ! command -v cmake && ! command -v flutter && ! command -v ninja'], read_only=True)
        run('package configured', ['dpkg-query', '-W', '-f=${Status} ${Version}\n', 'argo-runtime'])
    a.log.with_suffix('.json').write_text(json.dumps(results, indent=2) + '\n')

if __name__ == '__main__': main()
