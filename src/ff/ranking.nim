# src/ff/ranking.nim
import std/[times, algorithm]
import core, cli


proc depthScore*(path: string): int =
  ## count directory depth (lower is better)
  result = 0
  for ch in path:
    if ch == '/': inc result

proc recencyScore*(mtime: Time): int =
  ## recent files get lower scores
  let age = getTime() - mtime
  let hours = age.inHours
  
  if hours < 1: return 0
  elif hours < 24: return 1
  elif hours < 168: return 2  # 1 week
  else: return 3

proc computeRankScore*(m: MatchResult; cfg: Config): int =
  ## combined ranking score (lower is better) ill stop saying lower is better i promise
  result = 0
  
  case cfg.rankMode
  of rmScore:
    result = m.fuzzyScore
  of rmDepth:
    result = depthScore(m.relPath) * 10
  of rmRecency:
    result = recencyScore(m.mtime) * 10
  of rmAuto:
    # combine multiple factors
    result = m.fuzzyScore
    if cfg.rankDepth:
      result += depthScore(m.relPath) * 2
    if cfg.rankRecency:
      result += recencyScore(m.mtime) * 3
  of rmNone:
    result = 0

proc rankMatches*(matches: var seq[MatchResult]; cfg: Config) =
  if cfg.rankMode == rmNone: return
  
  for i in 0 ..< matches.len:
    matches[i].fuzzyScore = computeRankScore(matches[i], cfg)
  
  matches.sort(proc(a, b: MatchResult): int =
    cmp(a.fuzzyScore, b.fuzzyScore)
  )
