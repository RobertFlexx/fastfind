#!/bin/sh
set -eux
binary="${1:?binary required}"
case "$binary" in /*) ;; *) binary="$PWD/$binary" ;; esac
fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-native.XXXXXXXX")"
trap 'rm -rf "$fixture"; rm -f "$fixture.serial" "$fixture.parallel"' 0
trap 'exit 1' 1 2 15
mkdir -p "$fixture/deep/a/b/c"
printf 'TODO FIXME\n' > "$fixture/deep/a/b/c/main.nim"
printf 'ordinary text\n' > "$fixture/plain.txt"
mkfifo "$fixture/pipe"
test "$("$binary" --query 'how many Nim files' "$fixture")" = 1
test "$("$binary" --name --regex '^main[.]nim$' "$fixture")" = deep/a/b/c/main.nim
test "$("$binary" --query 'Nim files containing TODO and FIXME' "$fixture")" = deep/a/b/c/main.nim
test "$("$binary" --count --type file '*' "$fixture")" = 2
i=0
while [ "$i" -lt 64 ]; do
  mkdir "$fixture/deep/a/b/c/branch$i"
  : > "$fixture/deep/a/b/c/branch$i/file.txt"
  i=$((i + 1))
done
"$binary" -j1 --hidden '*' "$fixture" | LC_ALL=C sort > "$fixture.serial"
expected="$("$binary" -j1 --hidden --count '*' "$fixture")"
for workers in 2 8 32; do
  "$binary" "-j$workers" --hidden '*' "$fixture" | LC_ALL=C sort > "$fixture.parallel"
  cmp "$fixture.serial" "$fixture.parallel"
  test "$("$binary" "-j$workers" --hidden --count '*' "$fixture")" = "$expected"
done
rm -f "$fixture.serial" "$fixture.parallel"
printf 'PASS: native CLI, NLP, regex, FIFO safety and serial/parallel traversal\n'
