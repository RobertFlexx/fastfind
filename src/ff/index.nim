## Small binary index that can be read one record at a time.
## Roots are written once and entries keep only metadata plus a relative path,
## so a search mostly holds the matches it finds.
import std/[os, times, strutils, options, locks]
import core, cli, matchers

const
  IndexFileName = ".fastfind_index.ffidx"
  LegacyIndexFileName = ".fastfind_index.json"
  IndexMagic = "FFIDX004"
  IndexVersion* = 4
  MaxIndexEntries = 20_000_000'u64
  MaxRoots = 4096'u32
  MaxStoredString = 16 * 1024 * 1024
  DefaultIndexAgeHours = 24

type
  IndexHeader = object
    updated: int64
    count: uint64
    roots: seq[string]

  IndexEntry = object
    rootId: uint64
    kind: EntryType
    size: int64
    mtime: int64
    relPath: string

var indexLock: Lock
initLock(indexLock)

proc getIndexPath*(): string =
  let overridePath = getEnv("FASTFIND_INDEX")
  if overridePath.len > 0: return absolutePath(overridePath)
  getHomeDir() / ".cache" / "fastfind" / IndexFileName

proc getLegacyIndexPath(): string =
  getHomeDir() / ".cache" / "fastfind" / LegacyIndexFileName

proc getIndexPathFor*(rootPath: string): string =
  let cacheDir = getHomeDir() / ".cache" / "fastfind" / "indexes"
  var h = 1469598103934665603'u64
  for c in absolutePath(rootPath):
    h = (h xor uint64(ord(c))) * 1099511628211'u64
  cacheDir / ("index_" & $h & ".ffidx")

proc indexExists*(): bool = fileExists(getIndexPath())
proc indexExistsFor*(rootPath: string): bool = fileExists(getIndexPathFor(rootPath))

proc writeByte(f: File; value: uint8) =
  var b = value
  if f.writeBuffer(addr b, 1) != 1:
    raise newException(IOError, "short write while creating index")

proc readByte(f: File; value: var uint8): bool =
  f.readBuffer(addr value, 1) == 1

proc writeU32(f: File; value: uint32) =
  for shift in countup(0, 24, 8):
    f.writeByte(uint8((value shr shift) and 0xff))

proc readU32(f: File; value: var uint32): bool =
  value = 0
  for shift in countup(0, 24, 8):
    var b: uint8
    if not f.readByte(b): return false
    value = value or (uint32(b) shl shift)
  true

proc writeU64(f: File; value: uint64) =
  for shift in countup(0, 56, 8):
    f.writeByte(uint8((value shr shift) and 0xff))

proc readU64(f: File; value: var uint64): bool =
  value = 0
  for shift in countup(0, 56, 8):
    var b: uint8
    if not f.readByte(b): return false
    value = value or (uint64(b) shl shift)
  true

proc writeVarUInt(f: File; value: uint64) =
  var v = value
  while v >= 0x80:
    f.writeByte(uint8(v and 0x7f) or 0x80)
    v = v shr 7
  f.writeByte(uint8(v))

proc readVarUInt(f: File; value: var uint64): bool =
  value = 0
  var shift = 0
  while shift < 64:
    var b: uint8
    if not f.readByte(b): return false
    value = value or (uint64(b and 0x7f) shl shift)
    if (b and 0x80) == 0: return true
    shift += 7
  false

proc writeString(f: File; value: string) =
  f.writeVarUInt(uint64(value.len))
  if value.len > 0 and f.writeBuffer(unsafeAddr value[0], value.len) != value.len:
    raise newException(IOError, "short write while creating index")

proc readString(f: File; value: var string): bool =
  var length: uint64
  if not f.readVarUInt(length) or length > uint64(MaxStoredString): return false
  value = newString(int(length))
  length == 0 or f.readBuffer(addr value[0], int(length)) == int(length)

proc normalizedRoot(path: string): string =
  result = absolutePath(path)
  normalizePath(result)

proc writeHeader(f: File; roots: seq[string]; updated: int64; count: uint64) =
  let magic = IndexMagic
  if f.writeBuffer(unsafeAddr magic[0], magic.len) != magic.len:
    raise newException(IOError, "short write while creating index")
  f.writeU64(cast[uint64](updated))
  f.writeU64(count)
  f.writeU32(uint32(roots.len))
  for root in roots: f.writeString(root)

proc readHeader(f: File; header: var IndexHeader): bool =
  var magic = newString(IndexMagic.len)
  if f.readBuffer(addr magic[0], magic.len) != magic.len or magic != IndexMagic:
    return false
  var updated, count: uint64
  var rootCount: uint32
  if not f.readU64(updated) or not f.readU64(count) or
      not f.readU32(rootCount) or rootCount > MaxRoots or count > MaxIndexEntries:
    return false
  header.updated = cast[int64](updated)
  header.count = count
  header.roots = newSeqOfCap[string](int(rootCount))
  for _ in 0..<rootCount:
    var root: string
    if not f.readString(root) or root.len == 0: return false
    header.roots.add(root)
  true

proc writeEntry(f: File; entry: IndexEntry) =
  f.writeVarUInt(entry.rootId)
  f.writeByte(uint8(ord(entry.kind)))
  f.writeVarUInt(uint64(max(0'i64, entry.size)))
  f.writeVarUInt(uint64(max(0'i64, entry.mtime)))
  f.writeString(entry.relPath)

proc readEntry(f: File; entry: var IndexEntry): bool =
  var kindByte: uint8
  var size, mtime: uint64
  if not f.readVarUInt(entry.rootId) or not f.readByte(kindByte) or
      kindByte > uint8(ord(high(EntryType))) or not f.readVarUInt(size) or
      not f.readVarUInt(mtime) or not f.readString(entry.relPath):
    return false
  if size > uint64(high(int64)) or mtime > uint64(high(int64)): return false
  entry.kind = EntryType(kindByte)
  entry.size = int64(size)
  entry.mtime = int64(mtime)
  entry.relPath.len > 0 and entry.relPath != "."

proc openIndex(header: var IndexHeader; f: var File): bool =
  if not open(f, getIndexPath(), fmRead): return false
  if not f.readHeader(header):
    close(f)
    return false
  true

proc indexRoots(paths: seq[string]): seq[string] =
  for path in paths:
    let root = normalizedRoot(path)
    if not dirExists(root): continue
    var covered = false
    for existing in result:
      if root == existing or root.startsWith(existing & DirSep):
        covered = true
        break
    if covered: continue
    var i = result.len - 1
    while i >= 0:
      if result[i].startsWith(root & DirSep): result.delete(i)
      dec i
    result.add(root)

proc atomicReplace(tempPath, destination: string) =
  when defined(windows):
    if fileExists(destination): removeFile(destination)
  moveFile(tempPath, destination)

proc rebuildIndex(paths: seq[string]; showProgress: bool) =
  let roots = indexRoots(paths)
  if roots.len == 0:
    raise newException(ValueError, "no readable directories to index")
  let destination = getIndexPath()
  createDir(destination.parentDir())
  let tempPath = destination & ".tmp." & $getCurrentProcessId()
  var f: File
  if not open(f, tempPath, fmWrite):
    raise newException(IOError, "cannot create index: " & tempPath)
  var succeeded = false
  try:
    f.writeHeader(roots, getTime().toUnix, 0)
    var count = 0'u64
    var lastProgress = 0'u64
    for rootId, root in roots:
      try:
        for path in walkDirRec(root,
            yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir},
            followFilter = {pcDir}):
          if count >= MaxIndexEntries:
            raise newException(ValueError, "index entry safety limit exceeded")
          try:
            let info = getFileInfo(path, followSymlink = false)
            let kind = case info.kind
              of pcFile: etFile
              of pcDir: etDir
              of pcLinkToFile, pcLinkToDir: etLink
            let rel = safeRelPath(path, root)
            if rel.len == 0 or rel == ".": continue
            f.writeEntry(IndexEntry(rootId: uint64(rootId), kind: kind,
              size: info.size, mtime: info.lastWriteTime.toUnix, relPath: rel))
            inc count
            if showProgress and count - lastProgress >= 25_000:
              stderr.write("\rIndexed: " & $count & " entries...")
              stderr.flushFile()
              lastProgress = count
          except OSError:
            continue
      except CatchableError as e:
        if e of ValueError or e of IOError: raise
        continue
    flushFile(f)
    setFilePos(f, int64(IndexMagic.len + 8))
    f.writeU64(count)
    flushFile(f)
    close(f)
    if showProgress:
      stderr.writeLine("\rIndexed: " & $count & " entries.    ")
    atomicReplace(tempPath, destination)
    succeeded = true
  finally:
    if not succeeded:
      try: close(f)
      except CatchableError: discard
      if fileExists(tempPath): removeFile(tempPath)

proc updateIndexIncremental*(paths: seq[string]; cfg: Config;
                             showProgress: bool = false) =
  ## Rebuild in one pass so memory stays predictable, then swap the finished
  ## file into place. The old index remains usable until that last step.
  acquire(indexLock)
  try: rebuildIndex(paths, showProgress)
  finally: release(indexLock)

proc updateIndex*(paths: seq[string]; cfg: Config; showProgress: bool = false;
                  forceFullRebuild: bool = false) =
  updateIndexIncremental(paths, cfg, showProgress)

proc pathDepth(path: string): int =
  if path.len == 0 or path == ".": return 0
  result = 1
  for c in path:
    if c == '/' or c == '\\': inc result

proc isHiddenPath(path: string): bool =
  var componentStart = true
  for c in path:
    if componentStart and c == '.': return true
    componentStart = c == '/' or c == '\\'
  false

proc passesExtensions(cfg: Config; path: string): bool =
  if cfg.extensions.len == 0: return true
  let lower = path.toLowerAscii()
  for ext in cfg.extensions:
    let wanted = ext.toLowerAscii()
    if wanted.startsWith(".") and lower.endsWith(wanted): return true
    if not wanted.startsWith(".") and extractFilename(lower) == wanted: return true
  false

proc requestedRelPath(absPath: string; requestedRoots: seq[string];
                      relPath: var string): bool =
  for root in requestedRoots:
    if absPath == root:
      relPath = "."
      return true
    if absPath.startsWith(root & DirSep):
      relPath = absPath[root.len + 1..^1]
      return true
  false

proc indexCovers*(paths: seq[string]): bool =
  var f: File
  var header: IndexHeader
  if not openIndex(header, f): return false
  defer: close(f)
  for path in paths:
    let requested = normalizedRoot(path)
    var covered = false
    for root in header.roots:
      if requested == root or requested.startsWith(root & DirSep):
        covered = true
        break
    if not covered: return false
  true

proc buildMatcher(cfg: Config): Matcher =
  result = Matcher(mode: cfg.matchMode, pathMode: cfg.pathMode,
    ignoreCase: cfg.ignoreCase, smartCase: cfg.smartCase,
    fullMatch: cfg.fullMatch, patterns: cfg.patterns)
  result.compile()

proc buildExcluder(cfg: Config): Excluder =
  result = Excluder(patterns: cfg.excludes)
  result.compile()

proc searchIndex*(cfg: Config): SearchResult =
  result.stats.startTime = getTime()
  defer: result.stats.endTime = getTime()
  var f: File
  var header: IndexHeader
  if not openIndex(header, f): return
  defer: close(f)

  var requestedRoots = newSeqOfCap[string](cfg.paths.len)
  for path in cfg.paths: requestedRoots.add(normalizedRoot(path))
  var directRoot = newSeq[int](header.roots.len)
  for i in 0..<directRoot.len: directRoot[i] = -1
  for rootId, indexedRoot in header.roots:
    for requestedId, requestedRoot in requestedRoots:
      if indexedRoot == requestedRoot:
        directRoot[rootId] = requestedId
        break
  let matcher = buildMatcher(cfg)
  let excluder = buildExcluder(cfg)

  for _ in 0..<header.count:
    var entry: IndexEntry
    if not f.readEntry(entry) or entry.rootId >= uint64(header.roots.len):
      inc result.stats.errors
      result.matches.setLen(0)
      result.stats.matched = 0
      return
    inc result.stats.visited
    var relPath: string
    if directRoot[int(entry.rootId)] >= 0:
      relPath = entry.relPath
    else:
      let candidate = header.roots[int(entry.rootId)] / entry.relPath
      if not requestedRelPath(candidate, requestedRoots, relPath): continue
    let depth = pathDepth(relPath)
    if entry.kind notin cfg.types or
        (not cfg.includeHidden and isHiddenPath(relPath)) or
        (cfg.minDepth > 0 and depth < cfg.minDepth) or
        (cfg.maxDepth >= 0 and depth > cfg.maxDepth) or
        (cfg.minSize >= 0 and entry.size < cfg.minSize) or
        (cfg.maxSize >= 0 and entry.size > cfg.maxSize) or
        not passesExtensions(cfg, relPath) or
        (cfg.newerThan.isSome and entry.mtime <= cfg.newerThan.get.toUnix) or
        (cfg.olderThan.isSome and entry.mtime >= cfg.olderThan.get.toUnix) or
        (cfg.excludes.len > 0 and excluder.isExcluded(relPath)):
      inc result.stats.skipped
      continue
    var name = ""
    if cfg.fuzzyMode or cfg.matchMode == mmFuzzy: name = extractFilename(relPath)
    if not matcher.anyMatch(name, relPath): continue
    var score = 0
    if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
      score = matcher.fuzzyScore(name, relPath)
      if score >= 999999: continue
    inc result.stats.matched
    if not cfg.countOnly:
      if name.len == 0: name = extractFilename(relPath)
      let absPath = header.roots[int(entry.rootId)] / entry.relPath
      result.matches.add(MatchResult(path: relPath, relPath: relPath,
        absPath: absPath, name: name, size: entry.size,
        mtime: fromUnix(entry.mtime), kind: entry.kind, fuzzyScore: score))
    if cfg.limit > 0 and result.stats.matched >= cfg.limit: break

proc searchIndexFast*(cfg: Config): SearchResult = searchIndex(cfg)

proc getIndexStats*(): tuple[count: int, lastUpdate: Time, sizeBytes: int64,
                             rootPaths: seq[string]] =
  var f: File
  var header: IndexHeader
  if not openIndex(header, f): return (0, fromUnix(0), 0'i64, @[])
  close(f)
  result.count = int(header.count)
  result.lastUpdate = fromUnix(header.updated)
  result.rootPaths = header.roots
  try: result.sizeBytes = getFileSize(getIndexPath())
  except CatchableError: result.sizeBytes = 0

proc getIndexAge*(): Duration =
  let stats = getIndexStats()
  if stats.lastUpdate.toUnix == 0: return initDuration(days = 365)
  getTime() - stats.lastUpdate

proc isIndexStale*(maxAge: Duration = initDuration(hours = DefaultIndexAgeHours)): bool =
  getIndexAge() > maxAge

proc verifyIndex(): tuple[valid, invalid: int] =
  var f: File
  var header: IndexHeader
  if not openIndex(header, f): return
  defer: close(f)
  for _ in 0..<header.count:
    var entry: IndexEntry
    if not f.readEntry(entry) or entry.rootId >= uint64(header.roots.len):
      inc result.invalid
      break
    let path = header.roots[int(entry.rootId)] / entry.relPath
    if fileExists(path) or dirExists(path) or symlinkExists(path): inc result.valid
    else: inc result.invalid

proc handleIndexCommand*(cfg: Config) =
  case cfg.indexCommand
  of icRebuild, icUpdate:
    let started = getTime()
    stderr.writeLine(if cfg.indexCommand == icRebuild:
      "Building compact index..." else: "Refreshing compact index...")
    updateIndex(cfg.paths, cfg, showProgress = true,
      forceFullRebuild = cfg.indexCommand == icRebuild)
    let stats = getIndexStats()
    stdout.writeLine("Index ready: " & $stats.count & " entries in " &
      $(getTime() - started).inMilliseconds & "ms")
    stdout.writeLine("Saved to: " & getIndexPath())
  of icStatus:
    if indexExists():
      let stats = getIndexStats()
      if stats.lastUpdate.toUnix == 0:
        stdout.writeLine("Index is corrupt or unsupported; rebuild it.")
        return
      stdout.writeLine("Index status:")
      stdout.writeLine("  Format: compact binary v" & $IndexVersion)
      stdout.writeLine("  Path: " & getIndexPath())
      stdout.writeLine("  Entries: " & $stats.count)
      stdout.writeLine("  Size: " & $(stats.sizeBytes div 1024) & " KiB")
      stdout.writeLine("  Last updated: " & stats.lastUpdate.format("yyyy-MM-dd HH:mm:ss"))
      stdout.writeLine("  Age: " & $getIndexAge().inHours & " hours")
      for root in stats.rootPaths: stdout.writeLine("  Root: " & root)
      stdout.writeLine(if isIndexStale(): "  Status: STALE" else: "  Status: OK")
    elif fileExists(getLegacyIndexPath()):
      stdout.writeLine("Legacy JSON index found. Migrate with: ff --rebuild-index <path>")
    else:
      stdout.writeLine("No index found. Create one with: ff --rebuild-index <path>")
  of icVerify:
    if not indexExists(): stdout.writeLine("No index found")
    else:
      let checked = verifyIndex()
      stdout.writeLine("Index verified: " & $checked.valid & " valid, " &
        $checked.invalid & " stale/corrupt")
      if checked.invalid > 0:
        stdout.writeLine("Run --update-index to atomically refresh it.")
  of icDaemon:
    stderr.writeLine("Daemon mode is not implemented; schedule --update-index instead.")
    quit(1)
  of icNone: discard

proc clearIndex*() =
  let path = getIndexPath()
  if fileExists(path): removeFile(path)
