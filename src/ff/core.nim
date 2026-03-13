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
