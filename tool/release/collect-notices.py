#!/usr/bin/env python3
"""Collect source license files plus exact Rust dependency metadata for a build."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import urllib.parse

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--argo', type=Path, required=True)
    p.add_argument('--ihs', type=Path, required=True)
    p.add_argument('--veloce', type=Path, required=True)
    p.add_argument('--engine-license', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    index = []
    def collect(name, source):
        files = [f for f in source.iterdir() if f.is_file() and f.name.lower().startswith(('license', 'licence', 'copying', 'copyright', 'notice'))]
        if not files:
            files = [f for f in source.glob('*/*') if f.is_file() and f.name.lower().startswith(('license', 'licence', 'copying', 'copyright', 'notice')) and '.git' not in f.parts]
        files = sorted(files)
        for file in files:
            destination = a.output / name / file.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
        return [f.name for f in files]
    for tree in ['carplay', 'projection', 'camera']:
        result = subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version=1', '--filter-platform=x86_64-unknown-linux-gnu', '--manifest-path', str(a.argo / 'native' / tree / 'Cargo.toml'), *(['--features', {'carplay': 'linux-audio,linux-usb', 'projection': 'linux-media,linux-usb'}[tree]] if tree != 'camera' else [])], text=True)
        for item in json.loads(result)['packages']:
            name = 'rust/' + item['name'] + '-' + item['version']
            files = collect(name, Path(item['manifest_path']).parent)
            destination = a.output / name
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item['manifest_path'], destination / 'Cargo.toml')
            index.append({'component': name, 'source': item['source'], 'license': item['license'], 'files': files})
    config = json.loads((a.argo / '.dart_tool/package_config.json').read_text())
    for item in config['packages']:
        uri = urllib.parse.urljoin((a.argo / '.dart_tool/package_config.json').resolve().as_uri(), item['rootUri'])
        source = Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
        index.append({'component': 'dart/' + item['name'], 'files': collect('dart/' + item['name'], source)})
    for name, path in [('ihs', a.ihs), ('veloce', a.veloce), ('argo', a.argo)]:
        index.append({'component': name, 'files': collect(name, path)})
    for path in sorted((a.ihs / 'third_party').iterdir()):
        if path.is_dir(): index.append({'component': 'ihs/' + path.name, 'files': collect('ihs/' + path.name, path)})
    lua = a.veloce / 'packages/veloce_lua_native/third_party/lua/src/lua.h'
    if lua.exists():
        (a.output / 'lua').mkdir(exist_ok=True)
        shutil.copy2(lua, a.output / 'lua/lua-header-with-license.txt')
    for license_file in a.engine_license.parent.glob('bin/cache/artifacts/engine/linux-x64-release/LICENSE*'):
        shutil.copy2(license_file, a.output / license_file.name)
    shutil.copy2(a.engine_license, a.output / 'engine-archive-license.txt')
    shutil.copytree(Path(__file__).parent / 'notices', a.output / 'supplemental', dirs_exist_ok=True)
    shutil.copy2('/usr/share/common-licenses/Apache-2.0', a.output / 'supplemental/Apache-2.0.txt')
    (a.output / 'index.json').write_text(json.dumps(index, indent=2, sort_keys=True) + '\n')

if __name__ == '__main__': main()
