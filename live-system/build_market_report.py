from __future__ import annotations

import csv
import json
import re
import shutil
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DATA_DIR = PROJECT_ROOT / "live-data"

SIGNAL_STATS_PATH = DATA_DIR / "signal_stats_24h.json"
NOTIFICATIONS_PATH = DATA_DIR / "notifications.jsonl"
MARKER_HEALTH_PATH = DATA_DIR / "marker_health.json"
QUEUE_SUMMARY_PATH = DATA_DIR / "missing_coordinate_queue_summary.json"
MAP_POINTS_PATH = DATA_DIR / "map_points.csv"
QUEUE_PATH = DATA_DIR / "missing_coordinate_queue.csv"
OUTPUT_PATH = DATA_DIR / "market_report.json"

REPORT_VERSION = "v1.4.2"
HIGH_VALUE_KEYWORDS = ("急", "急件", "加價", "高速", "高鐵", "機場", "預約", "包車")
ADDRESS_HINTS = ("市", "區", "路", "街", "大道", "段", "巷", "弄", "衖", "號")


def configure_console() -> None:
    for stream_name in ("stdout", "stderr"):
        try:
            getattr(sys, stream_name).reconfigure(encoding="utf-8")
        except Exception:
            pass


def now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None


def csv_count(path: Path) -> int | None:
    if not path.exists():
        return None
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            return sum(1 for _ in csv.DictReader(handle))
    except OSError:
        return None


def number(value: Any, default: int = 0) -> int:
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def ratio(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return round(numerator / denominator, 4)


def backup_output() -> str:
    if not OUTPUT_PATH.exists():
        return ""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = OUTPUT_PATH.with_name(f"{OUTPUT_PATH.stem}.backup_{timestamp}{OUTPUT_PATH.suffix}")
    shutil.copy2(OUTPUT_PATH, backup_path)
    return str(backup_path.relative_to(PROJECT_ROOT))


def market_signal_level(deduped_count: Any, duplicate_ratio: float) -> str:
    if deduped_count is None:
        return "unknown"
    count = number(deduped_count)
    if duplicate_ratio >= 0.35:
        return "noisy"
    if count < 50:
        return "cold"
    if count < 200:
        return "normal"
    return "active"


def status_value(path: Path, payload: dict[str, Any] | None) -> str:
    if not path.exists() or payload is None:
        return "missing"
    return "ok"


def data_health_note(market_status: str, marker_status: str, queue_status: str) -> str:
    if market_status == "missing":
        return "24HR 資料缺失"
    if marker_status == "missing":
        return "Marker Health 缺失"
    if queue_status == "missing":
        return "Queue Summary 缺失"
    return "資料來源正常"


def operator_note(level: str, marker_status: str, queue_status: str) -> str:
    if level == "noisy":
        return "重複訊號偏高，判讀時注意洗頻"
    if level == "cold":
        return "訊號偏冷，僅供觀察"
    if level == "normal":
        return "目前市場訊號正常"
    if level == "active":
        return "目前市場訊號活躍"
    if marker_status == "ok" and queue_status == "ok":
        return "Marker 資料可用，Queue 可供後續人工補點"
    return "資料狀態待觀察"


def report_note(level: str, market_60m: dict[str, Any], hot_zones: list[dict[str, Any]], groups: list[dict[str, Any]]) -> str:
    if level == "noisy":
        return "重複訊號偏高，判讀時注意洗頻"
    if number(market_60m.get("signal_count")) > 0:
        if hot_zones or groups:
            return "近 60 分鐘有市場訊號，熱區與群組活躍資料已更新"
        return "近 60 分鐘有市場訊號"
    return "近 60 分鐘暫無明顯訊號"


def parse_time(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        try:
            timestamp = float(value)
            if timestamp > 10_000_000_000:
                timestamp = timestamp / 1000
            return datetime.fromtimestamp(timestamp)
        except (OSError, OverflowError, ValueError):
            return None
    text = str(value).strip()
    if not text:
        return None
    text = text.replace("T", " ").replace("Z", "").strip()
    if "." in text:
        text = text.split(".", 1)[0]
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y/%m/%d %H:%M"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def notification_time(row: dict[str, Any]) -> datetime | None:
    for key in ("time", "timestamp", "created_at", "datetime", "received_at"):
        parsed = parse_time(row.get(key))
        if parsed:
            return parsed
    return None


def compact_spaces(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def short_text(value: Any, limit: int = 40) -> str:
    text = compact_spaces(str(value or ""))
    return text[:limit]


def text_field(row: dict[str, Any]) -> str:
    for key in ("text", "message", "body", "content", "raw_text", "note"):
        value = row.get(key)
        if value:
            return str(value)
    raw = row.get("raw")
    if isinstance(raw, dict):
        title = str(raw.get("title") or "")
        body = str(raw.get("text") or "")
        return compact_spaces(f"{title} {body}")
    return ""


def group_name(row: dict[str, Any]) -> str:
    for key in ("source", "group", "group_name", "source_name"):
        value = row.get(key)
        if value:
            return compact_spaces(str(value))
    raw = row.get("raw")
    if isinstance(raw, dict) and raw.get("title"):
        return compact_spaces(str(raw["title"]))
    return "unknown"


def address_values(row: dict[str, Any]) -> list[str]:
    values: list[str] = []
    for key in ("address", "normalized_address", "resolved_address"):
        value = row.get(key)
        if value:
            values.append(str(value))
    addresses = row.get("addresses")
    if isinstance(addresses, list):
        values.extend(str(item) for item in addresses if item)
    places = row.get("places")
    if isinstance(places, list):
        for place in places:
            if isinstance(place, dict):
                for key in ("address", "normalized_address", "resolved_address"):
                    value = place.get(key)
                    if value:
                        values.append(str(value))
    return [compact_spaces(item) for item in values if compact_spaces(item)]


def area_name(row: dict[str, Any]) -> str:
    for key in ("district", "area", "town", "zone"):
        value = row.get(key)
        if value:
            return compact_spaces(str(value))
    for address in address_values(row):
        match = re.search(r"([\u4e00-\u9fff]{1,6}[區鄉鎮市])", address)
        if match:
            return match.group(1)
    return ""


def has_location_info(row: dict[str, Any]) -> bool:
    if address_values(row):
        return True
    for key in ("lat", "lng", "latitude", "longitude", "district", "area", "town", "zone"):
        if row.get(key):
            return True
    return False


def is_personal_alert(row: dict[str, Any]) -> bool:
    if bool(row.get("personal_alert")) or bool(row.get("dispatcher_private")):
        return True
    alert_type = str(row.get("alert_type") or row.get("type") or "").lower()
    return alert_type in {"personal_alert", "dispatcher_private"}


def high_value_label(row: dict[str, Any]) -> str:
    content = text_field(row)
    if is_personal_alert(row):
        return "個人提醒"
    if "機場" in content:
        return "機場"
    if "高鐵" in content:
        return "高鐵"
    if "預約" in content:
        return "預約"
    if "急件" in content or "急" in content:
        return "急件"
    if has_location_info(row):
        return "地址訊號"
    return "一般訊號"


def is_high_value(row: dict[str, Any]) -> bool:
    if has_location_info(row) or is_personal_alert(row):
        return True
    content = text_field(row)
    return any(keyword in content for keyword in HIGH_VALUE_KEYWORDS)


def read_notifications(path: Path) -> tuple[list[dict[str, Any]], int]:
    if not path.exists():
        return [], 0
    rows: list[dict[str, Any]] = []
    skipped = 0
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1
                    continue
                if isinstance(payload, dict):
                    rows.append(payload)
                else:
                    skipped += 1
    except OSError:
        return [], skipped
    return rows, skipped


def top_from_counter(counter: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    rows = [
        {"name": name, "count": data["count"], "last_seen": data["last_seen"]}
        for name, data in counter.items()
    ]
    rows.sort(key=lambda item: (number(item["count"]), str(item["last_seen"] or "")), reverse=True)
    return rows[:5]


def top_rows_from_signal_stats(signal: dict[str, Any] | None, paths: Iterable[tuple[str, str]]) -> list[dict[str, Any]]:
    if not signal:
        return []
    for parent_key, child_key in paths:
        parent = signal.get(parent_key)
        rows = parent.get(child_key) if isinstance(parent, dict) else signal.get(child_key)
        if not isinstance(rows, list) or not rows:
            continue
        result = []
        for row in rows[:5]:
            if not isinstance(row, dict):
                continue
            name = row.get("name") or row.get("area") or row.get("group") or row.get("source") or "unknown"
            result.append({
                "name": str(name),
                "count": number(row.get("count") or row.get("signals") or row.get("total")),
                "last_seen": row.get("last_seen") or row.get("last_signal_time") or signal.get("generated_at"),
            })
        if result:
            return result[:5]
    return []


def notification_analytics(rows: list[dict[str, Any]], now: datetime, signal: dict[str, Any] | None) -> dict[str, Any]:
    window_60m = now - timedelta(minutes=60)
    window_24h = now - timedelta(hours=24)
    rows_60m: list[tuple[dict[str, Any], datetime]] = []
    rows_24h: list[tuple[dict[str, Any], datetime]] = []

    for row in rows:
        seen_at = notification_time(row)
        if not seen_at:
            continue
        if seen_at >= window_60m:
            rows_60m.append((row, seen_at))
        if seen_at >= window_24h:
            rows_24h.append((row, seen_at))

    last_signal = max((seen_at for _, seen_at in rows_60m), default=None)
    market_60m = {
        "signal_count": len(rows_60m),
        "signals": len(rows_60m),
        "total_signals": len(rows_60m),
        "located_count": sum(1 for row, _ in rows_60m if has_location_info(row)),
        "located_addresses": sum(1 for row, _ in rows_60m if has_location_info(row)),
        "hot_event_count": 0,
        "hot_events": 0,
        "personal_alert_count": sum(1 for row, _ in rows_60m if is_personal_alert(row)),
        "personal_alerts": sum(1 for row, _ in rows_60m if is_personal_alert(row)),
        "last_signal_time": last_signal.strftime("%Y-%m-%d %H:%M:%S") if last_signal else None,
    }

    hot_zones = top_rows_from_signal_stats(signal, (("current_24h", "top_areas"), ("", "top_areas")))
    if not hot_zones:
        zone_counter: dict[str, dict[str, Any]] = defaultdict(lambda: {"count": 0, "last_seen": ""})
        for row, seen_at in rows_24h:
            area = area_name(row)
            if not area:
                continue
            zone_counter[area]["count"] += 1
            seen_text = seen_at.strftime("%Y-%m-%d %H:%M:%S")
            if seen_text > str(zone_counter[area]["last_seen"]):
                zone_counter[area]["last_seen"] = seen_text
        hot_zones = top_from_counter(zone_counter)

    active_groups = top_rows_from_signal_stats(signal, (("current_24h", "top_groups"), ("", "top_groups")))
    if not active_groups:
        group_counter: dict[str, dict[str, Any]] = defaultdict(lambda: {"count": 0, "last_seen": ""})
        for row, seen_at in rows_24h:
            name = group_name(row)
            group_counter[name]["count"] += 1
            seen_text = seen_at.strftime("%Y-%m-%d %H:%M:%S")
            if seen_text > str(group_counter[name]["last_seen"]):
                group_counter[name]["last_seen"] = seen_text
        active_groups = top_from_counter(group_counter)

    high_value_candidates: list[tuple[datetime, dict[str, Any]]] = []
    for row, seen_at in rows_24h:
        if is_high_value(row):
            high_value_candidates.append((seen_at, row))
    high_value_candidates.sort(key=lambda item: item[0], reverse=True)
    high_value_signals = []
    for seen_at, row in high_value_candidates[:5]:
        addresses = address_values(row)
        area_or_address = addresses[0] if addresses else (area_name(row) or "—")
        high_value_signals.append({
            "time": seen_at.strftime("%Y-%m-%d %H:%M:%S"),
            "area_or_address": area_or_address,
            "address": area_or_address,
            "source": group_name(row),
            "label": high_value_label(row),
            "summary": short_text(text_field(row), 40),
        })

    return {
        "market_60m": market_60m,
        "hot_zones": hot_zones[:5],
        "top_zones": hot_zones[:5],
        "active_groups": active_groups[:5],
        "top_groups": active_groups[:5],
        "high_value_signals": high_value_signals,
        "recent_high_value_signals": high_value_signals,
        "recent_signals": high_value_signals,
    }


def build_report() -> tuple[dict[str, Any], str, int]:
    signal = read_json(SIGNAL_STATS_PATH)
    marker = read_json(MARKER_HEALTH_PATH)
    queue = read_json(QUEUE_SUMMARY_PATH)
    notifications, skipped_invalid_rows = read_notifications(NOTIFICATIONS_PATH)
    analytics = notification_analytics(notifications, datetime.now(), signal)

    raw_count = number(signal.get("raw_count") if signal else None)
    deduped_value = signal.get("deduped_count") if signal else None
    deduped_count = number(deduped_value)
    duplicate_count = number(signal.get("duplicate_count") if signal else None)
    duplicate_ratio = ratio(duplicate_count, raw_count)

    map_points_count = csv_count(MAP_POINTS_PATH)
    queue_count = csv_count(QUEUE_PATH)

    market_status = status_value(SIGNAL_STATS_PATH, signal)
    marker_status = status_value(MARKER_HEALTH_PATH, marker)
    queue_status = status_value(QUEUE_SUMMARY_PATH, queue)
    overall = "ok" if all(item == "ok" for item in (market_status, marker_status, queue_status)) else "attention"
    level = market_signal_level(deduped_value, duplicate_ratio)

    summary = {
        "market_signal_level": level,
        "data_health_note": data_health_note(market_status, marker_status, queue_status),
        "operator_note": operator_note(level, marker_status, queue_status),
        "last_signal_time": analytics["market_60m"]["last_signal_time"],
        "report_note": report_note(level, analytics["market_60m"], analytics["hot_zones"], analytics["active_groups"]),
    }

    report = {
        "generated_at": now_text(),
        "report_version": REPORT_VERSION,
        "status": {
            "market_data": market_status,
            "marker_data": marker_status,
            "queue_data": queue_status,
            "overall": overall,
        },
        "market_24h": {
            "generated_at": signal.get("generated_at") if signal else None,
            "source_file_mtime": signal.get("source_file_mtime") if signal else None,
            "raw_count": raw_count,
            "deduped_count": deduped_count,
            "duplicate_count": duplicate_count,
            "duplicate_ratio": duplicate_ratio,
        },
        "market_60m": analytics["market_60m"],
        "hot_zones": analytics["hot_zones"],
        "top_zones": analytics["top_zones"],
        "active_groups": analytics["active_groups"],
        "top_groups": analytics["top_groups"],
        "group_activity": analytics["active_groups"],
        "high_value_signals": analytics["high_value_signals"],
        "recent_high_value_signals": analytics["recent_high_value_signals"],
        "recent_signals": analytics["recent_signals"],
        "markers": {
            "generated_at": marker.get("generated_at") if marker else None,
            "source_file_mtime": marker.get("source_file_mtime") if marker else None,
            "output_markers": number(marker.get("output_markers") if marker else map_points_count),
            "input_rows": number(marker.get("input_rows") if marker else None),
            "duplicate_merged": number(marker.get("duplicate_merged") if marker else None),
            "skipped_invalid_coordinates": number(marker.get("skipped_invalid_coordinates") if marker else None),
            "skipped_missing_address": number(marker.get("skipped_missing_address") if marker else None),
            "map_points_count": map_points_count,
        },
        "missing_coordinate_queue": {
            "total_candidates": number(queue.get("total_candidates") if queue else None),
            "good_count": number(queue.get("good_count") if queue else None),
            "suspicious_count": number(queue.get("suspicious_count") if queue else None),
            "rejected_count": number(queue.get("rejected_count") if queue else None),
            "final_queue_count": number(queue.get("final_queue_count") if queue else queue_count),
            "dedupe_merged_count": number(queue.get("dedupe_merged_count") if queue else None),
            "queue_count": queue_count,
        },
        "summary": summary,
        "diagnostics": {
            "notifications_file": str(NOTIFICATIONS_PATH.relative_to(PROJECT_ROOT)),
            "notifications_rows": len(notifications),
            "skipped_invalid_rows": skipped_invalid_rows,
        },
    }
    return report, backup_output(), skipped_invalid_rows


def main() -> int:
    configure_console()
    report, backup_path, skipped_invalid_rows = build_report()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"output_path={OUTPUT_PATH.relative_to(PROJECT_ROOT)}")
    print(f"backup_created={backup_path or '-'}")
    print(f"market_signal_level={report['summary']['market_signal_level']}")
    print(f"market_60m_signal_count={report['market_60m']['signal_count']}")
    print(f"market_60m_located_count={report['market_60m']['located_count']}")
    print(f"hot_zones_count={len(report['hot_zones'])}")
    print(f"active_groups_count={len(report['active_groups'])}")
    print(f"high_value_signals_count={len(report['high_value_signals'])}")
    print(f"skipped_invalid_rows={skipped_invalid_rows}")
    print(f"duplicate_ratio={report['market_24h']['duplicate_ratio']}")
    print(f"output_markers={report['markers']['output_markers']}")
    print(f"final_queue_count={report['missing_coordinate_queue']['final_queue_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
