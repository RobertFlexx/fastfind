# src/ff/semantic.nim
import std/[os, strutils, re, options, sets]
import matchers


type
  Language* = enum
    langUnknown, langNim, langPython, langC, langCpp, langRust,
    langJavaScript, langTypeScript, langGo, langJava

  SymbolType* = enum
    symFunction, symClass, symStruct, symEnum, symInterface,
    symMethod, symVariable, symConstant, symType, symAny

  SymbolMatch* = object
    file*: string
    line*: int
    column*: int
    symbolName*: string
    symbolType*: SymbolType
    context*: string  # the actual line content

  LanguagePatterns = object
    functions*: seq[Regex]
    classes*: seq[Regex]
    structs*: seq[Regex]
    enums*: seq[Regex]
    interfaces*: seq[Regex]
    methods*: seq[Regex]
    variables*: seq[Regex]
    constants*: seq[Regex]
    types*: seq[Regex]

# language detection by extension
proc detectLanguage*(path: string): Language =
  let ext = path.splitFile().ext.toLowerAscii()
  case ext
  of ".nim", ".nims", ".nimble": langNim
  of ".py", ".pyw", ".pyi": langPython
  of ".c", ".h": langC
  of ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".c++", ".h++": langCpp
  of ".rs": langRust
  of ".js", ".mjs", ".cjs": langJavaScript
  of ".ts", ".mts", ".cts": langTypeScript
  of ".go": langGo
  of ".java": langJava
  else: langUnknown

# compile patterns for each language
proc getNimPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*proc\s+(\w+)\s*[\[\(]",
    re"^\s*func\s+(\w+)\s*[\[\(]",
    re"^\s*method\s+(\w+)\s*[\[\(]",
    re"^\s*iterator\s+(\w+)\s*[\[\(]",
    re"^\s*template\s+(\w+)\s*[\[\(]",
    re"^\s*macro\s+(\w+)\s*[\[\(]",
    re"^\s*converter\s+(\w+)\s*[\[\(]"
  ]
  result.classes = @[
    re"^\s*type\s+(\w+)\s*\*?\s*=\s*(?:ref\s+)?object",
    re"^\s*(\w+)\s*\*?\s*=\s*(?:ref\s+)?object"
  ]
  result.enums = @[
    re"^\s*type\s+(\w+)\s*\*?\s*=\s*enum",
    re"^\s*(\w+)\s*\*?\s*=\s*enum"
  ]
  result.types = @[
    re"^\s*type\s+(\w+)\s*\*?\s*="
  ]
  result.constants = @[
    re"^\s*const\s+(\w+)\s*\*?\s*="
  ]
  result.variables = @[
    re"^\s*(?:var|let)\s+(\w+)\s*\*?\s*[:=]"
  ]

proc getPythonPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*def\s+(\w+)\s*\(",
    re"^\s*async\s+def\s+(\w+)\s*\("
  ]
  result.classes = @[
    re"^\s*class\s+(\w+)\s*[\(:]"
  ]
  result.methods = @[
    re"^\s+def\s+(\w+)\s*\(self",
    re"^\s+async\s+def\s+(\w+)\s*\(self"
  ]
  result.variables = @[
    re"^(\w+)\s*:\s*\w+\s*=",
    re"^(\w+)\s*=\s*[^=]"
  ]

proc getCPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*(?:static\s+)?(?:inline\s+)?(?:extern\s+)?(?:const\s+)?(?:\w+[\s\*]+)+(\w+)\s*\([^;]*\)\s*\{",
    re"^\s*(?:static\s+)?(?:inline\s+)?(?:extern\s+)?(?:const\s+)?(?:\w+[\s\*]+)+(\w+)\s*\([^;]*\)\s*$"
  ]
  result.structs = @[
    re"^\s*(?:typedef\s+)?struct\s+(\w+)\s*\{",
    re"^\s*struct\s+(\w+)\s*;"
  ]
  result.enums = @[
    re"^\s*(?:typedef\s+)?enum\s+(\w+)\s*\{",
    re"^\s*enum\s+(\w+)\s*;"
  ]
  result.types = @[
    re"^\s*typedef\s+.*\s+(\w+)\s*;"
  ]
  result.constants = @[
    re"^\s*#define\s+(\w+)\s+"
  ]

proc getCppPatterns(): LanguagePatterns =
  result = getCPatterns()
  # add c++ specific patterns
  result.classes.add(re"^\s*class\s+(\w+)\s*(?:final\s*)?[\{:]")
  result.classes.add(re"^\s*class\s+(\w+)\s*;")
  result.structs.add(re"^\s*struct\s+(\w+)\s*(?:final\s*)?[\{:]")
  result.methods = @[
    re"^\s*(?:virtual\s+)?(?:static\s+)?(?:inline\s+)?(?:const\s+)?(?:\w+[\s\*\&]+)+(\w+)\s*\([^;]*\)\s*(?:const\s*)?(?:override\s*)?(?:final\s*)?\{"
  ]
  result.interfaces = @[
    re"^\s*class\s+(\w+)\s*(?::\s*public)?"  # pure virtual classes often indicate interfaces
  ]

proc getRustPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)\s*[<\(]",
    re"^\s*(?:pub\s+)?(?:const\s+)?fn\s+(\w+)\s*[<\(]"
  ]
  result.structs = @[
    re"^\s*(?:pub\s+)?struct\s+(\w+)\s*[<\{;\(]"
  ]
  result.enums = @[
    re"^\s*(?:pub\s+)?enum\s+(\w+)\s*[<\{]"
  ]
  result.interfaces = @[
    re"^\s*(?:pub\s+)?trait\s+(\w+)\s*[<\{:]"
  ]
  result.types = @[
    re"^\s*(?:pub\s+)?type\s+(\w+)\s*[<=]"
  ]
  result.constants = @[
    re"^\s*(?:pub\s+)?const\s+(\w+)\s*:"
  ]
  result.variables = @[
    re"^\s*(?:pub\s+)?static\s+(?:mut\s+)?(\w+)\s*:"
  ]
  result.methods = @[
    re"^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)\s*\(\s*&?(?:mut\s+)?self"
  ]

proc getJavaScriptPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(",
    re"^\s*(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>",
    re"^\s*(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?function\s*\("
  ]
  result.classes = @[
    re"^\s*(?:export\s+)?class\s+(\w+)\s*(?:extends\s+\w+\s*)?[\{]"
  ]
  result.methods = @[
    re"^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{",
    re"^\s+(?:static\s+)?(?:async\s+)?(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>"
  ]
  result.constants = @[
    re"^\s*(?:export\s+)?const\s+(\w+)\s*="
  ]
  result.variables = @[
    re"^\s*(?:export\s+)?(?:let|var)\s+(\w+)\s*="
  ]

proc getTypeScriptPatterns(): LanguagePatterns =
  result = getJavaScriptPatterns()
  # add typescript specific patterns
  result.interfaces = @[
    re"^\s*(?:export\s+)?interface\s+(\w+)\s*[<\{]"
  ]
  result.types.add(re"^\s*(?:export\s+)?type\s+(\w+)\s*[<=]")
  result.enums = @[
    re"^\s*(?:export\s+)?(?:const\s+)?enum\s+(\w+)\s*\{"
  ]

proc getGoPatterns(): LanguagePatterns =
  result.functions = @[
    re"^func\s+(\w+)\s*\(",
    re"^func\s+\([^)]+\)\s*(\w+)\s*\("  # methods
  ]
  result.structs = @[
    re"^type\s+(\w+)\s+struct\s*\{"
  ]
  result.interfaces = @[
    re"^type\s+(\w+)\s+interface\s*\{"
  ]
  result.types = @[
    re"^type\s+(\w+)\s+\w+"
  ]
  result.constants = @[
    re"^\s*const\s+(\w+)\s*="
  ]
  result.variables = @[
    re"^\s*var\s+(\w+)\s+"
  ]

proc getJavaPatterns(): LanguagePatterns =
  result.functions = @[
    re"^\s*(?:public|private|protected)?\s*(?:static\s+)?(?:final\s+)?(?:synchronized\s+)?(?:\w+(?:<[^>]+>)?\s+)+(\w+)\s*\([^)]*\)\s*(?:throws\s+[\w,\s]+)?\s*\{"
  ]
  result.classes = @[
    re"^\s*(?:public\s+)?(?:abstract\s+)?(?:final\s+)?class\s+(\w+)\s*(?:<[^>]+>)?\s*(?:extends\s+\w+)?\s*(?:implements\s+[\w,\s]+)?\s*\{"
  ]
  result.interfaces = @[
    re"^\s*(?:public\s+)?interface\s+(\w+)\s*(?:<[^>]+>)?\s*(?:extends\s+[\w,\s<>]+)?\s*\{"
  ]
  result.enums = @[
    re"^\s*(?:public\s+)?enum\s+(\w+)\s*(?:implements\s+[\w,\s]+)?\s*\{"
  ]
  result.constants = @[
    re"^\s*(?:public|private|protected)?\s*static\s+final\s+\w+\s+(\w+)\s*="
  ]

proc buildPatterns(lang: Language): LanguagePatterns =
  case lang
  of langNim: getNimPatterns()
  of langPython: getPythonPatterns()
  of langC: getCPatterns()
  of langCpp: getCppPatterns()
  of langRust: getRustPatterns()
  of langJavaScript: getJavaScriptPatterns()
  of langTypeScript: getTypeScriptPatterns()
  of langGo: getGoPatterns()
  of langJava: getJavaPatterns()
  of langUnknown: LanguagePatterns()

var
  PatternCache: array[Language, LanguagePatterns]
  PatternsReady: array[Language, bool]

proc getPatterns(lang: Language): LanguagePatterns =
  ## Build a language's regexes the first time they're needed, then reuse them.
  ## Plain filename searches never pay that startup cost.
  if not PatternsReady[lang]:
    PatternCache[lang] = buildPatterns(lang)
    PatternsReady[lang] = true
  PatternCache[lang]

proc matchesName(pattern: string; name: string; ignoreCase: bool): bool =
  if pattern.len == 0: return true
  let p = if ignoreCase: pattern.toLowerAscii() else: pattern
  let n = if ignoreCase: name.toLowerAscii() else: name
  
  # support wildcards
  if '*' in p or '?' in p:
    # simple glob matching
    var pi = 0
    var ni = 0
    while pi < p.len and ni < n.len:
      if p[pi] == '*':
        if pi + 1 >= p.len: return true
        while ni < n.len:
          if matchesName(p[pi+1..^1], n[ni..^1], false): return true
          inc ni
        return false
      elif p[pi] == '?' or p[pi] == n[ni]:
        inc pi
        inc ni
      else:
        return false
    while pi < p.len and p[pi] == '*': inc pi
    return pi >= p.len and ni >= n.len
  else: discard

proc extractSymbolName(line: string; rx: Regex): Option[string] =
  var matches: array[1, string]
  if line.match(rx, matches):
    if matches[0].len > 0:
      return some(matches[0])
  return none(string)

proc searchFileForSymbols*(path: string; symbolName: string; 
                           symbolType: SymbolType; 
                           ignoreCase: bool = true;
                           maxResults: int = 100): seq[SymbolMatch] =
  result = @[]
  let lang = detectLanguage(path)
  if lang == langUnknown: return
  
  let patterns = getPatterns(lang)
  var f: File
  if not open(f, path, fmRead): return
  defer: close(f)
  
  var patternsToCheck: seq[tuple[rx: Regex, st: SymbolType]] = @[]
  template addPatterns(field: untyped; kind: SymbolType) =
    for rx in field: patternsToCheck.add((rx, kind))
  case symbolType
  of symFunction: addPatterns(patterns.functions, symFunction)
  of symClass: addPatterns(patterns.classes, symClass)
  of symStruct: addPatterns(patterns.structs, symStruct)
  of symEnum: addPatterns(patterns.enums, symEnum)
  of symInterface: addPatterns(patterns.interfaces, symInterface)
  of symMethod: addPatterns(patterns.methods, symMethod)
  of symVariable: addPatterns(patterns.variables, symVariable)
  of symConstant: addPatterns(patterns.constants, symConstant)
  of symType: addPatterns(patterns.types, symType)
  of symAny:
    addPatterns(patterns.functions, symFunction)
    addPatterns(patterns.classes, symClass)
    addPatterns(patterns.structs, symStruct)
    addPatterns(patterns.enums, symEnum)
    addPatterns(patterns.interfaces, symInterface)
    addPatterns(patterns.methods, symMethod)
    addPatterns(patterns.variables, symVariable)
    addPatterns(patterns.constants, symConstant)
    addPatterns(patterns.types, symType)

  if patternsToCheck.len == 0: return
  let searchName = if ignoreCase: symbolName.toLowerAscii() else: symbolName
  
  var lineNum = 0
  for line in f.lines:
    if result.len >= maxResults: break
    inc lineNum
    var seen = initHashSet[tuple[kind: SymbolType, name: string]]()
    for (rx, st) in patternsToCheck:
      let nameOpt = extractSymbolName(line, rx)
      if nameOpt.isSome:
        let name = nameOpt.get
        let matchName = if ignoreCase: name.toLowerAscii() else: name
        let key = (kind: st, name: name)
        if key notin seen and (matchName.contains(searchName) or searchName == "*"):
          seen.incl(key)
          result.add(SymbolMatch(file: path, line: lineNum,
                                  column: max(0, line.find(name)) + 1,
                                  symbolName: name, symbolType: st, context: line.strip()))
          if result.len >= maxResults: break

proc searchDirectoryForSymbols*(rootPath: string; symbolName: string;
                                symbolType: SymbolType;
                                ignoreCase: bool = true;
                                maxResults: int = 100;
                                includeHidden: bool = false;
                                excludes: seq[string] = @[]): seq[SymbolMatch] =
  result = @[]
  if maxResults <= 0: return
  let root = absolutePath(rootPath)
  var excluder = Excluder(patterns: excludes)
  excluder.compile()
  var stack = @[root]
  while stack.len > 0 and result.len < maxResults:
    let directory = stack.pop()
    try:
      for kind, path in walkDir(directory):
        let name = extractFilename(path)
        let rel = relativePath(path, root)
        if not includeHidden and name.len > 0 and name[0] == '.': continue
        if excludes.len > 0 and excluder.isExcluded(rel): continue
        if kind == pcDir:
          stack.add(path)
        elif kind == pcFile and detectLanguage(path) != langUnknown:
          let matches = searchFileForSymbols(path, symbolName, symbolType,
            ignoreCase, maxResults - result.len)
          result.add(matches)
          if result.len >= maxResults: break
    except OSError:
      continue
