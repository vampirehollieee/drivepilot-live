from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from init_signal_db import LIVE_DATA_DIR


SOURCE_PATH = LIVE_DATA_DIR / "notifications.jsonl"
OUTPUT_PATH = LIVE_DATA_DIR / "signal_stats_24h.json"
DEDUP_WINDOW = timedelta(minutes=3)
CURRENT_WINDOW = timedelta(minutes=60)
PREVIOUS_OFFSET = timedelta(hours=24)


def iso_dt(value: datetime) -> str:
    return value.replace(microsecond=0).isoformat(sep=" ")


def file_mtime(path: Path) -> Optional[str]:
    try:
        return iso_dt(datetime.fromtimestamp(path.stat().st_mtime))
    except OSError:
        return None


def normalize_text(value: Any) -> str:
    return " ".join(str(value or "").strip().split())


def parse_dt(value: Any) -> Optional[datetime]:
    text = normalize_text(value)
    if not text:
        return None
    candidates = (text, text.replace("T", " "), text.replace("/", "-"))
    formats = (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
    )
    for candidate in candidates:
        try:
            parsed = datetime.fromisoformat(candidate)
            if parsed.tzinfo is not None:
                return parsed.astimezone().replace(tzinfo=None)
            return parsed
        except ValueError:
            pass
        for fmt in formats:
            try:
                return datetime.strptime(candidate, fmt)
            except ValueError:
                pass
    return None


def safe_console_text(value: Any) -> str:
    text = str(value or "")
    encoding = sys.stdout.encoding or "utf-8"
    return text.encode(encoding, errors="replace").decode(encoding, errors="replace")


def read_notification_rows(path: Path = SOURCE_PATH) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not path.exists():
        raise FileNotFoundError(f"DrivePilot notification source not found: {path}")

    with path.open("r", encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                row = json.loads(text)
            except json.JSONDecodeError as exc:
                print(f"skip invalid notification json line {line_number}: {exc}")
                continue
            timestamp = parse_dt(row.get("timestamp") or row.get("created_at") or row.get("time") or row.get("datetime"))
            if timestamp is None:
                continue
            row["_parsed_timestamp"] = timestamp
            rows.append(row)
    return rows


def row_group(row: Dict[str, Any]) -> str:
    return (
        normalize_text(row.get("source"))
        or normalize_text(row.get("group"))
        or normalize_text(row.get("group_name"))
        or normalize_text(row.get("source_name"))
        or normalize_text(row.get("title"))
    )


def row_group_key(row: Dict[str, Any]) -> str:
    return row_group(row) or "unknown"


def row_addresses(row: Dict[str, Any]) -> List[str]:
    values: List[str] = []
    for field in ("address", "normalized_address", "resolved_address", "parsed_address", "formatted_address"):
        value = normalize_text(row.get(field))
        if value:
            values.append(value)
    addresses = row.get("addresses")
    if isinstance(addresses, list):
        values.extend(normalize_text(address) for address in addresses if normalize_text(address))
    places = row.get("places")
    if isinstance(places, list):
        for place in places:
            if isinstance(place, dict):
                value = normalize_text(place.get("address") or place.get("formatted_address"))
                if value:
                    values.append(value)
    return values


def row_signal_key(row: Dict[str, Any]) -> str:
    addresses = row_addresses(row)
    if addresses:
        return addresses[0]
    for field in ("raw_text", "text", "message", "body", "content"):
        value = normalize_text(row.get(field))
        if value:
            return value
    raw = row.get("raw")
    if isinstance(raw, dict):
        return normalize_text(raw.get("text") or raw.get("title"))
    return ""


def row_text(row: Dict[str, Any]) -> str:
    for field in ("text", "raw_text", "body", "message", "content"):
        value = normalize_text(row.get(field))
        if value:
            return value
    raw = row.get("raw")
    if isinstance(raw, dict):
        return normalize_text(raw.get("text") or raw.get("title"))
    return ""


def row_area(row: Dict[str, Any]) -> str:
    for value in row_addresses(row):
        match = next((part for part in ("楠梓區", "左營區", "三民區", "新興區", "前金區", "苓雅區", "前鎮區", "小港區", "鳳山區", "仁武區", "鳥松區", "大寮區", "鼓山區") if part in value), "")
        if match:
            return match
    return ""


def window_rows(rows: Iterable[Dict[str, Any]], start_dt: datetime, end_dt: datetime) -> List[Dict[str, Any]]:
    return [
        row
        for row in rows
        if start_dt <= row["_parsed_timestamp"] < end_dt
    ]


def top_items(values: Iterable[str], limit: int = 3) -> List[Dict[str, Any]]:
    counter = Counter(value for value in values if value)
    return [{"name": name, "count": count} for name, count in counter.most_common(limit)]


def dedupe_rows(rows: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], int]:
    deduped: List[Dict[str, Any]] = []
    duplicate_count = 0
    last_seen: Dict[Tuple[str, str], datetime] = {}

    for row in sorted(rows, key=lambda item: item["_parsed_timestamp"]):
        seen_at = row.get("_parsed_timestamp")
        signal_key = row_signal_key(row)

        if not isinstance(seen_at, datetime) or not signal_key:
            deduped.append(row)
            continue

        dedupe_key = (row_group_key(row).casefold(), signal_key.casefold())
        previous_at = last_seen.get(dedupe_key)
        last_seen[dedupe_key] = seen_at
        if previous_at and seen_at - previous_at <= DEDUP_WINDOW:
            duplicate_count += 1
            continue
        deduped.append(row)

    return deduped, duplicate_count


def dedupe_counts(rows: List[Dict[str, Any]]) -> Dict[str, int]:
    raw_count = len(rows)
    _, duplicate_count = dedupe_rows(rows)

    return {
        "raw_count": raw_count,
        "deduped_count": raw_count - duplicate_count,
        "duplicate_count": duplicate_count,
    }


def window_stats(rows: List[Dict[str, Any]], start_dt: datetime, end_dt: datetime) -> Dict[str, Any]:
    selected = window_rows(rows, start_dt, end_dt)
    deduped, duplicate_count = dedupe_rows(selected)
    groups = [row_group(row) for row in deduped]
    areas = [row_area(row) for row in deduped]
    locatable_count = sum(1 for row in deduped if row_addresses(row))
    personal_count = sum(1 for row in deduped if bool(row.get("personal_alert")) or bool(row.get("dispatcher_private")))
    hotzone_count = sum(1 for row in deduped if "hotzone" in [normalize_text(tag).casefold() for tag in (row.get("tags") or [])])
    last_signal = max((row["_parsed_timestamp"] for row in selected), default=None)
    raw_count = len(selected)
    deduped_count = len(deduped)

    return {
        "from": iso_dt(start_dt),
        "to": iso_dt(end_dt),
        "total_signals": deduped_count,
        "raw_count": raw_count,
        "deduped_count": deduped_count,
        "duplicate_count": duplicate_count,
        "locatable_signals": locatable_count,
        "hotzone_events": hotzone_count,
        "personal_alerts": personal_count,
        "unique_groups": len({group for group in groups if group}),
        "top_areas": top_items(areas),
        "top_groups": top_items(groups),
        "last_signal_time": iso_dt(last_signal) if last_signal else None,
    }


def build_stats() -> Dict[str, Any]:
    rows = read_notification_rows()
    now = datetime.now().replace(microsecond=0)
    current_start = now - CURRENT_WINDOW
    current_end = now
    previous_start = current_start - PREVIOUS_OFFSET
    previous_end = current_end - PREVIOUS_OFFSET

    current = window_stats(rows, current_start, current_end)
    previous = window_stats(rows, previous_start, previous_end)

    delta_keys = (
        "total_signals",
        "raw_count",
        "deduped_count",
        "duplicate_count",
        "locatable_signals",
        "hotzone_events",
        "personal_alerts",
        "unique_groups",
    )
    delta = {key: int(current[key]) - int(previous[key]) for key in delta_keys}

    return {
        "generated_at": iso_dt(now),
        "source_file_mtime": file_mtime(SOURCE_PATH),
        "source": str(SOURCE_PATH),
        "window_minutes": int(CURRENT_WINDOW.total_seconds() // 60),
        "comparison": "current_window_vs_yesterday_same_window",
        "source_row_count": len(rows),
        "raw_count": current["raw_count"],
        "deduped_count": current["deduped_count"],
        "duplicate_count": current["duplicate_count"],
        "current_24h": current,
        "previous_24h": previous,
        "delta": delta,
    }


def format_top(items: List[Dict[str, Any]]) -> str:
    if not items:
        return "--"
    return ", ".join(f"{safe_console_text(item['name'])} ({item['count']})" for item in items)


def print_window(title: str, stats: Dict[str, Any]) -> None:
    print(f"{title}:")
    print(f"- From: {stats['from']}")
    print(f"- To: {stats['to']}")
    print(f"- Total signals: {stats['total_signals']}")
    print(f"- Raw signals: {stats['raw_count']}")
    print(f"- Deduped signals: {stats['deduped_count']}")
    print(f"- Duplicate signals: {stats['duplicate_count']}")
    print(f"- Locatable signals: {stats['locatable_signals']}")
    print(f"- Hotzone events: {stats['hotzone_events']}")
    print(f"- Personal alerts: {stats['personal_alerts']}")
    print(f"- Unique groups: {stats['unique_groups']}")
    print(f"- Top areas: {format_top(stats['top_areas'])}")
    print(f"- Top groups: {format_top(stats['top_groups'])}")
    print(f"- Last signal time: {stats['last_signal_time'] or '--'}")


def print_debug_summary(stats: Dict[str, Any]) -> None:
    current = stats["current_24h"]
    previous = stats["previous_24h"]
    print("Debug summary:")
    print(f"- now: {stats['generated_at']}")
    print(f"- source_file_mtime: {stats.get('source_file_mtime') or '--'}")
    print(f"- current_start: {current['from']}")
    print(f"- current_end: {current['to']}")
    print(f"- previous_start: {previous['from']}")
    print(f"- previous_end: {previous['to']}")
    print(f"- source row count: {stats['source_row_count']}")
    print(f"- current raw count: {current['raw_count']}")
    print(f"- current deduped count: {current['deduped_count']}")
    print(f"- previous raw count: {previous['raw_count']}")
    print(f"- previous deduped count: {previous['deduped_count']}")
    print(f"- duplicate count: {current['duplicate_count']}")


def main() -> int:
    try:
        stats = build_stats()
    except FileNotFoundError as exc:
        print(str(exc))
        return 1

    OUTPUT_PATH.write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")

    print("DrivePilot Signal 24HR Compare")
    print("")
    print_debug_summary(stats)
    print("")
    print_window("Current Window", stats["current_24h"])
    print("")
    print_window("Yesterday Same Window", stats["previous_24h"])
    print("")
    print("Delta:")
    for key, value in stats["delta"].items():
        print(f"- {key.replace('_', ' ').title()}: {value}")
    print("")
    print(f"json path: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
