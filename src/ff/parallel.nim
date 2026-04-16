# src/ff/parallel.nim

import std/[locks, atomics, strutils]
import std/times as times
import core

type
  DirEntry* = object
    path*: string
    relPath*: string
    depth*: int

  WorkQueue* = ptr WorkQueueObj
  WorkQueueObj = object
    items*: seq[DirEntry]
    lock: Lock
    pendingCount: Atomic[int]
    shutdown: Atomic[bool]

  ResultCollector* = ptr ResultCollectorObj
  ResultCollectorObj = object
    matches*: seq[MatchResult]
    lock: Lock
    limit*: int
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
  result.pendingCount.store(0)
  result.shutdown.store(false)

proc destroy*(q: WorkQueue) =
  if q != nil:
    deinitLock(q.lock)
    deallocShared(q)

proc push*(q: WorkQueue, entry: DirEntry) =
  discard q.pendingCount.fetchAdd(1)
  acquire(q.lock)
  q.items.add(entry)
  release(q.lock)

proc pushBatch*(q: WorkQueue, entries: openArray[DirEntry]) =
  if entries.len == 0: return
  discard q.pendingCount.fetchAdd(entries.len)
  acquire(q.lock)
  q.items.add(entries)
  release(q.lock)

proc tryPopBatch*(q: WorkQueue; maxCount: int): seq[DirEntry] =
  result = @[]
  acquire(q.lock)
  let remaining = q.items.len
  if remaining == 0:
    release(q.lock)
    return
  let count = min(maxCount, remaining)
  let startIdx = remaining - count
  result.setLen(count)
  var i = 0
  while i < count:
    result[i] = q.items[startIdx + (count - 1 - i)]
    inc i
  q.items.setLen(startIdx)
  release(q.lock)

proc isEmpty*(q: WorkQueue): bool =
  acquire(q.lock)
  result = q.items.len == 0
  release(q.lock)

proc len*(q: WorkQueue): int =
  acquire(q.lock)
  result = q.items.len
  release(q.lock)

proc signalShutdown*(q: WorkQueue) =
  q.shutdown.store(true)

proc isShutdown*(q: WorkQueue): bool =
  q.shutdown.load()

proc decPending*(q: WorkQueue) =
  discard q.pendingCount.fetchSub(1)

proc isComplete*(q: WorkQueue): bool =
  # pendingCount tracks queued + in-flight directory work.
  q.pendingCount.load() == 0

proc pendingCount*(q: WorkQueue): int =
  q.pendingCount.load()

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

proc isLimitReached*(rc: ResultCollector): bool =
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

proc incVisited*(s: AtomicStats) = discard s.visited.fetchAdd(1)
proc incVisitedFiles*(s: AtomicStats) = discard s.visitedFiles.fetchAdd(1)
proc incVisitedDirs*(s: AtomicStats) = discard s.visitedDirs.fetchAdd(1)
proc incVisitedLinks*(s: AtomicStats) = discard s.visitedLinks.fetchAdd(1)
proc incMatched*(s: AtomicStats) = discard s.matched.fetchAdd(1)
proc incErrors*(s: AtomicStats) = discard s.errors.fetchAdd(1)
proc incSkipped*(s: AtomicStats) = discard s.skipped.fetchAdd(1)
proc addBytesRead*(s: AtomicStats, bytes: int64) = discard s.bytesRead.fetchAdd(bytes)
proc matchedCount*(s: AtomicStats): int = s.matched.load()

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

proc clear*(buf: var PathBuffer) = buf.len = 0

proc setPath*(buf: var PathBuffer, path: string) =
  let pathLen = path.len
  if pathLen > buf.data.len:
    buf.data = newString(pathLen * 2)
  buf.len = pathLen
  if pathLen > 0:
    copyMem(addr buf.data[0], unsafeAddr path[0], pathLen)

proc toString*(buf: PathBuffer): string =
  if buf.len == 0: return ""
  result = newString(buf.len)
  copyMem(addr result[0], unsafeAddr buf.data[0], buf.len)

proc computeRelPathFast*(fullPath, rootAbs: string): string =
  let fullLen = fullPath.len
  let rootLen = rootAbs.len
  if fullLen <= rootLen:
    return fullPath
  if not fullPath.startsWith(rootAbs):
    return fullPath
  var start = rootLen
  if start < fullLen and fullPath[start] in {'/', '\\'}:
    inc start
  if start >= fullLen:
    return ""
  result = fullPath[start..^1]

proc computeRelPathInPlace*(fullPath, rootAbs: string, buf: var PathBuffer) =
  buf.clear()
  let fullLen = fullPath.len
  let rootLen = rootAbs.len
  if fullLen <= rootLen:
    buf.setPath(fullPath)
    return
  if fullPath.startsWith(rootAbs):
    var start = rootLen
    if start < fullLen and fullPath[start] in {'/', '\\'}:
      inc start
    let relLen = fullLen - start
    if relLen > 0:
      if relLen > buf.data.len:
        buf.data = newString(relLen * 2)
      buf.len = relLen
      moveMem(addr buf.data[0], unsafeAddr fullPath[start], relLen)
      return
  buf.setPath(fullPath)
