# src/ff/nlp.nim
## natural language query parser
## converts human readable queries to filter parameters
import std/[strutils, times, options, sequtils, sets]
import core, units, matchers

# PSA: any commented variables you see were unused, but I (kokonico) have no idea what they're original purpose was
# hence, i'll keep them just in case

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
    modeExplicit*: bool
    pathMode*: PathMode
    minDepth*: int
    maxDepth*: int
    limit*: int
    sortKey*: SortKey
    reverseSort*: bool
    includeHidden*: bool
    followSymlinks*: bool
    containsRegex*: string
    interpretation*: seq[string]
    warnings*: seq[string]
    humanDescription*: string

const
  SizeGt = toHashSet(@["larger", "bigger", "greater", "more", "over", "above", "exceeding", "exceed", "huge", "massive", "big", "enormous", "giant", "gigantic", "vast", "immense", "巨", "large", "sz"])
  SizeLt = toHashSet(@["smaller", "less", "under", "below", "within", "tinier", "tiny", "little", "short", "compact", "mini", "miniature", "microscopic", "petite", "slight", "微", "small", "lt"])
  SizeEq = toHashSet(@["exactly", "equal", "sized", "precisely", "around", "about", "approximately", "roughly", "eq"])

  TimeAnchors = @[
    ("today", 0), ("tonight", 0), ("now", 0), ("rightnow", 0), ("immediately", 0),
    ("yesterday", 1), ("dayago", 1),
    ("day", 1), ("days", 1),
    ("week", 7), ("weekend", 2), ("weekly", 7), ("thisweek", 7), ("this_week", 7), ("lastweek", 7),
    ("month", 30), ("monthly", 30), ("thismonth", 30), ("this_month", 30), ("lastmonth", 30),
    ("quarter", 90), ("season", 90),
    ("year", 365), ("yearly", 365), ("thisyear", 365), ("this_year", 365), ("lastyear", 365),
    ("decade", 3650), ("centuries", 36500), ("century", 36500)
  ]

  # TimeUnitDays = toHashSet(@["day", "days", "d", "jornada", "dia", "giorni", "tag", "tages"])
  # TimeUnitHours = toHashSet(@["hour", "hours", "hr", "hrs", "h", "hrz", "hora", "heure", "stunde", "ore"])
  # TimeUnitWeeks = toHashSet(@["week", "weeks", "w", "wk", "wks", "semaine", "woche", "settimana"])
  # TimeUnitMonths = toHashSet(@["month", "months", "mo", "mos", "mese", "mois", "monat", "mesi"])
  # TimeUnitMins = toHashSet(@["minute", "minutes", "min", "mins", "m", "minuto", "minute", "minuten"])
  # TimeUnitSecs = toHashSet(@["second", "seconds", "sec", "secs", "s", "segundo"])

  TypeFile = toHashSet(@["file", "files", "document", "documents", "doc", "docs", "documento", "fichier", "datei", "archivio", "ficheiro"])
  TypeDir = toHashSet(@["directory", "directories", "folder", "folders", "dir", "dirs", "carpeta", "dossier", "ordner", "cartella", "directorio"])
  TypeLink = toHashSet(@["link", "links", "symlink", "symlinks", "shortcut", "shortcuts", "alias", "enlace", "raccourci"])

  FillerWords = toHashSet(@[
    "a", "an", "the", "that", "are", "is", "and", "or", "but", "so", "yet",
    "all", "any", "some", "these", "those", "every", "each", "any",
    "find", "search", "show", "list", "get", "give", "display", "look", "locate", "discover",
    "me", "my", "i", "we", "you", "they", "he", "she", "it", "its",
    "want", "need", "would", "could", "should", "will", "can", "may", "might", "must",
    "please", "kindly", "thanks", "thank", "sorry",
    "which", "what", "where", "when", "why", "how", "who", "whom", "whichever",
    "have", "has", "had", "were", "was", "do", "does", "did", "done",
    "with", "without", "for", "to", "from", "of", "at", "by", "on", "in", "into", "over", "under", "upon",
    "as", "like", "about", "than", "then", "through", "during", "before", "after", "between",
    "up", "down", "out", "off", "just", "only", "also", "even", "still", "already",
    "very", "really", "quite", "rather", "fairly", "pretty", "extremely", "absolutely",
    "here", "there", "anywhere", "somewhere", "everywhere", "nowhere",
    "anything", "something", "nothing", "everything", "anyone", "someone", "noone", "everyone"
  ])

  ActionWords = toHashSet(@["find", "findme", "findall", "show", "showme", "showall", "list", "listall",
    "search", "searchfor", "look", "lookfor", "lookup", "locate", "get", "getme",
    "give", "giveme", "display", "displayall", "discover", "fetch", "grab", "pull"])

  ModifierWords = toHashSet(@["all", "every", "any", "some", "only", "just", "recent", "latest",
    "new", "newest", "old", "oldest", "modified", "changed", "updated", "created",
    "big", "biggest", "small", "smallest", "largest", "first", "last", "hidden"])

  CategoryImages = @[".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg", ".tiff", ".ico", ".heic", ".raw", ".avif", ".psd", ".ai", ".eps", ".webp", ".jfif", ".pnm", ".ppm", ".pgm", ".pbm"]
  CategoryVideos = @[".mp4", ".avi", ".mkv", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpeg", ".mpg", ".prores", ".264", ".hevc", ".ts", ".mts", ".m2ts", ".vob", ".ogv"]
  CategoryAudio = @[".mp3", ".wav", ".flac", ".aac", ".ogg", ".m4a", ".wma", ".opus", ".aiff", ".alac", ".mid", ".midi", ".kar", ".rmi", ".aac", ".ape", ".opus", ".wavpack"]
  CategoryDocs = @[".pdf", ".doc", ".docx", ".odt", ".rtf", ".tex", ".pages", ".epub", ".mobi", ".chm", ".djvu", ".fb2", ".lit", ".lrf", ".pdb", ".oxps", ".xps"]
  CategoryText = @[".txt", ".md", ".markdown", ".rst", ".org", ".csv", ".tsv", ".log", ".text", ".plaintext", ".utf8", ".ascii", ".ans", ".nfo"]
  CategoryArchives = @[".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar", ".tgz", ".zst", ".lz", ".lz4", ".cab", ".iso", ".arj", ".lzh", ".ace", ".arc", ".zoo", ".bz", ".sz", ".lzop", ".z", ".zipx"]
  CategoryCode = @[".c", ".cpp", ".h", ".hpp", ".cs", ".java", ".go", ".rs", ".py", ".js", ".ts", ".rb", ".php", ".swift", ".kt", ".nim", ".zig", ".v", ".d", ".lua", ".r", ".m", ".scala", ".hs", ".ex", ".exs", ".erl", ".hrl", ".clj", ".cljs", ".fs", ".fsx", ".vue", ".svelte", ".html", ".htm", ".css", ".scss", ".sass", ".less", ".sql", ".pl", ".pm", ".pas", ".f", ".f90", ".f95", ".asm", ".s", ".asmx", ".jl", ".cl", ".lisp", ".scm", ".rkt", ".fs", ".fsx", ".fsi", ".ml", ".mli", ".fs", ".nim", ".nimble", ".nims"]
  CategoryConfig = @[".toml", ".yaml", ".yml", ".json", ".xml", ".ini", ".cfg", ".conf", ".env", ".properties", ".plist", ".toml", ".desktop", ".service", ".socket", ".timer", ".target", ".slice", ".scope", ".path", ".mount", ".automount", ".swap", ".network", ".netdev"]
  CategoryLogs = @[".log", ".out", ".err", ".trace", ".debug", ".txt"]
  CategorySheets = @[".xls", ".xlsx", ".ods", ".numbers", ".csv", ".tsv"]
  CategorySlides = @[".ppt", ".pptx", ".odp", ".key", ".fodp", ".fodt", ".sxi"]
  CategoryDevops = @[".yaml", ".yml", ".json", ".toml", ".ini", ".conf", ".cfg", ".env", ".properties", ".tf", ".tfvars", ".bicep", ".dockerfile", ".dockerignore", ".gitignore", ".dockerignore"]
  # CategoryMedia = @[".jpg", ".jpeg", ".png", ".gif", ".bmp", ".svg", ".webp", ".mp4", ".avi", ".mkv", ".mov", ".mp3", ".wav", ".flac", ".ogg", ".m4a"]
  CategoryDatabase = @[".sql", ".db", ".sqlite", ".sqlite3", ".mdb", ".accdb", ".frm", ".ibd", ".dbf", ".nsf", ".dbi"]
  CategoryFonts = @[".ttf", ".otf", ".woff", ".woff2", ".eot", ".svg", ".pfb", ".pfm", ".afm", ".ttc", ".fnt", ".gsf"]

  LangMap = @[
    ("python", @[".py", ".pyw", ".pyx", ".pyd", ".pyi"]),
    ("javascript", @[".js", ".mjs", ".cjs", ".jsx"]),
    ("typescript", @[".ts", ".tsx", ".mts", ".cts"]),
    ("js", @[".js", ".mjs", ".cjs", ".jsx"]),
    ("ts", @[".ts", ".tsx"]),
    ("rust", @[".rs", ".rlib"]),
    ("go", @[".go"]),
    ("golang", @[".go"]),
    ("c", @[".c", ".h"]),
    ("cpp", @[".cpp", ".cc", ".cxx", ".hpp", ".hxx", ".hh", ".c++", ".h++"]),
    ("c++", @[".cpp", ".cc", ".cxx", ".hpp", ".c++"]),
    ("java", @[".java"]),
    ("kotlin", @[".kt", ".kts"]),
    ("swift", @[".swift"]),
    ("ruby", @[".rb", ".rake", ".gem", ".rbc", ".rake"]),
    ("rb", @[".rb"]),
    ("php", @[".php", ".phtml", ".php3", ".php4", ".php5", ".php7", ".phps", ".phar"]),
    ("nim", @[".nim", ".nims", ".nimble"]),
    ("zig", @[".zig"]),
    ("lua", @[".lua"]),
    ("perl", @[".pl", ".pm", ".pod", ".t"]),
    ("perl5", @[".pl", ".pm"]),
    ("python3", @[".py", ".pyw"]),
    ("shell", @[".sh", ".bash", ".zsh", ".fish", ".ksh", ".csh", ".tcsh", ".ash", ".dash"]),
    ("bash", @[".sh", ".bash", ".bashrc", ".bash_profile"]),
    ("zsh", @[".zsh", ".zshrc", ".zprofile", ".zshenv"]),
    ("fish", @[".fish", ".fishrc"]),
    ("powershell", @[".ps1", ".psm1", ".psd1", ".pssc", ".psrc"]),
    ("powershellcore", @[".ps1", ".psm1"]),
    ("haskell", @[".hs", ".lhs", ".hs-boot", ".lhs-boot"]),
    ("scala", @[".scala", ".sc"]),
    ("elixir", @[".ex", ".exs", ".eex", ".leex", ".heex"]),
    ("erlang", @[".erl", ".hrl", ".app", ".app.src"]),
    ("clojure", @[".clj", ".cljs", ".cljc", ".edn"]),
    ("fsharp", @[".fs", ".fsx", ".fsi", ".fsscript"]),
    ("csharp", @[".cs"]),
    ("cs", @[".cs"]),
    ("r", @[".r", ".R", ".rmd", ".rprofile"]),
    ("matlab", @[".m", ".mat"]),
    ("mathematica", @[".nb", ".wl", ".wls"]),
    ("dart", @[".dart"]),
    ("vue", @[".vue"]),
    ("svelte", @[".svelte"]),
    ("html", @[".html", ".htm", ".html5", ".xhtml"]),
    ("css", @[".css", ".scss", ".sass", ".less", ".stylus", ".styl"]),
    ("sql", @[".sql"]),
    ("toml", @[".toml"]),
    ("yaml", @[".yaml", ".yml"]),
    ("json", @[".json", ".jsonc", ".json5"]),
    ("xml", @[".xml", ".xsl", ".xslt", ".dtd", ".svg", ".xaml"]),
    ("markdown", @[".md", ".markdown", ".mdown", ".mkd", ".mkdn", ".mkdtxt"]),
    ("md", @[".md", ".markdown"]),
    ("csv", @[".csv", ".tsv", ".tab"]),
    ("perl", @[".pl", ".pm", ".pod"]),
    ("pascal", @[".pas", ".pp", ".inc", ".dpr", ".dpk"]),
    ("fortran", @[".f", ".f90", ".f95", ".f03", ".f08", ".for"]),
    ("objectivec", @[".m", ".mm", ".h"]),
    ("objective-c", @[".m", ".mm", ".h"]),
    ("groovy", @[".groovy", ".gvy", ".gy", ".gsh"]),
    ("gradle", @[".gradle"]),
    ("make", @[".mk", ".mak", ".make"]),
    ("cmake", @[".cmake", ".cmake.in", ".CMakeLists.txt"]),
    ("ninja", @[".ninja"]),
    ("dockerfile", @[".dockerfile", "Dockerfile"]),
    ("terraform", @[".tf", ".tfvars", ".tfstate"]),
    ("helm", @[".yaml", ".tpl"]),
    ("nginx", @[".conf"]),
    ("apache", @[".htaccess", ".htpasswd", ".conf"]),
    ("vim", @[".vim", ".vimrc", ".gvimrc", "_vimrc", "_gvimrc", ".nvimrc", ".nvim"]),
    ("emacs", @[".el", ".elc", ".emacs", ".emacs.desktop"]),
    ("git", @[".gitignore", ".gitattributes", ".gitconfig", ".gitkeep", ".gitignore-global"]),
    ("puppet", @[".pp"]),
    ("ansible", @[".yml", ".yaml"]),
    ("react", @[".jsx", ".tsx"]),
    ("next", @[".tsx", ".jsx"]),
    ("node", @[".js", ".json", ".package.json"]),
    ("npm", @[".json", "package.json", "package-lock.json"]),
    ("pip", @["requirements.txt", "Pipfile", "pyproject.toml"]),
    ("cargo", @["Cargo.toml", "Cargo.lock"]),
    ("go.mod", @["go.mod", "go.sum"]),
    ("julia", @[".jl"]),
    ("zig", @[".zig"]),
    ("crystal", @[".cr"]),
    ("v", @[".v"]),
    ("odin", @[".odin"]),
    ("gleam", @[".gleam"]),
    ("rescript", @[".res", ".resi"]),
    ("ocaml", @[".ml", ".mli", ".eliom", ".eliomi"]),
    ("reason", @[".re", ".rei"]),
    ("purescript", @[".purs"]),
    ("elm", @[".elm"]),
    ("idris", @[".idr", ".ipkg"]),
    ("agda", @[".agda"]),
    ("coq", @[".v"]),
    ("lean", @[".lean"]),
    ("verilog", @[".v", ".vh", ".sv"]),
    ("systemverilog", @[".sv", ".svi", ".svh"]),
    ("vhdl", @[".vhd", ".vhdl"]),
    ("tcl", @[".tcl", ".tk"]),
    ("awk", @[".awk"]),
    ("sed", @[".sed"]),
    ("kotlin", @[".kt", ".kts"]),
    ("gradle", @[".gradle", ".gradle.kts"]),
    ("sbt", @[".sbt"]),
    ("make", @["Makefile", "makefile", "GNUmakefile"]),
    ("cmake", @["CMakeLists.txt", "CMakeCache.txt"]),
    ("ninja", @["build.ninja", "rules.ninja"]),
    ("meson", @["meson.build", "meson.options"]),
    ("bazel", @["BUILD", "BUILD.bazel", ".bazelrc"]),
    ("buck", @["BUCK"]),
    ("prawn", @[".prawn"]),
    ("tmux", @[".tmux.conf"]),
    ("ssh", @[".ssh/config", "known_hosts"]),
    ("gpg", @[".gnupg/pubring.gpg", ".gnupg/secring.gpg"]),
    ("x11", @[".xinitrc", ".xprofile", ".Xresources", ".Xdefaults"]),
    ("i3", @[".config/i3/config"]),
    ("sway", @[".config/sway/config"]),
    ("alacritty", @[".config/alacritty/alacritty.yml"]),
    ("kitty", @[".config/kitty/kitty.conf"]),
    ("wezterm", @[".config/wezterm/wezterm.lua"]),
    ("starship", @[".config/starship.toml"]),
    ("tmux", @[".tmux.conf"]),
  ]

  CompoundCategories = @[
    ("image files", CategoryImages),
    ("images", CategoryImages),
    ("image", CategoryImages),
    ("pictures", CategoryImages),
    ("picture", CategoryImages),
    ("photos", CategoryImages),
    ("photo", CategoryImages),
    ("video files", CategoryVideos),
    ("videos", CategoryVideos),
    ("video", CategoryVideos),
    ("movies", CategoryVideos),
    ("movie", CategoryVideos),
    ("films", CategoryVideos),
    ("film", CategoryVideos),
    ("audio files", CategoryAudio),
    ("audio", CategoryAudio),
    ("music", CategoryAudio),
    ("songs", CategoryAudio),
    ("song", CategoryAudio),
    ("document files", CategoryDocs),
    ("documents", CategoryDocs),
    ("document", CategoryDocs),
    ("text files", CategoryText),
    ("text", CategoryText),
    ("plain text", CategoryText),
    ("archive files", CategoryArchives),
    ("archives", CategoryArchives),
    ("archive", CategoryArchives),
    ("compressed files", CategoryArchives),
    ("compressed", CategoryArchives),
    ("zipped files", CategoryArchives),
    ("code files", CategoryCode),
    ("code", CategoryCode),
    ("source files", CategoryCode),
    ("source", CategoryCode),
    ("scripts", CategoryCode),
    ("script", CategoryCode),
    ("source code", CategoryCode),
    ("config files", CategoryConfig),
    ("configuration files", CategoryConfig),
    ("configs", CategoryConfig),
    ("config", CategoryConfig),
    ("configuration", CategoryConfig),
    ("log files", CategoryLogs),
    ("logs", CategoryLogs),
    ("log", CategoryLogs),
    ("spreadsheet files", CategorySheets),
    ("spreadsheets", CategorySheets),
    ("spreadsheet", CategorySheets),
    ("presentation files", CategorySlides),
    ("presentations", CategorySlides),
    ("slides", CategorySlides),
    ("slide", CategorySlides),
    ("devops files", CategoryDevops),
    ("devops", CategoryDevops),
    ("database files", CategoryDatabase),
    ("database", CategoryDatabase),
    ("db files", CategoryDatabase),
    ("font files", CategoryFonts),
    ("fonts", CategoryFonts),
    ("font", CategoryFonts),
  ]

  SizeKeywords = toHashSet(@["size", "sized", "length", "long", "big", "huge", "large", "small", "tiny", "bytes", "kb", "mb", "gb", "tb"])
  TimeKeywords = toHashSet(@["modified", "changed", "updated", "created", "accessed", "birth", "mtime", "atime", "ctime", "timestamp", "date"])
  ContentKeywords = toHashSet(@["containing", "contains", "include", "includes", "with", "having", "has", "matching", "content", "text", "string"])
  # NameKeywords = toHashSet(@["named", "called", "name", "matching", "like", "filename", "file"])
  LocationKeywords = toHashSet(@["in", "inside", "under", "within", "from", "located", "locatedin", "path", "directory", "folder", "subdirectory"])
  # ExcludeKeywords = toHashSet(@["not", "exclude", "excluding", "without", "except", "ignore", "ignoring", "skip", "skipping", "avoid"])
  # ExtensionKeywords = toHashSet(@["extension", "ext", "type", "format", "kind"])

proc isNaturalLanguageQuery*(query: string): bool =
  let q = query.strip()
  if q.len == 0: return false

  let qlc = q.toLowerAscii()
  let words = qlc.split()

  if words.len < 2: return false

  var score = 0
  for word in words:
    if word in ActionWords: inc score, 2
    if word in ModifierWords: inc score
    if word in SizeGt or word in SizeLt: inc score, 2
    if word in TypeFile or word in TypeDir: inc score
    if word in SizeKeywords: inc score
    if word in TimeKeywords: inc score, 2
    if word in ContentKeywords: inc score, 2
    if word in LocationKeywords: inc score
    if word in FillerWords: dec score

  if score >= 1: return true

  for item in CompoundCategories:
    let compound = item[0]
    if qlc.contains(compound): return true

  for item in LangMap:
    let lang = item[0]
    if qlc.contains(" " & lang & " ") or qlc.contains(" " & lang & "s ") or qlc.contains(" " & lang & " code"): return true

  if qlc.contains("files") or qlc.contains("folders") or qlc.contains("directories"): return true

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
  var parts: seq[string] = @[]
  var typeStr = "files"
  if etDir in pq.types and etFile notin pq.types:
    typeStr = "directories"
  elif etLink in pq.types and etFile notin pq.types:
    typeStr = "symlinks"

  if pq.extensions.len > 0:
    let exts = pq.extensions.mapIt(if it.startsWith("."): it[1..^1] else: it).join("/")
    parts.add(exts & " " & typeStr)
  elif pq.patterns.len > 0 and pq.patterns[0] != "*":
    parts.add("'" & pq.patterns.join(", ") & "'")
  else:
    parts.add(typeStr)

  if pq.minSize >= 0 and pq.maxSize >= 0:
    parts.add("between " & formatSize(pq.minSize) & " and " & formatSize(pq.maxSize))
  elif pq.minSize >= 0:
    parts.add("larger than " & formatSize(pq.minSize))
  elif pq.maxSize >= 0:
    parts.add("smaller than " & formatSize(pq.maxSize))

  if pq.newerThan.isSome:
    let diff = getTime() - pq.newerThan.get
    let hours = diff.inHours
    if hours < 2: parts.add("modified in the last hour")
    elif hours < 25: parts.add("modified today")
    elif hours < 49: parts.add("modified yesterday")
    elif hours < 24 * 8: parts.add("modified this week")
    elif hours < 24 * 32: parts.add("modified this month")
    else: parts.add("modified recently")

  if pq.containsText.len > 0:
    parts.add("containing '" & pq.containsText & "'")

  if parts.len == 0: return originalQuery
  result = parts.join(" ")

proc parseNaturalQueryLegacy(query: string): ParsedQuery {.used.} =
  var q = ParsedQuery()
  q.minSize = -1
  q.maxSize = -1
  q.newerThan = none(Time)
  q.olderThan = none(Time)
  q.types = {}
  q.matchMode = mmGlob

  var textParts: seq[string] = @[]
  # var collectText = false
  var rawWords = query.toLowerAscii().split()
  var words: seq[string] = @[]

  for w in rawWords:
    let stripped = w.strip(chars = {'.', ',', ':', ';', '!', '?', '"', '\'', '(', ')', '[', ']', '{', '}'})
    if stripped.len > 0:
      words.add(stripped)

  var idx = 0

  proc peek(i: int): string =
    if i < words.len: words[i] else: ""

  proc skip(keyword: string): bool =
    if idx < words.len and words[idx] == keyword:
      inc idx; true
    else: false

  proc skipAny(keywords: openArray[string]): bool =
    for kw in keywords:
      if skip(kw): return true
    false

  proc parseNumber(): int =
    try: parseInt(peek(idx))
    except: -1

  proc parseDuration(): Option[Duration] =
    if idx >= words.len: return none(Duration)
    let num = parseNumber()
    if num < 0: return none(Duration)
    inc idx
    if idx >= words.len: return some(initDuration(days = num))
    let unit = words[idx]
    case unit
    of "second", "seconds", "sec", "secs", "s":
      inc idx; result = some(initDuration(seconds = num))
    of "minute", "minutes", "min", "mins", "m":
      inc idx; result = some(initDuration(minutes = num))
    of "hour", "hours", "hr", "hrs", "h":
      inc idx; result = some(initDuration(hours = num))
    of "day", "days", "d":
      inc idx; result = some(initDuration(days = num))
    of "week", "weeks", "w", "wk", "wks":
      inc idx; result = some(initDuration(days = num * 7))
    of "month", "months", "mo", "mos":
      inc idx; result = some(initDuration(days = num * 30))
    of "year", "years", "yr", "yrs":
      inc idx; result = some(initDuration(days = num * 365))
    else:
      result = some(initDuration(days = num))

  proc parseSizeExpr(): tuple[min, max: int64] =
    result = (-1'i64, -1'i64)
    discard skipAny(["not", "no", "non"])
    if skipAny(["empty", "zero", "zerobytes"]):
      result.max = 0
      return
    if skipAny(["small", "tiny", "little", "micro"]):
      result.max = 10 * 1024
      return
    if skipAny(["medium", "mediumsized"]):
      result.min = 10 * 1024
      result.max = 10 * 1024 * 1024
      return
    if skipAny(["large", "big", "huge", "massive", "enormous", "giant"]):
      result.min = 10 * 1024 * 1024
      return
    if skipAny(["larger", "bigger", "greater", "over", "above", "more"]):
      discard skip("than")
      if idx < words.len:
        try:
          result.min = parseBytes(words[idx]) + 1
          inc idx
        except: discard
      return
    if skipAny(["smaller", "less", "under", "below"]):
      discard skip("than")
      if idx < words.len:
        try:
          result.max = parseBytes(words[idx]) - 1
          inc idx
        except: discard
      return
    if skipAny(["around", "about", "approximately", "roughly", "equal", "exactly"]):
      if idx < words.len:
        try:
          let sz = parseBytes(words[idx])
          result.min = sz - sz div 10
          result.max = sz + sz div 10
          inc idx
        except: discard
      return
    if skipAny(["between", "from"]):
      if idx < words.len:
        try:
          result.min = parseBytes(words[idx])
          inc idx
          discard skipAny(["to", "and", "-", "–"])
          if idx < words.len:
            result.max = parseBytes(words[idx])
            inc idx
        except: discard
      return
    if skipAny(["max", "maximum", "upto", "up to"]):
      if idx < words.len:
        try:
          result.max = parseBytes(words[idx])
          inc idx
        except: discard
      return
    if skipAny(["min", "minimum", "atleast", "at least"]):
      if idx < words.len:
        try:
          result.min = parseBytes(words[idx])
          inc idx
        except: discard
      return

  proc parseTimeExpr(isOlder: bool): bool =
    discard skipAny(["modified", "changed", "updated", "created", "accessed", "birth", "touched"])
    discard skipAny(["newer", "older"])
    discard skipAny(["in", "the", "last", "past", "within", "during", "for", "over", "since", "before", "after", "ago", "on", "this", "that"])
    if idx >= words.len: return false
    let anchorDays = getTimeDays(words[idx])
    if anchorDays >= 0:
      let t = some(getTime() - initDuration(days = anchorDays))
      if isOlder: q.olderThan = t
      else: q.newerThan = t
      inc idx
      return true
    if skip("this"):
      if skip("week"):
        q.newerThan = some(getTime() - initDuration(days = 7)); return true
      if skip("month"):
        q.newerThan = some(getTime() - initDuration(days = 30)); return true
      if skip("year"):
        q.newerThan = some(getTime() - initDuration(days = 365)); return true
      if skip("weekend"):
        q.newerThan = some(getTime() - initDuration(days = 2)); return true
      if skip("quarter"):
        q.newerThan = some(getTime() - initDuration(days = 90)); return true
      return false
    if skip("last"):
      if skip("week"):
        q.newerThan = some(getTime() - initDuration(days = 7)); return true
      if skip("month"):
        q.newerThan = some(getTime() - initDuration(days = 30)); return true
      if skip("year"):
        q.newerThan = some(getTime() - initDuration(days = 365)); return true
      return false
    if skip("recently") or skip("recent") or skip("new") or skip("latest") or skip("newest"):
      q.newerThan = some(getTime() - initDuration(days = 7)); return true
    if skip("old") or skip("oldest") or skip("ancient") or skip("stale"):
      q.olderThan = some(getTime() - initDuration(days = 365)); return true
    let durOpt = parseDuration()
    if durOpt.isSome:
      let t = some(getTime() - durOpt.get)
      if isOlder: q.olderThan = t
      else: q.newerThan = t
      discard skip("ago")
      return true
    false

  proc parseCompoundCategory(): bool =
    for item in CompoundCategories:
      let compound = item[0]
      let exts = item[1]
      let compoundWords = compound.split()
      var matches = true
      for i, cw in compoundWords:
        if idx + i >= words.len or words[idx + i] != cw:
          matches = false
          break
      if matches:
        q.addExtensions(exts)
        idx += compoundWords.len
        return true
    false

  while idx < words.len:
    let word = words[idx]

    if word in TypeFile:
      q.types.incl(etFile); inc idx; continue
    if word in TypeDir:
      q.types.incl(etDir); inc idx; continue
    if word in TypeLink:
      q.types.incl(etLink); inc idx; continue

    if parseCompoundCategory(): continue

    if word in ["image", "images", "photo", "photos", "picture", "pictures", "pic", "pics", "img", "imgs"]:
      q.addExtensions(CategoryImages); inc idx; continue
    if word in ["video", "videos", "movie", "movies", "film", "films", "clip", "clips"]:
      q.addExtensions(CategoryVideos); inc idx; continue
    if word in ["audio", "music", "song", "songs", "sound", "sounds", "track", "tracks", "podcast"]:
      q.addExtensions(CategoryAudio); inc idx; continue
    if word in ["document", "documents", "doc", "docs", "pdf", "pdfs"]:
      q.addExtensions(CategoryDocs); inc idx; continue
    if word in ["archive", "archives", "compressed", "zipped", "zip"]:
      q.addExtensions(CategoryArchives); inc idx; continue
    if word in ["log", "logs", "logfile", "logfiles"]:
      q.addExtensions(CategoryLogs); inc idx; continue
    if word in ["config", "configs", "configuration", "configurations", "settings", "conf", "cfg"]:
      q.addExtensions(CategoryConfig); inc idx; continue
    if word in ["spreadsheet", "spreadsheets", "sheet", "sheets", "excel"]:
      q.addExtensions(CategorySheets); inc idx; continue
    if word in ["slide", "slides", "presentation", "presentations", "ppt", "powerpoint"]:
      q.addExtensions(CategorySlides); inc idx; continue
    if word in ["code", "source", "script", "scripts", "programming"]:
      q.addExtensions(CategoryCode); inc idx; continue
    if word in ["text", "textfile", "textfiles", "plaintext", "txt"]:
      q.addExtensions(CategoryText); inc idx; continue
    if word in ["devops", "infrastructure", "infra", "docker", "kubernetes", "k8s", "deployment"]:
      q.addExtensions(CategoryDevops); inc idx; continue
    if word in ["database", "databases", "db", "sql"]:
      q.addExtensions(CategoryDatabase); inc idx; continue
    if word in ["font", "fonts", "typography"]:
      q.addExtensions(CategoryFonts); inc idx; continue

    for item in LangMap:
      let lang = item[0]
      let exts = item[1]
      if word == lang or word == lang & "s" or word == lang & "code" or word == lang & "files":
        q.addExtensions(exts); inc idx; break

    var parsedSize = false
    discard skipAny(["size", "sized", "length", "long"])
    if word in SizeGt or word in SizeLt or word in SizeEq or word in ["between", "min", "max", "around"]:
      let (minS, maxS) = parseSizeExpr()
      if minS >= 0: q.minSize = minS
      if maxS >= 0: q.maxSize = maxS
      if q.minSize >= 0 or q.maxSize >= 0:
        parsedSize = true
        continue

    if word in ["empty", "zero", "zerobytes"]:
      q.maxSize = 0; inc idx; continue
    if word in ["small", "tiny", "little", "micro"]:
      q.maxSize = 10 * 1024; inc idx; continue
    if word in ["large", "big", "huge", "massive"]:
      q.minSize = 10 * 1024 * 1024; inc idx; continue

    if parseTimeExpr(word in ["older", "before", "ancient", "old"]): continue

    if word in ["containing", "contains", "include", "includes", "with", "having", "has", "matching", "text", "content"]:
      inc idx
      textParts = @[]
      while idx < words.len:
        let w = words[idx]
        if w in ["modified", "larger", "smaller", "in", "named", "called", "older", "newer", "size", "type", "updated", "changed"]:
          break
        if w in FillerWords:
          inc idx
          continue
        textParts.add(w)
        inc idx
      if textParts.len > 0:
        q.containsText = textParts.join(" ")
      continue

    if word in ["named", "called", "name", "matching", "like", "filename"]:
      inc idx
      if idx < words.len:
        var pat = words[idx].strip(chars = {'"', '\''})
        if '*' notin pat and '?' notin pat:
          pat = "*" & pat & "*"
        q.patterns.add(pat)
        inc idx
      continue

    if word in ["in", "inside", "under", "within", "from", "located", "path", "directory", "folder"] and idx + 1 < words.len:
      let next = words[idx + 1]
      if next.startsWith("/") or next.startsWith("~") or next.startsWith("."):
        q.inDirectory = next
        idx += 2
        continue
      if idx + 2 < words.len and (words[idx + 2] == "folder" or words[idx + 2] == "directory" or words[idx + 2] == "dir"):
        q.inDirectory = next
        idx += 3
        continue

    if word in ["not", "exclude", "excluding", "without", "except", "ignore", "ignoring", "skip"]:
      inc idx
      if idx < words.len:
        q.excludePatterns.add(words[idx])
        inc idx
      continue

    if word.startsWith(".") and word.len > 1:
      q.extensions.add(word)
      q.types.incl(etFile)
      inc idx; continue

    if word.startsWith("*."):
      q.extensions.add(word[1..^1])
      q.types.incl(etFile)
      inc idx; continue

    if word.startsWith("!"):
      q.excludePatterns.add(word[1..^1])
      inc idx; continue

    if word in FillerWords or word in ActionWords or word in ModifierWords:
      inc idx; continue

    if word.len > 1 and q.patterns.len == 0 and q.extensions.len == 0:
      if '*' in word or '?' in word:
        q.patterns.add(word)
      else:
        q.patterns.add("*" & word & "*")
      inc idx
      continue

    if q.extensions.len > 0 or q.patterns.len > 0:
      inc idx
      continue

    inc idx

  if q.types == {}:
    q.types = {etFile, etDir, etLink}

  q.humanDescription = buildHumanDescription(q, query)
  result = q

type QueryToken = object
  raw: string
  norm: string
  quoted: bool

proc tokenizeQuery(query: string): seq[QueryToken] =
  ## Split on whitespace, but keep quoted phrases and the original path casing.
  ## Quoted text may contain spaces and backslash escapes.
  var current = newStringOfCap(32)
  var quote = '\0'
  var quoted = false
  var escaped = false
  template flush() =
    if current.len == 0: return
    let raw = current.strip(chars = {',', ';'})
    if raw.len > 0:
      result.add(QueryToken(raw: raw, norm: raw.toLowerAscii(), quoted: quoted))
    current.setLen(0)
    quoted = false
  for c in query:
    if escaped:
      current.add(c)
      escaped = false
    elif c == '\\' and quote != '\0':
      escaped = true
    elif quote != '\0':
      if c == quote:
        quote = '\0'
        quoted = true
      else:
        current.add(c)
    elif c == '"' or c == '\'':
      quote = c
      quoted = true
    elif c in Whitespace:
      flush()
    else:
      current.add(c)
  if escaped: current.add('\\')
  flush()

proc categoryExtensions(word: string): seq[string] =
  for item in CompoundCategories:
    if word == item[0]: return item[1]
  case word
  of "image", "images", "photo", "photos", "picture", "pictures", "pics": CategoryImages
  of "video", "videos", "movie", "movies", "film", "films", "clips": CategoryVideos
  of "audio", "music", "song", "songs", "sound", "podcast", "podcasts": CategoryAudio
  of "document", "documents", "pdf", "pdfs", "ebook", "ebooks": CategoryDocs
  of "text", "plaintext", "textfile", "textfiles": CategoryText
  of "archive", "archives", "compressed", "zip", "zipped": CategoryArchives
  of "code", "source", "scripts", "script", "programming": CategoryCode
  of "config", "configs", "configuration", "settings": CategoryConfig
  of "log", "logs", "logfile", "logfiles": CategoryLogs
  of "spreadsheet", "spreadsheets", "excel", "sheets": CategorySheets
  of "presentation", "presentations", "slides", "powerpoint": CategorySlides
  of "devops", "infrastructure", "infra", "kubernetes", "k8s": CategoryDevops
  of "database", "databases", "db": CategoryDatabase
  of "font", "fonts", "typography": CategoryFonts
  else: @[]

proc languageExtensions(word: string): seq[string] =
  var w = word
  if w.endsWith("files") and w.len > 5: w.setLen(w.len - 5)
  elif w.endsWith("code") and w.len > 4: w.setLen(w.len - 4)
  for item in LangMap:
    if w == item[0] or w == item[0] & "s": return item[1]
  @[]

proc cleanExtension(value: string): string =
  result = value.strip(chars = {'.', '*', ',', ';', ':'}).toLowerAscii()
  if result.len > 0: result = "." & result

proc parseByteToken(tokens: seq[QueryToken]; i: var int): Option[int64] =
  if i >= tokens.len: return none(int64)
  var value = tokens[i].raw.strip(chars = {',', ';'})
  var consumed = 1
  while value.len > 0 and value[0] in {'>', '<', '=', '~'}: value = value[1..^1]
  if value.len == 0: return none(int64)
  if i + 1 < tokens.len and tokens[i + 1].norm in
      ["b", "byte", "bytes", "kb", "kib", "mb", "mib", "gb", "gib", "tb", "tib"]:
    value.add(tokens[i + 1].norm)
    consumed = 2
  try:
    result = some(parseBytes(value))
    i += consumed
  except CatchableError:
    result = none(int64)

proc parseDurationTokens(tokens: seq[QueryToken]; i: var int): Option[Duration] =
  if i >= tokens.len: return none(Duration)
  let anchor = tokens[i].norm
  case anchor
  of "today", "tonight": inc i; return some(initDuration(days = 1))
  of "yesterday": inc i; return some(initDuration(days = 2))
  of "recent", "recently", "latest", "newest": inc i; return some(initDuration(days = 7))
  of "week", "weekly": inc i; return some(initDuration(days = 7))
  of "month", "monthly": inc i; return some(initDuration(days = 30))
  of "year", "yearly": inc i; return some(initDuration(days = 365))
  else: discard
  try:
    let n = parseInt(anchor)
    if i + 1 >= tokens.len: return none(Duration)
    let unit = tokens[i + 1].norm
    i += 2
    case unit
    of "s", "sec", "secs", "second", "seconds": some(initDuration(seconds = n))
    of "m", "min", "mins", "minute", "minutes": some(initDuration(minutes = n))
    of "h", "hr", "hrs", "hour", "hours": some(initDuration(hours = n))
    of "d", "day", "days": some(initDuration(days = n))
    of "w", "wk", "wks", "week", "weeks": some(initDuration(days = n * 7))
    of "mo", "month", "months": some(initDuration(days = n * 30))
    of "y", "yr", "yrs", "year", "years": some(initDuration(days = n * 365))
    else:
      i -= 2
      none(Duration)
  except CatchableError:
    try:
      let d = parseDuration(tokens[i].raw)
      inc i
      some(d)
    except CatchableError:
      none(Duration)

proc clauseBoundary(word: string): bool =
  word in ["named", "called", "containing", "contains", "content", "under",
    "inside", "located", "exclude", "excluding", "except", "without",
    "larger", "bigger", "smaller", "older", "newer", "modified", "changed",
    "updated", "sort", "order", "limit", "top", "depth", "hidden"]

proc addInterpretation(q: var ParsedQuery; text: string) =
  if text.len > 0 and text notin q.interpretation: q.interpretation.add(text)

proc parseNaturalQuery*(query: string): ParsedQuery =
  ## Turn a sentence into search filters. Quoted phrases, key:value filters,
  ## and conversational wording are understood; unfamiliar words stay in the
  ## name query instead of quietly disappearing.
  var q = ParsedQuery(minSize: -1, maxSize: -1, newerThan: none(Time),
    olderThan: none(Time), types: {}, matchMode: mmGlob,
    pathMode: pmBaseName, minDepth: 0, maxDepth: -1,
    sortKey: skNone)
  let tokens = tokenizeQuery(query)
  var i = 0
  var unknown: seq[string] = @[]

  template addExts(exts: seq[string]; label: string) =
    if exts.len > 0:
      q.addExtensions(exts)
      q.addInterpretation(label)

  while i < tokens.len:
    let token = tokens[i]
    let word = token.norm.strip(chars = {'.', ',', ';', '!', '?'})

    # Short key:value filters can be mixed into an ordinary sentence.
    let colon = token.raw.find(':')
    if colon > 0 and colon + 1 < token.raw.len:
      let key = token.raw[0..<colon].toLowerAscii()
      let value = token.raw[colon + 1..^1]
      case key
      of "ext", "extension", "format":
        for part in value.split(','):
          let ext = cleanExtension(part)
          if ext.len > 1: q.addExtensions([ext])
        q.addInterpretation("extension filter")
      of "name", "named":
        var pat = value
        if '*' notin pat and '?' notin pat: pat = "*" & pat & "*"
        q.patterns.add(pat); q.addInterpretation("name " & value)
      of "contains", "content", "text":
        q.containsText = value; q.addInterpretation("content phrase")
      of "regex", "content-re":
        q.containsRegex = value; q.addInterpretation("content regex")
      of "in", "under", "path":
        q.inDirectory = value; q.addInterpretation("under " & value)
      of "exclude", "without":
        q.excludePatterns.add(value); q.addInterpretation("exclude " & value)
      of "limit", "top":
        try: q.limit = max(0, parseInt(value))
        except CatchableError: q.warnings.add("invalid limit: " & value)
      of "depth":
        try: q.maxDepth = max(0, parseInt(value))
        except CatchableError: q.warnings.add("invalid depth: " & value)
      else:
        unknown.add(token.raw)
      inc i
      continue

    if word in TypeFile: q.types.incl(etFile); inc i; continue
    if word in TypeDir: q.types.incl(etDir); inc i; continue
    if word in TypeLink: q.types.incl(etLink); inc i; continue

    let category = categoryExtensions(word)
    if category.len > 0:
      addExts(category, word)
      inc i
      continue
    let language = languageExtensions(word)
    if language.len > 0:
      addExts(language, word & " source")
      inc i
      continue

    if word in ["extension", "extensions", "ext", "format", "formats"] and i + 1 < tokens.len:
      inc i
      for part in tokens[i].raw.split(','):
        let ext = cleanExtension(part)
        if ext.len > 1: q.addExtensions([ext])
      q.addInterpretation("extension filter")
      inc i
      continue
    if (token.raw.startsWith("*.") or token.raw.startsWith(".")) and token.raw.len > 2:
      q.addExtensions([cleanExtension(token.raw)])
      inc i
      continue

    if word in ["named", "called", "filename", "name"] and i + 1 < tokens.len:
      inc i
      var pat = tokens[i].raw
      if '*' notin pat and '?' notin pat: pat = "*" & pat & "*"
      q.patterns.add(pat)
      q.addInterpretation("name " & tokens[i].raw)
      inc i
      continue

    if word in ["containing", "contains", "content", "text", "having"] and i + 1 < tokens.len:
      inc i
      var parts: seq[string] = @[]
      if tokens[i].quoted:
        parts.add(tokens[i].raw); inc i
      else:
        while i < tokens.len and not clauseBoundary(tokens[i].norm):
          if tokens[i].norm notin ["the", "a", "an", "string", "phrase"]:
            parts.add(tokens[i].raw)
          inc i
      q.containsText = parts.join(" ")
      if q.containsText.len > 0: q.addInterpretation("content “" & q.containsText & "”")
      continue

    if word in ["under", "inside", "located", "within"] and i + 1 < tokens.len:
      if word == "within" and i + 1 < tokens.len and
          (tokens[i + 1].norm[0] in {'0'..'9'}): discard
      else:
        inc i
        if tokens[i].norm == "the" and i + 1 < tokens.len: inc i
        q.inDirectory = tokens[i].raw
        q.addInterpretation("under " & q.inDirectory)
        inc i
        if i < tokens.len and tokens[i].norm in ["folder", "directory", "dir"]: inc i
        continue
    if word == "in" and i + 1 < tokens.len and
        tokens[i + 1].norm notin ["the", "last", "past", "this"]:
      inc i
      q.inDirectory = tokens[i].raw
      q.addInterpretation("under " & q.inDirectory)
      inc i
      continue

    if word in ["exclude", "excluding", "except", "without", "ignore", "skip", "not"] and i + 1 < tokens.len:
      inc i
      if tokens[i].norm in ["named", "files", "file", "folders", "folder"] and i + 1 < tokens.len: inc i
      q.excludePatterns.add(tokens[i].raw)
      q.addInterpretation("exclude " & tokens[i].raw)
      inc i
      continue
    if token.raw.startsWith("!") and token.raw.len > 1:
      q.excludePatterns.add(token.raw[1..^1]); inc i; continue

    if token.raw.len > 1 and (token.raw[0] in {'>', '<', '=', '~'}):
      var sizeIdx = i
      let size = parseByteToken(tokens, sizeIdx)
      if size.isSome:
        if token.raw.startsWith(">="): q.minSize = size.get
        elif token.raw.startsWith(">"): q.minSize = size.get + 1
        elif token.raw.startsWith("<="): q.maxSize = size.get
        elif token.raw.startsWith("<"): q.maxSize = max(0'i64, size.get - 1)
        else: q.minSize = size.get; q.maxSize = size.get
        i = sizeIdx
        q.addInterpretation("size filter")
        continue

    if word in ["larger", "bigger", "greater", "over", "above", "more",
        "smaller", "less", "under", "below", "atleast", "atmost", "around",
        "about", "exactly", "between", "size", "at"]:
      var op = word
      inc i
      if op == "at" and i < tokens.len:
        if tokens[i].norm in ["least", "minimum"]: op = "atleast"; inc i
        elif tokens[i].norm in ["most", "maximum"]: op = "atmost"; inc i
      if i < tokens.len and tokens[i].norm in ["than", "of", "is"]: inc i
      if op == "atleast" or op == "atmost": discard
      elif op == "at" and i < tokens.len: discard
      if op == "between":
        let lo = parseByteToken(tokens, i)
        if i < tokens.len and tokens[i].norm in ["and", "to", "through"]: inc i
        let hi = parseByteToken(tokens, i)
        if lo.isSome: q.minSize = lo.get
        if hi.isSome: q.maxSize = hi.get
      else:
        let size = parseByteToken(tokens, i)
        if size.isSome:
          if op in ["smaller", "less", "under", "below", "atmost"]: q.maxSize = size.get
          elif op in ["around", "about"]:
            q.minSize = max(0'i64, size.get - size.get div 10)
            q.maxSize = size.get + size.get div 10
          elif op == "exactly": q.minSize = size.get; q.maxSize = size.get
          else: q.minSize = size.get
        else: q.warnings.add("size clause had no valid size")
      q.addInterpretation("size filter")
      continue
    if word in ["empty", "zero-byte", "zerobytes"]:
      q.minSize = 0; q.maxSize = 0; q.types.incl(etFile); inc i; continue

    if word in ["modified", "changed", "updated", "newer", "recent", "recently",
        "latest", "newest", "older", "before", "after", "within", "last", "past",
        "today", "yesterday"]:
      let older = word in ["older", "before"]
      inc i
      while i < tokens.len and tokens[i].norm in ["in", "the", "last", "past", "within", "than", "ago"]: inc i
      if word in ["today", "yesterday", "recent", "recently", "latest", "newest"]: dec i
      var absoluteTime = none(Time)
      if i < tokens.len:
        try: absoluteTime = maybeTime(tokens[i].raw)
        except CatchableError: discard
      if absoluteTime.isSome:
        if older: q.olderThan = absoluteTime else: q.newerThan = absoluteTime
        inc i
        q.addInterpretation(if older: "modified before date" else: "modified after date")
        continue
      let duration = parseDurationTokens(tokens, i)
      if duration.isSome:
        let threshold = getTime() - duration.get
        if older: q.olderThan = some(threshold) else: q.newerThan = some(threshold)
        q.addInterpretation(if older: "older than interval" else: "recent interval")
      else:
        q.warnings.add("time clause had no valid interval")
      continue

    if word in ["sort", "order", "ordered"]:
      inc i
      if i < tokens.len and tokens[i].norm == "by": inc i
      if i < tokens.len:
        case tokens[i].norm
        of "newest", "latest", "recent", "time", "modified": q.sortKey = skTime; q.reverseSort = true
        of "oldest": q.sortKey = skTime
        of "largest", "biggest", "size": q.sortKey = skSize; q.reverseSort = true
        of "smallest": q.sortKey = skSize
        of "name": q.sortKey = skName
        of "path": q.sortKey = skPath
        else: q.warnings.add("unknown sort: " & tokens[i].raw)
        inc i
      continue
    if word in ["top", "limit", "first"] and i + 1 < tokens.len:
      try:
        q.limit = max(0, parseInt(tokens[i + 1].norm)); i += 2
      except CatchableError:
        q.warnings.add("invalid result limit"); inc i
      continue
    if word in ["depth", "deep"] and i + 1 < tokens.len:
      try: q.maxDepth = max(0, parseInt(tokens[i + 1].norm)); i += 2
      except CatchableError: q.warnings.add("invalid depth"); inc i
      continue

    if word in ["hidden", "dotfiles"]: q.includeHidden = true; inc i; continue
    if word in ["follow-links", "followsymlinks", "dereference"]: q.followSymlinks = true; inc i; continue
    if word == "fuzzy": q.matchMode = mmFuzzy; q.modeExplicit = true; inc i; continue
    if word in ["regex", "regular-expression"]: q.matchMode = mmRegex; q.modeExplicit = true; inc i; continue
    if word in ["exact", "literally", "literal"]: q.matchMode = mmFixed; q.modeExplicit = true; inc i; continue
    if word in ["full-path", "pathnames", "paths"]: q.pathMode = pmFullPath; inc i; continue

    if word in FillerWords or word in ActionWords or word in ModifierWords or
        word in ["file", "files", "folder", "folders", "directory", "directories"]:
      inc i
      continue
    unknown.add(token.raw)
    inc i

  if q.types == {}: q.types = {etFile, etDir, etLink}
  if q.extensions.len == 0 and q.patterns.len == 0 and unknown.len > 0:
    var pat = unknown.join(" ")
    if '*' notin pat and '?' notin pat: pat = "*" & pat & "*"
    q.patterns.add(pat)
    q.addInterpretation("name " & unknown.join(" "))
  elif unknown.len > 0:
    q.warnings.add("uninterpreted words: " & unknown.join(" "))
  q.humanDescription = buildHumanDescription(q, query)
  if q.interpretation.len > 0:
    q.humanDescription &= " [" & q.interpretation.join("; ") & "]"
  result = q
