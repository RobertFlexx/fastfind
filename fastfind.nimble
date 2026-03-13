# fastfind.nimble - Nim utility: fast file finder

version       = "1.0.0"
author        = "RobertFlexx"
description   = "fastfind: a fast, feature-rich file finder with fuzzy search, interactive terminal UI, and git awareness."
license       = "MIT"

srcDir        = "src"
bin           = @["fastfind"]
skipDirs      = @["tests", "nimcache", "bin"]

requires "nim >= 1.6.0"

task run, "Build and run fastfind":
  exec "nim c -r -d:debug -o:bin/fastfind src/ff.nim"

task dev, "Build debug binary":
  exec "nim c -d:debug -o:bin/fastfind src/ff.nim"

task release, "Build optimized release binary":
  exec "nim c -d:release --opt:speed -o:bin/fastfind src/ff.nim"

task release_fast, "Build high-optimization release binary":
  exec "nim c -d:release -d:danger --opt:speed --passC:-flto --passL:-flto -o:bin/fastfind src/ff.nim"

task release_threaded, "Build release binary with threading":
  exec "nim c -d:release --opt:speed --threads:on -o:bin/fastfind src/ff.nim"

task release_full, "Build fully optimized threaded release binary":
  exec "nim c -d:release -d:danger --opt:speed --threads:on --passC:-flto --passL:-flto -o:bin/fastfind src/ff.nim"

task check, "Compile check":
  exec "nim c src/ff.nim"

task clean, "Remove build artifacts":
  exec "rm -rf bin/fastfind nimcache"

task install, "Build release binary and install to /usr/local/bin/ff":
  exec "nim c -d:release --opt:speed -o:bin/fastfind src/ff.nim"
  exec "sudo cp bin/fastfind /usr/local/bin/ff"
