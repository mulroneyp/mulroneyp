#!/usr/bin/env python3
"""Sanity-check eBird life-list / My Data CSV parsing expectations for Handy Field Guide."""

from __future__ import annotations

import csv
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "HandyFieldGuide" / "Resources" / "fixtures" / "ebird_sample_life_list.csv"


def parse_life_list(text: str) -> list[dict[str, str]]:
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames or "Common Name" not in reader.fieldnames:
        raise SystemExit("missing Common Name header")
    rows = []
    for row in reader:
        countable = row.get("Countable", "").strip()
        if countable and countable != "1":
            continue
        rows.append(row)
    return rows


def main() -> None:
    if not FIXTURE.exists():
        raise SystemExit(f"missing fixture: {FIXTURE}")
    text = FIXTURE.read_text(encoding="utf-8")
    rows = parse_life_list(text)
    assert len(rows) >= 2, rows
    first = rows[0]
    assert first["Common Name"], first
    assert first.get("Date"), "classic life-list Date should map to First Recorded"
    assert first.get("Location"), "classic life-list Location should map to First Recorded"
    sp = (first.get("S/P") or "").strip()
    assert sp.startswith("US"), f"sample S/P should yield country US, got {sp!r}"
    # Explicit last columns in the sample when present
    with_last = [r for r in rows if (r.get("Last Date") or "").strip()]
    print(f"ok: {len(rows)} countable rows; {len(with_last)} with Last Date; S/P country={sp.split('-', 1)[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
