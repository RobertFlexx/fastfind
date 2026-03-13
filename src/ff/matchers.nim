# src/ff/matchers.nim
import std/[strutils, re]
import fuzzy_match

type
  MatchMode* = enum mmGlob, mmRegex, mmFixed, mmFuzzy
  PathMode*  = enum pmBaseName, pmFullPath
  
  GlobKind = enum
    gkComplex, gkPrefix, gkSuffix, gkContains, gkExact

  OptGlob = object
    kind: GlobKind
    pattern: string
    regex: Regex

  Matcher* = object
    mode*: MatchMode
    pathMode*: PathMode
    ignoreCase*: bool
    smartCase*: bool
    fullMatch*: bool
    patterns*: seq[string]
    compiled*: seq[Regex]
    fixed*: seq[string]
    effectiveIC*: bool
    optGlobs*: seq[OptGlob]

  Excluder* = object
    ignoreCase*: bool
    patterns*: seq[string]
    compiled*: seq[Regex]

  Gitignore* = object
    ignoreCase*: bool
    exclude*: seq[Regex]
    allow*: seq[Regex]

proc escapeRe(s: string): string =
  result = newStringOfCap(s.len + 8)
  for ch in s:
    case ch
    of '\\', '.', '+', '*', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|':
      result.add('\\'); result.add(ch)
    else:
      result.add(ch)

proc globToRegex*(glob: string): string =
  result = newStringOfCap(glob.len * 2 + 4)
  result.add('^')
  var i = 0
  while i < glob.len:
    let c = glob[i]
    case c
    of '*': result.add(".*")
    of '?': result.add('.')
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
  result.add('$')

proc analyzeGlob(glob: string; ic: bool): OptGlob =
  if glob.len == 0:
    return OptGlob(kind: gkExact, pattern: "")
  
  let hasLead = glob[0] == '*'
  let hasTrail = glob[^1] == '*'
  var hasMid = false
  for i in 1..<glob.len-1:
    if glob[i] in {'*', '?', '[', ']'}:
      hasMid = true
      break
  
  if hasMid:
    let rx = globToRegex(glob)
    return OptGlob(kind: gkComplex, regex: re(rx, if ic: {reIgnoreCase} else: {}))
  
  var core: string
  var kind: GlobKind
  
  if hasLead and hasTrail and glob.len > 2:
    kind = gkContains
    core = glob[1..^2]
  elif hasLead and glob.len > 1:
    kind = gkSuffix
    core = glob[1..^1]
  elif hasTrail and glob.len > 1:
    kind = gkPrefix
    core = glob[0..^2]
  elif not hasLead and not hasTrail:
    kind = gkExact
    core = glob
  else:
    let rx = globToRegex(glob)
    return OptGlob(kind: gkComplex, regex: re(rx, if ic: {reIgnoreCase} else: {}))
  
  OptGlob(kind: kind, pattern: if ic: core.toLowerAscii() else: core)

proc computeEffectiveIC(m: Matcher): bool {.inline.} =
  if m.ignoreCase: return true
  if not m.smartCase: return false
  for p in m.patterns:
    for ch in p:
      if ch in {'A'..'Z'}: return false
  true

proc compile*(m: var Matcher) =
  m.effectiveIC = computeEffectiveIC(m)
  let ic = m.effectiveIC
  m.compiled.setLen(0)
  m.fixed.setLen(0)
  m.optGlobs.setLen(0)

  case m.mode
  of mmFixed:
    for p in m.patterns:
      m.fixed.add(if ic: p.toLowerAscii() else: p)
  of mmGlob:
    for p in m.patterns:
      m.optGlobs.add(analyzeGlob(p, ic))
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

proc toLowerInPlace(s: var string) {.inline.} =
  for i in 0..<s.len:
    let c = s[i]
    if c in {'A'..'Z'}:
      s[i] = chr(ord(c) + 32)

proc anyMatch*(m: Matcher; baseName, fullRelPath: string): bool =
  if m.patterns.len == 0: return true
  
  let target = if m.pathMode == pmFullPath: fullRelPath else: baseName

  case m.mode
  of mmFixed:
    var t = target
    if m.effectiveIC: toLowerInPlace(t)
    for pat in m.fixed:
      if m.fullMatch:
        if t == pat: return true
      else:
        if pat in t: return true
    false
  of mmGlob:
    var t = target
    if m.effectiveIC: toLowerInPlace(t)
    for og in m.optGlobs:
      case og.kind
      of gkExact:
        if t == og.pattern: return true
      of gkPrefix:
        if t.startsWith(og.pattern): return true
      of gkSuffix:
        if t.endsWith(og.pattern): return true
      of gkContains:
        if og.pattern in t: return true
      of gkComplex:
        if target.match(og.regex): return true
    false
  of mmRegex:
    for rx in m.compiled:
      if m.fullMatch:
        if target.match(rx): return true
      else:
        if target.contains(rx): return true
    false
  of mmFuzzy:
    var t = target
    if m.effectiveIC: toLowerInPlace(t)
    for pat in m.fixed:
      if fuzzyMatch(pat, t) >= 0: return true
    false

proc fuzzyScore*(m: Matcher; baseName, fullRelPath: string): int =
  if m.mode != mmFuzzy: return 999999
  let target = if m.pathMode == pmFullPath: fullRelPath else: baseName
  var t = target
  if m.effectiveIC: toLowerInPlace(t)
  result = 999999
  for pat in m.fixed:
    let s = fuzzyMatch(pat, t)
    if s >= 0 and s < result: result = s

proc compile*(e: var Excluder) =
  e.compiled.setLen(0)
  for p in e.patterns:
    let rxStr = globToRegex(p)
    e.compiled.add(re(rxStr, if e.ignoreCase: {reIgnoreCase} else: {}))

proc isExcluded*(e: Excluder; relPath: string): bool {.inline.} =
  for rx in e.compiled:
    if relPath.match(rx): return true
  false

proc compileGitignore*(gi: var Gitignore; lines: seq[string]) =
  gi.exclude.setLen(0)
  gi.allow.setLen(0)
  for raw in lines:
    var s = raw.strip()
    if s.len == 0 or s[0] == '#': continue
    let h = s.find('#')
    if h > 0: s = s[0..<h].strip()
    if s.len == 0: continue

    var neg = false
    if s[0] == '!':
      neg = true
      s = s[1..^1].strip()
      if s.len == 0: continue

    if s[^1] == '/': s &= "**"
    if s[0] == '/': s = s[1..^1]
    if not s.contains('/') and not s.startsWith("**/"): s = "**/" & s

    let rxStr = globToRegex(s)
    let flags = if gi.ignoreCase: {reIgnoreCase} else: {}
    let rx = re(rxStr, flags)
    if neg: gi.allow.add(rx) else: gi.exclude.add(rx)

proc isGitIgnored*(gi: Gitignore; relPath: string): bool {.inline.} =
  var excluded = false
  for rx in gi.exclude:
    if relPath.match(rx):
      excluded = true
      break
  if not excluded: return false
  for rx in gi.allow:
    if relPath.match(rx): return false
  true
