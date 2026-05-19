from __future__ import annotations

import sqlite3
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
LIVE_DATA_DIR = PROJECT_ROOT / "live-data"
DB_PATH = LIVE_DATA_DIR / "drivepilot.db"


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS signals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_uid TEXT UNIQUE,
    ts TEXT,
    source TEXT,
    group_name TEXT,
    sender_name TEXT,
    raw_text TEXT,
    kind TEXT,
    confidence TEXT,
    confidence_score REAL,
    area TEXT,
    place_name TEXT,
    lat REAL,
    lng REAL,
    is_locatable INTEGER,
    is_hotzone_event INTEGER,
    is_personal_alert INTEGER,
    push_mode TEXT,
    created_at TEXT
)
"""


INDEX_SQL = [
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_signals_event_uid ON signals(event_uid)",
    "CREATE INDEX IF NOT EXISTS idx_signals_ts ON signals(ts)",
    "CREATE INDEX IF NOT EXISTS idx_signals_group_name ON signals(group_name)",
    "CREATE INDEX IF NOT EXISTS idx_signals_area ON signals(area)",
    "CREATE INDEX IF NOT EXISTS idx_signals_is_hotzone_event ON signals(is_hotzone_event)",
    "CREATE INDEX IF NOT EXISTS idx_signals_is_personal_alert ON signals(is_personal_alert)",
    "CREATE INDEX IF NOT EXISTS idx_signals_is_locatable ON signals(is_locatable)",
]


def init_db(db_path: Path = DB_PATH) -> Path:
    LIVE_DATA_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.execute(SCHEMA_SQL)
        for statement in INDEX_SQL:
            conn.execute(statement)
        conn.commit()
    return db_path


def main() -> int:
    db_path = init_db()
    print("DrivePilot signal DB initialized")
    print(f"db path: {db_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
