from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DATA_DIR = PROJECT_ROOT / "live-data"

AUTO_MAP8_SCRIPT = SCRIPT_DIR / "auto_map8_coordinate_import.py"
BUILD_MAP_POINTS_SCRIPT = SCRIPT_DIR / "build_map_points.py"
LOG_PATH = DATA_DIR / "auto_map8_routine.jsonl"
LOCK_PATH = DATA_DIR / "auto_map8_routine.lock"

DEFAULT_INTERVAL_SECONDS = 300
DEFAULT_LIMIT = 5
MAX_ROUTINE_LIMIT = 5


def configure_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def clamp_limit(value: int) -> int:
    if value < 1:
        return 1
    if value > MAX_ROUTINE_LIMIT:
        return MAX_ROUTINE_LIMIT
    return value


def parse_key_value_output(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if re.fullmatch(r"[A-Za-z0-9_]+", key):
            values[key] = value.strip()
    return values


def parse_int(values: dict[str, str], key: str) -> int:
    try:
        return int(values.get(key, "0"))
    except ValueError:
        return 0


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(PROJECT_ROOT),
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )


def run_once(limit: int) -> dict[str, object]:
    run_at = datetime.now().isoformat(timespec="seconds")
    auto_command = [sys.executable, str(AUTO_MAP8_SCRIPT), "--limit", str(limit)]
    auto_result = run_command(auto_command)
    auto_values = parse_key_value_output(auto_result.stdout)

    build_command = [sys.executable, str(BUILD_MAP_POINTS_SCRIPT)]
    build_result = run_command(build_command)

    error_count = 0
    if auto_result.returncode != 0:
        error_count += 1
    if build_result.returncode != 0:
        error_count += 1

    record: dict[str, object] = {
        "run_at": run_at,
        "limit": limit,
        "selected_count": parse_int(auto_values, "selected_count"),
        "auto_imported_count": parse_int(auto_values, "auto_imported_count"),
        "review_only_count": parse_int(auto_values, "review_only_count"),
        "bad_auto_import_count": 0,
        "error_count": error_count,
        "auto_returncode": auto_result.returncode,
        "build_map_points_returncode": build_result.returncode,
    }
    return record


def append_log(record: dict[str, object]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def acquire_lock() -> object:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    handle = LOCK_PATH.open("x", encoding="utf-8")
    handle.write(f"pid={os.getpid()}\n")
    handle.flush()
    return handle


def release_lock(handle: object) -> None:
    try:
        handle.close()
    except Exception:
        pass
    try:
        LOCK_PATH.unlink()
    except FileNotFoundError:
        pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Auto MAP8 Coordinate Import in a small polling routine.")
    parser.add_argument("--interval-seconds", type=int, default=DEFAULT_INTERVAL_SECONDS)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--max-runs", type=int, default=0, help="Optional test guard. 0 means run until Ctrl+C.")
    args = parser.parse_args()
    if args.interval_seconds < 1:
        args.interval_seconds = 1
    args.limit = clamp_limit(args.limit)
    if args.max_runs < 0:
        args.max_runs = 0
    return args


def main() -> int:
    configure_console()
    args = parse_args()
    try:
        lock_handle = acquire_lock()
    except FileExistsError:
        print(f"error: routine already appears to be running; lock file exists: {LOCK_PATH}")
        return 1

    print(f"Auto MAP8 routine started. interval_seconds={args.interval_seconds}, limit={args.limit}")
    print("Stop with Ctrl+C or close this window.")
    runs = 0
    try:
        while True:
            runs += 1
            try:
                record = run_once(args.limit)
            except Exception as error:
                record = {
                    "run_at": datetime.now().isoformat(timespec="seconds"),
                    "limit": args.limit,
                    "selected_count": 0,
                    "auto_imported_count": 0,
                    "review_only_count": 0,
                    "bad_auto_import_count": 0,
                    "error_count": 1,
                    "error": f"{error.__class__.__name__}: {error}",
                }
            append_log(record)
            print(
                "run_at={run_at} limit={limit} auto_imported_count={auto_imported_count} "
                "review_only_count={review_only_count} bad_auto_import_count={bad_auto_import_count} "
                "error_count={error_count}".format(**record)
            )
            if args.max_runs and runs >= args.max_runs:
                break
            time.sleep(args.interval_seconds)
    except KeyboardInterrupt:
        print("Auto MAP8 routine stopped.")
    finally:
        release_lock(lock_handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
