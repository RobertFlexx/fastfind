# Changelog - fastfind v2.3.0

## v2.3.0 - Engine Overhaul

- Replaced the object-heavy JSON index with the compact, versioned FFIDX004
  binary stream: root deduplication, relative paths, varint metadata, bounded
  decoding, atomic refreshes, coverage checks, and corrupt-index fallback.
- Rebuilt natural-language search as an explainable query planner with quoted
  phrases, intersecting filters, compact clauses, size/date/duration parsing,
  sorting, depth, limits, and case-preserved paths/content.
- Expanded semantic symbol search to every supported symbol category, cached
  language grammars lazily, pruned hidden/excluded directories, and bounded
  per-file results.
- Fixed skipped metadata, followed-symlink cycles, nested and ordered Gitignore
  rules, NUL-safe Git status parsing, content boundaries/full-file defaults,
  case-aware content matching, and child-command exit propagation.
- Added adaptive path traversal, thread-local parallel accounting, bounded work
  stealing, streaming JSON output, `--extension`, `--print0`, `--index-only`,
  `--explain`, safe terminal output, confirmed TUI deletion, fail-closed release
  verification, immutable updater sourcing, regression tests, and pinned CI.

---

## v2.2.2 - Performance and Correctness Update

This patch release improves large-tree traversal speed and tightens POSIX file-type behavior while preserving existing search features.

### Bug Fixes

- Fixed POSIX `-t f` / `--type f` filtering so regular files are not confused with sockets, pipes, or other special filesystem entries.
- Fixed fast-path match accounting so type-filtered counts only include entries that pass the requested type filter.

### Performance Improvements

- Kept the low-allocation POSIX `readdir` fast path active for simple `-t f` and `-t d` searches.
- Added POSIX fast-path support for `-x` / `--one-file-system`, checking device IDs only for traversed directories.
- Avoided building unused matchers, excluders, and content regex state for simple path-streaming searches.
- Removed per-match callback overhead from count-only streaming paths.

### Benchmark Notes

- On a local `/usr` tree, `ff "*" /usr -H -t f` ran about 1.38x faster than `find /usr -type f` while using less user CPU than `fd`.
- On a local one-filesystem root scan, `ff "*" / -H -x -t f` ran about 1.17x faster than `find / -xdev -type f` after the fast-path update.
- `fd` remains faster on highly parallel broad scans, while fastfind prioritizes low allocation, lower user CPU, and feature coverage.

---

## v2.2.1 - Patch Update

This patch release focuses on correctness, security hardening, regression coverage, and small performance wins for count-only tree walking.

### Security Fixes

- Fixed shell placeholder quoting in select-mode `--exec` so paths containing shell metacharacters are passed safely.
- Fixed non-shell exec handling so selected paths are passed as arguments without shell interpretation.
- Hardened index serialization by using proper JSON string escaping for indexed paths and names, including control characters and newlines.

### Bug Fixes

- Fixed `--count`, which was parsed but previously still printed matching paths.
- Fixed fuzzy `--limit` ordering so limits are applied after fuzzy/ranked sorting instead of before ranking.
- Fixed `--exec-cmd` / `--exec-arg` handling in multi-result mode.
- Fixed child process output inheritance for non-shell exec commands.
- Fixed invalid `--regex` and `--contains-re` inputs to produce clean CLI errors instead of crashes or misleading no-match results.
- Fixed index command positional paths so `ff --rebuild-index <path>` and `ff --update-index <path>` operate on the requested path.
- Fixed `--use-index` path scoping so index results are limited to the requested search roots.
- Fixed `--use-index` fallback behavior for unsupported searches such as content filters, excludes, regex mode, and full-path matching.
- Fixed `-L` / `--follow` traversal into symlinked directories.

### Performance Improvements

- Improved fuzzy scoring quality while keeping full fuzzy-scan performance effectively unchanged in local benchmarks.
- Removed redundant fuzzy/ranked result sorting work.
- Avoid path output construction for count-only traversal.
- Use traversal stats for count-only streaming output to reduce callback overhead.
- Precompute indexed root prefixes before filtering index entries.

### Tests

- Added `nimble test` for CLI regression coverage.
- Added regression tests for count output, exec arguments, shell quoting, regex errors, symlink traversal, index path scoping, index JSON escaping, and index fallback behavior.
- Added fuzzy ranking regression coverage for exact/prefix and compact matches.

### Benchmark Notes

- Large-tree listing performance is effectively unchanged.
- Count-only scans improved by roughly 11% on a local ~25k-entry benchmark fixture.

---

## v2.2.0 - Feature Update

This release brings major improvements to the NLP (natural language) query system and index functionality, plus important bug fixes.

### NLP Improvements (Natural Language Queries)

The NLP parser has been completely rewritten with significantly enhanced capabilities:

#### Expanded Word Database
- **Action words**: findme, showall, listall, locate, discover, fetch, grab, pull
- **Modifier words**: hidden, latest, newest, first, last, modified, changed
- **Filler words**: 100+ common English words intelligently ignored

#### Compound Categories (NEW)
Natural English phrases now work seamlessly:
```bash
ff "image files"
ff "video files"
ff "audio files"
ff "code files"
ff "config files"
ff "log files"
ff "document files"
ff "archive files"
```

#### Enhanced Language Support
- 80+ programming languages with proper extensions
- Shell scripts: bash, zsh, fish, powershell
- Devops: dockerfile, terraform, ansible, helm, kubernetes
- Config: nginx, apache, vim, tmux, ssh, git

#### Improved Time Parsing (NEW)
```bash
ff "files modified this week"
ff "files modified 2 days ago"
ff "files modified in the last hour"
ff "files older than 30 days"
ff "files modified between 1 week and 1 month"
ff "recent files"
```

#### Improved Size Parsing (NEW)
```bash
ff "large files"
ff "small files"
ff "empty files"
ff "files larger than 10mb"
ff "files between 1mb and 10mb"
ff "medium sized files"
```

#### Compound Expressions (NEW)
Combine filters naturally:
```bash
ff "python code files modified this week"
ff "rust files larger than 100kb"
ff "config files modified today"
ff "large log files modified yesterday"
```

### Index Improvements

#### Incremental Updates (NEW)
Index now supports fast incremental updates instead of full rebuilds:
```bash
ff --rebuild-index <path>   # Full rebuild
ff --update-index <path>    # Incremental update (fast)
```

#### Index Management Commands (NEW)
```bash
ff --update-index <path>    # Incremental update
ff --verify-index           # Remove stale entries
ff --index-status          # Show index info
ff --use-index             # Use index for search
```

#### Index Improvements
- Lock-free reads (no lock contention during searches)
- Automatic stale entry removal
- Version tracking for format detection
- Better progress reporting (shows new/modified/unchanged counts)

### Bug Fixes

#### Interactive Mode
- Added `:exec <command>` command to run arbitrary commands on selected files
- Added `:rm` / `:delete` command to delete selected files
- Fixed bare `except:` clauses to properly catch `CatchableError`

#### Exec Command (FIXED)
- Fixed `--exec` using relative paths which failed when not in search directory
- Now uses absolute paths for reliable execution

#### Code Quality
- Fixed 14 bare `except:` clauses in interactive mode
- Removed unused dead code in search path handling
- Improved error handling consistency

### Migration from v2.1.0

No CLI changes. Drop-in replacement.

```bash
# Rebuild index for new features
ff --rebuild-index ~

# Or use incremental updates
ff --update-index ~
```

### Known Issues

- Software is not mature - expect occasional bugs
- Interactive mode requires POSIX (Linux/macOS/BSD)

---

## v2.1.0 - Performance Update

### Performance Improvements

- **Major performance overhaul** - Significantly faster file scanning and matching
- **Universal `*` fast path** - Direct pattern matching for wildcard queries
- **Pattern match before stat** - Avoids unnecessary syscalls on non-matching entries
- **Buffered output** - 256KB buffer reduces syscall overhead
- **Buffer reuse** - Single allocation for path construction
- **Local variable hoisting** - Avoids repeated field access
- **Types fast path** - Skips set membership for default types
- **Optimized case-insensitive matching** - Separate branches avoid redundant condition checks
- **Threading improvements** - Better parallel processing with thread pool and CPU detection

### Benchmark Results

| Command | Time | Notes |
|---------|------|-------|
| `ff "*" /` | ~0.54s | Fastest mode (single-thread) |
| `ff "*" / -H` | ~0.71s | With hidden files |
| `fd . /` | ~0.30s | Reference |

**Key Finding:** Single-thread fast path is faster than parallel mode for simple recursive listing.

---

## Versions below these have no documented changelogs.
