from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from init_signal_db import DB_PATH, LIVE_DATA_DIR, init_db


NOTIFICATIONS_PATH = LIVE_DATA_DIR / "notifications.jsonl"


def first_value(item: Dict[str, Any], names: Tuple[str, ...]) -> Any:
    for name in names:
        value = item.get(name)
        if value is not None and str(value).strip() != "":
            return value
    return ""


def first_nested_place_value(item: Dict[str, Any], names: Tuple[str, ...]) -> Any:
    places = item.get("places")
    if not isinstance(places, list):
        return ""
    for place in places:
        if not isinstance(place, dict):
            continue
        value = first_value(place, names)
        if value != "":
            return value
    return ""


def normalize_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value).strip()


def normalize_timestamp(value: Any) -> str:
    text = normalize_text(value)
    if not text:
        return datetime.now().replace(microsecond=0).isoformat(sep=" ")

    candidates = [text]
    if text.endswith("Z"):
        candidates.append(text[:-1] + "+00:00")
    candidates.append(text.replace("/", "-"))

    formats = (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
    )
    for candidate in candidates:
        try:
            parsed = datetime.fromisoformat(candidate)
            return parsed.replace(microsecond=0).isoformat(sep=" ")
        except ValueError:
            pass
        for fmt in formats:
            try:
                parsed = datetime.strptime(candidate, fmt)
                return parsed.isoformat(sep=" ")
            except ValueError:
                pass
    return text


def to_float(value: Any) -> Optional[float]:
    if value is None or str(value).strip() == "":
        return None
    try:
        return float(str(value).strip())
    except ValueError:
        return None


def valid_lat_lng(lat: Optional[float], lng: Optional[float]) -> bool:
    if lat is None or lng is None:
        return False
    if lat == 0 or lng == 0:
        return False
    return -90 <= lat <= 90 and -180 <= lng <= 180


def tag_values(item: Dict[str, Any]) -> List[str]:
    tags = item.get("tags")
    if isinstance(tags, list):
        return [normalize_text(tag).lower() for tag in tags]
    if isinstance(tags, str):
        return [tags.lower()]
    return []


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    text = normalize_text(value).lower()
    return text in {"1", "true", "yes", "y"}


def make_event_uid(item: Dict[str, Any], ts: str, source: str, group_name: str, sender_name: str, raw_text: str) -> str:
    for name in ("id", "uid", "event_id"):
        value = normalize_text(item.get(name))
        if value:
            return value
    basis = "|".join((ts, source, group_name, sender_name, raw_text))
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()


def map_row(item: Dict[str, Any], created_at: str) -> Dict[str, Any]:
    ts = normalize_timestamp(first_value(item, ("timestamp", "time", "created_at", "received_at")))
    source = normalize_text(first_value(item, ("source", "app", "package")))
    group_name = normalize_text(first_value(item, ("group_name", "group", "title", "source")))
    sender_name = normalize_text(first_value(item, ("sender_name", "sender", "display_name")))
    raw_text = normalize_text(first_value(item, ("message", "text", "body", "raw_text", "content")))
    kind = normalize_text(first_value(item, ("kind", "type")))
    confidence = normalize_text(first_value(item, ("confidence",)))
    confidence_score = to_float(first_value(item, ("confidence_score", "score")))
    area = normalize_text(first_value(item, ("area", "district", "zone")))

    place_name = normalize_text(first_value(item, ("place", "place_name", "landmark", "address")))
    if not place_name:
        addresses = item.get("addresses")
        if isinstance(addresses, list) and addresses:
            place_name = normalize_text(addresses[0])
    if not place_name:
        place_name = normalize_text(first_nested_place_value(item, ("place", "place_name", "landmark", "address", "alias")))

    lat = to_float(first_value(item, ("lat", "latitude")))
    lng = to_float(first_value(item, ("lng", "longitude")))
    if lat is None:
        lat = to_float(first_nested_place_value(item, ("lat", "latitude")))
    if lng is None:
        lng = to_float(first_nested_place_value(item, ("lng", "longitude")))

    tags = tag_values(item)
    kind_text = kind.lower()
    confidence_text = confidence.lower()
    area_text = area.lower()
    combined_markers = " ".join(tags + [kind_text, confidence_text, area_text])

    is_locatable = int(
        valid_lat_lng(lat, lng)
        or confidence_text in {"high", "medium", "resolved", "locatable"}
        or (kind_text in {"place", "place_alias", "landmark", "start", "end"} and place_name != "")
        or boolish(first_value(item, ("is_locatable", "locatable", "resolved", "is_resolved")))
    )
    is_hotzone_event = int(
        boolish(first_value(item, ("is_hotzone_event", "is_hotzone", "hotzone")))
        or any(marker in combined_markers for marker in ("hotzone", "hot_zone", "熱區"))
    )
    is_personal_alert = int(
        boolish(first_value(item, ("personal_alert", "is_personal_alert", "dispatcher_private")))
        or any(marker in combined_markers for marker in ("personal_alert", "dispatcher_private"))
    )
    push_mode = normalize_text(first_value(item, ("push_mode", "mode")))

    event_uid = make_event_uid(item, ts, source, group_name, sender_name, raw_text)

    return {
        "event_uid": event_uid,
        "ts": ts,
        "source": source,
        "group_name": group_name,
        "sender_name": sender_name,
        "raw_text": raw_text,
        "kind": kind,
        "confidence": confidence,
        "confidence_score": confidence_score,
        "area": area,
        "place_name": place_name,
        "lat": lat,
        "lng": lng,
        "is_locatable": is_locatable,
        "is_hotzone_event": is_hotzone_event,
        "is_personal_alert": is_personal_alert,
        "push_mode": push_mode,
        "created_at": created_at,
    }


def count_signals(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COUNT(*) FROM signals").fetchone()[0])


def import_notifications() -> Dict[str, Any]:
    db_path = init_db()
    scanned = 0
    inserted = 0
    bad_json = 0
    skipped_duplicate = 0

    if not NOTIFICATIONS_PATH.exists():
        raise FileNotFoundError(f"notifications.jsonl not found: {NOTIFICATIONS_PATH}")

    sql = """
    INSERT OR IGNORE INTO signals (
        event_uid, ts, source, group_name, sender_name, raw_text, kind, confidence,
        confidence_score, area, place_name, lat, lng, is_locatable, is_hotzone_event,
        is_personal_alert, push_mode, created_at
    ) VALUES (
        :event_uid, :ts, :source, :group_name, :sender_name, :raw_text, :kind, :confidence,
        :confidence_score, :area, :place_name, :lat, :lng, :is_locatable, :is_hotzone_event,
        :is_personal_alert, :push_mode, :created_at
    )
    """

    created_at = datetime.now().replace(microsecond=0).isoformat(sep=" ")
    with sqlite3.connect(db_path) as conn:
        with NOTIFICATIONS_PATH.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                scanned += 1
                try:
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        bad_json += 1
                        continue
                except json.JSONDecodeError:
                    bad_json += 1
                    continue

                before = conn.total_changes
                conn.execute(sql, map_row(item, created_at))
                if conn.total_changes > before:
                    inserted += 1
                else:
                    skipped_duplicate += 1
        conn.commit()
        total_rows = count_signals(conn)

    return {
        "scanned_rows": scanned,
        "inserted_rows": inserted,
        "skipped_duplicate_rows": skipped_duplicate,
        "bad_json_rows": bad_json,
        "signals_table_total_rows": total_rows,
        "db_path": str(db_path),
    }


def main() -> int:
    result = import_notifications()
    print("DrivePilot notifications import complete")
    print(f"scanned rows: {result['scanned_rows']}")
    print(f"inserted rows: {result['inserted_rows']}")
    print(f"skipped duplicate rows: {result['skipped_duplicate_rows']}")
    print(f"bad json rows: {result['bad_json_rows']}")
    print(f"signals table total rows: {result['signals_table_total_rows']}")
    print(f"db path: {result['db_path']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
