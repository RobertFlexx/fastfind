# Manual maintenance

`ff.1` is roff source using the classic `man` macros. The installer and Unix
release archives copy it to both `man1/ff.1` and `man1/fastfind.1`. Ship these
sources unchanged; preformatted output and `.so` aliases depend on the local
formatter, terminal, and search path.

Keep the source ASCII and use the common macros documented by
[man(7)](https://mandoc.bsd.lv/man/man.7.html). Use `.nf`/`.fi` for examples,
`.TP` with `.B` for option labels, and `.PP` between synopsis forms. Avoid
GNU-only macros such as `.EX`, `.SY`, and `.UR`, or external preprocessors.
The `.nh` request prevents groff from inserting hyphens into URLs and text.

Roff escapes are written once in this file: `\-` prints an option minus,
`\fI`/`\fR` change fonts, and `\e` prints a literal backslash in a regex.
Do not double these escapes as if the source were a JSON or language string.
Quote shell size comparisons (`'>10M'`, `'<100K'`) so examples do not redirect
input or output.

Run from the repository root:

```sh
nimble test_man
python3 tests/manpage_regression.py --require mandoc --require groff --require nroff --require man
sh tests/manpage_portability.sh
bash tests/installer_regression.sh
```

The Python check validates ASCII/UTF-8/HTML output from mandoc, normal and
compatibility-mode groff output, nroff, and both names in a temporary man
hierarchy. Missing optional renderers are skipped unless `--require` names
them. The shell check needs only native man, col, and mandoc or nroff. Neither
check changes the installed system manual pages.

CI runs the full rendering checks on Linux and macOS, the shell check in the
FreeBSD/OpenBSD/NetBSD build VMs, and native man-page checks on Solaris 11.4
and OmniOS (illumos). These jobs run after the changes reach GitHub; local
formatter results do not substitute for native VM results.

The search engine detects whether `struct dirent` actually has `d_type`.
Solaris and illumos use the existing `lstat` fallback. To exercise that same
code path on Linux, macOS, or BSD, build with `-d:fastfindNoDType` and run the
CLI and search regression suites. CI also generates C for each POSIX target
with threads on and off; Nim's `solaris` target covers Solaris and illumos.
C generation checks Nim declarations and branches, not target C headers,
linking, or native execution.
