#!/usr/bin/env python3
"""Ensure dimorphic species have male and female photos when open images exist.

Fetches missing openly licensed Wikimedia Commons images with attribution,
using the widened Commons search in assemble_monteverde.py (alt names,
scientific names, sex keywords; PD / CC0 / CC BY / CC BY-SA / GFDL only).

Also:
  - resolves missing scientific names
  - relabels unsexed photos that are clearly male/female on Commons
  - leaves monomorphic species with a single photo (does not invent sexes)
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
    name_match,
    photo_record,
    resolve_scientific,
    save_jpeg,
    sex_flags,
    slug,
)

GUIDE_PATH = Path(__file__).resolve().parents[1] / "HandyFieldGuide" / "Resources" / "guide.json"
SUPPLEMENTAL_PATH = Path(__file__).resolve().parents[1] / "HandyFieldGuide" / "Resources" / "ebird_supplemental.json"
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


def species_payload(species: dict) -> dict:
    common = species["commonName"]
    scientific = (species.get("scientificName") or "").strip()
    if scientific in {"", "—", "-", "?"}:
        scientific = resolve_scientific(common, "")
        if scientific:
            species["scientificName"] = scientific
    return {
        "common": common,
        "scientific": scientific or common,
        "also_scientific": list(species.get("alsoScientific") or []),
        "also_called": list(species.get("alsoCalled") or []) + list(species.get("aliases") or []),
        "aliases": list(species.get("aliases") or []),
    }


def relabel_sexed_photos(species: dict) -> list[str]:
    """If an unsexed photo's Commons title/description names a sex, fix the role."""
    notes = []
    photos = list(species.get("photos") or [])
    changed = False
    for photo in photos:
        if photo.get("role") not in {"unsexed", "either"}:
            continue
        blob = f"{photo.get('file') or ''} {photo.get('alt') or ''} {photo.get('label') or ''}"
        title = photo.get("file") or ""
        if title:
            info = imageinfo([title])
            meta = info.get(title) or next(iter(info.values()), None)
            if meta:
                blob = f"{meta.get('title', '')} {meta.get('description', '')}"
        male, female = sex_flags(blob.lower())
        if male and not female:
            photo["role"] = "male"
            photo["label"] = "Male"
            photo["alt"] = f"Male {species['commonName']}"
            # Prefer sexed filename when moving off the unsexed slot.
            src_name = Path(photo["src"]).name
            species_id = species.get("id") or slug(species["commonName"])
            if not src_name.endswith("-male.jpg"):
                dest = IMAGE_DIR / f"{species_id}-male.jpg"
                src_path = Path(__file__).resolve().parents[1] / "HandyFieldGuide" / "Resources" / photo["src"]
                if src_path.exists() and src_path.resolve() != dest.resolve():
                    dest.write_bytes(src_path.read_bytes())
                    photo["src"] = f"images/{dest.name}"
            changed = True
            notes.append("relabel→male")
        elif female and not male:
            photo["role"] = "female"
            photo["label"] = "Female"
            photo["alt"] = f"Female {species['commonName']}"
            src_name = Path(photo["src"]).name
            species_id = species.get("id") or slug(species["commonName"])
            if not src_name.endswith("-female.jpg"):
                dest = IMAGE_DIR / f"{species_id}-female.jpg"
                src_path = Path(__file__).resolve().parents[1] / "HandyFieldGuide" / "Resources" / photo["src"]
                if src_path.exists() and src_path.resolve() != dest.resolve():
                    dest.write_bytes(src_path.read_bytes())
                    photo["src"] = f"images/{dest.name}"
            changed = True
            notes.append("relabel→female")
    if changed:
        species["photos"] = ordered_photos(photos)
    return notes


def fetch_role(payload: dict, role: str, avoid: set[str], species_id: str) -> dict | None:
    try:
        item = choose_photo(payload, role, avoid)
    except RuntimeError:
        return None
    if not item or not license_ok(item.get("license", "")):
        return None
    text = f"{item.get('title', '')} {item.get('description', '')}".lower()
    if hard_skip(text) or not name_match(text, payload):
        return None
    male, female = sex_flags(text)
    if role == "male" and not (male and not female):
        return None
    if role == "female" and not (female and not male):
        return None
    avoid.add(item["title"])
    dest = IMAGE_DIR / f"{species_id}-{role}.jpg"
    width, height = save_jpeg(item["download"], dest)
    return photo_record(species_id, payload["common"], role, item, width, height)


def fill_species(species: dict, progress: dict) -> tuple[bool, str]:
    notes = []
    if not species.get("dimorphic"):
        photos = list(species.get("photos") or [])
        if len(photos) > 1:
            roles = roles_present(photos)
            if "male" not in roles and "female" not in roles:
                species["photos"] = photos[:1]
        return False, "monomorphic"

    notes.extend(relabel_sexed_photos(species))

    photos = list(species.get("photos") or [])
    present = roles_present(photos)
    needed = [role for role in ("male", "female") if role not in present]
    if not needed:
        # Drop unsexed placeholders once both sexes exist.
        photos = [photo for photo in photos if photo.get("role") in {"male", "female"}]
        species["photos"] = ordered_photos(photos)
        return True, "; ".join(notes + ["already complete"])

    if species.get("scientificName") in {None, "", "—", "-", "?"}:
        resolved = resolve_scientific(species["commonName"], "")
        if resolved:
            species["scientificName"] = resolved
            notes.append(f"sci={resolved}")

    # Known checklist aliases for awkward common / synonym scientific names.
    # Do not invent taxa — only alternate labels for the same species.
    alias_map = {
        "Gartered Violaceous Trogon": {
            "alsoCalled": ["Gartered Trogon", "Northern Violaceous Trogon", "Violaceous Trogon"],
            "alsoScientific": ["Trogon violaceus"],
        },
        "Scaly-breasted Hummingbird": {
            "alsoCalled": ["Scaly-breasted Sabrewing"],
            "alsoScientific": ["Campylopterus cuvierii"],
        },
        "Dull-mantled Antbird": {
            "alsoCalled": [],
            "alsoScientific": ["Sipia laemosticta", "Myrmeciza laemosticta"],
        },
        "Middle American Leaftosser": {
            "alsoCalled": ["Tawny-throated Leaftosser", "Mexican Leaftosser"],
            "alsoScientific": ["Sclerurus mexicanus"],
        },
        "Blue-vented Hummingbird": {
            "alsoCalled": ["Steely-vented Hummingbird"],
            "alsoScientific": ["Saucerottia saucerottei", "Amazilia saucerottei"],
        },
        "Morelet's Seedeater": {
            "alsoCalled": ["White-collared Seedeater"],
            "alsoScientific": ["Sporophila moreleti", "Sporophila torqueola"],
        },
        "Black-thighed Grosbeak": {
            "alsoCalled": ["Black-thighed Grosbeak"],
            "alsoScientific": ["Pheucticus tibialis"],
        },
    }
    if species["commonName"] in alias_map:
        extras = alias_map[species["commonName"]]
        called = list(species.get("alsoCalled") or [])
        for alias in extras.get("alsoCalled") or []:
            if alias not in called:
                called.append(alias)
        species["alsoCalled"] = called
        aliases = list(species.get("aliases") or [])
        for alias in extras.get("alsoCalled") or []:
            if alias not in aliases:
                aliases.append(alias)
        species["aliases"] = aliases
        also_sci = list(species.get("alsoScientific") or [])
        for syn in extras.get("alsoScientific") or []:
            if syn not in also_sci and syn != species.get("scientificName"):
                also_sci.append(syn)
        species["alsoScientific"] = also_sci

    species_id = species.get("id") or slug(species["commonName"])
    payload = species_payload(species)
    avoid = {photo.get("file") for photo in photos if photo.get("file")}
    for role in needed:
        cache_key = f"{species_id}:{role}"
        if cache_key in progress and progress[cache_key].get("photo"):
            photo = progress[cache_key]["photo"]
            photos.append(photo)
            notes.append(f"reuse {role}")
            continue
        photo = fetch_role(payload, role, avoid, species_id)
        if photo is None:
            notes.append(f"missing {role}")
            continue
        progress[cache_key] = {"photo": photo}
        save_progress(progress)
        photos.append(photo)
        notes.append(f"fetched {role}")

    have = roles_present(photos)
    if "male" in have and "female" in have:
        photos = [photo for photo in photos if photo.get("role") in {"male", "female"}]
        # Mark complete dimorphic pairs clearly in sexes text when previously apologetic.
        sexes = species.get("sexes") or ""
        if "not found" in sexes.lower() or "only a labeled" in sexes.lower():
            species["sexes"] = (
                sexes.split(" The photograph")[0].split(" An openly")[0].split(" Only a")[0].strip()
            )

    species["photos"] = ordered_photos(photos)
    have = roles_present(species["photos"])
    ok = "male" in have and "female" in have
    return ok, "; ".join(notes)


def iter_species_lists():
    guide = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    lists = []
    for coverage in guide["coverages"]:
        lists.append((coverage["id"], coverage["species"], GUIDE_PATH))
    if SUPPLEMENTAL_PATH.exists():
        supplemental = json.loads(SUPPLEMENTAL_PATH.read_text(encoding="utf-8"))
        lists.append(("ebird_supplemental", supplemental, SUPPLEMENTAL_PATH))
    return lists, guide


def main() -> int:
    progress = load_progress()
    lists, guide = iter_species_lists()
    filled = 0
    still_missing: list[str] = []
    baseline_photos = 0
    after_photos = 0

    supplemental_list = None
    for label, species_list, path in lists:
        if label == "ebird_supplemental":
            supplemental_list = species_list
        for species in species_list:
            baseline_photos += len(species.get("photos") or [])
            if not species.get("dimorphic"):
                after_photos += len(species.get("photos") or [])
                continue
            ok, note = fill_species(species, progress)
            after_photos += len(species.get("photos") or [])
            print(f"{label}:{species['commonName']}: {note}", flush=True)
            if ok:
                filled += 1
            elif "already complete" not in note:
                still_missing.append(f"{label}:{species['commonName']} ({note})")

    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if supplemental_list is not None:
        SUPPLEMENTAL_PATH.write_text(
            json.dumps(supplemental_list, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    report = {
        "dimorphicCompletePasses": filled,
        "stillMissing": still_missing,
        "photoSlotsBefore": baseline_photos,
        "photoSlotsAfter": after_photos,
        "photoSlotsAdded": after_photos - baseline_photos,
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
