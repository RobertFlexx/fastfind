import std/[os, terminal, strutils]

type ColorMode* = enum
  cmAuto, cmAlways, cmNever

proc supportsColor*(mode: ColorMode = cmAuto): bool =
  if mode == cmAlways: return true
  if mode == cmNever: return false
  if existsEnv("NO_COLOR"): return false
  try:
    return isatty(stdout)
  except CatchableError:
    return false

const
  Reset* = "\x1b[0m"
  Bold*  = "\x1b[1m"
  Dim*   = "\x1b[2m"
  Under* = "\x1b[4m"

  Red*   = "\x1b[31m"
  Green* = "\x1b[32m"
  Yellow* = "\x1b[33m"
  Blue*  = "\x1b[34m"
  Magenta* = "\x1b[35m"
  Cyan*  = "\x1b[36m"
  Gray*  = "\x1b[90m"

proc b*(s: string; on=true): string =
  if on: Bold & s & Reset else: s

proc dim*(s: string; on=true): string =
  if on: Dim & s & Reset else: s

proc c*(s: string; color: string; on=true): string =
  if on: color & s & Reset else: s

proc padRight*(s: string; n: int): string =
  if s.len >= n: return s
  result = s & repeat(' ', n - s.len)
