from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DATA_DIR = PROJECT_ROOT / "live-data"
CONFIG_DIR = PROJECT_ROOT / "config"

QUEUE_PATH = DATA_DIR / "missing_coordinate_queue.csv"
CACHE_PATH = DATA_DIR / "address_geocode_cache.csv"
REVIEW_PATH = DATA_DIR / "map8_geocode_review.csv"
MAP_RESOLVED_PATH = DATA_DIR / "map_resolved_points.csv"
MAP_POINTS_PATH = DATA_DIR / "map_points.csv"
BUILD_MAP_POINTS_SCRIPT = SCRIPT_DIR / "build_map_points.py"
API_KEY_PATH = CONFIG_DIR / "map8_api_key.txt"

MAP8_STANDARDIZATION_URL = "https://api.map8.zone/v2/address/standardization"
MAP8_GEOCODE_URL = "https://api.map8.zone/v2/place/geocode/json"
REQUEST_TIMEOUT_SECONDS = 15
DEFAULT_LIMIT = 30
MAX_LIMIT = 50

REVIEW_FIELDS = [
    "original_address",
    "formatted_address",
    "lat",
    "lng",
    "city",
    "town",
    "api_type",
    "status",
    "confidence_hint",
    "should_import",
    "error",
]
CACHE_FIELDS = [
    "raw_address",
    "normalized_address",
    "match_key",
    "lat",
    "lng",
    "source",
    "confidence",
    "note",
    "updated_at",
]
MAP_RESOLVED_FIELDS = [
    "time",
    "group",
    "address",
    "normalized_address",
    "lat",
    "lng",
    "source",
    "confidence",
    "kind",
    "text_summary",
]

ROAD_TOKENS = ("路", "街", "大道", "段", "巷", "弄", "衖")
DIRTY_TOKENS = (
    "http",
    "line.me",
    "@",
    "回金",
    "匯款",
    "銀行",
    "帳號",
    "戶名",
    "UBIKE",
    "系統派單",
    "上車",
    "下車",
    "客下",
    "備註",
)
BAD_SUFFIXES = ("莊", "會館", "備註")
KAOHSIUNG_LAT = (22.3, 23.0)
KAOHSIUNG_LNG = (120.0, 120.7)


def configure_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def clean_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").replace("\u3000", " ")).strip()


def compact_key(value: object) -> str:
    return re.sub(r"\s+", "", clean_text(value)).casefold()


def parse_float(value: object) -> float | None:
    try:
        return float(clean_text(value))
    except ValueError:
        return None


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    if not path.exists():
        return [], []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        return list(reader.fieldnames or []), list(reader)


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def backup_file(path: Path, timestamp: str) -> str:
    if not path.exists():
        return ""
    backup_path = path.with_name(f"{path.stem}.backup_{timestamp}{path.suffix}")
    shutil.copy2(path, backup_path)
    return str(backup_path.relative_to(PROJECT_ROOT))


def data_row_count(path: Path) -> int:
    _, rows = read_csv(path)
    return len(rows)


def load_api_key() -> str | None:
    if not API_KEY_PATH.exists():
        print("error: config/map8_api_key.txt not found")
        return None
    key = API_KEY_PATH.read_text(encoding="utf-8").strip()
    if not key:
        print("error: config/map8_api_key.txt is blank")
        return None
    return key


def build_url(base_url: str, params: dict[str, Any]) -> str:
    return base_url + "?" + urllib.parse.urlencode(params)


def request_json(base_url: str, params: dict[str, Any]) -> tuple[int | None, dict[str, Any] | None, str | None]:
    request = urllib.request.Request(
        build_url(base_url, params),
        method="GET",
        headers={"Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", errors="replace")
            try:
                return response.status, json.loads(body), None
            except json.JSONDecodeError:
                return response.status, None, "JSON parse failed"
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        payload = None
        try:
            payload = json.loads(body) if body.strip() else None
        except json.JSONDecodeError:
            pass
        reason = getattr(error, "reason", "") or error.msg or "HTTP error"
        return error.code, payload, f"HTTP {error.code}: {reason}"
    except urllib.error.URLError as error:
        reason = getattr(error, "reason", None)
        return None, None, f"Request failed: {reason or 'URL error'}"
    except TimeoutError:
        return None, None, "Request timeout"
    except Exception as error:
        return None, None, f"Request failed: {error.__class__.__name__}"


def first_result(payload: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None
    results = payload.get("results")
    if isinstance(results, list) and results and isinstance(results[0], dict):
        return results[0]
    result = payload.get("result")
    if isinstance(result, dict):
        return result
    return None


def nested_get(data: Any, path: list[str]) -> Any:
    current = data
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def candidate_address_ok(address: str) -> bool:
    text = clean_text(address)
    lower = text.casefold()
    if not text or len(text) > 40:
        return False
    if "號" not in text:
        return False
    if not any(token in text for token in ROAD_TOKENS):
        return False
    if any(token.casefold() in lower for token in DIRTY_TOKENS):
        return False
    if re.match(r"^\d{2,}(?!段|巷|弄|衖|號)", text):
        return False
    if any(text.endswith(token) for token in BAD_SUFFIXES):
        return False
    return True


def extract_road_name(address: str) -> str:
    text = clean_text(address)
    text = re.sub(r"^.*[縣市].*[區鄉鎮]", "", text)
    text = re.sub(r"^Demo City", "", text)
    text = re.sub(r"^.*[區鄉鎮]", "", text)
    match = re.search(r"([\u4e00-\u9fffA-Za-z0-9一二三四五六七八九十]+(?:大道|路|街))", text)
    return match.group(1) if match else ""


def geocode_address(address: str, api_key: str) -> dict[str, Any]:
    http_status, payload, request_error = request_json(
        MAP8_STANDARDIZATION_URL,
        {"key": api_key, "query": address, "en": "false"},
    )
    result = first_result(payload)
    response_status = payload.get("status") if isinstance(payload, dict) else None
    coordinates = nested_get(result, ["geom", "coordinates"])
    lng = lat = None
    if isinstance(coordinates, list) and len(coordinates) >= 2:
        lng = parse_float(coordinates[0])
        lat = parse_float(coordinates[1])

    error = request_error
    if error is None and result is None:
        error = "results empty"
    elif error is None and (lat is None or lng is None):
        error = "lat/lng not found in response"

    standard = {
        "api_type": "standardization",
        "http_status": http_status,
        "status": response_status or (f"HTTP {http_status}" if http_status else ""),
        "formatted_address": result.get("formatted_address") if isinstance(result, dict) else "",
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else "",
        "town": result.get("town") if isinstance(result, dict) else "",
        "error": error or "",
    }
    if not standard["error"]:
        return standard

    http_status, payload, request_error = request_json(
        MAP8_GEOCODE_URL,
        {"key": api_key, "address": address},
    )
    result = first_result(payload)
    response_status = payload.get("status") if isinstance(payload, dict) else None
    lat = parse_float(nested_get(result, ["geometry", "location", "lat"]))
    lng = parse_float(nested_get(result, ["geometry", "location", "lng"]))

    error = request_error
    if error is None and result is None:
        error = "results empty"
    elif error is None and (lat is None or lng is None):
        error = "lat/lng not found in response"

    return {
        "api_type": "geocode_fallback",
        "http_status": http_status,
        "status": response_status or (f"HTTP {http_status}" if http_status else ""),
        "formatted_address": result.get("formatted_address") if isinstance(result, dict) else "",
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else "",
        "town": result.get("town") if isinstance(result, dict) else "",
        "error": error or "",
    }


def confidence_hint(result: dict[str, Any]) -> str:
    if result.get("api_type") == "standardization" and result.get("lat") is not None and result.get("lng") is not None:
        if result.get("formatted_address"):
            return "standardized"
        return "standardized_review"
    if result.get("api_type") == "geocode_fallback" and result.get("lat") is not None and result.get("lng") is not None:
        return "geocode_fallback_review"
    if result.get("city") or result.get("town"):
        return "no_coordinates"
    return "api_failed"


def is_high_confidence(original: str, result: dict[str, Any]) -> bool:
    hint = confidence_hint(result)
    lat = result.get("lat")
    lng = result.get("lng")
    formatted = clean_text(result.get("formatted_address"))
    road_name = extract_road_name(original)
    return (
        result.get("status") == "OK"
        and hint == "standardized"
        and result.get("city") == "Demo City"
        and bool(clean_text(result.get("town")))
        and isinstance(lat, float)
        and isinstance(lng, float)
        and KAOHSIUNG_LAT[0] <= lat <= KAOHSIUNG_LAT[1]
        and KAOHSIUNG_LNG[0] <= lng <= KAOHSIUNG_LNG[1]
        and bool(formatted)
        and "號" in formatted
        and bool(road_name)
        and road_name in formatted
        and candidate_address_ok(original)
    )


def make_review_row(original: str, result: dict[str, Any]) -> dict[str, str]:
    return {
        "original_address": original,
        "formatted_address": clean_text(result.get("formatted_address")),
        "lat": "" if result.get("lat") is None else str(result.get("lat")),
        "lng": "" if result.get("lng") is None else str(result.get("lng")),
        "city": clean_text(result.get("city")),
        "town": clean_text(result.get("town")),
        "api_type": clean_text(result.get("api_type")),
        "status": clean_text(result.get("status")),
        "confidence_hint": confidence_hint(result),
        "should_import": "false",
        "error": clean_text(result.get("error")),
    }


def cache_key(row: dict[str, str]) -> str:
    for field in ("raw_address", "address", "original_address", "normalized_address", "formatted_address", "match_key"):
        value = row.get(field)
        if value:
            return compact_key(value)
    return ""


def read_existing_keys(cache_rows: list[dict[str, str]], review_rows: list[dict[str, str]]) -> set[str]:
    keys = {cache_key(row) for row in cache_rows}
    for row in review_rows:
        if clean_text(row.get("should_import")).casefold() == "true":
            keys.add(compact_key(row.get("original_address")))
    return {key for key in keys if key}


def filter_review_rows(review_rows: list[dict[str, str]], cached_keys: set[str]) -> list[dict[str, str]]:
    filtered: list[dict[str, str]] = []
    seen: set[str] = set()
    for row in review_rows:
        key = compact_key(row.get("original_address"))
        if not key or key in cached_keys or key in seen:
            continue
        filtered.append(row)
        seen.add(key)
    return filtered


def select_candidates(limit: int, existing_keys: set[str]) -> tuple[list[dict[str, str]], int, int]:
    _, rows = read_csv(QUEUE_PATH)
    selected: list[dict[str, str]] = []
    seen: set[str] = set()
    skipped_cached = 0
    skipped_dirty = 0

    def rank(row: dict[str, str]) -> tuple[int, int]:
        quality = clean_text(row.get("quality")).casefold()
        quality_rank = 0 if quality == "good" else 1
        try:
            count_rank = -int(float(clean_text(row.get("count")) or "0"))
        except ValueError:
            count_rank = 0
        return quality_rank, count_rank

    for row in sorted(rows, key=rank):
        if len(selected) >= limit:
            break
        address = clean_text(row.get("address"))
        key = compact_key(address)
        if not candidate_address_ok(address):
            skipped_dirty += 1
            continue
        if key in existing_keys or key in seen:
            skipped_cached += 1
            continue
        selected.append(row)
        seen.add(key)
    return selected, skipped_cached, skipped_dirty


def build_cache_row(fieldnames: list[str], original: str, result: dict[str, Any], now_text: str) -> dict[str, str]:
    formatted = clean_text(result.get("formatted_address"))
    values = {
        "address": original,
        "raw_address": original,
        "original_address": original,
        "formatted_address": formatted,
        "normalized_address": formatted or original,
        "match_key": compact_key(original),
        "lat": str(result.get("lat") or ""),
        "lng": str(result.get("lng") or ""),
        "city": clean_text(result.get("city")),
        "town": clean_text(result.get("town")),
        "source": "auto_map8",
        "confidence": "standardized",
        "note": "auto_map8_high_confidence",
        "updated_at": now_text,
    }
    return {field: values.get(field, "") for field in fieldnames}


def build_resolved_row(queue_row: dict[str, str], result: dict[str, Any]) -> dict[str, str]:
    original = clean_text(queue_row.get("address"))
    formatted = clean_text(result.get("formatted_address")) or original
    signal_time = clean_text(queue_row.get("last_seen")) or clean_text(queue_row.get("time"))
    group = clean_text(queue_row.get("source_detail")) or "auto_map8_coordinate_import"
    kind = clean_text(queue_row.get("kind")) or "place"
    text_summary = clean_text(queue_row.get("sample_text")) or clean_text(queue_row.get("text_summary"))
    return {
        "time": signal_time,
        "group": group,
        "address": original,
        "normalized_address": formatted,
        "lat": str(result.get("lat") or ""),
        "lng": str(result.get("lng") or ""),
        "source": "address_geocode_cache",
        "confidence": "high",
        "kind": kind,
        "text_summary": text_summary,
    }


def ensure_fields(existing_fields: list[str], fallback_fields: list[str]) -> list[str]:
    fields = list(existing_fields or fallback_fields)
    for field in fallback_fields:
        if field not in fields:
            fields.append(field)
    return fields


def run_build_map_points() -> int:
    command = [sys.executable, str(BUILD_MAP_POINTS_SCRIPT)]
    completed = subprocess.run(command, cwd=str(PROJECT_ROOT), check=False)
    return completed.returncode


def load_queue_by_address() -> dict[str, dict[str, str]]:
    _, rows = read_csv(QUEUE_PATH)
    queue_by_address: dict[str, dict[str, str]] = {}
    for row in rows:
        key = compact_key(row.get("address"))
        if key and key not in queue_by_address:
            queue_by_address[key] = row
    return queue_by_address


def is_auto_map8_resolved_row(row: dict[str, str]) -> bool:
    group = clean_text(row.get("group"))
    text_summary = clean_text(row.get("text_summary"))
    return group == "auto_map8_coordinate_import" or "auto MAP8 high-confidence import" in text_summary


def repair_auto_map8_time() -> int:
    configure_console()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    resolved_fields, resolved_rows = read_csv(MAP_RESOLVED_PATH)
    resolved_fields = ensure_fields(resolved_fields, MAP_RESOLVED_FIELDS)
    queue_by_address = load_queue_by_address()

    matched_count = 0
    repaired_count = 0
    missing_queue_count = 0
    for row in resolved_rows:
        if not is_auto_map8_resolved_row(row):
            continue
        matched_count += 1
        queue_row = queue_by_address.get(compact_key(row.get("address")))
        if not queue_row:
            missing_queue_count += 1
            continue

        before = dict(row)
        signal_time = clean_text(queue_row.get("last_seen")) or clean_text(queue_row.get("time"))
        group = clean_text(queue_row.get("source_detail"))
        kind = clean_text(queue_row.get("kind"))
        text_summary = clean_text(queue_row.get("sample_text")) or clean_text(queue_row.get("text_summary"))

        if signal_time:
            row["time"] = signal_time
        if group:
            row["group"] = group
        if kind:
            row["kind"] = kind
        if text_summary:
            row["text_summary"] = text_summary

        if any(row.get(field, "") != before.get(field, "") for field in ("time", "group", "kind", "text_summary")):
            repaired_count += 1

    backup_path = ""
    build_status = 0
    if repaired_count:
        backup_path = backup_file(MAP_RESOLVED_PATH, timestamp)
        write_csv(MAP_RESOLVED_PATH, resolved_fields, resolved_rows)
        build_status = run_build_map_points()

    print("mode=repair-auto-map8-time")
    print(f"matched_auto_map8_rows={matched_count}")
    print(f"repaired_count={repaired_count}")
    print(f"missing_queue_count={missing_queue_count}")
    print(f"backup_path={backup_path or '-'}")
    print(f"output_path={MAP_RESOLVED_PATH.relative_to(PROJECT_ROOT)};{MAP_POINTS_PATH.relative_to(PROJECT_ROOT)}")
    print(f"build_map_points_status={build_status}")
    return 0 if build_status == 0 else build_status


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Auto import high-confidence MAP8 coordinates into DrivePilot cache.")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--repair-auto-map8-time", action="store_true")
    args = parser.parse_args()
    if args.limit < 1:
        args.limit = 1
    if args.limit > MAX_LIMIT:
        args.limit = MAX_LIMIT
    return args


def main() -> int:
    configure_console()
    args = parse_args()
    if args.repair_auto_map8_time:
        return repair_auto_map8_time()

    api_key = load_api_key()
    if api_key is None:
        return 1

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    now_text = datetime.now().isoformat(timespec="seconds")
    source_file = str(QUEUE_PATH.relative_to(PROJECT_ROOT))
    cache_before_count = data_row_count(CACHE_PATH)
    map_points_before_count = data_row_count(MAP_POINTS_PATH)

    cache_fields, cache_rows = read_csv(CACHE_PATH)
    review_fields, review_rows = read_csv(REVIEW_PATH)
    resolved_fields, resolved_rows = read_csv(MAP_RESOLVED_PATH)
    cache_fields = ensure_fields(cache_fields, CACHE_FIELDS)
    review_fields = ensure_fields(review_fields, REVIEW_FIELDS)
    resolved_fields = ensure_fields(resolved_fields, MAP_RESOLVED_FIELDS)
    existing_keys = read_existing_keys(cache_rows, review_rows)

    selected, skipped_cached_count, skipped_dirty_count = select_candidates(args.limit, existing_keys)

    backup_paths = [
        backup_file(CACHE_PATH, timestamp),
        backup_file(REVIEW_PATH, timestamp),
        backup_file(MAP_POINTS_PATH, timestamp),
    ]
    backup_paths = [path for path in backup_paths if path]

    map8_ok_count = 0
    auto_imported_count = 0
    review_only_count = 0
    new_cache_rows: list[dict[str, str]] = []
    new_review_rows: list[dict[str, str]] = []
    new_resolved_rows: list[dict[str, str]] = []

    for queue_row in selected:
        address = clean_text(queue_row.get("address"))
        result = geocode_address(address, api_key)
        if result.get("status") == "OK":
            map8_ok_count += 1
        if is_high_confidence(address, result):
            new_cache_rows.append(build_cache_row(cache_fields, address, result, now_text))
            new_resolved_rows.append(build_resolved_row(queue_row, result))
            existing_keys.add(compact_key(address))
            auto_imported_count += 1
        else:
            new_review_rows.append(make_review_row(address, result))
            review_only_count += 1

    updated_cache_rows = cache_rows + new_cache_rows
    if new_cache_rows:
        write_csv(CACHE_PATH, cache_fields, updated_cache_rows)
    cached_keys_after = {cache_key(row) for row in updated_cache_rows}
    updated_review_rows = filter_review_rows(review_rows + new_review_rows, cached_keys_after)
    if new_review_rows or len(updated_review_rows) != len(review_rows):
        write_csv(REVIEW_PATH, review_fields, updated_review_rows)
    if new_resolved_rows:
        write_csv(MAP_RESOLVED_PATH, resolved_fields, resolved_rows + new_resolved_rows)
        build_status = run_build_map_points()
    else:
        build_status = 0

    cache_after_count = data_row_count(CACHE_PATH)
    map_points_after_count = data_row_count(MAP_POINTS_PATH)

    print(f"source_file={source_file}")
    print(f"selected_count={len(selected)}")
    print(f"map8_ok_count={map8_ok_count}")
    print(f"auto_imported_count={auto_imported_count}")
    print(f"review_only_count={review_only_count}")
    print(f"skipped_cached_count={skipped_cached_count}")
    print(f"skipped_dirty_count={skipped_dirty_count}")
    print(f"cache_before_count={cache_before_count}")
    print(f"cache_after_count={cache_after_count}")
    print(f"map_points_before_count={map_points_before_count}")
    print(f"map_points_after_count={map_points_after_count}")
    print(f"backup_path={';'.join(backup_paths) if backup_paths else '-'}")
    print(f"output_path={CACHE_PATH.relative_to(PROJECT_ROOT)};{REVIEW_PATH.relative_to(PROJECT_ROOT)};{MAP_POINTS_PATH.relative_to(PROJECT_ROOT)}")
    print(f"build_map_points_status={build_status}")
    return 0 if build_status == 0 else build_status


if __name__ == "__main__":
    raise SystemExit(main())
