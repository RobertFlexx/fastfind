# src/ff/gitops.nim
import std/[os, strutils, osproc, sets]
import core, cli


proc findGitRoot*(startPath: string): string =
  var p = absolutePath(startPath)
  if fileExists(p): p = p.parentDir
  while true:
    if dirExists(p / ".git") or fileExists(p / ".git"):
      return p
    let parent = p.parentDir
    if parent == p: break
    p = parent
  ""

proc getGitModified*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0: return
  
  try:
    let (output, code) = execCmdEx("git -C " & root & " status --porcelain")
    if code != 0: return
    
    for line in output.splitLines():
      if line.len < 4: continue
      let status = line[0..1]
      let file = line[3..^1].strip()
      
      if status[0] == 'M' or status[1] == 'M':
        result.incl(root / file)
  except CatchableError:
    discard

proc getGitUntracked*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0: return
  
  try:
    let (output, code) = execCmdEx("git -C " & root & " ls-files --others --exclude-standard")
    if code != 0: return
    
    for line in output.splitLines():
      if line.len > 0:
        result.incl(root / line.strip())
  except CatchableError:
    discard

proc getGitTracked*(root: string): HashSet[string] =
  result = initHashSet[string]()
  if root.len == 0: return
  
  try:
    let (output, code) = execCmdEx("git -C " & root & " ls-files")
    if code != 0: return
    
    for line in output.splitLines():
      if line.len > 0:
        result.incl(root / line.strip())
  except CatchableError:
    discard

proc applyGitFilters*(cfg: Config; matches: var seq[MatchResult]) =
  if not (cfg.gitModified or cfg.gitUntracked or cfg.gitTracked or cfg.gitChanged):
    return
  
  var roots: HashSet[string]
  for m in matches:
    let root = findGitRoot(m.absPath)
    if root.len > 0:
      roots.incl(root)
  
  var modified, untracked, tracked: HashSet[string]
  
  for root in roots:
    if cfg.gitModified or cfg.gitChanged:
      modified = modified + getGitModified(root)
    if cfg.gitUntracked or cfg.gitChanged:
      untracked = untracked + getGitUntracked(root)
    if cfg.gitTracked:
      tracked = tracked + getGitTracked(root)
  
  var filtered: seq[MatchResult] = @[]
  for m in matches:
    var keep = false
    
    if cfg.gitModified and m.absPath in modified:
      keep = true
    if cfg.gitUntracked and m.absPath in untracked:
      keep = true
    if cfg.gitTracked and m.absPath in tracked:
      keep = true
    if cfg.gitChanged and (m.absPath in modified or m.absPath in untracked):
      keep = true
    
    if keep:
      filtered.add(m)
  
  matches = filtered
