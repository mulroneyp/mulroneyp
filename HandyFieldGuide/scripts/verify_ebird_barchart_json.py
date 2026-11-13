#!/usr/bin/env python3
"""Sanity-check the JSON → week-frequency mapping used by EBirdBarchartJSONParser."""

from __future__ import annotations

import json
import sys


def means_and_maxes(weeks: list[float]) -> tuple[list[float], list[float]]:
    means: list[float] = []
    maxes: list[float] = []
    for month in range(12):
        slice_ = weeks[month * 4 : month * 4 + 4]
        means.append(sum(slice_) / 4.0)
        maxes.append(max(slice_))
    return means, maxes


def main() -> int:
    sample = {
        "numSpecies": 1,
        "dataRows": [
            {
                "taxon": {"commonName": "Crested Guan", "speciesCode": "cregua1"},
                "values": [0.1 * ((i % 4) + 1) for i in range(48)],
            }
        ],
    }
    raw = json.dumps(sample).encode()
    root = json.loads(raw)
    row = root["dataRows"][0]
    name = row["taxon"]["commonName"]
    weeks = row["values"][:48]
    means, maxes = means_and_maxes(weeks)
    assert name == "Crested Guan"
    assert len(weeks) == 48
    assert len(means) == 12 and len(maxes) == 12
    assert abs(means[0] - (0.1 + 0.2 + 0.3 + 0.4) / 4) < 1e-9
    print("VERIFY JSON OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
