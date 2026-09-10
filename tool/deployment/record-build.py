#!/usr/bin/env python3
"""Record a completed matching source build, before argoctl stage. Never builds or installs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('kind', choices=['daemon', 'bundle'])
    p.add_argument('path', type=Path)
    p.add_argument('--ihs-prefix', type=Path)
    args = p.parse_args()
    ipc = (ROOT / 'native/projection/argo-projectiond/src/ipc.rs').read_text()
    version = int(re.search(r'pub const VERSION: u16 = (\d+);', ipc)[1])
    dart = (ROOT / 'lib/integrations/projection/projection_ipc.dart').read_text()
    if int(re.search(r'static const int version = (\d+);', dart)[1]) != version:
        p.error('Application and daemon source IPC versions disagree')
    source = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    record = {'schema': 1, 'ipc': version, 'source': source,
              'source_dirty': bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']))}
    record['source_diff_sha256'] = hashlib.sha256(subprocess.check_output(['git', '-C', str(ROOT), 'diff', 'HEAD', '--binary'])).hexdigest()
    if args.kind == 'daemon':
        record['sha256'] = sha(args.path)
        output = Path(str(args.path) + '.json')
    else:
        if args.ihs_prefix is None:
            p.error('Bundle records require the known matched --ihs-prefix')
        record['managed_control'] = 1
        if version >= 7:
            record['native_view_contract'] = 1  # ARVW negotiated crop parameters
        record['ihs_sha256'] = {f: sha(args.ihs_prefix / f) for f in (
            'bin/homescreen', 'lib/libihs_shared.so', 'include/ihs/platform_view.h')}
        record['ihs_contract'] = 'tool/projection/README.md#ihs-base-and-local-patch'
        output = args.path / 'argo-release.json'
        record['sha256'] = {str(f.relative_to(args.path)): sha(f)
                            for f in sorted(args.path.rglob('*')) if f.is_file() and f != output}
    output.write_text(json.dumps(record, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
