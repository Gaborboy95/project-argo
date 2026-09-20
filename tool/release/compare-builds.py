#!/usr/bin/env python3
"""Compare complete Debian artifacts and identify differing installed files."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = {'link': str(path.readlink())}
        elif path.is_file():
            result[name] = {'sha256': sha(path), 'mode': oct(path.stat().st_mode & 0o7777)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first', type=Path)
    parser.add_argument('second', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='argo-reproducibility-') as directory:
        root = Path(directory)
        for name, package in [('first', args.first), ('second', args.second)]:
            subprocess.run(['dpkg-deb', '--raw-extract', str(package.resolve()), str(root / name)], check=True)
        first, second = inventory(root / 'first'), inventory(root / 'second')
        differences = [{'path': name, 'first': first.get(name), 'second': second.get(name)}
                       for name in sorted(first.keys() | second.keys()) if first.get(name) != second.get(name)]
    a, b = sha(args.first), sha(args.second)
    report = {'equal': a == b, 'first_sha256': a, 'second_sha256': b,
              'installed_files_equal': not differences, 'differences': differences}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report, indent=2, sort_keys=True))
    raise SystemExit(0 if a == b else 1)


if __name__ == '__main__':
    main()
