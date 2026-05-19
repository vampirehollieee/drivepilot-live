from __future__ import annotations

import csv
import ctypes
import json
import re
from io import StringIO
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "live-data"

PLACES_PATH = DATA_DIR / "places.csv"
RESOLVED_PATH = DATA_DIR / "map_resolved_points.csv"
UNRESOLVED_PATH = DATA_DIR / "unresolved_addresses.csv"
CACHE_PATH = DATA_DIR / "address_geocode_cache.csv"

REVIEW_PATH = DATA_DIR / "parsed_address_classification_review.csv"
SUMMARY_PATH = DATA_DIR / "parsed_address_classification_audit.json"

SPECIAL_CASES = [
    "九如二路138號",
    "大同一路188號",
    "高雄市新興區大同一路188號",
]

FRONTEND_STATUS = {
    "high": "可定位",
    "medium": "部分定位",
    "low": "待確認",
}

REVIEW_FIELDS = [
    "time",
    "raw_text",
    "parsed_address",
    "frontend_status",
    "inferred_status",
    "in_map_resolved_points",
    "in_unresolved_addresses",
    "in_address_geocode_cache",
    "has_city",
    "has_district",
    "has_road",
    "has_house_number",
    "reason",
]


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            return [dict(row) for row in csv.DictReader(handle)]
    except PermissionError:
        text = read_text_shared(path)
        return [dict(row) for row in csv.DictReader(StringIO(text))]


def read_text_shared(path: Path) -> str:
    """Read a possibly live-written CSV on Windows without modifying it."""
    if not hasattr(ctypes, "windll"):
        raise

    kernel32 = ctypes.windll.kernel32
    generic_read = 0x80000000
    file_share_read = 0x00000001
    file_share_write = 0x00000002
    file_share_delete = 0x00000004
    open_existing = 3
    file_attribute_normal = 0x00000080
    invalid_handle_value = ctypes.c_void_p(-1).value

    handle = kernel32.CreateFileW(
        str(path),
        generic_read,
        file_share_read | file_share_write | file_share_delete,
        None,
        open_existing,
        file_attribute_normal,
        None,
    )
    if handle == invalid_handle_value:
        raise PermissionError(f"Unable to open locked file for shared read: {path}")

    chunks: list[bytes] = []
    try:
        buffer_size = 1024 * 1024
        buffer = ctypes.create_string_buffer(buffer_size)
        bytes_read = ctypes.c_ulong(0)
        while True:
            ok = kernel32.ReadFile(handle, buffer, buffer_size, ctypes.byref(bytes_read), None)
            if not ok:
                raise OSError(f"Unable to read locked file: {path}")
            if bytes_read.value == 0:
                break
            chunks.append(buffer.raw[: bytes_read.value])
    finally:
        kernel32.CloseHandle(handle)

    data = b"".join(chunks)
    return data.decode("utf-8-sig", errors="replace")


def parse_time(value: str) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text[:19], fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def compact_key(value: str) -> str:
    text = str(value or "").strip()
    text = text.replace("\u3000", " ")
    text = re.sub(r"\s+", "", text)
    text = re.sub(r"[,\uFF0C\u3002;；:：/|｜()\[\]（）【】\"']", "", text)
    return text


def add_index_key(index: set[str], value: str) -> None:
    key = compact_key(value)
    if key:
        index.add(key)


def build_index(rows: list[dict[str, str]], fields: list[str]) -> set[str]:
    index: set[str] = set()
    for row in rows:
        for field in fields:
            add_index_key(index, row.get(field, ""))
    return index


def build_resolved_latlng_index(rows: list[dict[str, str]]) -> set[str]:
    index: set[str] = set()
    for row in rows:
        try:
            float(str(row.get("lat", "")).strip())
            float(str(row.get("lng", "")).strip())
        except ValueError:
            continue
        for field in ("address", "normalized_address", "resolved_address"):
            add_index_key(index, row.get(field, ""))
    return index


def key_in_index(address: str, index: set[str]) -> bool:
    key = compact_key(address)
    if not key:
        return False
    if key in index:
        return True
    return any(key in candidate or candidate in key for candidate in index if len(candidate) >= 4)


def address_features(address: str) -> dict[str, bool]:
    text = str(address or "")
    has_city = "高雄市" in text
    has_district = re.search(r"[\u4e00-\u9fff]{1,4}區", text) is not None
    has_road = re.search(r"(路|街|大道|巷|弄)", text) is not None
    has_house_number = re.search(r"[0-9０-９一二三四五六七八九十百\-之]+(?:號|号)", text) is not None
    return {
        "has_city": has_city,
        "has_district": has_district,
        "has_road": has_road,
        "has_house_number": has_house_number,
    }


def infer_status(address: str, resolved: bool, features: dict[str, bool]) -> tuple[str, str]:
    if resolved:
        return "resolved", "address exists in map_resolved_points.csv with lat/lng"
    if features["has_road"] and features["has_house_number"]:
        if not features["has_city"] or not features["has_district"]:
            return "queryable_unresolved", "road plus house number; missing city/district may reduce resolver/cache matching"
        return "queryable_unresolved", "full address shape but not found in resolved points"
    if features["has_road"]:
        return "road_level_only", "road-like text without house number"
    if address:
        return "landmark_or_text", "no clear road plus house number pattern"
    return "unknown", "empty parsed address"


def frontend_status(confidence: str) -> str:
    return FRONTEND_STATUS.get(str(confidence or "").strip(), str(confidence or "").strip() or "待確認")


def to_review_row(
    place: dict[str, str],
    resolved_index: set[str],
    unresolved_index: set[str],
    cache_index: set[str],
) -> dict[str, str]:
    address = place.get("address") or place.get("parsed_address") or ""
    features = address_features(address)
    in_resolved = key_in_index(address, resolved_index)
    in_unresolved = key_in_index(address, unresolved_index)
    in_cache = key_in_index(address, cache_index)
    inferred, reason = infer_status(address, in_resolved, features)
    if in_cache and not in_resolved and inferred == "queryable_unresolved":
        reason += "; address exists in geocode cache but is not resolved in map output"
    if in_unresolved:
        reason += "; address appears in unresolved_addresses.csv"

    return {
        "time": place.get("timestamp", ""),
        "raw_text": place.get("text", ""),
        "parsed_address": address,
        "frontend_status": frontend_status(place.get("confidence", "")),
        "inferred_status": inferred,
        "in_map_resolved_points": str(in_resolved).lower(),
        "in_unresolved_addresses": str(in_unresolved).lower(),
        "in_address_geocode_cache": str(in_cache).lower(),
        "has_city": str(features["has_city"]).lower(),
        "has_district": str(features["has_district"]).lower(),
        "has_road": str(features["has_road"]).lower(),
        "has_house_number": str(features["has_house_number"]).lower(),
        "reason": reason,
    }


def latest_matching_place(places: list[dict[str, str]], address: str) -> dict[str, str]:
    key = compact_key(address)
    exact_matches = []
    fuzzy_matches = []
    for place in places:
        address_key = compact_key(place.get("address", ""))
        text_key = compact_key(place.get("text", ""))
        if key and address_key == key:
            exact_matches.append(place)
        elif key and (key in address_key or address_key in key or key in text_key):
            fuzzy_matches.append(place)
    matches = exact_matches or fuzzy_matches
    if not matches:
        return {"timestamp": "", "address": address, "confidence": "", "text": ""}
    matches.sort(key=lambda row: parse_time(row.get("timestamp", "")) or datetime.min)
    return matches[-1]


def main() -> int:
    places = read_csv_rows(PLACES_PATH)
    resolved_rows = read_csv_rows(RESOLVED_PATH)
    unresolved_rows = read_csv_rows(UNRESOLVED_PATH)
    cache_rows = read_csv_rows(CACHE_PATH)

    resolved_index = build_resolved_latlng_index(resolved_rows)
    unresolved_index = build_index(unresolved_rows, ["raw_address", "normalized_address", "match_key"])
    cache_index = build_index(cache_rows, ["raw_address", "normalized_address", "match_key"])

    now = datetime.now()
    window_start = now - timedelta(minutes=60)
    recent_places = []
    for place in places:
        timestamp = parse_time(place.get("timestamp", ""))
        if timestamp and window_start <= timestamp <= now:
            recent_places.append(place)

    review_rows = [
        to_review_row(place, resolved_index, unresolved_index, cache_index)
        for place in recent_places
    ]

    special_rows = []
    for address in SPECIAL_CASES:
        place = latest_matching_place(places, address)
        row = to_review_row(place, resolved_index, unresolved_index, cache_index)
        row["reason"] = f"special_case: {row['reason']}"
        special_rows.append((address, row))

    all_review_rows = review_rows + [row for _, row in special_rows]

    with REVIEW_PATH.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=REVIEW_FIELDS)
        writer.writeheader()
        writer.writerows(all_review_rows)

    inferred_counts = Counter(row["inferred_status"] for row in review_rows)
    frontend_counts = Counter(row["frontend_status"] for row in review_rows)
    queryable_unresolved = inferred_counts.get("queryable_unresolved", 0)

    summary = {
        "generated_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        "window_minutes": 60,
        "window_start": window_start.strftime("%Y-%m-%d %H:%M:%S"),
        "window_end": now.strftime("%Y-%m-%d %H:%M:%S"),
        "source_files": {
            "places": str(PLACES_PATH),
            "map_resolved_points": str(RESOLVED_PATH),
            "unresolved_addresses": str(UNRESOLVED_PATH),
            "address_geocode_cache": str(CACHE_PATH),
        },
        "total_places_rows": len(places),
        "recent_60min_places_rows": len(recent_places),
        "review_rows_written": len(all_review_rows),
        "frontend_status_counts": dict(sorted(frontend_counts.items())),
        "inferred_status_counts": dict(sorted(inferred_counts.items())),
        "queryable_unresolved_count": queryable_unresolved,
        "special_cases": {
            query: {
                "matched_parsed_address": row["parsed_address"],
                "time": row["time"],
                "frontend_status": row["frontend_status"],
                "inferred_status": row["inferred_status"],
                "in_map_resolved_points": row["in_map_resolved_points"],
                "in_unresolved_addresses": row["in_unresolved_addresses"],
                "in_address_geocode_cache": row["in_address_geocode_cache"],
                "has_city": row["has_city"],
                "has_district": row["has_district"],
                "has_road": row["has_road"],
                "has_house_number": row["has_house_number"],
                "reason": row["reason"],
            }
            for query, row in special_rows
        },
    }

    with SUMMARY_PATH.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"places file: {PLACES_PATH}")
    print(f"resolved file: {RESOLVED_PATH}")
    print(f"unresolved file: {UNRESOLVED_PATH}")
    print(f"cache file: {CACHE_PATH}")
    print(f"review CSV: {REVIEW_PATH}")
    print(f"summary JSON: {SUMMARY_PATH}")
    print(f"recent 60min rows: {len(recent_places)}")
    print(f"inferred_status_counts: {dict(sorted(inferred_counts.items()))}")
    print(f"frontend_status_counts: {dict(sorted(frontend_counts.items()))}")
    print(f"queryable_unresolved_count: {queryable_unresolved}")
    print("special cases:")
    for query, row in special_rows:
        print(
            "- {query} (matched {address}): frontend={frontend}, inferred={inferred}, "
            "resolved={resolved}, unresolved={unresolved}, cache={cache}, reason={reason}".format(
                query=query,
                address=row["parsed_address"],
                frontend=row["frontend_status"],
                inferred=row["inferred_status"],
                resolved=row["in_map_resolved_points"],
                unresolved=row["in_unresolved_addresses"],
                cache=row["in_address_geocode_cache"],
                reason=row["reason"],
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
