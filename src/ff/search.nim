# src/ff/search.nim
import std/[os, strutils, options, re]
import std/times as times
import core, cli, matchers, content, fuzzy_match

when defined(posix):
  import std/posix

when compileOption("threads"):
  import std/[locks, atomics]
  import parallel

type
  StackEntry = object
    path: string
    depth: int

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

    WorkerArgs = object
      ctx: ptr WorkerContext
      queue: WorkQueue
      results: ResultCollector
      stats: AtomicStats
      workerId: int

proc isHiddenPath(relPath: string): bool {.inline.} =
  if relPath.len == 0: return false
  if relPath[0] == '.': return true
  var i = 0
  let last = relPath.len - 1
  while i < last:
    let c = relPath[i]
    inc i
    if (c == '/' or c == '\\') and relPath[i] == '.':
      return true
  false

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

proc needsFileInfo(cfg: Config): bool {.inline.} =
  cfg.minSize >= 0 or cfg.maxSize >= 0 or
  cfg.newerThan.isSome or cfg.olderThan.isSome or
  cfg.containsText.len > 0 or cfg.containsRegex.len > 0

proc extractName(relPath: string): string {.inline.} =
  var nameStart = relPath.len - 1
  while nameStart > 0 and relPath[nameStart - 1] notin {'/', '\\'}:
    dec nameStart
  if nameStart >= 0 and nameStart < relPath.len: relPath[nameStart..^1] else: relPath

proc scanEntry(rootAbs: string; cfg: Config; matcher: Matcher;
               ex: Excluder; gi: Gitignore; useGi: bool;
               rootDev: int64; fullPath, relPath: string;
               kind: EntryType; depth: int;
               contentRx: Option[Regex]; cachedIC: bool;
               needInfo: bool; includeHidden: bool;
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

  let name = extractName(relPath)
  var fuzzyScore = -1

  if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
    let target = if matcher.pathMode == pmFullPath: relPath else: name
    var t = target
    if cachedIC:
      for i in 0..<t.len:
        let c = t[i]
        if c in {'A'..'Z'}: t[i] = chr(ord(c) + 32)

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

  var size: int64 = 0
  var mtime: times.Time

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
    name: name,
    size: size,
    mtime: mtime,
    kind: kind,
    fuzzyScore: fuzzyScore
  ))

when compileOption("threads"):
  proc scanEntryAtomic(rootAbs: string; cfg: Config; matcher: Matcher;
                       ex: Excluder; gi: Gitignore; useGi: bool;
                       rootDev: int64; fullPath, relPath: string;
                       kind: EntryType; depth: int;
                       contentRx: Option[Regex]; cachedIC: bool;
                       needInfo: bool; includeHidden: bool;
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

    if (not includeHidden) and isHiddenPath(relPath):
      stats.incSkipped()
      return none(MatchResult)

    if ex.compiled.len > 0 and ex.isExcluded(relPath):
      stats.incSkipped()
      return none(MatchResult)

    if useGi and isGitIgnored(gi, relPath):
      stats.incSkipped()
      return none(MatchResult)

    if (cfg.containsText.len > 0 or cfg.containsRegex.len > 0) and kind != etFile:
      stats.incSkipped()
      return none(MatchResult)

    let name = extractName(relPath)
    var fuzzyScore = -1

    if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
      let target = if matcher.pathMode == pmFullPath: relPath else: name
      var t = target
      if cachedIC:
        for i in 0..<t.len:
          let c = t[i]
          if c in {'A'..'Z'}: t[i] = chr(ord(c) + 32)
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

    var size: int64 = 0
    var mtime: times.Time

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
      name: name,
      size: size,
      mtime: mtime,
      kind: kind,
      fuzzyScore: fuzzyScore
    ))

  proc workerProc(args: WorkerArgs) {.thread, gcsafe.} =
    let ctx = args.ctx
    var localMatches: seq[MatchResult] = @[]
    var childDirs: seq[DirEntry] = @[]
    var idleSpins = 0
    var relBuf = initPathBuffer(512)

    var gi: Gitignore
    if ctx.useGi:
      gi.ignoreCase = true
      gi.compileGitignore(ctx.giLines)

    while true:
      if args.queue.isShutdown() or args.results.isLimitReached():
        break

      let batch = args.queue.tryPopBatch(4)

      if batch.len == 0:
        inc idleSpins
        if args.queue.isComplete():
          break
        if idleSpins > 1000:
          sleep(1)
          idleSpins = 0
        continue

      idleSpins = 0
      args.queue.markWorkerActive()

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

            if kind == etDir and shouldTraverseDir(ctx.cfg, relPath, childDepth,
                                   ctx.ex, gi, ctx.useGi,
                                   ctx.rootDev, fullPath, ctx.includeHidden):
              childDirs.add(DirEntry(path: fullPath, relPath: relPath, depth: childDepth))

            let om = scanEntryAtomic(
              ctx.rootAbs, ctx.cfg, ctx.matcher,
              ctx.ex, gi, ctx.useGi, ctx.rootDev,
              fullPath, relPath, kind, childDepth,
              ctx.contentRx, ctx.cachedIC,
              ctx.needInfo, ctx.includeHidden,
              args.stats
            )

            if om.isSome:
              args.stats.incMatched()
              localMatches.add(om.get)

        except CatchableError:
          args.stats.incErrors()

        if childDirs.len > 0:
          args.queue.pushBatch(childDirs)
        args.queue.decPending()

      args.queue.markWorkerIdle()

      if localMatches.len >= 32:
        discard args.results.addMatches(localMatches)
        localMatches.setLen(0)

    if localMatches.len > 0:
      discard args.results.addMatches(localMatches)

  proc runParallelSearch(cfg: Config; rootAbs: string; globalStart: times.Time): SearchResult =
    result.stats.startTime = globalStart

    let numWorkers = max(1, min(cfg.threads, 32))
    let cachedIC = effectiveIgnoreCase(cfg)
    let matcher = buildMatcher(cfg)
    let ex = buildExcluder(cfg)
    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
    let contentRx = compileContentRegex(cfg, cachedIC)
    let needInfo = needsFileInfo(cfg)
    let includeHidden = cfg.includeHidden

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
      includeHidden: includeHidden
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
                     needInfo: bool; includeHidden: bool;
                     stats: var Stats; matches: var seq[MatchResult];
                     stopAt: var bool) =
  var stack = newSeqOfCap[StackEntry](64)
  stack.add(StackEntry(path: startDir, depth: 0))
  let limit = cfg.limit
  let hasLimit = limit > 0

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

        let rel = safeRelPath(p, rootAbs)

        if kind == etDir and shouldTraverseDir(cfg, rel, childDepth, ex, gi, useGi, rootDev, p, includeHidden):
          stack.add(StackEntry(path: p, depth: childDepth))

        let om = scanEntry(rootAbs, cfg, matcher, ex, gi, useGi, rootDev,
                           p, rel, kind, childDepth, contentRx, cachedIC,
                           needInfo, includeHidden, stats)
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
    if cfg.threads > 1:
      return runParallelSearch(cfg, rootAbs, globalStart)

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let giInfo = buildGitignoreLines(cfg, rootAbs)
  let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
  let contentRx = compileContentRegex(cfg, cachedIC)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden

  var gi: Gitignore
  if giInfo.useGi:
    gi.ignoreCase = true
    gi.compileGitignore(giInfo.lines)

  var stopAt = false
  scanTreeCollect(rootAbs, rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                  contentRx, cachedIC, needInfo, includeHidden,
                  result.stats, result.matches, stopAt)

  result.stats.endTime = times.getTime()

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

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let contentRx = compileContentRegex(cfg, cachedIC)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden
  let hasLimit = cfg.limit > 0

  for p in cfg.paths:
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

          let rel = safeRelPath(fp, rootAbs)

          if kind == etDir and shouldTraverseDir(cfg, rel, childDepth, ex, gi, giInfo.useGi, rootDev, fp, includeHidden):
            stack.add(StackEntry(path: fp, depth: childDepth))

          let om = scanEntry(rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                             fp, rel, kind, childDepth, contentRx, cachedIC,
                             needInfo, includeHidden, result)
          if om.isSome:
            inc result.matched
            onMatch(om.get)
            if hasLimit and result.matched >= cfg.limit:
              stopAt = true
              break

      except CatchableError:
        inc result.errors

  result.endTime = times.getTime()
