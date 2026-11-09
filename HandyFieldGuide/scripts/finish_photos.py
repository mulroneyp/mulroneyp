#!/usr/bin/env python3
"""Replace bad or missing photos, then write guide.json.

Files were chosen from Wikimedia Commons after the bulk download. Each one
is an openly licensed photograph, except the Spotted Barbtail, where the only
open image found is a historical plate.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_monteverde import (  # noqa: E402
    GUIDE_PATH,
    IMAGE_DIR,
    PROGRESS_PATH,
    SPECIES,
    STRATA,
    imageinfo,
    make_record,
    monteverde_coverage,
    outside_places,
    photo_record,
    prune_images,
    save_jpeg,
    slug,
)

# common name -> note appended to the sexes line, and explicit Commons files.
# role, file title, optional label override.
FIXES: dict[str, dict] = {
    "Violet Sabrewing": {
        "note": "The Santa Elena photograph is not labeled male or female.",
        "photos": [("unsexed", "File:Campylopterus hemileucurus Santa Elena 2.JPG")],
    },
    "Red-legged Honeycreeper": {
        "photos": [
            ("male", "File:Cyanerpes cyaneus Mielero patirrojo Red-legged Honeycreeper (male) (8113956927).jpg"),
            ("female", "File:Cyanerpes cyaneus-20090405.jpg"),
        ],
    },
    "Golden-browed Chlorophonia": {
        "note": "The Monteverde photograph is not labeled male or female.",
        "photos": [("unsexed", "File:Chlorophonia callophrys 01.jpg")],
    },
    "Violet-headed Hummingbird": {
        "note": "Only a labeled female photograph was available under an open licence.",
        "photos": [("female", "File:Violet-headed Hummingbird (female).jpg")],
    },
    "Stripe-tailed Hummingbird": {
        "note": "Only a labeled male photograph, from near Santa Elena, was available under an open licence.",
        "photos": [("male", "File:Stripe-tailed Hummingbird.jpg")],
    },
    "Canada Warbler": {
        "note": "The duller bird is labeled female or immature, which is how many look in November.",
        "photos": [
            ("male", "File:Canada warbler (Cardellina canadensis) male San Isidro.jpg"),
            ("female", "File:Female or immature Canada warbler (46888).jpg", "Female or immature"),
        ],
    },
    "Bare-necked Umbrellabird": {
        "note": "The photograph is not labeled to sex. A nineteenth-century plate of a male was not used.",
        "photos": [("unsexed", "File:Cephalopterus glabricollis - Bare-necked Umbrellabird.jpg")],
    },
    "Magenta-throated Woodstar": {
        "note": "Only a labeled female photograph, from Monteverde, was available under an open licence.",
        "photos": [("female", "File:Calliphlox bryantae, Monteverde, Costa Rica.jpg")],
    },
    "White-ruffed Manakin": {
        "note": "Only a labeled male photograph was available under an open licence.",
        "photos": [("male", "File:Flickr - Rainbirder - White-ruffed Manakin (Corapipo altera) displaying male.jpg")],
    },
    "Spotted Antbird": {
        "note": "Only a labeled female photograph was available under an open licence.",
        "photos": [("female", "File:Spotted Antbird RWD.jpg")],
    },
    "Slaty Antwren": {
        "note": "The photograph is not labeled male or female.",
        "photos": [("unsexed", "File:Slaty Antwren Myrmotherula schisticolor - Flickr - gailhampshire.jpg")],
    },
    "Three-wattled Bellbird": {
        "note": "Only a labeled male photograph was available under an open licence.",
        "photos": [("male", "File:Procnias tricarunculata -Costa Rica -male-8-4c.jpg")],
    },
    "Red-fronted Parrotlet": {
        "photos": [("either", "File:Touit costaricensis - Roger A. Morales-Flores - 722302079.jpeg")],
    },
    "Black-and-yellow Tanager": {
        "note": "The Costa Rica photograph is not labeled male or female.",
        "photos": [("unsexed", "File:Chrysothlypis chrysomelas 316632168.jpg")],
    },
    "Dusky-capped Flycatcher": {
        "photos": [("either", "File:Dusky-capped flycatcher (Myiarchus tuberculifer atriceps) San Isidro.jpg")],
    },
    "Broad-winged Hawk": {
        "photos": [("either", "File:Broad-winged hawk in Costa Rica.jpg")],
    },
    "Song Wren": {
        "photos": [("either", "File:Song Wren - iNaturalist Panamá.jpg")],
    },
    "Rufous-breasted Antthrush": {
        "photos": [("either", "File:Rufous-breasted Antthrush (5201438136).jpg")],
    },
    "Spotted Barbtail": {
        "note": "No openly licensed field photograph was found, so the picture is a historical illustration.",
        "photos": [("illustration", "File:Premnoplex brunnescens 1902.jpg", "Historical illustration")],
    },
    "Mottled Owl": {
        "photos": [("either", "File:Ciccaba virgata DT -A Gramalote- (1) (20235847193).jpg")],
    },
    "King Vulture": {
        "photos": [("either", "File:Flickr - ggallice - King vulture.jpg")],
    },
    "Keel-billed Motmot": {
        "photos": [("either", "File:Keel-billed Motmot - Sarapiqui - Costa Rica S4E0981 (26404351020).jpg")],
    },
    "Sharpbill": {
        "photos": [("either", "File:Oxyruncus cristatus - Daniel S. Katz - 476753642.jpeg")],
    },
}


def info_for(title: str) -> dict:
    found = imageinfo([title])
    if title in found:
        return found[title]
    if len(found) == 1:
        return next(iter(found.values()))
    raise RuntimeError(f"No image info for {title}")


def main() -> None:
    by_name = {species["common"]: species for species in SPECIES}
    missing = [name for name in FIXES if name not in by_name]
    if missing:
        raise SystemExit(f"Unknown species: {missing}")

    progress = json.loads(PROGRESS_PATH.read_text(encoding="utf-8"))
    for name, fix in FIXES.items():
        species = dict(by_name[name])
        if fix.get("note"):
            species["sexes"] = f"{species['sexes']} {fix['note']}"
        species_id = slug(name)
        photos = []
        for spec in fix["photos"]:
            role, title = spec[0], spec[1]
            label = spec[2] if len(spec) > 2 else None
            item = info_for(title)
            if not item.get("ok"):
                raise RuntimeError(f"Licence not acceptable for {title}: {item.get('license')}")
            record = photo_record(species_id, name, role, item, 0, 0)
            dest = IMAGE_DIR / Path(record["src"]).name
            width, height = save_jpeg(item["download"], dest)
            record["width"] = width
            record["height"] = height
            if label:
                record["label"] = label
                record["alt"] = f"{label}. {name}."
            photos.append(record)
            print(f"{name} {role}: {item['license']} {item['title']}", flush=True)
        record = make_record(species, species_id, photos)
        progress[species_id] = {"ok": True, "record": record, "photos": photos}

    PROGRESS_PATH.write_text(json.dumps(progress, indent=2, ensure_ascii=False), encoding="utf-8")

    ordered = []
    for species in SPECIES:
        species_id = slug(species["common"])
        entry = progress.get(species_id)
        if not entry or not entry.get("ok"):
            raise SystemExit(f"Still missing {species['common']}")
        ordered.append(entry["record"])

    old = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    melbourne = next(item for item in old["coverages"] if item["id"] == "greater-melbourne")
    guide = {
        "defaultCoverageId": "monteverde",
        "strata": STRATA,
        "coverages": [monteverde_coverage(ordered), melbourne],
        "outside": outside_places(),
    }
    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    prune_images(guide)
    print(f"wrote {len(ordered)} Monteverde species", flush=True)


if __name__ == "__main__":
    main()
