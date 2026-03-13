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

