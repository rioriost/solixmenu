# Handoff

## Current goal
Updated release automation to upload README files and LICENSE to GitHub release assets.

## Decisions
Include README.md, README-jp.md, and LICENSE alongside the app zip during publish.

## Changes since last session
- scripts/release.sh: upload README.md, README-jp.md, LICENSE in release assets.

## Verification status
repo_verify: OK (shellcheck not installed; no tests detected).

## Risks
Missing files are skipped silently; ensure README-jp.md exists if needed.

## Next actions
Run make release to publish zip + docs + license to GitHub release.
