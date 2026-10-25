#!/usr/bin/env python3
"""Check portable man source, rendered text, and installed command aliases."""
import argparse
from html.parser import HTMLParser
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


class HTMLText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)


def plain_text(text):
    # Terminal man output can use overstrikes for bold/underline and ANSI SGR.
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    while '\b' in text:
        stripped = re.sub(r'[^\n]\x08', '', text)
        if stripped == text:
            raise AssertionError('unpaired backspace in rendered page')
        text = stripped
    return ' '.join(text.split())


def check_rendering(label, output):
    text = plain_text(output)
    for expected in [
        'fastfind, ff - file search with fuzzy matching and git awareness',
        'fastfind [OPTIONS] [PATTERN] [PATH ...]',
        'fastfind "natural language query"',
        'fastfind --interactive',
        'ff [OPTIONS] [PATTERN] [PATH ...]',
        "fastfind --regex '\\.py$'",
        "fastfind --regex 'test_[0-9]+\\.rs'",
        "fastfind \"*.nim\" --contains-re 'proc\\s+parse'",
        "fastfind \"*\" --size '>10M'",
        "fastfind \"*\" --size '<100K'",
        'Universal wildcard fast path',
        'Case Sensitivity',
        'https://github.com/RobertFlexx/fastfind/blob/main/LICENSE',
    ]:
        assert expected in text, (label, 'missing rendered text', expected)
    for artifact in [r'\-', r'\fB', r'\fI', r'\fR', r'\e', '\ufffd']:
        assert artifact not in text, (label, 'rendering artifact', artifact)
    print(f'PASS: {label}')


def check_source(source):
    # Stay within the classic man macros and roff requests shared by the
    # BSD, GNU and System V formatters; no GNU EX/SY/UR extensions or tbl.
    macros = {'TH', 'SH', 'SS', 'PP', 'TP', 'IP', 'B', 'I', 'BR', 'BI',
              'IR', 'IB', 'RB', 'RI', 'nf', 'fi', 'nh'}
    nofill = False
    for number, line in enumerate(source.splitlines(), 1):
        assert line.isascii(), (number, 'use portable roff escapes for non-ASCII')
        if line.startswith('.'):
            macro = line[1:].split()[0]
            assert macro in macros, (number, 'nonportable macro', macro)
            if macro == 'nf':
                assert not nofill, (number, 'nested no-fill block')
                nofill = True
            elif macro == 'fi':
                assert nofill, (number, 'unmatched fill request')
                nofill = False
        assert not line.startswith("'"), (number, 'unescaped roff control line')
        # In this document literal backslashes use \e. A doubled escape is
        # almost certainly accidental JSON/string escaping (the original bug).
        assert '\\\\' not in line, (number, 'doubled roff escape')
    assert not nofill, 'unterminated no-fill block'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('page', nargs='?', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'mandoc/ff.1')
    parser.add_argument('--require', action='append', default=[],
                        choices=['mandoc', 'groff', 'nroff', 'man'],
                        help='fail if this formatter/viewer is unavailable (repeatable)')
    args = parser.parse_args()
    page = args.page.resolve()
    check_source(page.read_text(encoding='ascii'))
    commands = {name: shutil.which(name) for name in ['mandoc', 'groff', 'nroff', 'man']}
    for name in args.require:
        assert commands[name], f'required command is missing: {name}'
    assert any(commands.values()), 'install mandoc, groff, nroff, or man to test rendering'
    env = dict(os.environ, LC_ALL='C', TERM='dumb', COLUMNS='80', MANWIDTH='80',
               PAGER='cat', MANPAGER='cat', MANOPT='', MANROFFOPT='',
               GROFF_NO_SGR='1')

    def run(command):
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
        assert result.returncode == 0, (command, result.returncode,
                                        result.stderr.decode(errors='replace'))
        return result.stdout.decode('utf-8', errors='strict'), result.stderr

    if commands['mandoc']:
        output, errors = run([commands['mandoc'], '-Tlint', '-Wall', str(page)])
        assert not output and not errors, ('mandoc lint', output, errors)
        for device in ['ascii', 'utf8', 'html']:
            output, errors = run([commands['mandoc'], '-T' + device, str(page)])
            assert not errors, ('mandoc', device, errors)
            if device == 'html':
                html = HTMLText()
                html.feed(output)
                output = ''.join(html.parts)
            check_rendering('mandoc ' + device, output)

    if commands['groff']:
        for options in [[], ['-C']]:
            output, errors = run([commands['groff'], *options, '-Tascii', '-man',
                                  '-ww', str(page)])
            assert not errors, ('groff', options, errors)
            check_rendering('groff' + (' compatibility mode' if options else ''), output)

    if commands['nroff']:
        # No GNU device/options: this invocation also works with System V nroff.
        output, errors = run([commands['nroff'], '-man', str(page)])
        assert not errors, ('nroff', errors)
        check_rendering('nroff -man', output)

    if commands['man']:
        with tempfile.TemporaryDirectory(prefix='fastfind-man-') as directory:
            root = Path(directory)
            (root / 'man1').mkdir()
            # The installer and release archives ship two complete sources.
            # Avoid .so aliases, whose resolution varies between man systems.
            for name in ['ff', 'fastfind']:
                shutil.copyfile(page, root / 'man1' / (name + '.1'))
            env['MANPATH'] = str(root)
            for name in ['ff', 'fastfind']:
                output, _ = run([commands['man'], '-M', str(root), name])
                check_rendering('man ' + name, output)


if __name__ == '__main__':
    main()
