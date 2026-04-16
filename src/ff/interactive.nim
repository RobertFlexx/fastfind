import std/[os, terminal, times as times, strutils, algorithm, sequtils, re, osproc]
import core, cli, search, ansi, fuzzy_match, matchers

when defined(posix):
  import std/posix

  const
    ICANON = 2.cuint
    ECHO = 8.cuint
    VMIN = 6
    VTIME = 5
    TCSANOW = 0.cint

  type
    Termios {.importc: "struct termios", header: "<termios.h>", pure.} = object
      c_iflag: cuint
      c_oflag: cuint
      c_cflag: cuint
      c_lflag: cuint
      c_cc: array[32, uint8]

  proc tcgetattr(fd: cint; t: ptr Termios): cint {.importc, header: "<termios.h>".}
  proc tcsetattr(fd: cint; actions: cint; t: ptr Termios): cint {.importc, header: "<termios.h>".}

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
    yankPath: string
    lastJump: char

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

proc hideCur() =
  stdout.write("\x1b[?25l")

proc showCur() =
  stdout.write("\x1b[?25h")

proc gotoXY(x, y: int) =
  stdout.write("\x1b[" & $y & ";" & $x & "H")

proc clearScr() =
  stdout.write("\x1b[2J\x1b[H")

proc clearLn() =
  stdout.write("\x1b[2K")

proc clearToEOL() =
  stdout.write("\x1b[K")

proc initState(cfg: Config): TUIState =
  result.mode = modeBrowse
  result.prevMode = modeBrowse
  result.cwd = absolutePath(".")
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
  result.showHidden = false
  result.showPreview = true
  result.showDetails = true
  result.sortBy = "name"
  result.sortReverse = false
  result.running = true
  result.selectedPaths = @[]
  result.history = @[absolutePath(".")]
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
  result.lastJump = ' '
  
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
  if s.len <= maxLen:
    return s
  return "..." & s[s.len - maxLen + 3 .. ^1]

proc truncateRight(s: string; maxLen: int): string =
  if s.len <= maxLen:
    return s
  return s[0 ..< maxLen - 3] & "..."

proc padRight(s: string; width: int): string =
  if s.len >= width:
    return s[0 ..< width]
  return s & repeat(' ', width - s.len)

proc padLeft(s: string; width: int): string =
  if s.len >= width:
    return s[0 ..< width]
  return repeat(' ', width - s.len) & s

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

proc isExecutable(path: string): bool =
  when defined(posix):
    try:
      let info = getFileInfo(path)
      return fpUserExec in info.permissions or
             fpGroupExec in info.permissions or
             fpOthersExec in info.permissions
    except CatchableError:
      return false
  else:
    return false

proc getFileIcon(entry: FileEntry): string =
  if entry.kind == etDir:
    return "📁 "
  if entry.kind == etLink:
    return "🔗 "
  
  let ext = entry.name.splitFile.ext.toLowerAscii
  case ext
  of ".nim", ".py", ".rs", ".c", ".cpp", ".h", ".go", ".js", ".ts":
    return "📄 "
  of ".md", ".txt", ".rst", ".doc", ".docx", ".pdf":
    return "📝 "
  of ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".svg", ".webp":
    return "🖼  "
  of ".mp4", ".mkv", ".avi", ".mov", ".webm":
    return "🎬 "
  of ".mp3", ".wav", ".flac", ".ogg", ".m4a":
    return "🎵 "
  of ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar":
    return "📦 "
  of ".sh", ".bash", ".zsh", ".fish":
    return "⚙  "
  of ".json", ".yaml", ".yml", ".toml", ".xml", ".ini", ".conf":
    return "🔧 "
  of ".git":
    return "🌿 "
  else:
    if isExecutable(entry.path):
      return "⚡ "
    return "   "

proc loadDirectory(state: var TUIState) =
  state.entries = @[]
  state.filtered = @[]
  state.cursor = 0
  state.scroll = 0
  
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
      entry.selected = path in state.selectedPaths
      
      case kind
      of pcFile:
        entry.kind = etFile
      of pcDir:
        entry.kind = etDir
      of pcLinkToFile, pcLinkToDir:
        entry.kind = etLink
      
      try:
        let info = getFileInfo(path)
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
  state.filtered = @[]
  
  if state.query.len == 0:
    for i in 0 ..< state.entries.len:
      state.filtered.add(i)
    return
  
  let queryLower = state.query.toLowerAscii()
  var scored: seq[tuple[score: int, idx: int]] = @[]
  
  for i, entry in state.entries:
    if entry.name == "..":
      scored.add((-1000, i))
      continue
    
    let nameLower = entry.name.toLowerAscii()
    
    if queryLower.contains("*") or queryLower.contains("?"):
      let pattern = queryLower.replace(".", "\\.").replace("*", ".*").replace("?", ".")
      try:
        if nameLower.match(re(pattern)):
          scored.add((0, i))
      except CatchableError:
        if nameLower.contains(queryLower.replace("*", "").replace("?", "")):
          scored.add((50, i))
    else:
      let score = fuzzyMatch(queryLower, nameLower)
      if score >= 0:
        scored.add((score, i))
  
  scored.sort(proc(a, b: tuple[score: int, idx: int]): int = cmp(a.score, b.score))
  
  for item in scored:
    state.filtered.add(item.idx)
  
  if state.cursor >= state.filtered.len:
    state.cursor = max(0, state.filtered.len - 1)
  state.scroll = 0

proc runGlobalSearch(state: var TUIState) =
  state.globalResults = @[]
  state.globalSearching = true
  
  var searchCfg = state.baseConfig
  
  let home = getHomeDir()
  searchCfg.paths = @[home, "/tmp", "/etc", "/usr/local", "/opt"]
  
  searchCfg.patterns = @[state.globalPattern]
  searchCfg.limit = 500
  searchCfg.includeHidden = state.showHidden
  searchCfg.maxDepth = 10
  
  searchCfg.excludes = @[
    "*.git*", "*node_modules*", "*__pycache__*", "*.cache*",
    "*/.local/share/Trash*", "*/snap/*", "*/.npm/*", "*/.cargo/registry/*",
    "*/proc/*", "*/sys/*", "*/dev/*", "*/run/*"
  ]
  
  if state.globalPattern.startsWith("*."):
    searchCfg.matchMode = mmGlob
    searchCfg.pathMode = pmBaseName
  elif state.globalPattern.contains("*") or state.globalPattern.contains("?"):
    searchCfg.matchMode = mmGlob
    searchCfg.pathMode = pmBaseName
  else:
    searchCfg.matchMode = mmFixed
    searchCfg.pathMode = pmBaseName
    searchCfg.ignoreCase = true
  
  try:
    let res = runSearchCollect(searchCfg)
    
    for m in res.matches:
      var entry: FileEntry
      entry.name = m.name
      entry.path = m.absPath
      entry.relPath = m.relPath
      entry.kind = m.kind
      entry.size = m.size
      entry.mtime = m.mtime
      entry.selected = m.absPath in state.selectedPaths
      state.globalResults.add(entry)
  except CatchableError:
    discard
  
  state.globalSearching = false
  state.entries = state.globalResults
  state.filtered = @[]
  for i in 0 ..< state.entries.len:
    state.filtered.add(i)
  
  state.cursor = 0
  state.scroll = 0
  state.setMessage("Found " & $state.entries.len & " results", "success")

proc currentEntry(state: TUIState): FileEntry =
  if state.filtered.len == 0:
    return FileEntry()
  let idx = state.filtered[min(state.cursor, state.filtered.len - 1)]
  if idx < state.entries.len:
    return state.entries[idx]
  return FileEntry()

proc listHeight(state: TUIState): int =
  return state.height - 4

proc previewWidth(state: TUIState): int =
  if state.showPreview:
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
  stdout.write(ColorBorder)
  stdout.write("┌")
  if title.len > 0:
    stdout.write("┤ " & title & " ├")
    stdout.write(repeat("─", w - title.len - 6))
  else:
    stdout.write(repeat("─", w - 2))
  stdout.write("┐")
  
  for i in 1 ..< h - 1:
    gotoXY(x, y + i)
    stdout.write("│")
    gotoXY(x + w - 1, y + i)
    stdout.write("│")
  
  gotoXY(x, y + h - 1)
  stdout.write("└" & repeat("─", w - 2) & "┘")
  stdout.write(ColorReset)

proc drawHeader(state: TUIState) =
  gotoXY(1, 1)
  stdout.write(ColorHeader)
  
  var modeIndicator = ""
  if state.globalMode:
    modeIndicator = " 🌍 GLOBAL "
  
  let cwdDisplay = truncateLeft(state.cwd, state.width - 30)
  
  let modeStr = case state.mode
    of modeBrowse: "BROWSE"
    of modeSearch: "SEARCH"
    of modeCommand: "CMD"
    of modeGlobalSearch: "GLOBAL"
    of modeGoto: "GOTO"
    of modeFilter: "FILTER"
    of modeConfirm: "CONFIRM"
  
  let sortIndicator = " [" & state.sortBy & (if state.sortReverse: "↓" else: "↑") & "]"
  let filterIndicator = if state.typeFilter.len > 0: " [type:" & state.typeFilter & "]" else: ""
  
  let leftPart = " " & cwdDisplay
  let rightPart = modeIndicator & filterIndicator & sortIndicator & " [" & modeStr & "] "
  let padding = state.width - leftPart.len - rightPart.len
  
  stdout.write(leftPart)
  if padding > 0:
    stdout.write(repeat(' ', padding))
  stdout.write(rightPart)
  stdout.write(ColorReset)

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

proc drawEntry(state: TUIState; entry: FileEntry; y: int; width: int; isSelected: bool; isCursor: bool) =
  gotoXY(1, y)
  clearLn()
  
  var baseColor = ColorFile
  case entry.kind
  of etDir:
    baseColor = ColorDir
  of etLink:
    baseColor = ColorLink
  of etFile:
    if isExecutable(entry.path):
      baseColor = ColorExec
  
  if isCursor:
    stdout.write(ColorSelected)
    baseColor = ""
  
  var prefix = "  "
  if entry.selected:
    prefix = "● "
  if isCursor:
    prefix = "▶ "
    if entry.selected:
      prefix = "◉ "
  
  stdout.write(prefix)
  
  let icon = getFileIcon(entry)
  stdout.write(icon)
  
  let detailsWidth = if state.showDetails: 22 else: 0
  let nameWidth = width - 5 - icon.len - detailsWidth
  let name = truncateRight(entry.name, nameWidth)
  
  if state.query.len > 0 and entry.name != "..":
    stdout.write(highlightMatch(padRight(name, nameWidth), state.query, baseColor))
  else:
    stdout.write(baseColor & padRight(name, nameWidth))
  
  if state.showDetails:
    if not isCursor:
      stdout.write(ColorSize)
    
    if entry.kind == etDir and entry.name != "..":
      stdout.write(padLeft("<DIR>", 8))
    elif entry.name == "..":
      stdout.write(padLeft("", 8))
    else:
      stdout.write(formatSize(entry.size))
    
    stdout.write(" ")
    
    if not isCursor:
      stdout.write(ColorTime)
    
    if entry.name != "..":
      stdout.write(formatTime(entry.mtime))
  
  stdout.write(ColorReset)

proc drawList(state: TUIState) =
  let h = listHeight(state)
  let w = listWidth(state)
  
  for i in 0 ..< h:
    let y = 2 + i
    let idx = state.scroll + i
    
    if idx >= state.filtered.len:
      gotoXY(1, y)
      clearLn()
      continue
    
    let entryIdx = state.filtered[idx]
    if entryIdx >= state.entries.len:
      continue
    let entry = state.entries[entryIdx]
    let isCursor = idx == state.cursor
    let isSelected = entry.selected
    
    drawEntry(state, entry, y, w, isSelected, isCursor)

proc drawPreview(state: TUIState) =
  if not state.showPreview:
    return
  
  let pw = previewWidth(state)
  let px = listWidth(state) + 1
  let h = listHeight(state)
  
  for i in 0 ..< h:
    gotoXY(px, 2 + i)
    stdout.write(ColorBorder & "│" & ColorReset)
    stdout.write(repeat(' ', pw - 1))
  
  let entry = currentEntry(state)
  if entry.name.len == 0:
    return
  
  gotoXY(px + 2, 2)
  stdout.write(ColorBold)
  stdout.write(truncateRight(entry.name, pw - 4))
  stdout.write(ColorReset)
  
  gotoXY(px + 2, 3)
  stdout.write(ColorDim)
  stdout.write(truncateRight(entry.path, pw - 4))
  stdout.write(ColorReset)
  
  if entry.kind == etDir:
    gotoXY(px + 2, 5)
    stdout.write(ColorPreview & "Directory" & ColorReset)
    
    var count = 0
    var dirCount = 0
    var fileCount = 0
    try:
      for kind, path in walkDir(entry.path):
        inc count
        if kind == pcDir:
          inc dirCount
        else:
          inc fileCount
        if count > 500:
          break
    except CatchableError:
      discard
    
    gotoXY(px + 2, 6)
    let countStr = $dirCount & " dirs, " & $fileCount & " files"
    stdout.write(ColorPreview & countStr & ColorReset)
    return
  
  if entry.kind == etLink:
    gotoXY(px + 2, 5)
    stdout.write(ColorPreview & "Symbolic Link" & ColorReset)
    try:
      let target = expandSymlink(entry.path)
      gotoXY(px + 2, 6)
      stdout.write(ColorPreview & "-> " & truncateRight(target, pw - 7) & ColorReset)
    except CatchableError:
      discard
    return
  
  if entry.kind != etFile:
    return
  
  gotoXY(px + 2, 5)
  stdout.write(ColorDim & formatSize(entry.size) & " | " & formatTime(entry.mtime) & ColorReset)
  
  var f: File
  if not open(f, entry.path, fmRead):
    gotoXY(px + 2, 7)
    stdout.write(ColorError & "Cannot read file" & ColorReset)
    return
  
  defer: close(f)
  
  var lineNum = 0
  let maxLines = h - 8
  let maxWidth = pw - 4
  
  for line in f.lines:
    if lineNum >= maxLines:
      break
    
    gotoXY(px + 2, 7 + lineNum)
    
    var displayLine = line.replace("\t", "  ")
    var isBinary = false
    for ch in displayLine:
      if ord(ch) < 32 and ch notin ['\t', '\n', '\r']:
        isBinary = true
        break
    
    if isBinary:
      gotoXY(px + 2, 7)
      stdout.write(ColorDim & "[Binary file]" & ColorReset)
      return
    
    stdout.write(ColorPreview)
    stdout.write(truncateRight(displayLine, maxWidth))
    stdout.write(ColorReset)
    inc lineNum

proc drawStatusBar(state: TUIState) =
  gotoXY(1, state.height - 1)
  stdout.write(ColorStatus)
  clearLn()
  
  let selectedCount = state.selectedPaths.len
  let totalCount = state.filtered.len
  let cursorPos = if totalCount > 0: state.cursor + 1 else: 0
  
  var parts: seq[string] = @[]
  
  if selectedCount > 0:
    parts.add($selectedCount & " selected")
  
  parts.add($cursorPos & "/" & $totalCount)
  
  if state.globalMode:
    parts.add("GLOBAL")
  
  if state.showHidden:
    parts.add("hidden")
  
  if state.typeFilter.len > 0:
    parts.add("type:" & state.typeFilter)
  
  let left = " " & parts.join(" │ ")
  
  let entry = currentEntry(state)
  var right = ""
  if entry.name.len > 0 and entry.name != "..":
    let perms = try:
      let info = getFileInfo(entry.path)
      var p = ""
      if fpUserRead in info.permissions: p.add("r") else: p.add("-")
      if fpUserWrite in info.permissions: p.add("w") else: p.add("-")
      if fpUserExec in info.permissions: p.add("x") else: p.add("-")
      p
    except CatchableError:
      "---"
    right = perms & " │ " & formatSize(entry.size).strip() & " │ " & formatTime(entry.mtime).strip() & " "
  
  let padding = state.width - left.len - right.len
  stdout.write(left)
  if padding > 0:
    stdout.write(repeat(' ', padding))
  stdout.write(right)
  stdout.write(ColorReset)

proc drawPrompt(state: TUIState) =
  gotoXY(1, state.height)
  clearLn()
  
  case state.mode
  of modeBrowse:
    let elapsed = (times.getTime() - state.messageTime).inSeconds
    if state.message.len > 0 and elapsed < 5:
      let color = case state.messageType
        of "error": ColorError
        of "success": ColorSuccess
        of "warning": ColorWarning
        else: ColorPrompt
      stdout.write(color & state.message & ColorReset)
    else:
      stdout.write(ColorDim & "? help │ / search │ : command │ g global │ q quit" & ColorReset)
  of modeSearch:
    stdout.write(ColorPrompt & "search: " & ColorReset)
    stdout.write(state.query)
    stdout.write(ColorDim & "█" & ColorReset)
  of modeGlobalSearch:
    stdout.write(ColorPrompt & "global search (*, ? supported): " & ColorReset)
    stdout.write(state.globalPattern)
    stdout.write(ColorDim & "█" & ColorReset)
  of modeCommand:
    stdout.write(ColorPrompt & ":" & ColorReset)
    stdout.write(state.commandLine)
    stdout.write(ColorDim & "█" & ColorReset)
  of modeGoto:
    stdout.write(ColorPrompt & "goto: " & ColorReset)
    stdout.write(state.gotoPath)
    stdout.write(ColorDim & "█" & ColorReset)
  of modeFilter:
    stdout.write(ColorPrompt & "filter type (f=file, d=dir, l=link, Enter=clear): " & ColorReset)
  of modeConfirm:
    stdout.write(ColorWarning & state.confirmAction & " " & state.confirmTarget & "? (y/n) " & ColorReset)
  
  stdout.flushFile()

proc drawBookmarks(state: TUIState) =
  let bw = 50
  let bh = min(state.bookmarks.len + 4, state.height - 4)
  let bx = (state.width - bw) div 2
  let by = (state.height - bh) div 2
  
  drawBox(bx, by, bw, bh, "Bookmarks")
  
  if state.bookmarks.len == 0:
    gotoXY(bx + 2, by + 2)
    stdout.write(ColorDim & "No bookmarks. Press 'b' to add current dir." & ColorReset)
  else:
    for i, bm in state.bookmarks:
      if i >= bh - 4:
        break
      gotoXY(bx + 2, by + 2 + i)
      stdout.write(ColorPrompt & $(i + 1) & ColorReset & " " & truncateRight(bm, bw - 6))
  
  gotoXY(bx + 2, by + bh - 2)
  stdout.write(ColorDim & "1-9 jump │ d delete │ Esc close" & ColorReset)

proc drawHelp(state: TUIState; fd: cint) =
  clearScr()
  stdout.write(ColorHeader & " fastfind interactive mode " & ColorReset & "\n\n")
  
  stdout.write(ColorBold & "Navigation" & ColorReset & "\n")
  stdout.write("  j/↓         Move down          k/↑         Move up\n")
  stdout.write("  l/→/Enter   Enter directory    h/←         Parent directory\n")
  stdout.write("  g           Top                G           Bottom\n")
  stdout.write("  Ctrl+D      Page down          Ctrl+U      Page up\n")
  stdout.write("  [           History back       ]           History forward\n")
  stdout.write("  ~           Home directory     /           Root directory\n")
  stdout.write("  1-9         Quick jump dirs    Tab         Goto path\n")
  stdout.write("\n")
  
  stdout.write(ColorBold & "Search & Filter" & ColorReset & "\n")
  stdout.write("  /           Local search       Esc         Clear search\n")
  stdout.write("  g           Toggle global      f           Filter by type\n")
  stdout.write("  Supports: fuzzy, *.ext, file??.txt patterns\n")
  stdout.write("\n")
  
  stdout.write(ColorBold & "Selection" & ColorReset & "\n")
  stdout.write("  Space       Toggle select      v           Select all\n")
  stdout.write("  V           Clear selection    Enter       Confirm & exit\n")
  stdout.write("\n")
  
  stdout.write(ColorBold & "View & Sort" & ColorReset & "\n")
  stdout.write("  .           Toggle hidden      p           Toggle preview\n")
  stdout.write("  i           Toggle details     s           Cycle sort\n")
  stdout.write("  r           Reverse sort\n")
  stdout.write("\n")
  
  stdout.write(ColorBold & "Actions" & ColorReset & "\n")
  stdout.write("  y           Yank path          Enter       Open/select\n")
  stdout.write("  b           Add bookmark       B           Show bookmarks\n")
  stdout.write("  R           Refresh            :           Command mode\n")
  stdout.write("\n")
  
  stdout.write(ColorBold & "Commands (:)" & ColorReset & "\n")
  stdout.write("  :cd PATH    Change directory   :q          Quit\n")
  stdout.write("  :h          Toggle hidden      :sort NAME  Set sort\n")
  stdout.write("  :exec CMD   Run cmd on files  :rm         Delete file(s)\n")
  stdout.write("  (use {} in exec cmd for path, e.g. :exec rm {})\n")
  stdout.write("\n")
  
  stdout.write(ColorDim & "Press any key to continue..." & ColorReset)
  stdout.flushFile()
  
  var dummy: char
  while read(fd, addr dummy, 1) <= 0:
    sleep(50)

proc render(state: TUIState) =
  hideCur()
  drawHeader(state)
  drawList(state)
  drawPreview(state)
  drawStatusBar(state)
  drawPrompt(state)
  stdout.flushFile()

proc navigateTo(state: var TUIState; path: string) =
  var newPath = path
  if newPath.startsWith("~"):
    newPath = getHomeDir() / newPath[1..^1]
  newPath = absolutePath(newPath)
  
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
  
  if entry.kind == etDir:
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
  for i, entry in state.entries:
    if entry.name != ".." and entry.path notin state.selectedPaths:
      state.selectedPaths.add(entry.path)
      state.entries[i].selected = true

proc clearSelection(state: var TUIState) =
  state.selectedPaths = @[]
  for i in 0 ..< state.entries.len:
    state.entries[i].selected = false

proc toggleHidden(state: var TUIState) =
  state.showHidden = not state.showHidden
  if state.globalMode:
    state.globalResults = @[]
    state.entries = @[]
    state.filtered = @[]
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
  
  if not state.globalMode:
    loadDirectory(state)
  state.setMessage("Sort by: " & state.sortBy, "info")

proc reverseSort(state: var TUIState) =
  state.sortReverse = not state.sortReverse
  if not state.globalMode:
    loadDirectory(state)

proc toggleGlobalMode(state: var TUIState) =
  state.globalMode = not state.globalMode
  if state.globalMode:
    state.mode = modeGlobalSearch
    state.globalPattern = ""
    state.setMessage("Global search enabled - search entire filesystem", "info")
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
        if not state.globalMode:
          loadDirectory(state)
        state.setMessage("Sort by: " & s, "info")
  of "filter":
    if parts.len > 1:
      state.typeFilter = parts[1][0..0]
      loadDirectory(state)
    else:
      state.typeFilter = ""
      loadDirectory(state)
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
      for path in targets:
        let fullCmd = cmd.replace("{}", quoteShell(path))
        let code = execShellCmd(fullCmd)
        if code != 0:
          state.setMessage("Command failed with exit code: " & $code, "error")
          return
      state.setMessage("Executed: " & cmd & " on " & $targets.len & " file(s)", "success")
    else:
      state.setMessage("Usage: exec <command> (use {} for path)", "warning")
  of "rm", "delete":
    if state.selectedPaths.len > 0:
      for path in state.selectedPaths:
        try:
          removeFile(path)
          state.selectedPaths.delete(state.selectedPaths.find(path))
        except CatchableError:
          state.setMessage("Failed to remove: " & path, "error")
          return
      state.setMessage("Removed " & $state.selectedPaths.len & " file(s)", "success")
      loadDirectory(state)
    else:
      let entry = currentEntry(state)
      if entry.name.len > 0 and entry.name != ".." and entry.kind == etFile:
        try:
          removeFile(entry.path)
          state.setMessage("Removed: " & entry.name, "success")
          loadDirectory(state)
        except CatchableError:
          state.setMessage("Failed to remove: " & entry.name, "error")
      else:
        state.setMessage("No file selected", "warning")
  else:
    state.setMessage("Unknown command: " & parts[0], "error")

proc readKey(fd: cint): tuple[kind: string, ch: char] =
  var buf: array[8, char]
  let n = read(fd, addr buf[0], 1)
  
  if n <= 0:
    return ("none", '\0')
  
  let ch = buf[0]
  
  if ch == '\x1b':
    var seqBuf: array[8, char]
    let n2 = read(fd, addr seqBuf[0], 2)
    if n2 == 2 and seqBuf[0] == '[':
      case seqBuf[1]
      of 'A': return ("up", '\0')
      of 'B': return ("down", '\0')
      of 'C': return ("right", '\0')
      of 'D': return ("left", '\0')
      of 'H': return ("home", '\0')
      of 'F': return ("end", '\0')
      of '5':
        discard read(fd, addr seqBuf[2], 1)
        return ("pageup", '\0')
      of '6':
        discard read(fd, addr seqBuf[2], 1)
        return ("pagedown", '\0')
      of '3':
        discard read(fd, addr seqBuf[2], 1)
        return ("delete", '\0')
      else:
        return ("escape", '\0')
    return ("escape", '\0')
  
  if ch == '\r' or ch == '\n':
    return ("enter", '\0')
  if ch == '\t':
    return ("tab", '\0')
  if ch == '\x7f' or ch == '\b':
    return ("backspace", '\0')
  if ch == '\x03':
    return ("ctrl-c", '\0')
  if ch == '\x04':
    return ("ctrl-d", '\0')
  if ch == '\x15':
    return ("ctrl-u", '\0')
  if ch == '\x17':
    return ("ctrl-w", '\0')
  if ch == '\x12':
    return ("ctrl-r", '\0')
  if ch == ' ':
    return ("space", ' ')
  if ch >= ' ' and ch <= '~':
    return ("char", ch)
  
  return ("unknown", ch)

proc runInteractive*(cfg: Config) =
  when not defined(posix):
    stderr.writeLine("Interactive mode requires POSIX system")
    quit(1)
  
  let stdinFd = cint(getFileHandle(stdin))
  
  var oldTermios: Termios
  discard tcgetattr(stdinFd, addr oldTermios)
  
  var rawTermios = oldTermios
  rawTermios.c_lflag = rawTermios.c_lflag and not ICANON and not ECHO
  rawTermios.c_cc[VMIN] = 0
  rawTermios.c_cc[VTIME] = 1
  discard tcsetattr(stdinFd, TCSANOW, addr rawTermios)
  
  var cleanupDone = false
  
  proc cleanup() =
    if not cleanupDone:
      discard tcsetattr(stdinFd, TCSANOW, addr oldTermios)
      showCur()
      clearScr()
      stdout.flushFile()
      cleanupDone = true
  
  defer: cleanup()
  
  clearScr()
  
  var state = initState(cfg)
  loadDirectory(state)
  
  var showingBookmarks = false
  
  while state.running:
    state.width = terminalWidth()
    state.height = terminalHeight()
    
    render(state)
    
    if showingBookmarks:
      drawBookmarks(state)
      stdout.flushFile()
    
    let key = readKey(stdinFd)
    
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
          if state.lastJump == 'g':
            state.cursor = 0
            state.scroll = 0
            state.lastJump = ' '
          else:
            toggleGlobalMode(state)
            state.lastJump = 'g'
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
          state.lastJump = ' '
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
        if entry.kind == etDir:
          enterDirectory(state)
        else:
          cleanupDone = true
          discard tcsetattr(stdinFd, TCSANOW, addr oldTermios)
          showCur()
          stdout.write("\x1b[2J\x1b[H")
          if state.selectedPaths.len > 0:
            for p in state.selectedPaths:
              echo p
          elif entry.name.len > 0:
            echo entry.path
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
      of "char":
        state.query.add(key.ch)
        applyFilter(state)
      of "backspace":
        if state.query.len > 0:
          state.query.setLen(state.query.len - 1)
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
      of "char":
        state.globalPattern.add(key.ch)
      of "backspace":
        if state.globalPattern.len > 0:
          state.globalPattern.setLen(state.globalPattern.len - 1)
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
      of "char":
        state.gotoPath.add(key.ch)
      of "backspace":
        if state.gotoPath.len > 0:
          state.gotoPath.setLen(state.gotoPath.len - 1)
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
      of "char":
        state.commandLine.add(key.ch)
      of "backspace":
        if state.commandLine.len > 0:
          state.commandLine.setLen(state.commandLine.len - 1)
        else:
          state.mode = modeBrowse
      of "enter":
        executeCommand(state, state.commandLine)
        state.commandLine = ""
        state.mode = modeBrowse
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
          loadDirectory(state)
          state.setMessage("Filter: " & (if key.ch == 'f': "files" elif key.ch == 'd': "dirs" else: "links"), "info")
        state.mode = modeBrowse
      of "enter":
        state.typeFilter = ""
        loadDirectory(state)
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
          state.mode = modeBrowse
        elif key.ch == 'n' or key.ch == 'N':
          state.confirmAction = ""
          state.confirmTarget = ""
          state.mode = modeBrowse
      of "escape":
        state.confirmAction = ""
        state.confirmTarget = ""
        state.mode = modeBrowse
      of "ctrl-c":
        state.running = false
      else:
        discard
