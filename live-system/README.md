# live-system Runtime Scripts

This folder contains the local runtime and data-builder scripts used by
DrivePilot Live. The public repository keeps the source code for portfolio
review, but excludes private runtime data, API keys, webhooks, logs, and
generated `live-data/` files.

DrivePilot is an observation system. These scripts do not auto-accept jobs,
operate LINE, or make dispatch decisions.

## Main Scripts

### `line_notification_receiver.ps1`

Local PowerShell HTTP receiver for Android notification forwarding. It receives
POST payloads from the mobile forwarding workflow and writes local runtime
records in the private `live-data/` directory in the full project.

### `map_server.ps1`

Lightweight local HTTP server for static dashboard pages and small local API
endpoints such as report refresh. It serves `live-map/` assets and local
generated data in the private runtime workspace.

### `location_resolver.ps1`

Location helper used by the local pipeline to resolve or normalize
location-related records. It belongs to the controlled local data workflow and
is not a dashboard-side API dependency.

### `build_market_report.py`

Builds `market_report.json` from existing local artifacts such as 24-hour stats,
marker health, missing-coordinate queue summaries, and recent
notification-derived summaries. The report is deterministic and does not use AI.

### `signal_stats_24h.py`

Builds the 24-hour market signal summary, including raw, deduped, and duplicate
signal counts. It operates at the statistics layer without changing raw
notification records.

### `health_check.ps1`

Runs local service health checks for DrivePilot runtime components such as
receiver and map server availability.

### `discord_notifier.ps1`

Optional notification sender for selected system or market-summary events.
Public configuration uses blank webhook placeholders; real webhook URLs are
excluded from this repository.

### `map8_api_smoke_test.py`

Small MAP8 connectivity smoke-test script. The public version uses demo address
labels only and expects any real API key to remain outside the repository.

### `map8_geocode_review.py`

Creates a small review file for coordinate lookup candidates. It is designed for
controlled review and does not automatically import low-confidence results.

### `auto_map8_coordinate_import.py`

Imports high-confidence coordinate results into the local cache path under
strict rules in the full private workflow. The public copy keeps the source for
review but excludes data files and keys.

### `build_map_points.py`

Builds the formal map marker output from resolved local data. It separates
marker-ready data from raw parser output and writes marker health metadata in
the private runtime workspace.

### `build_missing_coordinate_queue.py`

Builds the missing-coordinate candidate queue from local data sources, applies
quality filters, deduplicates variants, and writes a queue summary in the
private runtime workspace.

## Public Repository Notes

- No real runtime `live-data/` files are included.
- No API keys, private configuration, webhooks, raw LINE messages, or address
  caches are included.
- Scripts are kept to demonstrate architecture and implementation approach, not
  to run as a production deployment from this public copy.
