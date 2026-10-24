# 2.5.0 measurement record

Host: Linux 7.2.11-366.current, Intel Core i7-9700, eight physical cores.
Nim 2.2.0, ORC, GCC and LTO; fd 10.5.0. The baseline is commit
`5fd4556b85723c69f352c31cd2612f3ab379b171` (2.4.0).

Both binaries were built with the same options:

```sh
nim c --mm:orc --threads:on -d:release --opt:speed \
  --passC:-flto --passL:-flto -o:/tmp/fastfind-candidate src/ff.nim
```

Synthetic tree: 200 top-level directories, ten subdirectories per directory,
50 empty `.txt` files per subdirectory: 100,000 files, 2,200 directories.

```python
from pathlib import Path
root = Path('/tmp/fastfind-perf-tree')
for group in range(200):
    for sub in range(10):
        directory = root / f'group{group:03}' / f'sub{sub:02}'
        directory.mkdir(parents=True, exist_ok=True)
        for number in range(50):
            (directory / f'file{number:03}.txt').touch()
```

Commands:

```sh
python3 benchmarks/compare_fd.py /tmp/fastfind-candidate \
  /tmp/fastfind-perf-tree 30 --baseline /tmp/fastfind-baseline --json tree.json
python3 benchmarks/compare_fd.py /tmp/fastfind-candidate \
  /usr 20 --baseline /tmp/fastfind-baseline --json usr.json
```

The harness verifies NUL-delimited filename multisets before timing, compares
the same explicit thread counts, warms each command three times, randomizes
timing order, and includes process startup and output to `/dev/null`. All
searches are live, visible-entry glob searches with ignore rules disabled.
Peak RSS is the largest of three separate GNU time runs; `wait4.ru_maxrss`
alone can incorrectly include Python's pre-exec verification buffers.

| Dataset | Command | Median ms | p95 ms | Peak KiB |
| --- | --- | ---: | ---: | ---: |
| 102,200 entries | before -j 1 list | 20.026 | 20.502 | 3496 |
| | ff -j 1 list | 19.393 | 19.658 | 2956 |
| | fd -j 1 list | 88.798 | 91.611 | 5400 |
| | before -j 8 list | 19.881 | 20.275 | 3524 |
| | ff -j 8 list | 3.774 | 4.042 | 3624 |
| | fd -j 8 list | 18.729 | 19.745 | 8564 |
| | ff -j 1 count | 17.108 | 17.590 | 3000 |
| | ff -j 8 count | 3.485 | 4.164 | 3520 |
| 314,814 `/usr` entries | before -j 1 list | 118.745 | 119.719 | 3440 |
| | ff -j 1 list | 117.711 | 119.209 | 3000 |
| | fd -j 1 list | 342.468 | 347.592 | 10056 |
| | before -j 8 list | 118.618 | 119.797 | 3640 |
| | ff -j 8 list | 26.388 | 27.142 | 4808 |
| | fd -j 8 list | 53.895 | 54.999 | 19028 |
| | ff -j 1 count | 105.364 | 106.341 | 2912 |
| | ff -j 8 count | 24.479 | 25.428 | 3724 |

These are warm-cache traversal measurements on one host. Cold storage,
directory shape, output destination, Git ignore rules, content/metadata
filters and result collection can change the relative performance. The
count rows measure a distinct workload; fd has no directly equivalent native
count operation. Small serial count differences are within normal run noise.
