#!/usr/bin/env bash
# Exercise local installation helpers only; no network or privilege changes.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-install-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

for platform in linux darwin freebsd openbsd netbsd dragonflybsd solaris omnios openindiana tribblix; do
  (
    unset MAN_DIR
    export PREFIX="$fixture/$platform" BIN_DIR="$fixture/$platform/bin"
    source "$repo/update.sh"
    OS="$platform"
    finalize_paths
    case "$platform" in
      freebsd|openbsd|netbsd|dragonflybsd) expected="$PREFIX/man/man1" ;;
      *) expected="$PREFIX/share/man/man1" ;;
    esac
    [ "$MAN_DIR" = "$expected" ]
    [ "$MAN_DIR_EXPLICIT" -eq 0 ]
    export QUIET=1
    TMP_MAN="$repo/mandoc/ff.1"
    install_manpages
    cmp "$TMP_MAN" "$MAN_DIR/ff.1"
    cmp "$TMP_MAN" "$MAN_DIR/fastfind.1"
    ARCH=amd64
    os_token_matches "ff-$platform-amd64"
    ! os_token_matches 'ff-unrelated-amd64'
    arch_token_matches "ff-$platform-amd64"
    ! arch_token_matches "ff-$platform-arm64"
  )
done

(
  source "$repo/install.sh"
  [ "$(sunos_platform_id 'Oracle Solaris 11.4')" = solaris ]
  [ "$(sunos_platform_id 'OmniOS r151058')" = omnios ]
  [ "$(sunos_platform_id 'OpenIndiana Hipster 2026.04')" = openindiana ]
  [ "$(sunos_platform_id 'Tribblix 0m41')" = tribblix ]
  uname() { case "$1" in -s) printf '%s' SunOS ;; -m) printf '%s' i86pc ;; esac; }
  isainfo() { printf '%s' 64; }
  detect_platform
  [ "$ARCH" = amd64 ]
  # Body links must not become candidate binaries; parse only real assets.
  urls="$(extract_browser_download_urls '{"body":"https://github.com/x/y/releases/download/v1/poc","assets":[{"browser_download_url":"https://github.com/x/y/releases/download/v1/ff-solaris-amd64"}]}')"
  [ "$urls" = https://github.com/x/y/releases/download/v1/ff-solaris-amd64 ]
  OS=solaris
  mkdir -p "$fixture/atomic"
  printf 'new binary' > "$fixture/source"
  printf 'preserve target' > "$fixture/victim"
  ln -s "$fixture/victim" "$fixture/atomic/ff"
  install_file_mode 755 "$fixture/source" "$fixture/atomic/ff"
  [ ! -L "$fixture/atomic/ff" ]
  [ "$(cat "$fixture/atomic/ff")" = 'new binary' ]
  [ "$(cat "$fixture/victim")" = 'preserve target' ]
)

(
  export MAN_DIR="$fixture/custom manual/man1"
  source "$repo/update.sh"
  export OS=freebsd
  finalize_paths
  [ "$MAN_DIR" = "$fixture/custom manual/man1" ]
  [ "$MAN_DIR_EXPLICIT" -eq 1 ]
)
printf '%s\n' 'Installer and updater man-page regression tests passed'
