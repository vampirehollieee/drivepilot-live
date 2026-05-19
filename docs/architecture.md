# DrivePilot Live Architecture

DrivePilot Live is a local-first market-signal observation system. The runtime system is designed around a simple file-based pipeline so the operator can inspect each step without a cloud dependency.

## System Flow

```text
LINE work-group notification
-> MacroDroid captures Android notification
-> HTTP POST to local notification receiver
-> DrivePilot Parser / Resolver
-> live-data data layer
-> Dashboard / Mobile Dashboard / Market Console / Discord notification path
```

## Components

### 1. Notification Capture

MacroDroid watches Android notifications and forwards selected notification payloads to a local Windows machine. This keeps DrivePilot out of LINE automation: it reads notification events and does not control the LINE app.

### 2. Local Receiver

The local receiver accepts HTTP POST requests and writes records into the local data layer. Health checks are separated from the POST path so receiver status can be monitored safely.

### 3. Parser / Resolver

The parser extracts address-like text, source/group metadata, confidence hints, and signal categories. Parser confidence means text-extraction confidence; it does not mean a point has map coordinates.

### 4. Data Layer

The production runtime uses local generated files under `live-data/`. Those files are intentionally excluded from this public repository because they can contain private messages, addresses, logs, and operational state.

### 5. Coordinate and Marker Workflow

Missing-coordinate candidates are collected into a review queue. Reviewed or high-confidence coordinates are added to a local coordinate cache. The marker builder produces the formal map marker output and marker health metrics.

### 6. Frontend Views

- Desktop dashboard: broad operational overview.
- Mobile dashboard: compact driving-side observation view.
- Market Console: standalone report-style page that reads the market report JSON.
- Live map: marker visualization driven by generated marker output.

### 7. Reporting

Market Report Builder combines 24-hour statistics, marker health, missing-coordinate summary, and recent notification-derived summaries into a deterministic JSON report. The report is used for observation only, not dispatch advice.

## Public Repository Boundary

This sanitized copy keeps source code and documentation while excluding runtime data, logs, API keys, webhooks, private configuration, raw messages, address caches, and generated CSV/JSONL artifacts.
