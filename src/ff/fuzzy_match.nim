## Optimized fuzzy matching - lower scores are better

proc fuzzyMatch*(pattern: string; text: string): int =
  if pattern.len == 0: return 0
  if text.len == 0: return -1
  if pattern.len > text.len: return -1
  
  let patLen = pattern.len
  let textLen = text.len
  
  if patLen <= 5:
    for pc in pattern:
      var found = false
      for tc in text:
        if tc == pc:
          found = true
          break
      if not found: return -1
  
  var patIdx = 0
  var textIdx = 0
  var score = 0
  var lastMatchIdx = -1
  
  while textIdx < textLen:
    if textLen - textIdx < patLen - patIdx:
      return -1
    
    if text[textIdx] == pattern[patIdx]:
      if lastMatchIdx >= 0:
        let gap = textIdx - lastMatchIdx - 1
        if gap == 0:
          score -= 2
        else:
          score += gap
      
      if textIdx == 0:
        score -= 5
      else:
        let prev = text[textIdx - 1]
        if prev == '/' or prev == '_' or prev == '-' or prev == ' ' or prev == '.':
          score -= 5
        elif textIdx < textLen and text[textIdx] in {'A'..'Z'} and prev in {'a'..'z'}:
          score -= 3
      
      lastMatchIdx = textIdx
      inc patIdx
      if patIdx >= patLen: break
    
    inc textIdx
  
  if patIdx < patLen: return -1
  
  for ch in text:
    if ch == '/': score += 3
  score += text.len shr 2
  
  if score < 1: 1 else: score

proc fuzzyMatchMulti*(patterns: seq[string]; text: string): tuple[matched: bool, score: int] =
  result.matched = false
  result.score = 999999
  for pat in patterns:
    let s = fuzzyMatch(pat, text)
    if s >= 0:
      result.matched = true
      if s < result.score: result.score = s
