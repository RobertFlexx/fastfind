#!/usr/bin/env python3
"""Warm-cache, randomized comparison with equivalent, verified result sets.

Uses only Python's standard library. Peak RSS is measured separately with GNU time where available;
startup, traversal and output to /dev/null are all included in elapsed time.
"""
import argparse
import collections
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import time
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('root', type=Path)
    parser.add_argument('runs', nargs='?', type=int, default=20)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--threads', nargs='+', type=int, default=[1, min(8, os.cpu_count() or 1)])
    parser.add_argument('--pattern', default='*', help='same glob for both tools')
    parser.add_argument('--json', type=Path, help='save commands, versions, and measurements')
    args = parser.parse_args()
    if args.runs < 1 or any(n < 1 for n in args.threads):
        parser.error('runs and thread counts must be positive')
    root = args.root.resolve(strict=True)
    if not root.is_dir(): parser.error('root must be a directory')
    fd = shutil.which('fd') or shutil.which('fdfind')
    if not fd: parser.error('fd or fdfind must be installed')
    ff = str(args.binary.resolve(strict=True))
    commands = {}
    tools = [('ff', ff)]
    if args.baseline: tools.insert(0, ('before', str(args.baseline.resolve(strict=True))))
    threads = list(dict.fromkeys(args.threads))
    reference_cmd = [fd, '--no-ignore', '--case-sensitive', '--absolute-path', '--print0',
                     '--threads', '1', '--glob', args.pattern, str(root)]
    reference = subprocess.run(reference_cmd, stdout=subprocess.PIPE, check=True).stdout
    expected = collections.Counter(path.rstrip(b'/') for path in reference.split(b'\0') if path)
    # Byte-safe multisets detect missing paths AND duplicate output, including
    # names containing newlines. Counts alone cannot prove equivalent work.
    for tool, binary in tools:
        for n in threads:
            base = [binary, '--no-config', '-j', str(n), '--glob']
            check_cmd = base + ['--absolute', '--print0', args.pattern, str(root)]
            actual = subprocess.run(check_cmd, stdout=subprocess.PIPE, check=True).stdout
            found = collections.Counter(path for path in actual.split(b'\0') if path)
            if found != expected:
                raise SystemExit(f'refusing unequal results: {tool} -j {n}, '
                                 f'{sum((expected - found).values())} missing, '
                                 f'{sum((found - expected).values())} extra')
            count_cmd = base + ['--count', args.pattern, str(root)]
            count = int(subprocess.run(count_cmd, stdout=subprocess.PIPE, check=True).stdout)
            if count != sum(expected.values()): raise SystemExit(f'wrong count: {tool} -j {n}')
            commands[f'{tool} -j {n} list'] = base + [args.pattern, str(root)]
            commands[f'{tool} -j {n} count'] = count_cmd
    for n in threads:
        commands[f'fd -j {n} list'] = [fd, '--no-ignore', '--case-sensitive', '--threads', str(n),
                                      '--glob', args.pattern, str(root)]
    measurements = {name: [] for name in commands}

    def measure(cmd, null):
        start = time.perf_counter()
        process = subprocess.Popen(cmd, stdout=null)
        if hasattr(os, 'wait4'):
            _, status, usage = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            # ru_maxrss can include the Python parent's pre-exec RSS.
            rss = None
            cpu = usage.ru_utime + usage.ru_stime
        else:
            process.wait()
            rss = cpu = None
        elapsed = time.perf_counter() - start
        if process.returncode: raise subprocess.CalledProcessError(process.returncode, cmd)
        return dict(seconds=elapsed, rss_kib=rss, cpu_seconds=cpu)

    with open(os.devnull, 'wb') as null:
        for _ in range(3):
            for cmd in commands.values(): measure(cmd, null)
        order = list(commands) * args.runs
        random.Random(42).shuffle(order)
        for name in order: measurements[name].append(measure(commands[name], null))
    report = dict(platform=platform.platform(), processors=os.cpu_count(), root=str(root),
                  entries=sum(expected.values()), runs=args.runs, pattern=args.pattern,
                  versions={name: subprocess.run([binary, '--version'], check=True,
                            stdout=subprocess.PIPE).stdout.decode().strip()
                            for name, binary in tools + [('fd', fd)]},
                  results={})
    print(f'{report["entries"]:,} entries · {args.runs} runs · {root}')
    print(f'{"command":25} {"median ms":>10} {"p95 ms":>10} {"peak KiB":>10}')
    for name, samples in measurements.items():
        timings = sorted(sample['seconds'] * 1000 for sample in samples)
        rss_values = []
        # GNU time forks AFTER its own small executable has started, avoiding
        # the parent's large verification buffers in child peak RSS readings.
        if sys.platform.startswith('linux') and Path('/usr/bin/time').exists():
            with tempfile.TemporaryDirectory(prefix='fastfind-rss-') as directory:
                output = Path(directory) / 'rss'
                with open(os.devnull, 'wb') as null:
                    for _ in range(3):
                        subprocess.run(['/usr/bin/time', '-f', '%M', '-o', str(output),
                                        *commands[name]], stdout=null, check=True)
                        rss_values.append(float(output.read_text().strip()))
        median = statistics.median(timings)
        p95 = timings[math.ceil(.95 * len(timings)) - 1]
        peak = max(rss_values) if rss_values else None
        report['results'][name] = dict(command=commands[name], median_ms=median,
                                       p95_ms=p95, peak_rss_kib=peak, samples=samples)
        print(f'{name:25} {median:10.3f} {p95:10.3f} {peak if peak is not None else "n/a":>10}')
    if args.json: args.json.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
