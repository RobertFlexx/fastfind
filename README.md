# fastfind 2.1.0

## Modern replacement for `find`, with more features than fd but slightly different performance characteristics.

Find Nim files:

```
ff "*.nim"
```

Find Python files changed in the last day containing TODO:

```
ff "*.py" --changed 1d --contains TODO
```

Interactive fuzzy search:

```
ff --interactive
```

---

## Performance Benchmarks

| Command | Time | Notes |
|---------|------|-------|
| `ff "*" /` | ~0.54s | Fastest mode (single-thread) |
| `ff "*" / -H` | ~0.71s | With hidden files |
| `ff "*" / -j 8` | ~1.2s | Parallel mode (slower!) |
| `fd . /` | ~0.30s | Reference |
| `fd . / -H` | ~0.36s | Reference with hidden |

**Key insight:** The single-thread fast path is faster than parallel mode. Use default (no `-j` flag) for best performance.

### Parallel Mode Performance

**Important:** The parallel mode (`-j N`) is generally *slower* than single-thread for simple recursive listing. This is because:

1. **Threading overhead** - Parallel mode adds synchronization overhead that hurts performance for simple recursive listing
2. **I/O-bound workload** - Directory traversal is I/O-limited, not CPU-limited; threading doesn't help
3. **Per-entry allocations** - Parallel path does more string allocation

| Configuration | Time | Recommendation |
|---------------|------|----------------|
| Default (no `-j`) | ~0.54s | **Recommended** |
| `-j 1` | ~0.54s | Same as default |
| `-j 4` | ~1.4s | Slower |
| `-j 8` | ~1.2s | Slower |

**When to use parallel mode:**
- Content search (`--contains`)
- Complex regex patterns
- Heavy filtering workloads
- When CPU work per file is high

For simple filename search, always use the default (no `-j` flag).

---

## Below is more information on fastfind. Read below to learn how to install, use, and/or compile this software.

Cross-platform, single binary, zero runtime dependencies (written in Nim).

### (SOFTWARE IS NOT MATURE, EXPECT BUGS!)

⚠ fastfind is still early in development.
Expect occasional bugs or behavioral changes.

> Below is software supported, and software used in this project. click on any to be redirected to respected website.

[![License: MIT](https://img.shields.io/badge/License-MIT-1f6feb?style=for-the-badge)](LICENSE)
[![Language: Nim](https://img.shields.io/badge/Language-Nim-FFC200?style=for-the-badge&logo=nim&logoColor=black)](https://nim-lang.org/)
[![Linux](https://img.shields.io/badge/Linux-Supported-2ea44f?style=for-the-badge&logo=linux&logoColor=white)](https://www.kernel.org/)
[![macOS](https://img.shields.io/badge/macOS-Supported-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![FreeBSD](https://img.shields.io/badge/FreeBSD-Supported-2ea44f?style=for-the-badge&logo=freebsd&logoColor=white)](https://www.freebsd.org/)
[![OpenBSD](https://img.shields.io/badge/OpenBSD-Supported-2ea44f?style=for-the-badge&logo=openbsd&logoColor=white)](https://www.openbsd.org/)
[![NetBSD](https://img.shields.io/badge/NetBSD-Supported-2ea44f?style=for-the-badge&logo=netbsd&logoColor=white)](https://www.netbsd.org/)

`fastfind`/`ff` is a fast file finder with:

* Glob/regex/fixed/fuzzy matching
* Natural language queries (BETA)
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

### Quick install

Install latest published binary with

```bash
curl -fsSL https://raw.githubusercontent.com/RobertFlexx/fastfind/main/install.sh | bash
```
For some BSDs or Linux Distributions:
```bash
curl -fsSL https://raw.githubusercontent.com/RobertFlexx/fastfind/main/install.sh | sh
```

### Update

Update to the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/RobertFlexx/fastfind/main/update.sh | bash
```

* The update script checks your current version and only downloads if there's a new release.

* DISCLAIMER: binaries for other OSes, or musl libc Linux distributions may not ALWAYS be available. Primarily glibc Linux with architecture x86_64.
* HINT: there are dynamic binaries for: FreeBSD[amd64], OpenBSD[amd64], NetBSD[amd64], Darwin[arm64], Linux[glibc, amd64] (may not be immediately available for newly released versions)
### Or build from source (recommended for best performance)

```bash
git clone https://github.com/RobertFlexx/fastfind
cd fastfind
nim c -d:danger -d:release --mm:orc --threads:on -d:lto --opt:speed \
  --passC:-O3 --passC:-march=native --passC:-flto --passL:-flto --passL:-s \
  -o:bin/fastfind src/ff.nim
```

Nushell:

```nu
git clone https://github.com/RobertFlexx/fastfind
cd fastfind
nim c '-d:danger' '-d:release' '--mm:orc' '--threads:on' '-d:lto' '--opt:speed' '--passC:-O3' '--passC:-march=native' '--passC:-flto' '--passL:-flto' '--passL:-s' '-o:bin/fastfind' src/ff.nim
```

#### Build Flags Explained

| Flag | Purpose | Recommended |
|------|---------|--------------|
| `-d:danger` | Remove debug checks, runtime validation | ✅ Required for speed |
| `-d:release` | Enable compiler optimizations | ✅ Required |
| `--mm:orc` | Memory manager (orc = best balance, arc = low memory) | Use `orc` |
| `--threads:on` | Enable multi-threading support | ✅ Required |
| `-d:lto` | Enable link-time optimization | ✅ Required |
| `--opt:speed` | Optimize for speed not size | ✅ Required |
| `--passC:-O3` | C compiler optimization level 3 | ✅ Required |
| `--passC:-march=native` | Optimize for this CPU | ✅ Required |
| `--passC:-flto` | C compiler LTO | ✅ Required |
| `--passL:-flto` | Linker LTO | ✅ Required |
| `--passL:-s` | Strip symbols (smaller binary) | Optional |

#### Build for Different Systems (COMPILE WITH THREADS ON FOR FULL PERFORMANCE)

**For distribution, very optimized build (generic binary):**
```bash
nim c -d:danger -d:release --mm:orc --threads:on -d:lto --opt:speed \
  --passC:-O3 --passC:-march=x86-64 --passC:-flto --passL:-flto --passL:-s \
  -o:bin/fastfind src/ff.nim
```

Nushell:

```nu
nim c '-d:danger' '-d:release' '--mm:orc' '--threads:on' '-d:lto' '--opt:speed' '--passC:-O3' '--passC:-march=x86-64' '--passC:-flto' '--passL:-flto' '--passL:-s' '-o:bin/fastfind' src/ff.nim
```

**Debug build (for testing):**
```bash
nim c --threads:on -o:bin/fastfind_debug src/ff.nim
```

Nushell:

```nu
nim c '--threads:on' '-o:bin/fastfind_debug' src/ff.nim
```

**Production build (balanced):**
```bash
nim c -d:danger -d:release --mm:arc --threads:on --opt:speed \
  -o:bin/fastfind src/ff.nim
```

Nushell:

```nu
nim c '-d:danger' '-d:release' '--mm:arc' '--threads:on' '--opt:speed' '-o:bin/fastfind' src/ff.nim
```

### Install to PATH

```bash
sudo cp bin/fastfind /usr/local/bin/ff
```

## Troubleshooting

### libpcre.so error

If you see this error when running `ff`:
```
could not load: libpcre.so
```

First, check which library your binary actually needs:

```bash
ldd "$(command -v ff)" | rg -i pcre
```

Then install the matching runtime package for your distro:

| OS/Distro | Package Name | Install Command |
|-----------|--------------|------------------|
| **Ubuntu/Debian** | libpcre3 | `sudo apt install libpcre3` |
| **Fedora/RHEL/CentOS (current repos)** | pcre2 | `sudo dnf install pcre2` |
| **Arch Linux** | pcre (legacy `libpcre.so.*`) | `sudo pacman -S pcre` |
| **openSUSE** | libpcre1 | `sudo zypper install libpcre1` |
| **Alpine Linux** | pcre | `doas apk add pcre` |
| **macOS** | pcre (via brew) | `brew install pcre` |
| **FreeBSD** | pcre | `sudo pkg install pcre` |
| **OpenBSD** | pcre | `doas pkg_add pcre` |

If you still see an error for a specific SONAME (for example `libpcre.so.3`), query which package provides it:
```bash
sudo dnf provides '*/libpcre.so*'
```

On Fedora/RHEL 10+, legacy PCRE1 (`libpcre.so.*`) is no longer in default repos. If your binary was built against PCRE1, use a static release binary or rebuild against currently available libraries.
On Arch, `pcre` is available but deprecated upstream; new builds should prefer PCRE2.

> **Tip**: Using static builds from the release page avoids this dependency issue entirely.

### RHEL 10 / EL10 PCRE Issue

If you encounter this error on RHEL 10, EL10, or modern Fedora-like systems:

```
could not load: libpcre.so(.3|.1|)
```

**Root Cause:** The binary depends on legacy PCRE1 (`libpcre.so.1` / `libpcre.so.3`). RHEL 10+ and similar distributions no longer provide PCRE1 in default repositories. Installing `pcre2` does NOT fix the issue because it is ABI-incompatible.

**Workaround with Homebrew (Linuxbrew):**

1. Install PCRE:
   ```bash
   brew install pcre
   ```

2. Run with the library path:
   ```bash
   LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib ff
   ```

**Permanent Fix:**

- **Option A:** Add to your shell config (`~/.bashrc`, `~/.zshrc`, etc.):
  ```bash
  export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib:$LD_LIBRARY_PATH
  ```

- **Option B (recommended):** Create a wrapper script:
  ```bash
  sudo mv /usr/local/bin/ff /usr/local/bin/ff.real
  sudo tee /usr/local/bin/ff >/dev/null <<'EOF'
  #!/usr/bin/env bash
  export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib:${LD_LIBRARY_PATH:-}
  exec /usr/local/bin/ff.real "$@"
  EOF
  sudo chmod +x /usr/local/bin/ff
  ```

**Verification:**
```bash
LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib ff
```
If `ff` runs successfully, the issue is resolved.

> **Note for developers:** Rebuild without PCRE1 dependency or use static builds. Consider migrating away from runtime `dlopen` of PCRE1.

### Scanning Root Directory Performance Issue

When scanning `/` (root directory), `ff` may find fewer files and run slower compared to `fd`:

```
$ time ff . / -j 8 -H | wc     # ~690k files
$ time fd . / | wc            # ~1.1M files
```

**Root Cause:** The code has several issues when scanning large directory trees like `/`:

1. **Gitignore overhead:** When `--gitignore` is enabled (default on home directories), it searches for `.git` repositories from the root up, adding processing overhead.
2. **Pattern matching with large result sets:** When searching for `.` (match all), the matcher still iterates through all patterns for every file.
3. **Missing `/proc`, `/sys`, `/dev` handling:** Special files in `/proc`, `/sys`, `/dev` may cause errors or get skipped inconsistently.

**Workaround:** Use specific patterns instead of `.` to match all files:

```bash
ff "*" /     # Explicit glob pattern
ff --glob "*" /   # More explicit
```

Or exclude problematic paths:

```bash
ff "*" / --exclude "/proc/*" --exclude "/sys/*" --exclude "/dev/*"
```

**Note:** This issue may be more pronounced with threading enabled (`-j`). Future versions should optimize for the "match all" case and handle system directories better.

## Quick start

```bash
# Find Nim files
ff "*.nim" src/

# Fuzzy match
ff --fuzzy config src/

# Content search
ff "*.py" --contains TODO

# Natural language query
ff "python files containing TODO"

# Interactive mode
ff --interactive
```

## Natural language queries (BETA)

`fastfind` can interpret simple natural language queries and translate them into filters automatically.

Examples:

```bash
ff "python files containing TODO"
ff "large log files modified today"
ff "config files bigger than 10MB"
```

⚠ This feature is currently experimental and may change in future releases.

> for more documentation, use `man ff` (or whatever alias you're using) in the terminal.

## Why fastfind

`find` is extremely powerful, but syntax is heavy and platform behavior differs.

`fd` is excellent for speed and simplicity, but intentionally smaller in scope.

`fzf` is a fuzzy selector, not a filesystem crawler by itself.

`fastfind` sits between these: one command with richer features, while keeping command shape compact.

fastfind aims to combine the strengths of several tools:

* `find`: extremely powerful but complex
* `fd`: simple and fast but limited scope
* `fzf`: great interactive filtering but requires input pipelines

fastfind provides:

* a single consistent command
* built-in fuzzy and content search
* interactive mode
* semantic code queries
* optional indexed search

## Comparison: `ff` vs `find` vs `fd` vs `fzf`

### Ability and feature depth

| Capability               | `ff`                                           | `find`                             | `fd`                                    | `fzf`                           |
| ------------------------ | ---------------------------------------------- | ---------------------------------- | --------------------------------------- | ------------------------------- |
| Recursive file discovery | Built-in                                       | Built-in                           | Built-in                                | Input-driven (needs producer)   |
| Glob/regex/literal modes | Built-in switches                              | Primarily `-name`/`-regex` forms   | Built-in regex/glob modes               | Fuzzy/text filtering over input |
| Fuzzy matching           | Built-in (`--fuzzy`)                           | No                                 | No                                      | Core strength                   |
| Natural language queries | Built-in (BETA)                                | No                                 | No                                      | No                              |
| Size/time filters        | Built-in (`--size`, `--changed`, etc.)         | Built-in (`-size`, `-mtime`, etc.) | Built-in (`--size`, `--changed-within`) | Via upstream command only       |
| Content filtering        | Built-in (`--contains`)                        | Via `-exec grep`/pipeline          | Via `-X grep`/pipeline                  | Via upstream command only       |
| Git-aware file filters   | Built-in (`--git-*`)                           | No                                 | Partial (`--no-ignore-vcs`, etc.)       | No                              |
| Interactive picker       | Built-in (`--interactive`, `--select`)         | No                                 | No                                      | Core strength                   |
| Index mode               | Built-in (`--use-index`)                       | No                                 | No                                      | No                              |
| Semantic symbol search   | Built-in (`--function`, `--class`, `--symbol`) | No                                 | No                                      | No                              |

### Ease of use (common tasks)

| Task                       | `ff`                        | `find`                                   | `fd`                                      | `fzf`                                       |
| -------------------------- | --------------------------- | ---------------------------------------- | ----------------------------------------- | ------------------------------------------- |
| Find all `*.nim` files     | `ff "*.nim"`                | `find . -type f -name '*.nim'`           | `fd --glob '*.nim'`                       | `find . -type f \| fzf --filter '.nim'`     |
| Files changed in 1 day     | `ff "*.nim" --changed 1d`   | `find . -type f -name '*.nim' -mtime -1` | `fd --changed-within 1day --glob '*.nim'` | `find ... -mtime -1 \| fzf --filter '.nim'` |
| Find files containing TODO | `ff "*.py" --contains TODO` | `find ... -exec grep -l TODO {} +`       | `fd --glob '*.py' -X grep -l TODO`        | `find ... \| xargs grep -l TODO \| fzf`     |

## Performance and speed

All measurements below were run by executing commands repeatedly on the same local dataset.

Benchmark dataset:

* 20,000 files across 100 directories
* Tests run with `--warmup 3 --runs 20` using hyperfine

System specs:

* OS: Linux `6.19.12-1.el10.elrepo.x86_64` (Red Hat Enterprise Linux 10.1)
* CPU: Intel Core i7-9700 (8 cores @ 3.00GHz)
* RAM: 16 GB DDR4
* Tool versions: `ff 2.1.0`, `fd 10.4.2`, `find 4.9.0`

---

### Glob Patterns

| Pattern | ff (ms) | fd (ms) | find (ms) | Winner |
|---------|--------:|--------:|----------:|--------|
| `*.txt` | 8.1 | 7.5 | 10.4 | fd (+8% faster) |
| All files (`*`) | 14.6 | 7.1 | 7.3 | fd (2x faster) |

### With Type Filter

| Pattern | ff (ms) | fd (ms) | find (ms) | Winner |
|---------|--------:|--------:|----------:|--------|
| `*.txt -t f` | 12.4 | 7.2 | 10.7 | fd (+72% faster) |

### Content Search

| Command | ff (ms) | fd+grep (ms) | find+grep (ms) | Winner |
|---------|--------:|-------------:|---------------:|--------|
| `*.py --contains TODO` | 11.5 | 7.4 | 11.6 | fd (+56% faster) |

### Regex Patterns

| Pattern | ff (ms) | fd (ms) | find (ms) | Winner |
|---------|--------:|--------:|----------:|--------|
| `.*\.txt$` | 15.2 | 7.3 | 10.6 | fd (2x faster) |

### Single-thread vs Parallel

| Command | Time (ms) | Notes |
|---------|----------:|-------|
| `ff "*"` (default) | 14.6 | **Fastest** |
| `ff "*" -j 4` | 22.7 | 55% slower |
| `ff "*" -j 8` | 22.9 | 56% slower |

---

### Summary

- **fd is faster** - particularly for glob patterns and all-files traversal (2x faster)
- **ff single-thread** - faster than ff parallel mode (use default, no `-j`)
- **ff built-in content search** - simpler than fd+grep pipeline (but slower)
- **find** - surprisingly competitive for simple patterns

| Operation | Recommendation |
|-----------|----------------|
| Simple glob (`*.txt`) | `fd --glob` or `find -name` |
| All files | `fd .` |
| Content search | `fd --glob \| xargs grep` (faster) or `ff --contains` (simpler) |
| Parallel work | `fd` (better implementation) |

### What ff does better than fd:

* Built-in content search (no external grep needed)
* Natural language queries (`"python files modified this week"`)
* Fuzzy matching
* Semantic symbol search
* More flexible filtering options
* No dependencies (static binary available)

## Semantic code search

fastfind also supports semantic-style symbol discovery directly from the CLI.

Run these inside a project directory:

Find function definitions:

```
ff --function parse .
```

Find classes:

```
ff --class Parser .
```

Find symbols:

```
ff --symbol Config .
```

This allows basic code discovery without launching a language server.

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

| Area              | Flags                                                                     |
| ----------------- | ------------------------------------------------------------------------- |
| Match mode        | `--glob`, `--regex`, `--fixed`, `--fuzzy`                                 |
| Path mode         | `--name`, `--full-path`, `--full-match`                                   |
| Traversal         | `-H`, `-L`, `-x`, `--gitignore`, `--max-depth`, `-j`                      |
| Filters           | `--type`, `--size`, `--changed`, `--contains`, `--exclude`                |
| Git               | `--git-modified`, `--git-untracked`, `--git-tracked`, `--git-changed`     |
| Output            | `--long`, `--json`, `--ndjson`, `--table`, `--sort`, `--limit`, `--stats` |
| Interactive/index | `--interactive`, `--select`, `--use-index`, `--rebuild-index`             |

### More examples

```bash
# Recent logs, newest first
ff "*.log" --sort time --reverse

# Changed Python files in the current directory tree
ff "*.py" --changed 7d .

# Symbol search inside a project
ff --function parse .

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

Wanna talk privately? email me at: [robertflexxgh@gmail.com](mailto:robertflexxgh@gmail.com)
Please report vulnerabilities using [`SECURITY.md`](SECURITY.md).

## License

MIT License. See [`LICENSE`](LICENSE).
