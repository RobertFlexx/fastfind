# fastfind

A fast, feature-rich file search utility written in Nim. Single binary, zero dependencies, cross-platform.

## Installation

### Build from source

```bash
git clone https://github.com/yourusername/fastfind
cd fastfind
nim c -d:release -o:bin/fastfind src/fastfind.nim
````

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
fastfind "*.js" --contains-re "function\s+\w+"
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
