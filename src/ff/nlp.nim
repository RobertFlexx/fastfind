# src/ff/nlp.nim
## natural language query parser
## converts human readable queries to filter parameters
import std/[strutils, times, options, sequtils, sets, os, re]
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
    notContainsText*: seq[string]
    ignoreCase*: bool
    fullMatch*: bool
    countOnly*: bool
    gitTracked*, gitUntracked*, gitModified*: bool
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
    "whose", "their", "both", "either", "written", "coded", "programmed",
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
    if (" " & qlc & " ").contains(" " & compound & " "): return true

  for item in LangMap:
    let lang = item[0]
    if qlc.contains(" " & lang & " ") or qlc.contains(" " & lang & "s ") or qlc.contains(" " & lang & " code"): return true

  for word in words:
    if word in ["files", "folders", "directories", "symlinks", "largest", "smallest", "newest", "oldest"] or
        word.startsWith("ext:") or word.startsWith("name:") or word.startsWith("contains:"):
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

type QueryToken = object
  raw: string
  norm: string
  quoted: bool

proc tokenizeQuery(query: string): seq[QueryToken] =
  var current = newStringOfCap(32)
  var quote = '\0'
  var quoted = false
  var i = 0
  template flush() =
    if current.len > 0:
      let raw = current.strip(chars = {',', ';'})
      if raw.len > 0:
        result.add(QueryToken(raw: raw, norm: raw.toLowerAscii(), quoted: quoted))
    current.setLen(0)
    quoted = false
  while i < query.len:
    let c = query[i]
    if quote != '\0':
      if c == quote: quote = '\0'
      elif c == '\\' and i + 1 < query.len and query[i + 1] in {quote, '\\'}:
        inc i
        current.add(query[i])
      else: current.add(c)
    elif c in {'"', '\''} and (current.len == 0 or current[^1] == ':'):
      quote = c
      quoted = true
    elif c in Whitespace: flush()
    else: current.add(c)
    inc i
  flush()

proc numberValue(value: string): Option[float] =
  case value
  of "a", "an", "one": some(1.0)
  of "two", "couple": some(2.0)
  of "three", "few": some(3.0)
  of "four": some(4.0)
  of "five": some(5.0)
  of "six": some(6.0)
  of "seven": some(7.0)
  of "eight": some(8.0)
  of "nine": some(9.0)
  of "ten": some(10.0)
  of "eleven": some(11.0)
  of "twelve": some(12.0)
  of "fifteen": some(15.0)
  of "twenty": some(20.0)
  of "thirty": some(30.0)
  of "hundred": some(100.0)
  else:
    try:
      let n = parseFloat(value)
      if n >= 0 and n <= 1_000_000_000: some(n) else: none(float)
    except ValueError: none(float)

proc integerValue(value: string): int =
  let number = numberValue(value)
  if number.isNone: raise newException(ValueError, "invalid number: " & value)
  int(number.get)

proc calendarRange(word: string; now: Time): tuple[valid: bool, lower, upper: Time] =
  let date = now.local
  let midnight = dateTime(date.year, date.month, date.monthday, zone = date.timezone)
  var lower = midnight
  var upper = midnight + initTimeInterval(days = 1)
  case word
  of "today", "tonight": discard
  of "yesterday": lower = midnight - initTimeInterval(days = 1); upper = midnight
  of "this-week", "last-week":
    lower = midnight - initTimeInterval(days = ord(date.weekDay))
    upper = lower + initTimeInterval(days = 7)
    if word == "last-week": upper = lower; lower = lower - initTimeInterval(days = 7)
  of "this-month", "last-month":
    lower = dateTime(date.year, date.month, 1, zone = date.timezone)
    upper = lower + initTimeInterval(months = 1)
    if word == "last-month": upper = lower; lower = lower - initTimeInterval(months = 1)
  of "this-year", "last-year":
    lower = dateTime(date.year, mJan, 1, zone = date.timezone)
    upper = lower + initTimeInterval(years = 1)
    if word == "last-year": upper = lower; lower = lower - initTimeInterval(years = 1)
  else: return
  (true, lower.toTime, upper.toTime)

proc normalizedTokens(query: string): seq[QueryToken] =
  let source = tokenizeQuery(query)
  var i = 0
  while i < source.len:
    var token = source[i]
    if not token.quoted:
      let word = token.norm
      case word
      of "modifed", "modfied": token.norm = "modified"
      of "contaning", "containg": token.norm = "contains"
      of "exlcuding", "exluding": token.norm = "exclude"
      of "pyhton": token.norm = "python"
      of "javascritp": token.norm = "javascript"
      of "names", "filenames": token.norm = "name"
      else: discard
      if word in ["this", "last", "previous"] and i + 1 < source.len and
          source[i + 1].norm in ["week", "month", "year"]:
        token.norm = (if word == "this": "this-" else: "last-") & source[i + 1].norm
        token.raw = token.norm
        inc i
      elif word in ["doesn't", "don't", "isn't", "aren't", "isnt", "dont", "doesnt"]:
        token.norm = "not"
      elif word in ["containing", "include", "includes", "contain"]: token.norm = "contains"
      elif word in ["excluding", "except", "ignoring", "ignore", "skipping", "skip"] and
          not (i + 1 < source.len and source[i + 1].norm == "case"): token.norm = "exclude"
      elif word in ["sorted", "ordered", "arranged"]: token.norm = "sort"
      elif word in ["changed", "updated", "edited", "touched", "saved"]: token.norm = "modified"
      elif word in ["kilobyte", "kilobytes"]: token.raw = "KB"; token.norm = "kb"
      elif word in ["megabyte", "megabytes"]: token.raw = "MB"; token.norm = "mb"
      elif word in ["gigabyte", "gigabytes"]: token.raw = "GB"; token.norm = "gb"
      elif word in ["terabyte", "terabytes"]: token.raw = "TB"; token.norm = "tb"
      elif word in ["kibibyte", "kibibytes"]: token.raw = "KiB"; token.norm = "kib"
      elif word in ["mebibyte", "mebibytes"]: token.raw = "MiB"; token.norm = "mib"
      elif word in ["gibibyte", "gibibytes"]: token.raw = "GiB"; token.norm = "gib"
    result.add(token)
    inc i

proc resolvedLocation(value: string): string =
  if value == "~": return getHomeDir()
  if value.startsWith("~/"): return getHomeDir() / value[2..^1]
  case value.toLowerAscii()
  of "home": getHomeDir()
  of "downloads": getHomeDir() / "Downloads"
  of "documents": getHomeDir() / "Documents"
  of "desktop": getHomeDir() / "Desktop"
  of "pictures", "photos": getHomeDir() / "Pictures"
  of "music": getHomeDir() / "Music"
  of "videos": getHomeDir() / "Videos"
  of "here", "current", "cwd": "."
  else: value

proc categoryExtensions(word: string): seq[string] =
  let singular = if word.endsWith("s"): word[0..^2] else: word
  if singular in ["pdf", "png", "jpg", "jpeg", "gif", "svg", "webp", "mp4", "mkv", "mp3", "wav", "flac", "zip", "rar", "7z"]:
    return @["." & singular]
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
    if w == item[0] or w == item[0] & "s":
      for ext in item[1]:
        if ext notin result: result.add(ext)

proc cleanExtension(value: string): string =
  result = value.strip(chars = {'.', '*', ',', ';', ':'}).toLowerAscii()
  if result.len > 0: result = "." & result

proc parseByteToken(tokens: seq[QueryToken]; i: var int): Option[int64] =
  if i >= tokens.len: return none(int64)
  var value = tokens[i].raw.strip(chars = {',', ';'})
  let quantity = numberValue(value.toLowerAscii())
  if quantity.isSome: value = $quantity.get
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
    let quantity = numberValue(anchor)
    if quantity.isNone: raise newException(ValueError, "not a quantity")
    let n = quantity.get
    if i + 1 >= tokens.len: return none(Duration)
    let unit = tokens[i + 1].norm
    i += 2
    case unit
    of "s", "sec", "secs", "second", "seconds": some(initDuration(nanoseconds = int64(n * 1_000_000_000)))
    of "m", "min", "mins", "minute", "minutes": some(initDuration(seconds = int64(n * 60)))
    of "h", "hr", "hrs", "hour", "hours": some(initDuration(seconds = int64(n * 3600)))
    of "d", "day", "days": some(initDuration(seconds = int64(n * 86400)))
    of "w", "wk", "wks", "week", "weeks": some(initDuration(seconds = int64(n * 604800)))
    of "mo", "month", "months": some(initDuration(seconds = int64(n * 2592000)))
    of "y", "yr", "yrs", "year", "years": some(initDuration(seconds = int64(n * 31536000)))
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
    "updated", "sort", "sorted", "order", "limit", "top", "depth", "hidden",
    "in", "from", "over", "above", "below", "at", "between", "before", "after",
    "this-week", "last-week", "this-month", "last-month", "this-year", "last-year"]

proc addInterpretation(q: var ParsedQuery; text: string) =
  if text.len > 0 and text notin q.interpretation: q.interpretation.add(text)

proc parseNaturalQuery*(query: string; now: Time = getTime()): ParsedQuery =
  ## Turn a sentence into search filters. Quoted phrases, key:value filters,
  ## and conversational wording are understood; unfamiliar words stay in the
  ## name query instead of quietly disappearing.
  var q = ParsedQuery(minSize: -1, maxSize: -1, newerThan: none(Time),
    olderThan: none(Time), types: {}, matchMode: mmGlob,
    pathMode: pmBaseName, minDepth: 0, maxDepth: -1,
    sortKey: skNone)
  let tokens = normalizedTokens(query)
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
        if not q.fullMatch and '*' notin pat and '?' notin pat: pat = "*" & pat & "*"
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

    if token.quoted:
      unknown.add(token.raw)
      inc i
      continue
    if word == "how" and i + 1 < tokens.len and tokens[i + 1].norm == "many":
      q.countOnly = true; i += 2; q.addInterpretation("count matches"); continue
    if word in ["count", "counting"]:
      q.countOnly = true; inc i; q.addInterpretation("count matches"); continue
    if word in ["case-insensitive", "insensitive", "ignore-case"]:
      q.ignoreCase = true; inc i; continue
    if word == "ignoring" and i + 1 < tokens.len and tokens[i + 1].norm == "case":
      q.ignoreCase = true; i += 2; continue
    if word == "git" and i + 1 < tokens.len and tokens[i + 1].norm in ["tracked", "untracked", "modified", "changed"]:
      inc i
      continue
    if word in ["tracked", "git-tracked"]: q.gitTracked = true; inc i; continue
    if word in ["untracked", "git-untracked"]: q.gitUntracked = true; inc i; continue
    if word in ["git-modified", "git-changed"]: q.gitModified = true; inc i; continue
    if word in ["largest", "biggest", "smallest", "oldest", "newest", "latest"]:
      q.sortKey = if word in ["largest", "biggest", "smallest"]: skSize else: skTime
      q.reverseSort = word notin ["smallest", "oldest"]
      inc i
      if i < tokens.len:
        let amount = numberValue(tokens[i].norm)
        if amount.isSome: q.limit = int(amount.get); inc i
      q.addInterpretation("sort " & word)
      continue
    if numberValue(word).isSome and i + 1 < tokens.len and tokens[i + 1].norm in
        ["largest", "biggest", "smallest", "oldest", "newest", "latest"]:
      q.limit = int(numberValue(word).get); inc i; continue
    if word in ["ascending", "asc", "alphabetical", "alphabetically", "a-z"]:
      if q.sortKey == skNone: q.sortKey = skName
      q.reverseSort = false; inc i; continue
    if word in ["descending", "desc", "z-a"]:
      if q.sortKey == skNone: q.sortKey = skName
      q.reverseSort = true; inc i; continue
    if word in ["starting", "starts", "beginning", "begins", "ending", "ends"]:
      let suffix = word in ["ending", "ends"]
      inc i
      if i < tokens.len and tokens[i].norm in ["with", "in"]: inc i
      if i < tokens.len:
        q.patterns.add(if suffix: "*" & tokens[i].raw else: tokens[i].raw & "*")
        q.addInterpretation(if suffix: "name suffix" else: "name prefix")
        inc i
      continue
    if word == "exactly" and i + 1 < tokens.len and tokens[i + 1].norm in ["named", "called"]:
      q.fullMatch = true
      inc i
      continue
    if word in ["without", "not", "exclude"] and i + 1 < tokens.len:
      var j = i + 1
      while j < tokens.len and tokens[j].norm in ["any", "the", "files", "file", "named", "called", "that", "do", "does"]: inc j
      if j < tokens.len and tokens[j].norm in ["contains", "containing", "contain", "content", "text"]:
        inc j
        while j < tokens.len and tokens[j].norm in ["the", "word", "string", "phrase"]: inc j
        if j < tokens.len:
          q.notContainsText.add(tokens[j].raw)
          inc j
          while j + 1 < tokens.len and tokens[j].norm in ["or", "and"]:
            q.notContainsText.add(tokens[j + 1].raw)
            j += 2
          q.addInterpretation("exclude content phrases")
          i = j
          continue
      if j < tokens.len and tokens[j].norm in ["modified", "changed", "updated"]:
        var k = j + 1
        while k < tokens.len and tokens[k].norm in ["in", "the", "last", "past", "for", "within"]: inc k
        let duration = parseDurationTokens(tokens, k)
        if duration.isSome:
          q.olderThan = some(now - duration.get)
          q.addInterpretation("not modified in interval")
          i = k
          continue
      if j < tokens.len and tokens[j].norm == "empty":
        q.minSize = 1; i = j + 1; continue
      if j < tokens.len:
        while j < tokens.len:
          let ext = languageExtensions(tokens[j].norm)
          let category = categoryExtensions(tokens[j].norm)
          if ext.len > 0 or category.len > 0:
            for e in (if ext.len > 0: ext else: category): q.excludePatterns.add("*" & e)
          else: q.excludePatterns.add(tokens[j].raw)
          inc j
          if j < tokens.len and tokens[j].norm in ["and", "or"]: inc j
          else: break
        q.addInterpretation("exclude names or types")
        i = j
        continue
    if word == "with" and i + 2 < tokens.len and tokens[i + 1].norm in ["text", "content", "word", "string", "phrase"]:
      q.containsText = tokens[i + 2].raw
      q.addInterpretation("content phrase")
      i += 3
      continue

    if word == "in" and i + 1 < tokens.len and not tokens[i + 1].quoted:
      let language = languageExtensions(tokens[i + 1].norm)
      if language.len > 0:
        q.addExtensions(language); i += 2; q.addInterpretation("language filter"); continue
    if word in ["non-empty", "nonempty"]:
      q.minSize = 1; q.types.incl(etFile); inc i; continue
    if word in ["large", "big", "small", "tiny"]:
      q.sortKey = skSize
      q.reverseSort = word in ["large", "big"]
      q.addInterpretation("sort by size")
      inc i
      continue
    if word in ["with", "having"]:
      var j = i + 1
      while j < tokens.len and not clauseBoundary(tokens[j].norm): inc j
      if j < tokens.len and tokens[j].norm == "in":
        var k = j + 1
        if k < tokens.len and tokens[k].norm in ["the", "their", "its"]: inc k
        if k < tokens.len and tokens[k].norm in ["name", "filename"]:
          var phrase: seq[string]
          for n in i + 1..<j: phrase.add(tokens[n].raw)
          q.patterns.add("*" & phrase.join(" ") & "*")
          q.addInterpretation("name phrase")
          i = k + 1
          continue
    if word in ["name", "filename"] and i + 1 < tokens.len and tokens[i + 1].norm == "contains":
      i += 2
      if i < tokens.len:
        q.patterns.add("*" & tokens[i].raw & "*")
        q.addInterpretation("name contains")
        inc i
      continue

    if word in ["document", "documents", "doc", "docs"]:
      q.addExtensions(CategoryDocs); inc i; continue
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

    if word in ["named", "called", "filename", "name", "matching"] and i + 1 < tokens.len:
      inc i
      if tokens[i].norm in ["is", "like", "matches"] and i + 1 < tokens.len: inc i
      while i < tokens.len:
        var pat = tokens[i].raw
        if not q.fullMatch and q.matchMode != mmRegex and pat.find({'*', '?', '['}) < 0:
          pat = "*" & pat & "*"
        q.patterns.add(pat)
        q.addInterpretation("name " & tokens[i].raw)
        inc i
        if i + 1 < tokens.len and tokens[i].norm == "or": inc i
        else: break
      continue

    if word in ["containing", "contains", "content", "text", "having", "word", "string", "phrase"] and i + 1 < tokens.len:
      inc i
      var regex = false
      if tokens[i].norm in ["regex", "regular-expression"]:
        regex = true; inc i
      while i < tokens.len and tokens[i].norm in ["the", "a", "an", "word", "string", "phrase", "text"]: inc i
      var parts: seq[string] = @[]
      var connector = ""
      while i < tokens.len:
        parts.add(tokens[i].raw)
        let quoted = tokens[i].quoted
        inc i
        if i + 1 < tokens.len and tokens[i].norm in ["and", "or"]:
          connector = tokens[i].norm
          inc i
        elif quoted or i >= tokens.len or clauseBoundary(tokens[i].norm): break
      if regex:
        q.containsRegex = parts.join(" ")
      elif connector == "or":
        q.containsRegex = "(?:" & parts.mapIt(escapeRe(it)).join("|") & ")"
      elif connector == "and":
        q.containsRegex = "(?s)\\A" & parts.mapIt("(?=.*" & escapeRe(it) & ")").join("")
      else: q.containsText = parts.join(" ")
      q.addInterpretation("content " & (if connector.len > 0: connector else: "phrase"))
      continue

    if word in ["under", "inside", "located", "within"] and i + 1 < tokens.len:
      if word in ["within", "under"] and i + 1 < tokens.len and
          numberValue(tokens[i + 1].norm).isSome: discard
      else:
        inc i
        if tokens[i].norm in ["the", "my", "our"] and i + 1 < tokens.len: inc i
        q.inDirectory = if tokens[i].quoted: tokens[i].raw else: resolvedLocation(tokens[i].raw)
        q.addInterpretation("under " & q.inDirectory)
        inc i
        if i < tokens.len and tokens[i].norm in ["folder", "directory", "dir"]: inc i
        continue
    if word in ["in", "from", "beneath", "below"] and i + 1 < tokens.len and
        tokens[i + 1].norm notin ["last", "past", "this", "this-week", "this-month", "this-year", "last-week", "last-month", "last-year", "today", "yesterday"] and
        (word != "below" or numberValue(tokens[i + 1].norm).isNone):
      inc i
      if tokens[i].norm in ["the", "my", "our"] and i + 1 < tokens.len: inc i
      q.inDirectory = if tokens[i].quoted: tokens[i].raw else: resolvedLocation(tokens[i].raw)
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

    if word == "between" and i + 1 < tokens.len and '-' in tokens[i + 1].raw:
      var j = i + 1
      try:
        let lower = maybeTime(tokens[j].raw)
        inc j
        if j < tokens.len and tokens[j].norm in ["and", "to", "through"]: inc j
        if j < tokens.len:
          let upper = maybeTime(tokens[j].raw)
          if lower.isSome and upper.isSome:
            q.newerThan = some(lower.get - initDuration(nanoseconds = 1))
            q.olderThan = some(upper.get + (if tokens[j].raw.len == 10: initDuration(days = 1) else: initDuration()))
            q.addInterpretation("modified between dates")
            i = j + 1
            continue
      except CatchableError: discard

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
        let loStart = i
        var lo = parseByteToken(tokens, i)
        let loEnd = i
        if i < tokens.len and tokens[i].norm in ["and", "to", "through"]: inc i
        let hiStart = i
        let hi = parseByteToken(tokens, i)
        if lo.isSome and hi.isSome and loEnd == loStart + 1 and
            numberValue(tokens[loStart].norm).isSome and hiStart < tokens.len:
          var unit = ""
          for c in tokens[hiStart].norm:
            if c.isAlphaAscii: unit.add(c)
          if i > hiStart + 1: unit = tokens[i - 1].norm
          if unit.len > 0:
            try: lo = some(parseBytes($numberValue(tokens[loStart].norm).get & unit))
            except CatchableError: discard
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
        "older", "before", "after", "since", "on", "within", "last", "past", "today", "yesterday",
        "this-week", "last-week", "this-month", "last-month", "this-year", "last-year", "unmodified"]:
      var older = word in ["older", "before", "unmodified"]
      var onDate = word == "on"
      inc i
      while i < tokens.len and tokens[i].norm in ["in", "the", "last", "past", "within", "than", "ago", "for", "on", "after", "since", "before"]:
        if tokens[i].norm == "before": older = true
        if tokens[i].norm == "on": onDate = true
        inc i
      if word in ["today", "yesterday", "recent", "recently", "this-week", "last-week", "this-month", "last-month", "this-year", "last-year"]: dec i
      if i < tokens.len:
        let calendar = calendarRange(tokens[i].norm, now)
        if calendar.valid:
          q.newerThan = some(calendar.lower - initDuration(nanoseconds = 1))
          q.olderThan = some(calendar.upper)
          inc i
          q.addInterpretation("calendar date range")
          continue
        var absoluteTime = none(Time)
        try: absoluteTime = maybeTime(tokens[i].raw)
        except CatchableError: discard
        if absoluteTime.isSome:
          if older: q.olderThan = absoluteTime
          elif onDate:
            q.newerThan = some(absoluteTime.get - initDuration(nanoseconds = 1))
            q.olderThan = some(absoluteTime.get + initDuration(days = 1))
          else: q.newerThan = absoluteTime
          inc i
          q.addInterpretation("modified date")
          continue
      let duration = parseDurationTokens(tokens, i)
      if duration.isSome:
        let threshold = now - duration.get
        if older: q.olderThan = some(threshold)
        else: q.newerThan = some(threshold)
        if i < tokens.len and tokens[i].norm == "ago": inc i
        q.addInterpretation(if older: "older than interval" else: "recent interval")
      else: q.warnings.add("time clause had no valid interval")
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
        q.limit = max(0, integerValue(tokens[i + 1].norm)); i += 2
      except CatchableError:
        q.warnings.add("invalid result limit"); inc i
      continue
    if word in ["depth", "deep"] and i + 1 < tokens.len:
      try: q.maxDepth = max(0, integerValue(tokens[i + 1].norm)); i += 2
      except CatchableError: q.warnings.add("invalid depth"); inc i
      continue

    if word in ["hidden", "dotfiles"]: q.includeHidden = true; inc i; continue
    if word in ["follow-links", "followsymlinks", "dereference"]: q.followSymlinks = true; inc i; continue
    if word == "fuzzy": q.matchMode = mmFuzzy; q.modeExplicit = true; inc i; continue
    if word in ["regex", "regular-expression"]: q.matchMode = mmRegex; q.modeExplicit = true; inc i; continue
    if word in ["exact", "literally", "literal"]: q.matchMode = mmFixed; q.fullMatch = true; q.modeExplicit = true; inc i; continue
    if word in ["full-path", "pathnames", "paths"]: q.pathMode = pmFullPath; inc i; continue

    if word in FillerWords or word in ActionWords or word in ModifierWords or
        word in ["file", "files", "folder", "folders", "directory", "directories"]:
      inc i
      continue
    unknown.add(token.raw)
    inc i

  if q.types == {}: q.types = {etFile, etDir, etLink}
  if q.patterns.len == 0 and unknown.len > 0:
    var pat = unknown.join(" ")
    if '*' notin pat and '?' notin pat: pat = "*" & pat & "*"
    q.patterns.add(pat)
    q.addInterpretation("name " & unknown.join(" "))
  elif unknown.len > 0:
    q.warnings.add("uninterpreted words: " & unknown.join(" "))
  if q.minSize >= 0 and q.maxSize >= 0 and q.minSize > q.maxSize:
    q.warnings.add("minimum size exceeds maximum size; no files can match")
  if q.newerThan.isSome and q.olderThan.isSome and q.newerThan.get >= q.olderThan.get:
    q.warnings.add("modified date range is empty")
  q.humanDescription = buildHumanDescription(q, query)
  if q.interpretation.len > 0:
    q.humanDescription &= " [" & q.interpretation.join("; ") & "]"
  result = q
