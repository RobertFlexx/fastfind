# Changelog - fastfind v2.1.0

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
- **Optimized search path handling** - Faster path-only scanning mode for simple queries
- **Memory optimizations** - Reduced memory overhead with better lazy evaluation

### Benchmark Results

| Command | Time | Notes |
|---------|------|-------|
| `ff "*" /` | ~0.54s | Fastest mode (single-thread) |
| `ff "*" / -H` | ~0.71s | With hidden files |
| `fd . /` | ~0.30s | Reference |

**Key Finding:** Single-thread fast path is faster than parallel mode for simple recursive listing.

### Parallel Mode Note

Parallel mode (`-j N`) is generally **slower** than single-thread for simple recursive listing due to:
- Work queue overhead
- Per-entry allocations in parallel path  
- I/O-bound workload

Use default (no `-j` flag) for best performance on simple listings.

### Bug Fixes

- Fixed various bugs from v2.0.0
- Improved error handling during file scanning
- Fixed issues with symlink handling
- Resolved sorting and output issues

### Known Issues

- Parallel mode is slower than single-thread for simple workloads
- NLP (natural language queries) is still in BETA
- Software is not mature - expect occasional bugs

---

## v2.0.0 vs v2.1.0 Comparison

| Feature | v2.0.0 | v2.1.0 |
|---------|--------|--------|
| Performance | Basic | ~2.8x faster |
| Fast path | Basic | Universal `*` detection |
| Output buffering | Line-by-line | 256KB buffered |
| Matcher | Per-entry | Optimized with bypass |
| syscalls | Normal | Minimized |

---

## Upgrading from v2.0.0

The CLI interface remains backward compatible. Simply replace your binary or rebuild:

```bash
nim c -d:danger -d:release --mm:orc --threads:on -d:lto --opt:speed \
  --passC:-O3 --passC:-march=native --passC:-flto --passL:-flto --passL:-s \
  -o:bin/fastfind src/ff.nim
```

Or use the install script:

> NOTE: binaries for newest upstream releases wont ALWAYS be available.

```bash
curl -fsSL https://raw.githubusercontent.com/RobertFlexx/fastfind/main/install.sh | bash
```
