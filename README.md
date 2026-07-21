# DrivePilot Live

DrivePilot Live is a local-first market-signal observation system for LINE ride-driving work-group notifications. It turns noisy mobile notification streams into structured views for market rhythm, group activity, location readiness, system health, and report snapshots.

This repository is the sanitized public portfolio version. It demonstrates product thinking, data-pipeline design, local automation, and frontend reporting while excluding private runtime data and credentials.

DrivePilot Live is not an auto-order tool. It does not operate LINE, accept jobs, make dispatch decisions, predict income, score drivers, or automate user actions.

## Overview

DrivePilot was built to help a driver understand market activity across multiple fast-moving LINE work groups without manually scanning every notification. The system receives forwarded Android notifications, parses market-relevant signals, organizes address and group activity data, and presents the result through desktop, mobile, live map, and Market Console views.

The implementation is intentionally local-first. Runtime artifacts are plain JSON / JSONL / CSV files so the operator can inspect the data chain, rebuild reports manually, and verify system health without relying on a hosted backend.

## Problem

LINE ride-driving work groups can be noisy and time-sensitive:

- Useful market signals are mixed with repeated posts and group chatter.
- Address extraction confidence can be mistaken for actual coordinate readiness.
- Map markers need an auditable source instead of trusting raw parser output.
- Mobile viewing needs to be lightweight and quick.
- The system needs visibility into parser output, marker health, queue status, data freshness, and report quality.
- Private messages, addresses, and credentials must stay local.

## Solution

DrivePilot converts notification streams into structured local data and dashboard views:

1. Android / MacroDroid forwards selected notifications to a local receiver.
2. The receiver writes notification records to the private local data layer.
3. Parser and resolver scripts extract signal metadata, address candidates, confidence hints, and location state.
4. Missing-coordinate and marker-builder workflows separate unresolved candidates from confirmed map marker output.
5. Market report builders summarize signal volume, group activity, marker health, and queue status.
6. Frontend views expose the results through Desktop Dashboard, Mobile Dashboard, Live Map, and Market Console.

## System Flow

```text
LINE Notification
-> Android / MacroDroid
-> Local Receiver
-> Parser / Resolver
-> Structured Local Data
-> Queue / Marker / Health / Report Builders
-> Dashboard / Mobile Dashboard / Live Map / Market Console
```

More detail: [docs/system-flow.md](docs/system-flow.md) and [docs/architecture.md](docs/architecture.md).

## Core Features

- Local HTTP notification receiver for Android notification forwarding.
- Parser / resolver pipeline for market signals, address-like text, source/group metadata, and confidence classification.
- Clear separation between parser confidence and coordinate readiness.
- Missing Coordinate Queue for unresolved address candidates.
- MAP8 review/import workflow with explicit cache and review boundaries.
- Marker Builder that produces formal map marker output from resolved data.
- Marker Health reporting for marker counts, invalid coordinates, missing addresses, and build timestamps.
- 24HR signal statistics with duplicate visibility.
- Market Report JSON builder for deterministic report snapshots.
- Desktop Dashboard, Mobile Dashboard, Live Map, and standalone Market Console.
- Windows-friendly BAT and PowerShell entrypoints for local operation.

## Technical Architecture

DrivePilot uses explicit local artifacts instead of hidden service state:

- `live-system/` contains receiver, server, parser-adjacent utilities, builders, health checks, MAP8 review tools, and routine wrappers.
- `live-map/` contains the static dashboard, mobile dashboard, live map, and Market Console pages.
- `demo-data/` contains sanitized sample outputs for portfolio review.
- Private runtime data is excluded from this public repository.

Runtime script notes: [live-system/README.md](live-system/README.md).

## Technology Used

- PowerShell for the local receiver, server workflow, status checks, and Windows automation.
- Python for statistics builders, coordinate queue generation, marker output, report generation, and support tools.
- BAT files for operator-friendly manual entrypoints.
- HTML, CSS, and vanilla JavaScript for dashboard and console interfaces.
- Leaflet / OpenStreetMap for map visualization.
- JSON, JSONL, and CSV as transparent local data artifacts.
- Git for the sanitized portfolio workflow.

## What This Project Demonstrates

- Turning messy real-world notification streams into a local operations console.
- Designing safety boundaries between observation, alerting, and automation.
- Building auditable data pipelines with intermediate artifacts.
- Separating parser confidence, coordinate resolution, marker readiness, and UI display states.
- Implementing lightweight dashboards without a large frontend framework.
- Designing recovery and health-check workflows for a local Windows system.
- Preparing a privacy-safe public version of a sensitive local project.

## Project Outcomes

- End-to-end local pipeline from mobile notifications to market dashboard views.
- Dedicated Market Console for deterministic report review.
- Formal marker-output pipeline with marker health metrics.
- Missing-coordinate queue and review workflows for controlled coordinate completion.
- 24HR statistics with raw, deduped, and duplicate signal visibility.
- Sanitized public repository suitable for portfolio review.

## Repository Structure

```text
live-system/       Runtime scripts and local builders
live-map/          Desktop dashboard, mobile dashboard, live map, Market Console
docs/              Architecture, privacy, runtime notes, resume summary, screenshots
demo-data/         Sanitized sample JSON / JSONL / CSV outputs
config/            Example-only configuration placeholders
*.bat              Windows entrypoints for the private local workflow
```

## Demo Data

The `demo-data/` folder contains fake examples only. It uses placeholder groups and locations such as `Group A`, `Group B`, `Demo Location`, `North Zone`, and `Central Zone`.

It does not contain real LINE messages, real group names, real addresses, phone numbers, coordinates, API keys, or webhook URLs.

## Safety and Privacy

This repository intentionally excludes:

- Real LINE raw messages.
- Real group names and notification text.
- Real addresses, phone numbers, and coordinates.
- API keys, tokens, passwords, and webhook URLs.
- `live-data/` runtime files.
- Private `notification_config.json` and `place_aliases.json`.
- Logs, databases, caches, build outputs, and local machine paths.

Privacy details: [docs/privacy-boundaries.md](docs/privacy-boundaries.md).

## Screenshots

### Desktop Dashboard

![Desktop Dashboard](docs/screenshots/dashboard-main.png)

### Mobile Dashboard

![Mobile Dashboard](docs/screenshots/mobile-dashboard.png)

### Market Report

![Market Report](docs/screenshots/market-report.png)

## Project Documentation

- [Project Case Study](docs/project-docs/drivepilot-project-case-study.pdf)`n  Public resume-oriented project summary covering product context, system architecture, implementation highlights, privacy handling, AI-assisted development workflow, and roadmap.
- [Architecture](docs/architecture.md)
- [System Flow](docs/system-flow.md)
- [Privacy Boundaries](docs/privacy-boundaries.md)
- [Runtime Notes](docs/runtime-notes.md)
- [Resume Summary](docs/resume-summary.md)
- [Roadmap](docs/roadmap.md)

## My Role

I designed and implemented the DrivePilot Live workflow end to end:

- Defined the local-first product scope and safety boundaries.
- Built the notification ingestion and local server workflow.
- Implemented parser/resolver support scripts and data builders.
- Designed the missing-coordinate, marker-builder, marker-health, and market-report pipeline.
- Built the desktop, mobile, live map, and Market Console frontend views.
- Added Windows-friendly operational scripts for manual refresh, status checks, and local routines.
- Sanitized the project into a public GitHub-ready portfolio version without exposing private runtime data.

## Project Status

This is a portfolio-safe public repository. It is suitable for code review and resume discussion, not for production deployment as-is. Real runtime data and credentials must remain outside Git.
