#!/usr/bin/env python3
"""One-shot patch: add Sky stratum + activeTimes to guide.json (and light supplemental updates)."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUIDE_PATH = ROOT / "HandyFieldGuide" / "Resources" / "guide.json"
SUPP_PATH = ROOT / "HandyFieldGuide" / "Resources" / "ebird_supplemental.json"

ORDER = ["dawn", "morning", "midday", "afternoon", "dusk", "night"]

STRATA = [
    {"id": "ground", "label": "Ground", "hint": "On the ground, a lawn, mud, or the water"},
    {"id": "low", "label": "Low", "hint": "Shrubs, low branches, and the understory"},
    {"id": "mid", "label": "Mid", "hint": "The middle of the forest, or a small tree"},
    {"id": "canopy", "label": "Canopy", "hint": "Crowns of tall trees"},
    {"id": "sky", "label": "Sky", "hint": "Overhead — flying, soaring, or hawking in open air"},
]

# Replace or merge strata for typically aerial birds.
SKY_STRATA = {
    "monteverde": {
        "Turkey Vulture": ["sky"],
        "Black Vulture": ["sky"],
        "White-collared Swift": ["sky"],
        "Broad-winged Hawk": ["sky"],
        "Short-tailed Hawk": ["sky"],
        "Barred Hawk": ["sky"],
        "White Hawk": ["sky", "canopy"],
        "King Vulture": ["sky"],
        "Ornate Hawk-Eagle": ["sky", "canopy"],
        "Black Hawk-Eagle": ["sky", "canopy"],
        "Crimson-fronted Parakeet": ["canopy", "sky"],
    },
    "greater-melbourne": {
        "Nankeen Kestrel": ["sky", "low", "mid"],
        "Black-shouldered Kite": ["sky", "low", "mid"],
        "Welcome Swallow": ["sky", "low"],
        "Silver Gull": ["ground", "low", "sky"],
        "Pacific Gull": ["ground", "sky"],
        "Greater Crested Tern": ["ground", "low", "sky"],
    },
}

# Curated most-likely periods (broad field knowledge, not clock times).
ACTIVE_OVERRIDES = {
    # Monteverde nocturnal / crepuscular
    "Mottled Owl": ["dusk", "night"],
    "Spectacled Owl": ["dusk", "night"],
    "Crested Owl": ["dusk", "night"],
    "Costa Rican Pygmy-Owl": ["dawn", "dusk", "day"],  # fixed below — pygmy-owls often call by day
    # Dawn-noted
    "Crested Guan": ["dawn", "morning"],
    "Gray-cowled Wood-Rail": ["dawn", "morning"],
    # Aerial / thermal
    "Turkey Vulture": ["morning", "midday", "afternoon"],
    "Black Vulture": ["morning", "midday", "afternoon"],
    "King Vulture": ["morning", "midday", "afternoon"],
    "White-collared Swift": ["morning", "midday", "afternoon"],
    "Broad-winged Hawk": ["morning", "midday", "afternoon"],
    "Short-tailed Hawk": ["morning", "midday", "afternoon"],
    "Barred Hawk": ["morning", "midday", "afternoon"],
    "White Hawk": ["morning", "midday", "afternoon"],
    "Ornate Hawk-Eagle": ["morning", "midday", "afternoon"],
    "Black Hawk-Eagle": ["morning", "midday", "afternoon"],
    "Roadside Hawk": ["morning", "afternoon"],
    "Gray Hawk": ["morning", "afternoon"],
    "Semiplumbeous Hawk": ["morning", "afternoon"],
    # Melbourne specials
    "Nankeen Night-Heron": ["dusk", "night"],
    "Little Penguin": ["dusk", "night"],
    "Tawny Frogmouth": ["dusk", "night"],
    "Laughing Kookaburra": ["dawn", "morning"],
    "Nankeen Kestrel": ["morning", "midday", "afternoon"],
    "Black-shouldered Kite": ["morning", "midday", "afternoon"],
    "Welcome Swallow": ["morning", "midday", "afternoon"],
    "Silver Gull": ["morning", "midday", "afternoon"],
    "Pacific Gull": ["morning", "midday", "afternoon"],
    "Greater Crested Tern": ["morning", "midday", "afternoon"],
}

# Fix pygmy-owl: often diurnal calling
ACTIVE_OVERRIDES["Costa Rican Pygmy-Owl"] = ["dawn", "morning", "afternoon", "dusk"]


def normalize_times(times: list[str]) -> list[str]:
    cleaned = []
    for item in times:
        if item == "day":
            continue
        if item in ORDER and item not in cleaned:
            cleaned.append(item)
    return [period for period in ORDER if period in cleaned]


def default_times(name: str, summary: str, habitat: str) -> list[str]:
    if name in ACTIVE_OVERRIDES:
        return normalize_times(ACTIVE_OVERRIDES[name])
    blob = f"{name} {summary} {habitat}".lower()
    if any(token in blob for token in ("night bird", "nocturnal", "by night", "after dark")):
        return ["dusk", "night"]
    if "owl" in name.lower() or "frogmouth" in name.lower() or "night-heron" in name.lower():
        return ["dusk", "night"]
    if "ashore at dusk" in blob or "at dusk" in blob and "penguin" in name.lower():
        return ["dusk", "night"]
    if "dawn" in blob:
        return ["dawn", "morning"]
    # Default diurnal songbird / park bird: morning and afternoon are the safest “most likely” windows.
    return ["morning", "afternoon"]


def patch_species(coverage_id: str, species: dict) -> None:
    name = species["commonName"]
    sky_map = SKY_STRATA.get(coverage_id, {})
    if name in sky_map:
        species["strata"] = sky_map[name]
        if "sky" in species["strata"] and "canopy" not in species["strata"]:
            note = species.get("stratumNote", "")
            if "canopy mark means the sky" in note or "canopy" in note.lower() and "sky" not in note.lower():
                species["stratumNote"] = "Usually overhead in open air, not in the shrub layer."
            elif not note or "canopy" in note.lower():
                species["stratumNote"] = "Usually overhead in open air."
        elif "sky" in species["strata"] and "canopy" in species["strata"]:
            species["stratumNote"] = "Often overhead, and sometimes on a high perch in the canopy."
    species["activeTimes"] = default_times(name, species.get("summary", ""), species.get("habitat", ""))


def guess_supp_strata(common: str, strata: list[str]) -> list[str]:
    lower = common.lower()
    aerial_keys = (
        "swift",
        "swallow",
        "martin",
        "vulture",
        "kite",
        "hawk",
        "eagle",
        "falcon",
        "kestrel",
        "caracara",
        "frigate",
        "tern",
        "jaeger",
    )
    if any(key in lower for key in aerial_keys):
        if "sky" not in strata:
            # Prefer sky for true aerial hunters; keep a perch band when already present.
            if strata == ["canopy", "mid"] or strata == ["mid", "canopy"]:
                return ["sky"]
            merged = list(strata)
            if "sky" not in merged:
                merged.append("sky")
            return merged
    return strata


def guess_supp_times(common: str) -> list[str]:
    lower = common.lower()
    if any(key in lower for key in ("owl", "nightjar", "pauraque", "potoo", "frogmouth", "night-heron")):
        return ["dusk", "night"]
    if any(key in lower for key in ("swift", "swallow", "vulture", "kite", "hawk", "eagle", "falcon", "kestrel")):
        return ["morning", "midday", "afternoon"]
    return ["morning", "afternoon"]


def main() -> None:
    guide = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    guide["strata"] = STRATA
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            patch_species(coverage["id"], species)

    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    supplemental = json.loads(SUPP_PATH.read_text(encoding="utf-8"))
    for species in supplemental:
        species["strata"] = guess_supp_strata(species["commonName"], species.get("strata", ["mid"]))
        species["activeTimes"] = guess_supp_times(species["commonName"])
        if "sky" in species["strata"]:
            species["stratumNote"] = f"Estimated habitat zone: {', '.join(species['strata'])}."
            habitat = species.get("habitat", "")
            for old in (
                "Typical habitat zone estimated as",
                "Typical height band estimated as",
            ):
                if old in habitat:
                    prefix = habitat.split(old)[0]
                    species["habitat"] = (
                        prefix + f"Typical habitat zone estimated as {', '.join(species['strata'])}."
                    ).strip()
                    break
    SUPP_PATH.write_text(json.dumps(supplemental, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    sky_count = sum(
        1
        for coverage in guide["coverages"]
        for species in coverage["species"]
        if "sky" in species["strata"]
    )
    print(f"patched guide sky_species={sky_count} strata={len(guide['strata'])} supplemental={len(supplemental)}")


if __name__ == "__main__":
    main()
