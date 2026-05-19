from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_DIR = PROJECT_ROOT / "config"
LIVE_DATA_DIR = PROJECT_ROOT / "live-data"
API_KEY_PATH = CONFIG_DIR / "map8_api_key.txt"
OUTPUT_PATH = LIVE_DATA_DIR / "map8_test_results.json"

MAP8_GEOCODE_URL = "https://api.map8.zone/v2/place/geocode/json"
MAP8_STANDARDIZATION_URL = "https://api.map8.zone/v2/address/standardization"
REQUEST_TIMEOUT_SECONDS = 15

TEST_ADDRESSES = [
    "Demo City North Zone 100",
    "Demo City Central Road 200",
    "Demo City South District 300",
    "Demo City East Avenue 400",
    "Demo City West Street 500",
]


def configure_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def now_text() -> str:
    return datetime.now().replace(microsecond=0).isoformat(sep=" ")


def load_api_key() -> Optional[str]:
    if not API_KEY_PATH.exists():
        print("請建立 config/map8_api_key.txt 並放入 MAP8 API Key")
        return None
    key = API_KEY_PATH.read_text(encoding="utf-8").strip()
    if not key:
        print("config/map8_api_key.txt 是空檔，請放入 MAP8 API Key")
        return None
    return key


def build_url(base_url: str, params: Dict[str, Any]) -> str:
    query = urllib.parse.urlencode(params)
    joiner = "&" if "?" in base_url else "?"
    return base_url + joiner + query


def request_json(base_url: str, params: Dict[str, Any]) -> Tuple[Optional[int], Optional[Dict[str, Any]], Optional[str]]:
    url = build_url(base_url, params)
    request = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", errors="replace")
            try:
                return response.status, json.loads(body), None
            except json.JSONDecodeError:
                return response.status, None, "JSON parse failed"
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        parsed = None
        try:
            parsed = json.loads(body) if body.strip() else None
        except json.JSONDecodeError:
            pass
        reason = getattr(error, "reason", "") or error.msg or "HTTP error"
        return error.code, parsed, f"HTTP {error.code}: {reason}"
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


def raw_response(payload: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if isinstance(payload, dict):
        return payload
    return {}


def geocode_address(address: str, api_key: str) -> Dict[str, Any]:
    status_code, payload, request_error = request_json(
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
        "request_address": address,
        "api_type": "geocode",
        "http_status": status_code,
        "response_status": response_status,
        "success": error is None,
        "formatted_address": result.get("formatted_address") if isinstance(result, dict) else None,
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else None,
        "town": result.get("town") if isinstance(result, dict) else None,
        "type": result.get("type") if isinstance(result, dict) else None,
        "level": result.get("level") if isinstance(result, dict) else None,
        "likelihood": result.get("likelihood") if isinstance(result, dict) else None,
        "authoritative": result.get("authoritative") if isinstance(result, dict) else None,
        "error": error,
        "raw_response": raw_response(payload),
    }


def standardize_address(address: str, api_key: str) -> Dict[str, Any]:
    status_code, payload, request_error = request_json(
        MAP8_STANDARDIZATION_URL,
        {"key": api_key, "query": address, "en": "false"},
    )
    response_status = payload.get("status") if isinstance(payload, dict) else None
    query_quality = payload.get("queryQuality") if isinstance(payload, dict) else None
    result = first_result(payload)

    coordinates = nested_get(result, ["geom", "coordinates"])
    lng = lat = None
    if isinstance(coordinates, list) and len(coordinates) >= 2:
        lng = to_number(coordinates[0])
        lat = to_number(coordinates[1])

    error = request_error
    if error is None and result is None:
        error = "results empty"

    return {
        "request_address": address,
        "api_type": "standardization",
        "http_status": status_code,
        "response_status": response_status,
        "queryQuality": query_quality,
        "success": error is None,
        "standardized_address": result.get("formatted_address") if isinstance(result, dict) else None,
        "lat": lat,
        "lng": lng,
        "city": result.get("city") if isinstance(result, dict) else None,
        "town": result.get("town") if isinstance(result, dict) else None,
        "road": result.get("road") if isinstance(result, dict) else None,
        "num": result.get("num") if isinstance(result, dict) else None,
        "floor": result.get("floor") if isinstance(result, dict) else None,
        "error": error,
        "raw_response": raw_response(payload),
    }


def print_result(index: int, result: Dict[str, Any]) -> None:
    display_address = result.get("formatted_address") or result.get("standardized_address") or "-"
    print(f"{index}. {result['request_address']}")
    print(f"   API type: {result['api_type']}")
    print(f"   HTTP: {result.get('http_status') if result.get('http_status') is not None else '-'}")
    print(f"   Response status: {result.get('response_status') or '-'}")
    print(f"   Success: {str(bool(result.get('success'))).lower()}")
    print(f"   Address: {display_address}")
    print(f"   Lat: {result.get('lat') if result.get('lat') is not None else '-'}")
    print(f"   Lng: {result.get('lng') if result.get('lng') is not None else '-'}")
    print(f"   City: {result.get('city') or '-'}")
    print(f"   Town: {result.get('town') or '-'}")
    print(f"   Level: {result.get('level') or '-'}")
    print(f"   Likelihood: {result.get('likelihood') if result.get('likelihood') is not None else '-'}")
    print(f"   Authoritative: {result.get('authoritative') if result.get('authoritative') is not None else '-'}")
    print(f"   Error: {result.get('error') or '-'}")


def main() -> int:
    configure_console()
    print("DrivePilot MAP8 API Smoke Test")
    print("")

    api_key = load_api_key()
    if api_key is None:
        return 0

    print("Config:")
    print("- key loaded: yes")
    print("- geocode endpoint: configured")
    print("- standardization endpoint: configured")
    print("- auth mode: query key")
    print("")

    geocode_results = []
    standardization_results = []

    print("Geocoding Results:")
    for index, address in enumerate(TEST_ADDRESSES, start=1):
        result = geocode_address(address, api_key)
        geocode_results.append(result)
        print_result(index, result)

    print("")
    print("Address Standardization Results:")
    for index, address in enumerate(TEST_ADDRESSES, start=1):
        result = standardize_address(address, api_key)
        standardization_results.append(result)
        print_result(index, result)

    output = {
        "generated_at": now_text(),
        "api": "MAP8",
        "test_type": "smoke_test",
        "geocode_results": geocode_results,
        "standardization_results": standardization_results,
        "summary": {
            "geocode_success": sum(1 for item in geocode_results if item["success"]),
            "geocode_failed": sum(1 for item in geocode_results if not item["success"]),
            "standardization_success": sum(1 for item in standardization_results if item["success"]),
            "standardization_failed": sum(1 for item in standardization_results if not item["success"]),
        },
    }

    try:
        LIVE_DATA_DIR.mkdir(parents=True, exist_ok=True)
        OUTPUT_PATH.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
        print("")
        print("Output:")
        print(str(OUTPUT_PATH.relative_to(PROJECT_ROOT)))
    except Exception as error:
        print("")
        print(f"寫入 live-data/map8_test_results.json 失敗：{error}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
