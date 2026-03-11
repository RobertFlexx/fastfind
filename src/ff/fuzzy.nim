# src/ff/fuzzy.nim
import std/[strutils, sequtils, algorithm]

type
  Suggestion* = object
    text*: string
    score*: int  # lower is better fr

proc levenshtein(a, b: string): int =
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  var prev = newSeq[int](b.len + 1)
  var cur  = newSeq[int](b.len + 1)
  for j in 0..b.len: prev[j] = j
  for i in 1..a.len:
    cur[0] = i
    let ca = a[i-1]
    for j in 1..b.len:
      let cb = b[j-1]
      let cost = (if ca == cb: 0 else: 1)
      cur[j] = min(min(prev[j] + 1, cur[j-1] + 1), prev[j-1] + cost)
    swap(prev, cur)
  result = prev[b.len]

proc suggestClosest*(needle: string; candidates: seq[string]; limit = 3): seq[Suggestion] =
  let n = needle.toLowerAscii()
  var scored: seq[Suggestion] = @[]
  for c in candidates:
    let cc = c.toLowerAscii()
    let d = levenshtein(n, cc)
    scored.add(Suggestion(text: c, score: d))
  scored.sort(proc(x, y: Suggestion): int = cmp(x.score, y.score))
  result = scored[0 ..< min(limit, scored.len)]

proc niceError*(msg: string) =
  stderr.writeLine("fastfind: " & msg)
  stderr.writeLine("Try 'fastfind --help' for more information.")

proc printUnknownOption*(badOpt: string; knownLong: seq[string]) =
  niceError("unknown option: " & badOpt)
  var key = badOpt
  while key.startsWith("-"): key = key[1..^1]
  let cands = knownLong.mapIt("--" & it)
  let sugg = suggestClosest("--" & key, cands, 3)
  if sugg.len > 0 and sugg[0].score <= 4:
    stderr.write("Did you mean: ")
    stderr.writeLine(sugg.mapIt(it.text).join(", ") & " ?")

proc printUnknownShort*(badOpt: string; knownShort: seq[string]) =
  niceError("unknown option: " & badOpt)
  let sugg = suggestClosest(badOpt, knownShort.mapIt("-" & it), 3)
  if sugg.len > 0 and sugg[0].score <= 2:
    stderr.write("Did you mean: ")
    stderr.writeLine(sugg.mapIt(it.text).join(", ") & " ?")

proc printNoMatchesHint*(pattern: string; mode: string) =
  stderr.writeLine("fastfind: no matches found for " & pattern)
  case mode
  of "glob":
    stderr.writeLine("Tip: glob matches filenames. For substring matching, try: --fixed --full-path")
  of "regex":
    stderr.writeLine("Tip: if you meant literal text, try: --fixed")
  of "fixed":
    stderr.writeLine("Tip: if you meant a glob like *.rb, remove --fixed (glob is default).")
  else:
    discard
