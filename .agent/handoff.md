# Handoff

## Current goal
Added a guard in release publishing to require the tag to exist on origin before creating GitHub releases; prints push guidance for main and the tag.

## Decisions
Fail fast when the release tag is missing on origin to avoid GitHub release errors.

## Changes since last session
- scripts/release.sh: check remote tag and show push commands before publish.

## Verification status
repo_verify OK (no checks configured).

## Risks
If the tag is lightweight/annotated mismatch on origin, release publish may still fail; push the exact tag.

## Next actions
Push `main` and the release tag (e.g., `git push origin main` and `git push origin v1.0.1`) before running `make release`.
