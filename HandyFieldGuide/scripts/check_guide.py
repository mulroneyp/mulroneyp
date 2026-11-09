#!/usr/bin/env python3
"""Check guide.json against the Children's Eternal Rainforest checklist."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from monteverde_species import SPECIES

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "HandyFieldGuide" / "Resources"
GUIDE = json.loads((RESOURCE / "guide.json").read_text(encoding="utf-8"))

ALLOWED = ("cc0", "cc-zero", "public domain", "cc by", "cc-by", "gfdl", "free documentation", "pd")


def license_ok(short: str) -> bool:
    text = (short or "").strip().lower().replace("_", " ")
    if any(flag in text for flag in ("nc", "noncommercial", "non-commercial", "nd", "noderiv")):
        return False
    return any(flag in text for flag in ALLOWED) or text in {"pd", "no restrictions"}


def main() -> None:
    errors = []
    if GUIDE["defaultCoverageId"] != "monteverde":
        errors.append(f"default is {GUIDE['defaultCoverageId']}")
    ids = [item["id"] for item in GUIDE["coverages"]]
    if ids != ["monteverde", "greater-melbourne"]:
        errors.append(f"coverage order {ids}")
    monteverde = GUIDE["coverages"][0]
    melbourne = GUIDE["coverages"][1]
    names = [item["commonName"] for item in monteverde["species"]]
    expected = [item["common"] for item in SPECIES]
    if names != expected:
        errors.append(f"name mismatch: {len(names)} vs {len(expected)}")
        for index, (got, want) in enumerate(zip(names, expected)):
            if got != want:
                errors.append(f"  at {index}: {got!r} != {want!r}")
                break
        if len(names) != len(expected):
            errors.append(f"  lengths {len(names)} {len(expected)}")
    if len(melbourne["species"]) < 70:
        errors.append(f"melbourne species {len(melbourne['species'])}")
    stratum_ids = [item["id"] for item in GUIDE["strata"]]
    if stratum_ids != ["ground", "low", "mid", "canopy", "sky"]:
        errors.append(f"strata {stratum_ids}")
    allowed_times = {"dawn", "morning", "midday", "afternoon", "dusk", "night"}
    for coverage in GUIDE["coverages"]:
        for species in coverage["species"]:
            times = species.get("activeTimes")
            if not isinstance(times, list) or not times:
                errors.append(f"missing activeTimes {coverage['id']} {species['commonName']}")
            elif any(item not in allowed_times for item in times):
                errors.append(f"bad activeTimes {species['commonName']} {times}")
            for band in species.get("strata", []):
                if band not in stratum_ids:
                    errors.append(f"unknown stratum {species['commonName']} {band}")
    if any(item["closestCoverageId"] == "san-jose" for item in GUIDE["outside"]):
        errors.append("outside still points at san-jose")
    if any("monteverde" in item["names"] for item in GUIDE["outside"]):
        errors.append("monteverde is listed as an outside place")
    for species in monteverde["species"]:
        roles = [photo["role"] for photo in species["photos"]]
        allowed = {"male", "female", "unsexed", "illustration"} if species["dimorphic"] else {"either", "illustration"}
        if not roles or any(role not in allowed for role in roles):
            errors.append(f"{species['commonName']} roles {roles}")
        if species["dimorphic"] and "look alike" in species["sexes"].lower():
            errors.append(f"{species['commonName']} dimorphic text says look alike")
        if species["commonName"] not in expected:
            errors.append(f"invented {species['commonName']}")
        for photo in species["photos"]:
            path = RESOURCE / photo["src"]
            if not path.exists() or path.stat().st_size < 2000:
                errors.append(f"missing image {photo['src']}")
            if not license_ok(photo["license"]):
                errors.append(f"bad license {species['commonName']} {photo['license']}")
            if not photo.get("author") or not photo.get("sourceUrl"):
                errors.append(f"missing credit {species['commonName']}")
    image_names = {path.name for path in (RESOURCE / "images").glob("*.jpg")}
    used = set()
    for coverage in GUIDE["coverages"]:
        for species in coverage["species"]:
            for photo in species["photos"]:
                used.add(Path(photo["src"]).name)
    extra = sorted(image_names - used)
    if extra:
        errors.append(f"unreferenced images: {extra[:12]}")
    if errors:
        print("\n".join(errors))
        raise SystemExit(1)
    dimorphic = sum(1 for item in monteverde["species"] if item["dimorphic"])
    print(
        f"ok monteverde={len(monteverde['species'])} dimorphic={dimorphic} "
        f"melbourne={len(melbourne['species'])} images={len(used)}"
    )


if __name__ == "__main__":
    main()
