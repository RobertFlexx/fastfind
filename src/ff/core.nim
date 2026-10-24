# src/ff/core.nim
import std/[os, times]

type
  EntryType* = enum
    etFile, etDir, etLink

  OutputMode* = enum
    omPlain, omLong, omJson, omNdJson, omTable

  SortKey* = enum
    skNone, skPath, skName, skSize, skTime

  MatchResult* = object
    path*: string
    absPath*: string
    relPath*: string
    name*: string
    size*: int64
    mtime*: Time
    kind*: EntryType
    fuzzyScore*: int       ## lower is better (for fuzzy matching)
    lineNumber*: int       ## for semantic search results

  SearchResult* = object
    matches*: seq[MatchResult]
    stats*: Stats

  Stats* = object
    visited*: int
    visitedFiles*: int
    visitedDirs*: int
    visitedLinks*: int
    matched*: int
    errors*: int
    skipped*: int
    bytesRead*: int64
    startTime*: Time
    endTime*: Time

proc isHiddenName*(name: string): bool {.inline.} =
  name.len > 0 and name[0] == '.' and name != "." and name != ".."

proc kindFromPathComponent*(k: PathComponent): EntryType {.inline.} =
  case k
  of pcFile, pcLinkToFile: etFile
  of pcDir, pcLinkToDir: etDir

proc entryTypeFromWalk*(k: PathComponent): EntryType {.inline.} =
  case k
  of pcFile: etFile
  of pcDir: etDir
  of pcLinkToFile, pcLinkToDir: etLink

proc safeRelPath*(p, root: string): string {.inline.} =
  try:
    result = relativePath(p, root)
  except CatchableError:
    result = p

proc withinRoot*(path, root: string): bool {.inline.} =
  ## Include the separator boundary, including when root is `/` itself.
  if path == root: return true
  if root.len == 0 or path.len <= root.len: return false
  for i in 0..<root.len:
    if path[i] != root[i]: return false
  root[^1] == DirSep or path[root.len] == DirSep

proc ownedCopy*(matches: seq[MatchResult]): seq[MatchResult] =
  ## Copy into the caller's allocator before a producing thread exits. Nim
  ## strings/sequences must not outlive their allocating thread's heap.
  result = newSeq[MatchResult](matches.len)
  for i in 0..<matches.len:
    result[i] = matches[i]
    for field in fields(result[i]):
      when field is string:
        var copy = newString(field.len)
        if field.len > 0: copyMem(addr copy[0], unsafeAddr field[0], field.len)
        field = move copy
