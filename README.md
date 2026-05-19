# DrivePilot Live

DrivePilot Live is a LINE work-group notification market-signal observation system for ride-driving operations. It turns mobile notification streams into a local command-center view for market rhythm, group activity, location distribution, data health, and report snapshots.

DrivePilot is not an auto-order tool. It does not operate LINE, accept jobs, simulate user actions, or provide dispatch decisions. This public repository is a resume-friendly technical copy with private data removed.

## Core Features

- Local notification receiver for Android notification forwarding.
- Parser pipeline for extracting market signals, address-like text, group/source metadata, and signal confidence.
- Location data workflow with unresolved queue, manual review path, cache import path, and marker builder.
- Desktop dashboard, mobile dashboard, live map, and Market Console pages.
- 24-hour signal statistics, marker health, missing-coordinate summary, and market report JSON builder.
- Lightweight PowerShell/BAT operations for local Windows workflows.

## Technical Architecture

- Android notification capture: MacroDroid forwards selected LINE notification payloads to a local receiver.
- Local receiver: PowerShell-based HTTP receiver on the local machine.
- Data processing: Python and PowerShell scripts parse, normalize, classify, summarize, and build report files.
- Data layer: Local file-based artifacts are used by the dashboard. Private runtime data is excluded from this public copy.
- Frontend: Standalone HTML/CSS/JavaScript pages served by a lightweight local map server.
- Reporting: `market_report.json` is generated from existing local statistics and displayed by Market Console.

## Technology Used

- Python for builders, statistics, queue generation, marker output, and report generation.
- PowerShell for local receiver, status checks, server workflow, and Windows automation.
- HTML, CSS, and vanilla JavaScript for dashboard and Market Console interfaces.
- Leaflet for map visualization.
- Windows BAT files for operator-friendly local entrypoints.
- File-based JSON/CSV artifacts for a simple local-first data layer.

## Project Outcomes

- Built an end-to-end local observation pipeline from mobile notifications to market dashboard views.
- Separated parser confidence from marker/location readiness to reduce misleading UI interpretation.
- Added marker builder and marker health reporting to make map output auditable.
- Added missing-coordinate queue and review workflows for controlled coordinate completion.
- Added deterministic market-report generation and a standalone Market Console for quick review.
- Hardened local server and refresh endpoint behavior for a personal operations console.

## Safety and Privacy

This public copy intentionally excludes live operational data, raw notification logs, runtime logs, API keys, webhooks, private configuration, address caches, and generated CSV/JSONL data. It is intended to demonstrate architecture and implementation approach, not to run as a production deployment.

## Screenshots

Screenshots can be added under `docs/screenshots/`. No screenshots are included in this sanitized copy yet.

## My Role

I designed and implemented the local-first DrivePilot workflow: notification ingestion, parser/resolver data flow, marker-output pipeline, health reporting, Market Console, operator scripts, and documentation. I also defined safety boundaries so the system remains an observation tool rather than an automation or dispatch system.
