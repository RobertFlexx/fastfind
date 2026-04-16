# Changelog - fastfind v2.2.0

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
