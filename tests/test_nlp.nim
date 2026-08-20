import std/[unittest, options, os]
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
