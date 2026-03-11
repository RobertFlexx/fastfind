# src/ff/search.nim
import std/[os, strutils, options, re]
import std/times as times
import core, cli, matchers, content, fuzzy_match

when defined(posix):
  import std/posix


type
  SearchResult* = object
    matches*: seq[MatchResult]
    stats*: Stats

proc relDepth(relPath: string): int =
  if relPath.len == 0: return 0
  result = 0
  for ch in relPath:
    if ch == '/' or ch == '\\': inc result

proc isHiddenPath(relPath: string): bool =
  if relPath.len == 0: return false
  if relPath[0] == '.': return true
  for i in 0 ..< relPath.len-1:
    let c = relPath[i]
    if (c == '/' or c == '\\') and relPath[i+1] == '.':
      return true
  false

proc containsUpper(s: string): bool =
  for ch in s:
    if ch.isUpperAscii: return true
  false

proc effectiveIgnoreCase(cfg: Config): bool =
  if cfg.ignoreCase: return true
  if cfg.smartCase:
    for p in cfg.patterns:
      if containsUpper(p): return false
    return true
  false

proc findGitRepoRoot(startPath: string): string =
  var p = absolutePath(startPath)
  if fileExists(p): p = p.parentDir
  while true:
    if dirExists(p / ".git") or fileExists(p / ".git"):
      return p
    let parent = p.parentDir
    if parent == p: break
    p = parent
  ""

proc loadGitignoreLines(repoRoot: string): seq[string] =
  result = @[]
  if repoRoot.len > 0:
    let gi = repoRoot / ".gitignore"
    if fileExists(gi):
      try: result.add(readFile(gi).splitLines())
      except CatchableError: discard

    let excl = repoRoot / ".git" / "info" / "exclude"
    if fileExists(excl):
      try: result.add(readFile(excl).splitLines())
      except CatchableError: discard

  result.add(".git/")
  result.add(".hg/")
  result.add(".svn/")

proc getDeviceId(path: string): int64 =
  when defined(posix):
    var st: Stat
    if posix.stat(path.cstring, st) == 0:
      return int64(st.st_dev)
  -1

proc passesSize(cfg: Config; size: int64): bool =
  if cfg.minSize >= 0 and size < cfg.minSize: return false
  if cfg.maxSize >= 0 and size > cfg.maxSize: return false
  true

proc passesTime(cfg: Config; mtime: times.Time): bool =
  if cfg.newerThan.isSome and mtime <= cfg.newerThan.get: return false
  if cfg.olderThan.isSome and mtime >= cfg.olderThan.get: return false
  true

proc buildMatcher(cfg: Config): Matcher =
  let ic = effectiveIgnoreCase(cfg)
  var m = Matcher(
    mode: cfg.matchMode,
    pathMode: cfg.pathMode,
    fullMatch: cfg.fullMatch,
    patterns: cfg.patterns,
    ignoreCase: ic
  )
  m.compile()
  result = m

proc buildExcluder(cfg: Config): Excluder =
  var ex = Excluder(ignoreCase: false, patterns: cfg.excludes)
  ex.compile()
  result = ex

proc buildGitignoreLines(cfg: Config; rootAbs: string): tuple[useGi: bool, lines: seq[string]] =
  result.useGi = cfg.useGitignore
  result.lines = @[]
  if result.useGi:
    let repo = findGitRepoRoot(rootAbs)
    result.lines = loadGitignoreLines(repo)

proc compileContentRegex(cfg: Config; ic: bool): Option[Regex] =
  if cfg.containsRegex.len == 0: return none(Regex)
  let flags = if ic: {reIgnoreCase} else: {}
  try:
    return some(re(cfg.containsRegex, flags))
  except CatchableError:
    return none(Regex)

proc shouldTraverseDir(cfg: Config; relPath: string; depth: int;
                      ex: Excluder; gi: Gitignore; useGi: bool;
                      rootDev: int64; fullPath: string): bool =
  if (not cfg.includeHidden) and isHiddenPath(relPath): return false
  if cfg.maxDepth >= 0 and depth >= cfg.maxDepth: return false
  if ex.compiled.len > 0 and ex.isExcluded(relPath): return false
  if useGi and isGitIgnored(gi, relPath): return false
  if cfg.oneFileSystem and rootDev >= 0:
    let dev = getDeviceId(fullPath)
    if dev >= 0 and dev != rootDev: return false
  true

proc shouldSkipMatch(cfg: Config; kind: EntryType; relPath: string; depth: int): bool =
  if (not cfg.includeHidden) and isHiddenPath(relPath): return true
  if cfg.minDepth > 0 and depth < cfg.minDepth: return true
  if cfg.maxDepth >= 0 and depth > cfg.maxDepth: return true
  if kind notin cfg.types: return true
  false

proc scanEntry(rootAbs: string;
               cfg: Config;
               matcher: Matcher;
               ex: Excluder;
               gi: Gitignore; useGi: bool;
               rootDev: int64;
               fullPath: string; relPath: string; kind: EntryType;
               contentRx: Option[Regex];
               stats: var Stats): Option[MatchResult] =
  let depth = relDepth(relPath)

  if shouldSkipMatch(cfg, kind, relPath, depth):
    inc stats.skipped
    return none(MatchResult)

  if ex.compiled.len > 0 and ex.isExcluded(relPath):
    inc stats.skipped
    return none(MatchResult)

  if useGi and isGitIgnored(gi, relPath):
    inc stats.skipped
    return none(MatchResult)

  if (cfg.containsText.len > 0 or cfg.containsRegex.len > 0) and kind != etFile:
    inc stats.skipped
    return none(MatchResult)

  let name = extractFilename(fullPath)
  
  # fuzzy matching
  if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
    let target = if matcher.pathMode == pmFullPath: relPath else: name
    let ic = effectiveIgnoreCase(cfg)
    let t = if ic: target.toLowerAscii() else: target
    
    var bestScore = 999999
    for pat in matcher.fixed:
      let score = fuzzyMatch(pat, t)
      if score >= 0 and score < bestScore:
        bestScore = score
    
    if bestScore >= 999999:
      return none(MatchResult)
  else:
    if not matcher.anyMatch(name, relPath):
      return none(MatchResult)

  var info: FileInfo
  try:
    info = getFileInfo(fullPath, followSymlink = cfg.followSymlinks)
  except CatchableError:
    inc stats.errors
    return none(MatchResult)

  let size = info.size.int64
  let mtime = info.lastWriteTime

  if not passesSize(cfg, size) or not passesTime(cfg, mtime):
    inc stats.skipped
    return none(MatchResult)

  # content search with smart method selection
  if cfg.containsText.len > 0:
    var br: int64 = 0
    let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes, cfg.allowBinary, br)
    stats.bytesRead += br
    if not ok: return none(MatchResult)

  if cfg.containsRegex.len > 0:
    if contentRx.isNone:
      return none(MatchResult)
    var br: int64 = 0
    let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br)
    stats.bytesRead += br
    if not ok: return none(MatchResult)

  var m: MatchResult
  m.path = relPath
  m.relPath = relPath
  m.absPath = fullPath
  m.name = name
  m.size = size
  m.mtime = mtime
  m.kind = kind
  
  # compute fuzzy score for ranking
  if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
    let target = if matcher.pathMode == pmFullPath: relPath else: name
    let ic = effectiveIgnoreCase(cfg)
    let t = if ic: target.toLowerAscii() else: target
    
    var bestScore = 999999
    for pat in matcher.fixed:
      let score = fuzzyMatch(pat, t)
      if score >= 0 and score < bestScore:
        bestScore = score
    m.fuzzyScore = bestScore
  
  some(m)

proc scanTreeCollect(rootAbs: string; startDir: string;
                     cfg: Config; matcher: Matcher;
                     ex: Excluder; gi: Gitignore; useGi: bool;
                     rootDev: int64;
                     contentRx: Option[Regex];
                     stats: var Stats;
                     matches: var seq[MatchResult];
                     stopAt: var bool) =
  var stack: seq[string] = @[startDir]

  while stack.len > 0 and (not stopAt):
    let dir = stack.pop()
    inc stats.visitedDirs
    inc stats.visited

    try:
      for pc, p in walkDir(dir, relative = false):
        if stopAt: break

        let rel = safeRelPath(p, rootAbs)
        let kind = entryTypeFromWalk(pc)
        let depth = relDepth(rel)

        if kind == etFile: inc stats.visitedFiles
        elif kind == etLink: inc stats.visitedLinks
        inc stats.visited

        if kind == etDir and shouldTraverseDir(cfg, rel, depth, ex, gi, useGi, rootDev, p):
          stack.add(p)

        let om = scanEntry(rootAbs, cfg, matcher, ex, gi, useGi, rootDev, p, rel, kind, contentRx, stats)
        if om.isSome:
          inc stats.matched
          matches.add(om.get)
          if cfg.limit > 0 and stats.matched >= cfg.limit:
            stopAt = true
            break

    except CatchableError:
      inc stats.errors
      continue

when compileOption("threads"):
  import std/threadpool

  proc scanTask(rootAbs: string; startDir: string;
                cfg: Config;
                giLines: seq[string]; useGi: bool;
                rootDev: int64;
                startTime: times.Time): SearchResult {.gcsafe.} =
    var res: SearchResult
    res.stats.startTime = startTime

    let ic = effectiveIgnoreCase(cfg)
    let matcher = buildMatcher(cfg)
    let ex = buildExcluder(cfg)
    let contentRx = compileContentRegex(cfg, ic)

    var gi: Gitignore
    if useGi:
      gi.ignoreCase = true
      gi.compileGitignore(giLines)

    var stop = false
    scanTreeCollect(rootAbs, startDir, cfg, matcher, ex, gi, useGi, rootDev, contentRx, res.stats, res.matches, stop)
    res

proc mergeStats(dst: var Stats; src: Stats) =
  dst.visited += src.visited
  dst.visitedFiles += src.visitedFiles
  dst.visitedDirs += src.visitedDirs
  dst.visitedLinks += src.visitedLinks
  dst.matched += src.matched
  dst.errors += src.errors
  dst.skipped += src.skipped
  dst.bytesRead += src.bytesRead

proc runSearchCollectSingleRoot(cfg: Config; rootAbs: string; globalStart: times.Time): SearchResult =
  result.stats.startTime = globalStart

  let ic = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let giInfo = buildGitignoreLines(cfg, rootAbs)
  let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
  let contentRx = compileContentRegex(cfg, ic)

  var gi: Gitignore
  if giInfo.useGi:
    gi.ignoreCase = true
    gi.compileGitignore(giInfo.lines)

  var stopAt = false

  if cfg.threads > 1:
    when compileOption("threads"):
      setMaxPoolSize(max(1, cfg.threads))

      var subdirs: seq[string] = @[]
      inc result.stats.visitedDirs
      inc result.stats.visited

      try:
        for pc, p in walkDir(rootAbs, relative = false):
          if stopAt: break

          let rel = safeRelPath(p, rootAbs)
          let kind = entryTypeFromWalk(pc)
          let depth = relDepth(rel)

          if kind == etFile: inc result.stats.visitedFiles
          elif kind == etLink: inc result.stats.visitedLinks
          inc result.stats.visited

          if kind == etDir and shouldTraverseDir(cfg, rel, depth, ex, gi, giInfo.useGi, rootDev, p):
            subdirs.add(p)

          let om = scanEntry(rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev, p, rel, kind, contentRx, result.stats)
          if om.isSome:
            inc result.stats.matched
            result.matches.add(om.get)
            if cfg.limit > 0 and result.stats.matched >= cfg.limit:
              stopAt = true
              break

      except CatchableError:
        inc result.stats.errors

      if not stopAt and subdirs.len > 0:
        var flows: seq[FlowVar[SearchResult]] = @[]
        for d in subdirs:
          flows.add(spawn scanTask(rootAbs, d, cfg, giInfo.lines, giInfo.useGi, rootDev, globalStart))

        for fv in flows:
          let part = ^fv
          result.matches.add(part.matches)
          mergeStats(result.stats, part.stats)

    else:
      scanTreeCollect(rootAbs, rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev, contentRx, result.stats, result.matches, stopAt)

  else:
    scanTreeCollect(rootAbs, rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev, contentRx, result.stats, result.matches, stopAt)

proc runSearchCollect*(cfg: Config): SearchResult =
  let start = times.getTime()
  result.stats.startTime = start

  for p in cfg.paths:
    let rootAbs = absolutePath(p)
    let part = runSearchCollectSingleRoot(cfg, rootAbs, start)
    result.matches.add(part.matches)
    mergeStats(result.stats, part.stats)

  result.stats.endTime = times.getTime()

proc runSearchStream*(cfg: Config; onMatch: proc(m: MatchResult)): Stats =
  result.startTime = times.getTime()

  let ic = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let contentRx = compileContentRegex(cfg, ic)

  for p in cfg.paths:
    let rootAbs = absolutePath(p)
    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1

    var gi: Gitignore
    if giInfo.useGi:
      gi.ignoreCase = true
      gi.compileGitignore(giInfo.lines)

    var stopAt = false
    var stack: seq[string] = @[rootAbs]

    while stack.len > 0 and (not stopAt):
      let dir = stack.pop()
      inc result.visitedDirs
      inc result.visited

      try:
        for pc, fp in walkDir(dir, relative = false):
          if stopAt: break

          let rel = safeRelPath(fp, rootAbs)
          let kind = entryTypeFromWalk(pc)
          let depth = relDepth(rel)

          if kind == etFile: inc result.visitedFiles
          elif kind == etLink: inc result.visitedLinks
          inc result.visited

          if kind == etDir and shouldTraverseDir(cfg, rel, depth, ex, gi, giInfo.useGi, rootDev, fp):
            stack.add(fp)

          let om = scanEntry(rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev, fp, rel, kind, contentRx, result)
          if om.isSome:
            inc result.matched
            onMatch(om.get)
            if cfg.limit > 0 and result.matched >= cfg.limit:
              stopAt = true
              break

      except CatchableError:
        inc result.errors
        continue

  result.endTime = times.getTime()
