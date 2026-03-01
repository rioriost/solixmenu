# Handoff

## Current goal
Adjusted input power key selection to move photovoltaic power into AC input list so AC+DC sum avoids double-counting for A1761.

## Decisions
Treat photovoltaic power as part of AC input selection and remove it from DC input selection.

## Changes since last session
- Sources/App/SolixAppCoordinator.swift: add "photovoltaic_power" to AC input list; remove from DC input list.

## Verification status
repo_verify OK (xcodebuild debug build).

## Risks
Rebase may surface conflicts in homebrew-solixmenu that need manual resolution.

## Next actions
Validate input power readings for A1761/A1763 against app logs.
