# fastfind.nimble — Nim utility: fast file finder
# Install (dev): nimble build -d:release
# Run: ./bin/fastfind <pattern> [paths...]

version       = "0.1.0"
author        = "RobertFlexx"
description   = "fastfind; a fast, feature-rich file finder (single binary)."
license       = "MIT"
srcDir        = "src"
bin           = @["fastfind"]

# Dependencies are stdlib-only (no Nimble deps).
