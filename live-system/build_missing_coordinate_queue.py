from __future__ import annotations

import csv
import ctypes
import json
import re
import shutil
from collections import Counter
from datetime import datetime
from io import StringIO
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "live-data"

UNRESOLVED_PATH = DATA_DIR / "unresolved_addresses.csv"
PLACES_PATH = DATA_DIR / "places.csv"
NOTIFICATIONS_PATH = DATA_DIR / "notifications.jsonl"
RESOLVED_PATH = DATA_DIR / "map_resolved_points.csv"
MAP_POINTS_PATH = DATA_DIR / "map_points.csv"
CACHE_PATH = DATA_DIR / "address_geocode_cache.csv"
OUTPUT_PATH = DATA_DIR / "missing_coordinate_queue.csv"
SUMMARY_PATH = DATA_DIR / "missing_coordinate_queue_summary.json"

OUTPUT_FIELDS = [
    "address",
    "count",
    "last_seen",
    "source",
    "sample_text",
    "reason",
    "quality",
    "quality_reason",
    "time",
    "normalized_address",
    "resolved_address",
    "source_file",
    "source_detail",
    "confidence",
    "kind",
    "text_summary",
    "suggested_action",
]

ADDRESS_TOKENS = ("縣", "市", "區", "鄉", "鎮", "路", "街", "巷", "弄", "號", "大道")
STRONG_ADDRESS_TOKENS = ("路", "街", "巷", "弄", "號", "大道")
DIRTY_TOKENS = (
    "line.me",
    "http://",
    "https://",
    "@",
    "回金",
    "匯款",
    "汇款",
    "轉帳",
    "转账",
    "街口",
    "收款",
    "金額",
    "金额",
    "銀行",
    "帳號",
    "账号",
)
ADDRESS_PATTERN = re.compile(
    r"(?:Demo City)?[\u4e00-\u9fff0-9一二三四五六七八九十]{1,8}區"
    r"[\u4e00-\u9fff0-9一二三四五六七八九十]{1,16}"
    r"(?:大道|路|街|巷|弄)"
    r"[\u4e00-\u9fff0-9一二三四五六七八九十段巷弄\-之]{0,18}"
    r"(?:號)?"
)


def read_text_shared(path: Path) -> str:
    if not hasattr(ctypes, "windll"):
        raise PermissionError(f"Unable to shared-read locked file on this platform: {path}")

    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateFileW(
        str(path),
        0x80000000,
        0x00000001 | 0x00000002 | 0x00000004,
        None,
        3,
        0x00000080,
        None,
    )
    if handle == ctypes.c_void_p(-1).value:
        raise PermissionError(f"Unable to open locked file for shared read: {path}")

    chunks: list[bytes] = []
    try:
        size = 1024 * 1024
        buffer = ctypes.create_string_buffer(size)
        bytes_read = ctypes.c_ulong(0)
        while True:
            ok = kernel32.ReadFile(handle, buffer, size, ctypes.byref(bytes_read), None)
            if not ok:
                raise OSError(f"Unable to read locked file: {path}")
            if bytes_read.value == 0:
                break
            chunks.append(buffer.raw[: bytes_read.value])
    finally:
        kernel32.CloseHandle(handle)
    return b"".join(chunks).decode("utf-8-sig", errors="replace")


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            return list(csv.DictReader(handle))
    except PermissionError:
        return list(csv.DictReader(StringIO(read_text_shared(path))))


def iter_jsonl(path: Path):
    if not path.exists():
        return
    try:
        lines = path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    except PermissionError:
        lines = read_text_shared(path).splitlines()
    for line in lines:
        if not line.strip():
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def parse_time(value: object) -> datetime:
    text = str(value or "").strip()
    if not text:
        return datetime.min
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
        return datetime.min


def clean_text(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").replace("\u3000", " ")).strip()


def compact_key(value: object) -> str:
    text = clean_text(value)
    text = re.sub(r"\s+", "", text)
    return re.sub(r"[,，。;；|()\[\]\"'`：:、，。！？!?<>《》「」『』【】]", "", text)


def variant_key(value: object) -> str:
    key = compact_key(value)
    key = re.sub(r"^\d{3}(?=Demo City)", "", key)
    return re.sub(r"^(?:台灣|臺灣)?Demo City", "", key)


def first_value(row: dict, *names: str) -> str:
    for name in names:
        value = clean_text(row.get(name, ""))
        if value:
            return value
    return ""


def source_rank(source_file: str) -> int:
    ranks = {"unresolved_addresses.csv": 3, "places.csv": 2, "notifications.jsonl": 1}
    return ranks.get(source_file, 0)


def has_address_token(text: str) -> bool:
    return any(token in text for token in ADDRESS_TOKENS)


def has_strong_address_token(text: str) -> bool:
    return any(token in text for token in STRONG_ADDRESS_TOKENS)


def dirty_matches(text: str) -> list[str]:
    lower = text.casefold()
    matches = [token for token in DIRTY_TOKENS if token.casefold() in lower]
    if re.search(r"\b09\d{8}\b", text):
        matches.append("phone")
    if re.search(r"\b\d{10,16}\b", text):
        matches.append("account_like_number")
    return matches


def remove_dirty_terms(text: str) -> str:
    cleaned = text
    for token in DIRTY_TOKENS:
        cleaned = re.sub(re.escape(token), "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\b\d+\s*元\b", "", cleaned)
    return clean_text(cleaned)


def is_mojibake(value: object) -> bool:
    text = str(value or "")
    return text.count("?") >= 2 or any(token in text for token in ("嚙", "�"))


def is_queryable_address(value: object) -> bool:
    text = compact_key(value)
    return bool(4 <= len(text) <= 50 and has_address_token(text))


def quality_for(address: str, sample_text: str, source_file: str) -> tuple[str, str]:
    text = compact_key(address)
    sample = clean_text(sample_text)
    reasons: list[str] = []

    dirty = dirty_matches(address)
    if dirty:
        return "rejected", "dirty_address_token:" + ",".join(dirty)
    if not has_address_token(text):
        return "rejected", "missing_address_token"
    if len(text) > 50 and not has_strong_address_token(text):
        return "rejected", "too_long_without_strong_address_token"
    if len(text) < 4:
        return "rejected", "too_short"
    if re.fullmatch(r"[\d\-+() ]+", text):
        return "rejected", "number_only"
    if not re.search(r"\d", text) and "路口" not in text:
        return "rejected", "weak_address_without_number"
    if dirty_matches(sample) and not re.search(r"\d", text):
        return "rejected", "dirty_sample_with_weak_address"
    if is_mojibake(address):
        reasons.append("mojibake")

    if len(text) > 30:
        reasons.append("address_over_30_chars")
    if not has_strong_address_token(text):
        reasons.append("weak_address_token")
    if "00" in text:
        reasons.append("suspicious_zero_sequence")
    if source_file == "notifications.jsonl" and len(sample) > 80:
        reasons.append("long_notification_sample")
    if dirty_matches(sample) and len(sample) > 80:
        reasons.append("sample_contains_non_address_terms")

    if reasons:
        return "suspicious", ";".join(reasons)
    return "good", "address_like"


def clean_sample(text: str, address: str) -> str:
    text = clean_text(text)
    address = clean_text(address)
    if not text:
        return address
    text = re.sub(r"https?://\S+", "", text, flags=re.IGNORECASE)
    text = re.sub(r"line\.me/\S+", "", text, flags=re.IGNORECASE)
    text = re.sub(r"@\S+", "", text)
    text = clean_text(text)
    index = text.find(address)
    if index < 0:
        compact = compact_key(address)
        compact_text = compact_key(text)
        compact_index = compact_text.find(compact)
        if compact_index >= 0:
            return address
        return remove_dirty_terms(text[:80])
    start = max(0, index - 18)
    end = min(len(text), index + len(address) + 18)
    sample = text[start:end].strip()
    if start > 0:
        sample = "..." + sample
    if end < len(text):
        sample += "..."
    return remove_dirty_terms(sample)


def build_known_index(rows: list[dict[str, str]], fields: tuple[str, ...]) -> set[str]:
    index: set[str] = set()
    for row in rows:
        for field in fields:
            key = compact_key(row.get(field, ""))
            if key:
                index.add(key)
                index.add(variant_key(key))
    return index


def is_known(address: str, index: set[str]) -> bool:
    key = compact_key(address)
    secondary = variant_key(address)
    return bool((key and key in index) or (secondary and secondary in index))


def candidate_row(
    *,
    time: str,
    address: str,
    normalized_address: str = "",
    resolved_address: str = "",
    source_file: str,
    source: str,
    confidence: str = "",
    kind: str = "",
    text_summary: str = "",
) -> dict[str, str]:
    normalized = normalized_address or address
    resolved = resolved_address or normalized or address
    sample = clean_sample(text_summary, address)
    return {
        "time": time,
        "last_seen": time,
        "address": clean_text(address),
        "count": "1",
        "normalized_address": clean_text(normalized),
        "resolved_address": clean_text(resolved),
        "source_file": source_file,
        "source": source_file,
        "source_detail": remove_dirty_terms(source),
        "confidence": confidence,
        "kind": kind,
        "reason": "queryable_address_missing_coordinates;not_in_resolved_or_cache_or_marker",
        "sample_text": sample,
        "text_summary": sample,
        "suggested_action": "map8_review_candidate",
        "quality": "",
        "quality_reason": "",
    }


def candidates_from_unresolved(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    output = []
    for row in rows:
        address = first_value(row, "normalized_address", "raw_address", "match_key")
        output.append(
            candidate_row(
                time=first_value(row, "last_seen", "first_seen"),
                address=address,
                normalized_address=first_value(row, "normalized_address", "raw_address"),
                source_file="unresolved_addresses.csv",
                source="unresolved_addresses",
                kind="unresolved",
                text_summary=first_value(row, "sample_text"),
            )
        )
    return output


def candidates_from_places(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    output = []
    for row in rows:
        output.append(
            candidate_row(
                time=first_value(row, "timestamp", "time"),
                address=first_value(row, "address", "normalized_address", "parsed_address"),
                normalized_address=first_value(row, "normalized_address", "address"),
                source_file="places.csv",
                source=first_value(row, "group", "source"),
                confidence=first_value(row, "confidence"),
                kind=first_value(row, "kind"),
                text_summary=first_value(row, "text", "note"),
            )
        )
    return output


def extract_addresses_from_text(text: str) -> list[str]:
    addresses: list[str] = []
    for match in ADDRESS_PATTERN.finditer(text):
        address = compact_key(match.group(0))
        if is_queryable_address(address):
            addresses.append(address)
    return addresses


def candidates_from_notifications(items: list[dict]) -> list[dict[str, str]]:
    output = []
    message_fields = ("message", "text", "body", "raw_text", "content")
    for item in items:
        text = first_value(item, *message_fields)
        if not text:
            continue
        for address in extract_addresses_from_text(text):
            output.append(
                candidate_row(
                    time=first_value(item, "timestamp", "created_at", "received_at", "time", "datetime"),
                    address=address,
                    normalized_address=address,
                    source_file="notifications.jsonl",
                    source=first_value(item, "group_name", "source", "source_name", "title", "group"),
                    confidence=first_value(item, "confidence"),
                    kind=first_value(item, "kind", "type"),
                    text_summary=text,
                )
            )
    return output


def better_address(left: str, right: str) -> str:
    if not left:
        return right
    if not right:
        return left
    left_key = compact_key(left)
    right_key = compact_key(right)
    left_city = left_key.startswith("Demo City")
    right_city = right_key.startswith("Demo City")
    if right_city and not left_city:
        return right
    if left_city and not right_city:
        return left
    return right if len(right_key) > len(left_key) else left


def merge_candidate(existing: dict[str, str], row: dict[str, str]) -> dict[str, str]:
    existing["count"] = str(int(existing.get("count") or "0") + int(row.get("count") or "1"))
    existing_sources = {part for part in existing.get("source", "").split(";") if part}
    existing_sources.add(row.get("source_file", "") or row.get("source", ""))
    existing["source"] = ";".join(sorted(existing_sources))

    if parse_time(row.get("last_seen")) >= parse_time(existing.get("last_seen")):
        existing["last_seen"] = row.get("last_seen", "")
        existing["time"] = row.get("time", "")
        for field in ("source_detail", "confidence", "kind"):
            if row.get(field):
                existing[field] = row[field]

    chosen_address = better_address(existing.get("address", ""), row.get("address", ""))
    existing["address"] = chosen_address
    existing["normalized_address"] = better_address(existing.get("normalized_address", ""), row.get("normalized_address", ""))
    existing["resolved_address"] = better_address(existing.get("resolved_address", ""), row.get("resolved_address", ""))

    current_sample = existing.get("sample_text", "")
    new_sample = row.get("sample_text", "")
    if new_sample and (not current_sample or len(new_sample) < len(current_sample)):
        existing["sample_text"] = new_sample
        existing["text_summary"] = new_sample

    qualities = {existing.get("quality", "good"), row.get("quality", "good")}
    existing["quality"] = "suspicious" if "suspicious" in qualities else "good"
    reason_parts: set[str] = set()
    for value in (existing.get("quality_reason", ""), row.get("quality_reason", "")):
        reason_parts.update(part for part in value.split(";") if part and part != "address_like")
    existing["quality_reason"] = ";".join(sorted(reason_parts)) if reason_parts else "address_like"
    return existing


def write_queue(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_summary(path: Path, summary: dict[str, Any]) -> None:
    path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")


def count_existing_rows(path: Path) -> int:
    try:
        return len(read_csv(path)) if path.exists() else 0
    except Exception:
        return 0


def main() -> int:
    unresolved_rows = read_csv(UNRESOLVED_PATH)
    places_rows = read_csv(PLACES_PATH)
    notification_items = list(iter_jsonl(NOTIFICATIONS_PATH) or [])
    resolved_rows = read_csv(RESOLVED_PATH)
    map_points_rows = read_csv(MAP_POINTS_PATH)
    cache_rows = read_csv(CACHE_PATH)

    resolved_index = build_known_index(resolved_rows, ("address", "normalized_address", "resolved_address"))
    marker_index = build_known_index(map_points_rows, ("address", "normalized_address", "resolved_address"))
    cache_index = build_known_index(cache_rows, ("address", "formatted_address", "normalized_address", "raw_address", "original_address", "match_key"))

    source_candidates = (
        candidates_from_unresolved(unresolved_rows)
        + candidates_from_places(places_rows)
        + candidates_from_notifications(notification_items)
    )

    unresolved_source_count = len(unresolved_rows)
    places_source_count = len(places_rows)
    notifications_source_count = len(notification_items)
    before_count = count_existing_rows(OUTPUT_PATH)

    invalid_skipped = 0
    rejected_count = 0
    already_resolved_skipped = 0
    already_marker_skipped = 0
    already_cached_skipped = 0
    total_candidates = 0
    quality_counts: Counter[str] = Counter()
    latest_by_key: dict[str, dict[str, str]] = {}

    for row in source_candidates:
        address = first_value(row, "normalized_address", "address", "resolved_address")
        if not address or not is_queryable_address(address) or is_mojibake(address):
            invalid_skipped += 1
            continue
        if is_known(address, resolved_index):
            already_resolved_skipped += 1
            continue
        if is_known(address, marker_index):
            already_marker_skipped += 1
            continue
        if is_known(address, cache_index):
            already_cached_skipped += 1
            continue

        quality, quality_reason = quality_for(address, row.get("sample_text", ""), row.get("source_file", ""))
        row["quality"] = quality
        row["quality_reason"] = quality_reason
        quality_counts[quality] += 1
        total_candidates += 1
        if quality == "rejected":
            rejected_count += 1
            continue

        key = variant_key(address)
        existing = latest_by_key.get(key)
        if existing is None:
            latest_by_key[key] = row
        else:
            latest_by_key[key] = merge_candidate(existing, row)

    final_rows = sorted(latest_by_key.values(), key=lambda item: parse_time(item["last_seen"]))
    dedupe_merged_count = max(0, (quality_counts["good"] + quality_counts["suspicious"]) - len(final_rows))

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = DATA_DIR / f"missing_coordinate_queue.backup_{timestamp}.csv"
    if OUTPUT_PATH.exists():
        shutil.copy2(OUTPUT_PATH, backup_path)
        backup_created = backup_path.name
    else:
        backup_created = ""

    write_queue(OUTPUT_PATH, final_rows)

    source_file_breakdown = Counter(row["source_file"] for row in final_rows)
    quality_breakdown = Counter(row["quality"] for row in final_rows)
    reason_breakdown = Counter(row["quality_reason"] for row in final_rows)
    summary = {
        "generated_at": datetime.now().replace(microsecond=0).isoformat(sep=" "),
        "total_candidates": total_candidates,
        "good_count": quality_counts["good"],
        "suspicious_count": quality_counts["suspicious"],
        "rejected_count": rejected_count,
        "final_queue_count": len(final_rows),
        "dedupe_merged_count": dedupe_merged_count,
        "backup_created": backup_created,
        "previous_queue_count": before_count,
        "invalid_skipped_count": invalid_skipped,
        "already_resolved_skipped_count": already_resolved_skipped,
        "already_marker_skipped_count": already_marker_skipped,
        "already_cached_skipped_count": already_cached_skipped,
        "unresolved_source_count": unresolved_source_count,
        "places_source_count": places_source_count,
        "notifications_source_count": notifications_source_count,
        "source_file_breakdown": dict(source_file_breakdown),
        "quality_breakdown": dict(quality_breakdown),
        "quality_reason_breakdown": dict(reason_breakdown),
    }
    write_summary(SUMMARY_PATH, summary)

    print("input files:")
    print(f"- {UNRESOLVED_PATH}")
    print(f"- {PLACES_PATH}")
    print(f"- {NOTIFICATIONS_PATH}")
    print(f"- {RESOLVED_PATH}")
    print(f"- {MAP_POINTS_PATH}")
    print(f"- {CACHE_PATH}")
    print(f"output file: {OUTPUT_PATH}")
    print(f"summary file: {SUMMARY_PATH}")
    print(f"backup file: {backup_path if backup_created else '(not created; previous queue did not exist)'}")
    print(f"previous queue count: {before_count}")
    print(f"unresolved source count: {unresolved_source_count}")
    print(f"places source count: {places_source_count}")
    print(f"notifications source count: {notifications_source_count}")
    print(f"total candidates: {total_candidates}")
    print(f"good count: {quality_counts['good']}")
    print(f"suspicious count: {quality_counts['suspicious']}")
    print(f"rejected count: {rejected_count}")
    print(f"dedupe merged count: {dedupe_merged_count}")
    print(f"already resolved skipped count: {already_resolved_skipped}")
    print(f"already marker skipped count: {already_marker_skipped}")
    print(f"already cached skipped count: {already_cached_skipped}")
    print(f"invalid skipped count: {invalid_skipped}")
    print(f"final queue count: {len(final_rows)}")
    print(f"source_file breakdown: {json.dumps(dict(source_file_breakdown), ensure_ascii=False)}")
    print(f"quality breakdown: {json.dumps(dict(quality_breakdown), ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
