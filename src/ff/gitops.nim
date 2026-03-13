import std/[os, strutils, osproc, sets, tables]
import core, cli

type
  GitStatus* = enum
    gsTracked
    gsModified
    gsUntracked
    gsIgnored

  GitCache* = object
    root*: string
    modified*: HashSet[string]
    untracked*: HashSet[string]
    tracked*: HashSet[string]

var gitCacheTable = initTable[string, GitCache]()

proc quoteShellArg(s: string): string =
  if s.len == 0: return "''"
  result = "'"
  for c in s:
    if c == '\'':
      result.add("'\\''")
    else:
      result.add(c)
  result.add("'")

proc findGitRoot*(startPath: string): string =
  if startPath.len == 0:
    return ""
  var p: string
  try:
    p = absolutePath(startPath)
  except CatchableError:
    return ""
  if fileExists(p):
    p = p.parentDir
  while p.len > 0:
    let gitDir = p / ".git"
    if dirExists(gitDir) or fileExists(gitDir):
      return p
    let parent = p.parentDir
    if parent == p or parent.len == 0:
      break
    p = parent
  ""

proc isGitRepo*(path: string): bool =
  findGitRoot(path).len > 0

proc runGitCommand(root: string; args: openArray[string]; timeout: int = 5000): tuple[output: string, success: bool] =
  if root.len == 0:
    return ("", false)
  let quotedRoot = quoteShellArg(root)
  var cmd = "git -C " & quotedRoot
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShellArg(arg))
  try:
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    result = (output, code == 0)
  except CatchableError:
    result = ("", false)

proc parseGitStatusLine(line: string; root: string): tuple[path: string, status: set[GitStatus]] =
  if line.len < 3:
    return ("", {})
  let xy = if line.len >= 2: line[0..1] else: "  "
  var relPath = ""
  if line.len > 3:
    relPath = line[3..^1]
  let arrowPos = relPath.find(" -> ")
  if arrowPos >= 0:
    relPath = relPath[arrowPos + 4..^1]
  relPath = relPath.strip(chars = {'"', ' ', '\t'})
  if relPath.len == 0:
    return ("", {})
  let fullPath = root / relPath
  var status: set[GitStatus] = {}
  if xy[0] == '?' and xy[1] == '?':
    status.incl(gsUntracked)
  elif xy[0] == '!' and xy[1] == '!':
    status.incl(gsIgnored)
  else:
    if xy[0] in {'M', 'A', 'D', 'R', 'C', 'U'}:
      status.incl(gsModified)
      status.incl(gsTracked)
    if xy[1] in {'M', 'A', 'D', 'R', 'C', 'U'}:
      status.incl(gsModified)
      status.incl(gsTracked)
    if xy[0] == ' ' and xy[1] == ' ':
      status.incl(gsTracked)
  (fullPath, status)

proc getGitModified*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0:
    return
  let (output, success) = runGitCommand(root, ["status", "--porcelain", "-uno"])
  if not success:
    return
  for line in output.splitLines():
    if line.len < 3:
      continue
    let (path, status) = parseGitStatusLine(line, root)
    if path.len > 0 and gsModified in status:
      result.incl(path)

proc getGitUntracked*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0:
    return
  let (output, success) = runGitCommand(root, ["ls-files", "--others", "--exclude-standard"])
  if not success:
    return
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.incl(root / trimmed)

proc getGitTracked*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0:
    return
  let (output, success) = runGitCommand(root, ["ls-files", "--cached"])
  if not success:
    return
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.incl(root / trimmed)

proc getGitStaged*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0:
    return
  let (output, success) = runGitCommand(root, ["diff", "--cached", "--name-only"])
  if not success:
    return
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.incl(root / trimmed)

proc getGitChanged*(root: string): HashSet[string] =
  result = getGitModified(root) + getGitUntracked(root)

proc loadGitCache*(root: string): GitCache =
  if root.len == 0:
    return GitCache()
  if root in gitCacheTable:
    return gitCacheTable[root]
  result = GitCache(root: root)
  let (output, success) = runGitCommand(root, ["status", "--porcelain"])
  if success:
    for line in output.splitLines():
      if line.len < 3:
        continue
      let (path, status) = parseGitStatusLine(line, root)
      if path.len == 0:
        continue
      if gsModified in status:
        result.modified.incl(path)
      if gsUntracked in status:
        result.untracked.incl(path)
      if gsTracked in status:
        result.tracked.incl(path)
  let (trackedOutput, trackedSuccess) = runGitCommand(root, ["ls-files", "--cached"])
  if trackedSuccess:
    for line in trackedOutput.splitLines():
      let trimmed = line.strip()
      if trimmed.len > 0:
        result.tracked.incl(root / trimmed)
  gitCacheTable[root] = result

proc clearGitCache*() =
  gitCacheTable.clear()

proc applyGitFilters*(cfg: Config; matches: var seq[MatchResult]) =
  if not (cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged):
    return
  if matches.len == 0:
    return
  var rootsTable = initTable[string, GitCache]()
  var pathToRoot = initTable[string, string]()
  for m in matches:
    if m.absPath notin pathToRoot:
      let root = findGitRoot(m.absPath)
      pathToRoot[m.absPath] = root
      if root.len > 0 and root notin rootsTable:
        rootsTable[root] = loadGitCache(root)
  var filtered = newSeqOfCap[MatchResult](matches.len)
  for m in matches:
    let root = pathToRoot.getOrDefault(m.absPath, "")
    if root.len == 0:
      continue
    let cache = rootsTable.getOrDefault(root, GitCache())
    var keep = false
    if cfg.gitModified and m.absPath in cache.modified:
      keep = true
    if cfg.gitUntracked and m.absPath in cache.untracked:
      keep = true
    if cfg.gitTracked and m.absPath in cache.tracked:
      keep = true
    if cfg.gitChanged and (m.absPath in cache.modified or m.absPath in cache.untracked):
      keep = true
    if keep:
      filtered.add(m)
  matches = filtered

proc getFileGitStatus*(path: string): set[GitStatus] =
  result = {}
  let root = findGitRoot(path)
  if root.len == 0:
    return
  let cache = loadGitCache(root)
  let absPath = absolutePath(path)
  if absPath in cache.modified:
    result.incl(gsModified)
  if absPath in cache.untracked:
    result.incl(gsUntracked)
  if absPath in cache.tracked:
    result.incl(gsTracked)

proc isGitIgnored*(path: string): bool =
  let root = findGitRoot(path)
  if root.len == 0:
    return false
  let relPath = relativePath(path, root)
  let (output, success) = runGitCommand(root, ["check-ignore", "-q", relPath])
  success

proc getGitBranch*(root: string): string =
  if root.len == 0:
    return ""
  let (output, success) = runGitCommand(root, ["rev-parse", "--abbrev-ref", "HEAD"])
  if success:
    result = output.strip()
  else:
    result = ""

proc getGitRemoteUrl*(root: string): string =
  if root.len == 0:
    return ""
  let (output, success) = runGitCommand(root, ["remote", "get-url", "origin"])
  if success:
    result = output.strip()
  else:
    result = ""
