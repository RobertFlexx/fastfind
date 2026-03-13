# src/ff/nlp.nim
## natural language query parser
## converts human readable queries to filter parameters
import std/[strutils, times, options, sequtils, re]
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
    humanDescription*: string  # for error messages

const
  # size comparison words
  SizeGt = ["larger", "bigger", "greater", "more", "over", "above", "exceeding", "exceed"]
  SizeLt = ["smaller", "less", "under", "below", "within", "tinier"]
  SizeEq = ["exactly", "equal", "sized"]

  # time anchor words
  TimeAnchors = [
    ("today", 0), ("tonight", 0),
    ("yesterday", 1),
    ("week", 7), ("weekly", 7),
    ("month", 30), ("monthly", 30),
    ("year", 365), ("yearly", 365)
  ]

  # time unit multipliers
  TimeUnitDays = ["day", "days", "d"]
  TimeUnitHours = ["hour", "hours", "hr", "hrs", "h"]
  TimeUnitWeeks = ["week", "weeks", "w", "wk", "wks"]
  TimeUnitMonths = ["month", "months", "mo", "mos"]
  TimeUnitMins = ["minute", "minutes", "min", "mins", "m"]

  # type words
  TypeFile = ["file", "files", "document", "documents"]
  TypeDir  = ["directory", "directories", "folder", "folders", "dir", "dirs"]
  TypeLink = ["link", "links", "symlink", "symlinks", "shortcut"]

  # nl detection words
  NLSignals = ["files", "file", "directories", "folders", "larger", "smaller",
               "bigger", "modified", "changed", "created", "containing",
               "named", "today", "yesterday", "than", "within", "ago",
               "images", "videos", "documents", "photos", "recently",
               "last", "past", "older", "newer", "since", "before",
               "find", "show", "list", "search", "get", "give"]

  # file category, extensions
  CategoryImages   = [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg", ".tiff", ".ico", ".heic", ".raw"]
  CategoryVideos   = [".mp4", ".avi", ".mkv", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpeg", ".mpg"]
  CategoryAudio    = [".mp3", ".wav", ".flac", ".aac", ".ogg", ".m4a", ".wma", ".opus", ".aiff"]
  CategoryDocs     = [".pdf", ".doc", ".docx", ".odt", ".rtf", ".tex", ".pages"]
  CategoryText     = [".txt", ".md", ".rst", ".org", ".csv", ".tsv"]
  CategoryArchives = [".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar", ".tgz", ".zst"]
  CategoryCode     = [".c", ".cpp", ".h", ".hpp", ".cs", ".java", ".go", ".rs",
                      ".py", ".js", ".ts", ".rb", ".php", ".swift", ".kt",
                      ".nim", ".zig", ".v", ".d", ".lua", ".r", ".m", ".scala"]
  CategoryConfig   = [".toml", ".yaml", ".yml", ".json", ".xml", ".ini", ".cfg",
                      ".conf", ".env", ".properties", ".plist"]
  CategoryLogs     = [".log", ".out", ".err"]
  CategorySheets   = [".xls", ".xlsx", ".ods", ".numbers", ".csv"]
  CategorySlides   = [".ppt", ".pptx", ".odp", ".key"]

  # language, extensions
  LangMap = [
    ("python",      @[".py", ".pyw", ".pyx"]),
    ("javascript",  @[".js", ".mjs", ".cjs"]),
    ("typescript",  @[".ts", ".tsx"]),
    ("js",          @[".js", ".mjs"]),
    ("ts",          @[".ts", ".tsx"]),
    ("rust",        @[".rs"]),
    ("go",          @[".go"]),
    ("golang",      @[".go"]),
    ("c",           @[".c", ".h"]),
    ("cpp",         @[".cpp", ".cc", ".cxx", ".hpp", ".hxx"]),
    ("c++",         @[".cpp", ".cc", ".cxx", ".hpp"]),
    ("java",        @[".java"]),
    ("kotlin",      @[".kt", ".kts"]),
    ("swift",       @[".swift"]),
    ("ruby",        @[".rb", ".rake"]),
    ("rb",          @[".rb"]),
    ("php",         @[".php"]),
    ("nim",         @[".nim", ".nims"]),
    ("zig",         @[".zig"]),
    ("lua",         @[".lua"]),
    ("shell",       @[".sh", ".bash", ".zsh", ".fish"]),
    ("bash",        @[".sh", ".bash"]),
    ("zsh",         @[".zsh"]),
    ("fish",        @[".fish"]),
    ("haskell",     @[".hs", ".lhs"]),
    ("scala",       @[".scala"]),
    ("elixir",      @[".ex", ".exs"]),
    ("erlang",      @[".erl", ".hrl"]),
    ("clojure",     @[".clj", ".cljs"]),
    ("fsharp",      @[".fs", ".fsx"]),
    ("csharp",      @[".cs"]),
    ("cs",          @[".cs"]),
    ("r",           @[".r", ".rmd"]),
    ("matlab",      @[".m", ".mat"]),
    ("dart",        @[".dart"]),
    ("vue",         @[".vue"]),
    ("svelte",      @[".svelte"]),
    ("html",        @[".html", ".htm"]),
    ("css",         @[".css", ".scss", ".sass", ".less"]),
    ("sql",         @[".sql"]),
    ("toml",        @[".toml"]),
    ("yaml",        @[".yaml", ".yml"]),
    ("json",        @[".json"]),
    ("xml",         @[".xml"]),
    ("markdown",    @[".md", ".markdown"]),
    ("md",          @[".md"]),
  ]

  # filler words to skip
  FillerWords = ["a", "an", "the", "that", "are", "is", "and", "or",
                 "all", "any", "find", "search", "show", "list", "get",
                 "give", "me", "my", "i", "want", "need", "please",
                 "which", "what", "where", "how", "have", "been",
                 "were", "was", "some", "those", "these", "with",
                 "of", "at", "by", "for", "from", "into", "on", "up"]

proc isNaturalLanguageQuery*(query: string): bool =
  let words = query.toLowerAscii().split()
  if words.len < 2: return false
  var score = 0
  for word in words:
    if word in NLSignals: inc score
    # has spaces = likely nl
  if score >= 1: return true
  # quoted string with spaces and no glob chars is likely nl
  if ' ' in query and '*' notin query and '?' notin query:
    return true
  false

proc getTimeDays(word: string): int =
  for (k, v) in TimeAnchors:
    if k == word: return v
  -1

proc addExtensions(result: var ParsedQuery; exts: openArray[string]) =
  for e in exts:
    if e notin result.extensions:
      result.extensions.add(e)
  result.types.incl(etFile)

proc buildHumanDescription(pq: ParsedQuery; originalQuery: string): string =
  ## build a human readable description of what was searched for
  var parts: seq[string] = @[]

  # type
  var typeStr = "files"
  if etDir in pq.types and etFile notin pq.types:
    typeStr = "directories"
  elif etLink in pq.types and etFile notin pq.types:
    typeStr = "symlinks"

  # extensions
  if pq.extensions.len > 0:
    let exts = pq.extensions.mapIt(it[1..^1]).join("/")
    parts.add(exts & " " & typeStr)
  elif pq.patterns.len > 0 and pq.patterns[0] != "*":
    parts.add("'" & pq.patterns.join(", ") & "'")
  else:
    parts.add(typeStr)

  # size
  if pq.minSize >= 0 and pq.maxSize >= 0:
    parts.add("between " & formatSize(pq.minSize) & " and " & formatSize(pq.maxSize))
  elif pq.minSize >= 0:
    parts.add("larger than " & formatSize(pq.minSize))
  elif pq.maxSize >= 0:
    parts.add("smaller than " & formatSize(pq.maxSize))

  # time
  if pq.newerThan.isSome:
    let diff = getTime() - pq.newerThan.get
    let hours = diff.inHours
    if hours < 2:
      parts.add("modified in the last hour")
    elif hours < 25:
      parts.add("modified today")
    elif hours < 49:
      parts.add("modified yesterday")
    elif hours < 24 * 8:
      parts.add("modified this week")
    elif hours < 24 * 32:
      parts.add("modified this month")
    else:
      parts.add("modified recently")

  # content
  if pq.containsText.len > 0:
    parts.add("containing '" & pq.containsText & "'")

  if parts.len == 0:
    return originalQuery

  result = parts.join(" ")

proc parseNaturalQuery*(query: string): ParsedQuery =
  result = ParsedQuery()
  result.minSize = -1
  result.maxSize = -1
  result.newerThan = none(Time)
  result.olderThan = none(Time)
  result.types = {}
  result.matchMode = mmGlob

  let words = query.toLowerAscii().split()
  var idx = 0

  # helpers
  proc peek(i: int): string =
    if i < words.len: words[i] else: ""

  proc skip(keyword: string): bool =
    if idx < words.len and words[idx] == keyword:
      inc idx; true
    else: false

  while idx < words.len:
    let word = words[idx]

    # kinda wanna hurt myself
    if word in TypeFile:
      result.types.incl(etFile); inc idx; continue
    if word in TypeDir:
      result.types.incl(etDir); inc idx; continue
    if word in TypeLink:
      result.types.incl(etLink); inc idx; continue

    # --- file categories ---
    if word in ["image", "images", "photo", "photos", "picture", "pictures", "pic", "pics"]:
      result.addExtensions(CategoryImages); inc idx; continue
    if word in ["video", "videos", "movie", "movies", "film", "films", "clip", "clips"]:
      result.addExtensions(CategoryVideos); inc idx; continue
    if word in ["audio", "music", "song", "songs", "sound", "sounds", "track", "tracks"]:
      result.addExtensions(CategoryAudio); inc idx; continue
    if word in ["document", "documents", "doc", "docs", "pdf", "pdfs"]:
      result.addExtensions(CategoryDocs); inc idx; continue
    if word in ["archive", "archives", "compressed", "zipped"]:
      result.addExtensions(CategoryArchives); inc idx; continue
    if word in ["log", "logs", "logfile", "logfiles"]:
      result.addExtensions(CategoryLogs); inc idx; continue
    if word in ["config", "configs", "configuration", "configurations", "settings"]:
      result.addExtensions(CategoryConfig); inc idx; continue
    if word in ["spreadsheet", "spreadsheets", "sheet", "sheets"]:
      result.addExtensions(CategorySheets); inc idx; continue
    if word in ["slide", "slides", "presentation", "presentations"]:
      result.addExtensions(CategorySlides); inc idx; continue
    if word in ["code", "source", "script", "scripts"]:
      result.addExtensions(CategoryCode); inc idx; continue
    if word in ["text", "textfile", "textfiles", "plaintext"]:
      result.addExtensions(CategoryText); inc idx; continue

    # programming languages
    var foundLang = false
    for (lang, exts) in LangMap:
      if word == lang:
        result.addExtensions(exts)
        foundLang = true
        break
    if foundLang: inc idx; continue

    # size expressions
    # "between Xmb and Ymb"
    if word == "between":
      inc idx
      try:
        let lo = parseBytes(peek(idx)); inc idx
        discard skip("and")
        discard skip("to")
        let hi = parseBytes(peek(idx)); inc idx
        result.minSize = lo
        result.maxSize = hi
      except CatchableError: discard
      continue

    # "larger/smaller than X"
    var sizeDir = 0  # 1=gt, -1=lt, 0=eq
    if word in SizeGt: sizeDir = 1
    elif word in SizeLt: sizeDir = -1
    elif word in SizeEq: sizeDir = 0

    if sizeDir != 0 or word in SizeEq:
      if word in SizeGt or word in SizeLt or word in SizeEq:
        inc idx
        discard skip("than")
        discard skip("or")
        discard skip("equal")
        discard skip("to")
        if idx < words.len:
          try:
            let bytes = parseBytes(words[idx]); inc idx
            if sizeDir == 1:
              result.minSize = bytes + 1
            elif sizeDir == -1:
              result.maxSize = bytes - 1
            else:
              result.minSize = bytes
              result.maxSize = bytes
          except CatchableError: discard
        continue

    # time expressions
    if word in ["modified", "changed", "updated", "created", "accessed",
                "newer", "older", "since", "after", "before"]:
      let isOlder = word in ["older", "before"]
      inc idx
      # skip prepositions
      discard skip("within")
      discard skip("in")
      discard skip("the")
      discard skip("last")
      discard skip("past")
      discard skip("than")
      discard skip("on")

      if idx >= words.len: continue
      let timeWord = words[idx]

      # "today", "yesterday", "this week" etc
      let anchorDays = getTimeDays(timeWord)
      if anchorDays >= 0:
        let t = some(getTime() - initDuration(days = anchorDays))
        if isOlder: result.olderThan = t
        else: result.newerThan = t
        inc idx
        continue

      # "this week/month/year"
      if timeWord == "this":
        inc idx
        if idx < words.len:
          case words[idx]
          of "week": result.newerThan = some(getTime() - initDuration(days = 7)); inc idx
          of "month": result.newerThan = some(getTime() - initDuration(days = 30)); inc idx
          of "year": result.newerThan = some(getTime() - initDuration(days = 365)); inc idx
          else: discard
        continue

      # "X days/hours/weeks ago" or "X days/hours/weeks" blah blah blahwah90fhqwi
      try:
        let num = parseInt(timeWord); inc idx
        discard skip("or")
        discard skip("more")
        if idx < words.len:
          let unit = words[idx]
          var dur: Duration
          if unit in TimeUnitDays: dur = initDuration(days = num); inc idx
          elif unit in TimeUnitHours: dur = initDuration(hours = num); inc idx
          elif unit in TimeUnitWeeks: dur = initDuration(days = num * 7); inc idx
          elif unit in TimeUnitMonths: dur = initDuration(days = num * 30); inc idx
          elif unit in TimeUnitMins: dur = initDuration(minutes = num); inc idx
          else: dur = initDuration(days = num)
          discard skip("ago")
          let t = some(getTime() - dur)
          if isOlder: result.olderThan = t
          else: result.newerThan = t
      except CatchableError: discard
      continue

    # "recently" / "recent"
    if word in ["recently", "recent", "new", "latest", "newest"]:
      result.newerThan = some(getTime() - initDuration(days = 7))
      inc idx; continue

    # "old" / "oldest"
    if word in ["old", "oldest", "ancient", "stale"]:
      result.olderThan = some(getTime() - initDuration(days = 365))
      inc idx; continue

    # "empty"
    if word == "empty":
      result.maxSize = 0
      inc idx; continue

    # "large" / "big" / "huge" / "small" / "tiny"
    if word in ["large", "big", "huge", "massive"]:
      result.minSize = 10 * 1024 * 1024  # >10MB
      inc idx; continue
    if word in ["small", "tiny", "little"]:
      result.maxSize = 100 * 1024  # <100KB
      inc idx; continue

    # content search
    if word in ["containing", "contains", "include", "includes",
                "with", "having", "has", "matching"]:
      inc idx
      # collect until next filter keyword
      var textParts: seq[string] = @[]
      while idx < words.len:
        let w = words[idx]
        if w in ["modified", "larger", "smaller", "in", "named",
                 "called", "older", "newer", "size", "type"]:
          break
        # strip quotes
        textParts.add(w.strip(chars = {'"', '\''}))
        inc idx
      if textParts.len > 0:
        result.containsText = textParts.join(" ")
      continue

    # name patterns
    if word in ["named", "called", "name", "matching", "like"]:
      inc idx
      if idx < words.len:
        var pat = words[idx].strip(chars = {'"', '\''})
        # add glob if no wildcards
        if '*' notin pat and '?' notin pat:
          pat = "*" & pat & "*"
        result.patterns.add(pat)
        inc idx
      continue

    # location
    if word in ["in", "inside", "under", "within", "from"] and idx + 1 < words.len:
      let next = words[idx + 1]
      # only treat as directory hint if it looks like a path
      if next.startsWith("/") or next.startsWith("~") or next.startsWith("."):
        result.inDirectory = next
        idx += 2
        continue

    # exclusions
    if word in ["not", "exclude", "excluding", "without", "except", "ignore", "ignoring"]:
      inc idx
      if idx < words.len:
        result.excludePatterns.add(words[idx])
        inc idx
      continue

    # extension hint e.g. ".nim files" or "*.nim"
    if word.startsWith(".") and word.len > 1:
      result.extensions.add(word)
      result.types.incl(etFile)
      inc idx; continue

    if word.startsWith("*."):
      result.extensions.add(word[1..^1])
      result.types.incl(etFile)
      inc idx; continue

    # filler words
    if word in FillerWords:
      inc idx; continue

    # treat remaining as name pattern (first unknown word)
    if word.len > 1 and result.patterns.len == 0 and result.extensions.len == 0:
      # could be a filename pattern
      if '*' in word or '?' in word or '.' in word:
        result.patterns.add(word)
      else:
        result.patterns.add("*" & word & "*")

    inc idx

  # defaults
  if result.types == {}:
    result.types = {etFile, etDir, etLink}

  result.humanDescription = buildHumanDescription(result, query)
