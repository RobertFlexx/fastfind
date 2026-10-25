import std/[os, terminal, times as times, strutils, algorithm, re, sets]
when compileOption("threads"): import std/[atomics, locks]
import core, cli, search, fuzzy_match, matchers, tui_text, tui_input, content, shellcmd, nlp
from ansi import terminalText

when defined(posix):
  import std/posix
  import posix/termios
  type SignalHandler = proc(signal: cint) {.noconv.}
  proc swapSignal(signal: cint; handler: SignalHandler): SignalHandler {.
    importc: "signal", header: "<signal.h>".}

var stopSignalNumber {.volatile.}: cint

proc stopOnSignal(signal: cint) {.noconv, stackTrace: off.} =
  stopSignalNumber = signal

type
  RawTerminalState = object
    when defined(posix):
      attrs: Termios

proc readInput(fd: cint; buffer: pointer; count: int): int {.inline.} =
  when defined(posix):
    int(posix.read(fd, buffer, count))
  else:
    -1

proc enableRawTerminal(fd: cint): RawTerminalState =
  when defined(posix):
    if tcGetAttr(fd, addr result.attrs) != 0:
      raise newException(IOError, "interactive mode requires a terminal on stdin")
    var raw = result.attrs
    raw.c_lflag = raw.c_lflag and not Cflag(ICANON or ECHO or ISIG or IEXTEN)
    raw.c_iflag = raw.c_iflag and not Cflag(IXON or ICRNL)
    raw.c_cc[VMIN] = char(0)
    raw.c_cc[VTIME] = char(1)
    if tcSetAttr(fd, TCSANOW, addr raw) != 0:
      raise newException(IOError, "cannot enable interactive terminal input")
  else:
    stderr.writeLine("Interactive mode is not supported on Windows")
    quit(1)

proc restoreTerminal(fd: cint; state: RawTerminalState) =
  when defined(posix):
    var attrs = state.attrs
    discard tcSetAttr(fd, TCSANOW, addr attrs)

when compileOption("threads"):
  type
    BackgroundSearch = ptr BackgroundSearchObj
    BackgroundSearchObj = object
      cfg: Config
      control: SearchControl
      completed: Atomic[bool]
      response: SearchResult
      error: string
      worker: Thread[BackgroundSearch]
      lock: Lock
      changed: Cond
      released: bool

type
  Mode = enum
    modeBrowse
    modeSearch
    modeCommand
    modeGlobalSearch
    modeGoto
    modeFilter
    modeConfirm

  FileEntry = object
    name: string
    path: string
    relPath: string
    kind: EntryType
    size: int64
    mtime: times.Time
    selected: bool
    executable: bool
    permissions: string
    lowerName: string
    displayName: string

  TUIState = object
    mode: Mode
    prevMode: Mode
    cwd: string
    entries: seq[FileEntry]
    filtered: seq[int]
    cursor: int
    scroll: int
    query: string
    commandLine: string
    gotoPath: string
    message: string
    messageTime: times.Time
    messageType: string
    showHidden: bool
    showPreview: bool
    showDetails: bool
    sortBy: string
    sortReverse: bool
    running: bool
    selectedPaths: seq[string]
    history: seq[string]
    historyIndex: int
    bookmarks: seq[string]
    width: int
    height: int
    baseConfig: Config
    globalMode: bool
    globalResults: seq[FileEntry]
    globalSearching: bool
    globalPattern: string
    typeFilter: string
    confirmAction: string
    confirmTarget: string
    pendingDelete: seq[string]
    yankPath: string
    previewKey: string
    previewLines: seq[string]
    inputFd: cint
    terminalState: RawTerminalState
    when compileOption("threads"):
      searchJob: BackgroundSearch

const
  ColorHeader = "\x1b[48;5;236m\x1b[38;5;252m"
  ColorSelected = "\x1b[48;5;24m\x1b[38;5;255m"
  ColorDir = "\x1b[38;5;39m\x1b[1m"
  ColorFile = "\x1b[38;5;252m"
  ColorExec = "\x1b[38;5;40m"
  ColorLink = "\x1b[38;5;43m"
  ColorSize = "\x1b[38;5;243m"
  ColorTime = "\x1b[38;5;243m"
  ColorPrompt = "\x1b[38;5;39m"
  ColorMatch = "\x1b[38;5;220m\x1b[1m"
  ColorStatus = "\x1b[48;5;238m\x1b[38;5;250m"
  ColorPreview = "\x1b[38;5;245m"
  ColorBorder = "\x1b[38;5;240m"
  ColorError = "\x1b[38;5;196m"
  ColorSuccess = "\x1b[38;5;40m"
  ColorWarning = "\x1b[38;5;220m"
  ColorReset = "\x1b[0m"
  ColorBold = "\x1b[1m"
  ColorDim = "\x1b[2m"

  QuickDirs = [
    ('1', "~"),
    ('2', "~/Documents"),
    ('3', "~/Downloads"),
    ('4', "~/Desktop"),
    ('5', "/tmp"),
    ('6', "/etc"),
    ('7', "/var/log"),
    ('8', "/usr"),
    ('9', "/")
  ]

proc applyFilter(state: var TUIState)
proc stopGlobalSearch(state: var TUIState)

var screenBuffer = newStringOfCap(32 * 1024)
var screenFile: File = stdout

proc screenWrite(value: string) = screenBuffer.add(value)

proc flushScreen() =
  if screenBuffer.len > 0:
    screenFile.write(screenBuffer)
    screenBuffer.setLen(0)
  screenFile.flushFile()

proc hideCur() =
  screenWrite("\x1b[?25l")

proc showCur() =
  screenWrite("\x1b[?25h")

proc gotoXY(x, y: int) =
  screenWrite("\x1b[" & $y & ";" & $x & "H")

proc clearScr() =
  screenWrite("\x1b[2J\x1b[H")

proc clearLn() =
  screenWrite("\x1b[2K")

# proc clearToEOL() =
#   screenWrite("\x1b[K")

proc initState(cfg: Config): TUIState =
  result.mode = modeBrowse
  result.prevMode = modeBrowse
  result.cwd = absolutePath(if cfg.paths.len > 0: cfg.paths[0] else: ".")
  result.entries = @[]
  result.filtered = @[]
  result.cursor = 0
  result.scroll = 0
  result.query = ""
  result.commandLine = ""
  result.gotoPath = ""
  result.message = ""
  result.messageTime = times.getTime()
  result.messageType = "info"
  result.showHidden = cfg.includeHidden
  result.showPreview = true
  result.showDetails = true
  result.sortBy = "name"
  result.sortReverse = false
  result.running = true
  result.selectedPaths = @[]
  result.history = @[result.cwd]
  result.historyIndex = 0
  result.bookmarks = @[]
  result.width = terminalWidth()
  result.height = terminalHeight()
  result.baseConfig = cfg
  result.globalMode = false
  result.globalResults = @[]
  result.globalSearching = false
  result.globalPattern = ""
  result.typeFilter = ""
  result.confirmAction = ""
  result.confirmTarget = ""
  result.yankPath = ""

  let bookmarkFile = getHomeDir() / ".config" / "fastfind" / "bookmarks"
  if fileExists(bookmarkFile):
    try:
      for line in lines(bookmarkFile):
        let l = line.strip()
        if l.len > 0 and dirExists(l):
          result.bookmarks.add(l)
    except CatchableError:
      discard

proc saveBookmarks(state: TUIState) =
  let configDir = getHomeDir() / ".config" / "fastfind"
  try:
    createDir(configDir)
    let bookmarkFile = configDir / "bookmarks"
    var f = open(bookmarkFile, fmWrite)
    defer: close(f)
    for b in state.bookmarks:
      f.writeLine(b)
  except CatchableError:
    discard

proc setMessage(state: var TUIState; msg: string; msgType: string = "info") =
  state.message = msg
  state.messageType = msgType
  state.messageTime = times.getTime()

proc truncateLeft(s: string; maxLen: int): string =
  clipText(s, maxLen, left = true)

proc truncateRight(s: string; maxLen: int): string =
  clipText(s, maxLen)

proc padRight(s: string; width: int): string =
  fitText(s, width)

proc padLeft(s: string; width: int): string =
  fitText(s, width, right = true)

proc formatSize(size: int64): string =
  if size < 0:
    return "     - "
  if size < 1024:
    return padLeft($size & "B", 7)
  elif size < 1024 * 1024:
    return padLeft($(size div 1024) & "K", 7)
  elif size < 1024 * 1024 * 1024:
    return padLeft($(size div (1024 * 1024)) & "M", 7)
  else:
    return padLeft($(size div (1024 * 1024 * 1024)) & "G", 7)

proc formatTime(t: times.Time): string =
  try:
    let now = times.getTime()
    let diff = now - t
    if diff.inDays < 1:
      return t.format("HH:mm:ss   ")
    elif diff.inDays < 180:
      return t.format("MMM dd HH:mm")
    else:
      return t.format("yyyy-MM-dd ")
  except CatchableError:
    return "           "

proc getFileIcon(entry: FileEntry): string =
  if entry.kind == etDir: return "▸ "
  if entry.kind == etLink: return "↗ "
  if entry.executable: return "* "
  let ext = entry.name.splitFile.ext.toLowerAscii
  case ext
  of ".nim", ".py", ".rs", ".c", ".cpp", ".h", ".go", ".js", ".ts": "λ "
  of ".md", ".txt", ".rst": "≡ "
  of ".json", ".yaml", ".yml", ".toml", ".xml", ".ini", ".conf": "⚙ "
  else: "· "

proc loadDirectory(state: var TUIState) =
  stopGlobalSearch(state)
  state.entries = @[]
  state.filtered = @[]
  state.cursor = 0
  state.scroll = 0
  state.globalMode = false
  state.previewKey = ""
  let selected = state.selectedPaths.toHashSet

  if state.cwd != "/":
    var parent: FileEntry
    parent.name = ".."
    parent.path = parentDir(state.cwd)
    parent.relPath = ".."
    parent.kind = etDir
    parent.size = -1
    parent.selected = false
    state.entries.add(parent)

  var dirs: seq[FileEntry] = @[]
  var files: seq[FileEntry] = @[]

  try:
    for kind, path in walkDir(state.cwd):
      let name = extractFilename(path)

      if not state.showHidden and name.len > 0 and name[0] == '.':
        continue

      var entry: FileEntry
      entry.name = name
      entry.path = path
      entry.relPath = name
      entry.selected = path in selected
      entry.lowerName = name.toLowerAscii()
      entry.displayName = safeText(name)

      case kind
      of pcFile:
        entry.kind = etFile
      of pcDir:
        entry.kind = etDir
      of pcLinkToFile, pcLinkToDir:
        entry.kind = etLink

      try:
        let info = getFileInfo(path, followSymlink = false)
        entry.executable = (info.permissions * {fpUserExec, fpGroupExec, fpOthersExec}) != {}
        entry.permissions = (if fpUserRead in info.permissions: "r" else: "-") &
          (if fpUserWrite in info.permissions: "w" else: "-") &
          (if fpUserExec in info.permissions: "x" else: "-")
        entry.size = info.size
        entry.mtime = info.lastWriteTime
      except CatchableError:
        entry.size = 0
        entry.mtime = times.fromUnix(0)

      if state.typeFilter.len > 0:
        case state.typeFilter
        of "f":
          if entry.kind != etFile: continue
        of "d":
          if entry.kind != etDir: continue
        of "l":
          if entry.kind != etLink: continue
        else:
          discard

      if entry.kind == etDir:
        dirs.add(entry)
      else:
        files.add(entry)
  except CatchableError:
    state.setMessage("Cannot read directory: " & state.cwd, "error")
    return

  proc cmpName(a, b: FileEntry): int = cmpIgnoreCase(a.name, b.name)
  proc cmpSize(a, b: FileEntry): int = cmp(a.size, b.size)
  proc cmpTime(a, b: FileEntry): int = cmp(a.mtime.toUnix, b.mtime.toUnix)
  proc cmpExt(a, b: FileEntry): int =
    let extA = a.name.splitFile.ext.toLowerAscii
    let extB = b.name.splitFile.ext.toLowerAscii
    result = cmp(extA, extB)
    if result == 0:
      result = cmpIgnoreCase(a.name, b.name)

  case state.sortBy
  of "name":
    dirs.sort(cmpName)
    files.sort(cmpName)
  of "size":
    dirs.sort(cmpName)
    files.sort(cmpSize)
  of "time":
    dirs.sort(cmpTime)
    files.sort(cmpTime)
  of "ext":
    dirs.sort(cmpName)
    files.sort(cmpExt)
  else:
    dirs.sort(cmpName)
    files.sort(cmpName)

  if state.sortReverse:
    dirs.reverse()
    files.reverse()

  for d in dirs:
    state.entries.add(d)
  for f in files:
    state.entries.add(f)

  state.applyFilter()

proc applyFilter(state: var TUIState) =
  state.filtered.setLen(0)
  state.cursor = 0
  state.scroll = 0
  if state.query.len == 0:
    for i in 0 ..< state.entries.len: state.filtered.add(i)
    return

  let queryLower = state.query.toLowerAscii()
  let wildcard = queryLower.find({'*', '?', '['}) >= 0
  var pattern: Regex
  if wildcard:
    try: pattern = re(globToRegex(queryLower))
    except CatchableError: return
  var scored = newSeqOfCap[tuple[score: int, idx: int]](state.entries.len)
  for i, entry in state.entries:
    if entry.name == "..": continue
    if wildcard:
      if entry.lowerName.match(pattern): state.filtered.add(i)
    else:
      let score = fuzzyMatch(queryLower, entry.lowerName)
      if score >= 0: scored.add((score, i))
  if not wildcard:
    scored.sort(proc(a, b: tuple[score: int, idx: int]): int =
      result = cmp(a.score, b.score)
      if result == 0: result = cmp(a.idx, b.idx))
    for item in scored: state.filtered.add(item.idx)

when compileOption("threads"):
  proc detachedConfig(cfg: Config): Config =
    # Isolate all managed strings before starting the thread. Nim's ORC
    # reference counts are not atomic; the UI may edit its query concurrently.
    result = cfg
    for field in fields(result):
      when field is string:
        var copy = newString(field.len)
        if field.len > 0: copyMem(addr copy[0], unsafeAddr field[0], field.len)
        field = move copy
      elif field is seq[string]:
        var copy = newSeq[string](field.len)
        for i in 0..<field.len:
          copy[i] = newString(field[i].len)
          if field[i].len > 0:
            copyMem(addr copy[i][0], unsafeAddr field[i][0], field[i].len)
        field = move copy

  proc searchInBackground(job: BackgroundSearch) {.thread, gcsafe.} =
    try: job.response = runSearchCollect(job.cfg, job.control)
    except CatchableError as e: job.error = e.msg
    finally:
      acquire(job.lock)
      job.completed.store(true)
      broadcast(job.changed)
      while not job.released: wait(job.changed, job.lock)
      release(job.lock)

proc stopGlobalSearch(state: var TUIState) =
  when compileOption("threads"):
    let job = state.searchJob
    if job != nil:
      job.control.cancel()
      acquire(job.lock)
      while not job.completed.load(): wait(job.changed, job.lock)
      reset(job.response)
      reset(job.error)
      job.released = true
      broadcast(job.changed)
      release(job.lock)
      joinThread(job.worker)
      job.control.destroy()
      reset(job.cfg)
      deinitCond(job.changed)
      deinitLock(job.lock)
      deallocShared(job)
      state.searchJob = nil
  state.globalSearching = false

proc refreshGlobalView(state: var TUIState) =
  state.entries.setLen(0)
  let selected = state.selectedPaths.toHashSet
  for entry in state.globalResults:
    if state.typeFilter == "f" and entry.kind != etFile: continue
    if state.typeFilter == "d" and entry.kind != etDir: continue
    if state.typeFilter == "l" and entry.kind != etLink: continue
    var visible = entry
    visible.selected = entry.path in selected
    state.entries.add(visible)
  let key = state.sortBy
  let reverse = state.sortReverse
  state.entries.sort(proc(a, b: FileEntry): int =
    if a.kind == etDir and b.kind != etDir: return -1
    if b.kind == etDir and a.kind != etDir: return 1
    case key
    of "size": result = cmp(a.size, b.size)
    of "time": result = cmp(a.mtime, b.mtime)
    of "ext": result = cmpIgnoreCase(a.name.splitFile.ext, b.name.splitFile.ext)
    else: result = cmpIgnoreCase(a.name, b.name)
    if result == 0: result = cmpIgnoreCase(a.name, b.name)
    if reverse: result = -result)
  state.applyFilter()

proc acceptGlobalResults(state: var TUIState; response: SearchResult) =
  state.globalResults.setLen(0)
  let selected = state.selectedPaths.toHashSet
  for m in response.matches:
    let name = if m.name.len > 0: m.name else: extractFilename(m.absPath)
    state.globalResults.add(FileEntry(name: name, path: m.absPath,
      relPath: m.relPath, lowerName: name.toLowerAscii(), displayName: safeText(name),
      kind: m.kind, size: m.size, mtime: m.mtime, selected: m.absPath in selected))
  state.query = ""
  state.refreshGlobalView()
  state.globalSearching = false
  state.previewKey = ""
  state.setMessage("Found " & $state.entries.len & " results" &
    (if state.entries.len == 500: " · first 500 shown" else: ""), "success")

proc pollGlobalSearch(state: var TUIState): bool =
  when compileOption("threads"):
    let job = state.searchJob
    if job != nil and job.completed.load():
      var response = SearchResult(matches: ownedCopy(job.response.matches), stats: job.response.stats)
      var error = newString(job.error.len)
      if error.len > 0: copyMem(addr error[0], unsafeAddr job.error[0], error.len)
      state.stopGlobalSearch()
      state.acceptGlobalResults(response)
      if error.len > 0: state.setMessage(error, "error")
      return true
  false

proc runGlobalSearch(state: var TUIState) =
  state.stopGlobalSearch()
  var searchCfg = state.baseConfig
  searchCfg.paths = @[state.cwd]
  searchCfg.patterns = @[state.globalPattern]
  searchCfg.limit = 500
  searchCfg.includeHidden = state.showHidden
  searchCfg.outputMode = omLong
  searchCfg.countOnly = false
  searchCfg.execCmd = ""
  searchCfg.fuzzyMode = false
  searchCfg.fullMatch = false
  searchCfg.pathMode = pmBaseName
  if isNaturalLanguageQuery(state.globalPattern):
    searchCfg.patterns.setLen(0)
    applyParsedQuery(searchCfg, parseNaturalQuery(state.globalPattern))
    if searchCfg.patterns.len == 0: searchCfg.patterns = @["*"]
    searchCfg.limit = if searchCfg.limit > 0: min(500, searchCfg.limit) else: 500
    searchCfg.countOnly = false
  elif state.globalPattern.find({'*', '?', '['}) >= 0:
    searchCfg.matchMode = mmGlob
  else:
    searchCfg.matchMode = mmFixed
    searchCfg.ignoreCase = true
  state.globalSearching = true
  state.entries.setLen(0)
  state.filtered.setLen(0)
  state.cursor = 0
  state.scroll = 0
  state.setMessage("Searching below " & state.cwd & " · Esc cancels", "info")
  when compileOption("threads"):
    let job = cast[BackgroundSearch](allocShared0(sizeof(BackgroundSearchObj)))
    initLock(job.lock)
    initCond(job.changed)
    job.cfg = detachedConfig(searchCfg)
    job.control = newSearchControl()
    state.searchJob = job
    createThread(job.worker, searchInBackground, job)
  else:
    try: state.acceptGlobalResults(runSearchCollect(searchCfg))
    except CatchableError as e:
      state.globalSearching = false
      state.setMessage(e.msg, "error")

proc currentEntry(state: TUIState): FileEntry =
  if state.filtered.len == 0:
    return FileEntry()
  let idx = state.filtered[min(state.cursor, state.filtered.len - 1)]
  if idx < state.entries.len:
    return state.entries[idx]
  return FileEntry()

proc listHeight(state: TUIState): int =
  return max(1, state.height - 5)

proc previewWidth(state: TUIState): int =
  if state.showPreview and state.width >= 88 and state.height >= 12:
    return (state.width * 2) div 5
  return 0

proc listWidth(state: TUIState): int =
  return state.width - previewWidth(state)

proc adjustScroll(state: var TUIState) =
  let h = listHeight(state)
  if state.cursor < state.scroll:
    state.scroll = state.cursor
  elif state.cursor >= state.scroll + h:
    state.scroll = state.cursor - h + 1
  if state.scroll < 0:
    state.scroll = 0

proc drawBox(x, y, w, h: int; title: string = "") =
  gotoXY(x, y)
  screenWrite(ColorBorder)
  screenWrite("┌")
  if title.len > 0:
    screenWrite("┤ " & title & " ├")
    screenWrite(repeat("─", w - title.len - 6))
  else:
    screenWrite(repeat("─", w - 2))
  screenWrite("┐")

  for i in 1 ..< h - 1:
    gotoXY(x, y + i)
    screenWrite("│" & repeat(' ', max(0, w - 2)) & "│")

  gotoXY(x, y + h - 1)
  screenWrite("└" & repeat("─", w - 2) & "┘")
  screenWrite(ColorReset)

proc safeDisplay(value: string): string

proc drawHeader(state: TUIState) =
  gotoXY(1, 1)
  let mode = case state.mode
    of modeBrowse: "BROWSE"
    of modeSearch: "FILTER"
    of modeCommand: "COMMAND"
    of modeGlobalSearch: "RECURSIVE"
    of modeGoto: "GO TO"
    of modeFilter: "TYPE"
    of modeConfirm: "CONFIRM"
  let badge = " " & mode & " "
  let brand = " fastfind "
  let pathWidth = max(0, state.width - brand.len - badge.len - 1)
  screenWrite(ColorHeader & ColorBold & brand & ColorReset & ColorHeader)
  screenWrite(fitText(truncateLeft(safeDisplay(state.cwd), pathWidth), pathWidth))
  screenWrite(ColorPrompt & badge & ColorReset)
  gotoXY(1, 2)
  let sort = state.sortBy & (if state.sortReverse: " ↓" else: " ↑")
  let scope = if state.globalMode: "recursive" else: "directory"
  let title = " " & scope & " · " & $state.filtered.len & " results · " & sort &
    (if state.showHidden: " · hidden" else: "")
  screenWrite(ColorDim & fitText(title, state.width) & ColorReset)

proc highlightMatch(name: string; query: string; baseColor: string): string =
  if query.len == 0:
    return baseColor & name

  let nameLower = name.toLowerAscii()
  let queryLower = query.toLowerAscii()

  result = ""
  var qi = 0
  for i, ch in name:
    if qi < queryLower.len and nameLower[i] == queryLower[qi]:
      result.add(ColorMatch & $ch & baseColor)
      inc qi
    else:
      result.add($ch)

  result = baseColor & result

proc safeDisplay(value: string): string = safeText(value)

proc drawEntry(state: TUIState; entry: FileEntry; y: int; width: int; isSelected: bool; isCursor: bool) =
  gotoXY(1, y)
  let details = state.showDetails and width >= 55
  let detailsWidth = if details: 22 else: 0
  let nameWidth = max(0, width - 5 - detailsWidth)
  var baseColor = case entry.kind
    of etDir: ColorDir
    of etLink: ColorLink
    of etFile: (if entry.executable: ColorExec else: ColorFile)
  if isCursor:
    screenWrite(ColorSelected)
    baseColor = ColorSelected
  let marker = if isCursor: "› " elif entry.selected: "● " else: "  "
  screenWrite(marker & baseColor & getFileIcon(entry))
  let display = if entry.displayName.len > 0: entry.displayName else: safeDisplay(entry.name)
  let name = padRight(truncateRight(display, nameWidth), nameWidth)
  screenWrite(highlightMatch(name, state.query, baseColor))
  if details:
    screenWrite((if isCursor: ColorSelected else: ColorSize))
    let size = if entry.name == "..": "" elif entry.kind == etDir: "dir" else: formatSize(entry.size).strip()
    screenWrite(padLeft(size, 8) & "  ")
    screenWrite(padRight(if entry.name == "..": "" else: formatTime(entry.mtime), 11))
  screenWrite(" " & ColorReset)

proc drawList(state: TUIState) =
  let h = listHeight(state)
  let w = listWidth(state)

  for i in 0 ..< h:
    let y = 3 + i
    let idx = state.scroll + i

    if idx >= state.filtered.len:
      gotoXY(1, y)
      screenWrite(repeat(' ', w))
      if state.filtered.len == 0 and i == 1:
        gotoXY(3, y)
        screenWrite(ColorDim & truncateRight(if state.globalSearching: "Searching… Esc cancels" else: "No matches. Esc clears the filter.", max(0, w - 4)) & ColorReset)
      continue

    let entryIdx = state.filtered[idx]
    if entryIdx >= state.entries.len:
      continue
    let entry = state.entries[entryIdx]
    let isCursor = idx == state.cursor
    let isSelected = entry.selected

    drawEntry(state, entry, y, w, isSelected, isCursor)

proc loadPreview(state: var TUIState; entry: FileEntry) =
  let key = entry.path & "\0" & $entry.size & "\0" & $entry.mtime.toUnix
  if key == state.previewKey: return
  state.previewKey = key
  state.previewLines.setLen(0)
  if entry.name.len == 0: return
  if entry.kind == etDir:
    state.previewLines.add("Directory")
    var count = 0
    try:
      for kind, path in walkDir(entry.path):
        if count >= 128: break
        state.previewLines.add((if kind in {pcDir, pcLinkToDir}: "▸ " else: "· ") & safeDisplay(extractFilename(path)))
        inc count
      if count == 128: state.previewLines.add("… first 128 entries")
    except CatchableError: state.previewLines.add("Cannot read directory")
    return
  if entry.kind == etLink:
    state.previewLines.add("Symbolic link")
    try: state.previewLines.add("→ " & safeDisplay(expandSymlink(entry.path)))
    except CatchableError: state.previewLines.add("Target unavailable")
    return
  var f: File
  if not openRegularFile(f, entry.path):
    state.previewLines.add("Preview unavailable for this file")
    return
  defer: close(f)
  # Both bytes and lines are bounded. readLine() can allocate gigabytes for a
  # single minified or binary line and can block indefinitely on FIFOs.
  var data = newString(64 * 1024)
  let n = f.readBuffer(addr data[0], data.len)
  data.setLen(n)
  if '\0' in data:
    state.previewLines.add("Binary file · preview disabled")
    return
  var start = 0
  for i in 0..<data.len:
    if data[i] == '\n':
      state.previewLines.add(safeDisplay(data[start..<i].replace("\t", "  ")))
      start = i + 1
      if state.previewLines.len >= 128: break
  if state.previewLines.len < 128 and start < data.len:
    state.previewLines.add(safeDisplay(data[start..^1].replace("\t", "  ")))
  if n == 0: state.previewLines.add("Empty file")
  if n == 64 * 1024: state.previewLines.add("… preview limited to 64 KiB")

proc drawPreview(state: var TUIState) =
  let pw = previewWidth(state)
  if pw == 0: return
  let px = listWidth(state) + 1
  let h = listHeight(state)
  for i in 0..<h:
    gotoXY(px, 3 + i)
    screenWrite(ColorBorder & "│" & ColorReset & repeat(' ', pw - 1))
  let entry = currentEntry(state)
  if entry.name.len == 0: return
  state.loadPreview(entry)
  gotoXY(px + 2, 3)
  screenWrite(ColorBold & truncateRight(safeDisplay(entry.name), pw - 4) & ColorReset)
  gotoXY(px + 2, 4)
  screenWrite(ColorDim & truncateRight(safeDisplay(entry.path), pw - 4) & ColorReset)
  for i in 0..<min(state.previewLines.len, max(0, h - 4)):
    gotoXY(px + 2, 7 + i)
    screenWrite(ColorPreview & truncateRight(state.previewLines[i], pw - 4) & ColorReset)

proc drawStatusBar(state: TUIState) =
  gotoXY(1, state.height - 1)
  let total = state.filtered.len
  let position = if total > 0: state.cursor + 1 else: 0
  let selected = if state.selectedPaths.len > 0: " · " & $state.selectedPaths.len & " selected" else: ""
  let entry = currentEntry(state)
  let left = " " & $position & " / " & $total & selected
  let right = if state.width >= 65 and entry.name.len > 0 and entry.name != "..":
    (if entry.permissions.len > 0: entry.permissions & " · " else: "") & formatSize(entry.size).strip() & " " else: ""
  screenWrite(ColorStatus & fitText(left, max(0, state.width - textWidth(right))) & right & ColorReset)

proc drawPrompt(state: TUIState) =
  gotoXY(1, state.height)
  var prompt = ""
  var input = ""
  var color = ColorPrompt
  case state.mode
  of modeBrowse:
    let elapsed = (times.getTime() - state.messageTime).inSeconds
    if state.message.len > 0 and elapsed < 5:
      color = case state.messageType
        of "error": ColorError
        of "success": ColorSuccess
        of "warning": ColorWarning
        else: ColorPrompt
      prompt = safeDisplay(state.message)
    else:
      prompt = "/ filter  g recursive  Space select  : command  ? help  q quit"
      color = ColorDim
  of modeSearch: prompt = " / "; input = state.query
  of modeGlobalSearch: prompt = " find / "; input = state.globalPattern
  of modeCommand: prompt = " : "; input = state.commandLine
  of modeGoto: prompt = " go / "; input = state.gotoPath
  of modeFilter: prompt = " Type: f file · d directory · l link · Enter all · Esc cancel"
  of modeConfirm:
    # Keep the response keys visible when a long path fills the prompt row.
    prompt = "y/n: " & safeDisplay(state.confirmAction & " " & state.confirmTarget)
    color = ColorWarning
  if input.len > 0 or state.mode in {modeSearch, modeGlobalSearch, modeCommand, modeGoto}:
    let available = max(0, state.width - textWidth(prompt) - 2)
    prompt &= truncateLeft(safeDisplay(input), available) & "▏"
  screenWrite(color & fitText(prompt, max(0, state.width - 1)) & ColorReset)

proc drawBookmarks(state: TUIState) =
  if state.width < 24 or state.height < 7: return
  let bw = min(58, state.width - 2)
  let bh = min(state.bookmarks.len + 5, state.height - 2)
  let bx = max(1, (state.width - bw) div 2 + 1)
  let by = max(1, (state.height - bh) div 2 + 1)

  drawBox(bx, by, bw, bh, "Bookmarks")

  if state.bookmarks.len == 0:
    gotoXY(bx + 2, by + 2)
    screenWrite(ColorDim & truncateRight("Press b to bookmark the current directory", bw - 4) & ColorReset)
  else:
    for i, bm in state.bookmarks:
      if i >= bh - 4:
        break
      gotoXY(bx + 2, by + 2 + i)
      screenWrite(ColorPrompt & $(i + 1) & ColorReset & " " & truncateRight(safeDisplay(bm), bw - 6))

  gotoXY(bx + 2, by + bh - 2)
  screenWrite(ColorDim & truncateRight("1-9 jump · Esc close", bw - 4) & ColorReset)

proc readByte(fd: cint; timeoutMs: int; ch: var char): int

proc drawHelp(state: var TUIState; fd: cint) =
  clearScr()
  let help = [
    "FASTFIND  /  keyboard shortcuts",
    "",
    "NAVIGATE   j/k or ↑/↓    move cursor",
    "           Enter / →    enter directory or choose file",
    "           h / ←        parent directory",
    "           Home / End   first / last result",
    "           Ctrl+U / D   page up / down",
    "           [ / ]        back / forward",
    "           Tab          go to path (Tab completes)",
    "",
    "SEARCH     /            fuzzy or glob filter",
    "           g            recursive search below current path",
    "           Esc          clear filter / cancel",
    "",
    "SELECT     Space        toggle selection and move",
    "           v / V        select visible / clear selection",
    "",
    "VIEW       p / i        preview / details",
    "           . / s / r    hidden files / sort / reverse",
    "           b / B        bookmark / show bookmarks",
    "           R            refresh",
    "",
    "COMMAND    :cd PATH     change directory",
    "           :exec CMD    run command; {} is the quoted path",
    "           :rm          confirm permanent file deletion",
    "",
    "QUIT       q / Ctrl+C   exit"
  ]
  for i in 0..<min(help.len, max(0, state.height - 2)):
    gotoXY(2, i + 1)
    screenWrite((if i == 0: ColorPrompt & ColorBold else: ColorFile) &
      truncateRight(help[i], max(0, state.width - 3)) & ColorReset)
  gotoXY(2, state.height)
  screenWrite(ColorDim & truncateRight("Press any key to return", max(0, state.width - 3)) & ColorReset)
  flushScreen()
  var ch: char
  while stopSignalNumber == 0:
    let status = readByte(fd, 100, ch)
    if status < 0 or (status > 0 and ch == '\x03'):
      state.running = false
      break
    if status > 0: break

proc render(state: var TUIState) =
  if state.width < 24 or state.height < 7:
    clearScr()
    screenWrite(truncateRight("Resize terminal · q quits", max(0, state.width - 1)))
    flushScreen()
    return
  hideCur()
  drawHeader(state)
  drawList(state)
  drawPreview(state)
  drawStatusBar(state)
  drawPrompt(state)
  flushScreen()

proc navigateTo(state: var TUIState; path: string) =
  var newPath = path
  if newPath == "~": newPath = getHomeDir()
  elif newPath.startsWith("~/"): newPath = getHomeDir() / newPath[2..^1]
  newPath = absolutePath(newPath, state.cwd)

  if not dirExists(newPath):
    state.setMessage("Not a directory: " & path, "error")
    return

  state.globalMode = false
  state.cwd = newPath
  state.query = ""
  state.mode = modeBrowse

  if state.historyIndex < state.history.len - 1:
    state.history = state.history[0 .. state.historyIndex]
  state.history.add(newPath)
  state.historyIndex = state.history.len - 1

  loadDirectory(state)

proc goUp(state: var TUIState) =
  if state.globalMode:
    state.globalMode = false
    loadDirectory(state)
    return
  if state.cwd != "/":
    navigateTo(state, parentDir(state.cwd))

proc goBack(state: var TUIState) =
  if state.historyIndex > 0:
    dec state.historyIndex
    state.cwd = state.history[state.historyIndex]
    state.query = ""
    state.globalMode = false
    state.mode = modeBrowse
    loadDirectory(state)

proc goForward(state: var TUIState) =
  if state.historyIndex < state.history.len - 1:
    inc state.historyIndex
    state.cwd = state.history[state.historyIndex]
    state.query = ""
    state.globalMode = false
    state.mode = modeBrowse
    loadDirectory(state)

proc enterDirectory(state: var TUIState) =
  let entry = currentEntry(state)
  if entry.name.len == 0:
    return

  if entry.kind == etDir or (entry.kind == etLink and dirExists(entry.path)):
    navigateTo(state, entry.path)

proc selectEntry(state: var TUIState) =
  if state.filtered.len == 0:
    return

  let idx = state.filtered[state.cursor]
  if idx >= state.entries.len:
    return
  let entry = state.entries[idx]

  if entry.name == "..":
    return

  if entry.path in state.selectedPaths:
    state.selectedPaths.delete(state.selectedPaths.find(entry.path))
    state.entries[idx].selected = false
  else:
    state.selectedPaths.add(entry.path)
    state.entries[idx].selected = true

proc toggleSelectAndMove(state: var TUIState) =
  selectEntry(state)
  if state.cursor < state.filtered.len - 1:
    inc state.cursor
    adjustScroll(state)

proc selectAll(state: var TUIState) =
  var selected = state.selectedPaths.toHashSet
  for i in state.filtered:
    let entry = state.entries[i]
    if entry.name != ".." and entry.path notin selected:
      selected.incl(entry.path)
      state.selectedPaths.add(entry.path)
      state.entries[i].selected = true

proc clearSelection(state: var TUIState) =
  state.selectedPaths = @[]
  for i in 0 ..< state.entries.len:
    state.entries[i].selected = false

proc toggleHidden(state: var TUIState) =
  state.showHidden = not state.showHidden
  if state.globalMode:
    if state.globalPattern.len > 0: runGlobalSearch(state)
    else: state.mode = modeGlobalSearch
  else:
    loadDirectory(state)
  state.setMessage(if state.showHidden: "Showing hidden files" else: "Hiding hidden files", "info")

proc togglePreview(state: var TUIState) =
  state.showPreview = not state.showPreview

proc toggleDetails(state: var TUIState) =
  state.showDetails = not state.showDetails

proc cycleSort(state: var TUIState) =
  case state.sortBy
  of "name": state.sortBy = "size"
  of "size": state.sortBy = "time"
  of "time": state.sortBy = "ext"
  of "ext": state.sortBy = "name"
  else: state.sortBy = "name"

  if state.globalMode: refreshGlobalView(state)
  else: loadDirectory(state)
  state.setMessage("Sort by: " & state.sortBy, "info")

proc reverseSort(state: var TUIState) =
  state.sortReverse = not state.sortReverse
  if state.globalMode: refreshGlobalView(state)
  else: loadDirectory(state)

proc toggleGlobalMode(state: var TUIState) =
  state.globalMode = not state.globalMode
  if state.globalMode:
    state.mode = modeGlobalSearch
    state.globalPattern = ""
    state.setMessage("Recursive search below " & state.cwd, "info")
  else:
    state.mode = modeBrowse
    loadDirectory(state)
    state.setMessage("Local mode", "info")

proc addBookmark(state: var TUIState) =
  if state.cwd notin state.bookmarks:
    state.bookmarks.add(state.cwd)
    saveBookmarks(state)
    state.setMessage("Bookmarked: " & state.cwd, "success")
  else:
    state.setMessage("Already bookmarked", "warning")

proc yankPath(state: var TUIState) =
  let entry = currentEntry(state)
  if entry.name.len > 0:
    state.yankPath = entry.path
    state.setMessage("Yanked: " & entry.path, "success")

proc performPendingDelete(state: var TUIState) =
  let requested = state.pendingDelete.len
  var removed = 0
  for path in state.pendingDelete:
    try:
      # This can remove a file or symlink, but it never deletes a directory.
      if dirExists(path) and not symlinkExists(path):
        state.setMessage("Refusing recursive directory deletion: " & safeDisplay(path), "error")
        continue
      removeFile(path)
      inc removed
    except CatchableError:
      state.setMessage("Failed to remove: " & safeDisplay(path), "error")
  state.pendingDelete.setLen(0)
  state.selectedPaths.setLen(0)
  state.confirmAction = ""
  state.confirmTarget = ""
  loadDirectory(state)
  if removed == requested:
    state.setMessage("Removed " & $removed & " file(s)", "success")

proc executeCommand(state: var TUIState; cmd: string) =
  let parts = cmd.strip().split(' ', maxsplit = 1)
  if parts.len == 0:
    return

  case parts[0].toLowerAscii()
  of "cd":
    if parts.len > 1:
      navigateTo(state, parts[1])
    else:
      navigateTo(state, "~")
  of "q", "quit", "exit":
    state.running = false
  of "h", "hidden":
    toggleHidden(state)
  of "p", "preview":
    togglePreview(state)
  of "sort":
    if parts.len > 1:
      let s = parts[1].toLowerAscii()
      if s in ["name", "size", "time", "ext"]:
        state.sortBy = s
        if state.globalMode: refreshGlobalView(state)
        else: loadDirectory(state)
        state.setMessage("Sort by: " & s, "info")
  of "filter":
    if parts.len > 1 and parts[1].len > 0:
      state.typeFilter = parts[1][0..0]
      if state.globalMode: refreshGlobalView(state)
      else: loadDirectory(state)
    else:
      state.typeFilter = ""
      if state.globalMode: refreshGlobalView(state)
      else: loadDirectory(state)
  of "exec":
    if parts.len > 1:
      let cmd = parts[1]
      let entry = currentEntry(state)
      var targets: seq[string]
      if state.selectedPaths.len > 0:
        targets = state.selectedPaths
      elif entry.name.len > 0 and entry.name != "..":
        targets = @[entry.path]
      else:
        targets = @[]
      if targets.len == 0:
        state.setMessage("No file selected", "warning")
        return
      restoreTerminal(state.inputFd, state.terminalState)
      screenWrite(ColorReset & "\x1b[?2004l\x1b[?1049l")
      showCur()
      flushScreen()
      var exitCode = 0
      try:
        for path in targets:
          exitCode = runShellForPath(cmd, path)
          if exitCode != 0: break
      finally:
        discard enableRawTerminal(state.inputFd)
        screenWrite("\x1b[?1049h\x1b[?2004h")
        clearScr()
        state.previewKey = ""
      if exitCode != 0:
        state.setMessage("Command failed with exit code: " & $exitCode, "error")
        return
      state.setMessage("Executed: " & cmd & " on " & $targets.len & " file(s)", "success")
    else:
      state.setMessage("Usage: exec <command> (use {} for path)", "warning")
  of "rm", "delete":
    state.pendingDelete.setLen(0)
    if state.selectedPaths.len > 0:
      state.pendingDelete = state.selectedPaths
    else:
      let entry = currentEntry(state)
      if entry.name.len > 0 and entry.name != ".." and entry.kind == etFile:
        state.pendingDelete = @[entry.path]
      else:
        state.setMessage("No file selected", "warning")
        return
    state.confirmAction = "Delete permanently"
    state.confirmTarget = if state.pendingDelete.len == 1:
      safeDisplay(state.pendingDelete[0]) else: $state.pendingDelete.len & " selected files"
    state.mode = modeConfirm
  else:
    state.setMessage("Unknown command: " & parts[0], "error")

proc readByte(fd: cint; timeoutMs: int; ch: var char): int =
  when defined(posix):
    var descriptor = TPollfd(fd: fd, events: POLLIN)
    let ready = poll(addr descriptor, Tnfds(1), cint(timeoutMs))
    if ready == 0: return 0
    if ready < 0:
      if errno == EINTR: return 0
      return -1
    if (descriptor.revents and (POLLHUP or POLLERR or POLLNVAL)) != 0: return -1
    let n = readInput(fd, addr ch, 1)
    if n <= 0: return -1
    return 1
  else: -1

proc readKey(fd: cint; decoder: var InputDecoder): TerminalKey =
  var ch: char
  while true:
    let status = readByte(fd, decoder.timeoutMs(), ch)
    if status < 0: return TerminalKey(kind: "eof")
    if status == 0: return decoder.expire()
    result = decoder.feed(ch)
    if result.kind != "none" or not decoder.readingControl(): return

proc runInteractive*(cfg: Config) =
  let stdinFd = cint(getFileHandle(stdin))
  if not isatty(stdin) or (not isatty(stdout) and not isatty(stderr)):
    stderr.writeLine("fastfind: interactive mode requires a terminal")
    quit(2)
  screenFile = if isatty(stdout): stdout else: stderr
  initTerminalText()
  let terminalState = enableRawTerminal(stdinFd)
  stopSignalNumber = 0
  when defined(posix):
    let previousInt = swapSignal(SIGINT, stopOnSignal)
    let previousTerm = swapSignal(SIGTERM, stopOnSignal)
    defer:
      discard swapSignal(SIGINT, previousInt)
      discard swapSignal(SIGTERM, previousTerm)
  screenWrite("\x1b[?1049h\x1b[?2004h")

  var cleanupDone = false

  proc cleanup() =
    if not cleanupDone:
      restoreTerminal(stdinFd, terminalState)
      screenWrite(ColorReset & "\x1b[?2004l\x1b[?1049l")
      showCur()
      flushScreen()
      cleanupDone = true

  defer: cleanup()

  clearScr()

  var state = initState(cfg)
  state.inputFd = stdinFd
  state.terminalState = terminalState
  defer: stopGlobalSearch(state)
  loadDirectory(state)

  var showingBookmarks = false
  var inputDecoder: InputDecoder
  var dirty = true
  var lastWidth = 0
  var lastHeight = 0

  while state.running and stopSignalNumber == 0:
    if pollGlobalSearch(state): dirty = true
    state.width = max(1, terminalWidth())
    state.height = max(1, terminalHeight())
    if state.width != lastWidth or state.height != lastHeight:
      lastWidth = state.width
      lastHeight = state.height
      state.previewKey = ""
      adjustScroll(state)
      clearScr()
      dirty = true

    if dirty:
      render(state)
      if showingBookmarks:
        drawBookmarks(state)
        flushScreen()
      dirty = false

    let key = readKey(stdinFd, inputDecoder)
    if key.kind != "none": dirty = true
    if key.kind in ["eof", "ctrl-c"]:
      state.running = false
      continue
    if key.kind == "escape" and state.globalSearching:
      stopGlobalSearch(state)
      state.globalMode = false
      loadDirectory(state)
      continue
    if key.kind == "paste":
      case state.mode
      of modeSearch:
        state.query.add(key.text)
        applyFilter(state)
      of modeCommand: state.commandLine.add(key.text)
      of modeGoto: state.gotoPath.add(key.text)
      of modeGlobalSearch: state.globalPattern.add(key.text)
      else: state.setMessage("Paste into / filter, g search, or Tab path", "info")
      continue

    if showingBookmarks:
      case key.kind
      of "escape":
        showingBookmarks = false
      of "char":
        if key.ch >= '1' and key.ch <= '9':
          let idx = ord(key.ch) - ord('1')
          if idx < state.bookmarks.len:
            showingBookmarks = false
            navigateTo(state, state.bookmarks[idx])
        elif key.ch == 'd':
          showingBookmarks = false
      else:
        discard
      if key.kind != "none": dirty = true
      continue

    case state.mode
    of modeBrowse:
      case key.kind
      of "none":
        sleep(10)
      of "char":
        case key.ch
        of 'j':
          if state.cursor < state.filtered.len - 1:
            inc state.cursor
            adjustScroll(state)
        of 'k':
          if state.cursor > 0:
            dec state.cursor
            adjustScroll(state)
        of 'h':
          goUp(state)
        of 'l':
          enterDirectory(state)
        of 'g':
          toggleGlobalMode(state)
        of 'G':
          if state.filtered.len > 0:
            state.cursor = state.filtered.len - 1
            adjustScroll(state)
        of '~':
          navigateTo(state, "~")
        of '/':
          state.mode = modeSearch
          state.query = ""
        of ':':
          state.mode = modeCommand
          state.commandLine = ""
        of '.':
          toggleHidden(state)
        of 'p':
          togglePreview(state)
        of 'i':
          toggleDetails(state)
        of 's':
          cycleSort(state)
        of 'r':
          reverseSort(state)
        of 'v':
          selectAll(state)
        of 'V':
          clearSelection(state)
        of 'q':
          state.running = false
        of '?':
          drawHelp(state, stdinFd)
          clearScr()
        of '[':
          goBack(state)
        of ']':
          goForward(state)
        of 'b':
          addBookmark(state)
        of 'B':
          showingBookmarks = true
        of 'y':
          yankPath(state)
        of 'R':
          loadDirectory(state)
          state.setMessage("Refreshed", "info")
        of 'f':
          state.mode = modeFilter
        of '1', '2', '3', '4', '5', '6', '7', '8', '9':
          let idx = ord(key.ch) - ord('1')
          if idx < QuickDirs.len:
            var path = QuickDirs[idx][1]
            if path.startsWith("~"):
              path = getHomeDir() / path[1..^1]
            if dirExists(path):
              navigateTo(state, path)
        else:
          discard
      of "up":
        if state.cursor > 0:
          dec state.cursor
          adjustScroll(state)
      of "down":
        if state.cursor < state.filtered.len - 1:
          inc state.cursor
          adjustScroll(state)
      of "left":
        goUp(state)
      of "right":
        enterDirectory(state)
      of "enter":
        let entry = currentEntry(state)
        if entry.kind == etDir or (entry.kind == etLink and dirExists(entry.path)):
          enterDirectory(state)
        else:
          cleanup()
          if state.selectedPaths.len > 0:
            for path in state.selectedPaths:
              stdout.write(terminalText(path, cfg.print0) & (if cfg.print0: "\0" else: "\n"))
          elif entry.name.len > 0:
            stdout.write(terminalText(entry.path, cfg.print0) & (if cfg.print0: "\0" else: "\n"))
          stdout.flushFile()
          state.running = false
      of "space":
        toggleSelectAndMove(state)
      of "pageup", "ctrl-u":
        let h = listHeight(state)
        state.cursor = max(0, state.cursor - h)
        adjustScroll(state)
      of "pagedown", "ctrl-d":
        let h = listHeight(state)
        state.cursor = min(state.filtered.len - 1, state.cursor + h)
        if state.cursor < 0:
          state.cursor = 0
        adjustScroll(state)
      of "home":
        state.cursor = 0
        state.scroll = 0
      of "end":
        if state.filtered.len > 0:
          state.cursor = state.filtered.len - 1
          adjustScroll(state)
      of "tab":
        state.mode = modeGoto
        state.gotoPath = state.cwd & "/"
      of "ctrl-c":
        state.running = false
      of "ctrl-r":
        loadDirectory(state)
        state.setMessage("Refreshed", "info")
      of "escape":
        if state.query.len > 0:
          state.query = ""
          applyFilter(state)
        elif state.globalMode:
          state.globalMode = false
          loadDirectory(state)
      else:
        discard

    of modeSearch:
      case key.kind
      of "none":
        sleep(10)
      of "char", "space":
        state.query.add(key.ch)
        applyFilter(state)
      of "backspace":
        if state.query.len > 0:
          eraseLastRune(state.query)
          applyFilter(state)
        else:
          state.mode = modeBrowse
      of "enter":
        state.mode = modeBrowse
      of "escape":
        state.query = ""
        state.mode = modeBrowse
        applyFilter(state)
      of "ctrl-c":
        state.running = false
      of "ctrl-u":
        state.query = ""
        applyFilter(state)
      of "up":
        if state.cursor > 0:
          dec state.cursor
          adjustScroll(state)
      of "down":
        if state.cursor < state.filtered.len - 1:
          inc state.cursor
          adjustScroll(state)
      else:
        discard

    of modeGlobalSearch:
      case key.kind
      of "none":
        sleep(10)
      of "char", "space":
        state.globalPattern.add(key.ch)
      of "backspace":
        if state.globalPattern.len > 0:
          eraseLastRune(state.globalPattern)
        else:
          state.globalMode = false
          state.mode = modeBrowse
          loadDirectory(state)
      of "enter":
        if state.globalPattern.len > 0:
          state.mode = modeBrowse
          runGlobalSearch(state)
        else:
          state.globalMode = false
          state.mode = modeBrowse
          loadDirectory(state)
      of "escape":
        state.globalMode = false
        state.globalPattern = ""
        state.mode = modeBrowse
        loadDirectory(state)
      of "ctrl-c":
        state.running = false
      of "ctrl-u":
        state.globalPattern = ""
      else:
        discard

    of modeGoto:
      case key.kind
      of "none":
        sleep(10)
      of "char", "space":
        state.gotoPath.add(key.ch)
      of "backspace":
        if state.gotoPath.len > 0:
          eraseLastRune(state.gotoPath)
        else:
          state.mode = modeBrowse
      of "tab":
        var basePath = state.gotoPath
        if basePath.endsWith("/"):
          basePath = basePath[0..^2]
        let parent = parentDir(basePath)
        let prefix = extractFilename(basePath).toLowerAscii()

        if dirExists(parent):
          var matches: seq[string] = @[]
          try:
            for kind, path in walkDir(parent):
              let name = extractFilename(path)
              if kind == pcDir and name.toLowerAscii().startsWith(prefix):
                matches.add(path)
          except CatchableError:
            discard

          if matches.len == 1:
            state.gotoPath = matches[0] & "/"
          elif matches.len > 1:
            var common = matches[0]
            for m in matches[1..^1]:
              var i = 0
              while i < common.len and i < m.len and common[i] == m[i]:
                inc i
              common = common[0..<i]
            state.gotoPath = common
      of "enter":
        if state.gotoPath.len > 0:
          navigateTo(state, state.gotoPath)
        state.mode = modeBrowse
      of "escape":
        state.gotoPath = ""
        state.mode = modeBrowse
      of "ctrl-c":
        state.running = false
      of "ctrl-u":
        state.gotoPath = ""
      else:
        discard

    of modeCommand:
      case key.kind
      of "none":
        sleep(10)
      of "char", "space":
        state.commandLine.add(key.ch)
      of "backspace":
        if state.commandLine.len > 0:
          eraseLastRune(state.commandLine)
        else:
          state.mode = modeBrowse
      of "enter":
        executeCommand(state, state.commandLine)
        state.commandLine = ""
        if state.mode == modeCommand: state.mode = modeBrowse
      of "escape":
        state.commandLine = ""
        state.mode = modeBrowse
      of "ctrl-c":
        state.running = false
      of "ctrl-u":
        state.commandLine = ""
      else:
        discard

    of modeFilter:
      case key.kind
      of "char":
        if key.ch in ['f', 'd', 'l']:
          state.typeFilter = $key.ch
          if state.globalMode: refreshGlobalView(state)
          else: loadDirectory(state)
          state.setMessage("Filter: " & (if key.ch == 'f': "files" elif key.ch == 'd': "dirs" else: "links"), "info")
        state.mode = modeBrowse
      of "enter":
        state.typeFilter = ""
        if state.globalMode: refreshGlobalView(state)
        else: loadDirectory(state)
        state.setMessage("Filter cleared", "info")
        state.mode = modeBrowse
      of "escape":
        state.mode = modeBrowse
      of "ctrl-c":
        state.running = false
      else:
        discard

    of modeConfirm:
      case key.kind
      of "char":
        if key.ch == 'y' or key.ch == 'Y':
          performPendingDelete(state)
          state.mode = modeBrowse
        elif key.ch == 'n' or key.ch == 'N':
          state.pendingDelete.setLen(0)
          state.confirmAction = ""
          state.confirmTarget = ""
          state.mode = modeBrowse
      of "escape":
        state.pendingDelete.setLen(0)
        state.confirmAction = ""
        state.confirmTarget = ""
        state.mode = modeBrowse
      of "ctrl-c":
        state.running = false
      else:
        discard
