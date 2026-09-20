#!/usr/bin/env python3
"""Run the public builder in a provisioned Debian root without host services."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'workspace', 'source'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    root, workspace, source = (p.resolve() for p in (args.root, args.workspace, args.source))
    if root == Path('/') or 'VERSION_ID="13"' not in (root / 'etc/os-release').read_text():
        parser.error('Expected a disposable, provisioned Debian 13 root')
    if workspace.exists():
        parser.error('Workspace must be fresh; no existing build outputs are reused')
    workspace.mkdir(parents=True)
    (workspace / 'home').mkdir()
    # Only network is shared for public downloads. The host home, runtime sockets,
    # device nodes and optional private checkout are absent from this namespace.
    subprocess.run([
        'bwrap', '--unshare-all', '--share-net', '--ro-bind', str(root), '/',
        '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp',
        '--ro-bind', '/etc/resolv.conf', '/etc/resolv.conf',
        '--ro-bind', str(source), '/source', '--bind', str(workspace), '/workspace',
        '--chdir', '/workspace', '--die-with-parent', '--new-session',
        '/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME=/workspace/home', 'LANG=C.UTF-8', 'TZ=UTC',
        'python3', '/source/tool/release/build-standard.py',
        '--source', '/source', '--work', '/workspace/build',
    ], check=True)


if __name__ == '__main__':
    main()
