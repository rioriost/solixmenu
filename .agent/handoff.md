# Handoff

## Current goal
Adjusted release script to pass tag commit as target when creating GitHub releases.

## Decisions
Use git rev-parse on the tag to avoid invalid target_commitish errors.

## Changes since last session
- scripts/release.sh: add --target $(git rev-parse "$TAG") when creating gh release.

## Verification status
repo_verify: OK (shellcheck not installed; no tests detected).

## Risks
None; GH release creation now specifies explicit target commit.

## Next actions
Re-run make release with APP_REPO=rioriost/solixmenu to create the GitHub release.
