# src/fastfind.nim
import std/[times, os, strutils, algorithm, osproc, json]
import ff/[cli, search, output, core, fuzzy, matchers, interactive, index, gitops, ranking, semantic]


proc sortMatches(cfg: Config; ms: var seq[MatchResult]) =
  if cfg.sortKey == skNone and not cfg.fuzzyMode and cfg.rankMode == rmNone: return
  
  if cfg.fuzzyMode or cfg.rankMode != rmNone:
    # apply ranking scores
    rankMatches(ms, cfg)
    
    ms.sort(proc(a, b: MatchResult): int = 
      let cmp = cmp(a.fuzzyScore, b.fuzzyScore)
      if cmp != 0: return cmp
      case cfg.sortKey
      of skPath: cmp(a.relPath, b.relPath)
      of skName: cmp(a.name, b.name)
      of skSize: cmp(a.size, b.size)
      of skTime: cmp(a.mtime.toUnix, b.mtime.toUnix)
      of skNone: 0
    )
  else:
    case cfg.sortKey
    of skPath:
      ms.sort(proc(a, b: MatchResult): int = cmp(a.relPath, b.relPath))
    of skName:
      ms.sort(proc(a, b: MatchResult): int = cmp(a.name, b.name))
    of skSize:
      ms.sort(proc(a, b: MatchResult): int = cmp(a.size, b.size))
    of skTime:
      ms.sort(proc(a, b: MatchResult): int = cmp(a.mtime.toUnix, b.mtime.toUnix))
    of skNone:
      discard
      
  if cfg.reverse:
    ms.reverse()

proc modeStr(cfg: Config): string =
  case cfg.matchMode
  of mmGlob:  "glob"
  of mmRegex: "regex"
  of mmFixed: "fixed"
  of mmFuzzy: "fuzzy"

proc pickIndex(ms: seq[MatchResult]): int =
  if ms.len == 0: return -1
  stdout.writeLine("Pick a result (1-" & $ms.len & "), or 0 to cancel:")
  for i, m in ms:
    if i >= 50:
      stdout.writeLine("... (" & $(ms.len - 50) & " more)")
      break
    stdout.writeLine($(i + 1) & ") " & m.relPath)
  stdout.write("> ")
  stdout.flushFile()

  try:
    let line = stdin.readLine().strip()
    if line.len == 0: return -1
    let n = parseInt(line)
    if n <= 0 or n > ms.len: return -1
    return n - 1
  except CatchableError:
    return -1

proc applyPlaceholders(s: string; path: string): string =
  s.replace("{}", path)

proc runExec(cfg: Config; m: MatchResult): int =
  if cfg.execCmd.len == 0: return 0
  let p = outPath(cfg, m)

  if cfg.execShell:
    var parts: seq[string] = @[applyPlaceholders(cfg.execCmd, p)]
    for a in cfg.execArgs:
      parts.add(applyPlaceholders(a, p))
    let line = parts.join(" ")
    return execCmd(line)
  else:
    var args: seq[string] = @[]
    for a in cfg.execArgs:
      args.add(applyPlaceholders(a, p))
    try:
      let pr = startProcess(cfg.execCmd, args = args, options = {poUsePath})
      let code = pr.waitForExit()
      pr.close()
      return code
    except CatchableError:
      return 127

proc emitOne*(cfg: Config; m: MatchResult) =
  case cfg.outputMode
  of omPlain:
    stdout.writeLine(outPath(cfg, m))

  of omLong:
    var line = $kindChar(m.kind) & " " &
               align($(m.size), 10) & " " &
               fmtTime(m.mtime) & " " &
               outPath(cfg, m)
    if cfg.fuzzyMode and cfg.showFuzzyScore:
      line &= " [" & $m.fuzzyScore & "]"
    if m.lineNumber > 0:
      line &= ":" & $m.lineNumber
    stdout.writeLine(line)

  of omJson, omNdJson:
    var o = newJObject()
    o["path"] = %outPath(cfg, m)
    o["absPath"] = %m.absPath
    o["relPath"] = %m.relPath
    o["name"] = %m.name
    o["size"] = %m.size
    o["kind"] = %($(m.kind))
    o["mtime"] = %fmtTime(m.mtime)
    if cfg.fuzzyMode and cfg.showFuzzyScore:
      o["fuzzyScore"] = %m.fuzzyScore
    if m.lineNumber > 0:
      o["lineNumber"] = %m.lineNumber
    stdout.writeLine($o)
    
  of omTable:
    discard

proc runSemanticSearch(cfg: Config): seq[MatchResult] =
  result = @[]
  
  var symbolType = symAny
  var symbolName = ""
  
  if cfg.searchFunction.len > 0:
    symbolType = symFunction
    symbolName = cfg.searchFunction
  elif cfg.searchClass.len > 0:
    symbolType = symClass
    symbolName = cfg.searchClass
  elif cfg.searchSymbol.len > 0:
    symbolType = symAny
    symbolName = cfg.searchSymbol
  else:
    return
  
  for rootPath in cfg.paths:
    let rootAbs = absolutePath(rootPath)
    let matches = searchDirectoryForSymbols(rootAbs, symbolName, symbolType,
                                            cfg.ignoreCase, 
                                            if cfg.limit > 0: cfg.limit else: 100)
    
    for sm in matches:
      var m: MatchResult
      m.absPath = sm.file
      m.path = sm.file
      m.relPath = safeRelPath(sm.file, rootAbs)
      m.name = extractFilename(sm.file) & ":" & $sm.line & " " & sm.symbolName
      m.lineNumber = sm.line
      
      try:
        let info = getFileInfo(sm.file)
        m.size = info.size
        m.mtime = info.lastWriteTime
      except CatchableError:
        discard
      
      m.kind = etFile
      result.add(m)

when isMainModule:
  let cfg = parseCli(commandLineParams())
  let autoThreads = if cfg.threads > 0: cfg.threads else: 1

  # handle index management commands
  if cfg.indexCommand != icNone:
    handleIndexCommand(cfg)
    quit(0)

  # interactive mode
  if cfg.interactiveMode:
    runInteractive(cfg)
    quit(0)

  # semantic search mode
  if cfg.searchFunction.len > 0 or cfg.searchClass.len > 0 or cfg.searchSymbol.len > 0:
    var matches = runSemanticSearch(cfg)
    
    if matches.len == 0:
      let searchTerm = if cfg.searchFunction.len > 0: cfg.searchFunction
                       elif cfg.searchClass.len > 0: cfg.searchClass
                       else: cfg.searchSymbol
      stderr.writeLine("fastfind: no symbols found matching: " & searchTerm)
      quit(1)
    
    sortMatches(cfg, matches)
    
    if cfg.limit > 0 and matches.len > cfg.limit:
      matches.setLen(cfg.limit)
    
    emitResults(cfg, matches, Stats())
    quit(0)

  let needsCollect =
    cfg.outputMode in [omJson, omTable] or
    cfg.sortKey != skNone or
    cfg.selectMode or
    autoThreads > 1 or
    cfg.fuzzyMode or
    cfg.rankMode != rmNone or
    cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged or
    (cfg.execCmd.len > 0)

  let pat0 = (if cfg.patterns.len > 0: cfg.patterns[0] else: "")

  if needsCollect:
    var res: SearchResult
    
    # ttry index first if enabled
    if cfg.useIndex and indexExists():
      res = searchIndex(cfg)
      if res.matches.len == 0 and not cfg.indexOnly:
        res = runSearchCollect(cfg)
    else:
      res = runSearchCollect(cfg)
    
    var matches = res.matches

    # apply git filters
    if cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged:
      applyGitFilters(cfg, matches)

    if matches.len == 0:
      if cfg.naturalQuery.len > 0:
        printNoMatchesNL(cfg.naturalQuery, if cfg.paths.len > 0: cfg.paths[0] else: ".")
      elif pat0.len > 0:
        printNoMatchesHint(pat0, modeStr(cfg))
      emitStatsIfNeeded(cfg, res.stats)
      quit(1)

    sortMatches(cfg, matches)

    if cfg.limit > 0 and matches.len > cfg.limit:
      matches.setLen(cfg.limit)

    if cfg.selectMode:
      let idx = pickIndex(matches)
      if idx < 0: quit(1)

      let chosen = matches[idx]
      if cfg.execCmd.len > 0:
        let code = runExec(cfg, chosen)
        if code != 0: quit(code)
      else:
        stdout.writeLine(outPath(cfg, chosen))
    else:
      emitResults(cfg, matches, res.stats)


  else:
    var matched = 0
    let stats =
      if cfg.outputMode == omPlain:
        runSearchStreamPaths(cfg,
          proc(p: string) =
            inc matched
            stdout.writeLine(p)
        )
      else:
        runSearchStream(cfg,
          proc(m: MatchResult) =
            inc matched
            emitOne(cfg, m)
        )

    if matched == 0:
      if cfg.naturalQuery.len > 0:
        printNoMatchesNL(cfg.naturalQuery, if cfg.paths.len > 0: cfg.paths[0] else: ".")
      elif pat0.len > 0:
        printNoMatchesHint(pat0, modeStr(cfg))
      emitStatsIfNeeded(cfg, stats)
      quit(1)

    emitStatsIfNeeded(cfg, stats)
