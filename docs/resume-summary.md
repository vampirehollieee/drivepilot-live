# DrivePilot Live Resume Summary

## One-line Version

Built DrivePilot Live, a local-first LINE notification market-signal observation console for ride-driving operations, with parser, data pipeline, map output, health checks, and report UI.

## Three-line Version

DrivePilot Live converts Android-forwarded LINE work-group notifications into a local market observation dashboard.
It includes notification ingestion, parser/resolver scripts, coordinate review workflows, marker-health reporting, and a standalone Market Console.
The system is intentionally read-only toward LINE and is not an auto-order, dispatch, or revenue-prediction tool.

## Project Experience Version

Designed and implemented DrivePilot Live, a Windows local-first market observation system for ride-driving operations. Built a PowerShell/Python data pipeline that receives Android-forwarded LINE notifications, extracts market signals and address candidates, tracks unresolved coordinates, builds map marker outputs, generates health metrics, and produces a deterministic market report JSON. Created desktop, mobile, live map, and Market Console frontend pages using HTML/CSS/JavaScript and Leaflet. Added operator-friendly BAT entrypoints, cache-busting data refresh, marker health diagnostics, and sanitized documentation suitable for public review.

## Technical Bullet Version

- Built local HTTP notification receiver and Windows operator scripts with PowerShell and BAT.
- Implemented Python builders for 24-hour stats, missing-coordinate queue, marker output, marker health, and market report JSON.
- Designed a file-based local data pipeline using generated JSON/CSV artifacts for inspectability and recovery.
- Built standalone dashboard and Market Console pages with vanilla HTML/CSS/JavaScript and Leaflet.
- Added safety boundaries: no LINE operation, no auto-ordering, no dispatch scoring, no income prediction, and no public runtime data.
- Prepared public repository copy with private logs, raw messages, credentials, webhooks, address data, and runtime artifacts removed.
