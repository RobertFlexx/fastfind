## Terminal cells, rather than UTF-8 bytes, determine clipping and alignment.
import std/[unicode, strutils]

when defined(posix):
  import std/posix
  proc wcwidth(value: cint): cint {.importc, header: "<wchar.h>".}

proc initTerminalText*() =
  when defined(posix):
    discard setlocale(LC_CTYPE, "")

proc cellWidth(r: Rune): int =
  when defined(posix):
    let cells = int(wcwidth(cint(r)))
    if cells >= 0: return cells
  if int(r) in 0x300..0x36f: 0
  elif int(r) in 0x1100..0x115f or int(r) in 0x2e80..0xa4cf or
       int(r) in 0xac00..0xd7a3 or int(r) in 0x1f300..0x1faff: 2
  else: 1

proc safeText*(value: string): string =
  ## Escape controls, invalid UTF-8, and bidi controls in untrusted paths/text.
  const hex = "0123456789abcdef"
  var i = 0
  while i < value.len:
    let start = i
    let c = value[i]
    if ord(c) < 32 or ord(c) == 127:
      result.add("\\x" & hex[ord(c) shr 4] & hex[ord(c) and 15])
      inc i
      continue
    if ord(c) < 128:
      result.add(c)
      inc i
      continue
    let length = runeLenAt(value, i)
    if length <= 0 or i + length > value.len or
        validateUtf8(value.toOpenArray(i, min(value.high, i + length - 1))) >= 0:
      result.add('?')
      inc i
      continue
    var r: Rune
    fastRuneAt(value, i, r)
    let n = int(r)
    if n in 0x80..0x9f or n in 0x202a..0x202e or n in 0x2066..0x2069:
      result.add('?')
    else:
      result.add(value[start..<i])

proc textWidth*(value: string): int =
  for r in value.runes: result += cellWidth(r)

proc clipText*(value: string; width: int; left = false): string =
  if width <= 0: return ""
  if textWidth(value) <= width: return value
  if width <= 3: return repeat('.', width)
  let budget = width - 3
  if left:
    let runes = value.toRunes
    var start = runes.len
    var used = 0
    while start > 0:
      let cells = cellWidth(runes[start - 1])
      if used + cells > budget: break
      used += cells
      dec start
    result = "..."
    for i in start..<runes.len: result.add($runes[i])
  else:
    var used = 0
    for r in value.runes:
      let cells = cellWidth(r)
      if used + cells > budget: break
      used += cells
      result.add($r)
    result.add("...")

proc fitText*(value: string; width: int; right = false): string =
  result = clipText(value, width)
  let padding = repeat(' ', max(0, width - textWidth(result)))
  if right: result = padding & result
  else: result.add(padding)

proc eraseLastRune*(value: var string) =
  if value.len == 0: return
  var start = value.high
  while start > 0 and (ord(value[start]) and 0xc0) == 0x80: dec start
  value.setLen(start)
