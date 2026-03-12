# fastfind.nimble Nim utility: fast file finder (i replaced gnu find)

version       = "0.2.0"
author        = "RobertFlexx"
description   = "fastfind: a fast, feature-rich file finder with fuzzy search, interactive terminal UI, and git awareness."
license       = "MIT"

srcDir        = "src"
bin           = @["fastfind"]

homepage      = "https://github.com/RobertFlexx/fastfind"
bugtracker    = "https://github.com/RobertFlexx/fastfind/issues"

skipDirs      = @["tests"]

requires "nim >= 1.6.0"

when defined(release):
    switch("opt", "speed")
    switch("danger")

    task run, "Run fastfind":
        exec "nim c -r src/fastfind.nim"

        task dev, "Build debug version":
            exec "nim c -d:debug src/fastfind.nim"

            task release, "Build optimized binary":
                exec "nim c -d:release --opt:speed --out:bin/fastfind src/fastfind.nim"

                task check, "Compile test":
                    exec "nim c src/fastfind.nim"
