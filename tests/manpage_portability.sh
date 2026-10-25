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
COLUMNS=80
MANWIDTH=80
export LC_ALL TERM PAGER MANPAGER MANOPT MANROFFOPT GROFF_NO_SGR COLUMNS MANWIDTH

page="${1:-mandoc/ff.1}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-man.XXXXXX")"
trap 'rm -rf "$fixture"' 0
trap 'exit 1' 1 2 15
mkdir "$fixture/man1"
cp "$page" "$fixture/man1/ff.1"
cp "$page" "$fixture/man1/fastfind.1"

contains_text() {
  # System V /usr/bin/grep lacks -F and -e. Pass literals through the
  # environment so awk does not reinterpret regexes or backslash escapes.
  FF_MAN_TEXT="$1" awk 'index($0, ENVIRON["FF_MAN_TEXT"]) { found = 1 }
    END { exit !found }' "$fixture/plain"
}

check_output() {
  # Native col may replace runs of spaces with tabs. Check text independently
  # of layout, just as the Python rendering regression does.
  col -b < "$fixture/rendered" | awk '{$1=$1; print}' > "$fixture/plain"
  for artifact in '\-' '\fB' '\fI' '\fR' '\e'; do
    if contains_text "$artifact"; then
      printf 'rendering artifact in %s\n' "$1" >&2
      exit 1
    fi
  done
  for expected in 'fastfind, ff - file search' \
    'fastfind [OPTIONS] [PATTERN] [PATH ...]' \
    "--regex '\.py\$'" \
    'https://github.com/RobertFlexx/fastfind/blob/main/LICENSE'; do
    if ! contains_text "$expected"; then
      printf 'missing rendered text in %s: %s\n' "$1" "$expected" >&2
      cat "$fixture/plain" >&2
      exit 1
    fi
  done
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
