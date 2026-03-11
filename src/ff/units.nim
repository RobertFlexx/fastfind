# src/ff/units.nim
import std/[strutils, times, options, tables, math]

type
  ParseError* = object of CatchableError

proc parseBytes*(s: string): int64 =
  ## parses sizes like: 123, 10K, 5MiB, 2G, 1.5GB
  var t = s.strip()
  if t.len == 0: raise newException(ParseError, "empty size")
  t = t.replace("_", "")

  var numPart = ""
  var unitPart = ""
  for ch in t:
    if ch.isDigit or ch == '.':
      if unitPart.len > 0: raise newException(ParseError, "invalid size: mixed number/unit")
      numPart.add(ch)
    else:
      unitPart.add(ch)

  if numPart.len == 0: raise newException(ParseError, "invalid size: missing number")
  let num = parseFloat(numPart)

  let u = unitPart.strip().toLowerAscii()
  var mul: float = 1.0
  case u
  of "", "b": mul = 1.0
  of "k", "kb": mul = 1_000.0
  of "m", "mb": mul = 1_000_000.0
  of "g", "gb": mul = 1_000_000_000.0
  of "t", "tb": mul = 1_000_000_000_000.0
  of "kib": mul = 1024.0
  of "mib": mul = 1024.0*1024.0
  of "gib": mul = 1024.0*1024.0*1024.0
  of "tib": mul = 1024.0*1024.0*1024.0*1024.0
  else:
    raise newException(ParseError, "unknown size unit: " & unitPart)

  result = int64(round(num * mul))

proc parseDuration*(s: string): Duration =
  ## parses durations like: 10s, 5m, 2h, 3d, 1w
  let t = s.strip().toLowerAscii()
  if t.len < 2: raise newException(ParseError, "invalid duration: " & s)
  var numPart = t
  var unit = ""
  # allow suffix units at end
  if t[^1].isAlphaAscii:
    unit = $t[^1]
    numPart = t[0..^2]
  else:
    raise newException(ParseError, "duration must end with unit: s/m/h/d/w")
  let n = parseFloat(numPart)
  case unit
  of "s": result = initDuration(seconds = int(n))
  of "m": result = initDuration(minutes = int(n))
  of "h": result = initDuration(hours = int(n))
  of "d": result = initDuration(days = int(n))
  of "w": result = initDuration(days = int(n*7))
  else:
    raise newException(ParseError, "unknown duration unit: " & unit)

proc parseTime*(s: string): Time =
  ## parses times like:
  ##  2025-12-01
  ##  2025-12-01T13:05:00
  ##  2025-12-01 13:05:00
  ## returns a utc time
  let t = s.strip()
  if t.len == 10:
    let dt = parse(t, "yyyy-MM-dd", utc())
    return dt.toTime
  if 'T' in t:
    let dt = parse(t, "yyyy-MM-dd'T'HH:mm:ss", utc())
    return dt.toTime
  if ' ' in t:
    let dt = parse(t, "yyyy-MM-dd HH:mm:ss", utc())
    return dt.toTime
  raise newException(ParseError, "invalid time format: " & s)

proc maybeTime*(s: string): Option[Time] =
  if s.strip().len == 0: return none(Time)
  some(parseTime(s))

proc parseSizeExpr*(s: string): tuple[minSize, maxSize: int64] =
  ## parses:
  ##  >10M, >=10M, <1G, <=1G
  ##  10M..200M
  ##  =10M
  ##  10M   (treated as =)
  let t = s.strip()
  if t.len == 0: raise newException(ParseError, "empty --size expression")
  if ".." in t:
    let parts = t.split("..")
    if parts.len != 2: raise newException(ParseError, "invalid size range: " & s)
    let a = parts[0].strip()
    let b = parts[1].strip()
    result.minSize = if a.len == 0: -1 else: parseBytes(a)
    result.maxSize = if b.len == 0: -1 else: parseBytes(b)
    return
  if t.startsWith(">="):
    result.minSize = parseBytes(t[2..^1]); result.maxSize = -1; return
  if t.startsWith(">"):
    result.minSize = parseBytes(t[1..^1]) + 1; result.maxSize = -1; return
  if t.startsWith("<="):
    result.minSize = -1; result.maxSize = parseBytes(t[2..^1]); return
  if t.startsWith("<"):
    result.minSize = -1; result.maxSize = max(int64(0), parseBytes(t[1..^1]) - 1); return
  if t.startsWith("="):
    let x = parseBytes(t[1..^1]); result.minSize = x; result.maxSize = x; return
  let x = parseBytes(t); result.minSize = x; result.maxSize = x

proc splitCmdline*(s: string): seq[string] =
  ## very small shell splitter:
  ## - supports single and double quotes
  ## - backslash escapes inside double quotes and outside
  var cur = ""
  var inS = false
  var inD = false
  var i = 0
  while i < s.len:
    let ch = s[i]
    if inS:
      if ch == '\'': inS = false
      else: cur.add(ch)
    elif inD:
      if ch == '"': inD = false
      elif ch == '\\' and i+1 < s.len:
        inc i; cur.add(s[i])
      else:
        cur.add(ch)
    else:
      case ch
      of ' ', '\t', '\n', '\r':
        if cur.len > 0:
          result.add(cur); cur.setLen(0)
      of '\'':
        inS = true
      of '"':
        inD = true
      of '\\':
        if i+1 < s.len:
          inc i; cur.add(s[i])
      else:
        cur.add(ch)
    inc i
  if cur.len > 0: result.add(cur)
  if inS or inD:
    raise newException(ParseError, "unclosed quote in --exec string")

proc loadSimpleToml*(path: string): Table[string, string] =
  ## minimal key=value parser (kinda like toml?)
  ## supports: strings, ints, bools, arrays kept as raw [...] string.
  ## ignores comments (#...) and blank lines.
  var t: Table[string, string]
  let data = readFile(path)
  for rawLine in data.splitLines():
    var line = rawLine.strip()
    if line.len == 0: continue
    if line.startsWith("#"): continue
    let hash = line.find('#')
    if hash >= 0: line = line[0..<hash].strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0..<eq].strip()
    let val = line[eq+1..^1].strip()
    if key.len == 0 or val.len == 0: continue
    t[key] = val
  t
