import std/[os, strutils, parseopt, times, tables, options, cpuinfo]
import ansi, core, matchers, units, fuzzy, nlp

type
  IndexCommand* = enum
    icNone, icRebuild, icStatus, icDaemon

  RankMode* = enum
    rmNone, rmScore, rmDepth, rmRecency, rmAuto

  Config* = object
    patterns*: seq[string]
    paths*: seq[string]
    matchMode*: MatchMode
    pathMode*: PathMode
    ignoreCase*: bool
    smartCase*: bool
    fullMatch*: bool
    fuzzyMode*: bool
    showFuzzyScore*: bool
    fuzzyMinScore*: int
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
    gitModified*: bool
    gitUntracked*: bool
    gitTracked*: bool
    gitChanged*: bool
    searchFunction*: string
    searchClass*: string
    searchSymbol*: string
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
    rankMode*: RankMode
    rankRecency*: bool
    rankDepth*: bool
    threads*: int
    selectMode*: bool
    execCmd*: string
    execArgs*: seq[string]
    execShell*: bool
    interactiveMode*: bool
    useIndex*: bool
    indexOnly*: bool
    indexCommand*: IndexCommand
    naturalQuery*: string
    justHelp*: bool
    justVersion*: bool
    modeExplicit*: bool
    pathModeExplicit*: bool
    configUsed*: string
    fdMode*: bool

const
  Version* = "fastfind 1.0.0"
  
  ShortOptsWithValue = {'j', 't', 'd', 'e', 's', 'n'}
  ShortOptsNoValue = {'h', 'v', 'q', 'l', 'r', 'c', 'H', 'L', 'x', 'i', 'f'}
  
  LongOptsNoValue = @[
    "help", "version", "glob", "regex", "fixed", "fuzzy", "fuzzy-score",
    "full-match", "name", "full-path", "ignore-case", "smart-case", "fd",
    "hidden", "follow", "one-file-system", "gitignore", "no-gitignore",
    "binary", "git-modified", "git-untracked", "git-tracked", "git-changed",
    "rank", "rank-recency", "rank-depth", "long", "json", "ndjson", "table",
    "absolute", "relative", "reverse", "count", "stats", "interactive",
    "select", "use-index", "rebuild-index", "index-status", "index-daemon",
    "shell", "verbose", "quiet-errors", "no-config", "recent"
  ]

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
  result.maxBytes = 1024 * 1024
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
  result.threads = countProcessors()
  result.selectMode = false
  result.execCmd = ""
  result.execArgs = @[]
  result.execShell = false
  result.interactiveMode = false
  result.useIndex = false
  result.indexOnly = false
  result.indexCommand = icNone
  result.naturalQuery = ""
  result.modeExplicit = false
  result.pathModeExplicit = false

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
  let cleaned = val.strip()
  if cleaned.len == 0:
    raise newException(ValueError, "expected int, got empty string")
  try:
    result = parseInt(cleaned)
  except CatchableError:
    raise newException(ValueError, "expected int, got: " & val)

proc parseStrArray(val: string): seq[string] =
  var t = val.strip()
  if not (t.startsWith("[") and t.endsWith("]")):
    return @[unquote(t)]
  t = t[1..^2].strip()
  if t.len == 0: return @[]
  for part in t.split(","):
    let p = part.strip()
    if p.len > 0: result.add(unquote(p))

proc applyConfigMap(cfg: var Config; mp: Table[string, string]; path: string) =
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
        case m
        of "glob": cfg.matchMode = mmGlob
        of "regex": cfg.matchMode = mmRegex
        of "fixed": cfg.matchMode = mmFixed
        of "fuzzy":
          cfg.matchMode = mmFuzzy
          cfg.fuzzyMode = true
        else: discard
      of "fuzzy":
        cfg.fuzzyMode = parseBool(v)
      of "use_index":
        cfg.useIndex = parseBool(v)
      of "path_mode":
        let m = unquote(v).toLowerAscii()
        case m
        of "name", "basename": cfg.pathMode = pmBaseName
        of "path", "fullpath", "full_path": cfg.pathMode = pmFullPath
        else: discard
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
        for item in parseStrArray(v):
          cfg.excludes.add(item)
      of "output":
        let o = unquote(v).toLowerAscii()
        case o
        of "plain": cfg.outputMode = omPlain
        of "long", "ls": cfg.outputMode = omLong
        of "json": cfg.outputMode = omJson
        of "ndjson": cfg.outputMode = omNdJson
        of "table": cfg.outputMode = omTable
        else: discard
      of "sort":
        let s = unquote(v).toLowerAscii()
        case s
        of "path": cfg.sortKey = skPath
        of "name": cfg.sortKey = skName
        of "size": cfg.sortKey = skSize
        of "time", "mtime": cfg.sortKey = skTime
        of "none", "": cfg.sortKey = skNone
        else: discard
      of "reverse":
        cfg.reverse = parseBool(v)
      of "stats":
        cfg.stats = parseBool(v)
      of "color":
        let c = unquote(v).toLowerAscii()
        case c
        of "auto": cfg.colorMode = cmAuto
        of "always": cfg.colorMode = cmAlways
        of "never": cfg.colorMode = cmNever
        else: discard
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
  proc B(s: string): string = b(s, useColor)
  proc D(s: string): string = dim(s, useColor)
  proc C(s: string): string = c(s, Cyan, useColor)
  
  result = ""
  result.add(B("fastfind") & " - fast file search\n\n")
  result.add(B("Usage") & ":\n")
  result.add("  fastfind " & C("[OPTIONS]") & " " & C("<pattern>") & " " & D("[path ...]") & "\n")
  result.add("  fastfind " & C("\"<natural language query>\"") & "\n\n")
  
  result.add(B("Pattern modes") & ":\n")
  result.add("  " & C("--glob") & "              Glob patterns (default)\n")
  result.add("  " & C("--regex") & "             Regular expressions\n")
  result.add("  " & C("--fixed") & "             Literal substring match\n")
  result.add("  " & C("--fuzzy") & "             Fuzzy matching\n")
  result.add("  " & C("--name") & "              Match basename (default)\n")
  result.add("  " & C("--full-path") & "         Match full path\n")
  result.add("  " & C("-i") & ", " & C("--ignore-case") & "   Case-insensitive\n")
  result.add("  " & C("--smart-case") & "        Smart case sensitivity\n\n")
  
  result.add(B("Traversal") & ":\n")
  result.add("  " & C("-H") & ", " & C("--hidden") & "        Include hidden files\n")
  result.add("  " & C("-L") & ", " & C("--follow") & "        Follow symlinks\n")
  result.add("  " & C("-x") & ", " & C("--one-file-system") & " Stay on one filesystem\n")
  result.add("  " & C("--gitignore") & "         Respect .gitignore\n")
  result.add("  " & C("--min-depth") & " N       Minimum depth\n")
  result.add("  " & C("--max-depth") & " N       Maximum depth\n")
  result.add("  " & C("-j") & ", " & C("--threads") & " N   Parallel threads\n\n")
  
  result.add(B("Filters") & ":\n")
  result.add("  " & C("-t") & ", " & C("--type") & " TYPE    f/file, d/dir, l/link\n")
  result.add("  " & C("--size") & " EXPR         e.g. >10M, 10K..5M\n")
  result.add("  " & C("--newer") & " TIME        Only newer than TIME\n")
  result.add("  " & C("--older") & " TIME        Only older than TIME\n")
  result.add("  " & C("--changed") & " DUR       Modified within duration\n")
  result.add("  " & C("--recent") & "            Modified in last 24h\n")
  result.add("  " & C("--contains") & " TEXT     Content contains TEXT\n")
  result.add("  " & C("--exclude") & " PATTERN   Exclude pattern\n\n")
  
  result.add(B("Git") & ":\n")
  result.add("  " & C("--git-modified") & "      Only modified files\n")
  result.add("  " & C("--git-untracked") & "     Only untracked files\n")
  result.add("  " & C("--git-tracked") & "       Only tracked files\n")
  result.add("  " & C("--git-changed") & "       Modified or untracked\n\n")
  
  result.add(B("Output") & ":\n")
  result.add("  " & C("-l") & ", " & C("--long") & "        Long format\n")
  result.add("  " & C("--json") & "              JSON output\n")
  result.add("  " & C("--absolute") & "          Absolute paths\n")
  result.add("  " & C("--sort") & " KEY          Sort by path/name/size/time\n")
  result.add("  " & C("-r") & ", " & C("--reverse") & "     Reverse sort\n")
  result.add("  " & C("--limit") & " N           Limit results\n")
  result.add("  " & C("-c") & ", " & C("--count") & "       Count only\n")
  result.add("  " & C("--stats") & "             Show statistics\n\n")
  
  result.add(B("Interactive") & ":\n")
  result.add("  " & C("--interactive") & "       Live search UI\n")
  result.add("  " & C("--select") & "            Pick interactively\n\n")
  
  result.add(B("Index") & ":\n")
  result.add("  " & C("--use-index") & "         Use cached index\n")
  result.add("  " & C("--rebuild-index") & "     Rebuild index\n")
  result.add("  " & C("--index-status") & "      Show index status\n\n")
  
  result.add(B("Misc") & ":\n")
  result.add("  " & C("-h") & ", " & C("--help") & "        Show help\n")
  result.add("  " & C("--version") & "           Show version\n")
  result.add("  " & C("-v") & ", " & C("--verbose") & "     Verbose output\n")
  result.add("  " & C("-q") & ", " & C("--quiet-errors") & " Suppress errors\n")

proc printHelp*() =
  stdout.write(helpText(supportsColor(cmAuto)))

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
  if cfg.modeExplicit or cfg.patterns.len == 0:
    return
  let p = cfg.patterns[0]
  var hasGlob = false
  var hasRegex = false
  for ch in p:
    if ch in {'*', '?', '[', ']'}: hasGlob = true
    if ch in {'(', ')', '{', '}', '|', '+', '^', '$'}: hasRegex = true
  if hasRegex and not hasGlob:
    cfg.matchMode = mmRegex
  elif hasGlob:
    cfg.matchMode = mmGlob
  else:
    cfg.matchMode = mmFixed

proc applyAutoPathMode(cfg: var Config) =
  if cfg.pathModeExplicit or cfg.patterns.len == 0:
    return
  if '/' in cfg.patterns[0] or '\\' in cfg.patterns[0]:
    cfg.pathMode = pmFullPath

proc parseTypeValue(val: string): set[EntryType] =
  result = {}
  let t = val.strip().toLowerAscii()
  case t
  of "f", "file", "files": result = {etFile}
  of "d", "dir", "dirs", "directory", "directories": result = {etDir}
  of "l", "link", "links", "symlink", "symlinks": result = {etLink}
  else:
    raise newException(ValueError, "unknown type: " & val)

proc parseSortKey(val: string): SortKey =
  let s = val.strip().toLowerAscii()
  case s
  of "path": skPath
  of "name": skName
  of "size": skSize
  of "time", "mtime": skTime
  of "none", "": skNone
  else:
    raise newException(ValueError, "unknown sort key: " & val)

proc parseColorMode(val: string): ColorMode =
  let c = val.strip().toLowerAscii()
  case c
  of "auto": cmAuto
  of "always": cmAlways
  of "never": cmNever
  else:
    raise newException(ValueError, "unknown color mode: " & val)

proc getOptValue(args: seq[string]; idx: var int; currentVal: string): string =
  if currentVal.len > 0:
    return currentVal
  if idx + 1 < args.len and not args[idx + 1].startsWith("-"):
    inc idx
    return args[idx]
  raise newException(ValueError, "option requires a value")

proc parseCli*(args: seq[string]): Config =
  result = defaultConfig()
  
  var configPath = ""
  var skipDefaultConfig = false
  var processedArgs: seq[string] = @[]
  var i = 0
  
  while i < args.len:
    let arg = args[i]
    if arg == "--no-config":
      skipDefaultConfig = true
    elif arg == "--config" and i + 1 < args.len:
      configPath = args[i + 1]
      inc i
    elif arg.startsWith("--config="):
      configPath = arg.split("=", 1)[1]
    else:
      processedArgs.add(arg)
    inc i
  
  if not skipDefaultConfig:
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
  i = 0
  
  while i < processedArgs.len:
    let arg = processedArgs[i]
    
    if arg == "--" :
      for j in (i + 1)..<processedArgs.len:
        positionals.add(processedArgs[j])
      break
    
    if not arg.startsWith("-"):
      positionals.add(arg)
      inc i
      continue
    
    if arg.startsWith("--"):
      let eqPos = arg.find('=')
      var key, val: string
      if eqPos > 0:
        key = arg[2..<eqPos]
        val = arg[eqPos + 1..^1]
      else:
        key = arg[2..^1]
        val = ""
      
      try:
        case key
        of "help": result.justHelp = true
        of "version": result.justVersion = true
        of "glob": result.matchMode = mmGlob; result.modeExplicit = true
        of "regex": result.matchMode = mmRegex; result.modeExplicit = true
        of "fixed": result.matchMode = mmFixed; result.modeExplicit = true
        of "fuzzy": result.matchMode = mmFuzzy; result.fuzzyMode = true; result.modeExplicit = true
        of "fuzzy-score": result.showFuzzyScore = true
        of "full-match": result.fullMatch = true
        of "name": result.pathMode = pmBaseName; result.pathModeExplicit = true
        of "full-path": result.pathMode = pmFullPath; result.pathModeExplicit = true
        of "ignore-case": result.ignoreCase = true
        of "smart-case": result.smartCase = true
        of "fd": applyFdDefaults(result)
        of "hidden": result.includeHidden = true
        of "follow": result.followSymlinks = true
        of "one-file-system": result.oneFileSystem = true
        of "gitignore": result.useGitignore = true
        of "no-gitignore": result.useGitignore = false
        of "binary": result.allowBinary = true
        of "git-modified": result.gitModified = true
        of "git-untracked": result.gitUntracked = true
        of "git-tracked": result.gitTracked = true
        of "git-changed": result.gitChanged = true
        of "rank": result.rankMode = rmAuto
        of "rank-recency": result.rankRecency = true
        of "rank-depth": result.rankDepth = true
        of "long": result.outputMode = omLong
        of "json": result.outputMode = omJson
        of "ndjson": result.outputMode = omNdJson
        of "table": result.outputMode = omTable
        of "absolute": result.absolute = true
        of "relative": result.relative = true
        of "reverse": result.reverse = true
        of "count": result.countOnly = true
        of "stats": result.stats = true
        of "interactive": result.interactiveMode = true
        of "select": result.selectMode = true
        of "use-index": result.useIndex = true
        of "rebuild-index": result.indexCommand = icRebuild
        of "index-status": result.indexCommand = icStatus
        of "index-daemon": result.indexCommand = icDaemon
        of "shell": result.execShell = true
        of "verbose": result.verbose = true
        of "quiet-errors": result.quietErrors = true
        of "recent": result.newerThan = some(getTime() - initDuration(hours = 24))
        of "threads":
          val = getOptValue(processedArgs, i, val)
          result.threads = max(0, parseIntSafe(val))
        of "type":
          val = getOptValue(processedArgs, i, val)
          if result.types == {etFile, etDir, etLink}:
            result.types = {}
          result.types = result.types + parseTypeValue(val)
        of "min-depth":
          val = getOptValue(processedArgs, i, val)
          result.minDepth = max(0, parseIntSafe(val))
        of "max-depth":
          val = getOptValue(processedArgs, i, val)
          result.maxDepth = parseIntSafe(val)
        of "exclude":
          val = getOptValue(processedArgs, i, val)
          if val.len > 0: result.excludes.add(val)
        of "size":
          val = getOptValue(processedArgs, i, val)
          let r = parseSizeExpr(val)
          result.minSize = r.minSize
          result.maxSize = r.maxSize
        of "newer":
          val = getOptValue(processedArgs, i, val)
          result.newerThan = maybeTime(val)
        of "older":
          val = getOptValue(processedArgs, i, val)
          result.olderThan = maybeTime(val)
        of "changed":
          val = getOptValue(processedArgs, i, val)
          let d = parseDuration(val)
          result.newerThan = some(getTime() - d)
        of "contains":
          val = getOptValue(processedArgs, i, val)
          result.containsText = val
        of "contains-re":
          val = getOptValue(processedArgs, i, val)
          result.containsRegex = val
        of "max-bytes":
          val = getOptValue(processedArgs, i, val)
          result.maxBytes = int(parseBytes(val))
        of "function":
          val = getOptValue(processedArgs, i, val)
          result.searchFunction = val
        of "class":
          val = getOptValue(processedArgs, i, val)
          result.searchClass = val
        of "symbol":
          val = getOptValue(processedArgs, i, val)
          result.searchSymbol = val
        of "sort":
          val = getOptValue(processedArgs, i, val)
          result.sortKey = parseSortKey(val)
        of "limit":
          val = getOptValue(processedArgs, i, val)
          result.limit = max(0, parseIntSafe(val))
        of "color":
          val = getOptValue(processedArgs, i, val)
          result.colorMode = parseColorMode(val)
        of "exec":
          val = getOptValue(processedArgs, i, val)
          result.execCmd = val
          result.execShell = true
        of "exec-cmd":
          val = getOptValue(processedArgs, i, val)
          result.execCmd = val
        of "exec-arg":
          val = getOptValue(processedArgs, i, val)
          result.execArgs.add(val)
        else:
          niceError("unknown option: --" & key)
          quit(2)
      except ValueError as e:
        niceError(e.msg)
        quit(2)
    
    elif arg.startsWith("-") and arg.len > 1:
      var j = 1
      while j < arg.len:
        let ch = arg[j]
        
        var shortVal = ""
        if j + 1 < arg.len and ch in ShortOptsWithValue:
          shortVal = arg[j + 1..^1]
          j = arg.len
        
        try:
          case ch
          of 'h': result.justHelp = true
          of 'v': result.verbose = true
          of 'q': result.quietErrors = true
          of 'l': result.outputMode = omLong
          of 'r': result.reverse = true
          of 'c': result.countOnly = true
          of 'H': result.includeHidden = true
          of 'L': result.followSymlinks = true
          of 'x': result.oneFileSystem = true
          of 'i': result.ignoreCase = true
          of 'f': result.matchMode = mmFixed; result.modeExplicit = true
          of 'j':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            result.threads = max(0, parseIntSafe(shortVal))
          of 't':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            if result.types == {etFile, etDir, etLink}:
              result.types = {}
            result.types = result.types + parseTypeValue(shortVal)
          of 'd':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            result.maxDepth = parseIntSafe(shortVal)
          of 'e':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            result.excludes.add(shortVal)
          of 's':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            let sr = parseSizeExpr(shortVal)
            result.minSize = sr.minSize
            result.maxSize = sr.maxSize
          of 'n':
            if shortVal.len == 0:
              shortVal = getOptValue(processedArgs, i, "")
            result.limit = max(0, parseIntSafe(shortVal))
          else:
            niceError("unknown option: -" & $ch)
            quit(2)
        except ValueError as e:
          niceError(e.msg)
          quit(2)
        
        if shortVal.len > 0:
          break
        inc j
    
    inc i
  
  if result.justHelp:
    printHelp()
    quit(0)
  
  if result.justVersion:
    stdout.writeLine(Version)
    quit(0)
  
  if positionals.len > 0:
    let first = positionals[0]
    if isNaturalLanguageQuery(first):
      result.naturalQuery = first
      let parsed = parseNaturalQuery(first)
      applyParsedQuery(result, parsed)
      result.naturalQuery = parsed.humanDescription
      if positionals.len > 1:
        result.paths = positionals[1..^1]
    else:
      result.patterns.add(first)
      if positionals.len > 1:
        result.paths = positionals[1..^1]
  
  let hasFilters = result.gitModified or result.gitUntracked or
                   result.gitTracked or result.gitChanged or
                   result.minSize >= 0 or result.maxSize >= 0 or
                   result.newerThan.isSome or result.olderThan.isSome or
                   result.containsText.len > 0 or result.containsRegex.len > 0 or
                   result.searchFunction.len > 0 or result.searchClass.len > 0 or
                   result.searchSymbol.len > 0
  
  let needsPattern = result.patterns.len == 0 and
                     result.indexCommand == icNone and
                     not result.interactiveMode and
                     result.naturalQuery.len == 0 and
                     not hasFilters
  
  if needsPattern:
    result.patterns = @["*"]
  
  if result.patterns.len == 0 and hasFilters:
    result.patterns = @["*"]
  
  if result.paths.len == 0:
    result.paths = @["."]
  
  applyAutoMode(result)
  applyAutoPathMode(result)
  
  if result.fuzzyMode and result.rankMode == rmNone:
    result.rankMode = rmScore

proc applyParsedQuery*(cfg: var Config; pq: ParsedQuery) =
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
  if pq.extensions.len > 0:
    for ext in pq.extensions:
      cfg.patterns.add("*" & ext)
    cfg.matchMode = pq.matchMode
  if pq.excludePatterns.len > 0:
    for ex in pq.excludePatterns:
      cfg.excludes.add("*" & ex & "*")
  if pq.inDirectory.len > 0:
    cfg.paths = @[pq.inDirectory]
