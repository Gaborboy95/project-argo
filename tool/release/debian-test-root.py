#!/usr/bin/env python3
"""Fetch a digest-pinned public Debian OCI filesystem for disposable tests."""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import tarfile
import urllib.request

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', required=True, help='sha256 digest of linux/amd64 manifest')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.exists(): p.error('Output must be a fresh directory')
    token = json.load(urllib.request.urlopen('https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull', timeout=30))['token']
    def get(kind, digest):
        request = urllib.request.Request('https://registry-1.docker.io/v2/library/debian/' + kind + '/' + digest, headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.oci.image.manifest.v1+json'})
        with urllib.request.urlopen(request, timeout=60) as response: data = response.read()
        if 'sha256:' + hashlib.sha256(data).hexdigest() != digest: raise ValueError('OCI digest mismatch')
        return data
    manifest = json.loads(get('manifests', args.manifest))
    config = json.loads(get('blobs', manifest['config']['digest']))
    if config['architecture'] != 'amd64' or config['os'] != 'linux': raise ValueError('Expected linux/amd64')
    args.output.mkdir(parents=True)
    for index, layer in enumerate(manifest['layers']):
        data = get('blobs', layer['digest'])
        archive = args.output.parent / f'{args.output.name}-layer-{index}.tar.gz'
        archive.write_bytes(data)
        with tarfile.open(archive) as tar:
            def safe(member, destination):
                if member.isdev(): return None
                if member.issym() and member.linkname.startswith('/'):
                    member.linkname = posixpath.relpath(member.linkname.lstrip('/'), posixpath.dirname(member.name))
                return tarfile.data_filter(member, destination)
            tar.extractall(args.output, filter=safe)
    (args.output.parent / (args.output.name + '-provenance.json')).write_text(json.dumps({'manifest': args.manifest, 'config': manifest['config'], 'layers': manifest['layers']}, indent=2) + '\n')

if __name__ == '__main__': main()
