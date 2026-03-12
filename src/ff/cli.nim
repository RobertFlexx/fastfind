# src/ff/cli.nim
import std/[os, strutils, parseopt, times, tables, options]
import ansi, core, matchers, units, fuzzy, nlp

type
  IndexCommand* = enum
    icNone, icRebuild, icStatus, icDaemon

  RankMode* = enum
    rmNone, rmScore, rmDepth, rmRecency, rmAuto

  Config* = object
    # inputs
    patterns*: seq[string]
    paths*: seq[string]

    # matching
    matchMode*: MatchMode
    pathMode*: PathMode
    ignoreCase*: bool
    smartCase*: bool
    fullMatch*: bool

    # fuzzy
    fuzzyMode*: bool
    showFuzzyScore*: bool
    fuzzyMinScore*: int

    # filtering
    types*: set[EntryType]
    includeHidden*: bool
    followSymlinks*: bool
    excludes*: seq[string]
    oneFileSystem*: bool
    useGitignore*: bool

    minDepth*: int
    maxDepth*: int
    minSize*: int64
    maxSize*: int64
    newerThan*: Option[Time]
    olderThan*: Option[Time]

    containsText*: string
    containsRegex*: string
    maxBytes*: int
    allowBinary*: bool

    # git integration
    gitModified*: bool
    gitUntracked*: bool
    gitTracked*: bool
    gitChanged*: bool

    # semantic search
    searchFunction*: string
    searchClass*: string
    searchSymbol*: string

    # output
    outputMode*: OutputMode
    absolute*: bool
    relative*: bool
    sortKey*: SortKey
    reverse*: bool
    limit*: int
    countOnly*: bool
    stats*: bool
    quietErrors*: bool
    verbose*: bool
    colorMode*: ColorMode

    # ranking
    rankMode*: RankMode
    rankRecency*: bool
    rankDepth*: bool

    # execution / interactivity
    threads*: int
    selectMode*: bool
    execCmd*: string
    execArgs*: seq[string]
    execShell*: bool
    interactiveMode*: bool

    # index
    useIndex*: bool
    indexOnly*: bool
    indexCommand*: IndexCommand

    # natural language
    naturalQuery*: string

    # meta
    justHelp*: bool
    justVersion*: bool

    # internal
    modeExplicit: bool
    pathModeExplicit: bool
    configUsed*: string
    fdMode*: bool

const
  Version* = "fastfind 0.2.1_2"

proc applyParsedQuery*(cfg: var Config; pq: ParsedQuery)
proc defaultConfig*(): Config =
  result.matchMode = mmGlob
  result.pathMode = pmBaseName
  result.ignoreCase = false
  result.smartCase = true
  result.fullMatch = false

  result.fuzzyMode = false
  result.showFuzzyScore = false
  result.fuzzyMinScore = 0

  result.types = {etFile, etDir, etLink}
  result.includeHidden = false
  result.followSymlinks = false
  result.excludes = @[]
  result.oneFileSystem = false
  result.useGitignore = false

  result.minDepth = 0
  result.maxDepth = -1
  result.minSize = -1
  result.maxSize = -1
  result.newerThan = none(Time)
  result.olderThan = none(Time)

  result.containsText = ""
  result.containsRegex = ""
  result.maxBytes = 1024*1024
  result.allowBinary = false

  result.gitModified = false
  result.gitUntracked = false
  result.gitTracked = false
  result.gitChanged = false

  result.searchFunction = ""
  result.searchClass = ""
  result.searchSymbol = ""

  result.outputMode = omPlain
  result.absolute = false
  result.relative = false
  result.sortKey = skNone
  result.reverse = false
  result.limit = 0
  result.countOnly = false
  result.stats = false
  result.quietErrors = false
  result.verbose = false
  result.colorMode = cmAuto

  result.rankMode = rmNone
  result.rankRecency = false
  result.rankDepth = false

  result.threads = 0
  result.selectMode = false
  result.execCmd = ""
  result.execArgs = @[]
  result.execShell = false
  result.interactiveMode = false

  result.useIndex = false
  result.indexOnly = false
  result.indexCommand = icNone

  result.naturalQuery = ""

proc unquote(s: string): string =
  let t = s.strip()
  if t.len >= 2 and ((t[0] == '"' and t[^1] == '"') or (t[0] == '\'' and t[^1] == '\'')):
    return t[1..^2]
  t

proc parseBool(val: string): bool =
  let t = val.strip().toLowerAscii()
  if t in ["1", "true", "yes", "on"]: return true
  if t in ["0", "false", "no", "off"]: return false
  raise newException(ValueError, "expected boolean, got: " & val)

proc parseIntSafe*(val: string): int =
  try: parseInt(val.strip())
  except CatchableError: raise newException(ValueError, "expected int, got: " & val)

proc parseStrArray(val: string): seq[string] =
  var t = val.strip()
  if not (t.startsWith("[") and t.endsWith("]")):
    return @[unquote(t)]
  t = t[1..^2].strip()
  if t.len == 0: return @[]
  for part in t.split(","):
    let p = part.strip()
    if p.len > 0: result.add(unquote(p))

proc applyConfigMap(cfg: var Config; mp: Table[string,string]; path: string) =
  for k, v in mp:
    let key = k.strip().toLowerAscii()
    try:
      case key
      of "hidden", "include_hidden":
        cfg.includeHidden = parseBool(v)
      of "gitignore":
        cfg.useGitignore = parseBool(v)
      of "follow_symlinks":
        cfg.followSymlinks = parseBool(v)
      of "one_file_system":
        cfg.oneFileSystem = parseBool(v)
      of "threads":
        cfg.threads = max(0, parseIntSafe(v))
      of "mode":
        let m = unquote(v).toLowerAscii()
        if m == "glob": cfg.matchMode = mmGlob
        elif m == "regex": cfg.matchMode = mmRegex
        elif m == "fixed": cfg.matchMode = mmFixed
        elif m == "fuzzy": cfg.matchMode = mmFuzzy; cfg.fuzzyMode = true
      of "fuzzy":
        cfg.fuzzyMode = parseBool(v)
      of "use_index":
        cfg.useIndex = parseBool(v)
      of "path_mode":
        let m = unquote(v).toLowerAscii()
        if m in ["name", "basename"]: cfg.pathMode = pmBaseName
        elif m in ["path", "fullpath", "full_path"]: cfg.pathMode = pmFullPath
      of "ignore_case":
        cfg.ignoreCase = parseBool(v)
      of "smart_case":
        cfg.smartCase = parseBool(v)
      of "full_match":
        cfg.fullMatch = parseBool(v)
      of "max_depth":
        cfg.maxDepth = parseIntSafe(v)
      of "min_depth":
        cfg.minDepth = max(0, parseIntSafe(v))
      of "size":
        let r = parseSizeExpr(unquote(v))
        cfg.minSize = r.minSize
        cfg.maxSize = r.maxSize
      of "exclude":
        let arr = parseStrArray(v)
        for it in arr: cfg.excludes.add(it)
      of "output":
        let o = unquote(v).toLowerAscii()
        if o in ["plain"]: cfg.outputMode = omPlain
        elif o in ["long", "ls"]: cfg.outputMode = omLong
        elif o in ["json"]: cfg.outputMode = omJson
        elif o in ["ndjson"]: cfg.outputMode = omNdJson
        elif o in ["table"]: cfg.outputMode = omTable
      of "sort":
        let s = unquote(v).toLowerAscii()
        if s == "path": cfg.sortKey = skPath
        elif s == "name": cfg.sortKey = skName
        elif s == "size": cfg.sortKey = skSize
        elif s in ["time", "mtime"]: cfg.sortKey = skTime
        elif s in ["none", ""]: cfg.sortKey = skNone
      of "reverse":
        cfg.reverse = parseBool(v)
      of "stats":
        cfg.stats = parseBool(v)
      of "color":
        let c = unquote(v).toLowerAscii()
        if c == "auto": cfg.colorMode = cmAuto
        elif c == "always": cfg.colorMode = cmAlways
        elif c == "never": cfg.colorMode = cmNever
      of "max_bytes":
        cfg.maxBytes = int(parseBytes(unquote(v)))
      of "allow_binary":
        cfg.allowBinary = parseBool(v)
      else:
        discard
    except CatchableError:
      if cfg.verbose:
        stderr.writeLine("fastfind: ignoring bad config key " & key & " in " & path)

proc helpText(useColor: bool): string =
  let B = proc(s: string): string = b(s, useColor)
  let D = proc(s: string): string = dim(s, useColor)
  let C = proc(s: string): string = c(s, Cyan, useColor)
  result = ""
  result.add(B("fastfind") & " — fast file/path search\n\n")
  result.add(B("Usage") & ":\n")
  result.add("  fastfind " & C("[OPTIONS]") & " " & C("<pattern>") & " " & D("[path ...]") & "\n")
  result.add("  fastfind " & C("\"<natural language query>\"") & "\n")
  result.add("  fastfind " & C("--fd") & " " & C("<query>") & " " & D("[path ...]") & "\n\n")

  result.add(B("Pattern modes") & ":\n")
  result.add("  " & C("--glob") & "            Glob patterns (default)\n")
  result.add("  " & C("--regex") & "           Regular expressions\n")
  result.add("  " & C("--fixed") & "           Literal substring match\n")
  result.add("  " & C("--fuzzy") & "           Fuzzy matching with scoring\n")
  result.add("  " & C("--fuzzy-score") & "     Show fuzzy match scores\n")
  result.add("  " & C("--full-match") & "      Match the whole target\n")
  result.add("  " & C("--name") & "            Match basename only (default)\n")
  result.add("  " & C("--full-path") & "       Match the full relative path\n")
  result.add("  " & C("-i") & ", " & C("--ignore-case") & "     Case-insensitive\n")
  result.add("  " & C("--smart-case") & "      Ignore case unless pattern has uppercase\n\n")

  result.add(B("Traversal") & ":\n")
  result.add("  " & C("-H") & ", " & C("--hidden") & "          Include hidden files/dirs\n")
  result.add("  " & C("-L") & ", " & C("--follow") & "          Follow symlinks\n")
  result.add("  " & C("-x") & ", " & C("--one-file-system") & " Stay on one filesystem\n")
  result.add("  " & C("--gitignore") & "       Respect .gitignore\n")
  result.add("  " & C("--no-gitignore") & "    Disable gitignore\n")
  result.add("  " & C("--min-depth") & " N     Minimum depth\n")
  result.add("  " & C("--max-depth") & " N     Maximum depth\n")
  result.add("  " & C("-j") & ", " & C("--threads") & " N     Parallel traversal\n\n")

  result.add(B("Filters") & ":\n")
  result.add("  " & C("--type") & " t          t in {file,dir,link}\n")
  result.add("  " & C("--size") & " EXPR       e.g. >10M, 10K..5M, =123\n")
  result.add("  " & C("--newer") & " TIME      Only newer than TIME\n")
  result.add("  " & C("--older") & " TIME      Only older than TIME\n")
  result.add("  " & C("--changed") & " DUR     Modified within duration\n")
  result.add("  " & C("--recent") & "          Modified in last 24h\n")
  result.add("  " & C("--contains") & " TEXT   File content contains TEXT\n")
  result.add("  " & C("--contains-re") & " RE  File content matches regex\n\n")

  result.add(B("Git integration") & ":\n")
  result.add("  " & C("--git-modified") & "    Only git-modified files\n")
  result.add("  " & C("--git-untracked") & "   Only untracked files\n")
  result.add("  " & C("--git-tracked") & "     Only tracked files\n")
  result.add("  " & C("--git-changed") & "     Modified or untracked\n\n")

  result.add(B("Semantic search") & ":\n")
  result.add("  " & C("--function") & " NAME   Find function definitions\n")
  result.add("  " & C("--class") & " NAME      Find class definitions\n")
  result.add("  " & C("--symbol") & " NAME     Find any symbol\n\n")

  result.add(B("Ranking") & ":\n")
  result.add("  " & C("--rank") & "            Enable smart ranking\n")
  result.add("  " & C("--rank-recency") & "    Favor recent files\n")
  result.add("  " & C("--rank-depth") & "      Favor shallow paths\n\n")

  result.add(B("Output") & ":\n")
  result.add("  " & C("-l") & ", " & C("--long") & "          Long output (ls-like)\n")
  result.add("  " & C("--json") & "            JSON array output\n")
  result.add("  " & C("--ndjson") & "          Newline-delimited JSON\n")
  result.add("  " & C("--table") & "           Table output\n")
  result.add("  " & C("--absolute") & "        Print absolute paths\n")
  result.add("  " & C("--relative") & "        Print relative paths\n")
  result.add("  " & C("--sort") & " KEY        Sort by path/name/size/time\n")
  result.add("  " & C("-r") & ", " & C("--reverse") & "       Reverse sort order\n")
  result.add("  " & C("--limit") & " N         Stop after N matches\n")
  result.add("  " & C("-c") & ", " & C("--count") & "       Print count only\n")
  result.add("  " & C("--stats") & "           Print stats\n")
  result.add("  " & C("--color") & " MODE      auto/always/never\n\n")

  result.add(B("Interactive") & ":\n")
  result.add("  " & C("--interactive") & "     Live search UI\n")
  result.add("  " & C("--select") & "          Pick a match interactively\n\n")

  result.add(B("Index") & ":\n")
  result.add("  " & C("--use-index") & "       Query index if available\n")
  result.add("  " & C("--rebuild-index") & "   Rebuild search index\n")
  result.add("  " & C("--index-status") & "    Show index status\n")
  result.add("  " & C("--index-daemon") & "    Run index update daemon\n\n")

  result.add(B("Natural Language") & ":\n")
  result.add("  Queries like:\n")
  result.add("    \"files larger than 10mb modified yesterday\"\n")
  result.add("    \"python files containing TODO\"\n")
  result.add("    \"images modified within 7 days\"\n\n")

  result.add(B("Actions") & ":\n")
  result.add("  " & C("--exec") & " CMD        Execute CMD per match\n")
  result.add("  " & C("--exec-cmd") & " CMD    Set command\n")
  result.add("  " & C("--exec-arg") & " ARG    Add argument\n\n")

  result.add(B("Config") & ":\n")
  result.add("  " & C("--config") & " FILE     Load config file\n")
  result.add("  " & C("--no-config") & "       Don't load default config\n\n")

  result.add(B("Misc") & ":\n")
  result.add("  " & C("-v") & ", " & C("--verbose") & "\n")
  result.add("  " & C("-q") & ", " & C("--quiet-errors") & "\n")
  result.add("  " & C("-h") & ", " & C("--help") & "\n")
  result.add("  " & C("--version") & "\n")

proc printHelp*() =
  let useColor = supportsColor(cmAuto)
  stdout.write(helpText(useColor))

proc knownLongOpts(): seq[string] =
  @[
    "help","version",
    "glob","regex","fixed","fuzzy","fuzzy-score","full-match",
    "name","full-path","ignore-case","smart-case",
    "fd",
    "hidden","follow","one-file-system","gitignore","no-gitignore",
    "min-depth","max-depth","threads",
    "type","size","newer","older","changed","recent",
    "contains","contains-re","max-bytes","binary",
    "git-modified","git-untracked","git-tracked","git-changed",
    "function","class","symbol",
    "rank","rank-recency","rank-depth",
    "long","json","ndjson","table","absolute","relative","sort","reverse","limit","count","stats","color",
    "interactive","select","exec","exec-cmd","exec-arg","shell",
    "use-index","rebuild-index","index-status","index-daemon",
    "config","no-config",
    "verbose","quiet-errors"
  ]

proc knownShortOpts(): seq[string] =
  @["h","v","q","i","l","r","c","H","L","x","j"]

proc applyFdDefaults(cfg: var Config) =
  cfg.fdMode = true
  cfg.matchMode = mmFixed
  cfg.pathMode = pmFullPath
  cfg.ignoreCase = true
  cfg.smartCase = false
  cfg.fullMatch = false
  cfg.useGitignore = true
  cfg.types = {etFile, etDir, etLink}
  cfg.includeHidden = false
  cfg.modeExplicit = true
  cfg.pathModeExplicit = true

proc applyAutoMode(cfg: var Config) =
  if cfg.modeExplicit or cfg.patterns.len == 0: return
  let p = cfg.patterns[0]
  var hasGlob = false
  var hasRegex = false
  for ch in p:
    if ch in ['*','?','[',']']: hasGlob = true
    if ch in ['(',')','{','}','|','+','^','$']: hasRegex = true
  if hasRegex and not hasGlob:
    cfg.matchMode = mmRegex
  elif hasGlob:
    cfg.matchMode = mmGlob
  else:
    cfg.matchMode = mmFixed

proc applyAutoPathMode(cfg: var Config) =
  if cfg.pathModeExplicit or cfg.patterns.len == 0: return
  if '/' in cfg.patterns[0] or '\\' in cfg.patterns[0]:
    cfg.pathMode = pmFullPath

proc parseCli*(args: seq[string]): Config =
  var configPath = ""
  var skipDefault = false
  var filtered: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--no-config":
      skipDefault = true
      inc i
      continue
    if a == "--config" and i+1 < args.len:
      configPath = args[i+1]
      i += 2
      continue
    if a.startsWith("--config="):
      configPath = a.split("=", 1)[1]
      inc i
      continue
    filtered.add(a)
    inc i

  result = defaultConfig()

  if not skipDefault:
    let defPath = getHomeDir() / ".config" / "fastfind" / "config.toml"
    if fileExists(defPath):
      try:
        let mp = loadSimpleToml(defPath)
        applyConfigMap(result, mp, defPath)
        result.configUsed = defPath
      except CatchableError:
        discard

  if configPath.len > 0:
    if not fileExists(configPath):
      niceError("config file not found: " & configPath)
      quit(2)
    try:
      let mp = loadSimpleToml(configPath)
      applyConfigMap(result, mp, configPath)
      result.configUsed = configPath
    except CatchableError as e:
      niceError("failed to read config: " & e.msg)
      quit(2)

  var positionals: seq[string] = @[]

  var p = initOptParser(filtered, shortNoVal = {'h', 'v', 'q', 'l', 'r', 'c', 'H', 'L', 'x'}, longNoVal = @["help", "version", "glob", "regex", "fixed", "fuzzy", "fuzzy-score", "full-match", "name", "full-path", "ignore-case", "smart-case", "fd", "hidden", "follow", "one-file-system", "gitignore", "no-gitignore", "binary", "git-modified", "git-untracked", "git-tracked", "git-changed", "rank", "rank-recency", "rank-depth", "long", "json", "ndjson", "table", "absolute", "relative", "reverse", "count", "stats", "interactive", "select", "use-index", "rebuild-index", "index-status", "index-daemon", "shell", "verbose", "quiet-errors", "no-config", "recent"])
  try:
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        positionals.add(key)
      of cmdLongOption, cmdShortOption:
        let k = key
        let v = val

        case k
        of "h","help":
          result.justHelp = true
        of "version":
          result.justVersion = true

        of "glob":
          result.matchMode = mmGlob; result.modeExplicit = true
        of "regex":
          result.matchMode = mmRegex; result.modeExplicit = true
        of "fixed":
          result.matchMode = mmFixed; result.modeExplicit = true
        of "fuzzy":
          result.matchMode = mmFuzzy; result.fuzzyMode = true; result.modeExplicit = true
        of "fuzzy-score":
          result.showFuzzyScore = true
        of "full-match":
          result.fullMatch = true
        of "name":
          result.pathMode = pmBaseName; result.pathModeExplicit = true
        of "full-path":
          result.pathMode = pmFullPath; result.pathModeExplicit = true

        of "i","ignore-case":
          result.ignoreCase = true
        of "smart-case":
          result.smartCase = true

        of "fd":
          applyFdDefaults(result)

        of "H","hidden":
          result.includeHidden = true
        of "L","follow":
          result.followSymlinks = true
        of "x","one-file-system":
          result.oneFileSystem = true
        of "gitignore":
          result.useGitignore = true
        of "no-gitignore":
          result.useGitignore = false

        of "min-depth":
          result.minDepth = max(0, parseIntSafe(v))
        of "max-depth":
          result.maxDepth = parseIntSafe(v)

        of "j","threads":
          result.threads = max(0, parseIntSafe(v))

        of "type":
          if result.types == {etFile, etDir, etLink}: result.types = {}
          let t = v.strip().toLowerAscii()
          case t
          of "file": result.types.incl(etFile)
          of "dir":  result.types.incl(etDir)
          of "link": result.types.incl(etLink)
          else:
            niceError("unknown type: " & v)
            quit(2)

        of "exclude":
          if v.strip().len > 0: result.excludes.add(v.strip())

        of "size":
          let r = parseSizeExpr(v)
          result.minSize = r.minSize
          result.maxSize = r.maxSize
        of "newer":
          result.newerThan = maybeTime(v)
        of "older":
          result.olderThan = maybeTime(v)
        of "changed":
          let d = parseDuration(v)
          result.newerThan = some(getTime() - d)
        of "recent":
          result.newerThan = some(getTime() - initDuration(hours = 24))

        of "contains":
          result.containsText = v
        of "contains-re":
          result.containsRegex = v
        of "max-bytes":
          result.maxBytes = int(parseBytes(v))
        of "binary":
          result.allowBinary = true

        of "git-modified":
          result.gitModified = true
        of "git-untracked":
          result.gitUntracked = true
        of "git-tracked":
          result.gitTracked = true
        of "git-changed":
          result.gitChanged = true

        of "function":
          result.searchFunction = v
        of "class":
          result.searchClass = v
        of "symbol":
          result.searchSymbol = v

        of "rank":
          result.rankMode = rmAuto
        of "rank-recency":
          result.rankRecency = true
        of "rank-depth":
          result.rankDepth = true

        of "l","long":
          result.outputMode = omLong
        of "json":
          result.outputMode = omJson
        of "ndjson":
          result.outputMode = omNdJson
        of "table":
          result.outputMode = omTable
        of "absolute":
          result.absolute = true
        of "relative":
          result.relative = true
        of "sort":
          let s = v.strip().toLowerAscii()
          case s
          of "path": result.sortKey = skPath
          of "name": result.sortKey = skName
          of "size": result.sortKey = skSize
          of "time","mtime": result.sortKey = skTime
          of "none","": result.sortKey = skNone
          else:
            niceError("unknown sort key: " & v)
            quit(2)
        of "r","reverse":
          result.reverse = true
        of "limit":
          result.limit = max(0, parseIntSafe(v))
        of "c","count":
          result.countOnly = true
        of "stats":
          result.stats = true
        of "color":
          let c = v.strip().toLowerAscii()
          case c
          of "auto": result.colorMode = cmAuto
          of "always": result.colorMode = cmAlways
          of "never": result.colorMode = cmNever
          else:
            niceError("unknown color mode: " & v)
            quit(2)

        of "interactive":
          result.interactiveMode = true
        of "select":
          result.selectMode = true

        of "use-index":
          result.useIndex = true
        of "rebuild-index":
          result.indexCommand = icRebuild
        of "index-status":
          result.indexCommand = icStatus
        of "index-daemon":
          result.indexCommand = icDaemon

        of "exec":
          if v.strip().len == 0:
            niceError("--exec requires a commandline string")
            quit(2)
          result.execCmd = v
          result.execArgs = @[]
          result.execShell = true
        of "exec-cmd":
          result.execCmd = v
        of "exec-arg":
          result.execArgs.add(v)
        of "shell":
          result.execShell = true

        of "v","verbose":
          result.verbose = true
        of "q","quiet-errors":
          result.quietErrors = true
        else:
          niceError("unknown option: --" & k)
          quit(2)

      of cmdEnd: discard
  except ValueError as e:
    let msg = e.msg
    if "unknown option:" in msg:
      let bad = msg.split("unknown option:")[1].strip()
      if bad.startsWith("--"):
        printUnknownOption(bad, knownLongOpts())
      else:
        printUnknownShort(bad, knownShortOpts())
    else:
      niceError(msg)
    quit(2)

  # handle positional arguments
  if result.patterns.len == 0 and positionals.len > 0:
    let firstArg = positionals[0]
    
    # check if its a natural language query
    if isNaturalLanguageQuery(firstArg):
      result.naturalQuery = firstArg
      let parsed = parseNaturalQuery(firstArg)
      applyParsedQuery(result, parsed)
      if positionals.len > 1:
        result.paths = positionals[1..^1]
    else:
      result.patterns.add(firstArg)
      if positionals.len > 1:
        result.paths = positionals[1..^1]
  else:
    result.paths = positionals

  if result.justHelp:
    printHelp()
    return
  if result.justVersion:
    stdout.writeLine(Version)
    return

  # allow index commands without patterns
  if result.patterns.len == 0 and result.indexCommand == icNone and 
     not result.interactiveMode and result.naturalQuery.len == 0 and
     result.searchFunction.len == 0 and result.searchClass.len == 0 and
     result.searchSymbol.len == 0 and
     not (result.gitModified or result.gitUntracked or result.gitTracked or result.gitChanged) and
     not (result.minSize >= 0 or result.maxSize >= 0 or
          result.newerThan.isSome or result.olderThan.isSome or
          result.containsText.len > 0 or result.containsRegex.len > 0):
    niceError("missing <pattern>")
    printHelp()
    quit(2)

  # allow git/semantic filters without explicit pattern
  if result.patterns.len == 0:
    if result.gitModified or result.gitUntracked or result.gitTracked or result.gitChanged:
      result.patterns = @["*"]
    if result.minSize >= 0 or result.maxSize >= 0 or result.newerThan.isSome or result.olderThan.isSome or result.containsText.len > 0 or result.containsRegex.len > 0:
      result.patterns = @["*"]
    if result.searchFunction.len > 0 or result.searchClass.len > 0 or result.searchSymbol.len > 0:
      result.patterns = @["*"]

  if result.paths.len == 0:
    result.paths = @["."]

  applyAutoMode(result)
  applyAutoPathMode(result)

  # auto enable fuzzy ranking when fuzzy mode is on
  if result.fuzzyMode and result.rankMode == rmNone:
    result.rankMode = rmScore
proc applyParsedQuery*(cfg: var Config; pq: ParsedQuery) =
  ## apply parsed natural language query to config
  
  if pq.patterns.len > 0:
    cfg.patterns = pq.patterns
  
  if pq.minSize >= 0:
    cfg.minSize = pq.minSize
  
  if pq.maxSize >= 0:
    cfg.maxSize = pq.maxSize
  
  if pq.newerThan.isSome:
    cfg.newerThan = pq.newerThan
  
  if pq.olderThan.isSome:
    cfg.olderThan = pq.olderThan
  
  if pq.types != {}:
    cfg.types = pq.types
  
  if pq.containsText.len > 0:
    cfg.containsText = pq.containsText
  
  # convert extensions to glob patterns
  if pq.extensions.len > 0:
    for ext in pq.extensions:
      cfg.patterns.add("*" & ext)
    cfg.matchMode = pq.matchMode
  
  if pq.excludePatterns.len > 0:
    for ex in pq.excludePatterns:
      cfg.excludes.add("*" & ex & "*")
  
  if pq.inDirectory.len > 0:
    cfg.paths = @[pq.inDirectory]
