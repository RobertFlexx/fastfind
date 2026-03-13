# fastfind

## Modern replacement of `find`, focused on speed and sane defaults.
Cross-platform, single binary, zero runtime dependencies (written in Nim).

### (SOFTWARE IS NOT MATURE, EXPECT BUGS!)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Nim](https://img.shields.io/badge/language-Nim-yellow)](https://nim-lang.org/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20BSD-lightgrey)]()

`fastfind`/`ff` is a fast file finder with:

* Glob/regex/fixed/fuzzy matching
* Size/time/content filters
* Git-aware filtering
* Interactive mode
* Optional index-based search
* Semantic symbol search

Official aliases (recommended):

* `ff`
* `ffind`
* `qf`
* `sfind`

(`qf` = quickfind, `sfind` = speed find)

## Installation

### Install latest published binary with
```bash
curl -fsSL https://raw.githubusercontent.com/RobertFlexx/fastfind/main/install.sh | bash
```

### Or build from source

```bash
git clone https://github.com/RobertFlexx/fastfind
cd fastfind
nim c -d:danger -d:release --mm:arc --threads:on -d:lto --opt:speed \
  --passC:-O3 --passC:-march=native --passC:-flto --passL:-flto --passL:-s \
  -o:bin/fastfind src/ff.nim
```

### Install to PATH

```bash
sudo cp bin/fastfind /usr/local/bin/ff
```

## Quick start

```bash
# Find Nim files
ff "*.nim" src/

# Fuzzy match
ff --fuzzy config src/

# Recent files with content
ff "*.py" --changed 24h --contains TODO

# Natural language query
ff "python files containing TODO" src/

# Interactive mode
ff --interactive
```

> for more documentation, use `man ff` (or whatever alias you're using) in the terminal.

## Why fastfind

`find` is extremely powerful, but syntax is heavy and platform behavior differs.

`fd` is excellent for speed and simplicity, but intentionally smaller in scope.

`fzf` is a fuzzy selector, not a filesystem crawler by itself.

`fastfind` sits between these: one command with richer features, while keeping command shape compact.

## Comparison: `ff` vs `find` vs `fd` vs `fzf`

### Ability and feature depth

| Capability | `ff` | `find` | `fd` | `fzf` |
| --- | --- | --- | --- | --- |
| Recursive file discovery | Built-in | Built-in | Built-in | Input-driven (needs producer) |
| Glob/regex/literal modes | Built-in switches | Primarily `-name`/`-regex` forms | Built-in regex/glob modes | Fuzzy/text filtering over input |
| Fuzzy matching | Built-in (`--fuzzy`) | No | No | Core strength |
| Size/time filters | Built-in (`--size`, `--changed`, etc.) | Built-in (`-size`, `-mtime`, etc.) | Built-in (`--size`, `--changed-within`) | Via upstream command only |
| Content filtering | Built-in (`--contains`) | Via `-exec grep`/pipeline | Via `-X grep`/pipeline | Via upstream command only |
| Git-aware file filters | Built-in (`--git-*`) | No | Partial (`--no-ignore-vcs`, etc.) | No |
| Interactive picker | Built-in (`--interactive`, `--select`) | No | No | Core strength |
| Index mode | Built-in (`--use-index`) | No | No | No |
| Semantic symbol search | Built-in (`--function`, `--class`, `--symbol`) | No | No | No |

### Ease of use (common tasks)

| Task | `ff` | `find` | `fd` | `fzf` |
| --- | --- | --- | --- | --- |
| Find all `*.nim` files | `ff "*.nim"` | `find . -type f -name '*.nim'` | `fd --glob '*.nim'` | `find . -type f \| fzf --filter '.nim'` |
| Files changed in 1 day | `ff "*.nim" --changed 1d` | `find . -type f -name '*.nim' -mtime -1` | `fd --changed-within 1day --glob '*.nim'` | `find ... -mtime -1 \| fzf --filter '.nim'` |
| Find files containing TODO | `ff "*.py" --contains TODO` | `find ... -exec grep -l TODO {} +` | `fd --glob '*.py' -X grep -l TODO` | `find ... \| xargs grep -l TODO \| fzf` |

Short version:

* `find`: extremely low level, highest syntax overhead.
* `fd`: easiest for common name/path filters.
* `fzf`: best interactive selector when you already have an input stream.
* `ff`: broad feature set in one tool.

### Performance and speed

All measurements below were run by executing commands repeatedly on the same local dataset.

Benchmark dataset:

* 30,000 files
* Nested directory tree (`200 x 150`)
* Mixed extensions (`.txt`, `.md`, `.py`, `.js`, `.nim`, `.json`, `.yaml`, `.log`, `.cfg`)
* Controlled keyword distribution (`config`, `cache`, `build`, etc.)

System specs:

* OS: Linux `6.19.6-2-cachyos` (x86_64)
* CPU: Intel Core i9-11900KF (performance power profile) (8C/16T, up to 5.3 GHz)
* RAM: 16 GB DDR4
* Tool versions: `ff 1.0.0`, `findutils 4.10.0`, `fd 10.4.2`, `fzf 0.70.0`

#### Filename glob benchmark (`*.nim`, 15 runs, lower is better)

| Tool | Mean (ms) | Median (ms) | Std Dev (ms) |
| --- | ---: | ---: | ---: |
| `ff '*.nim' .benchdata` | 8.89 | 8.60 | 1.37 |
| `fd --glob '*.nim' .benchdata` | 9.97 | 9.37 | 2.10 |
| `find .benchdata -type f -name '*.nim'` | 13.01 | 12.69 | 1.03 |

#### Substring name benchmark (`config`, 15 runs)

| Tool | Mean (ms) | Median (ms) | Std Dev (ms) |
| --- | ---: | ---: | ---: |
| `ff --fixed config .benchdata` | 7.32 | 7.22 | 1.14 |
| `fd 'config' .benchdata` | 9.14 | 9.18 | 0.81 |
| `find .benchdata -type f -name '*config*'` | 12.51 | 12.57 | 0.78 |
| `find ... \| fzf --filter config` | 13.56 | 13.48 | 1.28 |

#### Time/content filters (12 runs)

| Task | `ff` mean (ms) | `fd` mean (ms) | `find` mean (ms) |
| --- | ---: | ---: | ---: |
| Mtime (`*.nim` in last day) | 9.05 | 10.37 | 15.18 |
| Content (`TODO` in `*.py`) | 9.27 (`--contains`) | 18.73 (`fd ... -X grep`) | 22.75 (`find ... -exec grep`) |

Notes:

* `fzf` is very fast at filtering, but it needs a producer command (`find`, `fd`, etc.).
* These are warm-cache local numbers. Run your own benchmarks to make your choice.

## Use cases

Use `ff` when:

* You want one command for name, size/time, content, and git filters.
* You need fuzzy file lookup without wiring pipelines.
* You want interactive selection and direct output from the same tool.
* You want optional index-based search for repeated lookups.
* You need semantic symbol discovery (`--function`, `--class`, `--symbol`) without launching a language server.

Use something else when:

* Choose `find` for highly specialized POSIX expression logic or legacy scripts that already rely on it.
* Choose `fd` for minimal syntax and very fast everyday filename/path lookup.
* Choose `fzf` when you already have a candidate list and want the best interactive narrowing.

## Usage

```text
ff [OPTIONS] <pattern> [path ...]
ff "<natural language query>" [path ...]
```

### High-value flags

| Area | Flags |
| --- | --- |
| Match mode | `--glob`, `--regex`, `--fixed`, `--fuzzy` |
| Path mode | `--name`, `--full-path`, `--full-match` |
| Traversal | `-H`, `-L`, `-x`, `--gitignore`, `--max-depth`, `-j` |
| Filters | `--type`, `--size`, `--changed`, `--contains`, `--exclude` |
| Git | `--git-modified`, `--git-untracked`, `--git-tracked`, `--git-changed` |
| Output | `--long`, `--json`, `--ndjson`, `--table`, `--sort`, `--limit`, `--stats` |
| Interactive/index | `--interactive`, `--select`, `--use-index`, `--rebuild-index` |

### More examples

```bash
# Big logs, newest first
ff "*.log" --size ">100M" --sort time --reverse

# Changed Python files tracked by git
ff "*.py" --git-modified --changed 7d

# Symbol search
ff --function parse src/

# Interactive select, then open with editor
ff "*.nim" --select --exec "vim {}"
```

## Important repository files

If you are reading the codebase, start here:

* Entry point: [`src/ff.nim`](src/ff.nim)
* CLI parsing/config: [`src/ff/cli.nim`](src/ff/cli.nim)
* Search engine: [`src/ff/search.nim`](src/ff/search.nim)
* Core types: [`src/ff/core.nim`](src/ff/core.nim)
* Output formatting: [`src/ff/output.nim`](src/ff/output.nim)
* Fuzzy matcher: [`src/ff/fuzzy.nim`](src/ff/fuzzy.nim)
* Index support: [`src/ff/index.nim`](src/ff/index.nim)
* Interactive UI: [`src/ff/interactive.nim`](src/ff/interactive.nim)
* Semantic search: [`src/ff/semantic.nim`](src/ff/semantic.nim)
* Package metadata: [`fastfind.nimble`](fastfind.nimble)
* Binary output dir: [`bin/`](bin/)

Project docs:

* Contributing guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)
* Security policy: [`SECURITY.md`](SECURITY.md)
* Code of conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)

## Platform support

* Linux: full support
* macOS: full support
* BSD: full support
* Windows: partial support (interactive/index behavior may differ)

## Contributing

Contributions are welcome.

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) first.

## Security

Please report vulnerabilities using [`SECURITY.md`](SECURITY.md).

## License

MIT License. See [`LICENSE`](LICENSE).

