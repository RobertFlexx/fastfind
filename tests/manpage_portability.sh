#!/bin/sh
# Native man/nroff smoke test without Python or GNU utility dependencies.
set -eu
LC_ALL=C
TERM=dumb
PAGER='cat'
MANPAGER='cat'
MANOPT=
MANROFFOPT=
GROFF_NO_SGR=1
export LC_ALL TERM PAGER MANPAGER MANOPT MANROFFOPT GROFF_NO_SGR

page="${1:-mandoc/ff.1}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-man.XXXXXX")"
trap 'rm -rf "$fixture"' 0
trap 'exit 1' 1 2 15
mkdir "$fixture/man1"
cp "$page" "$fixture/man1/ff.1"
cp "$page" "$fixture/man1/fastfind.1"

check_output() {
  col -b < "$fixture/rendered" > "$fixture/plain"
  for artifact in '\-' '\fB' '\fI' '\fR' '\e'; do
    if grep -F -e "$artifact" "$fixture/plain"; then
      printf 'rendering artifact in %s\n' "$1" >&2
      exit 1
    fi
  done
  grep -F 'fastfind, ff - file search' "$fixture/plain" > /dev/null
  grep -F 'fastfind [OPTIONS] [PATTERN] [PATH ...]' "$fixture/plain" > /dev/null
  grep -F -e "--regex '\.py\$'" "$fixture/plain" > /dev/null
  grep -F 'https://github.com/RobertFlexx/fastfind/blob/main/LICENSE' "$fixture/plain" > /dev/null
  printf 'PASS: %s\n' "$1"
}

formatters=0
if command -v mandoc > /dev/null 2>&1; then
  mandoc -Tlint -Wall "$page"
  mandoc -Tascii "$page" > "$fixture/rendered"
  check_output mandoc
  formatters=$((formatters + 1))
fi
if command -v nroff > /dev/null 2>&1; then
  nroff -man "$page" > "$fixture/rendered"
  check_output 'nroff -man'
  formatters=$((formatters + 1))
fi
if [ "$formatters" -eq 0 ]; then
  printf '%s\n' 'mandoc or nroff is required' >&2
  exit 1
fi

MANPATH="$fixture"
export MANPATH
for name in ff fastfind; do
  man -M "$fixture" "$name" > "$fixture/rendered"
  check_output "man $name"
done
