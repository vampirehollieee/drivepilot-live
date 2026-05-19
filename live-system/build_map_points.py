from __future__ import annotations

import csv
import json
import re
import shutil
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "live-data"
INPUT_PATH = DATA_DIR / "map_resolved_points.csv"
OUTPUT_PATH = DATA_DIR / "map_points.csv"
HEALTH_PATH = DATA_DIR / "marker_health.json"

OUTPUT_FIELDS = [
    "marker_id",
    "address",
    "lat",
    "lng",
    "count",
    "first_seen",
    "last_seen",
    "source",
    "confidence",
    "sample_text",
    "time",
    "normalized_address",
    "resolved_address",
    "kind",
    "note",
    "text_summary",
]


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def clean_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").replace("\u3000", " ")).strip()


def compact_key(value: object) -> str:
    text = re.sub(r"\s+", "", clean_text(value))
    return re.sub(r"[,，。;|()\[\]\"']", "", text)


def first_value(row: dict[str, str], *names: str) -> str:
    for name in names:
        value = clean_text(row.get(name, ""))
        if value:
            return value
    return ""


def marker_key(row: dict[str, str]) -> str:
    return compact_key(first_value(row, "normalized_address", "resolved_address", "address"))


def parse_time(value: object) -> datetime | None:
    text = clean_text(value)
    if not text:
        return None
    normalized = text.replace("T", " ")
    for candidate, fmt in (
        (normalized[:19], "%Y-%m-%d %H:%M:%S"),
        (normalized[:16], "%Y-%m-%d %H:%M"),
        (normalized[:10], "%Y-%m-%d"),
    ):
        try:
            return datetime.strptime(candidate, fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def format_time(value: datetime | None) -> str:
    return value.strftime("%Y-%m-%d %H:%M:%S") if value else ""


def parse_float(value: object) -> float | None:
    try:
        return float(clean_text(value))
    except ValueError:
        return None


def valid_coordinate_pair(lat: object, lng: object) -> tuple[float, float] | None:
    lat_num = parse_float(lat)
    lng_num = parse_float(lng)
    if lat_num is None or lng_num is None:
        return None
    if not (-90 <= lat_num <= 90 and -180 <= lng_num <= 180):
        return None
    return lat_num, lng_num


def row_sample(row: dict[str, str]) -> str:
    return first_value(row, "text_summary", "note", "text")


def create_marker(marker_id: str, row: dict[str, str], lat: float, lng: float, seen_at: datetime | None) -> dict[str, str]:
    sample = row_sample(row)
    return {
        "marker_id": marker_id,
        "address": first_value(row, "address", "normalized_address", "resolved_address"),
        "lat": f"{lat:.6f}",
        "lng": f"{lng:.6f}",
        "count": "1",
        "first_seen": format_time(seen_at),
        "last_seen": format_time(seen_at),
        "source": first_value(row, "source") or "map_resolved_points",
        "confidence": first_value(row, "confidence") or "medium",
        "sample_text": sample,
        "time": format_time(seen_at),
        "normalized_address": first_value(row, "normalized_address", "address", "resolved_address"),
        "resolved_address": first_value(row, "resolved_address", "normalized_address", "address"),
        "kind": first_value(row, "kind", "type") or "place",
        "note": sample,
        "text_summary": sample,
    }


def merge_marker(marker: dict[str, str], row: dict[str, str], lat: float, lng: float, seen_at: datetime | None) -> None:
    marker["count"] = str(int(marker["count"]) + 1)

    first_seen = parse_time(marker["first_seen"])
    last_seen = parse_time(marker["last_seen"])
    if seen_at and (first_seen is None or seen_at < first_seen):
        marker["first_seen"] = format_time(seen_at)
    if seen_at and (last_seen is None or seen_at >= last_seen):
        sample = row_sample(row)
        marker.update(
            {
                "address": first_value(row, "address", "normalized_address", "resolved_address") or marker["address"],
                "lat": f"{lat:.6f}",
                "lng": f"{lng:.6f}",
                "last_seen": format_time(seen_at),
                "source": first_value(row, "source") or marker["source"],
                "confidence": first_value(row, "confidence") or marker["confidence"],
                "sample_text": sample or marker["sample_text"],
                "time": format_time(seen_at),
                "normalized_address": first_value(row, "normalized_address", "address", "resolved_address"),
                "resolved_address": first_value(row, "resolved_address", "normalized_address", "address"),
                "kind": first_value(row, "kind", "type") or marker["kind"],
                "note": sample or marker["note"],
                "text_summary": sample or marker["text_summary"],
            }
        )


def main() -> int:
    if not INPUT_PATH.exists():
        raise FileNotFoundError(f"Input file not found: {INPUT_PATH}")

    rows = read_csv(INPUT_PATH)
    generated_at = datetime.now()
    input_mtime = datetime.fromtimestamp(INPUT_PATH.stat().st_mtime)

    skipped_invalid_coordinates = 0
    skipped_missing_address = 0
    markers_by_key: dict[str, dict[str, str]] = {}

    for row in rows:
        key = marker_key(row)
        if not key:
            skipped_missing_address += 1
            continue

        coordinates = valid_coordinate_pair(row.get("lat"), row.get("lng"))
        if coordinates is None:
            skipped_invalid_coordinates += 1
            continue

        lat, lng = coordinates
        seen_at = parse_time(first_value(row, "time", "timestamp"))
        existing = markers_by_key.get(key)
        if existing:
            merge_marker(existing, row, lat, lng, seen_at)
            continue

        marker_id = f"marker-{len(markers_by_key) + 1:05d}"
        markers_by_key[key] = create_marker(marker_id, row, lat, lng, seen_at)

    output_rows = sorted(
        markers_by_key.values(),
        key=lambda item: (parse_time(item["last_seen"]) or datetime.min, item["marker_id"]),
    )
    valid_input_rows = len(rows) - skipped_invalid_coordinates - skipped_missing_address
    duplicate_merged = max(0, valid_input_rows - len(output_rows))

    backup_created = ""
    if OUTPUT_PATH.exists():
        timestamp = generated_at.strftime("%Y%m%d_%H%M%S")
        backup_path = DATA_DIR / f"map_points.backup_{timestamp}.csv"
        shutil.copy2(OUTPUT_PATH, backup_path)
        backup_created = backup_path.name

    write_csv(OUTPUT_PATH, output_rows)

    health = {
        "generated_at": format_time(generated_at),
        "source_file": str(INPUT_PATH),
        "source_file_mtime": format_time(input_mtime),
        "input_rows": len(rows),
        "output_markers": len(output_rows),
        "skipped_invalid_coordinates": skipped_invalid_coordinates,
        "skipped_missing_address": skipped_missing_address,
        "duplicate_merged": duplicate_merged,
        "backup_created": backup_created,
    }
    write_json(HEALTH_PATH, health)

    print(f"input file path: {INPUT_PATH}")
    print(f"output map_points path: {OUTPUT_PATH}")
    print(f"marker health path: {HEALTH_PATH}")
    print(f"input_rows: {health['input_rows']}")
    print(f"output_markers: {health['output_markers']}")
    print(f"skipped_invalid_coordinates: {health['skipped_invalid_coordinates']}")
    print(f"skipped_missing_address: {health['skipped_missing_address']}")
    print(f"duplicate_merged: {health['duplicate_merged']}")
    print(f"backup_created: {backup_created or '(none)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
