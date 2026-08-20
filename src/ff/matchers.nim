# src/ff/matchers.nim
import std/[os, strutils, re]
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
    matchAll*: bool

  Excluder* = object
    ignoreCase*: bool
    patterns*: seq[string]
    compiled*: seq[Regex]

  GitignoreRule = object
    regex: Regex
    negated: bool

  Gitignore* = object
    ignoreCase*: bool
    root*: string
    rules: seq[GitignoreRule]

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

proc gitGlobBody(glob: string): string =
  ## Turn gitignore wildcards into regex. A single star stops at `/`, while
  ## `**/` can cover any number of directories (including none).
  result = newStringOfCap(glob.len * 2 + 8)
  var i = 0
  while i < glob.len:
    case glob[i]
    of '*':
      if i + 1 < glob.len and glob[i + 1] == '*':
        inc i
        if i + 1 < glob.len and glob[i + 1] == '/':
          inc i
          result.add("(?:.*/)?")
        else:
          result.add(".*")
      else:
        result.add("[^/]*")
    of '?':
      result.add("[^/]")
    of '[':
      var j = i + 1
      if j < glob.len and glob[j] in {'!', '^'}: inc j
      if j < glob.len and glob[j] == ']': inc j
      while j < glob.len and glob[j] != ']': inc j
      if j < glob.len:
        result.add('[')
        var start = i + 1
        if start < j and glob[start] == '!':
          result.add('^')
          inc start
        result.add(glob[start..<j])
        result.add(']')
        i = j
      else:
        result.add("\\[")
    of '\\':
      if i + 1 < glob.len:
        inc i
        result.add(escapeRe($glob[i]))
      else:
        result.add("\\\\")
    else:
      result.add(escapeRe($glob[i]))
    inc i

proc gitPatternToRegex(pattern: string; directoryOnly: bool): string =
  var p = pattern
  let anchored = p.startsWith("/")
  if anchored: p = p[1..^1]
  let hasSlash = '/' in p
  result = if anchored or hasSlash: "^" else: "(?:^|.*/)"
  result.add(gitGlobBody(p))
  if directoryOnly:
    result.add("(?:/.*)?")
  result.add('$')

proc hasAnyWildcard(s: string): bool {.inline.} =
  for c in s:
    case c
    of '*', '?', '[': return true
    else: continue
  false

proc extractGlobExtension*(glob: string): string =
  if glob.len == 0: return ""
  if glob[0] == '*' and glob.len > 1:
    if glob[1] == '.':
      var extEnd = 2
      while extEnd < glob.len and glob[extEnd] notin {'*', '?', '['}:
        inc extEnd
      if extEnd > 2:
        return glob[1..<extEnd]
    elif glob[1] notin {'*', '?', '['}:
      var extEnd = 1
      while extEnd < glob.len and glob[extEnd] notin {'*', '?', '['}:
        inc extEnd
      return glob[0..<extEnd]
  ""

proc analyzeGlob(glob: string; ic: bool): OptGlob =
  if glob.len == 0:
    return OptGlob(kind: gkExact, pattern: "")
  
  if not hasAnyWildcard(glob):
    return OptGlob(kind: gkExact, pattern: if ic: glob.toLowerAscii() else: glob)
  
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

proc eqIgnoreAscii(a, b: string): bool {.inline.} =
  if a.len != b.len: return false
  for i in 0..<a.len:
    var ac = a[i]
    if ac in {'A'..'Z'}: ac = chr(ord(ac) + 32)
    if ac != b[i]: return false
  true

proc startsWithIgnoreAscii(s, prefixLower: string): bool {.inline.} =
  if prefixLower.len > s.len: return false
  for i in 0..<prefixLower.len:
    var c = s[i]
    if c in {'A'..'Z'}: c = chr(ord(c) + 32)
    if c != prefixLower[i]: return false
  true

proc endsWithIgnoreAscii(s, suffixLower: string): bool {.inline.} =
  if suffixLower.len > s.len: return false
  let start = s.len - suffixLower.len
  for i in 0..<suffixLower.len:
    var c = s[start + i]
    if c in {'A'..'Z'}: c = chr(ord(c) + 32)
    if c != suffixLower[i]: return false
  true

proc containsIgnoreAscii(s, needleLower: string): bool {.inline.} =
  if needleLower.len == 0: return true
  if needleLower.len > s.len: return false
  let last = s.len - needleLower.len
  for i in 0..last:
    var ok = true
    for j in 0..<needleLower.len:
      var c = s[i + j]
      if c in {'A'..'Z'}: c = chr(ord(c) + 32)
      if c != needleLower[j]:
        ok = false
        break
    if ok: return true
  false

proc baseStartIdx(path: string): int {.inline.} =
  var i = path.len - 1
  while i >= 0:
    if path[i] == '/' or path[i] == '\\':
      return i + 1
    dec i
  0

proc eqSlice(path: string; start: int; pat: string): bool {.inline.} =
  let plen = path.len - start
  if plen != pat.len: return false
  for i in 0..<pat.len:
    if path[start + i] != pat[i]: return false
  true

proc startsWithSlice(path: string; start: int; pat: string): bool {.inline.} =
  let plen = path.len - start
  if pat.len > plen: return false
  for i in 0..<pat.len:
    if path[start + i] != pat[i]: return false
  true

proc endsWithSlice(path: string; start: int; pat: string): bool {.inline.} =
  let plen = path.len - start
  if pat.len > plen: return false
  let off = path.len - pat.len
  for i in 0..<pat.len:
    if path[off + i] != pat[i]: return false
  true

proc containsSlice(path: string; start: int; pat: string): bool {.inline.} =
  let plen = path.len - start
  if pat.len == 0: return true
  if pat.len > plen: return false
  let last = path.len - pat.len
  var i = start
  while i <= last:
    var ok = true
    for j in 0..<pat.len:
      if path[i + j] != pat[j]:
        ok = false
        break
    if ok: return true
    inc i
  false

proc eqIgnoreAsciiSlice(path: string; start: int; patLower: string): bool {.inline.} =
  let plen = path.len - start
  if plen != patLower.len: return false
  for i in 0..<patLower.len:
    var c = path[start + i]
    if c in {'A'..'Z'}: c = chr(ord(c) + 32)
    if c != patLower[i]: return false
  true

proc startsWithIgnoreAsciiSlice(path: string; start: int; patLower: string): bool {.inline.} =
  let plen = path.len - start
  if patLower.len > plen: return false
  for i in 0..<patLower.len:
    var c = path[start + i]
    if c in {'A'..'Z'}: c = chr(ord(c) + 32)
    if c != patLower[i]: return false
  true

proc endsWithIgnoreAsciiSlice(path: string; start: int; patLower: string): bool {.inline.} =
  let plen = path.len - start
  if patLower.len > plen: return false
  let off = path.len - patLower.len
  for i in 0..<patLower.len:
    var c = path[off + i]
    if c in {'A'..'Z'}: c = chr(ord(c) + 32)
    if c != patLower[i]: return false
  true

proc containsIgnoreAsciiSlice(path: string; start: int; patLower: string): bool {.inline.} =
  let plen = path.len - start
  if patLower.len == 0: return true
  if patLower.len > plen: return false
  let last = path.len - patLower.len
  var i = start
  while i <= last:
    var ok = true
    for j in 0..<patLower.len:
      var c = path[i + j]
      if c in {'A'..'Z'}: c = chr(ord(c) + 32)
      if c != patLower[j]:
        ok = false
        break
    if ok: return true
    inc i
  false

proc compile*(m: var Matcher) =
  m.effectiveIC = computeEffectiveIC(m)
  let ic = m.effectiveIC
  m.compiled.setLen(0)
  m.fixed.setLen(0)
  m.optGlobs.setLen(0)
  m.matchAll = false

  if m.mode == mmGlob and m.patterns.len == 1 and m.patterns[0] == "*":
    m.matchAll = true
    return

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

proc matchWithCase(m: Matcher; og: OptGlob; t, target: string): bool =
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
    let searchTarget = if m.effectiveIC: t else: target
    if searchTarget.match(og.regex): return true
  false

proc anyMatch*(m: Matcher; baseName, fullRelPath: string): bool =
  if m.matchAll: return true
  if m.patterns.len == 0: return true
  
  let target = if m.pathMode == pmFullPath: fullRelPath else: baseName
  let useBaseSlice = m.pathMode == pmBaseName and baseName.len == 0
  let baseStart = if useBaseSlice: baseStartIdx(fullRelPath) else: 0

  case m.mode
  of mmFixed:
    if useBaseSlice:
      for pat in m.fixed:
        if m.fullMatch:
          if (if m.effectiveIC: eqIgnoreAsciiSlice(fullRelPath, baseStart, pat) else: eqSlice(fullRelPath, baseStart, pat)): return true
        else:
          if (if m.effectiveIC: containsIgnoreAsciiSlice(fullRelPath, baseStart, pat) else: containsSlice(fullRelPath, baseStart, pat)): return true
    else:
      for pat in m.fixed:
        if m.fullMatch:
          if (if m.effectiveIC: eqIgnoreAscii(target, pat) else: target == pat): return true
        else:
          if (if m.effectiveIC: containsIgnoreAscii(target, pat) else: pat in target): return true
    false
  of mmGlob:
    if useBaseSlice:
      for og in m.optGlobs:
        if m.effectiveIC:
          case og.kind
          of gkExact:
            if eqIgnoreAsciiSlice(fullRelPath, baseStart, og.pattern): return true
          of gkPrefix:
            if startsWithIgnoreAsciiSlice(fullRelPath, baseStart, og.pattern): return true
          of gkSuffix:
            if endsWithIgnoreAsciiSlice(fullRelPath, baseStart, og.pattern): return true
          of gkContains:
            if containsIgnoreAsciiSlice(fullRelPath, baseStart, og.pattern): return true
          of gkComplex:
            let bn = fullRelPath[baseStart..^1]
            if bn.match(og.regex): return true
        else:
          case og.kind
          of gkExact:
            if eqSlice(fullRelPath, baseStart, og.pattern): return true
          of gkPrefix:
            if startsWithSlice(fullRelPath, baseStart, og.pattern): return true
          of gkSuffix:
            if endsWithSlice(fullRelPath, baseStart, og.pattern): return true
          of gkContains:
            if containsSlice(fullRelPath, baseStart, og.pattern): return true
          of gkComplex:
            let bn = fullRelPath[baseStart..^1]
            if bn.match(og.regex): return true
    else:
      for og in m.optGlobs:
        if m.effectiveIC:
          case og.kind
          of gkExact:
            if eqIgnoreAscii(target, og.pattern): return true
          of gkPrefix:
            if startsWithIgnoreAscii(target, og.pattern): return true
          of gkSuffix:
            if endsWithIgnoreAscii(target, og.pattern): return true
          of gkContains:
            if containsIgnoreAscii(target, og.pattern): return true
          of gkComplex:
            if target.match(og.regex): return true
        else:
          if matchWithCase(m, og, target, target): return true
    false
  of mmRegex:
    for rx in m.compiled:
      if m.fullMatch:
        if target.match(rx): return true
      else:
        if target.contains(rx): return true
    false
  of mmFuzzy:
    let t = if m.effectiveIC: target.toLowerAscii() else: target
    for pat in m.fixed:
      if fuzzyMatch(pat, t) >= 0: return true
    false

proc fuzzyScore*(m: Matcher; baseName, fullRelPath: string): int =
  if m.mode != mmFuzzy: return 999999
  let target = if m.pathMode == pmFullPath: fullRelPath else: baseName
  let t = if m.effectiveIC: target.toLowerAscii() else: target
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

proc appendGitignore(gi: var Gitignore; lines: seq[string]; scope: string) =
  for raw in lines:
    var s = raw.strip(leading = false, trailing = true)
    if s.len == 0 or s[0] == '#': continue
    if s.startsWith("\\#"): s = s[1..^1]
    if s.len == 0: continue

    var neg = false
    if s.startsWith("\\!"):
      s = s[1..^1]
    elif s[0] == '!':
      neg = true
      s = s[1..^1]
      if s.len == 0: continue

    let directoryOnly = s.endsWith("/")
    if directoryOnly: s.setLen(s.len - 1)
    if s.len == 0: continue
    if scope.len > 0:
      let anchored = s.startsWith("/")
      if anchored: s = s[1..^1]
      if anchored or '/' in s:
        s = scope & "/" & s
      else:
        s = scope & "/**/" & s
    let rxStr = gitPatternToRegex(s, directoryOnly)
    let flags = if gi.ignoreCase: {reIgnoreCase} else: {}
    gi.rules.add(GitignoreRule(regex: re(rxStr, flags), negated: neg))

proc compileGitignore*(gi: var Gitignore; lines: seq[string]) =
  gi.rules.setLen(0)
  gi.appendGitignore(lines, "")

proc extendGitignore*(gi: var Gitignore; lines: seq[string]; scope: string) =
  gi.appendGitignore(lines, scope.strip(chars = {'/', '\\'}))

proc derivedGitignore*(parent: Gitignore; lines: seq[string]; scope: string): Gitignore =
  ## Copy the rule list before adding local rules so sibling directories don't
  ## accidentally share changes. The compiled regexes themselves are safe to reuse.
  result.ignoreCase = parent.ignoreCase
  result.root = parent.root
  result.rules = newSeqOfCap[GitignoreRule](parent.rules.len + lines.len)
  result.rules.add(parent.rules)
  result.appendGitignore(lines, scope.strip(chars = {'/', '\\'}))

proc isGitIgnored*(gi: Gitignore; relPath: string): bool {.inline.} =
  var target = relPath
  if gi.root.len > 0 and relPath.isAbsolute:
    try: target = relativePath(relPath, gi.root)
    except CatchableError: discard
  proc evaluate(path: string): bool =
    result = false
    for rule in gi.rules:
      if path.match(rule.regex): result = not rule.negated

  # Git can't bring an entry back when one of its parent directories is still
  # ignored. Checking parents here also keeps direct matcher calls consistent.
  var slash = target.find('/')
  while slash >= 0:
    if evaluate(target[0..<slash]): return true
    slash = target.find('/', slash + 1)
  evaluate(target)
