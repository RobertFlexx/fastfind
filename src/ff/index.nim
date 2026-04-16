import std/[os, times, strutils, json, locks, options, streams, tables, hashes, sequtils]
import core, cli, fuzzy_match, matchers

const
  IndexFileName = ".fastfind_index.json"
  IndexVersion = 3
  MaxIndexEntries = 5_000_000
  DefaultIndexAgeHours = 24

var indexLock: Lock
initLock(indexLock)

type
  IndexEntry* = object
    path*: string
    name*: string
    size*: int64
    mtime*: int64
    kind*: int8
    depth*: int16

  FileIndex* = object
    version*: int
    updated*: int64
    rootPaths*: seq[string]
    entries*: seq[IndexEntry]

proc getIndexPath*(): string =
  getHomeDir() / ".cache" / "fastfind" / IndexFileName

proc getIndexPathFor*(rootPath: string): string =
  let cacheDir = getHomeDir() / ".cache" / "fastfind" / "indexes"
  let h = hash(absolutePath(rootPath))
  cacheDir / ("index_" & $h & ".json")

proc indexExists*(): bool =
  fileExists(getIndexPath())

proc indexExistsFor*(rootPath: string): bool =
  fileExists(getIndexPathFor(rootPath))

proc computeDepth(path: string): int16 =
  result = 0
  for c in path:
    if c == '/' or c == '\\':
      inc result

proc saveIndexStream(idx: FileIndex; path: string) =
  createDir(path.parentDir())
  var fs = newFileStream(path, fmWrite)
  if fs == nil:
    raise newException(IOError, "Cannot open index file for writing: " & path)
  defer: fs.close()
  fs.writeLine("{")
  fs.writeLine("\"version\": " & $idx.version & ",")
  fs.writeLine("\"updated\": " & $idx.updated & ",")
  fs.write("\"rootPaths\": [")
  for i, rp in idx.rootPaths:
    if i > 0: fs.write(",")
    fs.write("\"" & rp.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
  fs.writeLine("],")
  fs.writeLine("\"entries\": [")
  for i, e in idx.entries:
    if i > 0: fs.writeLine(",")
    let escapedPath = e.path.replace("\\", "\\\\").replace("\"", "\\\"")
    let escapedName = e.name.replace("\\", "\\\\").replace("\"", "\\\"")
    fs.write("{\"p\":\"" & escapedPath & "\",")
    fs.write("\"n\":\"" & escapedName & "\",")
    fs.write("\"s\":" & $e.size & ",")
    fs.write("\"m\":" & $e.mtime & ",")
    fs.write("\"k\":" & $e.kind & ",")
    fs.write("\"d\":" & $e.depth & "}")
  fs.writeLine("")
  fs.writeLine("]")
  fs.writeLine("}")

proc loadIndexStream(path: string): FileIndex =
  result = FileIndex(version: IndexVersion, updated: 0, entries: @[])
  if not fileExists(path):
    return
  try:
    let content = readFile(path)
    let obj = parseJson(content)
    result.version = obj.getOrDefault("version").getInt(1)
    result.updated = obj.getOrDefault("updated").getBiggestInt(0)
    if obj.hasKey("rootPaths"):
      for rp in obj["rootPaths"]:
        result.rootPaths.add(rp.getStr())
    if obj.hasKey("entries"):
      result.entries = newSeqOfCap[IndexEntry](obj["entries"].len)
      for entry in obj["entries"]:
        var e: IndexEntry
        if entry.hasKey("p"):
          e.path = entry["p"].getStr()
        elif entry.hasKey("path"):
          e.path = entry["path"].getStr()
        if entry.hasKey("n"):
          e.name = entry["n"].getStr()
        elif entry.hasKey("name"):
          e.name = entry["name"].getStr()
        if entry.hasKey("s"):
          e.size = entry["s"].getBiggestInt()
        elif entry.hasKey("size"):
          e.size = entry["size"].getBiggestInt()
        if entry.hasKey("m"):
          e.mtime = entry["m"].getBiggestInt()
        elif entry.hasKey("mtime"):
          e.mtime = entry["mtime"].getBiggestInt()
        if entry.hasKey("k"):
          e.kind = int8(entry["k"].getInt())
        elif entry.hasKey("kind"):
          e.kind = int8(entry["kind"].getInt())
        if entry.hasKey("d"):
          e.depth = int16(entry["d"].getInt())
        result.entries.add(e)
  except CatchableError:
    result = FileIndex(version: IndexVersion, updated: 0, entries: @[])

proc saveIndex*(idx: FileIndex) =
  saveIndexStream(idx, getIndexPath())

proc loadIndex*(): FileIndex =
  loadIndexStream(getIndexPath())

proc saveIndexSafe*(idx: FileIndex) =
  acquire(indexLock)
  try:
    saveIndex(idx)
  finally:
    release(indexLock)

proc loadIndexSafe*(): FileIndex =
  acquire(indexLock)
  try:
    result = loadIndex()
  finally:
    release(indexLock)

proc verifyIndexEntries*(idx: var FileIndex): int =
  var valid = newSeqOfCap[IndexEntry](idx.entries.len)
  var removed = 0
  for entry in idx.entries:
    if fileExists(entry.path) or dirExists(entry.path) or symlinkExists(entry.path):
      valid.add(entry)
    else:
      inc removed
  idx.entries = valid
  removed

proc updateIndexEntry(path: string): Option[IndexEntry] =
  try:
    let info = getFileInfo(path, followSymlink = false)
    let name = extractFilename(path)
    let kind: int8 = case info.kind
      of pcFile: int8(ord(etFile))
      of pcDir: int8(ord(etDir))
      of pcLinkToFile, pcLinkToDir: int8(ord(etLink))
    let depth = computeDepth(path)
    result = some(IndexEntry(
      path: path,
      name: name,
      size: info.size,
      mtime: info.lastWriteTime.toUnix,
      kind: kind,
      depth: depth
    ))
  except CatchableError:
    discard

proc updateIndexIncremental*(paths: seq[string]; cfg: Config; showProgress: bool = false) =
  var idx: FileIndex
  var isNew = true
  var staleRemoved = 0
  var changedUpdated = 0
  var unchangedCount = 0

  if indexExists():
    idx = loadIndex()
    isNew = false
    if showProgress:
      stderr.writeLine("Loaded existing index with " & $idx.entries.len & " entries")
    staleRemoved = verifyIndexEntries(idx)
    if showProgress and staleRemoved > 0:
      stderr.writeLine("Removed " & $staleRemoved & " stale entries")
    idx.updated = getTime().toUnix

  if isNew:
    idx = FileIndex(
      version: IndexVersion,
      updated: getTime().toUnix,
      rootPaths: paths,
      entries: newSeqOfCap[IndexEntry](100000)
    )

  var existingPaths = initTable[string, int](idx.entries.len)
  for i, e in idx.entries:
    existingPaths[e.path] = i

  var count = 0
  var lastProgress = 0
  var newEntries = 0
  # var modifiedEntries = 0

  for rootPath in paths:
    let rootAbs = absolutePath(rootPath)
    if not dirExists(rootAbs):
      continue
    try:
      for path in walkDirRec(rootAbs, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
        if idx.entries.len >= MaxIndexEntries:
          break
        if existingPaths.hasKey(path):
          let existingIdx = existingPaths[path]
          let existing = idx.entries[existingIdx]
          var newEntry = updateIndexEntry(path)
          if newEntry.isSome:
            let ne = newEntry.get
            if ne.mtime != existing.mtime or ne.size != existing.size:
              idx.entries[existingIdx] = ne
              inc changedUpdated
            else:
              inc unchangedCount
          existingPaths.del(path)
        else:
          var newEntry = updateIndexEntry(path)
          if newEntry.isSome:
            idx.entries.add(newEntry.get)
            inc newEntries
        inc count
        if showProgress and count - lastProgress >= 10000:
          let status = if isNew: "Indexed" else: "Updated"
          stderr.write("\r" & status & ": " & $count & " files (" & $newEntries & " new, " & $changedUpdated & " modified)...")
          stderr.flushFile()
          lastProgress = count
    except CatchableError:
      continue

  if showProgress:
    let status = if isNew: "Indexed" else: "Updated"
    stderr.writeLine("\r" & status & ": " & $count & " files (" & $newEntries & " new, " & $changedUpdated & " modified, " & $unchangedCount & " unchanged).    ")

  if not isNew:
    idx.rootPaths = paths

  saveIndexSafe(idx)
  if showProgress and staleRemoved > 0:
    stderr.writeLine("Total entries: " & $idx.entries.len)

proc updateIndex*(paths: seq[string]; cfg: Config; showProgress: bool = false; forceFullRebuild: bool = false) =
  if forceFullRebuild or not indexExists():
    var idx = FileIndex(
      version: IndexVersion,
      updated: getTime().toUnix,
      rootPaths: paths,
      entries: newSeqOfCap[IndexEntry](100000)
    )
    var count = 0
    var lastProgress = 0
    for rootPath in paths:
      let rootAbs = absolutePath(rootPath)
      if not dirExists(rootAbs):
        continue
      try:
        for path in walkDirRec(rootAbs, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
          if idx.entries.len >= MaxIndexEntries:
            break
          var entryOpt = updateIndexEntry(path)
          if entryOpt.isSome:
            idx.entries.add(entryOpt.get)
            inc count
            if showProgress and count - lastProgress >= 10000:
              stderr.write("\rIndexed: " & $count & " files...")
              stderr.flushFile()
              lastProgress = count
      except CatchableError:
        continue
    if showProgress:
      stderr.writeLine("\rIndexed: " & $count & " files.    ")
    saveIndexSafe(idx)
  else:
    updateIndexIncremental(paths, cfg, showProgress)

proc matchesPattern(name: string; pattern: string; ignoreCase: bool; matchMode: MatchMode): bool =
  let n = if ignoreCase: name.toLowerAscii() else: name
  let p = if ignoreCase: pattern.toLowerAscii() else: pattern
  case matchMode
  of mmGlob:
    if '*' in p or '?' in p:
      var i = 0
      var j = 0
      var starIdx = -1
      var matchIdx = 0
      while i < n.len:
        if j < p.len and (p[j] == '?' or p[j] == n[i]):
          inc i
          inc j
        elif j < p.len and p[j] == '*':
          starIdx = j
          matchIdx = i
          inc j
        elif starIdx >= 0:
          j = starIdx + 1
          inc matchIdx
          i = matchIdx
        else:
          return false
      while j < p.len and p[j] == '*':
        inc j
      return j == p.len
    else:
      return p in n
  of mmFixed:
    return p in n
  of mmRegex:
    return p in n
  of mmFuzzy:
    return fuzzyMatch(p, n) >= 0

proc searchIndex*(cfg: Config): SearchResult =
  result.stats.startTime = getTime()
  if not indexExists():
    result.stats.endTime = getTime()
    return
  var idx = loadIndex()
  if idx.version < IndexVersion:
    result.stats.endTime = getTime()
    return
  let ignoreCase = cfg.ignoreCase or (cfg.smartCase and cfg.patterns.allIt(it == it.toLowerAscii()))
  let hasPatterns = cfg.patterns.len > 0
  let checkSize = cfg.minSize >= 0 or cfg.maxSize >= 0
  let checkTime = cfg.newerThan.isSome or cfg.olderThan.isSome
  let checkDepth = cfg.minDepth > 0 or cfg.maxDepth >= 0
  var lowercasePatterns: seq[string] = @[]
  if hasPatterns and ignoreCase:
    for p in cfg.patterns:
      lowercasePatterns.add(p.toLowerAscii())
  else:
    lowercasePatterns = cfg.patterns
  for entry in idx.entries:
    inc result.stats.visited
    let kind = EntryType(entry.kind)
    if kind notin cfg.types:
      inc result.stats.skipped
      continue
    if checkDepth:
      if cfg.minDepth > 0 and entry.depth < cfg.minDepth:
        inc result.stats.skipped
        continue
      if cfg.maxDepth >= 0 and entry.depth > cfg.maxDepth:
        inc result.stats.skipped
        continue
    if checkSize:
      if cfg.minSize >= 0 and entry.size < cfg.minSize:
        inc result.stats.skipped
        continue
      if cfg.maxSize >= 0 and entry.size > cfg.maxSize:
        inc result.stats.skipped
        continue
    if checkTime:
      let mtime = fromUnix(entry.mtime)
      if cfg.newerThan.isSome and mtime <= cfg.newerThan.get:
        inc result.stats.skipped
        continue
      if cfg.olderThan.isSome and mtime >= cfg.olderThan.get:
        inc result.stats.skipped
        continue
    var matched = not hasPatterns
    var bestScore = 999999
    if hasPatterns:
      let nameToMatch = if ignoreCase: entry.name.toLowerAscii() else: entry.name
      for pattern in lowercasePatterns:
        if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
          let score = fuzzyMatch(pattern, nameToMatch)
          if score >= 0:
            matched = true
            if score < bestScore:
              bestScore = score
        else:
          if matchesPattern(entry.name, pattern, ignoreCase, cfg.matchMode):
            matched = true
            break
    if not matched:
      inc result.stats.skipped
      continue
    var m = MatchResult(
      absPath: entry.path,
      path: entry.path,
      relPath: entry.path,
      name: entry.name,
      size: entry.size,
      mtime: fromUnix(entry.mtime),
      kind: kind,
      fuzzyScore: if cfg.fuzzyMode: bestScore else: 0
    )
    result.matches.add(m)
    inc result.stats.matched
    if cfg.limit > 0 and result.stats.matched >= cfg.limit:
      break
  result.stats.endTime = getTime()

proc searchIndexFast*(cfg: Config): SearchResult =
  result.stats.startTime = getTime()
  if not indexExists():
    result.stats.endTime = getTime()
    return
  var idx = loadIndex()
  if idx.version < IndexVersion:
    result.stats.endTime = getTime()
    return
  if idx.entries.len == 0:
    result.stats.endTime = getTime()
    return
  let ignoreCase = cfg.ignoreCase or (cfg.smartCase and cfg.patterns.allIt(it == it.toLowerAscii()))
  let hasPatterns = cfg.patterns.len > 0
  var pattern = ""
  if hasPatterns:
    pattern = if ignoreCase: cfg.patterns[0].toLowerAscii() else: cfg.patterns[0]
  let isFuzzy = cfg.fuzzyMode or cfg.matchMode == mmFuzzy
  let hasLimit = cfg.limit > 0
  let limit = cfg.limit
  var matchCount = 0
  for i in 0..<idx.entries.len:
    let entry = idx.entries[i]
    let kind = EntryType(entry.kind)
    if kind notin cfg.types:
      continue
    if hasPatterns:
      let nameToMatch = if ignoreCase: entry.name.toLowerAscii() else: entry.name
      if isFuzzy:
        let score = fuzzyMatch(pattern, nameToMatch)
        if score < 0:
          continue
        var m = MatchResult(
          absPath: entry.path,
          path: entry.path,
          relPath: entry.path,
          name: entry.name,
          size: entry.size,
          mtime: fromUnix(entry.mtime),
          kind: kind,
          fuzzyScore: score
        )
        result.matches.add(m)
      else:
        if pattern notin nameToMatch:
          continue
        var m = MatchResult(
          absPath: entry.path,
          path: entry.path,
          relPath: entry.path,
          name: entry.name,
          size: entry.size,
          mtime: fromUnix(entry.mtime),
          kind: kind
        )
        result.matches.add(m)
    else:
      var m = MatchResult(
        absPath: entry.path,
        path: entry.path,
        relPath: entry.path,
        name: entry.name,
        size: entry.size,
        mtime: fromUnix(entry.mtime),
        kind: kind
      )
      result.matches.add(m)
    inc matchCount
    if hasLimit and matchCount >= limit:
      break
  result.stats.matched = matchCount
  result.stats.endTime = getTime()

proc getIndexStats*(): tuple[count: int, lastUpdate: Time, sizeBytes: int64, rootPaths: seq[string]] =
  if not indexExists():
    return (0, fromUnix(0), 0'i64, @[])
  let idx = loadIndex()
  result.count = idx.entries.len
  result.lastUpdate = fromUnix(idx.updated)
  result.rootPaths = idx.rootPaths
  try:
    let info = getFileInfo(getIndexPath())
    result.sizeBytes = info.size
  except CatchableError:
    result.sizeBytes = 0

proc getIndexAge*(): Duration =
  if not indexExists():
    return initDuration(days = 365)
  let idx = loadIndex()
  getTime() - fromUnix(idx.updated)

proc isIndexStale*(maxAge: Duration = initDuration(hours = DefaultIndexAgeHours)): bool =
  getIndexAge() > maxAge

proc handleIndexCommand*(cfg: Config) =
  case cfg.indexCommand
  of icRebuild:
    let startTime = getTime()
    stderr.writeLine("Building index...")
    updateIndex(cfg.paths, cfg, showProgress = true, forceFullRebuild = true)
    let stats = getIndexStats()
    let elapsed = (getTime() - startTime).inMilliseconds
    stdout.writeLine("Index built: " & $stats.count & " entries in " & $elapsed & "ms")
    stdout.writeLine("Saved to: " & getIndexPath())
  of icUpdate:
    let startTime = getTime()
    stderr.writeLine("Updating index (incremental)...")
    updateIndex(cfg.paths, cfg, showProgress = true, forceFullRebuild = false)
    let stats = getIndexStats()
    let elapsed = (getTime() - startTime).inMilliseconds
    stdout.writeLine("Index updated: " & $stats.count & " entries in " & $elapsed & "ms")
    stdout.writeLine("Saved to: " & getIndexPath())
  of icStatus:
    if indexExists():
      let stats = getIndexStats()
      let age = getIndexAge()
      stdout.writeLine("Index status:")
      stdout.writeLine("  Path: " & getIndexPath())
      stdout.writeLine("  Entries: " & $stats.count)
      stdout.writeLine("  Size: " & $(stats.sizeBytes div 1024) & " KB")
      stdout.writeLine("  Last updated: " & stats.lastUpdate.format("yyyy-MM-dd HH:mm:ss"))
      stdout.writeLine("  Age: " & $age.inHours & " hours")
      if stats.rootPaths.len > 0:
        stdout.writeLine("  Indexed paths:")
        for rp in stats.rootPaths:
          stdout.writeLine("    - " & rp)
      if isIndexStale():
        stdout.writeLine("  Status: STALE (consider rebuilding with --rebuild-index)")
      else:
        stdout.writeLine("  Status: OK")
    else:
      stdout.writeLine("No index found")
      stdout.writeLine("Create one with: ff --rebuild-index <path>")
      stdout.writeLine("Or use incremental update: ff --update-index <path>")
  of icVerify:
    var idx = loadIndex()
    let before = idx.entries.len
    let removed = verifyIndexEntries(idx)
    let after = idx.entries.len
    if removed > 0:
      saveIndexSafe(idx)
      stdout.writeLine("Verified index: removed " & $removed & " stale entries")
      stdout.writeLine("Entries: " & $before & " -> " & $after)
    else:
      stdout.writeLine("Index verified: all " & $idx.entries.len & " entries valid")
  of icDaemon:
    stderr.writeLine("Daemon mode not yet implemented.")
    stderr.writeLine("Use cron or systemd timer to run: ff --update-index <path>")
    quit(1)
  of icNone:
    discard

proc clearIndex*() =
  let path = getIndexPath()
  if fileExists(path):
    removeFile(path)
