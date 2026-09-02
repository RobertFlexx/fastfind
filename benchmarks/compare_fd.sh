#!/usr/bin/env bash
set -Eeuo pipefail

fastfind_bin="${1:-./bin/fastfind}"
bench_root="${2:-.}"
runs="${3:-20}"

if [ ! -x "$fastfind_bin" ]; then
  printf 'fastfind binary is not executable: %s\n' "$fastfind_bin" >&2
  exit 2
fi
if [ ! -d "$bench_root" ]; then
  printf 'benchmark root is not a directory: %s\n' "$bench_root" >&2
  exit 2
fi
if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  printf 'runs must be a positive integer: %s\n' "$runs" >&2
  exit 2
fi
if ! command -v hyperfine >/dev/null 2>&1; then
  printf '%s\n' 'hyperfine is required for repeatable benchmark statistics' >&2
  exit 2
fi

fd_bin="$(command -v fd || command -v fdfind || true)"
if [ -z "$fd_bin" ]; then
  printf '%s\n' 'fd (or fdfind) is required for comparison' >&2
  exit 2
fi

ff_count="$("$fastfind_bin" --count '*' "$bench_root")"
fd_count="$("$fd_bin" --no-ignore --case-sensitive --glob '*' "$bench_root" | wc -l)"
fd_count="${fd_count//[[:space:]]/}"
if [ "$ff_count" != "$fd_count" ]; then
  printf 'refusing to compare different result sets: ff=%s fd=%s\n' \
    "$ff_count" "$fd_count" >&2
  exit 1
fi

export FASTFIND_BENCH_BIN="$fastfind_bin"
export FASTFIND_BENCH_FD="$fd_bin"
export FASTFIND_BENCH_ROOT="$bench_root"

printf 'entries: %s\n' "$ff_count"
printf 'root: %s\n\n' "$bench_root"
hyperfine --warmup 3 --runs "$runs" \
  --command-name 'ff list' \
    '"$FASTFIND_BENCH_BIN" "*" "$FASTFIND_BENCH_ROOT" >/dev/null' \
  --command-name 'fd list' \
    '"$FASTFIND_BENCH_FD" --no-ignore --case-sensitive --glob "*" "$FASTFIND_BENCH_ROOT" >/dev/null' \
  --command-name 'ff count' \
    '"$FASTFIND_BENCH_BIN" --count "*" "$FASTFIND_BENCH_ROOT" >/dev/null' \
  --command-name 'fd + wc -l' \
    '"$FASTFIND_BENCH_FD" --no-ignore --case-sensitive --glob "*" "$FASTFIND_BENCH_ROOT" | wc -l >/dev/null'
