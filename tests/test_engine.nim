import std/unittest
import ../src/ff/[matchers, tui_text, fuzzy_match]

suite "filename matching":
  test "long fuzzy matches never collide with the failure sentinel":
    check fuzzyMatch("select me.txt", "select me.txt") >= 0
    check fuzzyMatch("a_b_c_d_e_f_g_h", "a_b_c_d_e_f_g_h") >= 0
    check fuzzyMatch("missing", "file.txt") == -1
  test "regex can borrow a basename from a relative path":
    var m = Matcher(mode: mmRegex, pathMode: pmBaseName, patterns: @["^main\\.nim$"])
    m.compile()
    check m.anyMatch("", "src/main.nim")
    check not m.anyMatch("", "main.nim/other.txt")
  test "full regex alternation anchors both alternatives":
    var m = Matcher(mode: mmRegex, fullMatch: true, patterns: @["foo|bar"])
    m.compile()
    check m.anyMatch("foo", "foo")
    check m.anyMatch("bar", "bar")
    check not m.anyMatch("foobar", "foobar")
    check not m.anyMatch("bar\n", "bar\n")
  test "wildcards at the edges and repeated stars":
    for pattern in ["?oo", "fo?", "[af]oo", "**", "***"]:
      var m = Matcher(mode: mmGlob, patterns: @[pattern])
      m.compile()
      check m.anyMatch("foo", "foo")
  test "complex globs match newline bytes and the entire filename":
    var m = Matcher(mode: mmGlob, patterns: @["line?break.*"])
    m.compile()
    check m.anyMatch("line\nbreak.txt", "line\nbreak.txt")
    var strict = Matcher(mode: mmGlob, patterns: @["f?o"])
    strict.compile()
    check not strict.anyMatch("foo\n", "foo\n")

initTerminalText()
suite "terminal text":
  test "controls and invalid UTF-8 cannot become terminal commands":
    check safeText("a\x1b[2J\n\x9bb") == "a\\x1b[2J\\x0a?b"
    check safeText("a\u202eb") == "a?b"
  test "clipping uses cells and retains valid UTF-8":
    check textWidth("界a") == 3
    check textWidth("e\u0301") == 1
    check textWidth(fitText("界a", 8)) == 8
    for width in -2..15:
      check textWidth(clipText("日本語 / filename.txt", width)) <= max(0, width)
      check textWidth(clipText("日本語 / filename.txt", width, left = true)) <= max(0, width)
  test "backspace removes a complete codepoint":
    var value = "a界"
    eraseLastRune(value)
    check value == "a"
    eraseLastRune(value)
    eraseLastRune(value)
    check value == ""
