# src/ff/output.nim
import std/[times, strutils, json]
import cli, core, ansi


proc fmtTime*(t: Time): string =
  try:
    result = t.format("yyyy-MM-dd HH:mm:ss")
  except CatchableError:
    result = $t

proc outPath*(cfg: Config; m: MatchResult): string =
  if cfg.absolute: return m.absPath
  if cfg.relative: return m.relPath
  return m.path

proc emitStatsIfNeeded*(cfg: Config; stats: Stats) =
  if not cfg.stats: return
  stderr.writeLine("fastfind stats:")
  stderr.writeLine("  visited:      " & $stats.visited)
  stderr.writeLine("  matched:      " & $stats.matched)
  stderr.writeLine("  skipped:      " & $stats.skipped)
  stderr.writeLine("  errors:       " & $stats.errors)
  if stats.bytesRead > 0:
    stderr.writeLine("  bytesRead:    " & $stats.bytesRead)
  if stats.endTime != stats.startTime:
    let ms = (stats.endTime - stats.startTime).inMilliseconds
    stderr.writeLine("  elapsed:      " & $ms & " ms")

proc kindChar*(k: EntryType): char =
  case k
  of etFile: 'f'
  of etDir:  'd'
  of etLink: 'l'

proc emitResults*(cfg: Config; matches: seq[MatchResult]; stats: Stats) =
  case cfg.outputMode
  of omPlain:
    for m in matches:
      stdout.writeLine(outPath(cfg, m))
      
  of omLong:
    for m in matches:
      var line = $kindChar(m.kind) & " " &
                 align($m.size, 10) & " " &
                 fmtTime(m.mtime) & " " &
                 outPath(cfg, m)
      if cfg.fuzzyMode and cfg.showFuzzyScore:
        line &= " [" & $m.fuzzyScore & "]"
      stdout.writeLine(line)
      
  of omJson:
    var arr = newJArray()
    for m in matches:
      var o = newJObject()
      o["path"] = %outPath(cfg, m)
      o["absPath"] = %m.absPath
      o["relPath"] = %m.relPath
      o["name"] = %m.name
      o["size"] = %m.size
      o["kind"] = %($m.kind)
      o["mtime"] = %fmtTime(m.mtime)
      if cfg.fuzzyMode and cfg.showFuzzyScore:
        o["fuzzyScore"] = %m.fuzzyScore
      arr.add(o)
    stdout.writeLine($arr)
    
  of omNdJson:
    for m in matches:
      var o = newJObject()
      o["path"] = %outPath(cfg, m)
      o["absPath"] = %m.absPath
      o["relPath"] = %m.relPath
      o["name"] = %m.name
      o["size"] = %m.size
      o["kind"] = %($m.kind)
      o["mtime"] = %fmtTime(m.mtime)
      if cfg.fuzzyMode and cfg.showFuzzyScore:
        o["fuzzyScore"] = %m.fuzzyScore
      stdout.writeLine($o)
      
  of omTable:
    # table header
    let useColor = supportsColor(cfg.colorMode)
    stdout.writeLine(b("TYPE", useColor) & " | " &
                    b("SIZE", useColor) & " | " &
                    b("MODIFIED", useColor) & " | " &
                    b("PATH", useColor))
    stdout.writeLine("-" & repeat("-", 70))
    
    for m in matches:
      let kindStr = padRight($kindChar(m.kind), 4)
      let sizeStr = align($m.size, 10)
      let timeStr = fmtTime(m.mtime)
      stdout.writeLine(kindStr & " | " & sizeStr & " | " & timeStr & " | " & outPath(cfg, m))

  emitStatsIfNeeded(cfg, stats)
