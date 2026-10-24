#!/bin/sh
set -eu
export PATH="/usr/local/bin:/usr/pkg/bin:/usr/pkg/sbin:$PATH"
platform="${1:?BSD platform required}"
case "$platform" in
  freebsd|openbsd) prefix=/usr/local; compiler=clang ;;
  netbsd) prefix=/usr/pkg; compiler=gcc ;;
  *) echo 'unsupported BSD platform' >&2; exit 2 ;;
esac
pcre_archive="$prefix/lib/libpcre.a"
test -f "$pcre_archive"
nim --version
mkdir -p dist
binary="dist/ff-$platform-amd64"

nim c --mm:orc --threads:on -d:release -d:usePcreHeader --opt:speed \
  "--cc:$compiler" --passC:-flto --passL:-flto \
  "--passC:-I$prefix/include" "--passL:$pcre_archive" \
  "-o:$binary" src/ff.nim
strip "$binary"
chmod 0755 "$binary"
"$binary" --version
file "$binary"
if ldd "$binary" | grep -i pcre; then
  echo 'PCRE was linked dynamically' >&2
  exit 1
fi

# Native execution catches ABI, threading, filesystem and regex issues that
# cross-compilation alone cannot establish.
for suite in test_nlp test_engine; do
  nim c -r --mm:orc --threads:on -d:usePcreHeader "--cc:$compiler" \
    "--passC:-I$prefix/include" "--passL:$pcre_archive" \
    "-o:dist/$suite" "tests/$suite.nim"
done
fixture="$(mktemp -d /tmp/fastfind-bsd.XXXXXXXX)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir "$fixture/sub"
printf 'TODO FIXME\n' > "$fixture/sub/main.nim"
printf 'plain text\n' > "$fixture/plain.txt"
mkfifo "$fixture/pipe"
serial="$("$binary" -j 1 --count '*' "$fixture")"
parallel="$("$binary" -j 4 --count '*' "$fixture")"
test "$serial" = "$parallel"
test "$("$binary" --query 'how many Nim files' "$fixture")" = 1
test "$("$binary" --name --regex '^main[.]nim$' "$fixture")" = sub/main.nim
test "$("$binary" --query 'Nim files containing TODO and FIXME' "$fixture")" = sub/main.nim
test "$("$binary" --count --type file '*' "$fixture")" = 2

package_root="package/fastfind-$platform-amd64"
mkdir -p "$package_root/share/man/man1"
cp "$binary" "$package_root/ff"
ln -s ff "$package_root/fastfind"
cp LICENSE README.md "$package_root/"
cp mandoc/ff.1 "$package_root/share/man/man1/ff.1"
cp mandoc/ff.1 "$package_root/share/man/man1/fastfind.1"
uname -sr > "$package_root/BUILD-INFO.txt"
nim --version >> "$package_root/BUILD-INFO.txt"
tar -C package -czf "dist/fastfind-$platform-amd64.tar.gz" "fastfind-$platform-amd64"
