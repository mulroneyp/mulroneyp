#!/usr/bin/env python3
"""Build ebird_supplemental.json + images for high-frequency imported taxa.

Uses the bundled L436229 barchart. Reuses names already present in guide.json.
For the rest, downloads openly licensed Wikimedia Commons photographs with the
same licence rules as assemble_monteverde.py.

Enrichment set (documented threshold):
  - kind == species
  - November mean frequency >= 0.05
  - OR among the top 40 species by November mean
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_monteverde import (  # noqa: E402
    choose_photo,
    hard_skip,
    license_ok,
    name_match,
    photo_record,
    resolve_scientific,
    save_jpeg,
    sex_flags,
    slug,
)
from verify_ebird_barchart import ENRICHMENT, NEAR_ZERO, parse  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "HandyFieldGuide" / "Resources"
IMAGE_DIR = RESOURCE / "images"
GUIDE_PATH = RESOURCE / "guide.json"
FIXTURE = RESOURCE / "fixtures" / "ebird_L436229__2020_2026_1_12_barchart.txt"
OUT_JSON = RESOURCE / "ebird_supplemental.json"
PROGRESS = ROOT / "scripts" / ".ebird_supplemental_progress.json"

# Rough height bands for Costa Rican garden / foothill birds when not curated.
KEYWORD_STRATA = [
    (("duck", "teal", "heron", "egret", "guan", "curassow", "quail", "dove", "pigeon", "ground", "tinamou", "rail", "jacana", "sandpiper", "plover", "thrush", "sparrow", "seedeater", "grassquit", "ani", "pauraque", "wood-quail"), ["ground", "low"]),
    (("swift", "swallow", "martin", "kite", "hawk", "eagle", "falcon", "caracara", "vulture", "kestrel", "frigate", "tern"), ["sky"]),
    (("hummingbird", "jacobin", "coquette", "plumeleteer", "goldentail", "sabrewing", "emerald", "woodstar", "hermit", "toucan", "aracari", "oriole", "euphonia", "honeycreeper", "dacnis", "tanager", "chlorophonia"), ["canopy", "mid"]),
    (("wren", "antbird", "antwren", "gnatwren", "manakin", "becard", "flycatcher", "pewee", "tyrannulet", "tody", "woodcreeper", "foliage", "xenops", "puffbird", "motmot", "trogon"), ["low", "mid"]),
]


def normalize(name: str) -> str:
    text = name.lower().replace("grey", "gray")
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def guide_index(guide: dict) -> dict[str, dict]:
    mapping: dict[str, dict] = {}
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            mapping[normalize(species["commonName"])] = species
            for alias in species.get("aliases", []) + species.get("alsoCalled", []):
                mapping.setdefault(normalize(alias), species)
    return mapping


def guess_strata(common: str) -> list[str]:
    low = common.lower()
    for keys, strata in KEYWORD_STRATA:
        if any(key in low for key in keys):
            return strata
    return ["mid"]


def guess_group(common: str) -> str:
    low = common.lower()
    if any(word in low for word in ("hummingbird", "jacobin", "coquette", "plumeleteer", "goldentail", "sabrewing", "emerald", "woodstar", "hermit")):
        return "hummingbirds"
    if any(word in low for word in ("warbler", "redstart", "waterthrush", "yellowthroat")):
        return "warblers"
    if any(word in low for word in ("tanager", "honeycreeper", "dacnis", "euphonia", "chlorophonia", "bananaquit")):
        return "tanagers"
    if any(word in low for word in ("flycatcher", "pewee", "tyrant", "tyrannulet", "becard", "tody", "attila", "kiskadee")):
        return "flycatchers"
    if any(word in low for word in ("wren", "thrush", "robin", "nightingale")):
        return "songbirds"
    return "imported"


def wikipedia_scientific(common: str) -> str:
    """Prefer Wikidata / Commons binomial resolution over summary-extract regex."""
    return resolve_scientific(common, "")


def load_progress() -> dict:
    if PROGRESS.exists():
        return json.loads(PROGRESS.read_text(encoding="utf-8"))
    return {}


def save_progress(progress: dict) -> None:
    PROGRESS.write_text(json.dumps(progress, indent=2, ensure_ascii=False), encoding="utf-8")


def enrichment_targets(parsed: dict, month_index: int = 10) -> list[dict]:
    species_rows = [row for row in parsed["species"] if row["kind"] == "species"]
    ranked = sorted(species_rows, key=lambda row: row["monthlyMean"][month_index], reverse=True)
    top_names = {row["commonName"] for row in ranked[:40]}
    chosen = []
    for row in species_rows:
        freq = row["monthlyMean"][month_index]
        if freq >= ENRICHMENT or row["commonName"] in top_names:
            chosen.append(row)
    chosen.sort(key=lambda row: row["monthlyMean"][month_index], reverse=True)
    return chosen


DIMORPHIC_HINTS = (
    "tanager", "dacnis", "honeycreeper", "euphonia", "chlorophonia", "oriole",
    "grosbeak", "seedeater", "grassquit", "manakin", "bellbird", "umbrellabird",
    "antbird", "antwren", "woodpecker", "trogon", "barbet", "hummingbird",
    "woodnymph", "sabrewing", "woodstar", "fairy", "thorntail", "warbler",
    "redstart", "duck", "teal", "oriole", "cacique", "cowbird", "blackbird",
)


def likely_dimorphic(common: str) -> bool:
    low = common.lower()
    return any(hint in low for hint in DIMORPHIC_HINTS)


def guess_active_times(common: str) -> list[str]:
    low = common.lower()
    if any(key in low for key in ("owl", "nightjar", "pauraque", "potoo", "frogmouth", "night-heron")):
        return ["dusk", "night"]
    if any(key in low for key in ("swift", "swallow", "martin", "vulture", "kite", "hawk", "eagle", "falcon", "kestrel")):
        return ["morning", "midday", "afternoon"]
    return ["morning", "afternoon"]


def make_stub(common: str, scientific: str, photos: list[dict]) -> dict:
    strata = guess_strata(common)
    roles = {photo.get("role") for photo in photos}
    dimorphic = "male" in roles and "female" in roles
    if not dimorphic and likely_dimorphic(common) and len(photos) >= 2:
        dimorphic = True
    alts = alt_names_for(common)
    return {
        "id": slug(common),
        "commonName": common,
        "scientificName": scientific or "—",
        "aliases": list(alts),
        "alsoCalled": list(alts),
        "alsoScientific": [],
        "tags": ["imported", "ebird-supplemental"],
        "dimorphic": dimorphic,
        "origin": "native",
        "status": "imported",
        "group": guess_group(common),
        "strata": strata,
        "activeTimes": guess_active_times(common),
        "summary": "High-frequency species on the imported eBird barchart; field notes are a short placeholder.",
        "habitat": (
            f"Seen on complete checklists for the imported eBird location. "
            f"Typical height band estimated as {', '.join(strata)}. "
            "Curate a better habitat line when you know the site."
        ),
        "sexes": (
            "Male and female photographs are shown when openly licensed images were found."
            if dimorphic
            else "Sexes look alike, or are not separated in the bundled photograph set."
        ),
        "stratumNote": f"Estimated height band: {', '.join(strata)}.",
        "photos": photos,
    }


def alt_names_for(common: str) -> list[str]:
    """Lightweight open aliases for awkward eBird / checklist common names."""
    aliases = {
        "Gartered Violaceous Trogon": [
            "Gartered Trogon",
            "Northern Violaceous Trogon",
            "Violaceous Trogon",
        ],
        "Scaly-breasted Hummingbird": ["Scaly-breasted Sabrewing"],
    }
    return list(aliases.get(common, []))


def fetch_one(common: str, scientific: str, role: str, avoid: set[str], species_id: str):
    payload = {
        "common": common,
        "scientific": scientific or common,
        "also_scientific": [],
        "also_called": alt_names_for(common),
        "aliases": alt_names_for(common),
    }
    want = role if role != "unsexed" else "either"
    try:
        item = choose_photo(payload, want, avoid)
    except RuntimeError:
        return None
    if not item or not license_ok(item.get("license", "")):
        return None
    text = f"{item.get('title', '')} {item.get('description', '')}".lower()
    if hard_skip(text) or not name_match(text, payload):
        return None
    # If Commons clearly labels sex, keep that role rather than forcing unsexed.
    male, female = sex_flags(text)
    photo_role = role
    if role in {"either", "unsexed"}:
        if male and not female:
            photo_role = "male"
        elif female and not male:
            photo_role = "female"
        else:
            photo_role = "unsexed"
    elif role == "male" and not (male and not female):
        return None
    elif role == "female" and not (female and not male):
        return None
    avoid.add(item["title"])
    filename = (
        f"{species_id}.jpg"
        if photo_role in {"either", "unsexed"}
        else f"{species_id}-{photo_role}.jpg"
    )
    dest = IMAGE_DIR / filename
    width, height = save_jpeg(item["download"], dest)
    return photo_record(species_id, common, photo_role, item, width, height)


def fetch_photos(common: str, scientific: str, progress: dict) -> list[dict]:
    species_id = slug(common)
    if species_id in progress and progress[species_id].get("photos"):
        existing = progress[species_id]["photos"]
        roles = {photo.get("role") for photo in existing}
        if likely_dimorphic(common) and not ({"male", "female"} <= roles):
            # Upgrade older single-photo cache entries for dimorphic taxa.
            pass
        else:
            return existing
    avoid: set[str] = set()
    photos: list[dict] = []
    if likely_dimorphic(common):
        for role in ("male", "female"):
            photo = fetch_one(common, scientific, role, avoid, species_id)
            if photo:
                photos.append(photo)
        if len(photos) < 2:
            # Fall back to one unsexed image rather than inventing a sex.
            fallback = fetch_one(common, scientific, "either", avoid, species_id)
            if fallback and not photos:
                photos.append(fallback)
    else:
        photo = fetch_one(common, scientific, "either", avoid, species_id)
        if photo:
            photos.append(photo)
    progress[species_id] = {"common": common, "scientific": scientific, "photos": photos}
    save_progress(progress)
    return photos


def main() -> int:
    guide = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    index = guide_index(guide)
    parsed = parse(FIXTURE.read_text(encoding="utf-8"), FIXTURE.name)
    targets = enrichment_targets(parsed)
    progress = load_progress()
    supplemental: list[dict] = []
    skipped_existing = 0
    fetched = 0
    failed: list[str] = []

    for row in targets:
        common = row["commonName"]
        if normalize(common) in index:
            skipped_existing += 1
            continue
        scientific = wikipedia_scientific(common)
        try:
            photos = fetch_photos(common, scientific, progress)
        except Exception as exc:  # noqa: BLE001
            failed.append(f"{common}: {exc}")
            photos = []
        if not photos:
            failed.append(common)
            continue
        supplemental.append(make_stub(common, scientific, photos))
        fetched += 1
        print(f"ok {fetched}: {common} ({len(photos)} photo)")

    OUT_JSON.write_text(json.dumps(supplemental, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report = {
        "targets": len(targets),
        "alreadyInGuide": skipped_existing,
        "supplementalWritten": len(supplemental),
        "failed": failed,
        "nearZeroThreshold": NEAR_ZERO,
        "enrichmentFrequencyThreshold": ENRICHMENT,
        "out": str(OUT_JSON),
    }
    print(json.dumps(report, indent=2))
    return 0 if supplemental or skipped_existing else 1


if __name__ == "__main__":
    raise SystemExit(main())
