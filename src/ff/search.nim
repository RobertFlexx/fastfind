# src/ff/search.nim

import std/[os, strutils, options, re, times, sets, atomics]
import core, cli, matchers, content, fuzzy_match, ansi

when defined(posix):
  import std/posix

when compileOption("threads"):
  import std/[cpuinfo, locks]
  import parallel

type
  SearchControl* = ptr SearchControlObj
  SearchControlObj = object
    cancelled: Atomic[bool]

  StackEntry = object
    path: string
    depth: int
    gi: Gitignore

  FileIdentity = tuple[device: uint64, inode: uint64]

  SimplePatternKind = enum
    spkExact, spkPrefix, spkSuffix, spkContains, spkUniversal

  PathBatchCallback* = proc(data: string) {.closure, gcsafe.}

const PathBatchSize = 64 * 1024

when compileOption("threads"):
  type
    WorkerContext = object
      rootAbs: string
      control: SearchControl
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
      hasExcludes: bool
      oneFileSystem: bool
      onBatch: PathBatchCallback
      outputLock: ptr Lock
      sanitize: bool

    WorkerArgs = object
      ctx: ptr WorkerContext
      queue: WorkQueue
      results: ResultCollector
      stats: AtomicStats
      lifetime: ptr WorkerLifetime

    WorkerLifetime = object
      lock: Lock
      changed: Cond
      finished: int
      released: bool

proc newSearchControl*(): SearchControl =
  cast[SearchControl](allocShared0(sizeof(SearchControlObj)))

proc cancel*(control: SearchControl) =
  if control != nil: control.cancelled.store(true)

proc isCancelled(control: SearchControl): bool {.inline.} =
  control != nil and control.cancelled.load()

proc destroy*(control: SearchControl) =
  if control != nil: deallocShared(control)

proc effectiveThreadCount(cfg: Config): int {.inline.} =
  when compileOption("threads"):
    # Following links needs one shared visited set to catch cycles, so keep
    # this less-common path in a single traversal.
    if cfg.followSymlinks or cfg.useGitignore: return 1
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

proc effectiveContentIgnoreCase(cfg: Config): bool =
  if cfg.ignoreCase: return true
  if not cfg.smartCase: return false
  let pattern = if cfg.containsRegex.len > 0: cfg.containsRegex else: cfg.containsText
  not containsUpper(pattern)

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
    let excl = repoRoot / ".git" / "info" / "exclude"
    if fileExists(excl):
      try: result.add(readFile(excl).splitLines())
      except CatchableError: discard
    let gi = repoRoot / ".gitignore"
    if fileExists(gi):
      try: result.add(readFile(gi).splitLines())
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

proc getDirectoryIdentity(path: string): Option[FileIdentity] {.inline.} =
  when defined(posix):
    var st: Stat
    if posix.stat(path.cstring, st) == 0 and S_ISDIR(st.st_mode):
      return some((uint64(st.st_dev), uint64(st.st_ino)))
  none(FileIdentity)

proc isRegularFile(path: string): bool {.inline.} =
  when defined(posix):
    var st: Stat
    if posix.lstat(path.cstring, st) == 0:
      return S_ISREG(st.st_mode)
    false
  else:
    true

proc needsRegularFileCheck(cfg: Config; kind: EntryType): bool {.inline.} =
  kind == etFile and etFile in cfg.types and cfg.types != {etFile, etDir, etLink}

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
    result.lines = loadGitignoreLines(if repo.len > 0: repo else: rootAbs)

proc gitignoreRoot(rootAbs: string): string =
  result = findGitRepoRoot(rootAbs)
  if result.len == 0: result = rootAbs

proc extendGitignoreForDir(parent: Gitignore; directory: string): Gitignore =
  result = parent
  if parent.root.len == 0 or directory == parent.root: return
  let ignoreFile = directory / ".gitignore"
  if not fileExists(ignoreFile): return
  try:
    let scope = relativePath(directory, parent.root)
    result = derivedGitignore(parent, readFile(ignoreFile).splitLines(), scope)
  except CatchableError:
    discard

proc includeAncestorGitignores(base: Gitignore; searchRoot: string): Gitignore =
  ## When a search starts inside a repo, collect the ignore files between the
  ## repo root and the requested directory in the same order Git sees them.
  result = base
  if base.root.len == 0 or searchRoot == base.root: return
  var chain: seq[string] = @[]
  var directory = parentDir(searchRoot)
  while directory.len > base.root.len and directory.startsWith(base.root & DirSep):
    chain.add(directory)
    let parent = parentDir(directory)
    if parent == directory: break
    directory = parent
  if chain.len > 0:
    for i in countdown(chain.len - 1, 0):
      result = extendGitignoreForDir(result, chain[i])

proc compileContentRegex(cfg: Config): Option[Regex] =
  if cfg.containsRegex.len == 0: return none(Regex)
  let flags = if effectiveContentIgnoreCase(cfg): {reIgnoreCase} else: {}
  try: some(re(cfg.containsRegex, flags))
  except CatchableError: none(Regex)

proc shouldTraverseDir(cfg: Config; relPath: string; depth: int;
                       ex: Excluder; gi: Gitignore; useGi: bool;
                       rootDev: int64; fullPath: string;
                       includeHidden: bool): bool {.inline.} =
  if (not includeHidden) and isHiddenPath(relPath): return false
  if cfg.maxDepth >= 0 and depth >= cfg.maxDepth: return false
  if ex.compiled.len > 0 and ex.isExcluded(relPath): return false
  if useGi and isGitIgnored(gi, fullPath): return false
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
  if useGi and isGitIgnored(gi, fullPath): return false
  if oneFileSystem and rootDev >= 0:
    let dev = getDeviceId(fullPath)
    if dev >= 0 and dev != rootDev: return false
  true

proc shouldFollowLinkDir(cfg: Config; fullPath: string): bool {.inline.} =
  cfg.followSymlinks and dirExists(fullPath)

proc needsFileInfo(cfg: Config): bool {.inline.} =
  cfg.minSize >= 0 or cfg.maxSize >= 0 or
  cfg.newerThan.isSome or cfg.olderThan.isSome or
  cfg.hasContentFilter or
  cfg.outputMode in {omLong, omJson, omNdJson, omTable} or
  cfg.sortKey in {skSize, skTime} or cfg.rankRecency or
  cfg.rankMode in {rmRecency, rmAuto}

proc needsResultName(cfg: Config): bool {.inline.} =
  cfg.sortKey == skName or
  cfg.outputMode in {omLong, omJson, omNdJson, omTable}

proc extractName(relPath: string): string {.inline.} =
  let sepIdx = rfind(relPath, {'/', '\\'})
  if sepIdx >= 0 and sepIdx + 1 < relPath.len: relPath[sepIdx + 1..^1]
  elif relPath.len > 0: relPath
  else: ""

proc passesExtensions(cfg: Config; relPath: string): bool {.inline.} =
  if cfg.extensions.len == 0: return true
  let lower = relPath.toLowerAscii()
  for ext in cfg.extensions:
    let wanted = ext.toLowerAscii()
    if wanted.startsWith("."):
      if lower.endsWith(wanted): return true
    elif extractName(lower) == wanted:
      return true
  false

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

  if useGi and isGitIgnored(gi, fullPath):
    inc stats.skipped
    return none(MatchResult)

  if cfg.hasContentFilter and kind != etFile:
    inc stats.skipped
    return none(MatchResult)

  var name = ""
  template ensureName() =
    if name.len == 0:
      name = extractName(relPath)
  var fuzzyScore = -1

  if not passesExtensions(cfg, relPath):
    inc stats.skipped
    return none(MatchResult)

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

  if needsRegularFileCheck(cfg, kind) and not isRegularFile(fullPath):
    inc stats.skipped
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
      let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes,
        cfg.allowBinary, br, size, effectiveContentIgnoreCase(cfg))
      stats.bytesRead += br
      if not ok: return none(MatchResult)

    if cfg.containsRegex.len > 0:
      if contentRx.isNone: return none(MatchResult)
      var br: int64 = 0
      let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br, size)
      stats.bytesRead += br
      if not ok: return none(MatchResult)

    for text in cfg.notContainsText:
      var br: int64 = 0
      var validFile = false
      let excluded = fileContainsText(fullPath, text, cfg.maxBytes,
        cfg.allowBinary, br, effectiveContentIgnoreCase(cfg), addr validFile)
      stats.bytesRead += br
      if excluded or not validFile: return none(MatchResult)

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

  if useGi and isGitIgnored(gi, fullPath):
    inc stats.skipped
    return false

  if cfg.hasContentFilter and kind != etFile:
    inc stats.skipped
    return false

  if not passesExtensions(cfg, relPath):
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

  if needsRegularFileCheck(cfg, kind) and not isRegularFile(fullPath):
    inc stats.skipped
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
      let ok = fileContainsTextSmart(fullPath, cfg.containsText, cfg.maxBytes,
        cfg.allowBinary, br, info.size, effectiveContentIgnoreCase(cfg))
      stats.bytesRead += br
      if not ok: return false

    if cfg.containsRegex.len > 0:
      if contentRx.isNone: return false
      var br: int64 = 0
      let ok = fileContainsRegexSmart(fullPath, contentRx.get, cfg.maxBytes, cfg.allowBinary, br, info.size)
      stats.bytesRead += br
      if not ok: return false

    for text in cfg.notContainsText:
      var br: int64 = 0
      var validFile = false
      let excluded = fileContainsText(fullPath, text, cfg.maxBytes,
        cfg.allowBinary, br, effectiveContentIgnoreCase(cfg), addr validFile)
      stats.bytesRead += br
      if excluded or not validFile: return false

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
  (not cfg.useGitignore) and
  cfg.excludes.len == 0 and
  cfg.minDepth == 0 and
  cfg.maxDepth < 0 and
  cfg.minSize < 0 and cfg.maxSize < 0 and
  cfg.newerThan.isNone and cfg.olderThan.isNone and
  not cfg.hasContentFilter and
  cfg.extensions.len == 0

when defined(posix):
  # Solaris/illumos have DT_* declarations in some Nim versions, but no
  # d_type member in struct dirent. Check the field as well as the constants.
  # The override also lets native CI exercise the lstat-only traversal.
  const HasDirentType = not defined(fastfindNoDType) and
    compiles(default(Dirent).d_type) and
    declared(DT_DIR) and declared(DT_REG) and declared(DT_LNK) and
    declared(DT_UNKNOWN)

  type
    PosixStackEntry = object
      absPath: string
      relPath: string

  proc direntNameLen(name: cstring): int {.inline.} =
    while name[result] != '\0':
      inc result

  proc appendDirentName(buf: var string; name: cstring; nameLen: int) {.inline.} =
    let oldLen = buf.len
    buf.setLen(oldLen + nameLen)
    if nameLen > 0:
      copyMem(addr buf[oldLen], name, nameLen)

  proc setJoinedPath(buf: var string; parent: string;
                     name: cstring; nameLen: int) {.inline.} =
    buf.setLen(0)
    buf.add(parent)
    if parent.len > 0 and parent[^1] != '/':
      buf.add('/')
    buf.appendDirentName(name, nameLen)

  proc appendOutputPath(buf: var string; directory: string; rootPrefixLen: int;
                        name: cstring; nameLen: int; absolute: bool;
                        terminator: char; sanitize: bool) {.inline.} =
    let start = buf.len
    if absolute:
      buf.add(directory)
      if directory.len > 0 and directory[^1] != '/': buf.add('/')
    elif directory.len > rootPrefixLen:
      let oldLen = buf.len
      let prefixLen = directory.len - rootPrefixLen
      buf.setLen(oldLen + prefixLen)
      copyMem(addr buf[oldLen], unsafeAddr directory[rootPrefixLen], prefixLen)
      buf.add('/')
    buf.appendDirentName(name, nameLen)
    if sanitize:
      let safe = sanitizeTerminalText(buf[start..^1])
      buf.setLen(start)
      buf.add(safe)
    buf.add(terminator)

  proc direntKind(d: ptr Dirent; parentAbs: string;
                  name: cstring; nameLen: int): EntryType =
    when HasDirentType:
      if d.d_type == DT_DIR: return etDir
      if d.d_type == DT_REG: return etFile
      if d.d_type == DT_LNK: return etLink
    var fullPath = newStringOfCap(parentAbs.len + nameLen + 1)
    fullPath.setJoinedPath(parentAbs, name, nameLen)
    var st: Stat
    if lstat(fullPath.cstring, st) == 0:
      if S_ISDIR(st.st_mode): return etDir
      if S_ISLNK(st.st_mode): return etLink
    etFile

  proc direntIsRegular(d: ptr Dirent; parentAbs: string;
                       name: cstring; nameLen: int): bool =
    when HasDirentType:
      if d.d_type == DT_REG: return true
      if d.d_type != DT_UNKNOWN: return false
    var fullPath = newStringOfCap(parentAbs.len + nameLen + 1)
    fullPath.setJoinedPath(parentAbs, name, nameLen)
    isRegularFile(fullPath)

  proc matchSimpleName(name: cstring; nameLen: int;
                       kind: SimplePatternKind; core: string;
                       ignoreCase: bool): bool {.inline.} =
    template equalAt(nameIdx, coreIdx: int): bool =
      (if ignoreCase:
        var c = name[nameIdx]
        if c in {'A'..'Z'}: c = chr(ord(c) + 32)
        c == core[coreIdx]
      else:
        name[nameIdx] == core[coreIdx])

    case kind
    of spkUniversal:
      true
    of spkExact:
      if core.len != nameLen: return false
      for i in 0..<core.len:
        if not equalAt(i, i): return false
      true
    of spkPrefix:
      if core.len > nameLen: return false
      for i in 0..<core.len:
        if not equalAt(i, i): return false
      true
    of spkSuffix:
      if core.len > nameLen: return false
      let start = nameLen - core.len
      for i in 0..<core.len:
        if not equalAt(start + i, i): return false
      true
    of spkContains:
      if core.len == 0: return true
      if core.len > nameLen: return false
      let last = nameLen - core.len
      var start = 0
      while start <= last:
        var matches = true
        for i in 0..<core.len:
          if not equalAt(start + i, i):
            matches = false
            break
        if matches: return true
        inc start
      false

  proc runCountAllPosix(cfg: Config; rootAbs: string;
                        emitted: var int): Stats =
    ## Universal count is common in scripts and benchmarks. It needs neither
    ## relative paths nor filenames for ordinary files, so keep it separate
    ## from the output-oriented walker and allocate only for child directories.
    var stack = newSeqOfCap[string](64)
    stack.add(rootAbs)
    var childPath = newStringOfCap(512)
    let wantHidden = cfg.includeHidden
    let hasLimit = cfg.limit > 0
    let oneFileSystem = cfg.oneFileSystem
    let rootDev = if oneFileSystem: getDeviceId(rootAbs) else: -1

    while stack.len > 0:
      if hasLimit and emitted >= cfg.limit: break
      let currentPath = stack.pop()
      inc result.visitedDirs
      inc result.visited

      let dirp = opendir(currentPath.cstring)
      if dirp.isNil:
        inc result.errors
        continue

      while true:
        if hasLimit and emitted >= cfg.limit: break
        let dent = readdir(dirp)
        if dent.isNil: break
        let name = cast[cstring](addr dent.d_name[0])
        if name[0] == '.':
          if name[1] == '\0' or (name[1] == '.' and name[2] == '\0'):
            continue
          if not wantHidden:
            inc result.skipped
            continue

        var nameLen = -1
        template getNameLen(): int =
          if nameLen < 0: nameLen = direntNameLen(name)
          nameLen

        let kindVal = when HasDirentType:
          if dent.d_type == DT_DIR: etDir
          elif dent.d_type == DT_REG: etFile
          elif dent.d_type == DT_LNK: etLink
          else: direntKind(dent, currentPath, name, getNameLen())
        else:
          direntKind(dent, currentPath, name, getNameLen())

        inc result.visited
        case kindVal
        of etFile: inc result.visitedFiles
        of etLink: inc result.visitedLinks
        of etDir:
          childPath.setJoinedPath(currentPath, name, getNameLen())
          if oneFileSystem and rootDev >= 0:
            let dev = getDeviceId(childPath)
            if dev < 0 or dev != rootDev: continue
          stack.add(childPath)

        inc result.matched
        inc emitted
      discard closedir(dirp)

  when compileOption("threads"):
    type
      CountWorkerContext = object
        includeHidden: bool
        oneFileSystem: bool
        rootDev: int64
        patternKind: SimplePatternKind
        pattern: string
        ignoreCase: bool
        types: set[EntryType]
        defaultTypes: bool
        onBatch: PathBatchCallback
        outputLock: ptr Lock
        rootPrefixLen: int
        absolute: bool
        terminator: char
        sanitize: bool

      CountWorkerArgs = object
        ctx: ptr CountWorkerContext
        queue: WorkQueue
        lifetime: ptr WorkerLifetime
        stats: AtomicStats

    proc scanCountDirectory(ctx: ptr CountWorkerContext; directory: string;
                            childDirs: var seq[string]; childPath: var string;
                            outputBuf: var string; stats: var Stats) {.gcsafe.} =
      childDirs.setLen(0)
      inc stats.visitedDirs
      inc stats.visited
      let dirp = opendir(directory.cstring)
      if dirp.isNil:
        inc stats.errors
        return

      while true:
        let dent = readdir(dirp)
        if dent.isNil: break
        let name = cast[cstring](addr dent.d_name[0])
        if name[0] == '.':
          if name[1] == '\0' or (name[1] == '.' and name[2] == '\0'):
            continue
          if not ctx.includeHidden:
            inc stats.skipped
            continue

        var nameLen = -1
        template getNameLen(): int =
          if nameLen < 0: nameLen = direntNameLen(name)
          nameLen

        let kindVal = when HasDirentType:
          if dent.d_type == DT_DIR: etDir
          elif dent.d_type == DT_REG: etFile
          elif dent.d_type == DT_LNK: etLink
          else: direntKind(dent, directory, name, getNameLen())
        else:
          direntKind(dent, directory, name, getNameLen())

        inc stats.visited
        case kindVal
        of etFile: inc stats.visitedFiles
        of etLink: inc stats.visitedLinks
        of etDir:
          childPath.setJoinedPath(directory, name, getNameLen())
          if ctx.oneFileSystem and ctx.rootDev >= 0:
            let dev = getDeviceId(childPath)
            if dev < 0 or dev != ctx.rootDev: continue
          childDirs.add(childPath)

        if ctx.patternKind != spkUniversal and
            not matchSimpleName(name, getNameLen(), ctx.patternKind,
                                ctx.pattern, ctx.ignoreCase):
          continue
        if ctx.defaultTypes or kindVal in ctx.types:
          let requireRegular = kindVal == etFile and etFile in ctx.types and
            not ctx.defaultTypes
          if requireRegular and
              not direntIsRegular(dent, directory, name, getNameLen()):
            inc stats.skipped
            continue
          inc stats.matched
          if ctx.onBatch != nil:
            outputBuf.appendOutputPath(directory, ctx.rootPrefixLen, name,
              getNameLen(), ctx.absolute, ctx.terminator, ctx.sanitize)
            if outputBuf.len >= PathBatchSize:
              acquire(ctx.outputLock[])
              try: ctx.onBatch(outputBuf)
              finally: release(ctx.outputLock[])
              outputBuf.setLen(0)

      discard closedir(dirp)

    proc scanSimpleWorker(args: CountWorkerArgs) {.gcsafe.} =
      let ctx = args.ctx
      var localStats: Stats
      var stack = newSeqOfCap[string](64)
      var childDirs = newSeqOfCap[string](64)
      var tasks = newSeqOfCap[DirEntry](64)
      var childPath = newStringOfCap(512)
      var outputBuf = newStringOfCap(PathBatchSize + 512)
      var entry: DirEntry
      while args.queue.waitPop(entry):
        stack.add(move entry.path)
        while stack.len > 0:
          let directory = stack.pop()
          scanCountDirectory(ctx, directory, childDirs, childPath, outputBuf, localStats)
          for child in childDirs.mitems: stack.add(move child)
          # Stay allocation-local while workers are busy. Donate sibling
          # subtrees when a worker becomes idle, including fan-out discovered
          # far below an initially narrow root.
          if stack.len > 1 and args.queue.hasWaitingWorkers():
            let donate = min(64, stack.len - 1)
            for _ in 0..<donate: tasks.add(DirEntry(path: stack.pop()))
            args.queue.pushBatch(tasks)
        args.queue.decPending()
      if outputBuf.len > 0:
        acquire(ctx.outputLock[])
        try: ctx.onBatch(outputBuf)
        finally: release(ctx.outputLock[])
      args.stats.addStats(localStats)

    proc countSimpleWorker(args: CountWorkerArgs) {.thread, gcsafe.} =
      scanSimpleWorker(args)
      let lifetime = args.lifetime
      acquire(lifetime.lock)
      inc lifetime.finished
      broadcast(lifetime.changed)
      while not lifetime.released: wait(lifetime.changed, lifetime.lock)
      release(lifetime.lock)

    proc countThreadCount(cfg: Config; rootAbs: string): int =
      if cfg.threads > 0:
        return effectiveThreadCount(cfg)

      # Probe work in the caller before creating threads. This also works on
      # filesystems whose directory link counts do not encode fan-out.
      max(1, min(countProcessors(), 8))

    proc runCountSimpleParallelPosix(cfg: Config; rootAbs: string;
                                     kind: SimplePatternKind; core: string;
                                     ignoreCase: bool; workerCount: int;
                                     emitted: var int;
                                     onBatch: PathBatchCallback = nil;
                                     sanitize: bool = false): Stats =
      var outputLock: Lock
      initLock(outputLock)
      defer: deinitLock(outputLock)
      var ctx = CountWorkerContext(
        includeHidden: cfg.includeHidden,
        oneFileSystem: cfg.oneFileSystem,
        rootDev: if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1,
        patternKind: kind,
        pattern: core,
        ignoreCase: ignoreCase,
        types: cfg.types,
        defaultTypes: cfg.types == {etFile, etDir, etLink},
        onBatch: onBatch,
        outputLock: addr outputLock,
        rootPrefixLen: rootAbs.len + (if rootAbs[^1] == '/': 0 else: 1),
        absolute: cfg.absolute,
        terminator: if cfg.print0: '\0' else: '\n',
        sanitize: sanitize
      )
      var roots = newSeqOfCap[string](workerCount * 4)
      var children = newSeqOfCap[string](64)
      var childPath = newStringOfCap(512)
      var outputBuf = newStringOfCap(PathBatchSize + 512)
      scanCountDirectory(addr ctx, rootAbs, roots, childPath, outputBuf, result)

      # Never partition the whole tree in advance. Directory link counts do
      # not reliably reflect fan-out (notably on btrfs and virtual filesystems),
      # and a large tree under one initial child must remain shareable.
      if cfg.threads == 0:
        while roots.len > 0 and result.visited < 2048:
          let directory = roots.pop()
          scanCountDirectory(addr ctx, directory, children, childPath, outputBuf, result)
          for child in children.mitems: roots.add(move child)
      if outputBuf.len > 0:
        onBatch(outputBuf)
        outputBuf.setLen(0)

      if roots.len == 0:
        emitted += result.matched
        return

      let stats = newAtomicStats()
      stats.addStats(result)
      let queue = newWorkQueue()
      var initialTasks = newSeqOfCap[DirEntry](roots.len)
      for root in roots.mitems: initialTasks.add(DirEntry(path: move root))
      queue.pushBatch(initialTasks)
      var lifetime: WorkerLifetime
      initLock(lifetime.lock)
      initCond(lifetime.changed)
      defer:
        deinitCond(lifetime.changed)
        deinitLock(lifetime.lock)
      let activeWorkers = workerCount
      let args = CountWorkerArgs(ctx: addr ctx, queue: queue,
        lifetime: addr lifetime, stats: stats)
      var threads = newSeq[Thread[CountWorkerArgs]](activeWorkers)
      for i in 0..<activeWorkers:
        createThread(threads[i], countSimpleWorker, args)
      acquire(lifetime.lock)
      while lifetime.finished < activeWorkers: wait(lifetime.changed, lifetime.lock)
      release(lifetime.lock)

      result = stats.toStats(times.fromUnix(0), times.fromUnix(0))
      emitted += result.matched
      # Queue storage may belong to any producing worker's allocator. Reclaim
      # it while all worker heaps are still held alive at the lifetime barrier.
      queue.destroy()
      stats.destroy()
      acquire(lifetime.lock)
      lifetime.released = true
      broadcast(lifetime.changed)
      release(lifetime.lock)
      for thread in threads.mitems: joinThread(thread)

  proc runSearchStreamPathsSimplePosix(cfg: Config; rootAbs: string;
                                       kind: SimplePatternKind; coreCmp: string;
                                       ignoreCase: bool; emitted: var int;
                                       onPath: proc(p: string);
                                       onBatch: PathBatchCallback;
                                       sanitize: bool): Stats =
    let defaultTypes = cfg.types == {etFile, etDir, etLink}
    when compileOption("threads"):
      if cfg.limit == 0 and (cfg.countOnly or onBatch != nil):
        let workerCount = countThreadCount(cfg, rootAbs)
        if workerCount > 1:
          return runCountSimpleParallelPosix(cfg, rootAbs, kind, coreCmp,
            ignoreCase, workerCount, emitted,
            if cfg.countOnly: nil else: onBatch, sanitize)
    if cfg.countOnly:
      if kind == spkUniversal and defaultTypes:
        return runCountAllPosix(cfg, rootAbs, emitted)

    var stack = newSeqOfCap[PosixStackEntry](64)
    stack.add(PosixStackEntry(absPath: rootAbs, relPath: ""))
    let hasLimit = cfg.limit > 0
    var pathBuf = newStringOfCap(512)
    var absBuf = newStringOfCap(512)
    var outputBuf = newStringOfCap(PathBatchSize + 512)
    let rootPrefixLen = rootAbs.len + (if rootAbs[^1] == '/': 0 else: 1)
    
    let wantAbsolute = cfg.absolute
    let wantHidden = cfg.includeHidden
    let oneFileSystem = cfg.oneFileSystem
    let rootDev = if oneFileSystem: getDeviceId(rootAbs) else: -1

    proc sameFileSystemDir(fullPath: string): bool =
      if oneFileSystem and rootDev >= 0:
        let dev = getDeviceId(fullPath)
        return dev >= 0 and dev == rootDev
      true
    
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

      while true:
        if hasLimit and emitted >= cfg.limit:
          break
        let dent = readdir(dirp)
        if dent.isNil: break
        let name = cast[cstring](addr dent.d_name[0])
        if name[0] == '.':
          if name[1] == '\0' or (name[1] == '.' and name[2] == '\0'):
            continue
          if not wantHidden:
            inc result.skipped
            continue

        var nameLen = -1
        template getNameLen(): int =
          if nameLen < 0: nameLen = direntNameLen(name)
          nameLen

        let kindVal = when HasDirentType:
          if dent.d_type == DT_DIR: etDir
          elif dent.d_type == DT_REG: etFile
          elif dent.d_type == DT_LNK: etLink
          else: direntKind(dent, currentAbsPath, name, getNameLen())
        else:
          direntKind(dent, currentAbsPath, name, getNameLen())

        inc result.visited
        case kindVal
        of etFile: inc result.visitedFiles
        of etLink: inc result.visitedLinks
        of etDir: discard

        # The simple path mode never follows links, so only real directories
        # need persistent paths. Ordinary files remain allocation-free when
        # counting or when their name does not match.
        if kindVal == etDir:
          absBuf.setJoinedPath(currentAbsPath, name, getNameLen())
          if not sameFileSystemDir(absBuf):
            continue
          pathBuf.setLen(0)
          if currentRelEmpty:
            pathBuf.appendDirentName(name, getNameLen())
          else:
            pathBuf.add(currentRelPath)
            pathBuf.add('/')
            pathBuf.appendDirentName(name, getNameLen())
          stack.add(PosixStackEntry(absPath: absBuf, relPath: pathBuf))

        if kind != spkUniversal and
            not matchSimpleName(name, getNameLen(), kind, coreCmp, ignoreCase):
          continue

        if defaultTypes or (kindVal in cfg.types):
          if needsRegularFileCheck(cfg, kindVal) and
              not direntIsRegular(dent, currentAbsPath, name, getNameLen()):
            inc result.skipped
            continue
          inc result.matched
          if cfg.countOnly:
            discard
          elif onBatch != nil:
            outputBuf.appendOutputPath(currentAbsPath, rootPrefixLen, name,
              getNameLen(), wantAbsolute, if cfg.print0: '\0' else: '\n', sanitize)
            if outputBuf.len >= PathBatchSize:
              onBatch(outputBuf)
              outputBuf.setLen(0)
          elif wantAbsolute:
            if kindVal != etDir:
              absBuf.setJoinedPath(currentAbsPath, name, getNameLen())
            onPath(absBuf)
          else:
            pathBuf.setLen(0)
            if not currentRelEmpty:
              pathBuf.add(currentRelPath)
              pathBuf.add('/')
            pathBuf.appendDirentName(name, getNameLen())
            onPath(pathBuf)
          inc emitted

    if outputBuf.len > 0: onBatch(outputBuf)

when compileOption("threads"):
  proc scanWorker(args: WorkerArgs) {.gcsafe.} =
    let ctx = args.ctx
    var localMatches = newSeqOfCap[MatchResult](128)
    var childDirs = newSeqOfCap[DirEntry](128)
    var relBuf = initPathBuffer(512)
    var spinCount = 0
    var outputBuf = newStringOfCap(PathBatchSize + 512)
    var localStats: Stats

    var gi: Gitignore
    if ctx.useGi:
      gi.ignoreCase = defined(windows)
      gi.compileGitignore(ctx.giLines)

    while true:
      if ctx.control.isCancelled() or args.queue.isShutdown() or args.results.isLimitReached():
        break

      # Grab a few directories at a time so the other workers still get work.
      var batch = args.queue.tryPopBatch(16)
      
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
        inc localStats.visitedDirs
        inc localStats.visited

        try:
          for pc, fullPath in walkDir(entry.path, relative = false):
            if ctx.control.isCancelled() or args.results.isLimitReached():
              break

            let kind = entryTypeFromWalk(pc)
            let childDepth = entry.depth + 1

            inc localStats.visited
            case kind
            of etFile: inc localStats.visitedFiles
            of etLink: inc localStats.visitedLinks
            of etDir: discard

            computeRelPathInPlace(fullPath, ctx.rootAbs, relBuf)
            let relPath = relBuf.toString()

            if (kind == etDir or (kind == etLink and shouldFollowLinkDir(ctx.cfg, fullPath))) and
                shouldTraverseDirFast(ctx.cfg, relPath, childDepth,
                                   ctx.ex, gi, ctx.useGi,
                                   ctx.rootDev, fullPath, ctx.includeHidden,
                                   ctx.hasExcludes, ctx.oneFileSystem):
              childDirs.add(DirEntry(path: fullPath, depth: childDepth))

            let om = scanEntry(
              ctx.rootAbs, ctx.cfg, ctx.matcher,
              ctx.ex, gi, ctx.useGi, ctx.rootDev,
              fullPath, relPath, kind, childDepth,
              ctx.contentRx, ctx.cachedIC,
              ctx.needInfo, ctx.includeHidden, ctx.needResultName,
              localStats
            )

            if om.isSome:
              if ctx.cfg.countOnly:
                if ctx.cfg.limit == 0 or args.results.countMatch():
                  inc localStats.matched
              elif ctx.onBatch != nil:
                let m = om.get
                let path = if ctx.cfg.absolute: m.absPath else: m.relPath
                outputBuf.add(if ctx.sanitize: sanitizeTerminalText(path) else: path)
                outputBuf.add(if ctx.cfg.print0: '\0' else: '\n')
                if outputBuf.len >= PathBatchSize:
                  acquire(ctx.outputLock[])
                  try: ctx.onBatch(outputBuf)
                  finally: release(ctx.outputLock[])
                  outputBuf.setLen(0)
                inc localStats.matched
              elif ctx.cfg.limit > 0:
                if not args.results.addMatch(om.get):
                  args.queue.signalShutdown()
                  break
                inc localStats.matched
              else:
                inc localStats.matched
                localMatches.add(om.get)

        except CatchableError:
          inc localStats.errors

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
    if outputBuf.len > 0:
      acquire(ctx.outputLock[])
      try: ctx.onBatch(outputBuf)
      finally: release(ctx.outputLock[])
    args.stats.addStats(localStats)

  proc workerProc(args: WorkerArgs) {.thread, gcsafe.} =
    scanWorker(args)
    # Queued sequences and collected results can be allocated by any worker.
    # Keep their heaps alive until the caller has copied/reclaimed that data.
    let lifetime = args.lifetime
    acquire(lifetime.lock)
    inc lifetime.finished
    broadcast(lifetime.changed)
    while not lifetime.released: wait(lifetime.changed, lifetime.lock)
    release(lifetime.lock)

  proc runParallelSearch(cfg: Config; rootAbs: string; globalStart: times.Time;
                         control: SearchControl;
                         onBatch: PathBatchCallback = nil;
                         sanitize: bool = false): SearchResult =
    result.stats.startTime = globalStart

    let numWorkers = effectiveThreadCount(cfg)
    let cachedIC = effectiveIgnoreCase(cfg)
    let matcher = buildMatcher(cfg)
    let ex = buildExcluder(cfg)
    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
    let contentRx = compileContentRegex(cfg)
    let needInfo = needsFileInfo(cfg)
    let includeHidden = cfg.includeHidden
    let needResultName = needsResultName(cfg)

    var outputLock: Lock
    initLock(outputLock)
    defer: deinitLock(outputLock)
    var ctx = WorkerContext(
      rootAbs: rootAbs,
      control: control,
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
      hasExcludes: cfg.excludes.len > 0,
      oneFileSystem: cfg.oneFileSystem,
      onBatch: onBatch,
      outputLock: addr outputLock,
      sanitize: sanitize
    )

    let queue = newWorkQueue()
    let results = newResultCollector(cfg.limit)
    let stats = newAtomicStats()

    queue.push(DirEntry(path: rootAbs, depth: 0))

    var lifetime: WorkerLifetime
    initLock(lifetime.lock)
    initCond(lifetime.changed)
    defer:
      deinitCond(lifetime.changed)
      deinitLock(lifetime.lock)
    var threads = newSeq[Thread[WorkerArgs]](if numWorkers > 1: numWorkers else: 0)

    if numWorkers == 1:
      var args = WorkerArgs(
        ctx: addr ctx,
        queue: queue,
        results: results,
        stats: stats
      )
      scanWorker(args)
    else:
      for i in 0..<numWorkers:
        var args = WorkerArgs(
          ctx: addr ctx,
          queue: queue,
          results: results,
          stats: stats,
          lifetime: addr lifetime
        )
        createThread(threads[i], workerProc, args)
      acquire(lifetime.lock)
      while lifetime.finished < numWorkers: wait(lifetime.changed, lifetime.lock)
      release(lifetime.lock)

    result.matches = ownedCopy(results.getMatches())
    result.stats = stats.toStats(globalStart, times.getTime())
    if cfg.limit > 0 and not cfg.countOnly:
      result.stats.matched = result.matches.len

    queue.destroy()
    results.destroy()
    stats.destroy()
    if numWorkers > 1:
      acquire(lifetime.lock)
      lifetime.released = true
      broadcast(lifetime.changed)
      release(lifetime.lock)
      for thread in threads.mitems: joinThread(thread)

proc scanTreeCollect(rootAbs, startDir: string; cfg: Config;
                     matcher: Matcher; ex: Excluder;
                     gi: Gitignore; useGi: bool; rootDev: int64;
                     contentRx: Option[Regex]; cachedIC: bool;
                     needInfo: bool; includeHidden: bool; needResultName: bool;
                     stats: var Stats; matches: var seq[MatchResult];
                     stopAt: var bool; control: SearchControl) =
  var stack = newSeqOfCap[StackEntry](64)
  stack.add(StackEntry(path: startDir, depth: 0, gi: gi))
  var visitedDirs = initHashSet[FileIdentity]()
  if cfg.followSymlinks:
    let rootId = getDirectoryIdentity(startDir)
    if rootId.isSome: visitedDirs.incl(rootId.get)
  let limit = cfg.limit
  let hasLimit = limit > 0
  template relPathFor(fullPath: string): string =
    when compileOption("threads"):
      computeRelPathFast(fullPath, rootAbs)
    else:
      safeRelPath(fullPath, rootAbs)

  while stack.len > 0 and not stopAt and not control.isCancelled():
    let entry = stack.pop()
    let activeGi = if useGi: extendGitignoreForDir(entry.gi, entry.path) else: entry.gi
    inc stats.visitedDirs
    inc stats.visited

    try:
      for pc, p in walkDir(entry.path, relative = false):
        if stopAt or control.isCancelled(): break

        let kind = entryTypeFromWalk(pc)
        let childDepth = entry.depth + 1

        if kind == etFile: inc stats.visitedFiles
        elif kind == etLink: inc stats.visitedLinks
        inc stats.visited

        let rel = relPathFor(p)

        if (kind == etDir or (kind == etLink and shouldFollowLinkDir(cfg, p))) and
            shouldTraverseDir(cfg, rel, childDepth, ex, activeGi, useGi, rootDev, p, includeHidden):
          var canAdd = true
          if cfg.followSymlinks:
            let dirId = getDirectoryIdentity(p)
            if dirId.isSome:
              if dirId.get in visitedDirs: canAdd = false
              else: visitedDirs.incl(dirId.get)
          if canAdd: stack.add(StackEntry(path: p, depth: childDepth, gi: activeGi))

        let om = scanEntry(rootAbs, cfg, matcher, ex, activeGi, useGi, rootDev,
                           p, rel, kind, childDepth, contentRx, cachedIC,
                           needInfo, includeHidden, needResultName, stats)
        if om.isSome:
          inc stats.matched
          if not cfg.countOnly: matches.add(om.get)
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

proc runSearchCollectSingleRoot(cfg: Config; rootAbs: string; globalStart: times.Time;
                                control: SearchControl): SearchResult =
  result.stats.startTime = globalStart

  when compileOption("threads"):
    if effectiveThreadCount(cfg) > 1:
      return runParallelSearch(cfg, rootAbs, globalStart, control)

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let giInfo = buildGitignoreLines(cfg, rootAbs)
  let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1
  let contentRx = compileContentRegex(cfg)
  let needInfo = needsFileInfo(cfg)
  let includeHidden = cfg.includeHidden
  let needResultName = needsResultName(cfg)

  var gi: Gitignore
  if giInfo.useGi:
    gi.ignoreCase = defined(windows)
    gi.root = gitignoreRoot(rootAbs)
    gi.compileGitignore(giInfo.lines)
    gi = includeAncestorGitignores(gi, rootAbs)

  var stopAt = false
  scanTreeCollect(rootAbs, rootAbs, cfg, matcher, ex, gi, giInfo.useGi, rootDev,
                  contentRx, cachedIC, needInfo, includeHidden, needResultName,
                  result.stats, result.matches, stopAt, control)

  result.stats.endTime = times.getTime()

proc runSearchCollect*(cfg: Config; control: SearchControl = nil): SearchResult =
  let start = times.getTime()
  result.stats.startTime = start

  for p in cfg.paths:
    if control.isCancelled(): break
    if cfg.limit > 0 and result.stats.matched >= cfg.limit:
      break

    let rootAbs = absolutePath(p)
    var localCfg = cfg
    if cfg.limit > 0:
      localCfg.limit = max(0, cfg.limit - result.stats.matched)
      if localCfg.limit == 0:
        break

    let part = runSearchCollectSingleRoot(localCfg, rootAbs, start, control)
    result.matches.add(part.matches)
    mergeStats(result.stats, part.stats)

  result.stats.endTime = times.getTime()

proc runSearchStream*(cfg: Config; onMatch: proc(m: MatchResult)): Stats =
  result.startTime = times.getTime()

  let cachedIC = effectiveIgnoreCase(cfg)
  let matcher = buildMatcher(cfg)
  let ex = buildExcluder(cfg)
  let contentRx = compileContentRegex(cfg)
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
      gi.ignoreCase = defined(windows)
      gi.root = gitignoreRoot(rootAbs)
      gi.compileGitignore(giInfo.lines)
      gi = includeAncestorGitignores(gi, rootAbs)

    var stopAt = false
    var stack = newSeqOfCap[StackEntry](64)
    stack.add(StackEntry(path: rootAbs, depth: 0, gi: gi))
    var visitedDirs = initHashSet[FileIdentity]()
    if cfg.followSymlinks:
      let rootId = getDirectoryIdentity(rootAbs)
      if rootId.isSome: visitedDirs.incl(rootId.get)
    template relPathFor(fullPath: string): string =
      when compileOption("threads"):
        computeRelPathFast(fullPath, rootAbs)
      else:
        safeRelPath(fullPath, rootAbs)

    while stack.len > 0 and not stopAt:
      let entry = stack.pop()
      let activeGi = if giInfo.useGi: extendGitignoreForDir(entry.gi, entry.path) else: entry.gi
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

          if (kind == etDir or (kind == etLink and shouldFollowLinkDir(cfg, fp))) and
              shouldTraverseDir(cfg, rel, childDepth, ex, activeGi, giInfo.useGi, rootDev, fp, includeHidden):
            var canAdd = true
            if cfg.followSymlinks:
              let dirId = getDirectoryIdentity(fp)
              if dirId.isSome:
                if dirId.get in visitedDirs: canAdd = false
                else: visitedDirs.incl(dirId.get)
            if canAdd: stack.add(StackEntry(path: fp, depth: childDepth, gi: activeGi))

          let om = scanEntry(rootAbs, cfg, matcher, ex, activeGi, giInfo.useGi, rootDev,
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

proc runSearchStreamPaths*(cfg: Config; onPath: proc(p: string);
                           onBatch: PathBatchCallback = nil;
                           sanitizePaths: bool = false): Stats =
  ## Batch callbacks are serialized and may run on a worker thread. Their
  ## buffers are borrowed for the duration of the call; memory stays bounded
  ## by one 64 KiB buffer per worker, even when stdout is a slow pipe.
  result.startTime = times.getTime()

  let cachedIC = effectiveIgnoreCase(cfg)
  let includeHidden = cfg.includeHidden
  let hasLimit = cfg.limit > 0
  var emitted = 0
  var spKind: SimplePatternKind
  var spCore = ""
  let simplePathMode = defined(posix) and canUseSimplePathStream(cfg) and parseSimplePattern(cfg, spKind, spCore)
  let spCoreCmp = if cachedIC: spCore.toLowerAscii() else: spCore

  let matcher = if simplePathMode: Matcher() else: buildMatcher(cfg)
  let ex = if simplePathMode: Excluder() else: buildExcluder(cfg)
  let contentRx = if simplePathMode: none(Regex) else: compileContentRegex(cfg)
  let needInfo = if simplePathMode: false else: needsFileInfo(cfg)

  for p in cfg.paths:
    if hasLimit and emitted >= cfg.limit:
      break

    let rootAbs = absolutePath(p)

    when defined(posix):
      if simplePathMode:
        let s = runSearchStreamPathsSimplePosix(cfg, rootAbs, spKind, spCoreCmp,
          cachedIC, emitted, onPath, onBatch, sanitizePaths)
        result.visited += s.visited
        result.visitedFiles += s.visitedFiles
        result.visitedDirs += s.visitedDirs
        result.visitedLinks += s.visitedLinks
        result.matched += s.matched
        result.errors += s.errors
        result.skipped += s.skipped
        result.bytesRead += s.bytesRead
        continue

    when compileOption("threads"):
      if not simplePathMode and effectiveThreadCount(cfg) > 1 and cfg.limit == 0 and
          onBatch != nil:
        let part = runParallelSearch(cfg, rootAbs, result.startTime, nil,
          if cfg.countOnly: nil else: onBatch, sanitizePaths)
        mergeStats(result, part.stats)
        continue

    let giInfo = buildGitignoreLines(cfg, rootAbs)
    let rootDev = if cfg.oneFileSystem: getDeviceId(rootAbs) else: -1

    var gi: Gitignore
    if giInfo.useGi:
      gi.ignoreCase = defined(windows)
      gi.root = gitignoreRoot(rootAbs)
      gi.compileGitignore(giInfo.lines)
      gi = includeAncestorGitignores(gi, rootAbs)

    var stopAt = false
    var stack = newSeqOfCap[StackEntry](64)
    stack.add(StackEntry(path: rootAbs, depth: 0, gi: gi))
    var visitedDirs = initHashSet[FileIdentity]()
    if cfg.followSymlinks:
      let rootId = getDirectoryIdentity(rootAbs)
      if rootId.isSome: visitedDirs.incl(rootId.get)
    template relPathFor(fullPath: string): string =
      when compileOption("threads"):
        computeRelPathFast(fullPath, rootAbs)
      else:
        safeRelPath(fullPath, rootAbs)

    while stack.len > 0 and not stopAt:
      let entry = stack.pop()
      let activeGi = if giInfo.useGi: extendGitignoreForDir(entry.gi, entry.path) else: entry.gi
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
                stack.add(StackEntry(path: fp, depth: childDepth, gi: activeGi))
            else:
              if includeHidden or not isHiddenBase(fp):
                if matchSimpleBase(fp, spKind, spCoreCmp, cachedIC):
                  inc result.matched
                  if cfg.countOnly:
                    discard
                  else:
                    let rel = relPathFor(fp)
                    onPath(outputPathFor(cfg, rel, fp))
                  inc emitted
                  if hasLimit and emitted >= cfg.limit:
                    stopAt = true
                    break
          else:
            let rel = relPathFor(fp)

            if (kind == etDir or (kind == etLink and shouldFollowLinkDir(cfg, fp))) and
                shouldTraverseDir(cfg, rel, childDepth, ex, activeGi, giInfo.useGi, rootDev, fp, includeHidden):
              var canAdd = true
              if cfg.followSymlinks:
                let dirId = getDirectoryIdentity(fp)
                if dirId.isSome:
                  if dirId.get in visitedDirs: canAdd = false
                  else: visitedDirs.incl(dirId.get)
              if canAdd: stack.add(StackEntry(path: fp, depth: childDepth, gi: activeGi))

            if scanEntryPathOnly(cfg, matcher, ex, activeGi, giInfo.useGi, rootDev,
                                   fp, rel, kind, childDepth, contentRx, cachedIC,
                                   needInfo, includeHidden, result):
              inc result.matched
              if cfg.countOnly:
                discard
              else:
                onPath(outputPathFor(cfg, rel, fp))
              inc emitted
              if hasLimit and emitted >= cfg.limit:
                stopAt = true
                break

      except CatchableError:
        inc result.errors

  result.endTime = times.getTime()
