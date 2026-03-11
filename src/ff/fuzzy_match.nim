# src/ff/fuzzy_match.nim
## lightweight fuzzy matching with scoring
## lower scores are better

import std/strutils

proc fuzzyMatch*(pattern: string; text: string): int =
  ## reutrns match score (lower is better), or -1 if no match
  ## scoring favors:
  ## - contiguous matches
  ## - matches at word boundaries
  ## - shorter overall distance
  
  if pattern.len == 0: return 0
  if text.len == 0: return -1
  
  var patIdx = 0
  var textIdx = 0
  var score = 0
  var lastMatchIdx = -1
  var consecutiveMatches = 0
  
  while textIdx < text.len and patIdx < pattern.len:
    if text[textIdx] == pattern[patIdx]:
      # match found
      if lastMatchIdx >= 0:
        let gap = textIdx - lastMatchIdx - 1
        if gap == 0:
          # consecutive match, bonus
          inc consecutiveMatches
          score -= 2
        else:
          # gap penalty
          score += gap
          consecutiveMatches = 0
      
      # word boundary bonus
      if textIdx == 0 or text[textIdx - 1] in ['/', '_', '-', ' ', '.']:
        score -= 5
      
      # u[percase after lowercase bonus (camelCase)
      if textIdx > 0 and text[textIdx].isUpperAscii and text[textIdx - 1].isLowerAscii:
        score -= 3
      
      lastMatchIdx = textIdx
      inc patIdx
    
    inc textIdx
  
  if patIdx < pattern.len:
    # didnt match all pattern chars
    return -1
  
  # depth penalty (count directory separators)
  var depth = 0
  for ch in text:
    if ch == '/': inc depth
  score += depth * 3
  
  # length penalty (favor shorter paths)
  score += text.len div 4
  
  result = max(0, score)

proc fuzzyMatchMulti*(patterns: seq[string]; text: string): tuple[matched: bool, score: int] =
  ## match against multiple patterns, return best score
  result.matched = false
  result.score = 999999
  
  for pat in patterns:
    let s = fuzzyMatch(pat, text)
    if s >= 0:
      result.matched = true
      if s < result.score:
        result.score = s
