import std/[times, strutils, json, osproc, os]
import cli, core, ansi

const
  TableDivider = "-".repeat(78)

proc fmtTime*(t: Time): string =
  try:
    t.format("yyyy-MM-dd HH:mm:ss")
  except CatchableError:
    $t

proc outPath*(cfg: Config; m: MatchResult): string =
  if cfg.absolute: m.absPath
  elif cfg.relative: m.relPath
  else: m.path

proc printedPath*(cfg: Config; m: MatchResult): string =
  terminalText(outPath(cfg, m), cfg.print0)

proc kindChar*(k: EntryType): char =
  case k
  of etFile: 'f'
  of etDir:  'd'
  of etLink: 'l'

proc isCodeSearch*(cfg: Config): bool =
  cfg.searchFunction.len > 0 or cfg.searchClass.len > 0 or cfg.searchSymbol.len > 0

proc codeSearchType*(cfg: Config): string =
  if cfg.searchFunction.len > 0: "function"
  elif cfg.searchClass.len > 0: "class"
  elif cfg.searchSymbol.len > 0: "symbol"
  else: ""

proc codeSearchTarget*(cfg: Config): string =
  if cfg.searchFunction.len > 0: cfg.searchFunction
  elif cfg.searchClass.len > 0: cfg.searchClass
  elif cfg.searchSymbol.len > 0: cfg.searchSymbol
  else: ""

proc toJson(cfg: Config; m: MatchResult): JsonNode =
  result = %*{
    "path": outPath(cfg, m),
    "absPath": m.absPath,
    "relPath": m.relPath,
    "name": m.name,
    "size": m.size,
    "kind": $m.kind,
    "mtime": fmtTime(m.mtime)
  }
  if cfg.fuzzyMode and cfg.showFuzzyScore:
    result["fuzzyScore"] = %m.fuzzyScore
  if isCodeSearch(cfg):
    result["searchType"] = %codeSearchType(cfg)
    result["searchTarget"] = %codeSearchTarget(cfg)
    if m.lineNumber > 0:
      result["line"] = %m.lineNumber

proc emitStatsIfNeeded*(cfg: Config; stats: Stats) =
  if not cfg.stats:
    return
  stderr.writeLine "fastfind stats:"
  stderr.writeLine "  visited:      " & $stats.visited
  stderr.writeLine "  matched:      " & $stats.matched
  stderr.writeLine "  skipped:      " & $stats.skipped
  stderr.writeLine "  errors:       " & $stats.errors
  if stats.bytesRead > 0:
    stderr.writeLine "  bytesRead:    " & $stats.bytesRead
  if stats.endTime != stats.startTime:
    let ms = (stats.endTime - stats.startTime).inMilliseconds
    stderr.writeLine "  elapsed:      " & $ms & " ms"

proc execForMatches(cfg: Config; matches: seq[MatchResult]): int =
  result = 0
  for m in matches:
    let path = m.absPath
    var code = 0
    if cfg.execShell:
      var parts: seq[string] = @[cfg.execCmd.replace("{}", quoteShell(path))]
      for a in cfg.execArgs:
        parts.add(a.replace("{}", quoteShell(path)))
      code = execShellCmd(parts.join(" "))
    else:
      var args: seq[string] = @[]
      if cfg.execArgs.len == 0:
        args.add(path)
      else:
        for a in cfg.execArgs:
          args.add(a.replace("{}", path))
      try:
        let pr = startProcess(cfg.execCmd, args = args, options = {poUsePath, poParentStreams})
        code = pr.waitForExit()
        pr.close()
      except CatchableError:
        code = 127
    if code != 0:
      result = code
      if cfg.verbose:
        stderr.writeLine "fastfind: exit " & $code & ": " & cfg.execCmd

proc fmtCodeMatch(cfg: Config; m: MatchResult; colored: bool): string =
  let t = codeSearchType(cfg)
  let target = codeSearchTarget(cfg)
  if m.lineNumber > 0:
    result = c(t & ":", Cyan, colored) & target & c(":" & $m.lineNumber, Yellow, colored)
  else:
    result = c(t & ":", Cyan, colored) & target

proc emitPlain(cfg: Config; matches: seq[MatchResult]) =
  let showCode = isCodeSearch(cfg)
  for m in matches:
    let terminator = if cfg.print0: '\0' else: '\n'
    if showCode and m.lineNumber > 0:
      stdout.write(printedPath(cfg, m) & ":" & $m.lineNumber & terminator)
    else:
      stdout.write(printedPath(cfg, m) & terminator)

proc emitLong(cfg: Config; matches: seq[MatchResult]) =
  let showCode = isCodeSearch(cfg)
  let colored = supportsColor(cfg.colorMode)
  for m in matches:
    var line = $kindChar(m.kind) & " " &
               align($m.size, 10) & " " &
               fmtTime(m.mtime) & " " &
               printedPath(cfg, m)
    if m.lineNumber > 0:
      line &= c(":" & $m.lineNumber, Yellow, colored)
    if cfg.fuzzyMode and cfg.showFuzzyScore:
      line &= " [" & $m.fuzzyScore & "]"
    if showCode:
      line &= " " & fmtCodeMatch(cfg, m, colored)
    stdout.writeLine line

proc emitJson(cfg: Config; matches: seq[MatchResult]) =
  # Write the array as we go instead of keeping a second copy of every result.
  stdout.write('[')
  for i, m in matches:
    if i > 0: stdout.write(',')
    stdout.write($cfg.toJson(m))
  stdout.writeLine("]")

proc emitNdJson(cfg: Config; matches: seq[MatchResult]) =
  for m in matches:
    stdout.writeLine $cfg.toJson(m)

proc emitTable(cfg: Config; matches: seq[MatchResult]) =
  let colored = supportsColor(cfg.colorMode)
  let showCode = isCodeSearch(cfg)
  
  var header = b("TYPE", colored) & " | " &
               b("SIZE", colored) & " | " &
               b("MODIFIED", colored) & " | " &
               b("PATH", colored)
  if showCode:
    header &= " | " & b("LINE", colored) & " | " & b("MATCH", colored)
  stdout.writeLine header
  stdout.writeLine TableDivider
  
  for m in matches:
    var line = padRight($kindChar(m.kind), 4) & " | " &
               align($m.size, 10) & " | " &
               fmtTime(m.mtime) & " | " &
               printedPath(cfg, m)
    if showCode:
      let lineStr = if m.lineNumber > 0: $m.lineNumber else: "-"
      line &= " | " & align(lineStr, 4) & " | " & codeSearchType(cfg) & ":" & codeSearchTarget(cfg)
    stdout.writeLine line

proc emitResults*(cfg: Config; matches: seq[MatchResult]; stats: Stats): int =
  if cfg.countOnly:
    stdout.writeLine($matches.len)
    emitStatsIfNeeded(cfg, stats)
    return 0

  if cfg.execCmd.len > 0:
    result = execForMatches(cfg, matches)
    emitStatsIfNeeded(cfg, stats)
    return
  
  case cfg.outputMode
  of omPlain:  emitPlain(cfg, matches)
  of omLong:   emitLong(cfg, matches)
  of omJson:   emitJson(cfg, matches)
  of omNdJson: emitNdJson(cfg, matches)
  of omTable:  emitTable(cfg, matches)
  
  emitStatsIfNeeded(cfg, stats)
