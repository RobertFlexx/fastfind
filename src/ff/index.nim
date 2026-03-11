# src/ff/index.nim
## simple file index using JSON format

import std/[os, times, strutils, json, locks, options]
import core, cli, fuzzy_match, search, matchers

const
  IndexFileName = ".fastfind_index.json"

var indexLock: Lock
initLock(indexLock)

type
  IndexEntry = object
    path: string
    name: string
    size: int64
    mtime: int64
    kind: int

  FileIndex = object
    version: int
    updated: int64
    entries: seq[IndexEntry]

proc getIndexPath*(): string =
  getHomeDir() / ".cache" / "fastfind" / IndexFileName

proc indexExists*(): bool =
  fileExists(getIndexPath())

proc saveIndex(idx: FileIndex) =
  let path = getIndexPath()
  createDir(path.parentDir())
  
  var obj = newJObject()
  obj["version"] = %idx.version
  obj["updated"] = %idx.updated
  
  var arr = newJArray()
  for e in idx.entries:
    var entry = newJObject()
    entry["path"] = %e.path
    entry["name"] = %e.name
    entry["size"] = %e.size
    entry["mtime"] = %e.mtime
    entry["kind"] = %e.kind
    arr.add(entry)
  
  obj["entries"] = arr
  writeFile(path, $obj)

proc loadIndex(): FileIndex =
  if not indexExists():
    return FileIndex(version: 1, updated: 0, entries: @[])
  
  try:
    let content = readFile(getIndexPath())
    let obj = parseJson(content)
    
    result.version = obj["version"].getInt(1)
    result.updated = obj["updated"].getBiggestInt(0)
    
    for entry in obj["entries"]:
      var e: IndexEntry
      e.path = entry["path"].getStr()
      e.name = entry["name"].getStr()
      e.size = entry["size"].getBiggestInt()
      e.mtime = entry["mtime"].getBiggestInt()
      e.kind = entry["kind"].getInt()
      result.entries.add(e)
  except CatchableError:
    result = FileIndex(version: 1, updated: 0, entries: @[])

proc updateIndex*(paths: seq[string]; cfg: Config) =
  var idx = FileIndex(version: 1, updated: getTime().toUnix, entries: @[])
  
  for rootPath in paths:
    let rootAbs = absolutePath(rootPath)
    
    for path in walkDirRec(rootAbs):
      try:
        let info = getFileInfo(path)
        let name = extractFilename(path)
        let kind = case info.kind
          of pcFile: ord(etFile)
          of pcDir: ord(etDir)
          of pcLinkToFile, pcLinkToDir: ord(etLink)
        
        idx.entries.add(IndexEntry(
          path: path,
          name: name,
          size: info.size,
          mtime: info.lastWriteTime.toUnix,
          kind: kind
        ))
      except CatchableError:
        continue
  
  saveIndex(idx)

proc searchIndex*(cfg: Config): SearchResult =
  result.stats.startTime = getTime()
  
  if not indexExists():
    result.stats.endTime = getTime()
    return
  
  withLock(indexLock):
    let idx = loadIndex()
    
    for entry in idx.entries:
      let kind = EntryType(entry.kind)
      if kind notin cfg.types:
        continue
      
      if cfg.minSize >= 0 and entry.size < cfg.minSize:
        continue
      if cfg.maxSize >= 0 and entry.size > cfg.maxSize:
        continue
      
      let mtime = fromUnix(entry.mtime)
      if cfg.newerThan.isSome and mtime <= cfg.newerThan.get:
        continue
      if cfg.olderThan.isSome and mtime >= cfg.olderThan.get:
        continue
      
      if cfg.patterns.len > 0:
        let pattern = cfg.patterns[0].toLowerAscii()
        let name = entry.name.toLowerAscii()
        
        if cfg.fuzzyMode or cfg.matchMode == mmFuzzy:
          let score = fuzzyMatch(pattern, name)
          if score < 0:
            continue
        else:
          if not name.contains(pattern):
            continue
      
      if not fileExists(entry.path) and not dirExists(entry.path):
        continue
      
      var m: MatchResult
      m.absPath = entry.path
      m.path = entry.path
      m.relPath = entry.path
      m.name = entry.name
      m.size = entry.size
      m.mtime = fromUnix(entry.mtime)
      m.kind = kind
      
      if cfg.fuzzyMode and cfg.patterns.len > 0:
        m.fuzzyScore = fuzzyMatch(cfg.patterns[0].toLowerAscii(), entry.name.toLowerAscii())
      
      result.matches.add(m)
      inc result.stats.matched
      
      if cfg.limit > 0 and result.stats.matched >= cfg.limit:
        break
  
  result.stats.endTime = getTime()

proc getIndexStats*(): tuple[count: int, lastUpdate: Time, sizeBytes: int64] =
  if not indexExists():
    return (0, fromUnix(0), 0'i64)
  
  let idx = loadIndex()
  result.count = idx.entries.len
  result.lastUpdate = fromUnix(idx.updated)
  
  try:
    let info = getFileInfo(getIndexPath())
    result.sizeBytes = info.size
  except CatchableError:
    result.sizeBytes = 0

proc handleIndexCommand*(cfg: Config) =
  case cfg.indexCommand
  of icRebuild:
    stdout.writeLine("Rebuilding index...")
    let startTime = getTime()
    updateIndex(cfg.paths, cfg)
    let stats = getIndexStats()
    let elapsed = (getTime() - startTime).inMilliseconds
    stdout.writeLine("Index rebuilt: " & $stats.count & " entries in " & $elapsed & "ms")
  
  of icStatus:
    if indexExists():
      let stats = getIndexStats()
      stdout.writeLine("Index status:")
      stdout.writeLine("  Path: " & getIndexPath())
      stdout.writeLine("  Entries: " & $stats.count)
      stdout.writeLine("  Size: " & $(stats.sizeBytes div 1024) & " KB")
      stdout.writeLine("  Last updated: " & stats.lastUpdate.format("yyyy-MM-dd HH:mm:ss"))
    else:
      stdout.writeLine("No index found")
      stdout.writeLine("Create one with: fastfind --rebuild-index <path>")
  
  of icDaemon:
    stderr.writeLine("Daemon mode requires filesystem watcher support.")
    stderr.writeLine("For now, use --rebuild-index periodically.")
    quit(1)
  
  of icNone:
    discard
