# src/fastfind.nim
import std/[times, os, strutils, algorithm, osproc, json]
import ff/[cli, search, output, core, fuzzy, matchers, interactive, index, gitops, ranking, semantic, ansi]


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

proc applyShellPlaceholders(s: string; path: string): string =
  s.replace("{}", quoteShell(path))

proc runExec(cfg: Config; m: MatchResult): int =
  if cfg.execCmd.len == 0: return 0
  let p = m.absPath

  if cfg.execShell:
    var parts: seq[string] = @[applyShellPlaceholders(cfg.execCmd, p)]
    for a in cfg.execArgs:
      parts.add(applyShellPlaceholders(a, p))
    let line = parts.join(" ")
    return execCmd(line)
  else:
    var args: seq[string] = @[]
    if cfg.execArgs.len == 0:
      args.add(p)
    else:
      for a in cfg.execArgs:
        args.add(applyPlaceholders(a, p))
    try:
      let pr = startProcess(cfg.execCmd, args = args, options = {poUsePath, poParentStreams})
      let code = pr.waitForExit()
      pr.close()
      return code
    except CatchableError:
      return 127

proc emitOne*(cfg: Config; m: MatchResult) =
  case cfg.outputMode
  of omPlain:
    stdout.write(printedPath(cfg, m))
    stdout.write(if cfg.print0: '\0' else: '\n')

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
                                            if cfg.limit > 0: cfg.limit else: 100,
                                            cfg.includeHidden, cfg.excludes)
    
    for sm in matches:
      var m: MatchResult
      m.absPath = sm.file
      m.path = sm.file
      m.relPath = safeRelPath(sm.file, rootAbs)
      m.path = m.relPath
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

proc canUseIndexSearch(cfg: Config): bool =
  cfg.useIndex and indexExists() and indexCovers(cfg.paths) and
  cfg.containsText.len == 0 and cfg.containsRegex.len == 0 and
  not cfg.useGitignore and not cfg.oneFileSystem and not cfg.followSymlinks

when isMainModule:
  let cfg = parseCli(commandLineParams())
  let autoThreads = if cfg.threads > 0: cfg.threads else: 1

  if cfg.explainQuery:
    printQueryPlan(cfg)
    quit(0)

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
    
    if cfg.countOnly:
      stdout.writeLine($matches.len)
      emitStatsIfNeeded(cfg, Stats())
      quit(0)

    if matches.len == 0:
      let searchTerm = if cfg.searchFunction.len > 0: cfg.searchFunction
                       elif cfg.searchClass.len > 0: cfg.searchClass
                       else: cfg.searchSymbol
      if not cfg.quietErrors:
        stderr.writeLine("fastfind: no symbols found matching: " & searchTerm)
      quit(1)
    
    sortMatches(cfg, matches)
    
    if cfg.limit > 0 and matches.len > cfg.limit:
      matches.setLen(cfg.limit)
    
    let exitCode = emitResults(cfg, matches, Stats())
    quit(exitCode)

  let needsCollect =
    cfg.outputMode in [omJson, omTable] or
    cfg.sortKey != skNone or
    cfg.selectMode or
    # Threads earn their keep during content scans. For path-only searches,
    # the lighter POSIX walk is faster even when -j is set.
    (autoThreads > 1 and
      (cfg.containsText.len > 0 or cfg.containsRegex.len > 0)) or
    cfg.fuzzyMode or
    cfg.rankMode != rmNone or
    cfg.useIndex or
    cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged or
    (cfg.execCmd.len > 0)

  let pat0 = (if cfg.patterns.len > 0: cfg.patterns[0] else: "")

  if needsCollect:
    var res: SearchResult
    var searchCfg = cfg
    if cfg.sortKey != skNone or cfg.fuzzyMode or cfg.rankMode != rmNone:
      searchCfg.limit = 0
    if cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged:
      searchCfg.countOnly = false
    
    # ttry index first if enabled
    if canUseIndexSearch(searchCfg):
      res = searchIndex(searchCfg)
      if res.stats.errors > 0:
        if cfg.indexOnly:
          stderr.writeLine("fastfind: index is corrupt; rebuild it with --update-index")
          quit(2)
        res = runSearchCollect(searchCfg)
    elif cfg.indexOnly:
      stderr.writeLine("fastfind: no compatible index covers the requested path")
      quit(2)
    else:
      res = runSearchCollect(searchCfg)
    
    var matches = res.matches

    # apply git filters
    if cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged:
      applyGitFilters(cfg, matches)

    if cfg.countOnly:
      stdout.writeLine(if canUseIndexSearch(searchCfg): $res.stats.matched else: $matches.len)
      emitStatsIfNeeded(cfg, res.stats)
      quit(0)

    if matches.len == 0:
      if not cfg.quietErrors:
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
      let exitCode = emitResults(cfg, matches, res.stats)
      if exitCode != 0: quit(exitCode)


  else:
    var matched = 0
    var outputBuf = newStringOfCap(262144)
    let stats =
      if cfg.outputMode == omPlain:
        runSearchStreamPaths(cfg,
          proc(p: string) =
            if cfg.countOnly:
              discard
            else:
              inc matched
              outputBuf.add(terminalText(p, cfg.print0))
              outputBuf.add(if cfg.print0: '\0' else: '\n')
              if outputBuf.len > 262140:
                stdout.write(outputBuf)
                outputBuf.setLen(0)
        )
      else:
        runSearchStream(cfg,
          proc(m: MatchResult) =
            if cfg.countOnly:
              discard
            else:
              inc matched
              emitOne(cfg, m)
        )

    if cfg.countOnly:
      matched = stats.matched
      stdout.writeLine($matched)
      emitStatsIfNeeded(cfg, stats)
      quit(0)

    if outputBuf.len > 0:
      stdout.write(outputBuf)

    if matched == 0:
      if not cfg.quietErrors:
        if cfg.naturalQuery.len > 0:
          printNoMatchesNL(cfg.naturalQuery, if cfg.paths.len > 0: cfg.paths[0] else: ".")
        elif pat0.len > 0:
          printNoMatchesHint(pat0, modeStr(cfg))
      emitStatsIfNeeded(cfg, stats)
      quit(1)

    emitStatsIfNeeded(cfg, stats)
