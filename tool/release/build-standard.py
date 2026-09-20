#!/usr/bin/env python3
"""Public-input Standard builder. Run inside the documented disposable builder."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--definition', type=Path, default=HERE / 'standard-release.json')
    args = p.parse_args()
    definition = json.loads(args.definition.read_text())
    work = args.work.resolve()
    if work.exists(): p.error('Use a fresh work directory; external caches may be mounted separately')
    work.mkdir(parents=True)
    env = {**os.environ, 'CI': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true',
           'PUB_CACHE': str(work / 'pub-cache'), 'CARGO_HOME': str(work / 'cargo-cache'),
           'CARGO_INCREMENTAL': '0', 'SOURCE_DATE_EPOCH': str(definition['source_date_epoch'])}
    def download(spec, name):
        path = work / name
        with urllib.request.urlopen(spec['url'], timeout=120) as source, path.open('wb') as output:
            shutil.copyfileobj(source, output)
        if digest(path) != spec['sha256']: raise ValueError('Input checksum mismatch: ' + name)
        return path
    def checkout(name, spec):
        path = work / name
        run(['git', 'init', path])
        run(['git', '-C', path, '-c', 'credential.helper=', 'fetch', '--depth=1', spec['url'], spec.get('revision', spec.get('base_revision'))], env={**env, 'GIT_TERMINAL_PROMPT': '0'})
        run(['git', '-C', path, 'checkout', '--detach', 'FETCH_HEAD'])
        if spec.get('patch'):
            patch = args.definition.parent / spec['patch']
            if digest(patch) != spec['patch_sha256']: raise ValueError('Patch hash mismatch')
            run(['git', '-C', path, 'apply', '--check', patch.resolve()])
            run(['git', '-C', path, 'apply', patch.resolve()])
        return path
    source = work / 'argo'
    source.mkdir()
    archive = work / 'argo.tar'
    with archive.open('wb') as output:
        run(['git', '-C', args.source.resolve(), 'archive', definition['argo']['revision']], stdout=output)
    with tarfile.open(archive) as tar: tar.extractall(source, filter='data')
    veloce = checkout('veloce', definition['veloce'])
    flutter = checkout('flutter', definition['flutter'])
    run(['git', '-C', flutter, 'fetch', '--depth=1', definition['flutter']['url'], 'tag', definition['flutter']['version']], env=env)
    tag_revision = subprocess.check_output(['git', '-C', flutter, 'rev-parse', definition['flutter']['version'] + '^{commit}'], text=True).strip()
    if tag_revision != definition['flutter']['revision']: raise ValueError('Flutter version tag does not match pinned revision')
    ihs = checkout('ihs-source', definition['ihs'])
    run(['git', '-C', ihs, '-c', 'credential.helper=', 'submodule', 'update', '--init', '--recursive'], env={**env, 'GIT_TERMINAL_PROMPT': '0'})
    toolchain = work / 'rust'
    for name, spec in definition['rust']['archives'].items():
        archive = download(spec, name + '.tar.xz')
        with tarfile.open(archive) as tar: tar.extractall(work / 'rust-inputs', filter='data')
        installer = next((work / 'rust-inputs').glob(name + '-*/install.sh'))
        run(['sh', installer, '--prefix=' + str(toolchain), '--disable-ldconfig'])
    env['PATH'] = str(toolchain / 'bin') + ':' + str(flutter / 'bin') + ':' + env['PATH']
    env['RUSTFLAGS'] = '--remap-path-prefix=' + str(work) + '=/build'
    engine_archive = download(definition['engine'], 'engine.tar.gz')
    engine = work / 'engine/libflutter_engine.so'
    engine.parent.mkdir()
    with tarfile.open(engine_archive) as tar:
        member = next(m for m in tar if m.isfile() and m.name.endswith('engine-sdk/lib/libflutter_engine.so'))
        with engine.open('wb') as output: shutil.copyfileobj(tar.extractfile(member), output)
        header = next(m for m in tar.getmembers() if m.isfile() and m.name.endswith('engine-sdk/include/flutter_embedder.h'))
        with (engine.parent / 'flutter_embedder.h').open('wb') as output: shutil.copyfileobj(tar.extractfile(header), output)
    if digest(engine.parent / 'flutter_embedder.h') != definition['engine']['header_sha256']:
        raise ValueError('Engine embedder header checksum mismatch')
    shutil.copy2(engine.parent / 'flutter_embedder.h', ihs / 'third_party/flutter/shell/platform/embedder/embedder.h')
    prefix = work / 'ihs-runtime'
    run(['cmake', '-S', ihs, '-B', work / 'ihs-build', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=' + str(prefix), *['-D' + k + '=' + v for k, v in definition['ihs']['cmake'].items()]], env=env)
    run(['cmake', '--build', work / 'ihs-build', '-j2'], env=env)
    run(['cmake', '--install', work / 'ihs-build'], env=env)
    run([flutter / 'bin/flutter', 'pub', 'get', '--enforce-lockfile'], cwd=source, env=env)
    run([flutter / 'bin/flutter', 'build', 'linux', '--release', '--no-pub', '--target', 'lib/main.dart'], cwd=source, env=env)
    for directory, features in [('carplay', 'linux-audio,linux-usb'), ('projection', 'linux-media,linux-usb'), ('camera', '')]:
        command = ['cargo', 'build', '--manifest-path', source / 'native' / directory / 'Cargo.toml', '--locked', '--release', '-j2']
        if features: command += ['--features', features]
        if directory == 'projection': command += ['-p', 'argo-projectiond']
        run(command, env=env)
    for directory, name in [('projection/argo-projection-view', 'projection'), ('camera/argo-camera-view', 'camera')]:
        run(['cmake', '-S', source / 'native' / directory, '-B', work / (name + '-view'), '-DCMAKE_BUILD_TYPE=Release', '-DIHS_PREFIX=' + str(prefix), '-DARGO_WITH_SURROUND=OFF'], env={**env, 'IHS_PREFIX': str(prefix)})
        run(['cmake', '--build', work / (name + '-view'), '-j2'], env=env)
        run(['ctest', '--test-dir', work / (name + '-view'), '--output-on-failure'], env=env)
    output = work / 'packages'
    output.mkdir()
    with (output / 'builder-packages.txt').open('w') as stream: run(['dpkg-query', '-W'], stdout=stream)
    notices = work / 'notices'
    run(['python3', HERE / 'collect-notices.py', '--argo', source, '--ihs', ihs,
         '--veloce', veloce, '--engine-license', flutter / 'LICENSE', '--output', notices], env=env)
    run(['python3', HERE / 'package-runtime.py', '--flutter-bundle', source / 'build/linux/x64/release/bundle', '--engine', engine,
         '--ihs', prefix, '--projection-view', work / 'projection-view/libargo_projection_view.so', '--camera-view', work / 'camera-view/libargo_camera_view.so',
         '--notices', notices, '--source-root', source, '--native-root', source / 'native', '--definition', args.definition.resolve(), '--version', definition['version'], '--output', output], env=env)

if __name__ == '__main__': main()
