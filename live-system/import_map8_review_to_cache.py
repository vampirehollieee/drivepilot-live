from __future__ import annotations

import csv
import shutil
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REVIEW_PATH = ROOT / "live-data" / "map8_geocode_review.csv"
CACHE_PATH = ROOT / "live-data" / "address_geocode_cache.csv"
TRUE_VALUES = {"true", "1", "yes", "y"}
COORD_EPSILON = 0.000001


def is_true(value: str) -> bool:
    return str(value or "").strip().lower() in TRUE_VALUES


def parse_float(value: str) -> float | None:
    try:
        return float(str(value or "").strip())
    except (TypeError, ValueError):
        return None


def normalize_key(value: str) -> str:
    return "".join(str(value or "").strip().split())


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        return list(reader.fieldnames or []), list(reader)


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def cache_address_key(row: dict[str, str]) -> str:
    for field in ("address", "raw_address", "original_address", "normalized_address", "formatted_address", "match_key"):
        value = row.get(field)
        if value:
            return normalize_key(value)
    return ""


def nearly_same(lat_a: float, lng_a: float, lat_b: float, lng_b: float) -> bool:
    return abs(lat_a - lat_b) <= COORD_EPSILON and abs(lng_a - lng_b) <= COORD_EPSILON


def build_cache_row(fieldnames: list[str], review_row: dict[str, str], now_text: str) -> dict[str, str]:
    original_address = str(review_row.get("original_address") or "").strip()
    formatted_address = str(review_row.get("formatted_address") or "").strip()
    row = {field: "" for field in fieldnames}

    values = {
        "address": original_address,
        "raw_address": original_address,
        "original_address": original_address,
        "formatted_address": formatted_address,
        "normalized_address": formatted_address or original_address,
        "match_key": normalize_key(original_address),
        "lat": str(review_row.get("lat") or "").strip(),
        "lng": str(review_row.get("lng") or "").strip(),
        "city": str(review_row.get("city") or "").strip(),
        "town": str(review_row.get("town") or "").strip(),
        "source": "map8_review",
        "updated_at": now_text,
        "confidence": str(review_row.get("confidence_hint") or "").strip(),
        "note": "map8_review",
    }

    for field in fieldnames:
        if field in values:
            row[field] = values[field]
    return row


def main() -> int:
    print(f"input review file path: {REVIEW_PATH}")
    print(f"cache file path: {CACHE_PATH}")

    if not REVIEW_PATH.exists():
        print("error: review CSV does not exist")
        return 1
    if not CACHE_PATH.exists():
        print("error: address_geocode_cache.csv does not exist; import aborted")
        return 1

    review_fields, review_rows = read_csv(REVIEW_PATH)
    cache_fields, cache_rows = read_csv(CACHE_PATH)

    required_cache_fields = {"lat", "lng"}
    if not required_cache_fields.issubset(set(cache_fields)):
        print("error: address_geocode_cache.csv lacks lat/lng columns; import aborted")
        return 1

    backup_path = CACHE_PATH.with_name(f"address_geocode_cache.backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv")
    shutil.copy2(CACHE_PATH, backup_path)
    print(f"backup file path: {backup_path}")

    existing_by_key: dict[str, dict[str, str]] = {}
    for row in cache_rows:
        key = cache_address_key(row)
        if key and key not in existing_by_key:
            existing_by_key[key] = row

    imported_count = 0
    skipped_count = 0
    conflict_count = 0
    already_exists_count = 0
    error_count = 0
    new_rows: list[dict[str, str]] = []
    now_text = datetime.now().isoformat(timespec="seconds")

    for index, row in enumerate(review_rows, start=2):
        try:
            if not is_true(row.get("should_import", "")):
                skipped_count += 1
                continue

            original_address = str(row.get("original_address") or "").strip()
            lat_text = str(row.get("lat") or "").strip()
            lng_text = str(row.get("lng") or "").strip()
            error_text = str(row.get("error") or "").strip()
            lat = parse_float(lat_text)
            lng = parse_float(lng_text)

            if not original_address:
                skipped_count += 1
                print(f"skip row {index}: original_address is blank")
                continue
            if not lat_text or not lng_text:
                skipped_count += 1
                print(f"skip row {index}: lat/lng is blank ({original_address})")
                continue
            if lat is None or lng is None:
                skipped_count += 1
                print(f"skip row {index}: lat/lng is not numeric ({original_address})")
                continue
            if error_text:
                skipped_count += 1
                print(f"skip row {index}: error is not blank ({original_address}) - {error_text}")
                continue

            key = normalize_key(original_address)
            existing = existing_by_key.get(key)
            if existing:
                old_lat = parse_float(existing.get("lat", ""))
                old_lng = parse_float(existing.get("lng", ""))
                if old_lat is not None and old_lng is not None and nearly_same(old_lat, old_lng, lat, lng):
                    already_exists_count += 1
                    continue
                conflict_count += 1
                print(
                    "conflict: "
                    f"{original_address} old=({existing.get('lat', '')}, {existing.get('lng', '')}) "
                    f"new=({lat_text}, {lng_text})"
                )
                continue

            cache_row = build_cache_row(cache_fields, row, now_text)
            new_rows.append(cache_row)
            existing_by_key[key] = cache_row
            imported_count += 1
        except Exception as exc:  # keep the batch running for bad rows
            error_count += 1
            print(f"error row {index}: {exc}")

    if new_rows:
        write_csv(CACHE_PATH, cache_fields, cache_rows + new_rows)

    print(f"total review rows: {len(review_rows)}")
    print(f"imported count: {imported_count}")
    print(f"skipped count: {skipped_count}")
    print(f"conflict count: {conflict_count}")
    print(f"already exists count: {already_exists_count}")
    print(f"error count: {error_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
