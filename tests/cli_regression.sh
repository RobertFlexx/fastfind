#!/usr/bin/env bash
set -Eeuo pipefail

bin="${1:?usage: cli_regression.sh /path/to/fastfind}"
case "$bin" in /*) ;; *) bin="$(pwd)/$bin" ;; esac
[ -x "$bin" ] || { printf 'not executable: %s\n' "$bin" >&2; exit 2; }

fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-tests.XXXXXX")"
cleanup() {
  case "$fixture" in "${TMPDIR:-/tmp}"/fastfind-tests.*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT INT TERM

mkdir -p "$fixture/tree/.git/info" "$fixture/tree/src/generated" "$fixture/tree/build" "$fixture/tree/deep/a"
printf 'needle-across-boundary' > "$fixture/tree/src/index.nim"
printf 'MixedCaseNeedle' > "$fixture/tree/src/case.txt"
printf 'ignored\n' > "$fixture/tree/build/drop.tmp"
printf 'kept\n' > "$fixture/tree/build/keep.txt"
printf 'drop\n' > "$fixture/tree/src/generated/drop.nim"
printf 'keep\n' > "$fixture/tree/src/generated/keep.nim"
printf 'generated/*\n!generated/keep.nim\n' > "$fixture/tree/src/.gitignore"
printf 'build/*\n!build/keep.txt\n' > "$fixture/tree/.gitignore"
ln -s ../deep "$fixture/tree/deep/a/cycle"

CONTENT_ROOT="$fixture/tree" python3 - <<'PY'
import os
root = os.environ["CONTENT_ROOT"]
with open(os.path.join(root, "boundary.txt"), "wb") as f:
    f.write(b"x" * (64 * 1024 - 5) + b"cross-boundary-needle" + b"z" * 10)
with open(os.path.join(root, "large.txt"), "wb") as f:
    f.write(b"x" * (2 * 1024 * 1024) + b"beyond-old-default-cap")
PY

out="$($bin --gitignore '*' "$fixture/tree")"
! grep -q 'build/drop.tmp' <<< "$out"
grep -q 'build/keep.txt' <<< "$out"
! grep -q 'src/generated/drop.nim' <<< "$out"
grep -q 'src/generated/keep.nim' <<< "$out"
subtree_out="$($bin --gitignore '*' "$fixture/tree/src/generated")"
! grep -q 'drop.nim' <<< "$subtree_out"
grep -q 'keep.nim' <<< "$subtree_out"

# Literal content matching spans read boundaries and scans whole files unless
# the user explicitly supplies --max-bytes.
"$bin" --fixed boundary.txt "$fixture/tree" --contains cross-boundary-needle >/dev/null
"$bin" --fixed large.txt "$fixture/tree" --contains beyond-old-default-cap >/dev/null
"$bin" --ignore-case --fixed case.txt "$fixture/tree" --contains mixedcaseneedle >/dev/null
"$bin" --smart-case --fixed case.txt "$fixture/tree" --contains mixedcaseneedle >/dev/null
if "$bin" --fixed large.txt "$fixture/tree" --contains beyond-old-default-cap --max-bytes 1M >/dev/null 2>&1; then
  printf '%s\n' '--max-bytes cap was not enforced' >&2
  exit 1
fi

# Following a directory cycle must terminate and must not duplicate forever.
timeout 5 "$bin" --follow --limit 100 '*' "$fixture/tree" >/dev/null

# Metadata-backed output must contain the real size, not a zero placeholder.
long_out="$($bin --long --fixed index.nim "$fixture/tree")"
grep -Eq '[[:space:]]22[[:space:]]' <<< "$long_out"

# Exec errors propagate to the caller.
if "$bin" --fixed index.nim "$fixture/tree" --exec-cmd /bin/false; then
  printf '%s\n' '--exec-cmd failure was not propagated' >&2
  exit 1
fi

# NUL output remains unambiguous for hostile/newline-containing names.
newline_name=$'line\nbreak.txt'
printf x > "$fixture/tree/$newline_name"
PRINT0_BIN="$bin" PRINT0_ROOT="$fixture/tree" python3 - <<'PY'
import os, subprocess
p = subprocess.run([os.environ["PRINT0_BIN"], "--print0", "--fixed", "break.txt", os.environ["PRINT0_ROOT"]], check=True, stdout=subprocess.PIPE)
items = [x for x in p.stdout.split(b"\0") if x]
assert items == [b"line\nbreak.txt"], items
PY

# Compact index answers are equivalent and the file has the binary signature.
export FASTFIND_INDEX="$fixture/test.ffidx"
"$bin" --rebuild-index "$fixture/tree" >/dev/null
[ "$(head -c 8 "$FASTFIND_INDEX")" = 'FFIDX004' ]
live_count="$($bin --count --extension nim '*' "$fixture/tree")"
index_count="$($bin --use-index --count --extension nim '*' "$fixture/tree")"
[ "$live_count" = "$index_count" ]
[ "$index_count" = 3 ]

# Corruption is rejected in index-only mode instead of silently succeeding.
truncate -s 30 "$FASTFIND_INDEX"
if "$bin" --use-index --index-only --fixed index.nim "$fixture/tree" >/dev/null 2>&1; then
  printf '%s\n' 'corrupt index was accepted' >&2
  exit 1
fi

printf '%s\n' 'CLI regression tests passed'
