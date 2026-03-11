# src/ff/content.nim
import std/[os, strutils, re, memfiles]
s

proc looksBinary(buf: openArray[char]): bool =
  for ch in buf:
    if ch == '\0': return true
  false

proc looksBinaryMem(data: cstring; length: int): bool =
  for i in 0 ..< length:
    if data[i] == '\0': return true
  false

proc fileContainsText*(path: string; needle: string; maxBytes: int; allowBinary: bool; bytesRead: var int64): bool =
  if needle.len == 0: return true
  var f: File
  if not open(f, path, fmRead): return false
  defer: close(f)

  let cap = max(0, maxBytes)
  var readTotal = 0
  var buf = newString(64 * 1024)
  var carry = ""

  while true:
    let toRead = if cap == 0: buf.len else: min(buf.len, cap - readTotal)
    if cap != 0 and toRead <= 0: break
    let n = f.readBuffer(addr buf[0], toRead)
    if n <= 0: break
    readTotal += n
    bytesRead += n.int64

    let chunk = carry & buf[0..<n]
    if chunk.len > 0 and (not allowBinary) and looksBinary(chunk.toOpenArray(0, chunk.len-1)): return false
    if chunk.contains(needle): return true
    # keep a tail in case needle spans the boundary
    if needle.len <= 1:
      carry = ""
    else:
      let keep = min(needle.len - 1, chunk.len)
      carry = chunk[chunk.len - keep .. ^1]
  false

proc fileContainsRegex*(path: string; rx: Regex; maxBytes: int; allowBinary: bool; bytesRead: var int64): bool =
  var f: File
  if not open(f, path, fmRead): return false
  defer: close(f)

  let cap = max(0, maxBytes)
  var readTotal = 0
  var buf = newString(64 * 1024)
  var carry = ""

  while true:
    let toRead = if cap == 0: buf.len else: min(buf.len, cap - readTotal)
    if cap != 0 and toRead <= 0: break
    let n = f.readBuffer(addr buf[0], toRead)
    if n <= 0: break
    readTotal += n
    bytesRead += n.int64

    let chunk = carry & buf[0..<n]
    if chunk.len > 0 and (not allowBinary) and looksBinary(chunk.toOpenArray(0, chunk.len-1)): return false
    if chunk.match(rx): return true
    let keep = min(2048, chunk.len)
    carry = if keep == 0: "" else: chunk[chunk.len - keep .. ^1]
  false

# memory mapped versions for large files

proc fileContainsTextMmap*(path: string; needle: string; allowBinary: bool; bytesRead: var int64): bool =
  ## memory mapped version for large file content search
  ## more efficient for files > 1MB
  
  if needle.len == 0: return true
  
  var mm: MemFile
  try:
    mm = memfiles.open(path, fmRead)
  except OSError:
    return false
  
  defer: mm.close()
  
  let size = mm.size
  bytesRead = size.int64
  
  if size == 0: return false
  
  let data = cast[cstring](mm.mem)
  
  # check for binary
  if not allowBinary:
    # check first 8KB for binary content
    let checkLen = min(8192, size)
    if looksBinaryMem(data, checkLen):
      return false
  
  # search for needle using Boyer-Moore-Horspool-like approach (big wurds awhffohpa)
  let needleLen = needle.len
  if needleLen == 0: return true
  if size < needleLen: return false
  
  # build skip table
  var skip: array[256, int]
  for i in 0 ..< 256:
    skip[i] = needleLen
  for i in 0 ..< needleLen - 1:
    skip[ord(needle[i])] = needleLen - 1 - i
  
  var pos = 0
  while pos <= size - needleLen:
    var j = needleLen - 1
    while j >= 0 and data[pos + j] == needle[j]:
      dec j
    
    if j < 0:
      return true  # Found
    
    pos += skip[ord(data[pos + needleLen - 1])]
  
  return false

proc fileContainsRegexMmap*(path: string; rx: Regex; allowBinary: bool; bytesRead: var int64): bool =
  ## memory mapped regex search
  ## note: loads entire file content, use with caution on very large files
  
  var mm: MemFile
  try:
    mm = memfiles.open(path, fmRead)
  except OSError:
    return false
  
  defer: mm.close()
  
  let size = mm.size
  bytesRead = size.int64
  
  if size == 0: return false
  
  # for regex, we need to convert to string (not ideal for huge files)
  # limit to reasonable size
  if size > 100 * 1024 * 1024:  # 100MB limit for regex
    return false
  
  let data = cast[cstring](mm.mem)
  
  if not allowBinary:
    let checkLen = min(8192, size)
    if looksBinaryMem(data, checkLen):
      return false
  
  # convert to string for regex matching
  var content = newString(size)
  copyMem(addr content[0], mm.mem, size)
  
  return content.contains(rx)

# intelligent content search that chooses method based on file size
proc fileContainsTextSmart*(path: string; needle: string; maxBytes: int; 
                            allowBinary: bool; bytesRead: var int64): bool =
  ## automatically chooses between streaming and memory mapped search
  ## based on file size and search parameters
  
  let info = getFileInfo(path)
  let size = info.size
  
  # for small files or when maxBytes is set, use streaming
  if size < 1024 * 1024 or maxBytes > 0:  # < 1MB
    return fileContainsText(path, needle, maxBytes, allowBinary, bytesRead)
  
  # for larger files, use memory mapped search
  return fileContainsTextMmap(path, needle, allowBinary, bytesRead)

proc fileContainsRegexSmart*(path: string; rx: Regex; maxBytes: int;
                             allowBinary: bool; bytesRead: var int64): bool =
  ## automatically chooses between streaming and memory-mapped regex search
  
  let info = getFileInfo(path)
  let size = info.size
  
  # for small files or when maxBytes is set, use streaming
  if size < 1024 * 1024 or maxBytes > 0:
    return fileContainsRegex(path, rx, maxBytes, allowBinary, bytesRead)
  
  # for larger files up to 100MB, try mmap
  if size < 100 * 1024 * 1024:
    return fileContainsRegexMmap(path, rx, allowBinary, bytesRead)
  
  # for very large files, fall back to streaming
  return fileContainsRegex(path, rx, maxBytes, allowBinary, bytesRead)

# grep like line search with line numbers
type
  LineMatch* = object
    lineNumber*: int
    lineContent*: string
    matchStart*: int
    matchEnd*: int

proc grepFile*(path: string; pattern: string; ignoreCase: bool = false;
               maxMatches: int = 100): seq[LineMatch] =
  ## search file line by line, returning matching lines with line numbers
  result = @[]
  
  var f: File
  if not open(f, path, fmRead): return
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
  ## search file with regex, returning matching lines
  result = @[]
  
  var f: File
  if not open(f, path, fmRead): return
  defer: close(f)
  
  var lineNum = 0
  
  for line in f.lines:
    inc lineNum
    
    if line.contains(rx):
      var bounds: tuple[first, last: int] = (0, 0)
      let m = line.find(rx)
      if m != -1:
        bounds = (m, m + 1)  # approximate
      
      result.add(LineMatch(
        lineNumber: lineNum,
        lineContent: line,
        matchStart: bounds.first,
        matchEnd: bounds.last
      ))
      
      if result.len >= maxMatches:
        break
