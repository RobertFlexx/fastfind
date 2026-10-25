import std/[strutils, unittest]
import ../src/ff/tui_input

suite "terminal input decoding":
  test "fragmented arrows remain control sequences":
    var decoder: InputDecoder
    check decoder.feed('\x1b').kind == "none"
    check decoder.timeoutMs() == 35
    check decoder.feed('[').kind == "none"
    check decoder.timeoutMs() >= 200
    check decoder.feed('B').kind == "down"
    check not decoder.readingControl()
    check decoder.feed('B').kind == "char"

  test "lone escape and truncated CSI are different":
    var decoder: InputDecoder
    discard decoder.feed('\x1b')
    check decoder.expire().kind == "escape"
    discard decoder.feed('\x1b')
    discard decoder.feed('[')
    check decoder.expire().kind == "unknown"
    check decoder.feed('?').ch == '?'

  test "unknown and oversized controls do not leak command bytes":
    var decoder: InputDecoder
    for ch in "\x1b[" & repeat('1', 100):
      check decoder.feed(ch).kind == "none"
    check decoder.feed('q').kind == "unknown"
    check not decoder.readingControl()

  test "bracketed paste survives input timeouts":
    var decoder: InputDecoder
    for ch in "\x1b[200~:rm\ry\rq":
      check decoder.feed(ch).kind == "none"
    check decoder.expire().kind == "none"
    check decoder.readingControl()
    for ch in "\x1b[201":
      check decoder.feed(ch).kind == "none"
    let paste = decoder.feed('~')
    check paste.kind == "paste"
    check paste.text == ":rm y q"
    check not decoder.readingControl()

  test "oversized paste is bounded and terminates":
    var decoder: InputDecoder
    for ch in "\x1b[200~" & repeat('x', 70000) & "\x1b[201":
      check decoder.feed(ch).kind == "none"
    let paste = decoder.feed('~')
    check paste.kind == "paste"
    check paste.text.len <= 65536
    check paste.text == repeat('x', paste.text.len)
