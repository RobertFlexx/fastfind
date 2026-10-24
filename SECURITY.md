# Security Policy

## Supported versions

`fastfind` is still early stage. Security fixes are applied to the latest release on `main`.

Older snapshots may not receive backports.

## Reporting a vulnerability

Please report suspected vulnerabilities privately.

Use one of the following:

* GitHub Security Advisories (preferred): private report in this repository
* Email the maintainer listed in repository metadata/profile, preferrably @RobertFlexx

Please include:

* A clear description of the issue
* Affected version/commit
* Reproduction steps or proof of concept
* Potential impact

You can also include a suggested patch.

## Response expectations

After receiving a report, maintainers will:

* Acknowledge receipt
* Validate and triage impact
* Prepare and publish a fix when confirmed
* Credit the reporter (if not otherwise requested)

## Scope notes

Likely security-relevant areas in this project:

* Command execution flags (`--exec`, `--exec-cmd`, argument handling)
* Path traversal and symlink behavior
* Interactive mode input handling
* Index file read/write handling

## 2.5.0 hardening and limits

Regression tests cover hostile shell filenames, exclusive index refreshes,
index traversal/overflow, terminal controls and paste, special-file previews,
invalid UTF-8 JSON, and shared allocator lifetime under concurrent traversal.
This is targeted hardening, not a certification that the program is free of
vulnerabilities.

The regex backend is Nim's PCRE1 binding. Upstream PCRE1 is
[end of life](https://www.pcre.org/original/doc/html/pcre.html); distribution
patches and the libraries bundled by release builds still matter. A PCRE2
migration remains separate work. Arbitrary regexes can be expensive, and large
uncapped content searches use memory maps; avoid concurrent truncation of those
files, or set `--max-bytes` to a bounded prefix of at most 16 MiB for regex scans.
Natural-language parsing is local and never authorizes file operations.

