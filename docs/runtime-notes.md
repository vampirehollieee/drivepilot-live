# Runtime Notes

DrivePilot Live is designed as a Windows local-first workflow.

## Runtime Requirements

- Python 3 with the standard library.
- Windows PowerShell.
- A local Windows environment for BAT and PowerShell entrypoints.
- Optional browser access for viewing the local dashboard pages.

## Python Dependencies

The public `live-system/*.py` scripts use Python standard library modules only, plus local project modules where applicable. No external Python package is required for the sanitized public copy, so this repository does not include a `requirements.txt`.

## PowerShell Workflow

PowerShell scripts provide the local receiver, server, status checks, health checks, and notification helpers. The full private runtime uses generated data under `live-data/`, which is intentionally excluded from this public repository.

## Privacy Boundary

This public repository is for architecture and portfolio review. It does not include private runtime records, LINE raw messages, API keys, webhook URLs, config secrets, address caches, or local logs.

