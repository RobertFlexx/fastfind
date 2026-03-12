# fastfind

## Modern Reimplementation of [GNU Find](https://www.gnu.org/software/findutils/), or [BSD Find](https://man.freebsd.org/cgi/man.cgi?query=find&manpath=SunOS+5.9).
But now, better than both, and cross platform with 0 dependencies, thanks to Nim.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Nim](https://img.shields.io/badge/language-Nim-yellow)](https://nim-lang.org/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20BSD-lightgrey)]()

A fast, feature-rich file search utility written in Nim. Single binary, zero dependencies, cross-platform.
### Official Aliases (Recommended)
```
ffind
```
```
ff
```
```
sfind
```
```
qf
```

(qf is quickfind, sfind is speed find)



## Installation

### Build from source

```bash
git clone https://github.com/RobertFlexx/fastfind
cd fastfind
nim c -d:release -o:bin/fastfind src/fastfind.nim
```

### With threading support

```bash
nim c -d:release --threads:on -o:bin/fastfind src/fastfind.nim
```

### Install to PATH

```bash
sudo cp bin/fastfind /usr/local/bin/
```

## Quick Start

```bash
# Find all .nim files
fastfind "*.nim" src/

# Fuzzy search
fastfind --fuzzy config src/

# Find files larger than 10MB modified in the last hour
fastfind --size ">10M" --changed 1h

# Natural language query
fastfind "python files containing TODO" src/

# Interactive mode
fastfind --interactive
```

## Why fastfind

### Compared to find

The traditional `find` command is powerful but has several drawbacks:

1. Inconsistent syntax across platforms (GNU find vs BSD find)
2. Complex flag combinations for simple tasks
3. No fuzzy matching
4. No built-in content search
5. No interactive mode
6. No index-based instant search
7. Verbose syntax for common operations

fastfind example:

```bash
fastfind "*.py" --size ">1M" --changed 24h --contains "import"
```

Equivalent find command:

```bash
find . -name "*.py" -size +1M -mtime -1 -exec grep -l "import" {} \;
```

### Compared to fd

fd is an excellent tool. fastfind offers additional features:

1. Natural language queries ("files larger than 10mb modified yesterday")
2. Built-in file index for instant search across large directories
3. Semantic code search (find function/class definitions)
4. Interactive terminal UI with live filtering
5. Fuzzy matching with configurable scoring
6. Git integration (filter by modified/untracked/tracked status)
7. Single binary with no runtime dependencies

### Compared to ripgrep

ripgrep focuses on content search. fastfind focuses on file discovery with optional content filtering. Use ripgrep when you need to search inside files extensively. Use fastfind when you need to locate files by name, path, size, time, or type with optional content filtering.

### Compared to fzf

fzf is a general-purpose fuzzy finder that reads from stdin. fastfind is a file finder with built-in fuzzy matching, indexing, and file-aware features. They complement each other:

```bash
# Use together
fastfind "*.nim" src/ | fzf
```

### Compared to Everything (Windows)

Everything uses NTFS indexing for instant search on Windows. fastfind provides similar functionality through its own index system that works on any filesystem and operating system.

## Usage

```
fastfind [OPTIONS] <pattern> [path ...]
fastfind "<natural language query>" [path ...]
```

### Pattern Modes

| Flag      | Description                                         |
| --------- | --------------------------------------------------- |
| `--glob`  | Glob patterns (default). Supports `*`, `?`, `[abc]` |
| `--regex` | Regular expressions                                 |
| `--fixed` | Literal substring match                             |
| `--fuzzy` | Fuzzy matching with scoring                         |

### Pattern Target

| Flag           | Description                            |
| -------------- | -------------------------------------- |
| `--name`       | Match against basename only (default)  |
| `--full-path`  | Match against full relative path       |
| `--full-match` | Require pattern to match entire target |

### Case Sensitivity

| Flag                  | Description                                        |
| --------------------- | -------------------------------------------------- |
| `-i`, `--ignore-case` | Case insensitive matching                          |
| `--smart-case`        | Ignore case unless pattern has uppercase (default) |

### Traversal

| Flag                      | Description                           |
| ------------------------- | ------------------------------------- |
| `-H`, `--hidden`          | Include hidden files and directories  |
| `-L`, `--follow`          | Follow symbolic links                 |
| `-x`, `--one-file-system` | Do not cross filesystem boundaries    |
| `--gitignore`             | Respect .gitignore files              |
| `--no-gitignore`          | Ignore .gitignore files               |
| `--min-depth N`           | Minimum directory depth               |
| `--max-depth N`           | Maximum directory depth               |
| `-j`, `--threads N`       | Number of threads for parallel search |

### Type Filters

| Flag          | Description               |
| ------------- | ------------------------- |
| `--type file` | Match only regular files  |
| `--type dir`  | Match only directories    |
| `--type link` | Match only symbolic links |

Multiple type flags can be combined.

### Size Filters

| Flag                 | Description                  |
| -------------------- | ---------------------------- |
| `--size ">10M"`      | Larger than 10 megabytes     |
| `--size "<1K"`       | Smaller than 1 kilobyte      |
| `--size "10M..100M"` | Between 10 and 100 megabytes |
| `--size "=1234"`     | Exactly 1234 bytes           |

Supported units: B, K, KB, M, MB, G, GB, T, TB, KiB, MiB, GiB, TiB

### Time Filters

| Flag            | Description               |
| --------------- | ------------------------- |
| `--newer TIME`  | Modified after TIME       |
| `--older TIME`  | Modified before TIME      |
| `--changed DUR` | Modified within duration  |
| `--recent`      | Modified in last 24 hours |

TIME format: `2025-12-01`, `2025-12-01T13:05:00`, `2025-12-01 13:05:00`

DUR format: `10s`, `5m`, `2h`, `3d`, `1w`

### Content Filters

| Flag                  | Description                                  |
| --------------------- | -------------------------------------------- |
| `--contains TEXT`     | File contains TEXT                           |
| `--contains-re REGEX` | File contains REGEX match                    |
| `--max-bytes N`       | Maximum bytes to scan per file (default: 1M) |
| `--binary`            | Include binary files in content search       |

### Git Integration

| Flag              | Description                          |
| ----------------- | ------------------------------------ |
| `--git-modified`  | Only files modified according to git |
| `--git-untracked` | Only untracked files                 |
| `--git-tracked`   | Only tracked files                   |
| `--git-changed`   | Modified or untracked files          |

### Semantic Code Search

| Flag              | Description                             |
| ----------------- | --------------------------------------- |
| `--function NAME` | Find function definitions matching NAME |
| `--class NAME`    | Find class definitions matching NAME    |
| `--symbol NAME`   | Find any symbol matching NAME           |

Supported languages: Nim, Python, C, C++, Rust, JavaScript, TypeScript, Go, Java

### Fuzzy Search

| Flag            | Description                    |
| --------------- | ------------------------------ |
| `--fuzzy`       | Enable fuzzy matching          |
| `--fuzzy-score` | Display match scores in output |

Fuzzy scoring factors:

* Consecutive character matches (bonus)
* Word boundary matches (bonus)
* CamelCase transitions (bonus)
* Path depth (penalty)
* Path length (penalty)

### Ranking

| Flag             | Description                      |
| ---------------- | -------------------------------- |
| `--rank`         | Enable smart ranking (auto mode) |
| `--rank-recency` | Favor recently modified files    |
| `--rank-depth`   | Favor files closer to root       |

### Output Modes

| Flag           | Description                    |
| -------------- | ------------------------------ |
| `--long`, `-l` | Long format with size and time |
| `--json`       | JSON array output              |
| `--ndjson`     | Newline-delimited JSON         |
| `--table`      | Formatted table output         |
| `--absolute`   | Print absolute paths           |
| `--relative`   | Print relative paths           |

### Output Control

| Flag              | Description                       |
| ----------------- | --------------------------------- |
| `--sort KEY`      | Sort by path, name, size, or time |
| `-r`, `--reverse` | Reverse sort order                |
| `--limit N`       | Stop after N matches              |
| `-c`, `--count`   | Print match count only            |
| `--stats`         | Print search statistics           |
| `--color MODE`    | Color output: auto, always, never |

### Interactive Mode

| Flag            | Description                    |
| --------------- | ------------------------------ |
| `--interactive` | Launch interactive terminal UI |
| `--select`      | Pick a result interactively    |

Interactive mode keybindings:

* Up/Down: Navigate results
* Enter: Select file
* Ctrl+C: Exit

### Index

| Flag              | Description                       |
| ----------------- | --------------------------------- |
| `--rebuild-index` | Rebuild the file index            |
| `--index-status`  | Show index information            |
| `--use-index`     | Query index instead of filesystem |

The index is stored at `~/.cache/fastfind/.fastfind_index.json`

### Execution

| Flag             | Description                                         |
| ---------------- | --------------------------------------------------- |
| `--exec CMD`     | Execute CMD for each match. Use `{}` as placeholder |
| `--exec-cmd CMD` | Set command without shell parsing                   |
| `--exec-arg ARG` | Add argument (repeatable)                           |

### Configuration

| Flag            | Description                  |
| --------------- | ---------------------------- |
| `--config FILE` | Load configuration from FILE |
| `--no-config`   | Skip default configuration   |

Default configuration location: `~/.config/fastfind/config.toml`

### Other Flags

| Flag                   | Description                |
| ---------------------- | -------------------------- |
| `-v`, `--verbose`      | Verbose output             |
| `-q`, `--quiet-errors` | Suppress error messages    |
| `-h`, `--help`         | Show help                  |
| `--version`            | Show version               |
| `--fd`                 | Use fd-compatible defaults |

## Natural Language Queries

fastfind understands natural language queries:

```bash
# Size queries
fastfind "files larger than 10mb"
fastfind "files smaller than 1K"

# Time queries
fastfind "files modified today"
fastfind "files modified yesterday"
fastfind "files modified within 7 days"

# Content queries
fastfind "python files containing TODO"
fastfind "nim files containing proc"

# Type queries
fastfind "directories named config"
fastfind "images modified within 7 days"

# Combined
fastfind "files larger than 1M modified yesterday"
```

Recognized words:

* Types: files, directories, folders, images, videos, documents
* Languages: python, javascript, typescript, nim, rust
* Size: larger, smaller, bigger, greater, less, under, over
* Time: today, yesterday, modified, changed, within, ago
* Content: containing, contains, with

## Configuration File

Create `~/.config/fastfind/config.toml`:

```toml
# Default settings
hidden = false
gitignore = true
follow_symlinks = false
one_file_system = false

# Search mode
mode = "glob"
path_mode = "basename"
ignore_case = false
smart_case = true

# Fuzzy settings
fuzzy = false

# Index
use_index = false

# Output
output = "plain"
color = "auto"
stats = false

# Limits
max_depth = -1
max_bytes = "1M"

# Exclusions
exclude = [
    ".git/*",
    "node_modules/*",
    "__pycache__/*",
    "*.pyc",
    ".cache/*",
    "target/*",
    "build/*",
    "dist/*"
]

# Threading
threads = 0
```

## Examples

### Basic Searches

```bash
# All Python files
fastfind "*.py"

# All files named config (any extension)
fastfind "config.*"

# Files in a specific directory
fastfind "*.js" src/

# Case insensitive
fastfind -i readme
```

### Advanced Filtering

```bash
# Large log files
fastfind "*.log" --size ">100M"

# Recently modified source files
fastfind "*.nim" --changed 1h

# Source files excluding tests
fastfind "*.py" --exclude "*test*"

# Only directories
fastfind "*" --type dir --max-depth 2

# Hidden files
fastfind ".*" -H
```

### Content Search

```bash
# Files containing specific text
fastfind "*.nim" --contains "proc main"

# Files with TODO comments
fastfind "*.py" --contains TODO

# Using regex
fastfind "*.js" --contains-re "function\\s+\\w+"
```

### Git Integration

```bash
# Modified files
fastfind --git-modified

# Untracked files
fastfind --git-untracked

# All changed files (modified + untracked)
fastfind --git-changed

# Modified Python files
fastfind "*.py" --git-modified
```

### Code Search

```bash
# Find function definitions
fastfind --function parse

# Find class definitions
fastfind --class Config

# Find any symbol
fastfind --symbol handler
```

### Fuzzy Search

```bash
# Fuzzy match
fastfind --fuzzy config

# With scores
fastfind --fuzzy --fuzzy-score cfg

# Fuzzy with ranking
fastfind --fuzzy --rank --rank-depth main
```

### Index-Based Search

```bash
# Build index for home directory
fastfind --rebuild-index ~

# Check index status
fastfind --index-status

# Search using index
fastfind --use-index config
```

### Interactive Mode

```bash
# Launch interactive UI
fastfind --interactive

# Interactive with initial filter
fastfind --interactive --fuzzy
```

### Execution

```bash
# Count lines in each file
fastfind "*.nim" src/ --exec "wc -l src/{}"

# Open matching files in editor
fastfind "*.py" --limit 1 --exec "vim {}"

# Delete empty directories
fastfind "*" --type dir --exec "rmdir {} 2>/dev/null"

# Select and open
fastfind "*.nim" --select --exec "code {}"
```

### Output Formats

```bash
# Long format
fastfind "*.nim" --long

# JSON output
fastfind "*.nim" --json

# Newline-delimited JSON (streaming)
fastfind "*.nim" --ndjson

# Table format
fastfind "*.nim" --table

# Sorted by size (largest first)
fastfind "*.nim" --sort size --reverse --long

# With statistics
fastfind "*.nim" --stats
```

### Combined with Other Tools

```bash
# Pipe to fzf
fastfind "*.nim" | fzf

# Count matches
fastfind "*.py" --count

# Pipe to xargs
fastfind "*.log" --size ">1M" | xargs rm

# Pipe to grep
fastfind "*.nim" | xargs grep "proc"
```

## Performance

fastfind is designed for speed:

1. Streaming output for immediate results
2. Minimal memory allocation in hot paths
3. Efficient directory traversal
4. Optional parallel search with thread pool
5. File index for instant repeated searches
6. Smart content search with early termination

Benchmarks on a typical project (10,000 files):

* Basic glob search: <50ms
* Fuzzy search: <100ms
* Index-based search: <10ms
* Content search: varies by file sizes

## Platform Support

* Linux: Full support including inotify for file watching
* macOS: Full support including kqueue for file watching
* BSD: Full support including kqueue for file watching
* Windows: Basic support (no file watching, no interactive mode)

## License

MIT License. See LICENSE file for details.

## Contributing

Contributions are welcome. Please open an issue to discuss proposed changes before submitting a pull request.

## Acknowledgments

Inspired by:

* fd (simple syntax, smart defaults)
* ripgrep (performance focus)
* fzf (fuzzy matching, interactive UI)
* Everything (instant search via indexing)

---

## Project Setup Canvas

You can quickly recreate the full project configuration using the following copyable blocks.

### fastfind.nimble

```bash
cat > fastfind.nimble << 'EOF'
# fastfind.nimble - Nim utility: fast file finder (replaces GNU find)

version       = "0.1.0"
author        = "RobertFlexx"
description   = "fastfind: a fast, feature-rich file finder with fuzzy search, interactive terminal UI, and git awareness."
license       = "MIT"

srcDir        = "src"
bin           = @["fastfind"]

homepage      = "https://github.com/RobertFlexx/fastfind"

skipDirs      = @["tests"]

requires "nim >= 1.6.0"

task run, "Run fastfind":
  exec "nim c -r src/fastfind.nim"

task dev, "Build debug version":
  exec "nim c -d:debug -o:bin/fastfind src/fastfind.nim"

task release, "Build optimized binary":
  exec "nim c -d:release --opt:speed -o:bin/fastfind src/fastfind.nim"

task release_fast, "Build maximum optimization binary":
  exec "nim c -d:release -d:danger --opt:speed --passC:-flto --passL:-flto -o:bin/fastfind src/fastfind.nim"

task release_threaded, "Build optimized binary with threading":
  exec "nim c -d:release --opt:speed --threads:on -o:bin/fastfind src/fastfind.nim"

task release_full, "Build fully optimized binary with all features":
  exec "nim c -d:release -d:danger --opt:speed --threads:on --passC:-flto --passL:-flto -o:bin/fastfind src/fastfind.nim"

task check, "Compile check without running":
  exec "nim c --checks:on src/fastfind.nim"

task clean, "Remove build artifacts":
  exec "rm -rf bin/fastfind src/fastfind nimcache"

task install, "Install to /usr/local/bin":
  exec "nim c -d:release --opt:speed -o:bin/fastfind src/fastfind.nim"
  exec "sudo cp bin/fastfind /usr/local/bin/"
EOF
```

---

## Interactive Mode

Interactive mode provides a full-featured terminal file browser with fuzzy search capabilities.

### Launching Interactive Mode

```bash
fastfind --interactive
```

### Interface Overview

The interactive UI consists of:

* **Header bar**: Shows current directory, mode indicator, sort settings
* **File list**: Displays files and directories with icons, sizes, and timestamps
* **Preview pane**: Shows file contents or directory information (toggleable)
* **Status bar**: Displays selection count, position, and file details
* **Prompt line**: Shows available commands or input fields

### Keyboard Shortcuts

#### Navigation

| Key                 | Action                           |
| ------------------- | -------------------------------- |
| `j` / `↓`           | Move cursor down                 |
| `k` / `↑`           | Move cursor up                   |
| `l` / `→` / `Enter` | Enter directory                  |
| `h` / `←`           | Go to parent directory           |
| `g` (twice)         | Go to top of list                |
| `G`                 | Go to bottom of list             |
| `Ctrl+D`            | Page down                        |
| `Ctrl+U`            | Page up                          |
| `~`                 | Go to home directory             |
| `/` (in browse)     | Go to root directory             |
| `[`                 | Go back in history               |
| `]`                 | Go forward in history            |
| `Tab`               | Enter goto path mode             |
| `1-9`               | Quick jump to preset directories |

#### Quick Jump Directories (1-9)

| Key | Directory   |
| --- | ----------- |
| `1` | Home (~)    |
| `2` | ~/Documents |
| `3` | ~/Downloads |
| `4` | ~/Desktop   |
| `5` | /tmp        |
| `6` | /etc        |
| `7` | /var/log    |
| `8` | /usr        |
| `9` | / (root)    |

#### Search and Filter

| Key      | Action                                 |
| -------- | -------------------------------------- |
| `/`      | Start local fuzzy search/filter        |
| `g`      | Toggle global search mode              |
| `f`      | Filter by type (f=file, d=dir, l=link) |
| `Escape` | Clear search/filter                    |

#### Global Search

Press `g` to enter global search mode. This searches across your entire filesystem (optimized paths).

Supports patterns:

* `*.mp4` - Find all MP4 files
* `*.rb` - Find all Ruby files
* `config` - Find files containing "config" in name
* `test?.py` - Wildcard matching

#### Selection

| Key     | Action                                     |
| ------- | ------------------------------------------ |
| `Space` | Toggle selection and move down             |
| `v`     | Select all visible files                   |
| `V`     | Clear all selections                       |
| `Enter` | Confirm selection and exit (outputs paths) |

#### View Options

| Key            | Action                               |
| -------------- | ------------------------------------ |
| `.`            | Toggle hidden files                  |
| `p`            | Toggle preview pane                  |
| `i`            | Toggle file details (size, time)     |
| `s`            | Cycle sort mode (name/size/time/ext) |
| `r`            | Reverse sort order                   |
| `R` / `Ctrl+R` | Refresh directory                    |

#### Bookmarks

| Key | Action                             |
| --- | ---------------------------------- |
| `b` | Add current directory to bookmarks |
| `B` | Show bookmarks panel               |

In bookmarks panel:

* `1-9` - Jump to bookmark
* `d` - Delete bookmark
* `Escape` - Close panel

Bookmarks are saved to `~/.config/fastfind/bookmarks`

#### Other Actions

| Key            | Action                        |
| -------------- | ----------------------------- |
| `y`            | Yank (copy) current file path |
| `:`            | Enter command mode            |
| `?`            | Show help screen              |
| `q` / `Ctrl+C` | Quit                          |

### Command Mode

Press `:` to enter command mode. Available commands:

| Command           | Description                        |
| ----------------- | ---------------------------------- |
| `:cd PATH`        | Change to directory                |
| `:q` / `:quit`    | Quit interactive mode              |
| `:h` / `:hidden`  | Toggle hidden files                |
| `:p` / `:preview` | Toggle preview pane                |
| `:sort NAME`      | Set sort mode (name/size/time/ext) |
| `:filter TYPE`    | Filter by type (f/d/l)             |

### Goto Mode

Press `Tab` to enter goto mode. Type a path and press:

* `Tab` - Autocomplete path
* `Enter` - Navigate to path
* `Escape` - Cancel

Supports `~` expansion for home directory.

### Output

When you select a file (or files) and press `Enter`:

* Single file: Prints the absolute path to stdout
* Multiple selections: Prints each path on a new line

This allows piping to other commands:

```bash
fastfind --interactive | xargs vim
fastfind --interactive | xargs -I {} cp {} /destination/
fastfind --interactive | while read f; do echo "Processing: $f"; done
```

### Tips

1. Fast navigation: Use `1-9` for quick jumps to common directories
2. Efficient search: Start typing `/` immediately to filter current directory
3. Global search: Use `g` then `*.ext` pattern for system-wide file type search
4. Bulk operations: Select multiple files with `Space`, then `Enter` to output all paths
5. Preview: Toggle with `p` to quickly inspect file contents without leaving the UI
6. Bookmarks: Save frequently accessed directories with `b` for instant access

---

## Build Tasks (Nimble)

The project includes several nimble tasks for different build configurations.

```bash
# Development build
nimble dev

# Standard release build
nimble release

# Maximum optimization
nimble release_fast

# Release with threading
nimble release_threaded

# Full optimization build
nimble release_full

# Run directly
nimble run

# Compile check only
nimble check

# Clean build artifacts
nimble clean

# Build and install
nimble install
```

### Build Configurations

| Task               | Flags                                                          | Use Case                            |
| ------------------ | -------------------------------------------------------------- | ----------------------------------- |
| `dev`              | `-d:debug`                                                     | Development and debugging           |
| `release`          | `-d:release --opt:speed`                                       | Standard release                    |
| `release_fast`     | `-d:release -d:danger --opt:speed --passC:-flto --passL:-flto` | Maximum single-threaded performance |
| `release_threaded` | `-d:release --opt:speed --threads:on`                          | Multi-threaded search               |
| `release_full`     | All optimizations + threading + LTO                            | Production deployment               |
