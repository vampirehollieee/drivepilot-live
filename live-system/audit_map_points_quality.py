from __future__ import annotations

import csv
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "live-data"
INPUT_PATH = DATA_DIR / "map_resolved_points.csv"
REVIEW_PATH = DATA_DIR / "map_points_quality_review.csv"
SUMMARY_PATH = DATA_DIR / "map_points_quality_summary.json"

REVIEW_FIELDS = [
    "time",
    "normalized_address",
    "resolved_address",
    "lat",
    "lng",
    "source",
    "confidence",
    "kind",
    "risk_category",
    "risk_reason",
    "text_summary",
    "suggested_action",
]

RISK_CATEGORIES = [
    "precise_candidate",
    "road_or_landmark_level",
    "static_seed_risk",
    "alias_mismatch_risk",
    "mojibake_text_risk",
    "missing_address_risk",
    "unknown_risk",
]

SUGGESTED_ACTIONS = [
    "keep",
    "review",
    "downgrade_display",
    "hide_from_main_marker",
    "needs_cache_review",
]

MOJIBAKE_RE = re.compile(r"[�□]|Ã|Â|æ|å|ç|è|é|嚚|||銝|撣|擃|憭|蝡|鈭|頝|璈||||")
ROAD_RE = re.compile(r"[\u4e00-\u9fff0-9一二三四五六七八九十之\-]+(?:路|街|大道|巷|弄)")
HOUSE_NO_RE = re.compile(r"[0-9０-９一二三四五六七八九十之\-]+(?:號|号)")


def normalize_text(value: object) -> str:
    text = str(value or "")
    text = text.replace("\u3000", " ")
    return re.sub(r"\s+", "", text).strip()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def safe_float(value: object) -> float | None:
    try:
        number = float(str(value or "").strip())
    except ValueError:
        return None
    if -90 <= number <= 90:
        return number
    return number


def valid_lat_lng(lat: object, lng: object) -> bool:
    lat_number = safe_float(lat)
    lng_number = safe_float(lng)
    return (
        lat_number is not None
        and lng_number is not None
        and -90 <= lat_number <= 90
        and -180 <= lng_number <= 180
    )


def has_mojibake(*values: object) -> bool:
    return any(MOJIBAKE_RE.search(str(value or "")) for value in values)


def has_house_number(address: str) -> bool:
    return bool(HOUSE_NO_RE.search(address))


def looks_road_or_landmark_level(address: str) -> bool:
    if not address:
        return False
    return bool(ROAD_RE.search(address)) and not has_house_number(address)


def extract_road_tokens(text: str) -> set[str]:
    return {match.group(0) for match in ROAD_RE.finditer(text or "")}


def has_alias_mismatch(address: str, text_summary: str) -> bool:
    address_key = normalize_text(address)
    text_key = normalize_text(text_summary)
    if not address_key or not text_key:
        return False
    if address_key in text_key:
        return False

    address_roads = extract_road_tokens(address)
    text_roads = extract_road_tokens(text_summary)
    if not address_roads or not text_roads:
        return False

    return address_roads.isdisjoint(text_roads)


def classify_row(
    row: dict[str, str],
    address_counts: Counter[str],
    coordinate_counts: Counter[str],
) -> tuple[str, str, str]:
    normalized_address = (row.get("normalized_address") or "").strip()
    resolved_address = (row.get("address") or "").strip()
    address = normalized_address or resolved_address
    lat = (row.get("lat") or "").strip()
    lng = (row.get("lng") or "").strip()
    confidence = (row.get("confidence") or "").strip().lower()
    group = row.get("group") or ""
    text_summary = row.get("text_summary") or ""
    kind = (row.get("kind") or "").strip().lower()
    address_key = normalize_text(address)
    coord_key = f"{lat},{lng}"

    if not address or not lat or not lng or not valid_lat_lng(lat, lng):
        return (
            "missing_address_risk",
            "missing normalized/resolved address or invalid lat/lng",
            "hide_from_main_marker",
        )

    if has_mojibake(group, text_summary, normalized_address, resolved_address):
        return (
            "mojibake_text_risk",
            "group/text/address contains mojibake-like characters",
            "review",
        )

    if has_alias_mismatch(address, text_summary):
        return (
            "alias_mismatch_risk",
            "text_summary road/address tokens do not match resolved address",
            "needs_cache_review",
        )

    if address_counts[address_key] >= 10 or coordinate_counts[coord_key] >= 25:
        return (
            "static_seed_risk",
            "same address or coordinate is reused frequently from map_points seed",
            "review",
        )

    if looks_road_or_landmark_level(address) or kind == "description":
        return (
            "road_or_landmark_level",
            "address lacks house number or is a description-level marker",
            "downgrade_display",
        )

    if has_house_number(address) and confidence == "high":
        return (
            "precise_candidate",
            "address has house number, valid lat/lng, and high confidence",
            "keep",
        )

    return (
        "unknown_risk",
        "no specific risk rule matched",
        "review",
    )


def main() -> int:
    if not INPUT_PATH.exists():
        raise FileNotFoundError(f"Input file not found: {INPUT_PATH}")

    rows = read_csv(INPUT_PATH)
    map_point_rows = [
        row for row in rows if (row.get("source") or "").strip() == "map_points"
    ]

    address_counts: Counter[str] = Counter()
    coordinate_counts: Counter[str] = Counter()
    for row in map_point_rows:
        address = (row.get("normalized_address") or row.get("address") or "").strip()
        key = normalize_text(address)
        if key:
            address_counts[key] += 1
        lat = (row.get("lat") or "").strip()
        lng = (row.get("lng") or "").strip()
        if lat and lng:
            coordinate_counts[f"{lat},{lng}"] += 1

    review_rows: list[dict[str, str]] = []
    risk_counts: Counter[str] = Counter({key: 0 for key in RISK_CATEGORIES})
    action_counts: Counter[str] = Counter({key: 0 for key in SUGGESTED_ACTIONS})

    for row in map_point_rows:
        risk_category, risk_reason, suggested_action = classify_row(
            row,
            address_counts=address_counts,
            coordinate_counts=coordinate_counts,
        )
        risk_counts[risk_category] += 1
        action_counts[suggested_action] += 1
        review_rows.append(
            {
                "time": row.get("time", ""),
                "normalized_address": row.get("normalized_address", ""),
                "resolved_address": row.get("address", ""),
                "lat": row.get("lat", ""),
                "lng": row.get("lng", ""),
                "source": row.get("source", ""),
                "confidence": row.get("confidence", ""),
                "kind": row.get("kind", ""),
                "risk_category": risk_category,
                "risk_reason": risk_reason,
                "text_summary": row.get("text_summary", ""),
                "suggested_action": suggested_action,
            }
        )

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with REVIEW_PATH.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=REVIEW_FIELDS)
        writer.writeheader()
        writer.writerows(review_rows)

    summary = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "source_file": str(INPUT_PATH.relative_to(PROJECT_ROOT)).replace("\\", "/"),
        "total_records": len(rows),
        "total_map_points_records": len(map_point_rows),
        "risk_counts": dict(risk_counts),
        "suggested_action_counts": dict(action_counts),
    }
    with SUMMARY_PATH.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"input file path: {INPUT_PATH}")
    print(f"output review CSV path: {REVIEW_PATH}")
    print(f"output summary JSON path: {SUMMARY_PATH}")
    print(f"total records: {len(rows)}")
    print(f"map_points source records: {len(map_point_rows)}")
    print(f"risk_counts: {json.dumps(dict(risk_counts), ensure_ascii=False)}")
    print(f"suggested_action_counts: {json.dumps(dict(action_counts), ensure_ascii=False)}")

    high_risk = [
        row
        for row in review_rows
        if row["suggested_action"] in {"hide_from_main_marker", "needs_cache_review", "review"}
    ][:10]
    if high_risk:
        print("high risk sample:")
        for row in high_risk:
            print(
                f"- {row['time']} | {row['risk_category']} | {row['suggested_action']} | "
                f"{row['resolved_address']} | {row['risk_reason']}"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
