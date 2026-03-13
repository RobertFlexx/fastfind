import std/[os, times, sets, tables, options]

when defined(linux):
  import std/posix
  
  const
    IN_ACCESS = 0x00000001'u32
    IN_MODIFY = 0x00000002'u32
    IN_ATTRIB = 0x00000004'u32
    IN_CLOSE_WRITE = 0x00000008'u32
    IN_CLOSE_NOWRITE = 0x00000010'u32
    IN_OPEN = 0x00000020'u32
    IN_MOVED_FROM = 0x00000040'u32
    IN_MOVED_TO = 0x00000080'u32
    IN_CREATE = 0x00000100'u32
    IN_DELETE = 0x00000200'u32
    IN_DELETE_SELF = 0x00000400'u32
    IN_MOVE_SELF = 0x00000800'u32
    IN_ISDIR = 0x40000000'u32
    IN_NONBLOCK = 0x00000800'u32
    IN_CLOEXEC = 0x00080000'u32
    IN_WATCH_EVENTS = IN_CREATE or IN_DELETE or IN_MODIFY or IN_MOVED_FROM or IN_MOVED_TO or IN_CLOSE_WRITE
    INOTIFY_EVENT_SIZE = 16
    INOTIFY_BUF_LEN = 4096

  proc inotify_init(): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_init1(flags: cint): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_add_watch(fd: cint; path: cstring; mask: uint32): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_rm_watch(fd: cint; wd: cint): cint {.importc, header: "<sys/inotify.h>".}

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  import std/posix
  
  const
    EVFILT_VNODE = -4'i16
    NOTE_DELETE = 0x00000001'u32
    NOTE_WRITE = 0x00000002'u32
    NOTE_EXTEND = 0x00000004'u32
    NOTE_ATTRIB = 0x00000008'u32
    NOTE_LINK = 0x00000010'u32
    NOTE_RENAME = 0x00000020'u32
    NOTE_REVOKE = 0x00000040'u32
    NOTE_ALL = NOTE_DELETE or NOTE_WRITE or NOTE_EXTEND or NOTE_ATTRIB or NOTE_LINK or NOTE_RENAME
    EV_ADD = 0x0001'u16
    EV_DELETE = 0x0002'u16
    EV_ENABLE = 0x0004'u16
    EV_CLEAR = 0x0020'u16
    O_EVTONLY = 0x8000

  type
    KEvent {.importc: "struct kevent", header: "<sys/event.h>", pure, final.} = object
      ident: cuint
      filter: cshort
      flags: cushort
      fflags: cuint
      data: clong
      udata: pointer

    TimeSpec {.importc: "struct timespec", header: "<time.h>", pure, final.} = object
      tv_sec: clong
      tv_nsec: clong

  proc kqueue(): cint {.importc, header: "<sys/event.h>".}
  proc kevent(kq: cint; changelist: ptr KEvent; nchanges: cint;
              eventlist: ptr KEvent; nevents: cint; timeout: ptr TimeSpec): cint {.importc, header: "<sys/event.h>".}

type
  FileEventKind* = enum
    fekCreated
    fekModified
    fekDeleted
    fekRenamed
    fekAttributeChanged
    fekUnknown

  FileEvent* = object
    path*: string
    kind*: FileEventKind
    isDir*: bool
    timestamp*: Time
    cookie*: uint32

  WatcherCallback* = proc(event: FileEvent) {.closure, gcsafe.}

  WatcherError* = object of CatchableError

  WatcherState = enum
    wsIdle
    wsRunning
    wsStopping
    wsClosed

  Watcher* = ref object
    fd: cint
    state: WatcherState
    watchedPaths: HashSet[string]
    pathToWd: Table[string, cint]
    wdToPath: Table[cint, string]
    fdToPath: Table[cint, string]
    pathToFd: Table[string, cint]
    callback: WatcherCallback
    maxWatches: int
    errorCallback: proc(msg: string) {.closure, gcsafe.}
    pendingEvents: seq[FileEvent]
    renameCache: Table[uint32, string]

proc isSupported*(): bool =
  when defined(linux) or defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    true
  else:
    false

proc newWatcher*(maxWatches: int = 10000): Watcher =
  result = Watcher(
    fd: -1,
    state: wsIdle,
    watchedPaths: initHashSet[string](),
    pathToWd: initTable[string, cint](),
    wdToPath: initTable[cint, string](),
    fdToPath: initTable[cint, string](),
    pathToFd: initTable[string, cint](),
    maxWatches: maxWatches,
    pendingEvents: @[],
    renameCache: initTable[uint32, string]()
  )
  when defined(linux):
    result.fd = inotify_init1(cint(IN_NONBLOCK or IN_CLOEXEC))
    if result.fd < 0:
      result.fd = inotify_init()
    if result.fd < 0:
      raise newException(WatcherError, "Failed to initialize inotify: " & $errno)
  elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    result.fd = kqueue()
    if result.fd < 0:
      raise newException(WatcherError, "Failed to initialize kqueue: " & $errno)
  else:
    raise newException(WatcherError, "Filesystem watching not supported on this platform")

proc setErrorCallback*(w: Watcher; cb: proc(msg: string) {.closure, gcsafe.}) =
  w.errorCallback = cb

proc logError(w: Watcher; msg: string) =
  if w.errorCallback != nil:
    w.errorCallback(msg)

proc watchCount*(w: Watcher): int =
  w.watchedPaths.len

proc isWatching*(w: Watcher; path: string): bool =
  path in w.watchedPaths

proc isRunning*(w: Watcher): bool =
  w.state == wsRunning

when defined(linux):
  proc addWatchLinux(w: Watcher; path: string): bool =
    if path in w.pathToWd:
      return true
    if w.watchedPaths.len >= w.maxWatches:
      w.logError("Max watch limit reached: " & $w.maxWatches)
      return false
    let wd = inotify_add_watch(w.fd, path.cstring, IN_WATCH_EVENTS)
    if wd < 0:
      let err = errno
      if err == ENOSPC:
        w.logError("Inotify watch limit reached. Increase /proc/sys/fs/inotify/max_user_watches")
      elif err == EACCES:
        w.logError("Permission denied: " & path)
      elif err == ENOENT:
        return false
      else:
        w.logError("Failed to watch " & path & ": errno=" & $err)
      return false
    w.pathToWd[path] = wd
    w.wdToPath[wd] = path
    w.watchedPaths.incl(path)
    true

  proc removeWatchLinux(w: Watcher; path: string) =
    if path notin w.pathToWd:
      return
    let wd = w.pathToWd[path]
    discard inotify_rm_watch(w.fd, wd)
    w.pathToWd.del(path)
    w.wdToPath.del(wd)
    w.watchedPaths.excl(path)

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  proc addWatchBSD(w: Watcher; path: string): bool =
    if path in w.pathToFd:
      return true
    if w.watchedPaths.len >= w.maxWatches:
      w.logError("Max watch limit reached: " & $w.maxWatches)
      return false
    var flags = O_RDONLY
    when defined(macosx):
      flags = O_EVTONLY
    let fd = open(path.cstring, cint(flags))
    if fd < 0:
      let err = errno
      if err == EACCES:
        w.logError("Permission denied: " & path)
      elif err == ENOENT:
        return false
      else:
        w.logError("Failed to open for watching " & path & ": errno=" & $err)
      return false
    var ev: KEvent
    ev.ident = cuint(fd)
    ev.filter = EVFILT_VNODE
    ev.flags = EV_ADD or EV_CLEAR or EV_ENABLE
    ev.fflags = NOTE_ALL
    ev.data = 0
    ev.udata = nil
    if kevent(w.fd, addr ev, 1, nil, 0, nil) < 0:
      discard close(cint(fd))
      w.logError("Failed to add kevent for " & path)
      return false
    w.pathToFd[path] = cint(fd)
    w.fdToPath[cint(fd)] = path
    w.watchedPaths.incl(path)
    true

  proc removeWatchBSD(w: Watcher; path: string) =
    if path notin w.pathToFd:
      return
    let fd = w.pathToFd[path]
    var ev: KEvent
    ev.ident = cuint(fd)
    ev.filter = EVFILT_VNODE
    ev.flags = EV_DELETE
    ev.fflags = 0
    ev.data = 0
    ev.udata = nil
    discard kevent(w.fd, addr ev, 1, nil, 0, nil)
    discard close(fd)
    w.pathToFd.del(path)
    w.fdToPath.del(fd)
    w.watchedPaths.excl(path)

proc addWatch*(w: Watcher; path: string; recursive: bool = true) =
  if w.state == wsClosed:
    raise newException(WatcherError, "Watcher is closed")
  let absPath = absolutePath(path)
  if not dirExists(absPath) and not fileExists(absPath):
    return
  when defined(linux):
    if not w.addWatchLinux(absPath):
      return
  elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    if not w.addWatchBSD(absPath):
      return
  if recursive and dirExists(absPath):
    try:
      for kind, subpath in walkDir(absPath):
        if kind == pcDir:
          w.addWatch(subpath, recursive = true)
    except OSError:
      discard

proc removeWatch*(w: Watcher; path: string; recursive: bool = true) =
  if w.state == wsClosed:
    return
  let absPath = absolutePath(path)
  when defined(linux):
    w.removeWatchLinux(absPath)
  elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    w.removeWatchBSD(absPath)
  if recursive:
    var toRemove: seq[string] = @[]
    for watched in w.watchedPaths:
      if watched.startsWith(absPath & "/"):
        toRemove.add(watched)
    for p in toRemove:
      when defined(linux):
        w.removeWatchLinux(p)
      elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
        w.removeWatchBSD(p)

proc close*(w: Watcher) =
  if w.state == wsClosed:
    return
  w.state = wsClosed
  when defined(linux):
    for wd in toSeq(w.wdToPath.keys):
      discard inotify_rm_watch(w.fd, wd)
    if w.fd >= 0:
      discard close(w.fd)
  elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    for fd in toSeq(w.fdToPath.keys):
      discard close(fd)
    if w.fd >= 0:
      discard close(w.fd)
  w.fd = -1
  w.pathToWd.clear()
  w.wdToPath.clear()
  w.pathToFd.clear()
  w.fdToPath.clear()
  w.watchedPaths.clear()
  w.pendingEvents.setLen(0)
  w.renameCache.clear()

when defined(linux):
  proc readInotifyEvents(w: Watcher): seq[FileEvent] =
    result = @[]
    var buf: array[INOTIFY_BUF_LEN, uint8]
    let bytesRead = read(w.fd, addr buf[0], INOTIFY_BUF_LEN)
    if bytesRead <= 0:
      return
    var offset = 0
    while offset < bytesRead:
      if offset + INOTIFY_EVENT_SIZE > bytesRead:
        break
      let wd = cast[ptr cint](addr buf[offset])[]
      let mask = cast[ptr uint32](addr buf[offset + 4])[]
      let cookie = cast[ptr uint32](addr buf[offset + 8])[]
      let nameLen = cast[ptr uint32](addr buf[offset + 12])[]
      offset += INOTIFY_EVENT_SIZE
      var name = ""
      if nameLen > 0:
        if offset + int(nameLen) > bytesRead:
          break
        for i in 0..<int(nameLen):
          let c = char(buf[offset + i])
          if c == '\0':
            break
          name.add(c)
        offset += int(nameLen)
      let basePath = w.wdToPath.getOrDefault(wd, "")
      if basePath.len == 0:
        continue
      let fullPath = if name.len > 0: basePath / name else: basePath
      var kind = fekUnknown
      if (mask and IN_CREATE) != 0:
        kind = fekCreated
      elif (mask and IN_DELETE) != 0 or (mask and IN_DELETE_SELF) != 0:
        kind = fekDeleted
      elif (mask and IN_MODIFY) != 0 or (mask and IN_CLOSE_WRITE) != 0:
        kind = fekModified
      elif (mask and IN_MOVED_FROM) != 0:
        kind = fekRenamed
        w.renameCache[cookie] = fullPath
        continue
      elif (mask and IN_MOVED_TO) != 0:
        kind = fekRenamed
        if cookie in w.renameCache:
          w.renameCache.del(cookie)
      elif (mask and IN_ATTRIB) != 0:
        kind = fekAttributeChanged
      let isDir = (mask and IN_ISDIR) != 0
      let event = FileEvent(
        path: fullPath,
        kind: kind,
        isDir: isDir,
        timestamp: getTime(),
        cookie: cookie
      )
      result.add(event)
      if kind == fekCreated and isDir:
        try:
          w.addWatch(fullPath, recursive = true)
        except CatchableError:
          discard
      elif kind == fekDeleted:
        if fullPath in w.watchedPaths:
          w.removeWatchLinux(fullPath)

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  proc readKqueueEvents(w: Watcher): seq[FileEvent] =
    result = @[]
    var events: array[32, KEvent]
    var timeout: TimeSpec
    timeout.tv_sec = 0
    timeout.tv_nsec = 0
    let n = kevent(w.fd, nil, 0, addr events[0], 32, addr timeout)
    if n <= 0:
      return
    for i in 0..<n:
      let ev = events[i]
      let fd = cint(ev.ident)
      let path = w.fdToPath.getOrDefault(fd, "")
      if path.len == 0:
        continue
      var kind = fekUnknown
      if (ev.fflags and NOTE_DELETE) != 0:
        kind = fekDeleted
      elif (ev.fflags and NOTE_RENAME) != 0:
        kind = fekRenamed
      elif (ev.fflags and (NOTE_WRITE or NOTE_EXTEND)) != 0:
        kind = fekModified
      elif (ev.fflags and NOTE_ATTRIB) != 0:
        kind = fekAttributeChanged
      elif (ev.fflags and NOTE_LINK) != 0:
        kind = fekModified
      var isDir = false
      try:
        isDir = dirExists(path)
      except CatchableError:
        discard
      let event = FileEvent(
        path: path,
        kind: kind,
        isDir: isDir,
        timestamp: getTime(),
        cookie: 0
      )
      result.add(event)
      if kind == fekDeleted:
        w.removeWatchBSD(path)

proc pollEvents*(w: Watcher): seq[FileEvent] =
  if w.state == wsClosed:
    return @[]
  when defined(linux):
    result = w.readInotifyEvents()
  elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    result = w.readKqueueEvents()
  else:
    result = @[]

proc processEvents*(w: Watcher; callback: WatcherCallback) =
  let events = w.pollEvents()
  for event in events:
    try:
      callback(event)
    except CatchableError as e:
      w.logError("Callback error: " & e.msg)

proc run*(w: Watcher; callback: WatcherCallback; pollIntervalMs: int = 100) =
  if w.state != wsIdle:
    raise newException(WatcherError, "Watcher is already running or closed")
  w.state = wsRunning
  w.callback = callback
  while w.state == wsRunning:
    w.processEvents(callback)
    sleep(pollIntervalMs)
  w.state = wsIdle

proc stop*(w: Watcher) =
  if w.state == wsRunning:
    w.state = wsStopping

proc runAsync*(w: Watcher; callback: WatcherCallback): bool =
  if w.state != wsIdle:
    return false
  w.state = wsRunning
  w.callback = callback
  true

proc tick*(w: Watcher): seq[FileEvent] =
  if w.state != wsRunning:
    return @[]
  w.pollEvents()

proc watchDirectory*(path: string; callback: WatcherCallback; recursive: bool = true) =
  var w = newWatcher()
  try:
    w.addWatch(path, recursive = recursive)
    w.run(callback)
  finally:
    w.close()

proc createBatchedCallback*(callback: WatcherCallback; 
                            batchIntervalMs: int = 100): WatcherCallback =
  var lastEvents: seq[FileEvent] = @[]
  var lastFlush = getTime()
  var seenPaths: HashSet[string] = initHashSet[string]()
  result = proc(event: FileEvent) =
    let key = event.path & ":" & $event.kind
    if key in seenPaths:
      return
    seenPaths.incl(key)
    lastEvents.add(event)
    let now = getTime()
    if (now - lastFlush).inMilliseconds >= batchIntervalMs:
      for e in lastEvents:
        callback(e)
      lastEvents.setLen(0)
      seenPaths.clear()
      lastFlush = now

proc formatEvent*(event: FileEvent): string =
  let kindStr = case event.kind
    of fekCreated: "CREATED"
    of fekModified: "MODIFIED"
    of fekDeleted: "DELETED"
    of fekRenamed: "RENAMED"
    of fekAttributeChanged: "ATTRIB"
    of fekUnknown: "UNKNOWN"
  let typeStr = if event.isDir: "DIR" else: "FILE"
  result = "[" & kindStr & "] [" & typeStr & "] " & event.path
