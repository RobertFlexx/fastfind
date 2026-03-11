# src/ff/nlp.nim
## natural language query parser
## converts human readable queries to filter parameters

import std/[strutils, times, options]
import core, units, matchers

type
  ParsedQuery* = object
    patterns*: seq[string]
    minSize*: int64
    maxSize*: int64
    newerThan*: Option[Time]
    olderThan*: Option[Time]
    types*: set[EntryType]
    containsText*: string
    extensions*: seq[string]
    excludePatterns*: seq[string]
    inDirectory*: string
    matchMode*: MatchMode

const
  SizeWordsTable = [
    ("larger", ">"), ("bigger", ">"), ("greater", ">"), ("more", ">"),
    ("over", ">"), ("above", ">"), ("smaller", "<"), ("less", "<"),
    ("under", "<"), ("below", "<"), ("exactly", "="), ("equal", "=")
  ]
  
  TimeWordsTable = [
    ("today", 0), ("yesterday", 1), ("week", 7), ("month", 30), ("year", 365)
  ]
  
  TypeWordsFile = ["file", "files"]
  TypeWordsDir = ["directory", "directories", "folder", "folders", "dir", "dirs"]
  TypeWordsLink = ["link", "links", "symlink", "symlinks"]

proc getSizeOp(word: string): string =
  for (k, v) in SizeWordsTable:
    if k == word:
      return v
  return ""

proc getTimeDays(word: string): int =
  for (k, v) in TimeWordsTable:
    if k == word:
      return v
  return -1

proc isNaturalLanguageQuery*(query: string): bool =
  ## heuristic to detect if a query looks like natural language
  let words = query.toLowerAscii().split()
  
  let nlWords = ["files", "directories", "folders", "larger", "smaller", 
                 "modified", "containing", "named", "today", "yesterday",
                 "than", "within", "ago", "images", "videos", "documents"]
  
  var nlCount = 0
  for word in words:
    if word in nlWords:
      inc nlCount
  
  return nlCount >= 1 and words.len >= 2

proc parseNaturalQuery*(query: string): ParsedQuery =
  ## parse a natural language query into structured filters
  
  result = ParsedQuery()
  result.minSize = -1
  result.maxSize = -1
  result.newerThan = none(Time)
  result.olderThan = none(Time)
  result.types = {}
  result.matchMode = mmGlob
  
  let words = query.toLowerAscii().split()
  var idx = 0
  
  while idx < words.len:
    let word = words[idx]
    
    # type words, files
    if word in TypeWordsFile:
      result.types.incl(etFile)
      inc idx
      continue
    
    # type words, directories
    if word in TypeWordsDir:
      result.types.incl(etDir)
      inc idx
      continue
    
    # type words, links
    if word in TypeWordsLink:
      result.types.incl(etLink)
      inc idx
      continue
    
    # size expressions
    let sizeOp = getSizeOp(word)
    if sizeOp.len > 0:
      inc idx
      if idx < words.len and words[idx] == "than":
        inc idx
      if idx < words.len:
        try:
          let bytes = parseBytes(words[idx])
          if sizeOp == ">":
            result.minSize = bytes + 1
          elif sizeOp == "<":
            result.maxSize = bytes - 1
          else:
            result.minSize = bytes
            result.maxSize = bytes
          inc idx
        except CatchableError:
          discard
      continue
    
    # time expressions
    if word in ["modified", "changed", "updated"]:
      inc idx
      if idx < words.len and words[idx] in ["within", "in", "last"]:
        inc idx
      if idx < words.len and words[idx] == "the":
        inc idx
      if idx < words.len:
        let timeWord = words[idx]
        let days = getTimeDays(timeWord)
        if days >= 0:
          result.newerThan = some(getTime() - initDuration(days = days))
          inc idx
          continue
        # try parsing "X days"
        try:
          let num = parseInt(timeWord)
          inc idx
          if idx < words.len:
            let unit = words[idx]
            if unit in ["day", "days", "d"]:
              result.newerThan = some(getTime() - initDuration(days = num))
              inc idx
            elif unit in ["hour", "hours", "h"]:
              result.newerThan = some(getTime() - initDuration(hours = num))
              inc idx
            elif unit in ["week", "weeks", "w"]:
              result.newerThan = some(getTime() - initDuration(days = num * 7))
              inc idx
        except CatchableError:
          discard
      continue
    
    # content search
    if word in ["containing", "contains", "with"]:
      inc idx
      var textParts: seq[string] = @[]
      while idx < words.len:
        let w = words[idx]
        if w in ["modified", "larger", "smaller", "in", "named"]:
          break
        textParts.add(w)
        inc idx
      if textParts.len > 0:
        result.containsText = textParts.join(" ")
      continue
    
    # name patterns
    if word in ["named", "called", "name"]:
      inc idx
      if idx < words.len:
        result.patterns.add(words[idx])
        inc idx
      continue
    
    # extension patterns, images
    if word in ["images", "image", "photos", "photo"]:
      result.extensions.add(".jpg")
      result.extensions.add(".png")
      result.extensions.add(".gif")
      result.types.incl(etFile)
      inc idx
      continue
    
    # extension patterns, videos
    if word in ["videos", "video"]:
      result.extensions.add(".mp4")
      result.extensions.add(".avi")
      result.extensions.add(".mkv")
      result.types.incl(etFile)
      inc idx
      continue
    
    # extension patterns, documents
    if word in ["documents", "document", "docs"]:
      result.extensions.add(".pdf")
      result.extensions.add(".doc")
      result.extensions.add(".txt")
      result.types.incl(etFile)
      inc idx
      continue
    
    # language specific
    if word == "python":
      result.extensions.add(".py")
      result.types.incl(etFile)
      inc idx
      continue
    
    if word in ["javascript", "js"]:
      result.extensions.add(".js")
      result.types.incl(etFile)
      inc idx
      continue
    
    if word == "nim":
      result.extensions.add(".nim")
      result.types.incl(etFile)
      inc idx
      continue
    
    # skip filler words
    if word in ["a", "an", "the", "that", "are", "is", "and", "or", "all", "any", "find", "search", "show", "list", "get"]:
      inc idx
      continue
    
    # otherwise treat as a pattern (first non filler word)
    if word.len > 0 and result.patterns.len == 0:
      result.patterns.add(word)
    
    inc idx
  
  # default to all types if none specified
  if result.types == {}:
    result.types = {etFile, etDir, etLink}
