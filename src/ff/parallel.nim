# src/ff/parallel.nim

import std/[locks, atomics, options, os, strutils]
import std/times as times
import core

type
  DirEntry* = object
    path*: string
    relPath*: string
    depth*: int

  WorkQueue* = ptr WorkQueueObj
  WorkQueueObj = object
    items: seq[DirEntry]
    lock: Lock
    activeWorkers: Atomic[int]
    pendingDirs: Atomic[int]
    shutdown: Atomic[bool]

  ResultCollector* = ptr ResultCollectorObj
  ResultCollectorObj = object
    matches: seq[MatchResult]
    lock: Lock
    limit: int
    limitReached: Atomic[bool]

  AtomicStats* = ptr AtomicStatsObj
  AtomicStatsObj = object
    visited: Atomic[int]
    visitedFiles: Atomic[int]
    visitedDirs: Atomic[int]
    visitedLinks: Atomic[int]
    matched: Atomic[int]
    errors: Atomic[int]
    skipped: Atomic[int]
    bytesRead: Atomic[int64]

  PathBuffer* = object
    data*: string
    len*: int

proc newWorkQueue*(): WorkQueue =
  result = cast[WorkQueue](allocShared0(sizeof(WorkQueueObj)))
  result.items = @[]
  initLock(result.lock)
  result.activeWorkers.store(0)
  result.pendingDirs.store(0)
  result.shutdown.store(false)

proc destroy*(q: WorkQueue) =
  if q != nil:
    deinitLock(q.lock)
    deallocShared(q)

proc push*(q: WorkQueue, entry: DirEntry) =
  discard q.pendingDirs.fetchAdd(1)
  acquire(q.lock)
  q.items.add(entry)
  release(q.lock)

proc pushBatch*(q: WorkQueue, entries: openArray[DirEntry]) =
  if entries.len == 0: return
  discard q.pendingDirs.fetchAdd(entries.len)
  acquire(q.lock)
  q.items.add(entries)
  release(q.lock)

proc tryPop*(q: WorkQueue): Option[DirEntry] =
  acquire(q.lock)
  if q.items.len > 0:
    result = some(q.items.pop())
  else:
    result = none(DirEntry)
  release(q.lock)

proc tryPopBatch*(q: WorkQueue, maxCount: int): seq[DirEntry] =
  result = @[]
  acquire(q.lock)
  let count = min(maxCount, q.items.len)
  for i in 0..<count:
    result.add(q.items.pop())
  release(q.lock)

proc isEmpty*(q: WorkQueue): bool {.inline.} =
  acquire(q.lock)
  result = q.items.len == 0
  release(q.lock)

proc len*(q: WorkQueue): int {.inline.} =
  acquire(q.lock)
  result = q.items.len
  release(q.lock)

proc markWorkerActive*(q: WorkQueue) {.inline.} =
  discard q.activeWorkers.fetchAdd(1)

proc markWorkerIdle*(q: WorkQueue) {.inline.} =
  discard q.activeWorkers.fetchSub(1)

proc activeWorkerCount*(q: WorkQueue): int {.inline.} =
  q.activeWorkers.load()

proc signalShutdown*(q: WorkQueue) {.inline.} =
  q.shutdown.store(true)

proc isShutdown*(q: WorkQueue): bool {.inline.} =
  q.shutdown.load()

proc decPending*(q: WorkQueue) {.inline.} =
  discard q.pendingDirs.fetchSub(1)

proc isComplete*(q: WorkQueue): bool {.inline.} =
  q.pendingDirs.load() == 0

proc newResultCollector*(limit: int = 0): ResultCollector =
  result = cast[ResultCollector](allocShared0(sizeof(ResultCollectorObj)))
  result.matches = @[]
  initLock(result.lock)
  result.limit = limit
  result.limitReached.store(false)

proc destroy*(rc: ResultCollector) =
  if rc != nil:
    deinitLock(rc.lock)
    deallocShared(rc)

proc addMatch*(rc: ResultCollector, m: MatchResult): bool =
  if rc.limitReached.load():
    return false
  acquire(rc.lock)
  if rc.limit > 0 and rc.matches.len >= rc.limit:
    rc.limitReached.store(true)
    release(rc.lock)
    return false
  rc.matches.add(m)
  release(rc.lock)
  return true

proc addMatches*(rc: ResultCollector, ms: openArray[MatchResult]): int =
  if rc.limitReached.load() or ms.len == 0:
    return 0
  acquire(rc.lock)
  result = 0
  for m in ms:
    if rc.limit > 0 and rc.matches.len >= rc.limit:
      rc.limitReached.store(true)
      break
    rc.matches.add(m)
    inc result
  release(rc.lock)

proc isLimitReached*(rc: ResultCollector): bool {.inline.} =
  rc.limitReached.load()

proc getMatches*(rc: ResultCollector): seq[MatchResult] =
  acquire(rc.lock)
  result = rc.matches
  release(rc.lock)

proc matchCount*(rc: ResultCollector): int =
  acquire(rc.lock)
  result = rc.matches.len
  release(rc.lock)

proc newAtomicStats*(): AtomicStats =
  result = cast[AtomicStats](allocShared0(sizeof(AtomicStatsObj)))
  result.visited.store(0)
  result.visitedFiles.store(0)
  result.visitedDirs.store(0)
  result.visitedLinks.store(0)
  result.matched.store(0)
  result.errors.store(0)
  result.skipped.store(0)
  result.bytesRead.store(0)

proc destroy*(s: AtomicStats) =
  if s != nil:
    deallocShared(s)

proc incVisited*(s: AtomicStats) {.inline.} =
  discard s.visited.fetchAdd(1)

proc incVisitedFiles*(s: AtomicStats) {.inline.} =
  discard s.visitedFiles.fetchAdd(1)

proc incVisitedDirs*(s: AtomicStats) {.inline.} =
  discard s.visitedDirs.fetchAdd(1)

proc incVisitedLinks*(s: AtomicStats) {.inline.} =
  discard s.visitedLinks.fetchAdd(1)

proc incMatched*(s: AtomicStats) {.inline.} =
  discard s.matched.fetchAdd(1)

proc incErrors*(s: AtomicStats) {.inline.} =
  discard s.errors.fetchAdd(1)

proc incSkipped*(s: AtomicStats) {.inline.} =
  discard s.skipped.fetchAdd(1)

proc addBytesRead*(s: AtomicStats, bytes: int64) {.inline.} =
  discard s.bytesRead.fetchAdd(bytes)

proc matchedCount*(s: AtomicStats): int {.inline.} =
  s.matched.load()

proc toStats*(s: AtomicStats, startTime, endTime: times.Time): Stats =
  result.visited = s.visited.load()
  result.visitedFiles = s.visitedFiles.load()
  result.visitedDirs = s.visitedDirs.load()
  result.visitedLinks = s.visitedLinks.load()
  result.matched = s.matched.load()
  result.errors = s.errors.load()
  result.skipped = s.skipped.load()
  result.bytesRead = s.bytesRead.load()
  result.startTime = startTime
  result.endTime = endTime

proc initPathBuffer*(capacity: int = 512): PathBuffer =
  result.data = newString(capacity)
  result.len = 0

proc clear*(buf: var PathBuffer) {.inline.} =
  buf.len = 0

proc setPath*(buf: var PathBuffer, path: string) =
  if path.len > buf.data.len:
    buf.data = newString(path.len * 2)
  buf.len = path.len
  if path.len > 0:
    copyMem(addr buf.data[0], unsafeAddr path[0], path.len)

proc toString*(buf: PathBuffer): string {.inline.} =
  if buf.len == 0: return ""
  result = newString(buf.len)
  copyMem(addr result[0], unsafeAddr buf.data[0], buf.len)

proc computeRelPathFast*(fullPath, rootAbs: string): string =
  if fullPath.len <= rootAbs.len:
    return fullPath
  if not fullPath.startsWith(rootAbs):
    return fullPath
  var start = rootAbs.len
  if start < fullPath.len and fullPath[start] in {'/', '\\'}:
    inc start
  if start >= fullPath.len:
    return ""
  result = fullPath[start..^1]

proc computeRelPathInPlace*(fullPath, rootAbs: string, buf: var PathBuffer) =
  buf.clear()
  if fullPath.len <= rootAbs.len:
    buf.setPath(fullPath)
    return
  if not fullPath.startsWith(rootAbs):
    buf.setPath(fullPath)
    return
  var start = rootAbs.len
  if start < fullPath.len and fullPath[start] in {'/', '\\'}:
    inc start
  let relLen = fullPath.len - start
  if relLen <= 0:
    buf.len = 0
    return
  if relLen > buf.data.len:
    buf.data = newString(relLen * 2)
  buf.len = relLen
  copyMem(addr buf.data[0], unsafeAddr fullPath[start], relLen)
