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
    p.add_argument('--camera-mode', choices=['basic', 'surround', 'disabled', 'legacy', 'external'], default='basic')
    p.add_argument('--projection-media-contract', type=int, choices=[1])
    p.add_argument('--carplay-wired', action='store_true')
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
    # New feature files must be represented in dirty-build provenance too.
    untracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--others', '--exclude-standard', '-z'])
    record['source_untracked_sha256'] = {
        name: sha(ROOT / name) for name in untracked.decode().split('\0')
        if name and (ROOT / name).is_file()
    }
    if args.kind == 'daemon':
        record['sha256'] = sha(args.path)
        output = Path(str(args.path) + '.json')
    else:
        if args.ihs_prefix is None:
            p.error('Bundle records require the known matched --ihs-prefix')
        camera = [(args.path / f).is_file() for f in ('bin/argo-camerad', 'lib/libargo_camera_view.so')]
        if args.camera_mode in ('external', 'surround'):
            if camera[0] or not camera[1]:
                p.error('External Camera requires camera-view and no app-owned camerad binary')
            record.update(camera_mode='surround', camera_view_contract=2,
                          camera_api={'major': 1, 'min_minor': 0, 'max_minor': 0})
        else:
            if any(camera) and not all(camera):
                p.error('Camera bundles require both camerad and camera-view')
            record['camera_mode'] = 'disabled' if args.camera_mode == 'disabled' else 'basic'
            if all(camera):
                record['camera_contract'] = 1
        record['managed_control'] = 1
        if version >= 7:
            record['native_view_contract'] = 1  # ARVW negotiated crop parameters
        carplay = [(args.path / f).is_file() for f in ('bin/argo-carplayd', 'bin/argo-carplayctl')]
        if any(carplay):
            if not all(carplay):
                p.error('CarPlay diagnostics require both daemon and control tool')
            for name in ('argo-carplayd', 'argo-carplayctl'):
                version_output = subprocess.check_output([str(args.path.resolve() / 'bin' / name), '--version'], text=True, timeout=5)
                if 'control=1' not in version_output:
                    p.error('CarPlay binary control contract mismatch')
            record['carplay_control'] = 1
            record['carplay_scope'] = 'diagnostics-only'
            if args.carplay_wired:
                output = subprocess.check_output([str(args.path.resolve() / 'bin/argo-carplayd'), '--version'], text=True, timeout=5)
                if 'wired=true' not in output or args.projection_media_contract != 1:
                    p.error('Wired CarPlay requires a wired-capable daemon and media contract 1')
                record['carplay_wired'] = 1
                record['carplay_scope'] = 'wired-development'
        elif args.carplay_wired:
            p.error('Wired CarPlay requires daemon and control tool')
        if args.projection_media_contract:
            record['projection_media_contract'] = args.projection_media_contract
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
