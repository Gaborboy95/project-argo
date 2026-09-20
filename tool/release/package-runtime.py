#!/usr/bin/env python3
"""Assemble immutable Debian runtime assets; never installs or starts services."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
INSTALL = Path('/usr/lib/argo/runtime')

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['flutter-bundle', 'engine', 'ihs', 'projection-view', 'camera-view', 'definition', 'output']:
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--notices', type=Path, required=True)
    p.add_argument('--source-root', type=Path, default=ROOT)
    p.add_argument('--native-root', type=Path, default=ROOT / 'native')
    args = p.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path): setattr(args, name, value.resolve())
    subprocess.run(['dpkg', '--validate-version', args.version], check=True)
    definition = json.loads(args.definition.read_text())
    if definition['edition'] != 'standard':
        p.error('This packager accepts the standard edition only')
    engine = ctypes.CDLL(str(args.engine.resolve()))
    engine.FlutterEngineRunsAOTCompiledDartCode.restype = ctypes.c_bool
    if not engine.FlutterEngineRunsAOTCompiledDartCode():
        p.error('Release packaging requires the matched AOT engine')
    if sha(args.engine) != definition['engine']['library_sha256']:
        p.error('Engine does not match the release definition')
    if sha(args.ihs / 'include/ihs/platform_view.h') != definition['ihs']['platform_view_header_sha256']:
        p.error('IHS platform-view header does not match the release definition')
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='argo-package-', dir=args.output) as work:
        work = Path(work)
        stage = work / 'package'
        bundle = stage / INSTALL.relative_to('/')
        (bundle / 'bin').mkdir(parents=True)
        (bundle / 'lib').mkdir()
        shutil.copytree(args.flutter_bundle / 'data', bundle / 'data')
        # AOT contains its snapshots. Never ship a stale debug kernel/cache.
        for name in ['kernel_blob.bin', 'vm_snapshot_data', 'isolate_snapshot_data', '.last_build_id']:
            (bundle / 'data/flutter_assets' / name).unlink(missing_ok=True)
        sources = {
            'bin/homescreen': args.ihs / 'bin/homescreen',
            'lib/libihs_shared.so': args.ihs / 'lib/libihs_shared.so',
            'lib/libihs_shared.so.1': args.ihs / 'lib/libihs_shared.so.1',
            'lib/libflutter_engine.so': args.engine,
            'lib/libargo_projection_view.so': args.projection_view,
            'lib/libargo_camera_view.so': args.camera_view,
            'bin/argo-projectiond': args.native_root / 'projection/target/release/argo-projectiond',
            'bin/argo-carplayd': args.native_root / 'carplay/target/release/argo-carplayd',
            'bin/argo-carplayctl': args.native_root / 'carplay/target/release/argo-carplayctl',
            'bin/argo-camerad': args.native_root / 'camera/target/release/argo-camerad',
        }
        for name in ['libapp.so', 'libveloce_lua_native.so', 'libsqlite3.so']:
            sources['lib/' + name] = args.flutter_bundle / 'lib' / name
        for target, source in sources.items():
            if not source.is_file():
                p.error('Missing runtime input: ' + str(source))
            shutil.copy2(source, bundle / target, follow_symlinks=True)
            (bundle / target).chmod(0o755)
        symbols = subprocess.check_output(['nm', '-D', str(args.camera_view)], text=True)
        if 'argo_surround_camera_' in symbols:
            p.error('Standard camera library contains surround implementation')
        for source in [args.flutter_bundle / 'lib/native_assets.json', args.flutter_bundle / 'data/flutter_assets/NativeAssetsManifest.json']:
            if source.is_file():
                value = json.loads(source.read_text())
                def relocate(v):
                    if isinstance(v, list) and len(v) == 2 and v[0] in ('absolute', 'relative'):
                        name = Path(v[1]).name
                        if name not in ('libsqlite3.so', 'libveloce_lua_native.so'):
                            raise ValueError('Unexpected native asset: ' + name)
                        return ['absolute', str(INSTALL / 'lib' / name)]
                    if isinstance(v, dict): return {k: relocate(i) for k, i in v.items()}
                    if isinstance(v, list): return [relocate(i) for i in v]
                    return v
                target = bundle / source.relative_to(args.flutter_bundle)
                target.write_text(json.dumps(relocate(value), sort_keys=True) + '\n')
        # Private RUNPATH only; never shadow system graphics libraries.
        for path in [bundle / name for name in sources]:
            if path.read_bytes()[:4] == b'\x7fELF':
                subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/../lib' if path.parent.name == 'bin' else '$ORIGIN', str(path)], check=True)
        launcher = stage / 'usr/bin'
        launcher.mkdir(parents=True)
        for command, binary in [('argo', 'homescreen'), ('argo-projectiond', 'argo-projectiond'), ('argo-carplayd', 'argo-carplayd'), ('argo-carplayctl', 'argo-carplayctl')]:
            options = '-b "$runtime" --backend wayland-egl --fullscreen ' if command == 'argo' else ''
            script = f'''#!/bin/sh
set -eu
runtime={INSTALL}
export ARGO_MODE="${{ARGO_MODE:-production}}"
export ARGO_AUDIO_BACKEND="${{ARGO_AUDIO_BACKEND:-pipewire}}"
export ARGO_WIRELESS_BUNDLE="$runtime"
if [ -n "${{XDG_RUNTIME_DIR:-}}" ]; then
  export ARGO_PROJECTION_SOCKET="$XDG_RUNTIME_DIR/project-argo/projection.sock"
  export ARGO_PROJECTION_MEDIA_SOCKET="$XDG_RUNTIME_DIR/project-argo/video.sock"
fi
export ARGO_PROJECTION_VIEW_LIBRARY="$runtime/lib/libargo_projection_view.so"
export VELOCE_LUA_LIBRARY="$runtime/lib/libveloce_lua_native.so"
export LD_LIBRARY_PATH="$runtime/lib"
export ARGO_CAMERA_BACKEND="${{ARGO_CAMERA_BACKEND:-basic}}"
export ARGO_PROJECTION_BACKEND="${{ARGO_PROJECTION_BACKEND:-android-auto}}"
export ARGO_CARPLAY_ENABLED="${{ARGO_CARPLAY_ENABLED:-1}}"
exec "$runtime/bin/{binary}" {options}"$@"
'''
            (launcher / command).write_text(script)
            (launcher / command).chmod(0o755)
        units = stage / 'usr/lib/systemd/user'
        units.mkdir(parents=True)
        (units / 'argo-standard.target').write_text('[Unit]\nDescription=Argo Standard desktop session\nWants=argo-standard-app.service argo-standard-projection.service argo-standard-carplay.service\nAfter=graphical-session.target\nPartOf=graphical-session.target\n')
        for role, command in [('app', 'argo'), ('projection', 'argo-projectiond'), ('carplay', 'argo-carplayd')]:
            (units / ('argo-standard-' + role + '.service')).write_text(
                '[Unit]\nDescription=Argo Standard ' + role + '\nPartOf=argo-standard.target\nAfter=graphical-session.target pipewire.service wireplumber.service\nStartLimitIntervalSec=60\nStartLimitBurst=3\n\n[Service]\nType=exec\nExecStart=/usr/bin/' + command + '\nEnvironmentFile=-%h/.config/project-argo/runtime.env\nRestart=on-failure\nRestartSec=3\nTimeoutStopSec=50\nUMask=0077\n')
        (launcher / 'argo-session').write_text('#!/bin/sh\nset -eu\nexec systemctl --user start argo-standard.target\n')
        (launcher / 'argo-session').chmod(0o755)
        shutil.copy2(args.source_root / 'tool/deployment/argoctl', launcher / 'argoctl')
        (launcher / 'argoctl').chmod(0o755)
        desktop = stage / 'usr/share/applications'
        desktop.mkdir(parents=True)
        (desktop / 'argo.desktop').write_text('[Desktop Entry]\nType=Application\nName=Argo\nExec=argo-session\nTerminal=false\nCategories=AudioVideo;\n')
        doc = stage / 'usr/share/doc/argo-runtime'
        doc.mkdir(parents=True)
        for name in ['LICENSE', 'CREDITS.md']:
            if (args.source_root / name).is_file(): shutil.copy2(args.source_root / name, doc / name)
        shutil.copy2(args.definition, doc / 'release-definition.json')
        shutil.copytree(args.notices, doc / 'third-party-notices')
        copyright_text = ['Argo Standard development runtime. Argo and Veloce have no root license file; publication licensing remains unresolved.\nThird-party license texts follow. Dependency metadata is in third-party-notices/index.json.\n']
        for notice in sorted(args.notices.rglob('*')):
            if notice.is_file() and ('license' in notice.name.lower() or 'licence' in notice.name.lower() or notice.name.startswith(('COPYING', 'COPYRIGHT', 'NOTICE', 'Apache-2.0'))):
                copyright_text.append('\n--- ' + str(notice.relative_to(args.notices)) + ' ---\n' + notice.read_text(errors='replace'))
        (doc / 'copyright').write_text('\n'.join(copyright_text))
        (doc / 'state-ownership').write_text('Package files are immutable runtime assets only. Install, upgrade, remove and purge do not modify per-user settings, phone identity, pairing, integrations, plugins, calibrations, models or recordings. No services are started or enabled.\n')
        manifest = {'schema': 1, 'package_runtime': 1, 'edition': 'standard', 'ipc': 7,
                    'native_view_contract': 1, 'managed_control': 1, 'projection_media_contract': 1,
                    'camera_mode': 'basic', 'camera_contract': 1, 'carplay_control': 1, 'carplay_wired': 1,
                    'release_definition': definition, 'version': args.version,
                    'ihs_header_sha256': sha(args.ihs / 'include/ihs/platform_view.h'),
                    'ihs_sha256': {name: sha(bundle / name) for name in ['bin/homescreen', 'lib/libihs_shared.so']},
                    'sha256': {str(path.relative_to(bundle)): sha(path) for path in sorted(bundle.rglob('*')) if path.is_file()}}
        (bundle / 'argo-release.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        (work / 'debian').mkdir()
        (work / 'debian/control').write_text('Source: argo-runtime\nSection: misc\nPriority: optional\nMaintainer: Argo contributors <noreply@example.invalid>\nStandards-Version: 4.7.0\n\nPackage: argo-runtime\nArchitecture: amd64\nDescription: Argo standard runtime\n')
        control = stage / 'DEBIAN'
        control.mkdir()
        elfs = [str(bundle / name) for name in sources if (bundle / name).read_bytes()[:4] == b'\x7fELF']
        scan = subprocess.run(['dpkg-shlibdeps', '-O', '--ignore-missing-info', '-l' + str(bundle / 'lib'), *['-e' + path for path in elfs]], cwd=work, capture_output=True, text=True, check=True)
        (args.output / ('dependencies-' + args.version + '.log')).write_text(scan.stdout + scan.stderr)
        dependencies = scan.stdout.strip().removeprefix('shlibs:Depends=').split(', ')
        dependencies += definition['runtime_dependencies']
        (control / 'control').write_text(f'Package: argo-runtime\nVersion: {args.version}\nArchitecture: amd64\nMaintainer: Argo contributors <noreply@example.invalid>\nSection: misc\nPriority: optional\nDepends: ' + ', '.join(sorted(set(dependencies))) + '\nDescription: Argo Standard Edition runtime for Debian 13\n Matched IHS, Flutter, camera and phone projection runtime.\n')
        (control / 'md5sums').write_text(''.join(hashlib.md5(path.read_bytes()).hexdigest() + '  ' + str(path.relative_to(stage)) + '\n' for path in sorted(stage.rglob('*')) if path.is_file() and control not in path.parents))
        epoch = int(definition['source_date_epoch'])
        for path in stage.rglob('*'): os.utime(path, (epoch, epoch), follow_symlinks=False)
        output = args.output / f'argo-runtime_{args.version}_amd64.deb'
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(stage), str(output)], check=True, env={**os.environ, 'SOURCE_DATE_EPOCH': str(epoch)})
        (args.output / (output.name + '.sha256')).write_text(sha(output) + '  ' + output.name + '\n')
        print(output)

if __name__ == '__main__': main()
