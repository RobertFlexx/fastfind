#!/bin/sh
set -eu
export PATH="/usr/local/bin:/usr/pkg/bin:/usr/pkg/sbin:$PATH"
case "${1:?BSD platform required}" in
  freebsd) pkg install -y nim pcre ;;
  openbsd) pkg_add -I nim pcre ;;
  netbsd)
    if command -v pkgin >/dev/null 2>&1; then
      pkgin -y update
      pkgin -y install nim pcre
    else
      pkg_add -u nim pcre
    fi
    ;;
  *) echo 'unsupported BSD platform' >&2; exit 2 ;;
esac
