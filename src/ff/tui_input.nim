## Stateful terminal input decoding. A partial control sequence must never
## become a browse command merely because its bytes arrive in separate reads.
import std/strutils
from tui_text import safeText

type
  TerminalKey* = object
    kind*: string
    ch*: char
    text*: string

  EscapeState = enum
    escapeNone, escapeStart, escapeSequence

  InputDecoder* = object
    escape: EscapeState
    sequence: string
    sequenceTooLong: bool
    pending: char
    hasPending: bool
    pasteActive: bool
    pasteBuffer: string

proc timeoutMs*(decoder: InputDecoder): int =
  case decoder.escape
  of escapeStart: 100
  of escapeSequence: 250
  of escapeNone:
    if decoder.pasteActive: 20 else: 100

proc readingControl*(decoder: InputDecoder): bool =
  decoder.escape != escapeNone or decoder.pasteActive

proc takePending*(decoder: var InputDecoder; ch: var char): bool =
  if decoder.hasPending:
    ch = decoder.pending
    decoder.hasPending = false
    result = true

proc expire*(decoder: var InputDecoder): TerminalKey =
  case decoder.escape
  of escapeStart:
    result.kind = "escape"
    decoder.escape = escapeNone
    decoder.sequence.setLen(0)
  # A read timeout does not delimit CSI/SS3. Keep the bounded sequence until
  # its final byte, another Escape, or Ctrl+C, even across long pauses.
  of escapeSequence: result.kind = "none"
  of escapeNone: result.kind = "none"

proc feed*(decoder: var InputDecoder; ch: char): TerminalKey =
  if decoder.pasteActive:
    decoder.pasteBuffer.add(ch)
    # Keep a bounded prefix and the terminator, even for oversized pastes.
    if decoder.pasteBuffer.len > 65542:
      decoder.pasteBuffer.delete(65536..65536)
    if decoder.pasteBuffer.endsWith("\x1b[201~"):
      decoder.pasteActive = false
      decoder.pasteBuffer.setLen(decoder.pasteBuffer.len - 6)
      result = TerminalKey(kind: "paste", text: safeText(decoder.pasteBuffer).
        replace("\\x0a", " ").replace("\\x0d", " "))
      decoder.pasteBuffer.setLen(0)
      return
    return TerminalKey(kind: "none")

  if ch == '\x03':
    decoder.escape = escapeNone
    return TerminalKey(kind: "ctrl-c")
  if ch == '\x1b':
    decoder.escape = escapeStart
    return TerminalKey(kind: "none")

  case decoder.escape
  of escapeStart:
    if ch in {'[', 'O'}:
      decoder.escape = escapeSequence
      decoder.sequence.setLen(0)
      decoder.sequenceTooLong = false
      return TerminalKey(kind: "none")
    decoder.escape = escapeNone
    # Deliver both keys when Escape and ordinary text arrive together.
    # Dropping the next byte loses fast Esc-then-/ navigation.
    decoder.pending = ch
    decoder.hasPending = true
    return TerminalKey(kind: "escape")
  of escapeSequence:
    if decoder.sequence.len < 32: decoder.sequence.add(ch)
    else: decoder.sequenceTooLong = true
    if ch notin {'@'..'~'}: return TerminalKey(kind: "none")
    decoder.escape = escapeNone
    if decoder.sequenceTooLong: return TerminalKey(kind: "unknown")
    case decoder.sequence
    of "A": return TerminalKey(kind: "up")
    of "B": return TerminalKey(kind: "down")
    of "C": return TerminalKey(kind: "right")
    of "D": return TerminalKey(kind: "left")
    of "H", "1~", "7~": return TerminalKey(kind: "home")
    of "F", "4~", "8~": return TerminalKey(kind: "end")
    of "5~": return TerminalKey(kind: "pageup")
    of "6~": return TerminalKey(kind: "pagedown")
    of "3~": return TerminalKey(kind: "delete")
    of "200~":
      decoder.pasteActive = true
      decoder.pasteBuffer.setLen(0)
      return TerminalKey(kind: "none")
    else: return TerminalKey(kind: "unknown")
  of escapeNone: discard

  case ch
  of '\r', '\n': TerminalKey(kind: "enter")
  of '\t': TerminalKey(kind: "tab")
  of '\x7f', '\b': TerminalKey(kind: "backspace")
  of '\x04': TerminalKey(kind: "ctrl-d")
  of '\x15': TerminalKey(kind: "ctrl-u")
  of '\x17': TerminalKey(kind: "ctrl-w")
  of '\x12': TerminalKey(kind: "ctrl-r")
  of ' ': TerminalKey(kind: "space", ch: ch)
  else:
    if ch >= ' ' and ch != '\x7f': TerminalKey(kind: "char", ch: ch)
    else: TerminalKey(kind: "unknown")
