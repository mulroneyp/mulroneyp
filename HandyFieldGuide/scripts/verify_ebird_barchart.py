#!/usr/bin/env python3
"""Verify eBird barchart parsing against the bundled L436229 fixture.

Mirrors HandyFieldGuide/EBirdBarchartParser.swift:
- 4 week columns per month, monthly value = mean of the four weeks
- slash taxa (/) and “sp.” rows are flagged, not dropped
- location id is read from the filename when present
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = (
    ROOT
    / "HandyFieldGuide"
    / "Resources"
    / "fixtures"
    / "ebird_L436229__2020_2026_1_12_barchart.txt"
)

NEAR_ZERO = 0.005
ENRICHMENT = 0.05


def location_id(filename: str) -> str | None:
    match = re.search(r"(?:^|[_\W])(L\d{5,})(?:[_\W]|$)", filename)
    return match.group(1) if match else None


def classify(name: str) -> str:
    if "/" in name:
        return "slash"
    if re.search(r"(?i)\bsp\.?\b", name):
        return "provisionalSp"
    return "species"


def parse(text: str, source_file_name: str) -> dict:
    reported = None
    rows = []
    seen_sample = False
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        count = re.search(r"Number of taxa:\s*(\d+)", line)
        if count:
            reported = int(count.group(1))
            continue
        parts = line.split("\t")
        name = parts[0].strip()
        if name == "Sample Size:":
            seen_sample = True
            continue
        if not name and any(p.strip() == "Jan" for p in parts):
            continue
        if not seen_sample:
            continue
        if not name:
            continue
        values = []
        for part in parts[1:]:
            part = part.strip()
            if not part:
                continue
            values.append(float(part))
        if len(values) < 48:
            continue
        weeks = values[:48]
        means = []
        maxes = []
        for month in range(12):
            slice_ = weeks[month * 4 : month * 4 + 4]
            means.append(sum(slice_) / len(slice_))
            maxes.append(max(slice_))
        rows.append(
            {
                "commonName": name,
                "kind": classify(name),
                "monthlyMean": means,
                "monthlyMax": maxes,
                "weekFrequencies": weeks,
            }
        )
    if not rows:
        raise SystemExit("No species rows parsed")
    return {
        "ebirdLocationId": location_id(source_file_name),
        "sourceFileName": source_file_name,
        "reportedTaxonCount": reported,
        "species": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--month", type=int, default=11, help="Calendar month 1-12")
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    text = args.path.read_text(encoding="utf-8")
    parsed = parse(text, args.path.name)
    month_index = args.month - 1
    kinds = {"species": 0, "slash": 0, "provisionalSp": 0}
    for row in parsed["species"]:
        kinds[row["kind"]] += 1
    means = [row["monthlyMean"][month_index] for row in parsed["species"] if row["kind"] == "species"]
    summary = {
        "file": str(args.path),
        "ebirdLocationId": parsed["ebirdLocationId"],
        "reportedTaxonCount": parsed["reportedTaxonCount"],
        "parsedTaxonCount": len(parsed["species"]),
        "kinds": kinds,
        "month": args.month,
        "speciesAboveNearZero": sum(1 for value in means if value >= NEAR_ZERO),
        "speciesAboveEnrichment": sum(1 for value in means if value >= ENRICHMENT),
        "nearZeroThreshold": NEAR_ZERO,
        "enrichmentFrequencyThreshold": ENRICHMENT,
        "sampleFirst": parsed["species"][0]["commonName"],
        "sampleLast": parsed["species"][-1]["commonName"],
        "crestedGuanNovMean": next(
            row["monthlyMean"][10]
            for row in parsed["species"]
            if row["commonName"] == "Crested Guan"
        ),
    }
    print(json.dumps(summary, indent=2))
    if args.json_out:
        args.json_out.write_text(json.dumps(parsed, indent=2), encoding="utf-8")
    ok = (
        parsed["reportedTaxonCount"] == len(parsed["species"]) == 554
        and parsed["ebirdLocationId"] == "L436229"
        and kinds["species"] == 492
        and abs(summary["crestedGuanNovMean"] - 0.5595) < 0.001
    )
    if not ok:
        print("VERIFY FAILED", file=sys.stderr)
        return 1
    print("VERIFY OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
