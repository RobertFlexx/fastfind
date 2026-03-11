# src/ff/interactive.nim
import std/[os, terminal]
import core, cli, search, ansi

when defined(posix):
  import std/[posix, termios]

  proc setRawMode(fd: FileHandle): Termios =
    var old: Termios
    discard tcgetattr(fd, addr old)
    var raw = old
    raw.c_lflag = raw.c_lflag and not(ICANON or ECHO)
    raw.c_cc[VMIN] = 0.cuchar
    raw.c_cc[VTIME] = 1.cuchar
    discard tcsetattr(fd, TCSAFLUSH, addr raw)
    result = old

  proc restoreMode(fd: FileHandle; old: Termios) =
    discard tcsetattr(fd, TCSAFLUSH, unsafeAddr old)

type
  UIState = object
    query: string
    results: seq[MatchResult]
    selected: int
    offset: int
    needsRedraw: bool
    showPreview: bool

const
  MaxResults = 100

proc clearScreen() =
  stdout.write("\x1b[2J\x1b[H")
  stdout.flushFile()

proc moveCursor(row, col: int) =
  stdout.write("\x1b[" & $row & ";" & $col & "H")

proc clearLine() =
  stdout.write("\x1b[2K")

proc renderUI(state: UIState; cfg: Config) =
  clearScreen()
  
  # header
  stdout.write(b("Search: "))
  stdout.writeLine(state.query & "_")
  stdout.writeLine("")
  
  # results
  let termHeight = terminalHeight() - 5
  let maxVisible = min(termHeight, state.results.len)
  
  for i in 0 ..< maxVisible:
    let idx = state.offset + i
    if idx >= state.results.len: break
    
    let m = state.results[idx]
    let marker = if idx == state.selected: "> " else: "  "
    let line = marker & m.relPath
    
    if idx == state.selected:
      stdout.write(c(line, Green, true))
    else:
      stdout.write(line)
    stdout.write("\n")
  
  # status line
  stdout.write("\n")
  stdout.write(dim("↑/↓: navigate | Enter: select | Tab: preview | Ctrl+C: exit"))
  stdout.flushFile()

proc runSearch(query: string; cfg: var Config): seq[MatchResult] =
  if query.len == 0: return @[]
  
  cfg.patterns = @[query]
  cfg.limit = MaxResults
  
  let res = runSearchCollect(cfg)
  result = res.matches

proc runInteractive*(cfg: Config) =
  when not defined(posix):
    stderr.writeLine("Interactive mode not supported on this platform")
    quit(1)
  else:
    var state = UIState()
    state.needsRedraw = true
    
    let stdinFd = stdin.getFileHandle()
    let oldMode = setRawMode(stdinFd)
    defer: restoreMode(stdinFd, oldMode)
    
    hideCursor()
    defer: showCursor()
    
    var searchCfg = cfg
    searchCfg.fuzzyMode = true
    searchCfg.rankMode = rmScore
    
    while true:
      if state.needsRedraw:
        renderUI(state, cfg)
        state.needsRedraw = false
      
      # read input (non blocking)
      var ch: char
      let n = read(stdinFd, addr ch, 1)
      
      if n <= 0:
        sleep(10)
        continue
      
      case ch
      of '\x03': # Ctrl+C
        break
      of '\r', '\n': # enter
        if state.selected >= 0 and state.selected < state.results.len:
          clearScreen()
          showCursor()
          stdout.writeLine(state.results[state.selected].relPath)
        break
      of '\x7F', '\b': # backspace
        if state.query.len > 0:
          state.query.setLen(state.query.len - 1)
          state.results = runSearch(state.query, searchCfg)
          state.selected = 0
          state.offset = 0
          state.needsRedraw = true
      of '\t': # Tab
        state.showPreview = not state.showPreview
        state.needsRedraw = true
      of '\x1B': # escape sequence
        var seq: array[2, char]
        if read(stdinFd, addr seq[0], 2) == 2:
          if seq[0] == '[':
            case seq[1]
            of 'A': # Up
              if state.selected > 0:
                dec state.selected
                if state.selected < state.offset:
                  state.offset = state.selected
                state.needsRedraw = true
            of 'B': # down
              if state.selected < state.results.len - 1:
                inc state.selected
                let termHeight = terminalHeight() - 5
                if state.selected >= state.offset + termHeight:
                  state.offset = state.selected - termHeight + 1
                state.needsRedraw = true
            else:
              discard
      else:
        if ch >= ' ' and ch <= '~':
          state.query.add(ch)
          state.results = runSearch(state.query, searchCfg)
          state.selected = 0
          state.offset = 0
          state.needsRedraw = true
    
    clearScreen()
    showCursor()
