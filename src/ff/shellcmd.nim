## Paths are shell arguments, never text interpolated into executable code.
import std/osproc
when not defined(posix): import std/[strutils, os]

proc shellPathScript*(command: string): string =
  var quote = '\0'
  var escaped = false
  var i = 0
  while i < command.len:
    let ch = command[i]
    if not escaped and i + 1 < command.len and ch == '{' and command[i + 1] == '}':
      case quote
      of '\'': result.add("'\"$1\"'")
      of '"': result.add("$1")
      else: result.add("\"$1\"")
      i += 2
      continue
    result.add(ch)
    if escaped:
      escaped = false
    elif ch == '\\' and quote != '\'':
      escaped = true
    elif ch == quote:
      quote = '\0'
    elif quote == '\0' and ch in {'\'', '"'}:
      quote = ch
    inc i

proc runShellForPath*(command, path: string): int =
  when defined(posix):
    try:
      let process = startProcess("sh", args = @["-c", shellPathScript(command), "fastfind", path],
        options = {poUsePath, poParentStreams})
      try: result = process.waitForExit()
      finally: process.close()
    except CatchableError:
      result = 127
  else:
    # Windows argv quoting is not cmd.exe shell escaping. Fail closed for
    # shell metacharacters; structured --exec-cmd arguments handle these paths.
    if path.find({'&', '|', '<', '>', '^', '%', '!', '"', '(', ')', '\r', '\n'}) >= 0:
      stderr.writeLine("fastfind: this Windows path requires --exec-cmd arguments without --shell")
      return 2
    let script = command.replace("\"{}\"", "{}").replace("'{}'", "{}")
    execShellCmd(script.replace("{}", "\"" & path & "\""))
