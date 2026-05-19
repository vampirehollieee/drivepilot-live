# DrivePilot Live v1｜Changelog

This file records Codex changes and verification results.

Keep entries short and useful.

---

## 2026-05-07 - DrivePilot Live v1.4.2 Market Report Builder field completion MVP

### Task

Fill Market Report Builder fields used by the standalone Market Console without changing existing dashboard pages or backend data flows.

### Changed Files

* live-system/build_market_report.py
* live-data/market_report.json
* live-data/market_report.backup_20260507_020247.json
* live-data/market_report.backup_20260507_020255.json

### Summary

Updated build_market_report.py to preserve the existing report fields and add market_60m, hot_zones/top_zones, active_groups/top_groups/group_activity, high_value_signals/recent_high_value_signals/recent_signals, summary.last_signal_time, summary.report_note, and lightweight diagnostics. The builder reads notifications.jsonl read-only for 60-minute counts, 24-hour fallback ranking, and recent deterministic high-value signal summaries, while continuing to read existing 24HR stats, marker health, map_points, queue summary, and missing coordinate queue counts. Existing market_report.json is backed up before overwrite.

### Test Method

Ran python -B -m py_compile live-system/build_market_report.py, ran the script directly, ran Build Market Report.bat, parsed market_report.json with Python and Node JSON parsers, checked new field lengths, fetched market_report.json over localhost:8790, and searched build_market_report.py for forbidden market_windows/time-bucket strings.

### Test Result

Pass. Build Market Report.bat produced live-data/market_report.json and created live-data/market_report.backup_20260507_020255.json. The report includes market_60m signal_count=326, located_count=276, hot_event_count=0, personal_alert_count=2, last_signal_time=2026-05-07 02:02:53, hot_zones count=3, active_groups count=3, high_value_signals count=5, skipped_invalid_rows=0, duplicate_ratio=0.3205, output_markers=202, and final_queue_count=7369. JSON parsing passed in Python and Node, and localhost data fetch returned HTTP 200.

### Risk / Follow-up

No market_console.html, dashboard.html, mobile_dashboard.html, index.html, parser, notifications.jsonl format/write path, MAP8, Auto MAP8 routine, Missing Coordinate Queue builder, Marker Builder, build_map_points.py, signal_stats_24h.py dedupe logic, API, map, search/filter, OpenAI/AI analysis, auto-order, driver score, revenue prediction, dispatch advice, LINE operation, or Discord push change was made. Top zone/group names inherit whatever encoding quality exists in the current source data.

---

## 2026-05-06 - DrivePilot Live v1.3.1 Market Report JSON MVP

### Task

Build a deterministic market report JSON from existing 24HR market stats, marker health, and missing coordinate queue summary.

### Changed Files

* live-system/build_market_report.py
* Build Market Report.bat
* live-data/market_report.json
* live-data/market_report.backup_20260506_232614.json

### Summary

Added build_market_report.py to read signal_stats_24h.json, marker_health.json, missing_coordinate_queue_summary.json, map_points.csv, and missing_coordinate_queue.csv, then write live-data/market_report.json. The report includes generated_at, report_version, source status, 24HR raw/deduped/duplicate counts, duplicate_ratio, marker health, queue summary, deterministic market_signal_level, data_health_note, and operator_note. Existing market_report.json is backed up before overwrite. Added Build Market Report.bat as the manual entrypoint.

### Test Method

Ran python -B -m py_compile live-system/build_market_report.py, ran the script directly, ran Build Market Report.bat, inspected market_report.json fields, verified duplicate_ratio equals duplicate_count divided by raw_count, verified deterministic market_signal_level, checked backup creation, and searched for market_windows / time-bucket strings and OpenAI/API analysis references.

### Test Result

Pass. Build Market Report.bat produced live-data/market_report.json and created live-data/market_report.backup_20260506_232614.json. Report generated_at=2026-05-06 23:26:14, status overall=ok, raw_count=234, deduped_count=159, duplicate_count=75, duplicate_ratio=0.3205, output_markers=202, final_queue_count=7369, market_signal_level=normal, data_health_note=資料來源正常, and operator_note=目前市場訊號正常. No forbidden market_windows or time-bucket strings were found.

### Risk / Follow-up

No parser, notifications.jsonl format, MAP8, Auto MAP8 routine, Missing Coordinate Queue builder, Marker Builder, build_map_points.py, signal_stats_24h.py dedupe logic, dashboard UI, mobile UI, map popup, OpenAI API, AI analysis, search feature, Analyze Now, auto-order, driver score, revenue prediction, dispatch advice, LINE operation, or Discord push change was made.

---

## 2026-05-06 - DrivePilot Live v1.3.0k Auto MAP8 small batch routine

### Task

Wrap the existing Auto MAP8 Coordinate Import flow in a small polling routine for safe daily use.

### Changed Files

* live-system/auto_map8_routine.py
* Start Auto MAP8 Routine.bat
* live-data/auto_map8_routine.jsonl
* live-data/map_points.csv
* live-data/map_points.backup_20260506_035700.csv
* live-data/marker_health.json

### Summary

Added auto_map8_routine.py as a wrapper around the existing auto_map8_coordinate_import.py flow. The routine defaults to interval_seconds=300 and limit=5, clamps routine limit to a maximum of 5, runs immediately on startup, logs one JSONL summary per round, runs build_map_points.py after each round, and can be stopped with Ctrl+C or by closing the BAT window. Added Start Auto MAP8 Routine.bat as the manual entrypoint and pass-through for optional arguments such as --interval-seconds and --limit. Added a simple lock file guard to avoid starting multiple routine instances.

### Test Method

Ran python -B -m py_compile live-system/auto_map8_routine.py, then ran Start Auto MAP8 Routine.bat with --interval-seconds 10 --limit 2 --max-runs 1. Inspected live-data/auto_map8_routine.jsonl, marker_health.json, lock cleanup, and searched the new routine files for receiver / notifications / dashboard coupling strings.

### Test Result

Pass. Test run started immediately with interval_seconds=10 and limit=2, ran one round, and exited through the test guard. The routine log row contains run_at=2026-05-06T03:56:52, limit=2, selected_count=2, auto_imported_count=0, review_only_count=2, bad_auto_import_count=0, error_count=0, auto_returncode=0, and build_map_points_returncode=0. marker_health updated to generated_at=2026-05-06 03:57:00 with output_markers=202 and backup_created=map_points.backup_20260506_035700.csv. The lock file was removed after exit.

### Risk / Follow-up

No parser, notifications.jsonl format, dashboard UI, MAP8 address rule, MAP8 auto-import threshold, Auto MAP8 default batch size, Marker Builder dedupe, build_map_points.py strategy, Missing Coordinate Queue builder, 24HR dedupe, signal_stats_24h.py, receiver integration, notification-triggered MAP8 lookup, time-window market feature, LINE/Discord rule, auto-order, driver score, revenue prediction, or dispatch advice change was made. Routine limit is intentionally capped at 5 even if a larger value is passed.

---

## 2026-05-06 - DrivePilot Live v1.3.0j Post-fix Data Refresh and Auto MAP8 Resume

### Task

Run post-fix data refresh and validation after the Auto MAP8 marker-time repair.

### Changed Files

* CHANGELOG_DRIVEPILOT.md
* live-data/signal_stats_24h.json
* live-data/address_geocode_cache.backup_20260506_032606.csv
* live-data/map8_geocode_review.csv
* live-data/map8_geocode_review.backup_20260506_032606.csv
* live-data/map_points.csv
* live-data/map_points.backup_20260506_032606.csv
* live-data/map_points.backup_20260506_032813.csv
* live-data/marker_health.json

### Summary

Ran Refresh Market Data.bat, Auto MAP8 Coordinate Import.bat with its default 30-row batch, and Build Map Points.bat. The 24HR JSON was refreshed to the current run time. The Auto MAP8 batch selected 30 candidates but produced no high-confidence imports in this run, so no new cache rows or map_resolved_points.csv auto_map8 rows were added. Build Map Points rebuilt the formal marker output from the existing resolved points. No program logic was changed.

### Test Method

Checked signal_stats_24h.json generated_at, source_file_mtime, raw_count, deduped_count, duplicate_count, and duplicate_count formula. Checked Auto MAP8 console counts, cache/review row counts, bad auto-import validation, map_points.csv coordinate validity, marker_health.json, local dashboard HTTP responses, and computed marker counts for 60 minutes, 3 hours, 24 hours, and all markers from map_points.csv.

### Test Result

Partial pass. Refresh Market Data.bat passed with generated_at=2026-05-06 03:26:00, source_file_mtime=2026-05-06 03:26:00, raw_count=234, deduped_count=159, duplicate_count=75, and formula 234 - 159 = 75. Auto MAP8 completed with selected_count=30, map8_ok_count=0, auto_imported_count=0, review_only_count=30, skipped_cached_count=87, skipped_dirty_count=4, cache_before_count=97, cache_after_count=97, map_points_before_count=202, and map_points_after_count=202. bad_auto_import_count=0. Build Map Points passed with input_rows=2782, output_markers=202, skipped_invalid_coordinates=0, skipped_missing_address=0, duplicate_merged=2580, and marker_health generated_at=2026-05-06 03:28:13. Computed marker time-filter counts were 60m=3, 3h=7, 24h=47, all=202, missing_time=0. Dashboard HTTP checks passed for dashboard.html, data/map_points.csv, and data/marker_health.json, but in-app browser automation timed out before visual Ctrl+F5 verification.

### Risk / Follow-up

Auto MAP8 did not add new coordinates in this run because the 30 selected rows were review-only. Browser visual validation still needs a manual Ctrl+F5 check. No parser, notifications.jsonl, dashboard UI, MAP8 import rule, batch size, Marker Builder dedupe, Missing Coordinate Queue builder, 24HR dedupe, LINE/Discord rule, auto-order, driver score, revenue prediction, or dispatch advice change was made.

---

## 2026-05-06 - DrivePilot Live v1.3.0i Auto MAP8 Preserve Signal Time Fix

### Task

Preserve original signal time when Auto MAP8 imports high-confidence coordinates, and repair existing auto-imported marker rows that were stamped with import time.

### Changed Files

* live-system/auto_map8_coordinate_import.py
* Repair Auto MAP8 Marker Time.bat
* live-data/map_resolved_points.csv
* live-data/map_resolved_points.backup_20260506_031325.csv
* live-data/map_points.csv
* live-data/map_points.backup_20260506_031325.csv
* live-data/marker_health.json

### Summary

Updated auto_map8_coordinate_import.py so selected candidates carry the full missing_coordinate_queue.csv row instead of address only. New resolved rows now use queue last_seen, falling back to queue time, and preserve queue source_detail, kind, sample_text, and text_summary context. Added --repair-auto-map8-time plus Repair Auto MAP8 Marker Time.bat to repair existing auto_map8 rows by matching address back to missing_coordinate_queue.csv, backing up map_resolved_points.csv, and rebuilding map_points.csv through the existing Marker Builder. The repair does not call MAP8, add cache rows, delete rows, or change dashboard code.

### Test Method

Ran python -B -m py_compile live-system/auto_map8_coordinate_import.py, ran Repair Auto MAP8 Marker Time.bat, inspected repaired address_geocode_cache marker rows in map_resolved_points.csv, checked backup creation, checked map_points.csv and marker_health.json row counts, and searched for old 2026-05-06 02:4x import-time marker rows.

### Test Result

Pass. Repair matched 87 auto_map8 rows, repaired 87, missing_queue_count=0, created map_resolved_points.backup_20260506_031325.csv, and ran Build Map Points successfully. Marker Builder reported input_rows=2781, output_markers=202, duplicate_merged=2579, backup_created=map_points.backup_20260506_031325.csv. map_points.csv has 202 rows, marker_health.json output_markers=202, and old import-time marker rows matching 2026-05-06 02:4x are now 0.

### Risk / Follow-up

No new MAP8 query, cache import, parser change, notifications.jsonl format change, dashboard change, build_map_points.py dedupe change, missing_coordinate_queue builder change, or source-data deletion was made.

---

## 2026-05-06 - DrivePilot Live v1.3.0h Map Marker Time Filter Sync

### Task

Synchronize map marker visibility with the dashboard time filter so the map, event counts, and parsed-address counts use the same time range.

### Changed Files

* live-map/index.html
* live-map/dashboard.html
* live-map/mobile_dashboard.html

### Summary

Updated the embedded map to filter map_points.csv markers by the selected time window instead of falling back to all markers when the current window has no rows. The map now supports recent 60 minutes, recent 3 hours, recent 24 hours, and all markers, using time first and last_seen / updated_at as fallbacks. Missing-time markers appear only in all mode. Dashboard system health now shows total CSV rows, valid coordinate rows, current time filter, filtered marker count, rendered marker count, and last load time. Fit Markers continues to fit only currently rendered markers. Mobile mini map uses the same selected time-window filtering and no longer falls back to all marker rows for a non-all time window.

### Test Method

Parsed inline scripts in live-map/index.html, live-map/dashboard.html, and live-map/mobile_dashboard.html with Node, searched for the old fallback-to-all marker logic, and computed current marker counts from live-data/map_points.csv for 60 minutes, 3 hours, 24 hours, and all markers.

### Test Result

Pass. Inline script parsing succeeded. Current map_points.csv counts by the same time-field rules are 60m=88, 180m=92, 1440m=131, all=201, missing_time=0. The old window-empty fallback logic was removed from desktop and mobile map rendering. Browser automation could not complete because the in-app browser CDP session timed out before page inspection, so visual confirmation should be done manually with Ctrl+F5.

### Risk / Follow-up

No parser change, notifications.jsonl format change, MAP8 change, address_geocode_cache.csv change, build_map_points.py change, map_points.csv generation change, Marker Builder dedupe change, UI redesign, or map color change was made.

---

## 2026-05-06 - DrivePilot Live v1.3.0g Auto Coordinate Import for High-confidence Address

### Task

Add a small automatic MAP8 coordinate import path for high-confidence Taiwan street-address candidates from the Missing Coordinate Queue.

### Changed Files

* live-system/auto_map8_coordinate_import.py
* Auto MAP8 Coordinate Import.bat
* live-data/address_geocode_cache.csv
* live-data/map8_geocode_review.csv
* live-data/map_resolved_points.csv
* live-data/map_points.csv
* live-data/marker_health.json

### Summary

Added auto_map8_coordinate_import.py to read missing_coordinate_queue.csv, skip already cached or already-imported review addresses, select clean address candidates with a default limit of 30 and a hard maximum of 50, query MAP8, auto-import only high-confidence Kaohsiung address results into address_geocode_cache.csv, keep low-confidence results in map8_geocode_review.csv with should_import=false, append imported coordinates to map_resolved_points.csv so the existing Marker Builder can materialize them without changing build_map_points.py, and automatically run build_map_points.py. Added Auto MAP8 Coordinate Import.bat as the manual entrypoint.

### Test Method

Ran python -B -m py_compile for auto_map8_coordinate_import.py and build_map_points.py, dry-checked candidate selection from missing_coordinate_queue.csv, ran Auto MAP8 Coordinate Import.bat through cmd input, inspected cache/review/map_resolved/map_points counts, checked backups, and searched imported auto_map8 rows for missing house numbers, dirty tokens, non-Kaohsiung formatted addresses, and coordinates outside the Kaohsiung range.

### Test Result

Pass. The final BAT run used source_file=live-data\missing_coordinate_queue.csv, selected_count=30, map8_ok_count=30, auto_imported_count=29, review_only_count=1, skipped_cached_count=58, skipped_dirty_count=2, cache_before_count=68, cache_after_count=97, map_points_before_count=172, map_points_after_count=201, and build_map_points_status=0. Backups were created for address_geocode_cache.csv, map8_geocode_review.csv, and map_points.csv. Across validation runs, auto_map8 cache rows reached 87 and marker output rose from 57 to 201. The final review file has 1 row with should_import=false. bad_auto_import_count=0 for house-number, dirty-token, Kaohsiung, and coordinate-range checks.

### Risk / Follow-up

No parser change, notifications.jsonl format change, dashboard change, build_map_points.py logic change, Missing Coordinate Queue builder change, 24HR change, search feature, personal reminder feature, low-confidence auto-import, or source-data deletion was made. The script appends high-confidence imported points to map_resolved_points.csv because build_map_points.py intentionally reads map_resolved_points.csv only.

---

## 2026-05-01 - DrivePilot Live v1.3.0e Map Marker Visibility Recovery MVP

### Task

Recover the frontend marker visibility chain for dashboard and mobile dashboard while keeping map_points.csv as the formal marker source.

### Changed Files

* live-map/index.html
* live-map/dashboard.html
* live-map/mobile_dashboard.html

### Summary

Updated the map frontend to cache-bust map_points.csv, report a minimal map_points debug status, parse lat/lng as numbers, keep one marker per valid map_points row, show address, time or last_seen, source, and count in marker popups, and provide Fit Markers / fitBounds behavior. Dashboard now receives map debug status from the embedded map iframe and shows read status, CSV row count, valid coordinate count, rendered marker count, and last load time. Mobile dashboard keeps reading map_points.csv and falls back to all valid marker rows when the current 60-minute window has no marker rows.

### Test Method

Parsed inline scripts in live-map/index.html, live-map/dashboard.html, and live-map/mobile_dashboard.html with Node, inspected map_points.csv row and coordinate validity, searched for forbidden time-window feature strings, and verified dashboard and mobile dashboard in the in-app browser at localhost:8790.

### Test Result

Pass. map_points.csv has 51 rows and 51 valid coordinate rows. Dashboard debug showed map_points read success, CSV rows=51, valid coordinates=51, rendered markers=51, and a current last load time. The dashboard map visually displayed markers, Fit Markers/fallback fitBounds moved the map to the marker area, and clicking a marker opened a popup with address, time, source, count, parser confidence, and located status. Mobile dashboard displayed 51 located marker rows in the mini map, showed Marker last update and Marker count, and clicking a marker showed address, time, source, and count.

### Risk / Follow-up

No parser change, notifications.jsonl format change, MAP8 lookup, Missing Coordinate Queue change, build_missing_coordinate_queue.py change, Marker Builder change, build_map_points.py change, map_points.csv generation change, 24HR change, time-window market feature, LINE/Discord rule change, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0d Missing Coordinate Queue quality cleanup MVP

### Task

Clean the Missing Coordinate Queue candidate quality so manual coordinate review has fewer noisy rows.

### Changed Files

* live-system/build_missing_coordinate_queue.py
* live-data/missing_coordinate_queue.csv
* live-data/missing_coordinate_queue.backup_20260501_185115.csv
* live-data/missing_coordinate_queue_summary.json

### Summary

Updated build_missing_coordinate_queue.py to classify candidates as good, suspicious, or rejected. The main queue now keeps only good and suspicious rows and records quality plus quality_reason. The builder filters obvious non-address strings, URL and mention fragments, money-transfer text, weak address-like strings without numbers, and very long low-quality candidates. It also merges address variants with a compact key that removes whitespace, punctuation, Kaohsiung city prefix, and 3-digit postal prefixes, while keeping the more complete address, summing count, using the newest last_seen, merging source names, and retaining a short cleaned sample_text. A new missing_coordinate_queue_summary.json records candidate and quality totals.

### Test Method

Ran python -B -m py_compile live-system/build_missing_coordinate_queue.py, ran Build Missing Coordinate Queue.bat through cmd input, inspected the output CSV fields, inspected missing_coordinate_queue_summary.json, checked backup creation, searched the queue for URL, mention, and transfer-related terms, checked long address counts, and spot-checked common city/non-city address variants.

### Test Result

Pass. Bat run stats: previous_queue_count=7779, total_candidates=55203, good_count=50883, suspicious_count=1133, rejected_count=3187, final_queue_count=7369, dedupe_merged_count=44647, backup_created=missing_coordinate_queue.backup_20260501_185115.csv. Final queue quality breakdown: good=7141, suspicious=228, rejected=0. Required fields address, count, last_seen, source, sample_text, reason, quality, and quality_reason are present. Search counts in the final queue: line.me=0, http=0, at-mark=0, transfer-related terms=0 except yuan=10, with yuan occurring as address text such as street names. sample_text over 120 chars=0. The Kaohsiung city and non-city variants for water-source-road 165 and Ruixi-street 148 appear as single merged rows.

### Risk / Follow-up

No MAP8 lookup, address_geocode_cache import, parser change, notifications.jsonl format change, map_points.csv change, Marker Builder change, build_map_points.py change, 24HR dedupe change, signal_stats_24h.py change, dashboard change, LINE/Discord rule change, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.1b 24HR short-interval dedupe MVP

### Task

Add short-interval dedupe at the 24HR statistics layer only, without changing the raw notification log.

### Changed Files

* live-system/signal_stats_24h.py
* live-data/signal_stats_24h.json
* live-map/dashboard.html
* live-map/mobile_dashboard.html

### Summary

Updated signal_stats_24h.py to build a deduped row set inside the statistics layer. The dedupe key uses source, group, group_name, source_name, then unknown for the group side, and address, normalized_address, resolved_address, or normalized raw text for the signal side. Repeated rows with the same key inside 3 minutes are counted as duplicates. The JSON now exposes raw_count, deduped_count, and duplicate_count at the root and inside current_24h / previous_24h, while keeping generated_at and source_file_mtime. Hot area ranking, active group ranking, locatable count, hotzone events, personal alerts, and unique group count now use the deduped row set. Dashboard and mobile dashboard relabel the current 24HR count as 原始訊號 and continue showing 去重後訊號 and 重複訊號.

### Test Method

Ran python -B -m py_compile live-system/signal_stats_24h.py, ran python live-system/signal_stats_24h.py, ran Refresh Market Data.bat through cmd input, inspected live-data/signal_stats_24h.json, checked duplicate_count formula, searched for forbidden time-bucket feature strings, parsed dashboard/mobile inline scripts with Node, and verified dashboard/mobile 24HR display in the in-app browser at localhost:8790.

### Test Result

Pass. Bat run generated_at=2026-05-01 18:30:40, source_file_mtime=2026-05-01 18:30:39, raw_count=792, deduped_count=628, duplicate_count=164, and duplicate_count equals raw_count minus deduped_count. The output has no forbidden time-bucket feature field or labels. Browser verification showed dashboard and mobile_dashboard displaying 原始訊號=792, 去重後訊號=628, 重複訊號=164, and 24HR 最後更新=2026-05-01 18:30:40.

### Risk / Follow-up

No notifications.jsonl format change, parser change, MAP8 lookup, Marker Builder change, map_points.csv generation change, mojibake fix, LINE/Discord rule change, UI redesign, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0c-hotfix Marker Builder address dedupe

### Task

Fix only the Marker Builder dedupe strategy so the formal marker output keeps the latest row per address.

### Changed Files

* live-system/build_map_points.py
* live-data/map_points.csv
* live-data/map_points.backup_20260501_181514.csv
* live-data/map_points.backup_20260501_181517.csv
* live-data/marker_health.json

### Summary

Updated build_map_points.py to dedupe by normalized_address, resolved_address, or compacted address only. Coordinate fallback is no longer used as a marker key. When multiple rows share the same address key, the builder keeps the newest time / last_seen row and carries lat, lng, source, confidence, kind, note, sample_text, and related text fields from that newest row. The count field is retained as the number of source rows collapsed under the same address key. marker_health.json still reports duplicate_merged, now meaning older same-address rows discarded.

### Test Method

Ran python -B -m py_compile live-system/build_map_points.py, ran python live-system/build_map_points.py, ran Build Map Points.bat through cmd input, inspected map_points.csv columns, checked lat/lng validity, checked duplicate address keys, inspected marker_health.json, parsed dashboard/mobile/index inline scripts with Node, and verified marker_health display plus marker rendering in the in-app browser at localhost:8790.

### Test Result

Pass with one manual UI caveat. Bat run stats: input_rows=2158, output_markers=51, skipped_invalid_coordinates=0, skipped_missing_address=0, duplicate_merged=2107, backup_created=map_points.backup_20260501_181517.csv. map_points.csv has 51 rows, all required fields, 0 invalid coordinate rows, and 0 duplicate compact address keys. marker_health.json generated_at=2026-05-01 18:15:17 and output_markers=51. Browser verification showed dashboard and mobile_dashboard displaying Marker health time 2026-05-01 18:15:17 and Marker count 51; map markers rendered in the today view, while browser-click popup verification was inconclusive.

### Risk / Follow-up

No dashboard marker source, parser, MAP8, notifications.jsonl format, map_resolved_points.csv format, missing_coordinate_queue builder, SQLite schema, LINE/Discord rule, 24HR dedupe, time-window market stats, mojibake fix, UI redesign, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0c Marker Builder MVP and Marker Health

### Task

Build the official marker output from map_resolved_points.csv and expose Marker Health metadata.

### Changed Files

* live-system/build_map_points.py
* Build Map Points.bat
* live-data/map_points.csv
* live-data/map_points.backup_20260501_163325.csv
* live-data/map_points.backup_20260501_163330.csv
* live-data/marker_health.json
* live-map/index.html
* live-map/dashboard.html
* live-map/mobile_dashboard.html

### Summary

Updated build_map_points.py to read only live-data/map_resolved_points.csv, keep rows with non-empty addresses and valid lat/lng, aggregate duplicate markers by compact address or coordinate key, back up map_points.csv before writing, and write live-data/marker_health.json. The formal marker output now includes marker_id, address, lat, lng, count, first_seen, last_seen, source, confidence, and sample_text. The live map now loads marker rows from map_points.csv only. Dashboard and mobile dashboard read marker_health.json with timestamp cache busting and show Marker 最後更新 / Marker 數量 in the existing health/overview areas.

### Test Method

Ran python -B -m py_compile live-system/build_map_points.py, ran python live-system/build_map_points.py, ran Build Map Points.bat through cmd input, inspected map_points.csv columns and lat/lng validity, inspected marker_health.json, checked output_markers equals map_points.csv data rows, parsed dashboard/mobile/index inline scripts with Node, and verified dashboard/mobile marker health display in the in-app browser at localhost:8790.

### Test Result

Pass. Bat run stats: input_rows=2155, output_markers=50, skipped_invalid_coordinates=0, skipped_missing_address=0, duplicate_merged=2105, backup_created=map_points.backup_20260501_163330.csv. map_points.csv has 50 rows and 0 invalid coordinate rows. marker_health.json generated_at=2026-05-01 16:33:30, source_file_mtime=2026-05-01 16:06:44, output_markers=50. Browser verification showed dashboard and mobile_dashboard both displaying Marker 最後更新=2026-05-01 16:33:30 and Marker 數量=50.

### Risk / Follow-up

No MAP8 auto lookup, address_geocode_cache import, parser change, notifications.jsonl format change, map_resolved_points.csv format change, missing_coordinate_queue builder change, SQLite schema change, LINE/Discord rule change, 24HR dedupe, time-window market stats, mojibake fix, UI redesign, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0b Missing Coordinate Queue Builder alignment

### Task

Align the Missing Coordinate Queue Builder with the v1.3.0b minimum work order.

### Changed Files

* live-system/build_missing_coordinate_queue.py
* live-data/missing_coordinate_queue.csv
* live-data/missing_coordinate_queue.backup_20260501_162413.csv
* live-data/missing_coordinate_queue.backup_20260501_162422.csv

### Summary

Updated the existing queue builder to also read map_points.csv as an exclusion source, so candidate addresses already present in the dashboard marker output are skipped. The queue output now includes the required review fields address, count, last_seen, source, sample_text, and reason while preserving existing helper fields for review context. The builder still only reads unresolved_addresses.csv, places.csv, notifications.jsonl, map_resolved_points.csv, map_points.csv, and address_geocode_cache.csv; it does not call MAP8, import cache rows, build markers, or change parser/data-source formats.

### Test Method

Ran python -B -m py_compile live-system/build_missing_coordinate_queue.py, ran python live-system/build_missing_coordinate_queue.py, ran Build Missing Coordinate Queue.bat through cmd input, inspected the output CSV header and first 10 queue rows, checked backup creation, and cross-checked all queue addresses against address_geocode_cache.csv, map_resolved_points.csv, and map_points.csv by compact exact key.

### Test Result

Pass. Direct script run created missing_coordinate_queue.backup_20260501_162413.csv and produced 9335 rows. Bat run created missing_coordinate_queue.backup_20260501_162422.csv and produced 9337 rows. Current bat stats: previous queue count 9335, unresolved source count 7117, places source count 22868, notifications source count 49357, candidate before dedupe count 57825, dedupe removed count 48488, already resolved skipped count 1170, already marker skipped count 0, already cached skipped count 1, invalid skipped count 5707, final queue count 9337. Exclusion exact-key hits across the final queue: 0.

### Risk / Follow-up

No Marker Builder, MAP8 auto lookup, cache import, 24HR dedupe, time-window market stats, parser change, notifications.jsonl format change, source CSV rewrite, dashboard UI, map logic, LINE, Discord, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0b Missing Coordinate Queue from parsed addresses rerun

### Task

Re-run and verify the independent Missing Coordinate Queue Builder from parsed/unresolved address sources.

### Changed Files

* live-data/missing_coordinate_queue.csv
* live-data/missing_coordinate_queue.backup_20260501_095625.csv
* live-data/missing_coordinate_queue.backup_20260501_095636.csv

### Summary

Verified the existing live-system/build_missing_coordinate_queue.py and Build Missing Coordinate Queue.bat implementation. The builder reads unresolved_addresses.csv, places.csv, notifications.jsonl, map_resolved_points.csv, and address_geocode_cache.csv; keeps only queryable address candidates with 路/街/巷/弄 plus 號; excludes exact addresses already in resolved points or geocode cache; dedupes by address key keeping the latest row; and writes missing_coordinate_queue.csv. No MAP8 API call or cache import is performed.

### Test Method

Ran python -B -m py_compile live-system/build_missing_coordinate_queue.py, ran python live-system/build_missing_coordinate_queue.py, ran Build Missing Coordinate Queue.bat through cmd input, inspected the first 10 queue rows, and checked Demo Address A and Demo Address B behavior.

### Test Result

Pass. Previous queue count before the direct script run was 8817. Direct script run produced 8841 rows and created missing_coordinate_queue.backup_20260501_095625.csv. Bat run then backed up the 8841-row queue to missing_coordinate_queue.backup_20260501_095636.csv and regenerated 8841 rows. Current run stats: unresolved source count 6685, places source count 21441, notifications source count 46369, candidate before dedupe count 54682, dedupe removed count 45841, already resolved skipped count 1126, already cached skipped count 1, invalid skipped count 5268, final queue count 8841. source_file breakdown: unresolved_addresses.csv=823, notifications.jsonl=5674, places.csv=2344. Demo Address A is in the queue. Exact Demo Address B is excluded because it already exists in map_resolved_points.csv.

### Risk / Follow-up

No parser, notifications.jsonl, places.csv, unresolved_addresses.csv, map_resolved_points.csv, map_points.csv, address_geocode_cache.csv, MAP8, dashboard JS, live-map/index.html, live-map/dashboard.html, SQLite, UI layout, map color, sidebar, search, LINE, auto-order, driver score, revenue prediction, or dispatch advice changes were made. Some notification-derived candidates can still be long address-like fragments; candidate normalization should be a separate follow-up if needed.

---

## 2026-05-01 - DrivePilot Live v1.3.1a 24HR source and refresh entry audit

### Task

Confirm the 24HR market data generation source, add update metadata, provide a safe manual refresh entry, and show the latest 24HR update time in dashboard health areas.

### Changed Files

* live-system/signal_stats_24h.py
* live-data/signal_stats_24h.json
* Refresh Market Data.bat
* live-map/dashboard.html
* live-map/mobile_dashboard.html

### Summary

Confirmed signal_stats_24h.json is generated by live-system/signal_stats_24h.py from live-data/notifications.jsonl. Start DrivePilot.bat starts start_drivepilot_live.ps1 and does not rebuild the 24HR JSON. Existing dashboard/mobile refresh flows only fetch the JSON; they do not regenerate it. Added source_file_mtime at the JSON top level using notifications.jsonl last modified time, while preserving generated_at. Added Refresh Market Data.bat as a safe manual entry that only runs live-system/signal_stats_24h.py. Dashboard and mobile_dashboard already used timestamp cache busting and no-store fetch for signal_stats_24h.json; both now also show 24HR 最後更新 from generated_at in the system/overview health area.

### Test Method

Searched project references for signal_stats_24h.json, inspected Start DrivePilot.bat and start_drivepilot_live.ps1, compiled signal_stats_24h.py with python -B -m py_compile, ran python live-system/signal_stats_24h.py, ran Refresh Market Data.bat through cmd input, inspected live-data/signal_stats_24h.json, and verified dashboard/mobile cache-busting and update-time DOM hooks.

### Test Result

Pass. Refreshed JSON generated_at=2026-05-01 09:51:58 and source_file_mtime=2026-05-01 09:50:55. Source row count 46327. Current window 2026-05-01 08:51:58 to 2026-05-01 09:51:58: raw 496, deduped 365, duplicate 131. Yesterday same window raw 315, deduped 235. Refresh Market Data.bat completed successfully and printed Market data refreshed.

### Risk / Follow-up

Manual refresh is required unless a future task explicitly wires 24HR rebuild into startup or a scheduler. No parser, notifications.jsonl format, SQLite schema, MAP8, marker source, dashboard layout, map color, sidebar, LINE, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0b Missing Coordinate Queue from parsed addresses

### Task

Build an independent missing-coordinate queue from parsed/unresolved notification sources, excluding addresses already resolved or cached.

### Changed Files

* live-system/build_missing_coordinate_queue.py
* Build Missing Coordinate Queue.bat
* live-data/missing_coordinate_queue.csv
* live-data/missing_coordinate_queue.backup_20260501_093817.csv
* live-data/missing_coordinate_queue.backup_20260501_093826.csv

### Summary

Added a standard-library queue builder that reads unresolved_addresses.csv, places.csv, notifications.jsonl, map_resolved_points.csv, and address_geocode_cache.csv. It collects queryable address candidates using the MVP rule requiring 路/街/巷/弄 plus 號, skips empty/non-queryable/mojibake candidates, excludes exact addresses already present in map_resolved_points.csv or address_geocode_cache.csv, dedupes by address key keeping the latest row, backs up the previous missing_coordinate_queue.csv when present, and writes missing_coordinate_queue.csv with suggested_action=map8_review_candidate. The script does not call MAP8, does not write address_geocode_cache.csv, and does not modify parser, notifications, places, unresolved, map_resolved_points, or map_points.

### Test Method

Ran python -B -m py_compile live-system/build_missing_coordinate_queue.py, ran python live-system/build_missing_coordinate_queue.py, ran Build Missing Coordinate Queue.bat through cmd input, inspected missing_coordinate_queue.csv, checked first 10 queue examples, and checked Demo Address A / Demo Address B / Demo Address C behavior.

### Test Result

Pass. unresolved source count 6668, places source count 21384, notifications source count 46224. candidate before dedupe count 54521, dedupe removed count 45704, already resolved skipped count 1124, already cached skipped count 1, invalid skipped count 5261, final queue count 8817. source_file breakdown: unresolved_addresses.csv=824, notifications.jsonl=5659, places.csv=2334. reason breakdown: queryable_address_missing_coordinates;not_in_resolved_or_cache=8817. Demo Address A is in the queue. Exact Demo Address B and Demo Address C are excluded because they already exist in map_resolved_points.csv.

### Risk / Follow-up

No MAP8 API call or cache import was performed. Notification text extraction may still produce longer address-like fragments containing a resolved address, so the next cleanup pass should improve candidate normalization before MAP8 review import. No parser, notifications.jsonl, places.csv, unresolved_addresses.csv, map_resolved_points.csv, map_points.csv, address_geocode_cache.csv, dashboard JS, live-map/index.html, live-map/dashboard.html, SQLite, UI layout, map color, sidebar, search, LINE, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0 Marker Builder MVP map_resolved_points to map_points

### Task

Update the Marker Builder MVP to generate map_points.csv from map_resolved_points.csv with address dedupe and a missing-coordinate candidate queue.

### Changed Files

* live-system/build_map_points.py
* live-data/map_points.csv
* live-data/map_points.backup_20260501_042239.csv
* live-data/map_points.backup_20260501_042247.csv
* live-data/missing_coordinate_queue.csv

### Summary

Kept the existing 60min/today/24h window support and default today mode. build_map_points.py now writes dashboard-compatible map_points.csv with time, address, normalized_address, resolved_address, lat, lng, source, confidence, kind, note, and text_summary. It still reads map_resolved_points.csv, requires parseable time, address, and valid lat/lng for marker output, dedupes by normalized_address/address/resolved_address and keeps the latest row. It now also writes missing_coordinate_queue.csv for rows in the selected window that lack valid coordinates but look queryable by MVP rule: contains 路/街/巷/弄 and 號. The queue is output-only and does not call MAP8 or write address_geocode_cache.csv.

### Test Method

Ran python -B -m py_compile live-system/build_map_points.py, ran python live-system/build_map_points.py with default today mode, ran Build Map Points.bat with default today mode through cmd input, then inspected map_points.csv, missing_coordinate_queue.csv, and new map_points backups.

### Test Result

Pass. Before builder run, map_points.csv had 23 rows. Default today run: source total records 2078, records in selected window 30, valid coordinate records 30, missing coordinate candidate records 0, skipped records 0, dedupe input count 30, final marker count 8, duplicate removed count 22. Source breakdown: map_points=7, address_geocode_cache=1. Confidence breakdown: high=7, standardized=1. Kind breakdown: place=2, place_alias=2, start=4. missing_coordinate_queue.csv was created with 0 rows because selected map_resolved_points.csv rows already had valid coordinates.

### Risk / Follow-up

No parser, notifications.jsonl, MAP8, address_geocode_cache.csv, map_resolved_points.csv, dashboard JS, live-map/index.html, live-map/dashboard.html, SQLite, UI layout, map color, sidebar, search, LINE, auto-order, driver score, revenue prediction, or dispatch advice changes were made. Since map_resolved_points.csv normally contains only resolved rows, missing_coordinate_queue.csv may stay empty; a fuller missing-coordinate workflow should read parsed/unresolved address sources in a separate explicitly allowed task.

---

## 2026-05-01 - DrivePilot Live v1.3.0b Parsed address classification audit

### Task

Audit dashboard parsed-address status classification and compare frontend status with resolver/cache/unresolved data, without changing parser logic or marker data.

### Changed Files

* live-system/audit_parsed_address_classification.py
* Audit Parsed Address Classification.bat
* live-data/parsed_address_classification_review.csv
* live-data/parsed_address_classification_audit.json

### Summary

Added a read-only audit script for parsed address classification. The script reads places.csv, map_resolved_points.csv, unresolved_addresses.csv, and address_geocode_cache.csv; analyzes the latest 60 minutes of parsed addresses; classifies each row as resolved, queryable_unresolved, road_level_only, landmark_or_text, or unknown; and writes both a review CSV and summary JSON. It also explicitly audits Demo Address A, Demo Address B, and Demo Address C. Dashboard status text was confirmed to come from live-map/dashboard.html mapping places.csv confidence values: high to 可定位, medium to 部分定位, and low to 待確認.

### Test Method

Ran python -B -m py_compile live-system/audit_parsed_address_classification.py, ran python live-system/audit_parsed_address_classification.py, and ran Audit Parsed Address Classification.bat through cmd input to verify the wrapper. Inspected the generated summary and review rows for the three requested addresses.

### Test Result

Pass. Current audit window: 2026-05-01 03:11:17 to 2026-05-01 04:11:17. Recent 60-minute parsed address rows: 370. Inferred status counts: resolved=16, queryable_unresolved=290, road_level_only=61, landmark_or_text=3. Frontend status counts: 可定位=213, 部分定位=42, 待確認=115. Demo Address A is frontend 待確認 because places.csv confidence is low; it is queryable_unresolved, not in map_resolved_points.csv, present in unresolved_addresses.csv, and absent from address_geocode_cache.csv. Demo Address B latest exact row is frontend 待確認 but has historical/resolved marker rows. Demo Address C is frontend 可定位 because places.csv confidence is high and is also present in map_resolved_points.csv.

### Risk / Follow-up

No parser, notifications.jsonl, map_resolved_points.csv, map_points.csv, address_geocode_cache.csv, unresolved_addresses.csv, MAP8, SQLite, dashboard UI/layout, map color, sidebar, search, LINE, auto-order, driver score, revenue prediction, or dispatch advice changes were made. Next fix should separate frontend parse confidence from resolver state and route queryable_unresolved rows into the unresolved/MAP8 review path without treating them as generic 待確認.

---

## 2026-05-01 - DrivePilot Live v1.3.0a Marker Builder time window mode

### Task

Add Marker Builder window modes for 60min, today, and 24h, with today as the default Build Map Points.bat mode.

### Changed Files

* live-system/build_map_points.py
* Build Map Points.bat
* live-data/map_points.csv
* live-data/map_points.backup_20260501_035539.csv
* live-data/map_points.backup_20260501_035628.csv
* live-data/map_points.backup_20260501_035633.csv
* live-data/map_points.backup_20260501_035638.csv
* live-data/map_points.backup_20260501_035648.csv
* live-data/map_points.backup_20260501_035657.csv
* live-data/map_points.backup_20260501_035702.csv
* live-data/map_points.backup_20260501_035708.csv
* live-data/map_points.backup_20260501_035719.csv

### Summary

Updated build_map_points.py to support --window 60min, --window today, --window 24h, plus positional 60min/today/24h. Default mode is today. Build Map Points.bat now defaults to today, accepts 60min/today/24h, and rejects invalid input with Usage: Build Map Points.bat [60min|today|24h]. Existing builder rules remain: read map_resolved_points.csv, require parseable time/address/lat/lng, dedupe by address key keeping the latest row, back up map_points.csv before writing, and preserve popup fields.

### Test Method

Ran python -B -m py_compile, python build_map_points.py --window 60min, --window today, --window 24h, Build Map Points.bat with no args, 60min, today, 24h, and an invalid argument. Also ran python build_map_points.py today to verify positional argument support.

### Test Result

Pass. 60min: selected 4, valid 4, final marker count 3. today: selected 15, valid 15, final marker count 6. 24h: selected 561, valid 561, final marker count 22. Bat no-arg defaulted to today and produced final marker count 6. Bat 60min/today/24h all ran successfully. Invalid bat argument printed usage and exited with error. Each builder run created a map_points backup before writing.

### Risk / Follow-up

Final map_points.csv was left in today mode with 6 markers. Browser/dashboard should be refreshed with Ctrl+F5 or iframe reload to read the updated CSV. No parser, notifications, MAP8, address_geocode_cache, map_resolved_points, dashboard JS, map color, UI layout, sidebar, SQLite, search, auto-order, driver score, revenue prediction, or dispatch advice changes were made.

---

## 2026-05-01 - DrivePilot Live v1.3.0 Marker Builder resolved_points to map_points

### Task

Build a safe Marker Builder that produces live-data/map_points.csv from recent valid rows in live-data/map_resolved_points.csv.

### Changed Files

* live-system/build_map_points.py
* Build Map Points.bat
* live-data/map_points.csv
* live-data/map_points.backup_20260501_034237.csv

### Summary

Added a standard-library Python builder that reads map_resolved_points.csv with csv module, keeps only rows from the latest 60 minutes, requires address plus valid lat/lng plus parseable time, deduplicates by normalized address/address/resolved_address and keeps the latest row, backs up the previous map_points.csv, then writes a dashboard-compatible map_points.csv with time, address, normalized_address, lat, lng, source, confidence, kind, note, and text_summary. map_points.csv was previously only a static seed/fallback file read by location_resolver.ps1; map_resolved_points.csv is produced by location_resolver.ps1 when notifications resolve to coordinates.

### Test Method

Compiled build_map_points.py with python -B -m py_compile, ran python live-system/build_map_points.py, inspected the generated map_points.csv and backup, and verified the bat contents only invoke the builder script.

### Test Result

Pass. Previous map_points.csv count was 15 Import-Csv records. Source total records in map_resolved_points.csv were 2063. Latest 60-minute window had 6 records, all valid. Deduped output count is 4, duplicate removed count is 2. Final map_points.csv count is 4. Breakdown: source map_points=4, confidence high=4, kind place_alias=2/start=1/place=1.

### Risk / Follow-up

Marker count did not increase because the strict latest-60-minute rule produced only 4 unique valid markers at run time. Dashboard/browser should be refreshed, preferably Ctrl+F5, to reload the updated CSV. No parser, MAP8, notifications format, address_geocode_cache, SQLite, dashboard JS, map style, sidebar, or UI layout changes were made.

---

## 2026-04-30 - DrivePilot Live v1.3.0d map_points location quality audit

### Task

Audit source=map_points marker quality without changing parser, dashboard UI, or marker source data.

### Changed Files

* live-system/audit_map_points_quality.py
* Audit Map Points Quality.bat
* live-data/map_points_quality_review.csv
* live-data/map_points_quality_summary.json

### Summary

Added a standard-library Python audit script that reads live-data/map_resolved_points.csv, analyzes only source=map_points rows, classifies each row into risk categories, writes a review CSV, writes a summary JSON, and prints console totals. The audit is read-only for map_resolved_points.csv, map_points.csv, address_geocode_cache.csv, and notifications.jsonl.

### Test Method

Compiled audit_map_points_quality.py with python -B -m py_compile, ran python live-system/audit_map_points_quality.py, inspected generated review CSV and summary JSON, and checked that input data file timestamps were not changed by the audit.

### Test Result

Pass. Current run: total records 1995, map_points source records 1704. risk_counts: precise_candidate=10, road_or_landmark_level=4, static_seed_risk=1156, alias_mismatch_risk=532, mojibake_text_risk=2, missing_address_risk=0, unknown_risk=0. suggested_action_counts: keep=10, review=1158, downgrade_display=4, hide_from_main_marker=0, needs_cache_review=532.

### Risk / Follow-up

The audit is heuristic and does not hide or fix markers. Next step should review high-risk static_seed_risk and alias_mismatch_risk rows before changing any display or resolver behavior.

---

## 2026-04-30 - DrivePilot Live v1.3.0c Marker count / source / accuracy audit

### Task

Add marker loading audit visibility for the live map without changing parser, data files, map UI, or map styling.

### Changed Files

* live-map/index.html

### Summary

Added a console-only marker audit summary exposed as window.drivePilotMarkerAudit. The audit logs marker source file, loaded CSV records, parsed records, filtered records for the active time window, rendered marker count, source breakdown, kind breakdown, confidence breakdown, rough accuracy buckets, and skipped row reasons. This keeps existing marker rendering and popup behavior unchanged.

### Test Method

Parsed live-map/index.html inline scripts with Node, inspected the new audit hooks, and read current CSV counts/distributions from live-data/map_resolved_points.csv and live-data/map_points.csv without modifying data files.

### Test Result

Pass. Current local snapshot at test time: dashboard source priority is data/map_resolved_points.csv first; live-data/map_resolved_points.csv had 1967 Import-Csv records, with the active 60-minute window containing 12 rows. The current 60-minute source breakdown was map_points=12; kind breakdown place_alias=8/end=4; confidence high=12. Full loaded source distribution was map_points=1676 and address_geocode_cache=291.

### Risk / Follow-up

Audit is browser-console only and requires Ctrl+F5 or iframe reload to use the updated script. Accuracy classification is heuristic: map_points is treated as static/older source, low confidence or description rows as rough, and rows without a house number as road/landmark level.

---

## 2026-04-30 - DrivePilot Live v1.3.0b Dashboard marker source order

### Task

Fix live map marker CSV source priority so resolved points are the primary dashboard marker source and map_points.csv is only a fallback.

### Changed Files

* live-map/index.html

### Summary

Updated the live map marker CSV URL order to read data/map_resolved_points.csv first, then ../live-data/map_resolved_points.csv, then map_points.csv fallback paths. The coordinate fallback loader now uses the same resolved-first order and preserves source labels from resolved rows. map_points.csv remains available only as a static fallback if resolved points are unavailable. Existing popup details for address, time, resolved status, and location source remain unchanged.

### Test Method

Counted current CSV rows for live-data/map_points.csv and live-data/map_resolved_points.csv, searched live-system and live-map references to identify producers/readers, and parsed live-map/index.html inline scripts with Node.

### Test Result

Pass. Current local snapshot: map_points.csv has 15 Import-Csv records / 9 physical data lines; map_resolved_points.csv has 1782 Import-Csv records / 6611 physical data lines because some CSV fields contain embedded newlines. live-map/index.html now uses resolved-first URLs with timestamp cache busting and no-store fetch. No parser, notifications, MAP8, SQLite, dashboard UI layout, sidebar, or map color changes were made.

### Risk / Follow-up

Browser should be refreshed with Ctrl+F5 or the dashboard iframe reloaded so the updated index.html script is used. If the running receiver appends new resolved rows while testing, live row counts may differ from the static counts above.

---

## 2026-04-30 - DrivePilot Live v1.3.1 Notification data quality UTF-8 and personal reminder

### Task

Fix new notification UTF-8 decoding at the receiver boundary and tighten personal reminder trigger rules.

### Changed Files

* live-system/line_notification_receiver.ps1
* live-system/map_server.ps1
* live-system/test_dispatcher_private.ps1

### Summary

Added request-body decode fallback so JSON notification bodies prefer UTF-8 and correct mojibake when a non-UTF-8 charset is declared incorrectly. File writes continue through UTF-8 append helpers without changing notifications.jsonl schema or rewriting old data. Personal reminders now only inspect message/text/body/raw_text/content and only trigger on 東尼工作機, @東尼工作機, or 代駕. Removed 標記 and 被標記 from personal reminder triggers. Updated mobile API high-value type text from 總機私訊 to 個人提醒 while keeping existing internal dispatcher_private fields for compatibility.

### Test Method

Parsed line_notification_receiver.ps1 and map_server.ps1 with the PowerShell parser. Ran live-system/test_dispatcher_private.ps1 with cases for 標記, 被標記, 東尼工作機, @東尼工作機, 代駕, and sender/group-only matches. Searched receiver/dashboard/mobile display paths for removed trigger/display terms and inspected the latest notifications.jsonl line without modifying it.

### Test Result

Pass. Syntax checks passed. 標記 / 被標記 / 補單 / 總機請標記 no longer trigger the personal reminder test path. 東尼工作機, @東尼工作機, and 代駕 still trigger. Sender/group-only 東尼工作機 or 代駕 does not trigger. Existing historical notifications may still contain old dispatcher_private records, but no old notifications were rewritten.

### Risk / Follow-up

Receiver service must be restarted for the new decoding and personal reminder logic to apply to live traffic. Discord delivery was not sent during this test to avoid external side effects.

---

## 2026-04-30 - DrivePilot Live v1.2.7g Fix 24HR current window stats

### Task

Fix signal_stats_24h.json current-window counts so the 24HR market comparison follows the same live notification source used by dashboard event feeds.

### Changed Files

* live-system/signal_stats_24h.py
* live-data/signal_stats_24h.json

### Summary

Changed the 24HR stats source from the stale SQLite signals table to live-data/notifications.jsonl. The current window now covers the latest 60 minutes, and the comparison window covers the same 60-minute period yesterday while preserving the existing current_24h / previous_24h / delta JSON fields used by dashboard and mobile_dashboard. Kept raw_count, deduped_count, and duplicate_count, with 3-minute duplicate detection by group/source plus address-or-text signal key. Added console debug summary for now, current/previous window bounds, source row count, raw counts, deduped counts, and duplicate count.

### Test Method

Ran the old script before modification to confirm current=0 against SQLite. Compiled the updated script with python -m py_compile, regenerated live-data/signal_stats_24h.json, inspected the JSON fields, and parsed dashboard.html/mobile_dashboard.html inline scripts to confirm existing 24HR cache busting and fallback still work.

### Test Result

Pass. Before fix: current raw 0, previous raw 6975 from SQLite at test time. After fix: source rows 37423, current window 2026-04-30 19:52:19 to 2026-04-30 20:52:19, previous window 2026-04-29 19:52:19 to 2026-04-29 20:52:19, current raw 1084, current deduped 766, duplicate 318, previous raw 349, previous deduped 270.

### Risk / Follow-up

The JSON key names remain current_24h and previous_24h for frontend compatibility, but the comparison definition is now 60-minute current window versus yesterday's same 60-minute window.

---

## 2026-04-30 - DrivePilot Live v1.2.7f Rebuild map resolved points from geocode cache

### Task

Rebuild live-data/map_resolved_points.csv from existing notifications and geocode sources so MAP8-reviewed cache entries can become dashboard marker source rows when matching existing signal addresses.

### Changed Files

* live-data/map_resolved_points.csv
* live-data/map_resolved_points.backup_20260430_175702.csv
* live-data/map_resolved_points.partial_backup_20260430_180014.csv
* live-data/map_resolved_points.final_backup_20260430_180325.csv

### Summary

Identified live-system/location_resolver.ps1 as the existing resolver script that writes map_resolved_points.csv and reads address_geocode_cache.csv. Rebuilt map_resolved_points.csv from notifications.jsonl using the resolver's normalization and cache/map_points matching rules, without calling MAP8 API, changing parser logic, changing dashboard marker logic, or writing notifications.jsonl. The original map_resolved_points.csv was backed up before rebuild.

### Test Method

Searched project references for map_resolved_points.csv, inspected location_resolver.ps1 cache loading and resolved output logic, counted map_resolved_points.csv before and after rebuild, grouped rebuilt rows by source, and checked the 10 should_import=true MAP8 review addresses against address_geocode_cache.csv, notifications.jsonl, and rebuilt map_resolved_points.csv.

### Test Result

Pass. Before rebuild: 286 rows. After rebuild: 1169 rows. Rebuilt rows by source: 1010 from map_points, 159 from address_geocode_cache. MAP8 review rows in cache: 10. MAP8 review rows resolved into map_resolved_points.csv: 9. Unresolved MAP8 review row: Demo Address D, because notifications.jsonl had no matching address or text.

### Risk / Follow-up

The rebuild was intentionally data-only. It does not force unmatched cache entries into marker output; future marker increases still depend on notifications containing matching addresses.

---

## 2026-04-30 - DrivePilot Live v1.2.7e MAP8 review import to geocode cache

### Task

Add an independent importer for manually reviewed MAP8 geocode rows, importing only should_import=true results into address_geocode_cache.csv after creating a backup.

### Changed Files

* live-system/import_map8_review_to_cache.py
* Map8 Import Review To Cache.bat
* live-data/address_geocode_cache.backup_20260430_173050.csv

### Summary

Added a standard-library Python importer that reads live-data/map8_geocode_review.csv with utf-8-sig, validates should_import values, required address/lat/lng fields, non-empty error values, and existing cache conflicts. The importer preserves the existing address_geocode_cache.csv field order and maps review data into existing cache columns without changing schema. Added a BAT wrapper that only runs the importer and reports a missing Python executable.

The test run created a backup and found no importable rows because all current review rows were skipped by should_import rules.

### Test Method

Ran python -m py_compile on the importer, searched the importer/BAT for forbidden API/data-flow references, and executed python .\live-system\import_map8_review_to_cache.py.

### Test Result

Pass. Review rows: 10. Imported: 0. Skipped: 10. Already exists: 0. Conflicts: 0. Errors: 0. Backup: live-data/address_geocode_cache.backup_20260430_173050.csv.

### Risk / Follow-up

No cache rows were added in this run because no review row currently has an accepted should_import value.

---

## 2026-04-30 - DrivePilot Live v1.2.7d-hotfix-3 Embedded Leaflet map width

### Task

Fix the embedded dashboard Leaflet map width regression where map tiles rendered only as a narrow left strip after the preferred dark map follow-up.

### Changed Files

* live-map/dashboard.html
* live-map/index.html

### Summary

Locked index.html embed mode to a single full-width map stage, hid the embedded map's internal aside with an important embed override, and forced the map stage, #map, and .leaflet-container to fill the iframe. Updated dashboard.html's injected iframe CSS so it no longer restores the old two-column map layout, which was leaving a stale sidebar column while the aside was hidden. Added immediate and 600ms dashboard resize notifications around the existing 150ms and 300ms iframe-load invalidateSize requests. Removed stale map-tone switching classes so the existing preferred filter is the only active tile filter.

The preferred dark map tone filter was not changed and remains scoped to .leaflet-tile-pane:
invert(.88) hue-rotate(180deg) saturate(.48) brightness(.78) contrast(.94)

### Test Method

Parsed dashboard.html and index.html inline scripts with Node. Inspected the embedded iframe CSS, Leaflet container width/height rules, invalidateSize postMessage timing, right-side 24HR marker, and map header action markers.

### Test Result

Pass for code-level checks. The specific regression cause was removed: dashboard injected CSS no longer forces a two-column embedded map grid. Live browser visual confirmation is still required on the running dashboard because the reported failure is visual.

### Risk / Follow-up

Manual reload of dashboard.html should confirm that map tiles fill the entire map panel on first paint without dragging.

---

## 2026-04-30 - DrivePilot Live v1.2.7d-hotfix-2 Visual reference follow-up

### Task

Remove embedded-map fog sources while keeping the preferred dark tile tone and v1.2.7d dashboard UI placement.

### Changed Files

* live-map/index.html

### Summary

Kept the locked tile-only preferred dark filter unchanged. Removed the embedded map's left translucent panel by hiding the index.html aside only when loaded with ?embed=1, so the map fills the dashboard iframe. Removed backdrop-filter from the small map status overlay to avoid frosted/blurred map appearance.

### Test Method

Parsed dashboard.html and index.html inline scripts with Node, inspected Leaflet/map CSS for duplicate filters, overlay, opacity, mix-blend-mode, and verified dashboard header actions plus right-side 24HR markers.

### Test Result

Pass for static checks. The only tile filter remains invert(.88) hue-rotate(180deg) saturate(.48) brightness(.78) contrast(.94), scoped to .leaflet-tile-pane.

### Risk / Follow-up

Browser visual confirmation is still required on the running dashboard to compare against the provided target image.

---

## 2026-04-30 - DrivePilot Live v1.2.7d-hotfix-2 Preferred dark map tone lock

### Task

Lock the live map to the preferred dark map tone without changing dashboard layout, sidebar, 24HR cards, data logic, or marker sources.

### Changed Files

* live-map/index.html

### Summary

Verified that the current Leaflet tile styling already uses the preferred dark map tone filter and that no duplicate tile filters or full-map dark overlays are present. Added a CSS lock comment beside the single tile-only filter so the preferred tone is not freely retuned later. The filter remains scoped to .leaflet-tile-pane, leaving markers and popups unaffected.

### Test Method

Parsed dashboard.html and index.html inline scripts with Node, inspected map/Leaflet CSS references, verified the dashboard map header actions and v1.2.7d UI markers, and searched for forbidden parser/data/API changes.

### Test Result

Pass for static checks. The preserved filter is invert(.88) hue-rotate(180deg) saturate(.48) brightness(.78) contrast(.94). Browser visual confirmation on the running dashboard is still recommended.

### Risk / Follow-up

No code path or data-source risk. This change intentionally does not alter the visual parameters beyond documenting the lock.

---

## 2026-04-30 - DrivePilot Live v1.2.7d-hotfix Map dark style / Leaflet invalidateSize

### Task

Restore the embedded dashboard map to a dark command-center tone and fix Leaflet first-load sizing without changing map data or dashboard layout.

### Changed Files

* live-map/dashboard.html
* live-map/index.html

### Summary

Adjusted the OSM tile CSS filter to a controlled dark gray style using the existing Leaflet/OSM tiles, without changing map providers or marker data. Added a small Leaflet sizing helper in index.html that calls invalidateSize after init at 100ms and 300ms, again after window load, and on resize. Dashboard now asks the embedded map to run the same resize helper after the iframe loads at 150ms and 300ms.

### Test Method

Parsed dashboard.html and index.html inline scripts with Node, inspected the map CSS and invalidateSize references, and searched for forbidden parser/data/API changes. Browser visual testing was not available in this Codex environment.

### Test Result

Partial pass. Static checks pass and the hotfix preserves v1.2.7d UI cleanup markers: header map actions, hidden embedded 24HR, right-side 24HR without green card frame, and five sidebar categories. Live first-load visual verification still needs to be done in the running dashboard.

### Risk / Follow-up

Tile darkness may need a final visual tweak on the actual driver display, but the filter is now scoped to tiles only and avoids the previous heavy black fog.

---

## 2026-04-30 - DrivePilot Live v1.2.7d Dashboard UI cleanup

### Task

Clean up desktop dashboard map controls, duplicate 24HR placement, right-rail card styling, map darkness, and sidebar navigation.

### Changed Files

* live-map/dashboard.html
* live-map/index.html

### Summary

Moved the embedded live map actions into the dashboard map card header, kept the right-side 24HR market card as the only dashboard 24HR card, removed the green full-card border from that card, and consolidated the sidebar into five main entries. Reduced the map darkening by removing the inverted Leaflet tile filter, forcing normal tile opacity/blending, lightening the map status overlay, and trimming the dashboard map inset shadow.

### Test Method

Parsed dashboard.html and index.html inline scripts with Node, inspected dashboard/index CSS and HTML references, and searched for forbidden data/API/parser changes.

### Test Result

Pass. No new search feature, backend API, SQLite dashboard dependency, parser change, or notifications.jsonl format change was added.

### Risk / Follow-up

Visual verification in a running browser is still recommended on the live 8790 dashboard, especially tile brightness on the driver display.

---

## 2026-04-30 - DrivePilot Live v1.2.7c 24HR refresh / dedupe / UI position

### Task

Fix 24HR market compare refresh, dedupe counts, and dashboard/mobile display placement.

### Changed Files

* live-system/signal_stats_24h.py
* live-map/dashboard.html
* live-map/mobile_dashboard.html
* live-data/signal_stats_24h.json

### Summary

Added 3-minute duplicate counting for 24HR stats without changing notifications.jsonl or the SQLite schema. Dashboard and mobile dashboard now read the same signal_stats_24h.json with timestamp cache busting and show current signals, previous 24H same window, change, deduped signals, and duplicate signals. Desktop 24HR card is placed in the right rail between hot zones and system status.

### Test Method

Run python live-system/signal_stats_24h.py, compile signal_stats_24h.py, parse dashboard/mobile inline scripts with Node, and inspect JSON/frontend references.

### Test Result

Pass. signal_stats_24h.json includes raw_count, deduped_count, and duplicate_count. Both dashboard views reference data/signal_stats_24h.json with timestamp cache busting.

### Risk / Follow-up

Current 24H count is 0 because the local SQLite signal DB has no signals in the current 24-hour window at test time. No forbidden files or flows were intentionally changed.

---

## 2026-04-27｜Project Sync Files Created

### Task

Create project synchronization files to reduce context loss between ChatGPT and Codex.

### Files Added

* DRIVEPILOT_CONTEXT.md
* CODEX_TASK.md
* CHANGELOG_DRIVEPILOT.md
* IDEA_PARKING_LOT.md

### Purpose

* DRIVEPILOT_CONTEXT.md: shared project memory
* CODEX_TASK.md: current single Codex task
* CHANGELOG_DRIVEPILOT.md: implementation history
* IDEA_PARKING_LOT.md: future ideas not yet scheduled

### Test Method

Confirm the 4 Markdown files exist in the project root.

### Test Result

Pending Codex confirmation.

### Risk

Low. This task should not modify any functional DrivePilot files.

---

## Changelog Template

### Date

YYYY-MM-DD

### Task

Short task name.

### Changed Files

* file A
* file B

### Summary

Short explanation of what changed.

### Test Method

How the change was tested.

### Test Result

Pass / Fail / Partial.

### Risk / Follow-up

Anything that may need attention later.

---

