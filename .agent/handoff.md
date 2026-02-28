# Handoff

## Current goal
Added a remote-tag guard to release publishing so GitHub release creation fails fast when the tag is not on origin.

## Decisions
Require the tag to exist on origin before publishing; prompt to push main and the tag.

## Changes since last session
- scripts/release.sh: verify remote tag existence and print push instructions.

## Verification status
repo_verify OK (no checks configured).

## Risks
If the remote tag is missing or mismatched (lightweight vs annotated), publish will still fail until tags are aligned.

## Next actions
Push `main` and the release tag before running `make release`, then retry GitHub release publish.
