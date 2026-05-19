from __future__ import annotations

import csv
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_DIR = PROJECT_ROOT / "config"
LIVE_DATA_DIR = PROJECT_ROOT / "live-data"
API_KEY_PATH = CONFIG_DIR / "map8_api_key.txt"
MISSING_QUEUE_PATH = LIVE_DATA_DIR / "missing_coordinate_queue.csv"
FALLBACK_INPUT_PATH = LIVE_DATA_DIR / "unresolved_addresses.csv"
REVIEW_PATH = LIVE_DATA_DIR / "map8_geocode_review.csv"
CACHE_PATH = LIVE_DATA_DIR / "address_geocode_cache.csv"
OUTPUT_PATH = LIVE_DATA_DIR / "map8_geocode_review.csv"

MAP8_STANDARDIZATION_URL = "https://api.map8.zone/v2/address/standardization"
MAP8_GEOCODE_URL = "https://api.map8.zone/v2/place/geocode/json"
REQUEST_TIMEOUT_SECONDS = 15
MAX_ROWS = 10

ADDRESS_FIELDS = ("address", "original_address", "raw_address", "text", "query")
CACHE_ADDRESS_FIELDS = ("original_address", "address", "formatted_address")
DIRTY_TOKENS = ("line.me", "http://", "https://", "@", "回金", "匯款", "銀行", "帳號", "轉帳", "街口", "收款")
ADDRESS_TOKENS = ("縣", "市", "區", "鄉", "鎮", "路", "街", "巷", "弄", "號", "大道")
OUTPUT_FIELDS = (
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
)


def configure_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def load_api_key() -> Optional[str]:
    if not API_KEY_PATH.exists():
        print("請建立 config/map8_api_key.txt 並放入 MAP8 API Key")
        return None
    key = API_KEY_PATH.read_text(encoding="utf-8").strip()
    if not key:
        print("config/map8_api_key.txt 是空白，請放入 MAP8 API Key")
        return None
    return key


def build_url(base_url: str, params: Dict[str, Any]) -> str:
    return base_url + "?" + urllib.parse.urlencode(params)


def request_json(base_url: str, params: Dict[str, Any]) -> Tuple[Optional[int], Optional[Dict[str, Any]], Optional[str]]:
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


def first_result(payload: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(payload, dict):
        return None
    results = payload.get("results")
    if isinstance(results, list) and results and isinstance(results[0], dict):
        return results[0]
    result = payload.get("result")
    if isinstance(result, dict):
        return result
    return None


def nested_get(data: Any, path: List[str]) -> Any:
    current = data
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def to_number(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def row_value(row: Dict[str, Any], field: str) -> str:
    value = row.get(field)
    return str(value).strip() if value is not None else ""


def normalize_address_key(value: str) -> str:
    return re.sub(r"\s+", "", str(value or "")).strip().casefold()


def is_dirty_address(value: str) -> bool:
    text = str(value or "").strip()
    lower = text.casefold()
    return any(token.casefold() in lower for token in DIRTY_TOKENS)


def looks_like_address(value: str) -> bool:
    text = str(value or "").strip()
    if not text:
        return False
    if is_dirty_address(text):
        return False
    if len(text) > 50:
        return False
    if len(text) > 30 and not any(token in text for token in ("路", "街", "巷", "弄", "號", "大道")):
        return False
    return any(token in text for token in ADDRESS_TOKENS)


def detect_address_field(fieldnames: Optional[List[str]]) -> Optional[str]:
    names = set(fieldnames or [])
    for field in ADDRESS_FIELDS:
        if field in names:
            return field
    return None


def read_address_keys(path: Path, fields: Tuple[str, ...], import_only: bool = False) -> Set[str]:
    keys: Set[str] = set()
    if not path.exists():
        return keys
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                if import_only and row_value(row, "should_import").casefold() != "true":
                    continue
                for field in fields:
                    value = row_value(row, field)
                    if value:
                        keys.add(normalize_address_key(value))
    except Exception as error:
        print(f"warning: failed to read {path.relative_to(PROJECT_ROOT)}: {error}")
    return keys


def sorted_candidate_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    def rank(row: Dict[str, Any]) -> Tuple[int, int]:
        quality = row_value(row, "quality").casefold()
        if quality == "good":
            quality_rank = 0
        elif not quality:
            quality_rank = 1
        else:
            quality_rank = 2
        try:
            count_rank = -int(float(row_value(row, "count") or "0"))
        except ValueError:
            count_rank = 0
        return quality_rank, count_rank

    return sorted(rows, key=rank)


def load_candidate_rows(path: Path) -> Tuple[List[Dict[str, Any]], Optional[str], Optional[str]]:
    if not path.exists():
        return [], None, f"missing {path.relative_to(PROJECT_ROOT)}"
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames:
                return [], None, f"{path.name} is empty"
            address_field = detect_address_field(reader.fieldnames)
            if address_field is None:
                return [], None, f"{path.name} missing address field"
            return list(reader), address_field, None
    except Exception as error:
        return [], None, f"failed to read {path.name}: {error}"


def read_review_addresses() -> Tuple[List[str], str, Dict[str, int], Optional[str]]:
    cached_keys = read_address_keys(CACHE_PATH, CACHE_ADDRESS_FIELDS)
    imported_review_keys = read_address_keys(REVIEW_PATH, ("original_address",), import_only=True)
    skip_keys = cached_keys | imported_review_keys
    stats = {
        "selected_count": 0,
        "skipped_cached_count": 0,
        "skipped_low_quality_count": 0,
    }

    for path in (MISSING_QUEUE_PATH, FALLBACK_INPUT_PATH):
        rows, address_field, read_error = load_candidate_rows(path)
        if read_error or address_field is None:
            print(f"candidate_source_skip={path.name}; reason={read_error}")
            continue

        addresses: List[str] = []
        seen: Set[str] = set()
        for row in sorted_candidate_rows(rows):
            if len(addresses) >= MAX_ROWS:
                break
            address = row_value(row, address_field)
            key = normalize_address_key(address)
            quality = row_value(row, "quality").casefold()

            if not address or not key or quality == "rejected" or not looks_like_address(address):
                stats["skipped_low_quality_count"] += 1
                continue
            if key in skip_keys or key in seen:
                stats["skipped_cached_count"] += 1
                continue

            seen.add(key)
            addresses.append(address)

        if addresses:
            stats["selected_count"] = len(addresses)
            return addresses, path.name, stats, None

    return [], "", stats, "no usable candidate addresses"


def standardize_address(address: str, api_key: str) -> Dict[str, Any]:
    http_status, payload, request_error = request_json(
        MAP8_STANDARDIZATION_URL,
        {"key": api_key, "query": address, "en": "false"},
    )
    response_status = payload.get("status") if isinstance(payload, dict) else None
    result = first_result(payload)

    coordinates = nested_get(result, ["geom", "coordinates"])
    lng = lat = None
    if isinstance(coordinates, list) and len(coordinates) >= 2:
        lng = to_number(coordinates[0])
        lat = to_number(coordinates[1])

    error = request_error
    if error is None and result is None:
        error = "results empty"
    elif error is None and (lat is None or lng is None):
        error = "lat/lng not found in response"

    return {
        "api_type": "standardization",
        "http_status": http_status,
        "status": response_status or (f"HTTP {http_status}" if http_status else ""),
        "success": error is None,
        "formatted_address": result.get("formatted_address") if isinstance(result, dict) else "",
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else "",
        "town": result.get("town") if isinstance(result, dict) else "",
        "error": error or "",
    }


def geocode_address(address: str, api_key: str) -> Dict[str, Any]:
    http_status, payload, request_error = request_json(
        MAP8_GEOCODE_URL,
        {"key": api_key, "address": address},
    )
    response_status = payload.get("status") if isinstance(payload, dict) else None
    result = first_result(payload)

    lat = to_number(nested_get(result, ["geometry", "location", "lat"]))
    lng = to_number(nested_get(result, ["geometry", "location", "lng"]))

    error = request_error
    if error is None and result is None:
        error = "results empty"
    elif error is None and (lat is None or lng is None):
        error = "lat/lng not found in response"

    return {
        "api_type": "geocode_fallback",
        "http_status": http_status,
        "status": response_status or (f"HTTP {http_status}" if http_status else ""),
        "success": error is None,
        "formatted_address": result.get("formatted_address") if isinstance(result, dict) else "",
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else "",
        "town": result.get("town") if isinstance(result, dict) else "",
        "error": error or "",
    }


def confidence_hint(result: Dict[str, Any]) -> str:
    if result["api_type"] == "skipped":
        return "skipped_empty_address"
    if result["api_type"] == "standardization" and result.get("lat") is not None and result.get("lng") is not None:
        if result.get("formatted_address"):
            return "standardized"
        return "standardized_review"
    if result["api_type"] == "geocode_fallback" and result.get("lat") is not None and result.get("lng") is not None:
        return "geocode_fallback_review"
    if result.get("city") or result.get("town"):
        return "no_coordinates"
    return "api_failed"


def make_output_row(address: str, result: Dict[str, Any]) -> Dict[str, Any]:
    hint = confidence_hint(result)
    return {
        "original_address": address,
        "formatted_address": result.get("formatted_address") or "",
        "lat": "" if result.get("lat") is None else result.get("lat"),
        "lng": "" if result.get("lng") is None else result.get("lng"),
        "city": result.get("city") or "",
        "town": result.get("town") or "",
        "api_type": result.get("api_type") or "failed",
        "status": result.get("status") or "",
        "confidence_hint": hint,
        "should_import": "false",
        "error": result.get("error") or "",
    }


def review_address(address: str, api_key: str) -> Dict[str, Any]:
    if not address.strip():
        return {
            "api_type": "skipped",
            "status": "",
            "success": False,
            "formatted_address": "",
            "lat": None,
            "lng": None,
            "city": "",
            "town": "",
            "error": "empty address",
        }

    standard = standardize_address(address, api_key)
    if standard["success"]:
        return standard

    fallback = geocode_address(address, api_key)
    if fallback["success"]:
        return fallback

    return {
        "api_type": "failed",
        "status": fallback.get("status") or standard.get("status") or "",
        "success": False,
        "formatted_address": fallback.get("formatted_address") or standard.get("formatted_address") or "",
        "lat": fallback.get("lat"),
        "lng": fallback.get("lng"),
        "city": fallback.get("city") or standard.get("city") or "",
        "town": fallback.get("town") or standard.get("town") or "",
        "error": f"standardization: {standard.get('error') or '-'}; geocode: {fallback.get('error') or '-'}",
    }


def write_review_csv(rows: List[Dict[str, Any]]) -> Tuple[Optional[str], str]:
    backup_name = ""
    try:
        LIVE_DATA_DIR.mkdir(parents=True, exist_ok=True)
        if OUTPUT_PATH.exists():
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_path = LIVE_DATA_DIR / f"map8_geocode_review.backup_{timestamp}.csv"
            backup_path.write_bytes(OUTPUT_PATH.read_bytes())
            backup_name = str(backup_path.relative_to(PROJECT_ROOT))
        with OUTPUT_PATH.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        return None, backup_name
    except Exception as error:
        return f"寫入 live-data/map8_geocode_review.csv 失敗：{error}", backup_name


def print_row(address: str, row: Dict[str, Any], success: bool) -> None:
    print(f"- original_address: {address or '-'}")
    print(f"  api_type: {row['api_type']}")
    print(f"  success: {str(success).lower()}")
    print(f"  formatted_address: {row['formatted_address'] or '-'}")
    print(f"  lat: {row['lat'] or '-'}")
    print(f"  lng: {row['lng'] or '-'}")
    print(f"  city: {row['city'] or '-'}")
    print(f"  town: {row['town'] or '-'}")
    print(f"  error: {row['error'] or '-'}")


def main() -> int:
    configure_console()
    print("DrivePilot MAP8 Geocode Review")
    print(f"primary input file path: {MISSING_QUEUE_PATH.relative_to(PROJECT_ROOT)}")
    print(f"fallback input file path: {FALLBACK_INPUT_PATH.relative_to(PROJECT_ROOT)}")
    print(f"output file path: {OUTPUT_PATH.relative_to(PROJECT_ROOT)}")
    print(f"max rows: {MAX_ROWS}")

    api_key = load_api_key()
    if api_key is None:
        return 0

    addresses, source_file, select_stats, read_error = read_review_addresses()
    if read_error:
        print(read_error)
        return 0
    print(f"source_file={source_file}")
    print(f"selected_count={select_stats['selected_count']}")
    print(f"skipped_cached_count={select_stats['skipped_cached_count']}")
    print(f"skipped_low_quality_count={select_stats['skipped_low_quality_count']}")

    output_rows: List[Dict[str, Any]] = []
    processed = success_count = failed_count = skipped_count = 0

    for address in addresses or []:
        result = review_address(address, api_key)
        row = make_output_row(address, result)
        output_rows.append(row)

        if row["api_type"] == "skipped":
            skipped_count += 1
        else:
            processed += 1
            if result.get("success"):
                success_count += 1
            else:
                failed_count += 1
        print_row(address, row, bool(result.get("success")))

    write_error, backup_path = write_review_csv(output_rows)
    if write_error:
        print(write_error)
        return 1

    print("")
    print(f"selected_count: {select_stats['selected_count']}")
    print(f"skipped_cached_count: {select_stats['skipped_cached_count']}")
    print(f"skipped_low_quality_count: {select_stats['skipped_low_quality_count']}")
    print(f"processed count: {processed}")
    print(f"success count: {success_count}")
    print(f"failed count: {failed_count}")
    print(f"skipped count: {skipped_count}")
    print(f"output_path: {OUTPUT_PATH.relative_to(PROJECT_ROOT)}")
    print(f"backup_path: {backup_path or '-'}")
    print(f"generated at: {datetime.now().replace(microsecond=0).isoformat(sep=' ')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
