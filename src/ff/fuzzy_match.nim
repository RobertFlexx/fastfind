## Fuzzy matching - lower scores are better.

import std/strutils

proc isSep(c: char): bool {.inline.} =
  c == '/' or c == '\\' or c == '_' or c == '-' or c == ' ' or c == '.'

proc charBonus(text: string; idx: int): int {.inline.} =
  if idx == 0:
    return -18
  let prev = text[idx - 1]
  if isSep(prev):
    return -16
  if text[idx] in {'A'..'Z'} and prev in {'a'..'z'}:
    return -12
  0

proc fuzzyMatch*(pattern: string; text: string): int =
  if pattern.len == 0: return 0
  if text.len == 0: return -1
  if pattern.len > text.len: return -1

  let patLen = pattern.len
  let textLen = text.len
  var bestScore = high(int) div 8
  var start = 0
  while start < textLen:
    if text[start] != pattern[0]:
      inc start
      continue

    var patIdx = 1
    var textIdx = start + 1
    var lastMatch = start
    var score = start * 2 + charBonus(text, start)

    while patIdx < patLen and textIdx < textLen:
      if text[textIdx] == pattern[patIdx]:
        let gap = textIdx - lastMatch - 1
        if gap == 0:
          score -= 10
        else:
          score += gap * 3
        score += charBonus(text, textIdx)
        lastMatch = textIdx
        inc patIdx
      inc textIdx

    if patIdx == patLen:
      score += (textLen - patLen)
      for ch in text:
        if ch == '/' or ch == '\\': score += 4

      if textLen == patLen:
        score -= 24
      elif text.startsWith(pattern):
        score -= 14

      if score < bestScore:
        bestScore = score

    inc start

  if bestScore == high(int) div 8: return -1

  bestScore + 100

proc fuzzyMatchMulti*(patterns: seq[string]; text: string): tuple[matched: bool, score: int] =
  result.matched = false
  result.score = 999999
  for pat in patterns:
    let s = fuzzyMatch(pat, text)
    if s >= 0:
      result.matched = true
      if s < result.score: result.score = s
