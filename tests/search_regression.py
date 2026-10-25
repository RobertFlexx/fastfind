#!/usr/bin/env python3
"""Search equivalence, bounded counts, and hostile on-disk inputs."""
import collections
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())


def run(*args, env=None, codes=(0,), **kwargs):
    result = subprocess.run([binary, '--no-config', *map(str, args)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=15, env=env, **kwargs)
    assert result.returncode in codes, (args, result.returncode, result.stderr)
    return result.stdout


def paths(root, *args):
    return collections.Counter(run('--absolute', '--print0', *args, root,
                                   codes=(0, 1)).split(b'\0')[:-1])


def varint(value):
    data = bytearray()
    while value >= 128:
        data.append((value & 127) | 128)
        value >>= 7
    data.append(value)
    return bytes(data)


with tempfile.TemporaryDirectory(prefix='fastfind-engine-') as directory:
    root = Path(directory) / 'tree'
    root.mkdir()
    invalid_names = 0
    content_matches = 0
    for i in range(24):
        child = root / f'dir{i:02}'
        child.mkdir()
        for name in ['file.nim', 'FILE.TXT', 'foo', 'bar', 'foobar', '.hidden',
                     'line\nbreak.txt', 'esc\x1b[2J.txt', '日本語.txt', 'bad\udcff.txt']:
            try:
                (child / name).write_bytes(b'needle\n')
            except OSError:
                # APFS rejects invalid UTF-8; Linux/BSD still exercise the
                # byte-preserving JSON path on filesystems that allow it.
                if sys.platform != 'darwin' or name != 'bad\udcff.txt':
                    raise
                continue
            if name == 'bad\udcff.txt':
                invalid_names += 1
            if not name.startswith('.'):
                content_matches += 1
        (child / 'link').symlink_to('file.nim')
        os.mkfifo(child / 'pipe')
    (root / '.secret').mkdir()
    (root / '.secret' / 'secret.txt').touch()
    for flags in [[], ['--hidden'], ['--type', 'file'], ['--type', 'dir'],
                  ['--type', 'link'], ['--one-file-system']]:
        for pattern in ['*', '*.txt', '**', 'file*', '*oo*', '?oo', 'fo?', '[fb]*']:
            expected = paths(root, '-j', '1', '--glob', *flags, pattern)
            for threads in [2, 4, 8, 32]:
                actual = paths(root, '-j', str(threads), '--glob', *flags, pattern)
                assert actual == expected, (threads, pattern, flags, actual - expected, expected - actual)
                count = int(run('-j', str(threads), '--count', '--glob', *flags, pattern, root))
                assert count == sum(expected.values()), (threads, pattern, flags, count)
    # Exercise the shared generic walker and collected results repeatedly;
    # these allocations must be reclaimed before their worker heaps exit.
    for _ in range(12):
        assert paths(root, '-j', '32', '--regex', 'file[.]nim$') == paths(root, '-j', '1', '--regex', 'file[.]nim$')
        collected = json.loads(run('-j', '32', '--json', '--glob', '*', root))
        assert len(collected) == sum(paths(root, '-j', '1', '*').values())
        encoded = [entry for entry in collected if 'pathBytes' in entry]
        assert len(encoded) == invalid_names
        assert all(b'bad\xff.txt' in base64.b64decode(entry['pathBytes']) for entry in encoded)
    assert len(paths(root, '--name', '--regex', '^file[.]nim$')) == 24
    assert len(paths(root, '--name', '--regex', '--full-match', 'foo|bar')) == 48
    for threads in ['1', '4', '8']:
        assert int(run('-j', threads, '--count', '--contains', 'needle', '*', root)) == content_matches
        assert int(run('-j', threads, '--count', '--contains', 'needle', '--limit', '7', '*', root)) == 7
        assert len(paths(root, '-j', threads, '--limit', '7', '*')) == 7
        assert int(run('-j', threads, '--count', '--sort', 'name', '--limit', '7', '*', root)) == 7
    # Count limits span roots, including when the collector stores no matches.
    assert int(run('-j', '4', '--contains', 'needle', '--count', '--limit', '12', '*',
                   root / 'dir00', root / 'dir01')) == 12

    index = Path(directory) / 'index'
    env = dict(os.environ, FASTFIND_INDEX=str(index))
    run('--rebuild-index', root, env=env)
    assert paths(root, '--name', '--regex', '^file[.]nim$') == collections.Counter(
        run('--use-index', '--absolute', '--print0', '--name', '--regex', '^file[.]nim$', root,
            env=env).split(b'\0')[:-1])
    assert paths(root / 'dir00', '*') == collections.Counter(
        run('--use-index', '--absolute', '--print0', '*', root / 'dir00',
            env=env).split(b'\0')[:-1])
    # Crafted traversal and overflowing varints must never supply exec paths.
    encoded_root = os.fsencode(root)
    header = b'FFIDX004' + struct.pack('<QQI', 0, 1, 1) + varint(len(encoded_root)) + encoded_root
    for path in [b'../outside', b'/etc/passwd', b'a/../../outside', b'a\0bad', b'./foo']:
        index.write_bytes(header + b'\0\0\0\0' + varint(len(path)) + path)
        run('--index-only', '--use-index', '*', root, env=env, codes=(2,))
    index.write_bytes(header + b'\xff' * 9 + b'\x02' + b'\0\0\0\x03foo')
    run('--index-only', '--use-index', '*', root, env=env, codes=(2,))
    # A predictable preexisting symlink must not be followed during refresh.
    victim = Path(directory) / 'victim'
    victim.write_text('keep this data')
    subprocess.run([sys.executable, '-c',
                    'import os,sys; os.symlink(sys.argv[3], sys.argv[2]+".tmp."+str(os.getpid())); '
                    'os.execv(sys.argv[1], [sys.argv[1], "--no-config", "--rebuild-index", sys.argv[4]])',
                    binary, str(index), str(victim), str(root)], env=env,
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    assert victim.read_text() == 'keep this data'

    # Shell templates with quotes must treat hostile paths as argument data.
    hostile = Path(directory) / 'shell'
    hostile.mkdir()
    marker = Path(directory) / 'injected'
    evil = hostile / ('poc$(touch injected)`touch injected`\'".txt')
    evil.touch()
    for command in ["printf '%s' {}", "printf '%s' '{}'", 'printf \'%s\' "{}"']:
        result = run('--fixed', 'poc', hostile, '--exec-cmd', command, '--shell', cwd=directory)
        assert result == os.fsencode(evil), (command, result, os.fsencode(evil))
        assert not marker.exists(), 'filename executed shell code'

    # NLP integration checks actual filesystem results, not just parse trees.
    natural = Path(directory) / 'natural'
    natural.mkdir()
    (natural / 'main.py').write_text('TODO and FIXME 123\n')
    (natural / 'config.py').write_text('TODO secret key\n')
    (natural / 'notes.txt').write_text('plain text\n')
    (natural / 'python files').write_text('literal filename\n')
    for name, size in [('small.pdf', 100), ('large.pdf', 300), ('medium.pdf', 200)]:
        (natural / name).write_bytes(b'x' * size)
    assert run('--query', 'two largest PDF files', natural).splitlines() == [b'large.pdf', b'medium.pdf']
    assert run('how many python files', natural).strip() == b'2'
    assert run('--query', 'python files containing TODO and FIXME', natural).strip() == b'main.py'
    assert run('--query', "python files that don't contain 'secret key'", natural).strip() == b'main.py'
    assert run('--fixed', '--full-match', 'python files', natural).strip() == b'python files'
    assert int(run('--query', 'files between one and five megabytes', '--count', natural)) == 0
    for threads in ['1', '8']:
        assert run('-j', threads, '--not-contains', 'secret key', '--glob', '*.py', natural).strip() == b'main.py'
        assert run('-j', threads, '--not-contains', 'needle', '--glob', 'pipe', root, codes=(0, 1)).strip() == b''
    run('--query', "files containing regex '['", natural, codes=(2,))

    empty = natural / 'empty.txt'
    empty.touch()
    assert run('--fixed', 'empty.txt', '--contains-re', '^$', natural).strip() == b'empty.txt'
    folder = natural / 'folder.nim'
    folder.mkdir()
    (folder / 'other.txt').touch()
    regex_paths = run('--regex', r'\.nim', natural).splitlines()
    assert regex_paths == [b'folder.nim'], regex_paths
    assert json.loads(run('--json', '--fixed', 'no-such-result', natural, codes=(1,))) == []

    # Git filtering precedes --limit and indexed --count reflects that filter.
    repo = Path(directory) / 'repo'
    repo.mkdir()
    (repo / 'untracked').touch()
    (repo / 'tracked').touch()
    subprocess.run(['git', 'init', '-q', repo], check=True)
    subprocess.run(['git', '-C', repo, 'add', 'tracked'], check=True)
    for use_index in [[], ['--use-index']]:
        if use_index: run('--rebuild-index', repo, env=env)
        assert int(run(*use_index, '--git-tracked', '--count', '--limit', '1', '*', repo, env=env)) == 1
        assert run(*use_index, '--git-tracked', '--limit', '1', '*', repo, env=env).strip() == b'tracked'

print('Search regression tests passed')
