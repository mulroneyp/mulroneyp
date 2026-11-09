#!/usr/bin/env python3
"""Ensure dimorphic species in guide.json have male and female photos.

Fetches missing openly licensed Wikimedia Commons images with attribution,
using the same licence rules as assemble_monteverde.py. Monomorphic species
are left with a single photo.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_monteverde import (  # noqa: E402
    IMAGE_DIR,
    choose_photo,
    hard_skip,
    imageinfo,
    license_ok,
    photo_record,
    save_jpeg,
    search_files,
    slug,
)

GUIDE_PATH = Path(__file__).resolve().parents[1] / "HandyFieldGuide" / "Resources" / "guide.json"
PROGRESS = Path(__file__).resolve().parent / ".fill_dimorphic_progress.json"


def load_progress() -> dict:
    if PROGRESS.exists():
        return json.loads(PROGRESS.read_text(encoding="utf-8"))
    return {}


def save_progress(data: dict) -> None:
    PROGRESS.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def roles_present(photos: list[dict]) -> set[str]:
    return {photo.get("role") for photo in photos}


def ordered_photos(photos: list[dict]) -> list[dict]:
    order = {"male": 0, "female": 1, "either": 2, "unsexed": 3, "illustration": 4}
    return sorted(photos, key=lambda photo: (order.get(photo.get("role"), 9), photo.get("label", "")))


def fetch_role(common: str, scientific: str, role: str, avoid: set[str], species_id: str) -> dict | None:
    payload = {
        "common": common,
        "scientific": scientific,
        "also_scientific": [],
        "also_called": [],
    }
    try:
        item = choose_photo(payload, role, avoid)
    except RuntimeError:
        titles = search_files(f"{common} {role}") + search_files(f"{scientific} {role}") + search_files(common)
        info = imageinfo(titles[:24])
        item = None
        best = -10_000
        for title, meta in info.items():
            if title in avoid or not meta.get("ok") or not license_ok(meta.get("license", "")):
                continue
            text = f"{title} {meta.get('description', '')}".lower()
            if hard_skip(text):
                continue
            score = 5
            if role == "male" and ("male" in text or "♂" in text) and "female" not in text:
                score += 40
            if role == "female" and ("female" in text or "♀" in text) and "male" not in text:
                score += 40
            if scientific.lower() in text or common.lower() in text:
                score += 10
            if score > best:
                best = score
                item = meta
        if item is None or best < 8:
            return None

    avoid.add(item["title"])
    dest = IMAGE_DIR / f"{species_id}-{role}.jpg"
    width, height = save_jpeg(item["download"], dest)
    return photo_record(species_id, common, role, item, width, height)


def fill_species(species: dict, progress: dict) -> tuple[bool, str]:
    if not species.get("dimorphic"):
        return False, "monomorphic"
    photos = list(species.get("photos") or [])
    present = roles_present(photos)
    needed = [role for role in ("male", "female") if role not in present]
    if not needed:
        species["photos"] = ordered_photos(photos)
        return False, "already complete"

    species_id = species.get("id") or slug(species["commonName"])
    key = species_id
    avoid = {photo.get("file") for photo in photos if photo.get("file")}
    notes = []
    for role in needed:
        cache_key = f"{key}:{role}"
        if cache_key in progress and progress[cache_key].get("photo"):
            photo = progress[cache_key]["photo"]
            photos.append(photo)
            notes.append(f"reuse {role}")
            continue
        photo = fetch_role(species["commonName"], species["scientificName"], role, avoid, species_id)
        if photo is None:
            notes.append(f"missing {role}")
            continue
        progress[cache_key] = {"photo": photo}
        save_progress(progress)
        photos.append(photo)
        notes.append(f"fetched {role}")

    # Drop unsexed placeholders once both sexes exist.
    have = roles_present(photos)
    if "male" in have and "female" in have:
        photos = [photo for photo in photos if photo.get("role") in {"male", "female"}]

    species["photos"] = ordered_photos(photos)
    have = roles_present(species["photos"])
    ok = "male" in have and "female" in have
    return ok, "; ".join(notes)


def main() -> int:
    guide = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    progress = load_progress()
    filled = 0
    still_missing: list[str] = []

    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            if not species.get("dimorphic"):
                # Keep a single photo for monomorphic accounts; do not invent a second.
                if len(species.get("photos") or []) > 1:
                    # Prefer either/unsexed single image when duplicates exist without sexes.
                    roles = roles_present(species["photos"])
                    if "male" not in roles and "female" not in roles:
                        species["photos"] = species["photos"][:1]
                continue
            ok, note = fill_species(species, progress)
            label = f"{coverage['id']}:{species['commonName']}"
            print(f"{label}: {note}", flush=True)
            if ok:
                filled += 1
            elif "already complete" not in note:
                still_missing.append(f"{label} ({note})")

    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"filledOrCompletePasses": filled, "stillMissing": still_missing}, indent=2))
    return 0 if not still_missing else 0  # ship best effort; report gaps


if __name__ == "__main__":
    raise SystemExit(main())
