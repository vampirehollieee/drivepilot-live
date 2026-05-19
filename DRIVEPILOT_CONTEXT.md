# DrivePilot Live v1｜Project Context

## 1. Project Positioning

DrivePilot Live v1 is a semi-automatic command center for ride-driving operations.

It is designed to help the driver quickly understand LINE work group signals, locations, hotspots, dispatch rhythm, and system status.

It is not an auto-order tool.

## 2. Core Principle

DrivePilot only assists with reading, parsing, displaying, and alerting.

DrivePilot must not:

* Automatically accept orders
* Automatically operate LINE
* Bypass platform rules
* Simulate user actions
* Add OCR unless explicitly planned later
* Add Google Maps API unless explicitly planned later

## 3. Current Architecture

LINE work group notification
→ MacroDroid captures Android notification
→ HTTP POST to local port 8788
→ DrivePilot receives notification
→ Parser extracts address / landmark / hotspot / driver reply
→ Writes records to data files
→ Dashboard / mobile dashboard / live map read and display data
→ Discord sends important alerts

## 4. Main Services

* Port 8788: notification receiver
* Port 8790: dashboard / map server

## 5. Existing Core Files / Areas

Important project areas:

* live-system
* live-map
* live-data
* config
* dashboard.html
* mobile_dashboard.html
* index.html
* Start DrivePilot.bat
* Stop DrivePilot.bat
* Status DrivePilot.bat

Data / record files:

* notifications.jsonl
* parser_diagnostics.jsonl
* places.csv

## 6. Completed Features

Current completed or mostly completed features:

* 8788 notification receiver
* 8790 dashboard / map service
* Start / Stop / Status bat shortcuts
* MacroDroid LINE notification forwarding
* Windows Firewall rules for 8788 and 8790
* dashboard.html
* mobile_dashboard.html
* index.html live map
* Tailscale external mobile viewing
* Discord alerts for high-confidence locations, hotspots, and system status
* parser_diagnostics.jsonl raw notification diagnostics
* notifications.jsonl notification records
* places.csv location data
* Landmark alias parsing
* Driver reply exclusion rules
* Multiple address extraction from one notification
* confidence: high / medium / low
* kind classification: place / start / place_alias / description / driver_reply

## 7. UI Direction

DrivePilot UI should feel like a low-key dark command center.

Main colors:

* Black
* Dark gray
* Dark blue-black
* Gray-white text

Signal colors:

* Red: urgent / hotspot
* Green: high confidence / normal
* Yellow-orange: warning / medium confidence
* Blue: general information

Desktop dashboard direction:

* Fixed left sidebar
* Top bar
* Main map view in the center
* Recent notifications / recent parsed addresses
* Right-side panels for hotspot ranking, system status, event statistics, quick actions
* Dark floating card style for map popup

Mobile dashboard direction:

* For actual driving use
* Less information
* Larger text
* Faster judgment
* Fewer scroll areas
* Prioritize high-confidence places and hotspots

## 8. Current Version Status

Current project stage:

DrivePilot Live v1-beta

The core data flow works, but the system still needs:

* Stable backup
* Better coordinate accuracy
* Discord alert reliability check
* Health alert system
* Desktop UI simplification
* Mobile driving UI productization
* Push mode completion
* Parser rule refinement

Estimated overall progress:

68%

## 9. Development Rules for Codex

When modifying this project, always follow these rules:

1. Make the smallest possible change.
2. Do not refactor the whole project.
3. Do not mix UI, parser, Discord, and health-check changes in one task.
4. Do not modify unrelated files.
5. Do not add external APIs unless explicitly requested.
6. Do not add auto-order or LINE automation behavior.
7. Preserve the existing 8788 / 8790 architecture.
8. Preserve existing data formats unless explicitly requested.
9. For UI tasks, only modify HTML / CSS / frontend JS presentation.
10. For parser tasks, only modify parsing rules and related tests if available.
11. For Discord tasks, only modify alert logic and diagnostics.
12. Always report changed files, change summary, test method, and test result.

## 10. Current Priority

Recommended priority order:

1. Create v1 stable backup
2. Improve coordinate accuracy and places.csv
3. Fix / verify Discord alert reliability
4. Add system health alert
5. Simplify desktop dashboard UI
6. Productize mobile driving UI
7. Complete push modes
8. Add reports and cost tracking later

---
