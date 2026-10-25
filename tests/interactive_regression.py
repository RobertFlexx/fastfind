#!/usr/bin/env python3
"""Exercise the real UI through a PTY, including terminal restoration."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = str(Path(sys.argv[1]).resolve())


class Terminal:
    def __init__(self, root, width=110, height=28, piped=False):
        self.master, self.slave = pty.openpty()
        self.resize(width, height)
        self.before = termios.tcgetattr(self.slave)
        self.output = bytearray()
        self.proc = subprocess.Popen([binary, '--no-config', '--interactive', '*', str(root)],
                                     cwd=root.parent, stdin=self.slave,
                                     stdout=subprocess.PIPE if piped else self.slave,
                                     stderr=self.slave,
                                     env=dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8'))
        self.until(b'BROWSE')

    def resize(self, width, height):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))

    def read(self, duration=.15):
        end = time.monotonic() + duration
        data = bytearray()
        while time.monotonic() < end:
            ready, _, _ = select.select([self.master], [], [], max(0, end - time.monotonic()))
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                data.extend(chunk)
        self.output.extend(data)
        return bytes(data)

    def until(self, token, timeout=5):
        data = bytearray()
        end = time.monotonic() + timeout
        while token not in data and time.monotonic() < end:
            data.extend(self.read(.05))
            assert self.proc.poll() is None or token in data, (self.proc.returncode, data[-1000:])
        assert token in data, (token, data[-1000:])
        return bytes(data)

    def send(self, value):
        os.write(self.master, value)

    def finish(self, key=b'\x03'):
        if self.proc.poll() is None:
            self.send(key)
        end = time.monotonic() + 5
        while self.proc.poll() is None and time.monotonic() < end:
            self.read(.05)
        if self.proc.poll() is None:
            self.proc.kill()
            raise AssertionError('interactive mode hung')
        self.read(.05)
        assert self.proc.returncode == 0, (self.proc.returncode, self.output[-1000:])
        after = termios.tcgetattr(self.slave)
        before = self.before.copy()
        # BSD kernels can set PENDIN while restoring canonical input. This
        # transient flag requests retyping queued input at the next read.
        pending = getattr(termios, 'PENDIN', 0)
        before[3] &= ~pending
        after[3] &= ~pending
        assert after == before, 'terminal attributes were not restored'
        assert b'\x1b[?1049l' in self.output, 'alternate screen was not restored'
        assert b'\x1b[?2004l' in self.output, 'bracketed paste was not disabled'
        result = self.proc.stdout.read() if self.proc.stdout else b''
        os.close(self.master)
        os.close(self.slave)
        return result


with tempfile.TemporaryDirectory(prefix='fastfind-tui-') as directory:
    root = Path(directory) / 'workspace'
    root.mkdir()
    (root / '00 huge.txt').write_bytes(b'x' * (8 * 1024 * 1024))
    os.mkfifo(root / '01 pipe')
    (root / 'select me.txt').write_text('first line\nsecond line\n')
    (root / '日本語.txt').write_text('Unicode preview\n')
    (root / 'hostile\x1b]52;c;evil\x07.txt').touch()
    (root / 'subdir').mkdir()
    (root / 'subdir' / 'nested.txt').write_text('recursive result\n')

    terminal = Terminal(root)
    assert os.fsencode(root) in terminal.output, 'UI ignored the requested root'
    assert b'\x1b]52;c;evil' not in terminal.output, 'filename injected an OSC sequence'
    terminal.send(b'/00 huge.txt')
    terminal.until(b'00 huge.txt')
    terminal.read(.2)
    assert terminal.proc.poll() is None
    terminal.send(b'\x1b')
    terminal.read(.1)
    terminal.send(b'/01 pipe')
    terminal.until(b'Preview unavailable')
    terminal.send(b'\x1b')
    terminal.read(.1)
    terminal.send('/日本語.txt'.encode())
    terminal.until(b'Unicode preview')
    terminal.send(b'\x7f')
    terminal.read(.1)
    # Fast Escape-then-filter must preserve the slash and following text.
    terminal.send(b'\x1b/01 pipe')
    terminal.until(b'Preview unavailable')
    terminal.send(b'\x1b')
    terminal.read(.15)
    # An arrow sequence may arrive in separate reads.
    for part in [b'\x1b', b'[', b'B']:
        terminal.send(part)
        time.sleep(.005)
    arrow_output = terminal.read(.1)
    assert b'Bookmarks' not in arrow_output, arrow_output[-1000:]
    # A scheduling delay after CSI must not turn its final B into Bookmarks.
    terminal.send(b'\x1b[')
    time.sleep(.35)
    terminal.send(b'B')
    arrow_output = terminal.read(.15)
    assert b'Bookmarks' not in arrow_output, arrow_output[-1000:]
    for width, height in [(40, 10), (5, 3), (110, 28)]:
        terminal.resize(width, height)
        terminal.read(.2)
        assert terminal.proc.poll() is None, (width, height)
    # Pasted navigation/commands are text, never automatic actions.
    terminal.send(b'\x1b[200~:rm\ry\rq\x1b[201~')
    terminal.until(b'Paste into')
    assert (root / '00 huge.txt').exists()
    terminal.send(b':filter \r')
    terminal.read(.1)
    terminal.send(b'?')
    terminal.until(b'keyboard shortcuts')
    terminal.send(b' ')
    terminal.read(.1)
    terminal.send(b'\x1b')
    terminal.read(.1)
    terminal.send(b'g*.txt\r')
    # A directory preview may already contain nested.txt. Wait for search
    # completion before checking the result instead of racing the worker.
    completed_search = terminal.until(b'Found ')
    assert b'nested.txt' in completed_search, completed_search[-1000:]
    Path('/tmp/fastfind-tui-capture.ansi').write_bytes(terminal.output)
    terminal.finish()

    # Selecting into a pipe must keep all UI bytes on the terminal.
    terminal = Terminal(root, width=55, piped=True)
    terminal.send(b'/select me.txt\r')
    terminal.read(.2)
    terminal.send(b':rm\r')
    terminal.until(b'y/n')
    terminal.send(b'n')
    terminal.read(.1)
    assert (root / 'select me.txt').exists(), 'cancelled deletion removed a file'
    result = terminal.finish(b'\r')
    assert result == os.fsencode(root / 'select me.txt') + b'\n', result

    for signum in [signal.SIGINT, signal.SIGTERM]:
        terminal = Terminal(root)
        terminal.proc.send_signal(signum)
        terminal.finish()

result = subprocess.run([binary, '--no-config', '--interactive'], input=b'',
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
assert result.returncode == 2 and b'requires a terminal' in result.stderr
print('Interactive PTY regression tests passed')
