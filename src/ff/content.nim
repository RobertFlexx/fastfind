# src/ff/content.nim
import std/[os, strutils, re]

when defined(posix):
  import std/posix

proc openRegularFile*(f: var File; path: string): bool =
  ## Open nonblocking first, then verify the opened descriptor. A FIFO or a
  ## symlink swapped in during traversal must never hang a search or preview.
  when defined(posix):
    var flags = O_RDONLY or O_NONBLOCK
    when declared(O_CLOEXEC): flags = flags or O_CLOEXEC
    let fd = posix.open(path.cstring, flags)
    if fd < 0: return false
    var info: Stat
    if fstat(fd, info) != 0 or not S_ISREG(info.st_mode):
      discard posix.close(fd)
      return false
    if not system.open(f, FileHandle(fd), fmRead):
      discard posix.close(fd)
      return false
    true
  else:
    open(f, path, fmRead)

when not defined(openbsd):
  import std/memfiles

  proc mapRegularFile(path: string): MemFile =
    when defined(posix):
      var f: File
      if not openRegularFile(f, path):
        raise newException(OSError, "not a readable regular file")
      defer: close(f)
      var info: Stat
      let fd = cint(getFileHandle(f))
      if fstat(fd, info) != 0 or info.st_size <= 0 or info.st_size > high(int):
        raise newException(OSError, "file cannot be mapped")
      result.size = int(info.st_size)
      result.mem = mmap(nil, result.size, PROT_READ, MAP_PRIVATE, fd, 0)
      if result.mem == MAP_FAILED:
        raise newException(OSError, "file cannot be mapped")
      result.handle = -1
    else:
      result = memfiles.open(path, fmRead)

proc looksBinary(buf: openArray[char]): bool =
  for ch in buf:
    if ch == '\0': return true
  false

proc looksBinaryMem(data: cstring; length: int): bool =
  for i in 0 ..< length:
    if data[i] == '\0': return true
  false

proc asciiLower(c: char): char {.inline.} =
  if c in {'A'..'Z'}: chr(ord(c) + 32) else: c

proc containsText(buf, needle: string; ignoreCase: bool): bool {.inline.} =
  if not ignoreCase: return buf.find(needle) >= 0
  if needle.len == 0: return true
  if needle.len > buf.len: return false
  var skip: array[256, int]
  for i in 0..<256: skip[i] = needle.len
  for i in 0..<needle.len - 1:
    skip[ord(asciiLower(needle[i]))] = needle.len - 1 - i
  var pos = 0
  while pos <= buf.len - needle.len:
    var j = needle.len - 1
    while j >= 0 and asciiLower(buf[pos + j]) == asciiLower(needle[j]): dec j
    if j < 0: return true
    pos += skip[ord(asciiLower(buf[pos + needle.len - 1]))]
  false

proc fileContainsText*(path: string; needle: string; maxBytes: int; allowBinary: bool;
                       bytesRead: var int64; ignoreCase: bool = false;
                       validFile: ptr bool = nil): bool =
  if validFile != nil: validFile[] = false
  if needle.len == 0: return true
  var f: File
  if not openRegularFile(f, path): return false
  defer: close(f)

  let cap = max(0, maxBytes)
  var readTotal = 0
  const ChunkSize = 64 * 1024
  var buf = newString(ChunkSize + max(0, needle.len - 1))
  var carryLen = 0

  while true:
    let toRead = if cap == 0: ChunkSize else: min(ChunkSize, cap - readTotal)
    if cap != 0 and toRead <= 0: break
    buf.setLen(carryLen + toRead)
    let n = f.readBuffer(addr buf[carryLen], toRead)
    if n <= 0: break
    readTotal += n
    bytesRead += n.int64
    let total = carryLen + n
    buf.setLen(total)
    if not allowBinary and looksBinary(buf): return false
    if containsText(buf, needle, ignoreCase):
      if validFile != nil: validFile[] = true
      return true
    carryLen = min(max(0, needle.len - 1), total)
    if carryLen > 0:
      moveMem(addr buf[0], addr buf[total - carryLen], carryLen)
  if validFile != nil: validFile[] = true
  false

proc fileContainsRegex*(path: string; rx: Regex; maxBytes: int; allowBinary: bool; bytesRead: var int64): bool =
  var f: File
  if not openRegularFile(f, path): return false
  defer: close(f)

  let cap = max(0, maxBytes)
  var readTotal = 0
  # Keep enough of the previous chunk to catch matches split across reads.
  # Small or capped files still use one buffer, which keeps anchors and long
  # multi-line matches exact without letting huge files take over memory.
  const ChunkSize = 256 * 1024
  const RegexOverlap = 64 * 1024
  if cap > 0 and cap <= 16 * 1024 * 1024:
    var content = newString(cap)
    let n = f.readBuffer(addr content[0], cap)
    if n <= 0: return "".contains(rx)
    content.setLen(n)
    bytesRead += n
    if not allowBinary and looksBinary(content): return false
    return content.contains(rx)
  var buf = newString(ChunkSize + RegexOverlap)
  var carryLen = 0

  while true:
    let toRead = if cap == 0: ChunkSize else: min(ChunkSize, cap - readTotal)
    if cap != 0 and toRead <= 0: break
    buf.setLen(carryLen + toRead)
    let n = f.readBuffer(addr buf[carryLen], toRead)
    if n <= 0: break
    readTotal += n
    bytesRead += n.int64

    let total = carryLen + n
    buf.setLen(total)
    if not allowBinary and looksBinary(buf): return false
    if buf.contains(rx): return true
    carryLen = min(RegexOverlap, total)
    moveMem(addr buf[0], addr buf[total - carryLen], carryLen)
  if readTotal == 0: return "".contains(rx)
  false

when not defined(openbsd):
  proc fileContainsTextMmap*(path: string; needle: string; allowBinary: bool;
                             bytesRead: var int64; ignoreCase: bool = false): bool =
    if needle.len == 0: return true
    
    var mm: MemFile
    try:
      mm = mapRegularFile(path)
    except OSError:
      return false
    
    defer: mm.close()
    
    let size = mm.size
    bytesRead += size.int64
    
    if size == 0: return false
    
    let data = cast[cstring](mm.mem)
    
    if not allowBinary:
      let checkLen = min(8192, size)
      if looksBinaryMem(data, checkLen):
        return false
    
    let needleLen = needle.len
    if needleLen == 0: return true
    if size < needleLen: return false
    
    var skip: array[256, int]
    for i in 0 ..< 256:
      skip[i] = needleLen
    for i in 0 ..< needleLen - 1:
      skip[ord(if ignoreCase: asciiLower(needle[i]) else: needle[i])] = needleLen - 1 - i
    
    var pos = 0
    while pos <= size - needleLen:
      var j = needleLen - 1
      while j >= 0 and
          (if ignoreCase: asciiLower(data[pos + j]) == asciiLower(needle[j])
           else: data[pos + j] == needle[j]):
        dec j
      
      if j < 0:
        return true
      
      let tail = if ignoreCase: asciiLower(data[pos + needleLen - 1]) else: data[pos + needleLen - 1]
      pos += skip[ord(tail)]
    
    return false

  proc fileContainsRegexMmap*(path: string; rx: Regex; allowBinary: bool; bytesRead: var int64): bool =
    var mm: MemFile
    try:
      mm = mapRegularFile(path)
    except OSError:
      return false
    
    defer: mm.close()
    
    let size = mm.size
    bytesRead += size.int64
    
    if size == 0: return false
    
    let data = cast[cstring](mm.mem)
    
    if not allowBinary:
      let checkLen = min(8192, size)
      if looksBinaryMem(data, checkLen):
        return false
    
    # PCRE accepts a pointer and explicit length; duplicating the entire map
    # used to consume another file-sized allocation per worker.
    if size > int(high(cint)): return false
    return find(data, rx, 0, size) >= 0

else:
  # OpenBSD fallbacks - use streaming versions
  proc fileContainsTextMmap*(path: string; needle: string; allowBinary: bool;
                             bytesRead: var int64; ignoreCase: bool = false): bool =
    return fileContainsText(path, needle, 0, allowBinary, bytesRead, ignoreCase)

  proc fileContainsRegexMmap*(path: string; rx: Regex; allowBinary: bool; bytesRead: var int64): bool =
    return fileContainsRegex(path, rx, 0, allowBinary, bytesRead)

proc fileContainsTextSmart*(path: string; needle: string; maxBytes: int; 
                            allowBinary: bool; bytesRead: var int64;
                            knownSize: int64 = -1;
                            ignoreCase: bool = false): bool =
  when defined(openbsd):
    return fileContainsText(path, needle, maxBytes, allowBinary, bytesRead, ignoreCase)
  else:
    let size = if knownSize >= 0: knownSize else: getFileSize(path)
    
    if size < 1024 * 1024 or maxBytes > 0:
      return fileContainsText(path, needle, maxBytes, allowBinary, bytesRead, ignoreCase)
    
    return fileContainsTextMmap(path, needle, allowBinary, bytesRead, ignoreCase)

proc fileContainsRegexSmart*(path: string; rx: Regex; maxBytes: int;
                             allowBinary: bool; bytesRead: var int64;
                             knownSize: int64 = -1): bool =
  when defined(openbsd):
    return fileContainsRegex(path, rx, maxBytes, allowBinary, bytesRead)
  else:
    let size = if knownSize >= 0: knownSize else: getFileSize(path)
    
    if maxBytes == 0 and size <= 16 * 1024 * 1024:
      # Use one buffer for ordinary files so anchors and long matches work as
      # people expect.
      return fileContainsRegex(path, rx, int(size), allowBinary, bytesRead)
    if maxBytes > 0:
      return fileContainsRegex(path, rx, maxBytes, allowBinary, bytesRead)
    
    return fileContainsRegexMmap(path, rx, allowBinary, bytesRead)

type
  LineMatch* = object
    lineNumber*: int
    lineContent*: string
    matchStart*: int
    matchEnd*: int

proc grepFile*(path: string; pattern: string; ignoreCase: bool = false;
               maxMatches: int = 100): seq[LineMatch] =
  result = @[]
  
  var f: File
  if not openRegularFile(f, path): return
  defer: close(f)
  
  let searchPat = if ignoreCase: pattern.toLowerAscii() else: pattern
  var lineNum = 0
  
  for line in f.lines:
    inc lineNum
    let searchLine = if ignoreCase: line.toLowerAscii() else: line
    let pos = searchLine.find(searchPat)
    
    if pos >= 0:
      result.add(LineMatch(
        lineNumber: lineNum,
        lineContent: line,
        matchStart: pos,
        matchEnd: pos + pattern.len
      ))
      
      if result.len >= maxMatches:
        break

proc grepFileRegex*(path: string; rx: Regex; maxMatches: int = 100): seq[LineMatch] =
  result = @[]
  
  var f: File
  if not openRegularFile(f, path): return
  defer: close(f)
  
  var lineNum = 0
  
  for line in f.lines:
    inc lineNum
    
    if line.contains(rx):
      let bounds = findBounds(line, rx)
      
      result.add(LineMatch(
        lineNumber: lineNum,
        lineContent: line,
        matchStart: bounds.first,
        matchEnd: bounds.last
      ))
      
      if result.len >= maxMatches:
        break
