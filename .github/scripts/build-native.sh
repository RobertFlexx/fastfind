#!/bin/sh
set -eu
platform="${1:?native platform required}"
root="$PWD"
bundle="$root/build/native"
export PATH="/usr/xpg4/bin:/usr/gnu/bin:/usr/local/bin:/usr/bin:/usr/sbin:/usr/ccs/bin:/opt/tribblix/bin:$PATH"
case "$platform" in
  dragonflybsd) target=dragonfly ;;
  solaris|omnios|openindiana|tribblix) target=solaris ;;
  linux) target=linux ;;
  *) echo 'unsupported native platform' >&2; exit 2 ;;
esac
if [ -z "${CC:-}" ]; then
  for candidate in /opt/gcc-*/bin/gcc /opt/gcc*/bin/gcc /usr/gcc/*/bin/gcc \
      /usr/local/bin/gcc /usr/local/bin/gcc[0-9]* /usr/bin/gcc /usr/bin/cc; do
    if [ -x "$candidate" ]; then CC="$candidate"; break; fi
  done
fi
: "${CC:?native C compiler not found}"
export CC
export PATH="$(dirname "$CC"):$PATH"
printf 'Native compiler: %s\n' "$CC"
"$CC" --version
if command -v gmake >/dev/null 2>&1; then make_cmd=gmake; else make_cmd=make; fi
prefix="$root/build/native-pcre"
mkdir -p "$prefix/lib" "$prefix/include" "$root/dist"
(
  cd "$bundle/pcre"
  # Artifact extraction and SCP can reorder mtimes. Release-style timestamps
  # prevent make from unexpectedly regenerating autotools files in the VM.
  find . -type f -exec touch -t 200001010000 {} +
  if ! MAKE="$make_cmd" CFLAGS='-O3 -m64 -fPIC' LDFLAGS=-m64 sh ./configure --prefix="$prefix" \
    --disable-shared --enable-static --disable-cpp --enable-utf \
    --enable-unicode-properties --enable-jit \
    --disable-dependency-tracking --disable-pcregrep-libz --disable-pcregrep-libbz2; then
    cat config.log >&2
    exit 1
  fi
  "$make_cmd" -j2 libpcre.la
  cp .libs/libpcre.a "$prefix/lib/"
  cp pcre.h "$prefix/include/"
)
compile_program() {
  name="$1"
  directory="$bundle/$target/$name"
  for source in "$directory"/*.c; do
    "$CC" -c -m64 -O3 -flto -w -fmax-errors=3 -fno-strict-aliasing -pthread \
      -D_POSIX_PTHREAD_SEMANTICS -D__EXTENSIONS__ \
      -Wno-error=incompatible-pointer-types -I"$bundle" -I"$prefix/include" \
      "$source" -o "$source.o"
  done
  set --
  for library in $(cat "$directory/LINK-LIBRARIES.txt"); do set -- "$@" "$library"; done
  if [ "$target" = solaris ]; then
    "$CC" -m64 -flto -pthread -o "$root/dist/$name" "$directory"/*.c.o \
      "$prefix/lib/libpcre.a" "$@" -lrt -lsocket -lnsl
  else
    "$CC" -m64 -flto -pthread -o "$root/dist/$name" "$directory"/*.c.o \
      "$prefix/lib/libpcre.a" "$@"
  fi
}
for program in ff ff-serial test_nlp test_engine test_tui_input; do
  compile_program "$program"
done
for suite in test_nlp test_engine test_tui_input; do "$root/dist/$suite"; done
sh .github/scripts/native-smoke.sh dist/ff
sh .github/scripts/native-smoke.sh dist/ff-serial
sh tests/manpage_portability.sh
binary="dist/ff-$platform-amd64"
cp dist/ff "$binary"
strip "$binary"
chmod 0755 "$binary"
"$binary" --version
file "$binary"
if ldd "$binary" | grep -i pcre; then echo 'PCRE was not linked statically' >&2; exit 1; fi
package="package/fastfind-$platform-amd64"
mkdir -p "$package/share/man/man1"
cp "$binary" "$package/ff"
ln -s ff "$package/fastfind"
cp LICENSE README.md "$package/"
cp "$bundle/pcre/LICENCE" "$package/PCRE-LICENSE.txt"
cp mandoc/ff.1 "$package/share/man/man1/ff.1"
cp mandoc/ff.1 "$package/share/man/man1/fastfind.1"
uname -a > "$package/BUILD-INFO.txt"
if [ -f /etc/release ]; then cat /etc/release >> "$package/BUILD-INFO.txt"; fi
cat "$bundle/NIM-VERSION.txt" "$bundle/PCRE-SOURCE.txt" >> "$package/BUILD-INFO.txt"
"$CC" --version >> "$package/BUILD-INFO.txt"
(cd package && tar cf "$root/dist/fastfind-$platform-amd64.tar" "fastfind-$platform-amd64")
gzip -f "dist/fastfind-$platform-amd64.tar"
