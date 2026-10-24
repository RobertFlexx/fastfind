import std/[unittest, options, os, times, re]
import ../src/ff/[nlp, core, matchers, semantic]

suite "natural-language query planner":
  test "intersects language and name clauses":
    let q = parseNaturalQuery("find Nim files named index limit 10")
    check q.extensions.contains(".nim")
    check q.patterns == @["*index*"]
    check q.types == {etFile}
    check q.limit == 10

  test "preserves quoted content and path case":
    let q = parseNaturalQuery("Python files containing \"TODO and FIXME\" under ./SourceDir")
    check q.containsText == "TODO and FIXME"
    check q.inDirectory == "./SourceDir"
    check q.extensions.contains(".py")

  test "parses combined size time exclusion and ordering":
    let q = parseNaturalQuery("images larger than 5 MB modified in last 2 weeks excluding thumbnails sort newest")
    check q.minSize == 5_000_000
    check q.newerThan.isSome
    check q.excludePatterns == @["thumbnails"]
    check q.sortKey == skTime
    check q.reverseSort

  test "supports compact expert clauses":
    let q = parseNaturalQuery("ext:rs name:parser exclude:target limit:25 depth:4")
    check q.extensions == @[".rs"]
    check q.patterns == @["*parser*"]
    check q.excludePatterns == @["target"]
    check q.limit == 25
    check q.maxDepth == 4

  test "supports symbolic sizes inclusive phrases and absolute dates":
    let symbolic = parseNaturalQuery("files >10MB")
    check symbolic.minSize == 10_000_001
    let inclusive = parseNaturalQuery("files at least 10 MiB")
    check inclusive.minSize == 10 * 1024 * 1024
    let dated = parseNaturalQuery("files modified after 2026-01-01")
    check dated.newerThan.isSome

  test "does not steal an ordinary multiword filename":
    check not isNaturalLanguageQuery("quarterly report final")
    check isNaturalLanguageQuery("find recent PDF files")

  test "specific formats do not expand to every document":
    check parseNaturalQuery("PDF files").extensions == @[".pdf"]
    check parseNaturalQuery("zip files").extensions == @[".zip"]
    check parseNaturalQuery("make files").extensions.contains("Makefile")
    check not isNaturalLanguageQuery("profiles final")

  test "written quantities ranges and ranking":
    let ranked = parseNaturalQuery("show me the ten largest PDF files")
    check ranked.limit == 10
    check ranked.sortKey == skSize
    check ranked.reverseSort
    check ranked.extensions == @[".pdf"]
    let ranged = parseNaturalQuery("files between one and five megabytes")
    check ranged.minSize == 1_000_000
    check ranged.maxSize == 5_000_000
    let newest = parseNaturalQuery("newest five files")
    check newest.newerThan.isNone
    check newest.sortKey == skTime
    check newest.limit == 5
    check parseNaturalQuery("files limit nonsense").warnings.len > 0

  test "calendar windows are disjoint and deterministic":
    let now = dateTime(2026, mOct, 24, 14, zone = local()).toTime
    let yesterday = parseNaturalQuery("files modified yesterday", now)
    let today = parseNaturalQuery("files changed today", now)
    let before = dateTime(2026, mOct, 23, 12, zone = local()).toTime
    check yesterday.newerThan.get < before
    check yesterday.olderThan.get > before
    check yesterday.olderThan.get <= today.newerThan.get + initDuration(nanoseconds = 1)
    let previous = parseNaturalQuery("files from last month", now)
    check previous.newerThan.get.local.month == mAug # one ns before September
    check previous.olderThan.get.local.month == mOct
    let recent = parseNaturalQuery("files edited in the past three weeks", now)
    check (now - recent.newerThan.get).inDays == 21
    let untouched = parseNaturalQuery("files not modified in the last two days", now)
    check untouched.olderThan.get == now - initDuration(days = 2)

  test "names phrases alternatives and exact matching":
    check parseNaturalQuery("files whose name contains config").patterns == @["*config*"]
    check parseNaturalQuery("files with annual report in their name").patterns == @["*annual report*"]
    check parseNaturalQuery("python files named main or config").patterns == @["*main*", "*config*"]
    let exact = parseNaturalQuery("files exactly named config.toml")
    check exact.fullMatch
    check exact.patterns == @["config.toml"]
    check parseNaturalQuery("python invoice files").patterns == @["*invoice*"]

  test "content Boolean operations contractions and regex escapes":
    let both = parseNaturalQuery("files containing TODO and FIXME")
    check "FIXME then TODO".contains(re(both.containsRegex))
    check not "TODO only".contains(re(both.containsRegex))
    let either = parseNaturalQuery("files containing TODO or FIXME")
    check "FIXME only".contains(re(either.containsRegex))
    let negative = parseNaturalQuery("files that don't contain 'secret key'")
    check negative.notContainsText == @["secret key"]
    check parseNaturalQuery("files containing regex '\\d+'").containsRegex == "\\d+"
    check parseNaturalQuery("files containing 'the and or phrase'").containsText == "the and or phrase"

  test "questions paths and exclusions compose":
    let q = parseNaturalQuery("how many python files under './Source Dir' excluding rust and vendor")
    check q.countOnly
    check q.inDirectory == "./Source Dir"
    check q.excludePatterns.contains("*.rs")
    check q.excludePatterns.contains("vendor")
    check parseNaturalQuery("files in my downloads").inDirectory == getHomeDir() / "Downloads"
    check parseNaturalQuery("files written in python").extensions.contains(".py")
    check parseNaturalQuery("untracked git files").gitUntracked

  test "query corpus composes independent constraints":
    for action in ["find", "show me", "please locate", "list all"]:
      for language in ["python", "rust", "nim", "javascript", "go"]:
        for size in ["at least 10 MB", "over 10 MB", ">=10MB"]:
          let q = parseNaturalQuery(action & " " & language & " files " & size &
            " modified in the past two days excluding vendor named config")
          check q.extensions.len > 0
          check q.minSize == 10_000_000
          check q.newerThan.isSome
          check q.excludePatterns == @["vendor"]
          check q.patterns == @["*config*"]

suite "gitignore matcher":
  test "ordered negation and directory rules":
    var gi: Gitignore
    gi.compileGitignore(@["build/*", "!build/keep.txt", "*.tmp", "literal\\!name"])
    check gi.isGitIgnored("build/output.o")
    check not gi.isGitIgnored("build/keep.txt")
    check gi.isGitIgnored("nested/cache.tmp")
    check gi.isGitIgnored("literal!name")

  test "cannot reinclude beneath an excluded parent directory":
    var gi: Gitignore
    gi.compileGitignore(@["vendor/", "!vendor/keep.txt"])
    check gi.isGitIgnored("vendor/keep.txt")

  test "double star crosses directories but single star does not":
    var gi: Gitignore
    gi.compileGitignore(@["logs/*.txt", "cache/**/generated.bin"])
    check gi.isGitIgnored("logs/a.txt")
    check not gi.isGitIgnored("logs/deep/a.txt")
    check gi.isGitIgnored("cache/generated.bin")
    check gi.isGitIgnored("cache/a/b/generated.bin")

suite "semantic symbol search":
  test "any-symbol mode includes structs enums constants and types":
    let root = getTempDir() / "fastfind-semantic-test"
    createDir(root)
    let source = root / "sample.rs"
    writeFile(source, "pub struct Parser { value: i32 }\n" &
      "pub enum Mode { Fast, Safe }\n" &
      "pub const LIMIT: usize = 10;\n" &
      "pub fn parse_input() {}\n")
    defer:
      if fileExists(source): removeFile(source)
      if dirExists(root): removeDir(root)
    check searchFileForSymbols(source, "Parser", symAny).len == 1
    check searchFileForSymbols(source, "Mode", symAny).len == 1
    check searchFileForSymbols(source, "LIMIT", symAny).len == 1
    let functions = searchFileForSymbols(source, "parse", symFunction)
    check functions.len == 1
    check functions[0].column > 0
