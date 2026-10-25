#!/usr/bin/env python3
"""Prepare target-specific C; every object and executable is built in its VM."""
import argparse
import hashlib
import json
import re
import shlex
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

PCRE_COMMIT = 'c52be808155d837c54fd1bfde3d2b21e4d8900f7'
PCRE_SHA256 = '671f5333b12a1f7327e05e3ce2ce894dbc6c8750befcd0142f9150843fa9dd46'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('build/native'))
    parser.add_argument('--targets', nargs='+', default=['solaris', 'dragonfly'])
    parser.add_argument('--pcre-archive', type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    dump = json.loads(subprocess.check_output(['nim', 'dump', '--dump.format:json', 'src/ff.nim']))
    shutil.copyfile(Path(dump['libpath']) / 'nimbase.h', root / 'nimbase.h')
    (root / 'NIM-VERSION.txt').write_bytes(subprocess.check_output(['nim', '--version']))
    for target in args.targets:
        if target not in ['linux', 'solaris', 'dragonfly']:
            parser.error('unsupported C target: ' + target)
        for name, source, threads in [
            ('ff', 'src/ff.nim', 'on'), ('ff-serial', 'src/ff.nim', 'off'),
            ('test_nlp', 'tests/test_nlp.nim', 'on'),
            ('test_engine', 'tests/test_engine.nim', 'on'),
            ('test_tui_input', 'tests/test_tui_input.nim', 'on'),
        ]:
            cache = root / target / name
            subprocess.run(['nim', 'c', '--compileOnly', '--mm:orc', '--threads:' + threads,
                            '--os:' + target, '--cpu:amd64', '-d:release',
                            '-d:usePcreHeader', '--opt:speed', '--nimcache:' + str(cache),
                            source], check=True)
            manifest = json.loads(next(cache.glob('*.json')).read_text())
            libraries = [arg for arg in shlex.split(manifest['linkcmd'])
                         if re.fullmatch(r'-l[A-Za-z0-9_.+-]+', arg)]
            (cache / 'LINK-LIBRARIES.txt').write_text(' '.join(libraries) + '\n')
    archive = args.pcre_archive or root / 'pcre.tar.gz'
    if not args.pcre_archive:
        url = 'https://codeload.github.com/PCRE2Project/pcre1/tar.gz/' + PCRE_COMMIT
        with urllib.request.urlopen(url, timeout=60) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PCRE_SHA256:
        raise ValueError('PCRE digest mismatch')
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if (not parts or '..' in parts or member.name.startswith('/') or
                    not (member.isfile() or member.isdir())):
                raise ValueError('unsafe PCRE source member')
        tar.extractall(root)
    pcre = root / ('pcre1-' + PCRE_COMMIT)
    destination = root / 'pcre'
    if destination.exists():
        shutil.rmtree(destination)
    pcre.rename(destination)
    # Generate the portable configure script on the host. The VM performs
    # all platform detection and builds the library with its own compiler.
    subprocess.run(['autoreconf', '--force', '--install'], cwd=destination, check=True)
    shutil.rmtree(destination / 'autom4te.cache', ignore_errors=True)
    (root / 'PCRE-SOURCE.txt').write_text(PCRE_COMMIT + '\n' + PCRE_SHA256 + '\n')
    print('Prepared native C bundles:', ', '.join(args.targets))


if __name__ == '__main__':
    main()
