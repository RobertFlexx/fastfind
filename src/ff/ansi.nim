import std/[os, terminal, strutils, tables]

type
  ColorMode* = enum
    cmAuto
    cmAlways
    cmNever

  Color* = enum
    clNone
    clReset
    clBold
    clDim
    clItalic
    clUnderline
    clBlink
    clReverse
    clHidden
    clStrike
    clBlack
    clRed
    clGreen
    clYellow
    clBlue
    clMagenta
    clCyan
    clWhite
    clGray
    clBrightRed
    clBrightGreen
    clBrightYellow
    clBrightBlue
    clBrightMagenta
    clBrightCyan
    clBrightWhite

const
  Reset* = "\x1b[0m"
  Bold* = "\x1b[1m"
  Dim* = "\x1b[2m"
  Italic* = "\x1b[3m"
  Under* = "\x1b[4m"
  Underline* = "\x1b[4m"
  Blink* = "\x1b[5m"
  Reverse* = "\x1b[7m"
  Hidden* = "\x1b[8m"
  Strike* = "\x1b[9m"

  Black* = "\x1b[30m"
  Red* = "\x1b[31m"
  Green* = "\x1b[32m"
  Yellow* = "\x1b[33m"
  Blue* = "\x1b[34m"
  Magenta* = "\x1b[35m"
  Cyan* = "\x1b[36m"
  White* = "\x1b[37m"
  Gray* = "\x1b[90m"
  Grey* = "\x1b[90m"

  BrightRed* = "\x1b[91m"
  BrightGreen* = "\x1b[92m"
  BrightYellow* = "\x1b[93m"
  BrightBlue* = "\x1b[94m"
  BrightMagenta* = "\x1b[95m"
  BrightCyan* = "\x1b[96m"
  BrightWhite* = "\x1b[97m"

  BgBlack* = "\x1b[40m"
  BgRed* = "\x1b[41m"
  BgGreen* = "\x1b[42m"
  BgYellow* = "\x1b[43m"
  BgBlue* = "\x1b[44m"
  BgMagenta* = "\x1b[45m"
  BgCyan* = "\x1b[46m"
  BgWhite* = "\x1b[47m"

const ColorCodes = {
  clNone: "",
  clReset: Reset,
  clBold: Bold,
  clDim: Dim,
  clItalic: Italic,
  clUnderline: Underline,
  clBlink: Blink,
  clReverse: Reverse,
  clHidden: Hidden,
  clStrike: Strike,
  clBlack: Black,
  clRed: Red,
  clGreen: Green,
  clYellow: Yellow,
  clBlue: Blue,
  clMagenta: Magenta,
  clCyan: Cyan,
  clWhite: White,
  clGray: Gray,
  clBrightRed: BrightRed,
  clBrightGreen: BrightGreen,
  clBrightYellow: BrightYellow,
  clBrightBlue: BrightBlue,
  clBrightMagenta: BrightMagenta,
  clBrightCyan: BrightCyan,
  clBrightWhite: BrightWhite
}.toTable

var globalColorEnabled = true

proc setColorEnabled*(enabled: bool) =
  globalColorEnabled = enabled

proc isColorEnabled*(): bool =
  globalColorEnabled

proc supportsColor*(mode: ColorMode = cmAuto): bool =
  case mode
  of cmAlways:
    return true
  of cmNever:
    return false
  of cmAuto:
    if existsEnv("NO_COLOR"):
      return false
    if existsEnv("FORCE_COLOR"):
      return true
    let term = getEnv("TERM", "")
    if term == "dumb":
      return false
    if existsEnv("COLORTERM"):
      return true
    if term.len > 0 and ("color" in term or "256" in term or "xterm" in term or "screen" in term or "vt100" in term):
      return true
    try:
      return isatty(stdout)
    except CatchableError:
      return false

proc initColor*(mode: ColorMode = cmAuto) =
  globalColorEnabled = supportsColor(mode)

proc getCode*(color: Color): string {.inline.} =
  ColorCodes.getOrDefault(color, "")

proc colorize*(s: string; color: Color): string {.inline.} =
  if not globalColorEnabled or color == clNone:
    return s
  let code = getCode(color)
  if code.len == 0:
    return s
  code & s & Reset

proc colorize*(s: string; codes: varargs[string]): string =
  if not globalColorEnabled or codes.len == 0:
    return s
  result = ""
  for code in codes:
    result.add(code)
  result.add(s)
  result.add(Reset)

proc c*(s: string; color: string; enabled: bool = true): string {.inline.} =
  if not enabled or not globalColorEnabled or color.len == 0:
    return s
  color & s & Reset

proc c*(s: string; color: Color; enabled: bool = true): string {.inline.} =
  if not enabled or not globalColorEnabled:
    return s
  colorize(s, color)

proc bold*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Bold, enabled)

proc b*(s: string; enabled: bool = true): string {.inline.} =
  bold(s, enabled)

proc dim*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Dim, enabled)

proc italic*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Italic, enabled)

proc underline*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Underline, enabled)

proc strike*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Strike, enabled)

proc red*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Red, enabled)

proc green*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Green, enabled)

proc yellow*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Yellow, enabled)

proc blue*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Blue, enabled)

proc magenta*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Magenta, enabled)

proc cyan*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Cyan, enabled)

proc gray*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Gray, enabled)

proc grey*(s: string; enabled: bool = true): string {.inline.} =
  c(s, Gray, enabled)

proc white*(s: string; enabled: bool = true): string {.inline.} =
  c(s, White, enabled)

proc brightRed*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightRed, enabled)

proc brightGreen*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightGreen, enabled)

proc brightYellow*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightYellow, enabled)

proc brightBlue*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightBlue, enabled)

proc brightMagenta*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightMagenta, enabled)

proc brightCyan*(s: string; enabled: bool = true): string {.inline.} =
  c(s, BrightCyan, enabled)

proc rgb*(s: string; r, g, b: int; enabled: bool = true): string =
  if not enabled or not globalColorEnabled:
    return s
  let code = "\x1b[38;2;" & $r & ";" & $g & ";" & $b & "m"
  code & s & Reset

proc bgRgb*(s: string; r, g, b: int; enabled: bool = true): string =
  if not enabled or not globalColorEnabled:
    return s
  let code = "\x1b[48;2;" & $r & ";" & $g & ";" & $b & "m"
  code & s & Reset

proc color256*(s: string; code: int; enabled: bool = true): string =
  if not enabled or not globalColorEnabled or code < 0 or code > 255:
    return s
  let ansi = "\x1b[38;5;" & $code & "m"
  ansi & s & Reset

proc bgColor256*(s: string; code: int; enabled: bool = true): string =
  if not enabled or not globalColorEnabled or code < 0 or code > 255:
    return s
  let ansi = "\x1b[48;5;" & $code & "m"
  ansi & s & Reset

proc padLeft*(s: string; width: int; padChar: char = ' '): string =
  if s.len >= width:
    return s
  result = repeat(padChar, width - s.len) & s

proc padRight*(s: string; width: int; padChar: char = ' '): string =
  if s.len >= width:
    return s
  result = s & repeat(padChar, width - s.len)

proc padCenter*(s: string; width: int; padChar: char = ' '): string =
  if s.len >= width:
    return s
  let total = width - s.len
  let left = total div 2
  let right = total - left
  result = repeat(padChar, left) & s & repeat(padChar, right)

proc truncate*(s: string; width: int; suffix: string = "..."): string =
  if s.len <= width:
    return s
  if width <= suffix.len:
    return suffix[0..<width]
  result = s[0..<(width - suffix.len)] & suffix

proc stripAnsi*(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
        inc i
      if i < s.len:
        inc i
    else:
      result.add(s[i])
      inc i

proc visibleLen*(s: string): int =
  stripAnsi(s).len

proc success*(s: string): string {.inline.} =
  green(s)

proc error*(s: string): string {.inline.} =
  red(s)

proc warning*(s: string): string {.inline.} =
  yellow(s)

proc info*(s: string): string {.inline.} =
  blue(s)

proc highlight*(s: string): string {.inline.} =
  cyan(s)

proc muted*(s: string): string {.inline.} =
  dim(s)
