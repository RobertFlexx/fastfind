# src/ff/search.nim
import std/[os, strutils, options, re, times]
import core, cli, matchers, content, fuzzy_match

when defined(posix):
  import std/posix

when compileOption("threads"):
  import std/[locks, atomics, threadpool, cpuinfo]
  import parallel

type
  StackEntry = object
    path: string
    depth: int

  SimplePatternKind = enum
    spkExact, spkPrefix, spkSuffix, spkContains, spkUniversal

when compileOption("threads"):
  type
    WorkerContext = object
      rootAbs: string
      cfg: Config
      matcher: Matcher
      ex: Excluder
      giLines: seq[string]
      useGi: bool
      rootDev: int64
      contentRx: Option[Regex]
      cachedIC: bool
      needInfo: bool
      includeHidden: bool
      needResultName: bool
      matchAll: bool
      hasExcludes: bool
      oneFileSystem: bool
      spKind: SimplePatternKind
      spCore: string

    WorkerArgs = object
      ctx: ptr WorkerContext
      queue: WorkQueue
      results: ResultCollector
      stats: AtomicStats
      workerId: int

proc effectiveThreadCount(cfg: Config): int {.inline.} =
  when compileOption("threads"):
    if cfg.threads > 0:
      return max(1, min(cfg.threads, 32))
    # Auto mode defaults to single-thread for low overhead.
    return 1
  else:
    1

proc isHiddenPath(relPath: string): bool {.inline.} =
  if relPath.len == 0: return false
  if relPath[0] == '.': return true
  for i in 0..<relPath.len - 1:
    let c = relPath[i]
    if c == '/' or c == '\\':
      if relPath[i + 1] == '.': return true
  false

proc isHiddenName(name: string): bool {.inline.} =
  name.len > 0 and name[0] == '.'

proc containsUpper(s: string): bool {.inline.} =
  for ch in s:
    if ch in {'A'..'Z'}: return true
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
    if dirExists(p / ".git") or fileExists(p / ".git"): return p
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

proc getDeviceId(path: string): int64 {.inline.} =
  when defined(posix):
    var st: Stat
    if posix.stat(path.cstring, st) == 0:
      return int64(st.st_dev)
  -1

proc passesSize(cfg: Config; size: int64): bool {.inline.} =
  if cfg.minSize >= 0 and size < cfg.minSize: return false
  if cfg.maxSize >= 0 and size > cfg.maxSize: return false
  true

proc passesTime(cfg: Config; mtime: times.Time): bool {.inline.} =
  if cfg.newerThan.isSome and mtime <= cfg.newerThan.get: return false
  if cfg.olderThan.isSome and mtime >= cfg.olderThan.get: return false
  true

proc buildMatcher(cfg: Config): Matcher =
  var m = Matcher(
    mode: cfg.matchMode,
    pathMode: cfg.pathMode,
    fullMatch: cfg.fullMatch,
    patterns: cfg.patterns,
    ignoreCase: cfg.ignoreCase,
    smartCase: cfg.smartCase
  )
  m.compile()
  m

proc buildExcluder(cfg: Config): Excluder =
  var ex = Excluder(ignoreCase: false, patterns: cfg.excludes)
  ex.compile()
  ex

proc buildGitignoreLines(cfg: Config; rootAbs: string): tuple[useGi: bool, lines: seq[string]] =
  result.useGi = cfg.useGitignore
  result.lines = @[]
  if result.useGi:
    let repo = findGitRepoRoot(rootAbs)
    result.lines = loadGitignoreLines(repo)

proc compileContentRegex(cfg: Config; ic: bool): Option[Regex] =
  if cfg.containsRegex.len == 0: return none(Regex)
  let flags = if ic: {reIgnoreCase} else: {}
  try: some(re(cfg.containsRegex, flags))
  except CatchableError: none(Regex)

proc shouldTraverseDir(cfg: Config; relPath: string; depth: int;
                       ex: Excluder; gi: Gitignore; useGi: bool;
                       rootDev: int64; fullPath: string;
                       includeHidden: bool): bool {.inline.} =
  if (not includeHidden) and isHiddenPath(relPath): return false
  if cfg.maxDepth >= 0 and depth >= cfg.maxDepth: return false
  if ex.compiled.len > 0 and ex.isExcluded(relPath): return false
  if useGi and isGitIgnored(gi, relPath): return false
  if cfg.oneFileSystem and rootDev >= 0:
    let dev = getDeviceId(fullPath)
    if dev >= 0 and dev != rootDev: return false
  true

proc shouldTraverseDirFast(cfg: Config; relPath: string; depth: int;
                           ex: Excluder; gi: Gitignore; useGi: bool;
                           rootDev: int64; fullPath: string;
                           includeHidden: bool;
                           hasExcludes: bool;
                           oneFileSystem: bool): bool {.inline.} =
  if not includeHidden and isHiddenPath(relPath): return false
  if cfg.maxDepth >= 0 and depth >= cfg.maxDepth: return false
  if hasExcludes and ex.isExcluded(relPath): return false
  if useGi and isGitIgnored(gi, relPath): return false
  if oneFileSystem and rootDev >= 0:
    let dev = getDeviceId(fullPath)
    if dev >= 0 and dev != rootDev: return false
  true

proc needsFileInfo(cfg: Config): bool {.inline.} =
  cfg.minSize >= 0 or cfg.maxSize >= 0 or
  cfg.newerThan.isSome or cfg.olderThan.isSome or
  cfg.containsText.len > 0 or cfg.containsRegex.len > 0

proc needsResultName(cfg: Config): bool {.inline.} =
  cfg.sortKey == skName or
  cfg.outputMode in {omLong, omJson, omNdJson, omTable}

proc extractName(relPath: string): string {.inline.} =
  let sepIdx = rfind(relPath, {'/', '\\'})
  if sepIdx >= 0 and sepIdx + 1 < relPath.len: relPath[sepIdx + 1..^1]
  elif relPath.len > 0: relPath
  else: ""

proc scanEntry(rootAbs: string; cfg: Config; matcher: Matcher;
               ex: Excluder; gi: Gitignore; useGi: bool;
               rootDev: int64; fullPath, relPath: string;
               kind: EntryType; depth: int;
               contentRx: Option[Regex]; cachedIC: bool;
               needInfo: bool; includeHidden: bool;
               needResultName: bool;
               stats: var Stats): Option[MatchResult] =
  if kind notin cfg.types:
    inc stats.skipped
    return none(MatchResult)

  if cfg.minDepth > 0 and depth < cfg.minDepth:
    inc stats.skipped
    return none(MatchResult)

  if cfg.maxDepth >= 0 and depth > cfg.maxDepth:
    inc stats.skipped
    return none(MatchResult)

  if (not includeHidden) and isHiddenPath(relPath):
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

  var name = ""
  template ensureName() =
    if name.len == 0:
      name = extractName(relPath)
  var fuzzyScore = -1

  if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
    ensureName()
    let target = if matcher.pathMode == pmFullPath: relPath else: name
    let t = if cachedIC: target.toLowerAscii() else: target

    var bestScore = 999999
    for pat in matcher.fixed:
      let score = fuzzyMatch(pat, t)
      if score >= 0 and score < bestScore:
        bestScore = score

    if bestScore >= 999999:
      return none(MatchResult)
    fuzzyScore = bestScore
  else:
    if not matcher.anyMatch(name, relPath):
      return none(MatchResult)

  if needResultName:
    ensureName()

  var size: int64 = 0
  var mtime: times.Time = times.fromUnix(0)

  if needInfo:
    var info: FileInfo
    try:
      info = getFileInfo(fullPath, followSymlink = cfg.followSymlinks)
    except CatchableError:
      inc stats.errors
      return none(MatchResult)

    size = info.size.int64
    mtime = info.lastWriteTime

    if not passesSize(cfg, size) or not passesTime(cfg, mtime):
      inc stats.skipped
      return none(MatchResult)

    if cfg.containsText.len > 0:
      var br: int64 = 0
      let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes, cfg.allowBinary, br)
      stats.bytesRead += br
      if not ok: return none(MatchResult)

    if cfg.containsRegex.len > 0:
      if contentRx.isNone: return none(MatchResult)
      var br: int64 = 0
      let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br)
      stats.bytesRead += br
      if not ok: return none(MatchResult)

  some(MatchResult(
    path: relPath,
    relPath: relPath,
    absPath: fullPath,
    name: if needResultName: name else: "",
    size: size,
    mtime: mtime,
    kind: kind,
    fuzzyScore: fuzzyScore
  ))

proc scanEntryPathOnly(cfg: Config; matcher: Matcher;
                      ex: Excluder; gi: Gitignore; useGi: bool;
                      rootDev: int64; fullPath, relPath: string;
                      kind: EntryType; depth: int;
                      contentRx: Option[Regex]; cachedIC: bool;
                      needInfo: bool; includeHidden: bool;
                      stats: var Stats): bool =
  if kind notin cfg.types:
    inc stats.skipped
    return false

  if cfg.minDepth > 0 and depth < cfg.minDepth:
    inc stats.skipped
    return false

  if cfg.maxDepth >= 0 and depth > cfg.maxDepth:
    inc stats.skipped
    return false

  if (not includeHidden) and isHiddenPath(relPath):
    inc stats.skipped
    return false

  if ex.compiled.len > 0 and ex.isExcluded(relPath):
    inc stats.skipped
    return false

  if useGi and isGitIgnored(gi, relPath):
    inc stats.skipped
    return false

  if (cfg.containsText.len > 0 or cfg.containsRegex.len > 0) and kind != etFile:
    inc stats.skipped
    return false

  if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
    let name = extractName(relPath)
    let target = if matcher.pathMode == pmFullPath: relPath else: name
    let t = if cachedIC: target.toLowerAscii() else: target
    var bestScore = 999999
    for pat in matcher.fixed:
      let score = fuzzyMatch(pat, t)
      if score >= 0 and score < bestScore:
        bestScore = score
    if bestScore >= 999999:
      return false
  else:
    if not matcher.anyMatch("", relPath):
      return false

  if needInfo:
    var info: FileInfo
    try:
      info = getFileInfo(fullPath, followSymlink = cfg.followSymlinks)
    except CatchableError:
      inc stats.errors
      return false

    if not passesSize(cfg, info.size.int64) or not passesTime(cfg, info.lastWriteTime):
      inc stats.skipped
      return false

    if cfg.containsText.len > 0:
      var br: int64 = 0
      let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes, cfg.allowBinary, br)
      stats.bytesRead += br
      if not ok: return false

    if cfg.containsRegex.len > 0:
      if contentRx.isNone: return false
      var br: int64 = 0
      let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br)
      stats.bytesRead += br
      if not ok: return false

  true

proc outputPathFor(cfg: Config; relPath, fullPath: string): string {.inline.} =
  if cfg.absolute: fullPath
  elif cfg.relative: relPath
  else: relPath

proc baseStartIdx(path: string): int {.inline.} =
  var i = path.len - 1
  while i >= 0:
    if path[i] == '/' or path[i] == '\\':
      return i + 1
    dec i
  0

proc isHiddenBase(path: string): bool {.inline.} =
  let b = baseStartIdx(path)
  b < path.len and path[b] == '.'

proc parseSimplePattern(cfg: Config; kind: var SimplePatternKind; core: var string): bool =
  if cfg.patterns.len != 1: return false
  if cfg.pathMode != pmBaseName: return false
  if cfg.matchMode == mmFixed:
    kind = if cfg.fullMatch: spkExact else: spkContains
    core = cfg.patterns[0]
    return true
  if cfg.matchMode != mmGlob: return false
  let p = cfg.patterns[0]
  if p.len == 0:
    kind = spkExact
    core = ""
    return true
  if p == "*":
    kind = spkUniversal
    core = ""
    return true
  if p[0] == '*' and p[^1] == '*' and p.len > 2 and p[1..^2].find({'*', '?', '[', ']'}) < 0:
    kind = spkContains
    core = p[1..^2]
    return true
  if p[0] == '*' and p.len > 1 and p[1..^1].find({'*', '?', '[', ']'}) < 0:
    kind = spkSuffix
    core = p[1..^1]
    return true
  if p[^1] == '*' and p.len > 1 and p[0..^2].find({'*', '?', '[', ']'}) < 0:
    kind = spkPrefix
    core = p[0..^2]
    return true
  if p.find({'*', '?', '[', ']'}) < 0:
    kind = spkExact
    core = p
    return true
  false

proc matchSimpleBase(path: string; kind: SimplePatternKind; core: string; ignoreCase: bool): bool {.inline.} =
  let b = baseStartIdx(path)
  let nLen = path.len - b
  case kind
  of spkUniversal:
    true
  of spkExact:
    if core.len != nLen: return false
    if ignoreCase:
      for i in 0..<core.len:
        var c = path[b + i]
        if c in {'A'..'Z'}: c = chr(ord(c) + 32)
        if c != core[i]: return false
    else:
      for i in 0..<core.len:
        if path[b + i] != core[i]: return false
    true
  of spkPrefix:
    if core.len > nLen: return false
    if ignoreCase:
      for i in 0..<core.len:
        var c = path[b + i]
        if c in {'A'..'Z'}: c = chr(ord(c) + 32)
        if c != core[i]: return false
    else:
      for i in 0..<core.len:
        if path[b + i] != core[i]: return false
    true
  of spkSuffix:
    if core.len > nLen: return false
    let off = path.len - core.len
    if ignoreCase:
      for i in 0..<core.len:
        var c = path[off + i]
        if c in {'A'..'Z'}: c = chr(ord(c) + 32)
        if c != core[i]: return false
    else:
      for i in 0..<core.len:
        if path[off + i] != core[i]: return false
    true
  of spkContains:
    if core.len == 0: return true
    if core.len > nLen: return false
    let last = path.len - core.len
    var i = b
    if ignoreCase:
      while i <= last:
        var ok = true
        for j in 0..<core.len:
          var c = path[i + j]
          if c in {'A'..'Z'}: c = chr(ord(c) + 32)
          if c != core[j]:
            ok = false
            break
        if ok: return true
        inc i
    else:
      while i <= last:
        var ok = true
        for j in 0..<core.len:
          if path[i + j] != core[j]:
            ok = false
            break
        if ok: return true
        inc i
    false

proc canUseSimplePathStream(cfg: Config): bool {.inline.} =
  (cfg.matchMode in {mmGlob, mmFixed}) and
  (not cfg.fuzzyMode) and
  (not cfg.followSymlinks) and
  cfg.excludes.len == 0 and
  (not cfg.oneFileSystem) and
  cfg.minDepth == 0 and
  cfg.maxDepth < 0 and
  cfg.minSize < 0 and cfg.maxSize < 0 and
  cfg.newerThan.isNone and cfg.olderThan.isNone and
  cfg.containsText.len == 0 and cfg.containsRegex.len == 0 and
  cfg.types == {etFile, etDir, etLink}

when defined(posix):
  type
    PosixStackEntry = object
      absPath: string
      relPath: string
      depth: int

  proc direntKind(d: ptr Dirent; parentAbs, name: string): EntryType =
    when declared(DT_DIR):
      if d.d_type == DT_DIR: return etDir
      if d.d_type == DT_REG: return etFile
      if d.d_type == DT_LNK: return etLink
    let fullPath = parentAbs / name
    var st: Stat
    if lstat(fullPath.cstring, st) == 0:
      if S_ISDIR(st.st_mode): return etDir
      if S_ISLNK(st.st_mode): return etLink
    etFile

  proc runSearchStreamPathsSimplePosix(cfg: Config; rootAbs: string;
                                       kind: SimplePatternKind; coreCmp: string;
                                       ignoreCase: bool; emitted: var int;
                                       onPath: proc(p: string)): Stats =
    var stack = newSeqOfCap[PosixStackEntry](64)
    stack.add(PosixStackEntry(absPath: rootAbs, relPath: "", depth: 0))
    let hasLimit = cfg.limit > 0
    var pathBuf = newStringOfCap(512)
    var absBuf = newStringOfCap(512)
    
    let wantAbsolute = cfg.absolute
    let wantHidden = cfg.includeHidden
    let defaultTypes = cfg.types == {etFile, etDir, etLink}
    
    while stack.len > 0:
      if hasLimit and emitted >= cfg.limit:
        break
      let entry = stack.pop()
      inc result.visitedDirs
      inc result.visited

      let dirp = opendir(entry.absPath.cstring)
      if dirp.isNil:
        inc result.errors
        continue
      defer: discard closedir(dirp)

      let currentAbsPath = entry.absPath
      let currentRelPath = entry.relPath
      let currentRelEmpty = currentRelPath.len == 0
      var currentAbsSlashLen = currentAbsPath.len
      if currentAbsPath.len > 0 and currentAbsPath[^1] != '/':
        currentAbsSlashLen = currentAbsPath.len + 1

      while true:
        if hasLimit and emitted >= cfg.limit:
          break
        let dent = readdir(dirp)
        if dent.isNil: break
        let name = $cast[cstring](addr dent.d_name[0])
        if name == "." or name == "..":
          continue
        if not wantHidden and name.len > 0 and name[0] == '.':
          inc result.skipped
          continue

        if not matchSimpleBase(name, kind, coreCmp, ignoreCase):
          inc result.visited
          when declared(DT_DIR):
            if dent.d_type == DT_DIR:
              inc result.visitedDirs
              if currentRelEmpty:
                stack.add(PosixStackEntry(absPath: currentAbsPath & "/" & name, relPath: name, depth: entry.depth + 1))
              else:
                pathBuf.setLen(0)
                pathBuf.add(currentRelPath)
                pathBuf.add('/')
                pathBuf.add(name)
                stack.add(PosixStackEntry(absPath: currentAbsPath & "/" & name, relPath: pathBuf, depth: entry.depth + 1))
            elif dent.d_type == DT_REG:
              inc result.visitedFiles
            elif dent.d_type == DT_LNK:
              inc result.visitedLinks
          continue

        inc result.matched
        let kindVal = when declared(DT_DIR):
          if dent.d_type == DT_DIR: etDir
          elif dent.d_type == DT_REG: etFile
          elif dent.d_type == DT_LNK: etLink
          else: etFile
        else:
          direntKind(dent, currentAbsPath, name)

        if kindVal == etDir:
          let childDepth = entry.depth + 1
          if currentRelEmpty:
            stack.add(PosixStackEntry(absPath: currentAbsPath & "/" & name, relPath: name, depth: childDepth))
          else:
            pathBuf.setLen(0)
            pathBuf.add(currentRelPath)
            pathBuf.add('/')
            pathBuf.add(name)
            stack.add(PosixStackEntry(absPath: currentAbsPath & "/" & name, relPath: pathBuf, depth: childDepth))

        if defaultTypes or (kindVal in cfg.types):
          if wantAbsolute:
            absBuf.setLen(0)
            absBuf.add(currentAbsPath)
            if currentAbsPath.len > 0 and currentAbsPath[^1] != '/':
              absBuf.add('/')
            absBuf.add(name)
            onPath(absBuf)
          elif currentRelEmpty:
            onPath(name)
          else:
            pathBuf.setLen(0)
            pathBuf.add(currentRelPath)
            pathBuf.add('/')
            pathBuf.add(name)
            onPath(pathBuf)
          inc emitted

when compileOption("threads"):
  proc scanEntryAtomic(rootAbs: string; cfg: Config; matcher: Matcher;
                       ex: Excluder; gi: Gitignore; useGi: bool;
                       rootDev: int64; fullPath, relPath: string;
                       kind: EntryType; depth: int;
                       contentRx: Option[Regex]; cachedIC: bool;
                       needInfo: bool; includeHidden: bool;
                       needResultName: bool;
                       matchAll: bool;
                       hasExcludes: bool;
                       stats: AtomicStats): Option[MatchResult] =
    if kind notin cfg.types:
      stats.incSkipped()
      return none(MatchResult)

    if cfg.minDepth > 0 and depth < cfg.minDepth:
      stats.incSkipped()
      return none(MatchResult)

    if cfg.maxDepth >= 0 and depth > cfg.maxDepth:
      stats.incSkipped()
      return none(MatchResult)

    if not includeHidden and isHiddenPath(relPath):
      stats.incSkipped()
      return none(MatchResult)

    if hasExcludes and ex.isExcluded(relPath):
      stats.incSkipped()
      return none(MatchResult)

    if useGi and isGitIgnored(gi, relPath):
      stats.incSkipped()
      return none(MatchResult)

    if (cfg.containsText.len > 0 or cfg.containsRegex.len > 0) and kind != etFile:
      stats.incSkipped()
      return none(MatchResult)

    var name = ""
    template ensureName() =
      if name.len == 0:
        name = extractName(relPath)
    var fuzzyScore = -1

    if matchAll:
      ensureName()
    elif cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
      ensureName()
      let target = if matcher.pathMode == pmFullPath: relPath else: name
      let t = if cachedIC: target.toLowerAscii() else: target
      var bestScore = 999999
      for pat in matcher.fixed:
        let score = fuzzyMatch(pat, t)
        if score >= 0 and score < bestScore:
          bestScore = score
      if bestScore >= 999999:
        return none(MatchResult)
      fuzzyScore = bestScore
    elif not matchAll:
      if not matcher.anyMatch(name, relPath):
        return none(MatchResult)

    if needResultName:
      ensureName()

    var size: int64 = 0
    var mtime: times.Time = times.fromUnix(0)

    if needInfo:
      var info: FileInfo
      try:
        info = getFileInfo(fullPath, followSymlink = cfg.followSymlinks)
      except CatchableError:
        stats.incErrors()
        return none(MatchResult)
      size = info.size.int64
      mtime = info.lastWriteTime
      if not passesSize(cfg, size) or not passesTime(cfg, mtime):
        stats.incSkipped()
        return none(MatchResult)
      if cfg.containsText.len > 0:
        var br: int64 = 0
        let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes, cfg.allowBinary, br)
        stats.addBytesRead(br)
        if not ok: return none(MatchResult)
      if cfg.containsRegex.len > 0:
        if contentRx.isNone: return none(MatchResult)
        var br: int64 = 0
        let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br)
        stats.addBytesRead(br)
        if not ok: return none(MatchResult)

    some(MatchResult(
      path: relPath,
      relPath: relPath,
      absPath: fullPath,
      name: if needResultName: name else: "",
      size: size,
      mtime: mtime,
      kind: kind,
      fuzzyScore: fuzzyScore
    ))

  proc workerProc(args: WorkerArgs) {.thread, gcsafe.} =
    let ctx = args.ctx
    var localMatches = newSeqOfCap[MatchResult](128)
    var childDirs = newSeqOfCap[DirEntry](128)
    var relBuf = initPathBuffer(512)
    var spinCount = 0

    var gi: Gitignore
    if ctx.useGi:
      gi.ignoreCase = true
      gi.compileGitignore(ctx.giLines)

    while true:
      if args.queue.isShutdown() or args.results.isLimitReached():
        break

      var batch = args.queue.tryPopBatch(1024)
      
      if batch.len == 0:
        spinCount.inc
        if args.queue.isComplete():
          break
        if spinCount > 200:
          spinCount = 0
          if args.queue.isComplete():
            break
          os.sleep(1)
        continue

      spinCount = 0

      for entry in batch:
        childDirs.setLen(0)
        args.stats.incVisitedDirs()
        args.stats.incVisited()

        try:
          for pc, fullPath in walkDir(entry.path, relative = false):
            if args.results.isLimitReached():
              break

            let kind = entryTypeFromWalk(pc)
            let childDepth = entry.depth + 1

            args.stats.incVisited()
            case kind
            of etFile: args.stats.incVisitedFiles()
            of etLink: args.stats.incVisitedLinks()
            of etDir: discard

            computeRelPathInPlace(fullPath, ctx.rootAbs, relBuf)
            let relPath = relBuf.toString()

            if kind == etDir and shouldTraverseDirFast(ctx.cfg, relPath, childDepth,
                                   ctx.ex, gi, ctx.useGi,
                                   ctx.rootDev, fullPath, ctx.includeHidden,
                                   ctx.hasExcludes, ctx.oneFileSystem):
              childDirs.add(DirEntry(path: fullPath, relPath: relPath, depth: childDepth))

            let om = scanEntryAtomic(
              ctx.rootAbs, ctx.cfg, ctx.matcher,
              ctx.ex, gi, ctx.useGi, ctx.rootDev,
              fullPath, relPath, kind, childDepth,
              ctx.contentRx, ctx.cachedIC,
              ctx.needInfo, ctx.includeHidden, ctx.needResultName,
              ctx.matchAll, ctx.hasExcludes, args.stats
            )

            if om.isSome:
              args.stats.incMatched()
              localMatches.add(om.get)

        except CatchableError:
          args.stats.incErrors()

        if childDirs.len > 0:
          args.queue.pushBatch(childDirs)
        args.queue.decPending()

      if localMatches.len >= 64:
        let added = args.results.addMatches(localMatches)
        localMatches.setLen(0)
        if added == 0 and args.results.isLimitReached():
          args.queue.signalShutdown()
          break

    if localMatches.len > 0:
      let added = args.results.addMatches(localMatches)
      if added == 0 and args.results.isLimitReached():
        args.queue.signalShutdown()

  proc workerFastPathProc(args: WorkerArgs) {.thread, gcsafe.} =
    let ctx = args.ctx
    var localMatches = newSeqOfCap[MatchResult](256)
    var pathBuf = newStringOfCap(512)

    while true:
      if args.queue.isShutdown() or args.results.isLimitReached():
        break

      var batch = args.queue.tryPopBatch(2048)
      
      if batch.len == 0:
        if args.queue.isComplete():
          break
        os.sleep(1)
        continue

      for entry in batch:
        args.stats.incVisitedDirs()
        args.stats.incVisited()

        let dirp = opendir(entry.path.cstring)
        if dirp.isNil:
          args.stats.incErrors()
          continue
        defer: discard closedir(dirp)

        let currentPath = entry.path
        let currentRelPath = entry.relPath
        let currentRelEmpty = currentRelPath.len == 0
        var currentPathSlash = ""
        if currentPath.len > 0 and currentPath[^1] != '/':
          currentPathSlash = currentPath & '/'
        else:
          currentPathSlash = currentPath

        var childDirs = newSeqOfCap[DirEntry](128)

        while true:
          if args.results.isLimitReached():
            break
          let dent = readdir(dirp)
          if dent.isNil: break
          let name = $cast[cstring](addr dent.d_name[0])
          if name == "." or name == "..":
            continue
          if not ctx.includeHidden and name.len > 0 and name[0] == '.':
            args.stats.incSkipped()
            continue

          if not matchSimpleBase(name, ctx.spKind, ctx.spCore, ctx.cachedIC):
            args.stats.incVisited()
            when declared(DT_DIR):
              if dent.d_type == DT_DIR:
                args.stats.incVisitedDirs()
                if currentRelEmpty:
                  childDirs.add(DirEntry(path: currentPathSlash & name, relPath: name, depth: entry.depth + 1))
                else:
                  pathBuf.setLen(0)
                  pathBuf.add(currentRelPath)
                  pathBuf.add('/')
                  pathBuf.add(name)
                  childDirs.add(DirEntry(path: currentPathSlash & name, relPath: pathBuf, depth: entry.depth + 1))
            continue

          args.stats.incMatched()
          let kindVal = when declared(DT_DIR):
            if dent.d_type == DT_DIR: etDir
            elif dent.d_type == DT_REG: etFile
            elif dent.d_type == DT_LNK: etLink
            else: etFile
          else:
            etFile

          if kindVal == etDir:
            if currentRelEmpty:
              childDirs.add(DirEntry(path: currentPathSlash & name, relPath: name, depth: entry.depth + 1))
            else:
              pathBuf.setLen(0)
              pathBuf.add(currentRelPath)
              pathBuf.add('/')
              pathBuf.add(name)
              childDirs.add(DirEntry(path: currentPathSlash & name, relPath: pathBuf, depth: entry.depth + 1))

          if kindVal in ctx.cfg.types:
            let outPath = if ctx.cfg.absolute:
              currentPathSlash & name
            elif currentRelEmpty:
              name
            else:
              pathBuf.setLen(0)
              pathBuf.add(currentRelPath)
              pathBuf.add('/')
              pathBuf.add(name)
              pathBuf
            localMatches.add(MatchResult(
              path: outPath,
              relPath: outPath,
              absPath: currentPathSlash & name,
              name: if ctx.needResultName: name else: "",
              size: 0,
              mtime: times.fromUnix(0),
              kind: kindVal,
              fuzzyScore: -1
            ))

        if childDirs.len > 0:
          args.queue.pushBatch(childDirs)

        if localMatches.len >= 128:
          let added = args.results.addMatches(localMatches)
          localMatches.setLen(0)
          if added == 0 and args.results.isLimitReached():
            args.queue.signalShutdown()
            break

    if localMatches.len > 0:
      discard args.results.addMatches(localMatches)

  proc runParallelSearchFastPath(cfg: Config; rootAbs: string;
                                  spKind: SimplePatternKind; spCore: string;
                                  cachedIC: bool; globalStart: times.Time): SearchResult =
    result.stats.startTime = globalStart
    let numWorkers = effectiveThreadCount(cfg)

    var ctx = WorkerContext(
      rootAbs: rootAbs,
      cfg: cfg,
      matcher: Matcher(),
      ex: Excluder(),
      giLines: @[],
      useGi: false,
      rootDev: -1,
      contentRx: none(Regex),
      cachedIC: cachedIC,
      needInfo: false,
      includeHidden: cfg.includeHidden,
      needResultName: needsResultName(cfg),
      matchAll: spKind == spkUniversal,
      hasExcludes: false,
      oneFileSystem: false,
      spKind: spKind,
      spCore: spCore
    )

    let queue = newWorkQueue()
    let results = newResultCollector(cfg.limit)
    let stats = newAtomicStats()

    queue.push(DirEntry(path: rootAbs, relPath: "", depth: 0))

    if numWorkers == 1:
      var args = WorkerArgs(
        ctx: addr ctx,
        queue: queue,
        results: results,
        stats: stats,
        workerId: 0
      )
      workerFastPathProc(args)
    else:
      var threads = newSeq[Thread[WorkerArgs]](numWorkers)
      for i in 0..<numWorkers:
        var args = WorkerArgs(
          ctx: addr ctx,
          queue: queue,
          results: results,
          stats: stats,
          workerId: i
        )
        createThread(threads[i], workerFastPathProc, args)
      for i in 0..<numWorkers:
        joinThread(threads[i])

    result.matches = results.getMatches()
    result.stats = stats.toStats(globalStart, times.getTime())

    queue.destroy()
    results.destroy()
    stats.destroy()

  proc runParallelSearch(cfg: Config; rootAbs: string; globalStart: times.Time): SearchResult =
    result.stats.startTime = globalStart

    let numWorkers = effectiveThreadCount(cfg)
    let cachedIC = effectiveIgnoreCase(cfg)
    let matcher = buildMatcher(cfg)
    let ex = buildExcluder(cfg)
    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
    let contentRx = compileContentRegex(cfg, cachedIC)
    let needInfo = needsFileInfo(cfg)
    let includeHidden = cfg.includeHidden
    let needResultName = needsResultName(cfg)

    var spKind: SimplePatternKind
    var spCore = ""
    let useFastPath = canUseSimplePathStream(cfg) and parseSimplePattern(cfg, spKind, spCore)
    let spCoreCmp = if cachedIC: spCore.toLowerAscii() else: spCore

    var ctx = WorkerContext(
      rootAbs: rootAbs,
      cfg: cfg,
      matcher: matcher,
      ex: ex,
      giLines: giInfo.lines,
      useGi: giInfo.useGi,
      rootDev: rootDev,
      contentRx: contentRx,
      cachedIC: cachedIC,
      needInfo: needInfo,
      includeHidden: includeHidden,
      needResultName: needResultName,
      matchAll: matcher.matchAll,
      hasExcludes: cfg.excludes.len > 0,
      oneFileSystem: cfg.oneFileSystem,
      spKind: spKind,
      spCore: spCoreCmp
    )

    let queue = newWorkQueue()
    let results = newResultCollector(cfg.limit)
    let stats = newAtomicStats()

    queue.push(DirEntry(path: rootAbs, relPath: "", depth: 0))

    if numWorkers == 1:
      var args = WorkerArgs(
        ctx: addr ctx,
        queue: queue,
        results: results,
        stats: stats,
        workerId: 0
      )
      workerProc(args)
    else:
      var threads = newSeq[Thread[WorkerArgs]](numWorkers)
      for i in 0..<numWorkers:
        var args = WorkerArgs(
          ctx: addr ctx,
          queue: queue,
          results: results,
          stats: stats,
          workerId: i
        )
        createThread(threads[i], workerProc, args)
      for i in 0..<numWorkers:
        joinThread(threads[i])

    result.matches = results.getMatches()
    result.stats = stats.toStats(globalStart, times.getTime())

    queue.destroy()
    results.destroy()
    stats.destroy()

proc scanTreeCollect(rootAbs, startDir: string; cfg: Config;
                     matcher: Matcher; ex: Excluder;
                     gi: Gitignore; useGi: bool; rootDev: int64;
                     contentRx: Option[Regex]; cachedIC: bool;
                     needInfo: bool; includeHidden: bool; needResultName: bool;
                     stats: var Stats; matches: var seq[MatchResult];
                     stopAt: var bool) =
  var stack = newSeqOfCap[StackEntry](64)
  stack.add(StackEntry(path: startDir, depth: 0))
  let limit = cfg.limit
  let hasLimit = limit > 0
  template relPathFor(fullPath: string): string =
    when compileOption("threads"):
      computeRelPathFast(fullPath, rootAbs)
    else:
      safeRelPath(fullPath, rootAbs)

  while stack.len > 0 and not stopAt:
    let entry = stack.pop()
    inc stats.visitedDirs
    inc stats.visited

    try:
      for pc, p in walkDir(entry.path, relative = false):
        if stopAt: break

        let kind = entryTypeFromWalk(pc)
        let childDepth = entry.depth + 1

        if kind == etFile: inc stats.visitedFiles
        elif kind == etLink: inc stats.visitedLinks
        inc stats.visited

        let rel = relPathFor(p)

        if kind == etDir and shouldTraverseDir(cfg, rel, childDepth, ex, gi, useGi, rootDev, p, includeHidden):
          stack.add(StackEntry(path: p, depth: childDepth))

        let om = scanEntry(rootAbs, cfg, matcher, ex, gi, useGi, rootDev,
                           p, rel, kind, childDepth, contentRx, cachedIC,
                           needInfo, includeHidden, needResultName, stats)
        if om.isSome:
          inc stats.matched
          matches.add(om.get)
          if hasLimit and stats.matched >= limit:
            stopAt = true
            break

    except CatchableError:
      inc stats.errors

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

  when compileOption("threads"):
    if effectiveThreadCount(cfg) > 1:
      return runParallelSearch(cfg, rootAbs, globalStart)

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let giInfo = buildGitignoreLines(cfg, rootAbs)
  let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
  let contentRx = compileContentRegex(cfg, cachedIC)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden
  let needResultName = needsResultName(cfg)

  var gi: Gitignore
  if giInfo.useGi:
    gi.ignoreCase = true
    gi.compileGitignore(giInfo.lines)

  var stopAt = false
  scanTreeCollect(rootAbs, rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                  contentRx, cachedIC, needInfo, includeHidden, needResultName,
                  result.stats, result.matches, stopAt)

  result.stats.endTime = times.getTime()

proc runSearchCollect*(cfg: Config): SearchResult =
  let start = times.getTime()
  result.stats.startTime = start

  for p in cfg.paths:
    if cfg.limit > 0 and result.matches.len >= cfg.limit:
      break

    let rootAbs = absolutePath(p)
    var localCfg = cfg
    if cfg.limit > 0:
      localCfg.limit = max(0, cfg.limit - result.matches.len)
      if localCfg.limit == 0:
        break

    let part = runSearchCollectSingleRoot(localCfg, rootAbs, start)
    result.matches.add(part.matches)
    mergeStats(result.stats, part.stats)

  result.stats.endTime = times.getTime()

proc runSearchStream*(cfg: Config; onMatch: proc(m: MatchResult)): Stats =
  result.startTime = times.getTime()

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let contentRx = compileContentRegex(cfg, cachedIC)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden
  let needResultName = needsResultName(cfg)
  let hasLimit = cfg.limit > 0
  var emitted = 0

  for p in cfg.paths:
    if hasLimit and emitted >= cfg.limit:
      break

    let rootAbs = absolutePath(p)
    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1

    var gi: Gitignore
    if giInfo.useGi:
      gi.ignoreCase = true
      gi.compileGitignore(giInfo.lines)

    var stopAt = false
    var stack = newSeqOfCap[StackEntry](64)
    stack.add(StackEntry(path: rootAbs, depth: 0))
    template relPathFor(fullPath: string): string =
      when compileOption("threads"):
        computeRelPathFast(fullPath, rootAbs)
      else:
        safeRelPath(fullPath, rootAbs)

    while stack.len > 0 and not stopAt:
      let entry = stack.pop()
      inc result.visitedDirs
      inc result.visited

      try:
        for pc, fp in walkDir(entry.path, relative = false):
          if stopAt: break

          let kind = entryTypeFromWalk(pc)
          let childDepth = entry.depth + 1

          if kind == etFile: inc result.visitedFiles
          elif kind == etLink: inc result.visitedLinks
          inc result.visited

          let rel = relPathFor(fp)

          if kind == etDir and shouldTraverseDir(cfg, rel, childDepth, ex, gi, giInfo.useGi, rootDev, fp, includeHidden):
            stack.add(StackEntry(path: fp, depth: childDepth))

          let om = scanEntry(rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                             fp, rel, kind, childDepth, contentRx, cachedIC,
                             needInfo, includeHidden, needResultName, result)
          if om.isSome:
            inc result.matched
            onMatch(om.get)
            inc emitted
            if hasLimit and emitted >= cfg.limit:
              stopAt = true
              break

      except CatchableError:
        inc result.errors

  result.endTime = times.getTime()

proc runSearchStreamPaths*(cfg: Config; onPath: proc(p: string)): Stats =
  result.startTime = times.getTime()

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let contentRx = compileContentRegex(cfg, cachedIC)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden
  let hasLimit = cfg.limit > 0
  var emitted = 0
  var spKind: SimplePatternKind
  var spCore = ""
  let simplePathMode = canUseSimplePathStream(cfg) and parseSimplePattern(cfg, spKind, spCore)
  let spCoreCmp = if cachedIC: spCore.toLowerAscii() else: spCore

  for p in cfg.paths:
    if hasLimit and emitted >= cfg.limit:
      break

    let rootAbs = absolutePath(p)

    when defined(posix):
      if simplePathMode:
        let s = runSearchStreamPathsSimplePosix(cfg, rootAbs, spKind, spCoreCmp, cachedIC, emitted, onPath)
        result.visited += s.visited
        result.visitedFiles += s.visitedFiles
        result.visitedDirs += s.visitedDirs
        result.visitedLinks += s.visitedLinks
        result.matched += s.matched
        result.errors += s.errors
        result.skipped += s.skipped
        result.bytesRead += s.bytesRead
        continue

    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1

    var gi: Gitignore
    if giInfo.useGi:
      gi.ignoreCase = true
      gi.compileGitignore(giInfo.lines)

    var stopAt = false
    var stack = newSeqOfCap[StackEntry](64)
    stack.add(StackEntry(path: rootAbs, depth: 0))
    template relPathFor(fullPath: string): string =
      when compileOption("threads"):
        computeRelPathFast(fullPath, rootAbs)
      else:
        safeRelPath(fullPath, rootAbs)

    while stack.len > 0 and not stopAt:
      let entry = stack.pop()
      inc result.visitedDirs
      inc result.visited

      try:
        for pc, fp in walkDir(entry.path, relative = false):
          if stopAt: break

          let kind = entryTypeFromWalk(pc)
          let childDepth = entry.depth + 1

          if kind == etFile: inc result.visitedFiles
          elif kind == etLink: inc result.visitedLinks
          inc result.visited

          if simplePathMode:
            if kind == etDir:
              if includeHidden or not isHiddenBase(fp):
                stack.add(StackEntry(path: fp, depth: childDepth))
            else:
              if includeHidden or not isHiddenBase(fp):
                if matchSimpleBase(fp, spKind, spCoreCmp, cachedIC):
                  inc result.matched
                  let rel = relPathFor(fp)
                  onPath(outputPathFor(cfg, rel, fp))
                  inc emitted
                  if hasLimit and emitted >= cfg.limit:
                    stopAt = true
                    break
          else:
            let rel = relPathFor(fp)

            if kind == etDir and shouldTraverseDir(cfg, rel, childDepth, ex, gi, giInfo.useGi, rootDev, fp, includeHidden):
              stack.add(StackEntry(path: fp, depth: childDepth))

            if scanEntryPathOnly(cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                                 fp, rel, kind, childDepth, contentRx, cachedIC,
                                 needInfo, includeHidden, result):
              inc result.matched
              onPath(outputPathFor(cfg, rel, fp))
              inc emitted
              if hasLimit and emitted >= cfg.limit:
                stopAt = true
                break

      except CatchableError:
        inc result.errors

  result.endTime = times.getTime()
