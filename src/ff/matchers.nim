# src/ff/matchers.nim
import std/[strutils, re]
import fuzzy_match


type
  MatchMode* = enum mmGlob, mmRegex, mmFixed, mmFuzzy
  PathMode*  = enum pmBaseName, pmFullPath

proc escapeRe(s: string): string =
  for ch in s:
    case ch
    of '\\', '.', '+', '*', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|':
      result.add('\\'); result.add(ch)
    else:
      result.add(ch)

proc globToRegex*(glob: string): string =
  var i = 0
  result.add("^")
  while i < glob.len:
    let c = glob[i]
    case c
    of '*': result.add(".*")
    of '?': result.add(".")
    of '[':
      var j = i
      while j < glob.len and glob[j] != ']': inc j
      if j < glob.len:
        result.add(glob[i..j])
        i = j
      else:
        result.add("\\[")
    else:
      result.add(escapeRe($c))
    inc i
  result.add("$")

type
  Matcher* = object
    mode*: MatchMode
    pathMode*: PathMode
    ignoreCase*: bool
    smartCase*: bool
    fullMatch*: bool
    patterns*: seq[string]
    compiled*: seq[Regex]
    fixed*: seq[string]

proc needsIgnoreCase(m: Matcher): bool =
  if m.ignoreCase: return true
  if not m.smartCase: return false
  for p in m.patterns:
    for ch in p:
      if ch.isUpperAscii: return false
  true

proc compile*(m: var Matcher) =
  let ic = needsIgnoreCase(m)
  m.compiled.setLen(0)
  m.fixed.setLen(0)

  case m.mode
  of mmFixed:
    for p in m.patterns:
      m.fixed.add(if ic: p.toLowerAscii() else: p)
  of mmGlob:
    for p in m.patterns:
      let rxStr = globToRegex(p)
      m.compiled.add(re(rxStr, if ic: {reIgnoreCase} else: {}))
  of mmRegex:
    for p in m.patterns:
      var rxStr = p
      if m.fullMatch:
        if not rxStr.startsWith("^"): rxStr = "^" & rxStr
        if not rxStr.endsWith("$"): rxStr = rxStr & "$"
      m.compiled.add(re(rxStr, if ic: {reIgnoreCase} else: {}))
  of mmFuzzy:
    for p in m.patterns:
      m.fixed.add(if ic: p.toLowerAscii() else: p)

proc anyMatch*(m: Matcher; baseName, fullRelPath: string): bool =
  if m.patterns.len == 0: return true
  let target =
    if m.pathMode == pmFullPath: fullRelPath
    else: baseName

  let ic = needsIgnoreCase(m)
  case m.mode
  of mmFixed:
    let t = if ic: target.toLowerAscii() else: target
    for pat in m.fixed:
      if m.fullMatch:
        if t == pat: return true
      else:
        if t.contains(pat): return true
    return false
  of mmGlob:
    for rx in m.compiled:
      if target.match(rx): return true
    return false
  of mmRegex:
    for rx in m.compiled:
      if m.fullMatch:
        if target.match(rx): return true
      else:
        if target.contains(rx): return true
    return false
  of mmFuzzy:
    for pat in m.fixed:
      let score = fuzzyMatch(pat, if ic: target.toLowerAscii() else: target)
      if score >= 0: return true
    return false

proc fuzzyScore*(m: Matcher; baseName, fullRelPath: string): int =
  ## returns best fuzzy score (lower is better), or high value if no match
  if m.mode != mmFuzzy: return 999999
  
  let target =
    if m.pathMode == pmFullPath: fullRelPath
    else: baseName
  
  let ic = needsIgnoreCase(m)
  let t = if ic: target.toLowerAscii() else: target
  
  var best = 999999
  for pat in m.fixed:
    let score = fuzzyMatch(pat, t)
    if score >= 0 and score < best:
      best = score
  result = best

type
  Excluder* = object
    ignoreCase*: bool
    patterns*: seq[string]
    compiled*: seq[Regex]

proc compile*(e: var Excluder) =
  e.compiled.setLen(0)
  for p in e.patterns:
    let rxStr = globToRegex(p)
    e.compiled.add(re(rxStr, if e.ignoreCase: {reIgnoreCase} else: {}))

proc isExcluded*(e: Excluder; relPath: string): bool =
  for rx in e.compiled:
    if relPath.match(rx): return true
  false

type
  Gitignore* = object
    ignoreCase*: bool
    exclude*: seq[Regex]
    allow*: seq[Regex]

proc compileGitignore*(gi: var Gitignore; lines: seq[string]) =
  gi.exclude.setLen(0)
  gi.allow.setLen(0)
  for raw in lines:
    var s = raw.strip()
    if s.len == 0: continue
    if s.startsWith("#"): continue
    let h = s.find('#')
    if h > 0: s = s[0..<h].strip()
    if s.len == 0: continue

    var neg = false
    if s.startsWith("!"):
      neg = true
      s = s[1..^1].strip()
      if s.len == 0: continue

    if s.endsWith("/"):
      s &= "**"

    if s.startsWith("/"):
      s = s[1..^1]

    if not s.contains("/") and not s.startsWith("**/"):
      s = "**/" & s

    let rxStr = globToRegex(s)
    let flags = if gi.ignoreCase: {reIgnoreCase} else: {}
    let rx = re(rxStr, flags)
    if neg: gi.allow.add(rx) else: gi.exclude.add(rx)

proc isGitIgnored*(gi: Gitignore; relPath: string): bool =
  var excluded = false
  for rx in gi.exclude:
    if relPath.match(rx):
      excluded = true
      break
  if not excluded: return false
  for rx in gi.allow:
    if relPath.match(rx):
      return false
  true
