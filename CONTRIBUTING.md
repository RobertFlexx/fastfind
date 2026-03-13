# Contributing to fastfind

Thanks for helping improve `fastfind` :)

## Before you start

* Read [`README.md`](README.md) for feature scope and CLI behavior.
* Search existing issues/PRs before opening a new one.
* If you plan a larger change, open an issue first to align on direction.

## Development setup

```bash
git clone https://github.com/RobertFlexx/fastfind
cd fastfind
nim c -d:release -threads:on -o:bin/fastfind src/ff.nim
./bin/fastfind --help
```

If `ff` is already installed globally, still test your local build (`./bin/fastfind`) before opening a PR.

## Branch and commit guidelines

* Create a topic branch from `main`.
* Keep commits focused and logical.
* Write clear commit messages describing the intent and user impact.
* Rebase/squash if your branch has noisy fixup commits.

## Pull request checklist

Before opening a PR, please verify:

* Code builds on your machine.
* CLI help/behavior matches docs.
* `README.md` is updated when user-visible behavior changes.
* New flags/options are documented.
* You did not include unrelated refactors (open more PR's for that, we don't mind!).

In your PR description, include:

* What changed
* Why it changed
* How you tested it
* Any known limitations

> If your PR is incredibly simple, this is unnecessary, feel free to ignore it and say something like "same as title"

## Documentation changes

Docs-only contributions are welcome.

When changing examples, prefer commands that users can run immediately without hidden assumptions.

## Performance changes

If a PR claims speed improvements, include benchmark details:

* Dataset shape and size
* Hardware/system info
* Exact commands used
* Before/after timings

## Reporting bugs

Open an issue and include:

* OS and version
* `ff --version` output
* Repro command
* Expected vs actual behavior
* Minimal sample tree if possible

## Security issues

Please do not open public issues for vulnerabilities.

Follow [`SECURITY.md`](SECURITY.md) for responsible disclosure.

