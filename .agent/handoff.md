# Handoff

## Current goal
Updated release publishing to retry Homebrew tap push: on push failure, pull --rebase and retry push.

## Decisions
Automate recovery from non-fast-forward push failures in homebrew-solixmenu.

## Changes since last session
- scripts/release.sh: retry tap push after pull --rebase.

## Verification status
repo_verify OK (no checks configured).

## Risks
Rebase may surface conflicts in homebrew-solixmenu that need manual resolution.

## Next actions
Re-run `make release`; if tap push still fails, resolve conflicts in homebrew-solixmenu and push.
