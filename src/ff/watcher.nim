# src/ff/watcher.nim
## filesystem watcher for index auto updates
## supports inotify (linux) and kqueue (bsd and macos)

import std/[os, posix, times, sets, tables]

when defined(linux):
  # inotify constants and types
  const
    IN_ACCESS* = 0x00000001'u32
    IN_MODIFY* = 0x00000002'u32
    IN_ATTRIB* = 0x00000004'u32
    IN_CLOSE_WRITE* = 0x00000008'u32
    IN_CLOSE_NOWRITE* = 0x00000010'u32
    IN_OPEN* = 0x00000020'u32
    IN_MOVED_FROM* = 0x00000040'u32
    IN_MOVED_TO* = 0x00000080'u32
    IN_CREATE* = 0x00000100'u32
    IN_DELETE* = 0x00000200'u32
    IN_DELETE_SELF* = 0x00000400'u32
    IN_MOVE_SELF* = 0x00000800'u32
    IN_ISDIR* = 0x40000000'u32
    IN_ALL_EVENTS* = IN_ACCESS or IN_MODIFY or IN_ATTRIB or IN_CLOSE_WRITE or
                     IN_CLOSE_NOWRITE or IN_OPEN or IN_MOVED_FROM or IN_MOVED_TO or
                     IN_CREATE or IN_DELETE or IN_DELETE_SELF or IN_MOVE_SELF
    IN_WATCH_EVENTS* = IN_CREATE or IN_DELETE or IN_MODIFY or IN_MOVED_FROM or IN_MOVED_TO
  
  type
    InotifyEvent* {.importc: "struct inotify_event", header: "<sys/inotify.h>".} = object
      wd*: cint
      mask*: uint32
      cookie*: uint32
      len*: uint32
      # name follows

  proc inotify_init(): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_init1(flags: cint): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_add_watch(fd: cint; path: cstring; mask: uint32): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_rm_watch(fd: cint; wd: cint): cint {.importc, header: "<sys/inotify.h>".}

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
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
  
  type
    Kevent* {.importc: "struct kevent", header: "<sys/event.h>".} = object
      ident*: cuint    # identifier
      filter*: cshort  # filter type
      flags*: cushort  # action flags
      fflags*: cuint   # filter flags
      data*: clong     # filter data
      udata*: pointer  # user data
    
    Timespec* {.importc: "struct timespec", header: "<time.h>".} = object
      tv_sec*: clong
      tv_nsec*: clong
  
  proc kqueue(): cint {.importc, header: "<sys/event.h>".}
  proc kevent(kq: cint; changelist: ptr Kevent; nchanges: cint;
              eventlist: ptr Kevent; nevents: cint; timeout: ptr Timespec): cint {.importc, header: "<sys/event.h>".}

type
  FileEventKind* = enum
    fekCreated, fekModified, fekDeleted, fekRenamed, fekUnknown
  
  FileEvent* = object
    path*: string
    kind*: FileEventKind
    isDir*: bool
    timestamp*: times.Time
  
  WatcherCallback* = proc(event: FileEvent) {.closure.}
  
  Watcher* = object
    fd*: cint
    running*: bool
    watchedPaths*: HashSet[string]
    watchDescriptors*: Table[cint, string]  # for inotify
    fileDescriptors*: Table[cint, string]   # for kqueue
    callback*: WatcherCallback

proc newWatcher*(): Watcher =
  result.running = false
  result.watchedPaths = initHashSet[string]()
  result.watchDescriptors = initTable[cint, string]()
  result.fileDescriptors = initTable[cint, string]()
  
  when defined(linux):
    result.fd = inotify_init()
    if result.fd < 0:
      raise newException(OSError, "Failed to initialize inotify")
  
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    result.fd = kqueue()
    if result.fd < 0:
      raise newException(OSError, "Failed to initialize kqueue")

proc addWatch*(w: var Watcher; path: string; recursive: bool = true) =
  ## add a path to watch
  
  if not dirExists(path) and not fileExists(path):
    return
  
  when defined(linux):
    let wd = inotify_add_watch(w.fd, path.cstring, IN_WATCH_EVENTS)
    if wd >= 0:
      w.watchDescriptors[wd] = path
      w.watchedPaths.incl(path)
    
    if recursive and dirExists(path):
      for kind, subpath in walkDir(path):
        if kind == pcDir:
          w.addWatch(subpath, recursive = true)
  
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    let fd = open(path.cstring, O_RDONLY)
    if fd >= 0:
      var ev: Kevent
      ev.ident = fd.cuint
      ev.filter = EVFILT_VNODE
      ev.flags = EV_ADD or EV_CLEAR or EV_ENABLE
      ev.fflags = NOTE_ALL
      ev.data = 0
      ev.udata = nil
      
      if kevent(w.fd, addr ev, 1, nil, 0, nil) >= 0:
        w.fileDescriptors[fd] = path
        w.watchedPaths.incl(path)
    
    if recursive and dirExists(path):
      for kind, subpath in walkDir(path):
        if kind == pcDir:
          w.addWatch(subpath, recursive = true)

proc removeWatch*(w: var Watcher; path: string) =
  ## remove a path from watching
  
  when defined(linux):
    for wd, p in w.watchDescriptors:
      if p == path:
        discard inotify_rm_watch(w.fd, wd)
        w.watchDescriptors.del(wd)
        break
  
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    for fd, p in w.fileDescriptors:
      if p == path:
        discard close(fd)
        w.fileDescriptors.del(fd)
        break
  
  w.watchedPaths.excl(path)

proc close*(w: var Watcher) =
  ## close the watcher and release resources
  
  when defined(linux):
    for wd in w.watchDescriptors.keys:
      discard inotify_rm_watch(w.fd, wd)
    discard close(w.fd)
  
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    for fd in w.fileDescriptors.keys:
      discard close(fd)
    discard close(w.fd)
  
  w.watchDescriptors.clear()
  w.fileDescriptors.clear()
  w.watchedPaths.clear()
  w.running = false

when defined(linux):
  proc processInotifyEvents(w: var Watcher; callback: WatcherCallback) =
    var buf: array[4096, char]
    let length = read(w.fd, addr buf[0], buf.len)
    
    if length <= 0: return
    
    var offset = 0
    while offset < length:
      let event = cast[ptr InotifyEvent](addr buf[offset])
      
      var path = w.watchDescriptors.getOrDefault(event.wd, "")
      
      if event.len > 0:
        # extract the name
        var name = ""
        var i = 0
        let namePtr = cast[ptr char](cast[int](event) + sizeof(InotifyEvent))
        while i < int(event.len):
          let c = cast[ptr char](cast[int](namePtr) + i)[]
          if c == '\0': break
          name.add(c)
          inc i
        if name.len > 0:
          path = path / name
      
      var kind = fekUnknown
      if (event.mask and IN_CREATE) != 0:
        kind = fekCreated
      elif (event.mask and IN_DELETE) != 0:
        kind = fekDeleted
      elif (event.mask and IN_MODIFY) != 0:
        kind = fekModified
      elif (event.mask and (IN_MOVED_FROM or IN_MOVED_TO)) != 0:
        kind = fekRenamed
      
      let isDir = (event.mask and IN_ISDIR) != 0
      
      let fe = FileEvent(
        path: path,
        kind: kind,
        isDir: isDir,
        timestamp: getTime()
      )
      
      callback(fe)
      
      # if a new directory was created, add a watch for it
      if kind == fekCreated and isDir:
        w.addWatch(path, recursive = true)
      
      offset += sizeof(InotifyEvent) + int(event.len)

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  proc processKqueueEvents(w: var Watcher; callback: WatcherCallback) =
    var events: array[10, Kevent]
    var timeout: Timespec
    timeout.tv_sec = 0
    timeout.tv_nsec = 100_000_000  # 100ms
    
    let n = kevent(w.fd, nil, 0, addr events[0], 10, addr timeout)
    
    for i in 0 ..< n:
      let ev = events[i]
      let fd = cint(ev.ident)
      let path = w.fileDescriptors.getOrDefault(fd, "")
      
      if path.len == 0: continue
      
      var kind = fekUnknown
      if (ev.fflags and NOTE_DELETE) != 0:
        kind = fekDeleted
      elif (ev.fflags and (NOTE_WRITE or NOTE_EXTEND)) != 0:
        kind = fekModified
      elif (ev.fflags and NOTE_RENAME) != 0:
        kind = fekRenamed
      elif (ev.fflags and NOTE_ATTRIB) != 0:
        kind = fekModified
      
      let isDir = dirExists(path)
      
      let fe = FileEvent(
        path: path,
        kind: kind,
        isDir: isDir,
        timestamp: getTime()
      )
      
      callback(fe)

proc processEvents*(w: var Watcher; callback: WatcherCallback) =
  ## process pending events (non blocking)
  
  when defined(linux):
    processInotifyEvents(w, callback)
  
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    processKqueueEvents(w, callback)

proc run*(w: var Watcher; callback: WatcherCallback) =
  ## run the watcher loop (blocking)
  
  w.running = true
  w.callback = callback
  
  while w.running:
    w.processEvents(callback)
    sleep(100)  # small delay to avoid busy loop

proc stop*(w: var Watcher) =
  ## Stop the watcher loop
  w.running = false

# convenience function for watching a directory
proc watchDirectory*(path: string; callback: WatcherCallback) =
  ## watch a directory for changes
  var w = newWatcher()
  w.addWatch(path, recursive = true)
  
  try:
    w.run(callback)
  finally:
    w.close()
