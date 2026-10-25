#!/usr/bin/env bash
# Exercise local installation helpers only; no network or privilege changes.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-install-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

for platform in linux darwin freebsd openbsd netbsd; do
  (
    unset MAN_DIR
    export PREFIX="$fixture/$platform" BIN_DIR="$fixture/$platform/bin"
    source "$repo/update.sh"
    OS="$platform"
    finalize_paths
    case "$platform" in
      freebsd|openbsd|netbsd) expected="$PREFIX/man/man1" ;;
      *) expected="$PREFIX/share/man/man1" ;;
    esac
    [ "$MAN_DIR" = "$expected" ]
    [ "$MAN_DIR_EXPLICIT" -eq 0 ]
    export QUIET=1
    TMP_MAN="$repo/mandoc/ff.1"
    install_manpages
    cmp "$TMP_MAN" "$MAN_DIR/ff.1"
    cmp "$TMP_MAN" "$MAN_DIR/fastfind.1"
  )
done

(
  export MAN_DIR="$fixture/custom manual/man1"
  source "$repo/update.sh"
  export OS=freebsd
  finalize_paths
  [ "$MAN_DIR" = "$fixture/custom manual/man1" ]
  [ "$MAN_DIR_EXPLICIT" -eq 1 ]
)
printf '%s\n' 'Installer and updater man-page regression tests passed'
