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
exec python3 "$(dirname -- "$0")/compare_fd.py" "$fastfind_bin" "$bench_root" "$runs"
