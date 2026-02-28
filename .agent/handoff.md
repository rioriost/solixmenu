# Handoff

## Current goal
Fixed release automation to target the app repo explicitly when creating/uploading GitHub releases.

## Decisions
Pass --repo "$APP_REPO" to gh release commands to avoid wrong remote context.

## Changes since last session
- scripts/release.sh: add --repo "$APP_REPO" to gh release view/upload/create.

## Verification status
repo_verify: OK (shellcheck not installed; no tests detected).

## Risks
None; explicit repo targeting avoids tap repo collisions.

## Next actions
Re-run make release; ensure APP_REPO points to rioriost/solixmenu.
