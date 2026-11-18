#!/usr/bin/env python3
"""Fill published total-length (cm) ranges on guide + eBird supplemental species.

Looks up English Wikipedia convert templates / prose for birds that still lack
lengthCm. Leaves intentionally blank species alone (documented in INTENTIONAL_BLANKS).

Also adds scarce fixture taxa that are not yet in the catalog as length-only
supplemental stubs so imported scarce rows can show Size when a figure exists.
"""

from __future__ import annotations

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_monteverde import resolve_scientific, slug  # noqa: E402
from enrich_ebird_supplemental import (  # noqa: E402
    guess_active_times,
    guess_group,
    guess_strata,
    normalize,
)
from verify_ebird_barchart import parse  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "HandyFieldGuide" / "Resources"
GUIDE_PATH = RESOURCE / "guide.json"
SUPP_PATH = RESOURCE / "ebird_supplemental.json"
FIXTURE = RESOURCE / "fixtures" / "ebird_L436229__2020_2026_1_12_barchart.txt"
UA = "HandyFieldGuide/1.0 (educational iOS field guide; published length fill)"

# Keep blank: length would mislead the sparrow–ostrich scale, or no trustworthy figure.
INTENTIONAL_BLANKS: dict[str, str] = {
    "resplendent-quetzal": (
        "Wikipedia separates body length (36–40 cm) from male uppertail-covert "
        "streamers (often 65–100+ cm). A single Length figure misleads the relative scale."
    ),
}

# Previously blank for page confusion; Wikipedia now states a clear body length.
FORCE_FILL: dict[str, list[float]] = {
    "bicolored-antbird": [13.5, 15.0],
}

# Scarce import names whose Wikipedia pages lack a clear convert/prose figure.
# Values are published total lengths from standard field accounts (cm).
CURATED_SCARCE: dict[str, list[float]] = {
    "lessons-motmot": [38.0, 43.0],  # Momotus lessonii; Garrigues & Dean / similar Momotus accounts
    "american-barn-owl": [33.0, 39.0],  # Tyto furcata; same size class as Western barn owl body length
    "alder-flycatcher": [13.5, 17.0],  # Empidonax alnorum; Cornell All About Birds
    "dickcissel": [14.0, 16.0],  # Spiza americana; Cornell All About Birds
    "lesser-nighthawk": [19.0, 22.0],  # Chordeiles acutipennis
    "blue-ground-dove": [21.0, 23.0],  # Claravis pretiosa
    "ruddy-quail-dove": [20.0, 23.0],  # Geotrygon montana
    "black-eared-wood-quail": [24.0, 26.0],  # Odontophorus melanotis
    "barred-parakeet": [15.0, 17.0],  # Bolborhynchus lineola
    "russet-naped-wood-rail": [33.0, 40.0],  # now Gray-cowled Wood-Rail; Wikipedia overall length
    "costa-rican-warbler": [13.0],  # Basileuterus melanotis Wikipedia
}

# Scarce names left blank after lookup (misleading page or no trustworthy figure).
SCARCE_INTENTIONAL_BLANKS: dict[str, str] = {
    "lemon-bellied-tufted-flycatcher": (
        "eBird name does not resolve to a clear Wikipedia species page; no trustworthy length applied."
    ),
}

# Skip hybrids / forms that are not a single species length.
SKIP_NAME_SUBSTRINGS = ("(hybrid)", "(form)", " x ", " × ")

# {{convert|12|-|14|cm|in}} or {{cvt|12|to|14|cm|in}} — values already centimetres.
CONVERT_CM_RE = re.compile(
    r"\{\{\s*(?:convert|cvt)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*"
    r"(?:\|\s*(?:to(?:\([^)]*\))?|-|–|—|and)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*)?"
    r"\|\s*cm\b",
    re.I,
)
# {{convert|22.1|-|26.0|in|cm}} — inches, Wikipedia converts to cm for display.
CONVERT_IN_RE = re.compile(
    r"\{\{\s*(?:convert|cvt)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*"
    r"(?:\|\s*(?:to(?:\([^)]*\))?|-|–|—|and)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*)?"
    r"\|\s*in\s*\|\s*(?:cm|mm)\b",
    re.I,
)
PROSE_RANGE_RE = re.compile(
    r"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?"
    r"(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*cm"
)
PROSE_RANGE_BEFORE_RE = re.compile(
    r"(?i)(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*cm"
    r"[^\n.]{0,40}(?:in\s+)?(?:overall\s+)?(?:total\s+)?(?:body\s+)?length"
)
PROSE_SINGLE_RE = re.compile(
    r"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?"
    r"(\d+(?:\.\d+)?)\s*cm"
)
PROSE_IN_RANGE_RE = re.compile(
    r"(?i)(?:total\s+)?(?:body\s+)?length[^\n.]{0,60}?"
    r"(\d+(?:\.\d+)?)\s*(?:to|–|-)\s*(\d+(?:\.\d+)?)\s*(?:in(?:ch(?:es)?)?)\b"
)
OVERALL_LENGTH_CONVERT_RE = re.compile(
    r"\{\{\s*(?:convert|cvt)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*"
    r"(?:\|\s*(?:to(?:\([^)]*\))?|-|–|—|and)\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*)?"
    r"\|\s*cm\b[^}]{0,40}\}\}\s*in\s+overall\s+length",
    re.I,
)


def has_length(species: dict) -> bool:
    length = species.get("lengthCm")
    return (
        isinstance(length, list)
        and 1 <= len(length) <= 2
        and all(isinstance(item, (int, float)) and item > 0 for item in length)
    )


def catalog_index(guide: dict, supplemental: list[dict]) -> dict[str, tuple[str, dict]]:
    mapping: dict[str, tuple[str, dict]] = {}
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            mapping[normalize(species["commonName"])] = ("guide", species)
            for alias in species.get("aliases", []) + species.get("alsoCalled", []):
                mapping.setdefault(normalize(alias), ("guide", species))
    for species in supplemental:
        mapping.setdefault(normalize(species["commonName"]), ("supplemental", species))
        for alias in species.get("aliases", []) + species.get("alsoCalled", []):
            mapping.setdefault(normalize(alias), ("supplemental", species))
    return mapping


def should_skip_name(common: str) -> bool:
    low = common.lower()
    return any(token in low for token in SKIP_NAME_SUBSTRINGS)


def wikipedia_wikitext(title: str) -> str | None:
    url = "https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(
        {
            "action": "parse",
            "page": title,
            "prop": "wikitext",
            "format": "json",
            "redirects": 1,
        }
    )
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            data = json.load(response)
        time.sleep(0.35)
    except Exception:  # noqa: BLE001
        return None
    if "error" in data:
        return None
    return ((data.get("parse") or {}).get("wikitext") or {}).get("*")


def round_cm(value: float) -> float:
    # Keep one decimal when needed (13.5), otherwise whole centimetres.
    tenths = round(value * 2) / 2
    if abs(tenths - round(tenths)) < 0.05:
        return float(round(tenths))
    return float(tenths)


def normalize_range(low: float, high: float | None) -> list[float] | None:
    values = [round_cm(float(low))]
    if high is not None:
        values.append(round_cm(float(high)))
    values = sorted(values)
    if any(item < 5 or item > 280 for item in values):
        return None
    if len(values) == 2 and values[1] < values[0]:
        return None
    if len(values) == 2 and abs(values[1] - values[0]) < 0.05:
        return [values[0]]
    return values


def description_section(text: str) -> str:
    match = re.search(r"(?i)==\s*Description\s*==", text)
    if not match:
        return text
    start = match.end()
    nxt = re.search(r"\n==\s*[^=].*?==", text[start:])
    end = start + nxt.start() if nxt else min(len(text), start + 6000)
    return text[start:end]


def length_windows(text: str) -> list[str]:
    windows: list[str] = []
    # Explicit length labels first (info boxes / measurement lists).
    for match in re.finditer(r"(?i)'''\s*(?:total\s+)?(?:body\s+)?length\s*'''", text):
        windows.append(text[max(0, match.start() - 120) : match.start() + 500])
    for match in re.finditer(r"(?i)\|\s*(?:total\s+)?(?:body\s+)?length\s*\|", text):
        windows.append(text[match.start() : match.start() + 400])
    for match in re.finditer(r"(?i)(?:total\s+)?(?:body\s+)?length[^\n]{0,80}", text):
        # Avoid "egg length", "tail length", "wing length" when labeled that way.
        chunk = match.group(0)
        if re.search(r"(?i)\b(?:egg|tail|wing|tarsus|culmen|bill)\s+length\b", chunk):
            continue
        # Include preceding convert templates: "{{cvt|33|to|35|cm}} in overall length"
        windows.append(text[max(0, match.start() - 160) : match.start() + 700])
    # "is 24–33 cm long" style without the word length.
    desc = description_section(text)
    for match in re.finditer(
        r"(?i)(?:is|are|measures?|measure)\s+\{\{(?:convert|cvt)\|[^}]{0,80}\}\}\s*long",
        desc,
    ):
        windows.append(desc[max(0, match.start() - 20) : match.end() + 40])
    for match in OVERALL_LENGTH_CONVERT_RE.finditer(text):
        windows.append(text[match.start() : match.end()])
    if not windows and desc.strip():
        windows.append(desc[:2500])
    return windows


def preceding_is_wingspan(text: str, index: int) -> bool:
    prior = text[max(0, index - 48) : index].lower()
    return bool(
        re.search(r"wingspan|wing\s*span|\bspans\b|\bspan\b|across the wings", prior)
    )


def parse_convert_match(match: re.Match[str], *, inches: bool) -> list[float] | None:
    low = float(match.group(1))
    high = float(match.group(2)) if match.group(2) else None
    if inches:
        low *= 2.54
        if high is not None:
            high *= 2.54
    return normalize_range(low, high)


def parse_length_from_wikitext(text: str) -> list[float] | None:
    for window in length_windows(text):
        for match in CONVERT_CM_RE.finditer(window):
            if preceding_is_wingspan(window, match.start()):
                continue
            parsed = parse_convert_match(match, inches=False)
            if parsed:
                return parsed
        for match in CONVERT_IN_RE.finditer(window):
            if preceding_is_wingspan(window, match.start()):
                continue
            parsed = parse_convert_match(match, inches=True)
            if parsed:
                return parsed
        match = PROSE_RANGE_RE.search(window)
        if match and not re.search(r"(?i)egg|width|bill|wing", match.group(0)):
            parsed = normalize_range(float(match.group(1)), float(match.group(2)))
            if parsed:
                return parsed
        match = PROSE_RANGE_BEFORE_RE.search(window)
        if match and not re.search(r"(?i)egg|width|bill|wing", match.group(0)):
            parsed = normalize_range(float(match.group(1)), float(match.group(2)))
            if parsed:
                return parsed
        match = PROSE_IN_RANGE_RE.search(window)
        if match and not re.search(r"(?i)egg|width|bill|wing", match.group(0)):
            parsed = normalize_range(float(match.group(1)) * 2.54, float(match.group(2)) * 2.54)
            if parsed:
                return parsed
        match = PROSE_SINGLE_RE.search(window)
        if match and not re.search(r"(?i)egg|width|bill|wing", match.group(0)):
            parsed = normalize_range(float(match.group(1)), None)
            if parsed:
                return parsed
    return None


def candidate_titles(common: str) -> list[str]:
    titles = [
        common,
        common.replace("-", " "),
        f"{common} (bird)",
        common.replace("Grey", "Gray").replace("grey", "gray"),
        f"{common.replace('Grey', 'Gray')} (bird)",
    ]
    parts = common.split()
    if parts:
        sentence = parts[0].capitalize() + " " + " ".join(p.lower() for p in parts[1:])
        titles.extend([sentence, f"{sentence} (bird)"])
    # Deduplicate while preserving order.
    seen: set[str] = set()
    ordered: list[str] = []
    for title in titles:
        key = title.lower()
        if key in seen or not title.strip():
            continue
        seen.add(key)
        ordered.append(title)
    return ordered


def lookup_length(common: str) -> list[float] | None:
    curated = CURATED_SCARCE.get(slug(common))
    if curated:
        return list(curated)
    for title in candidate_titles(common):
        text = wikipedia_wikitext(title)
        if not text:
            continue
        # Avoid accepting lengths from unrelated disambiguation / non-bird pages.
        low = text[:800].lower()
        if "may refer to" in low and "bird" not in low and "(bird)" not in title.lower():
            continue
        if "legendary" in low or "wizard" in low:
            continue
        parsed = parse_length_from_wikitext(text)
        if parsed:
            return parsed
    return None


def length_only_stub(common: str, scientific: str, length: list[float]) -> dict:
    strata = guess_strata(common)
    return {
        "id": slug(common),
        "commonName": common,
        "scientificName": scientific or "—",
        "aliases": [],
        "alsoCalled": [],
        "alsoScientific": [],
        "tags": ["imported", "ebird-supplemental", "length-only"],
        "dimorphic": False,
        "origin": "native",
        "status": "imported",
        "group": guess_group(common),
        "strata": strata,
        "activeTimes": guess_active_times(common),
        "summary": "",
        "habitat": "",
        "sexes": "Sexes not curated for this imported name yet.",
        "stratumNote": "",
        "photos": [],
        "lengthCm": length,
    }


def set_length(species: dict, length: list[float]) -> None:
    species["lengthCm"] = length


def main() -> int:
    guide = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    supplemental = json.loads(SUPP_PATH.read_text(encoding="utf-8"))
    index = catalog_index(guide, supplemental)

    before_blank: list[tuple[str, str, str]] = []
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            if not has_length(species):
                before_blank.append((coverage["id"], species["id"], species["commonName"]))
    for species in supplemental:
        if not has_length(species):
            before_blank.append(("supplemental", species["id"], species["commonName"]))

    filled: list[dict] = []
    still_blank: list[dict] = []
    added_stubs: list[str] = []
    failed_lookup: list[str] = []

    # 1) Force-fill known trustworthy blanks already in the guide.
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            sid = species["id"]
            if sid in FORCE_FILL and not has_length(species):
                set_length(species, FORCE_FILL[sid])
                filled.append(
                    {
                        "id": sid,
                        "commonName": species["commonName"],
                        "lengthCm": FORCE_FILL[sid],
                        "source": "curated Wikipedia body length",
                    }
                )

    # 2) Scarce / unmatched fixture species → supplemental length stubs.
    parsed = parse(FIXTURE.read_text(encoding="utf-8"), FIXTURE.name)
    for row in parsed["species"]:
        if row["kind"] != "species":
            continue
        common = row["commonName"]
        if should_skip_name(common):
            still_blank.append(
                {
                    "commonName": common,
                    "reason": "hybrid/form — not a single-species length",
                }
            )
            continue
        key = normalize(common)
        if key in index:
            continue
        if max(row["monthlyMean"]) <= 0:
            continue
        if slug(common) in SCARCE_INTENTIONAL_BLANKS:
            still_blank.append(
                {
                    "commonName": common,
                    "reason": SCARCE_INTENTIONAL_BLANKS[slug(common)],
                }
            )
            continue
        length = lookup_length(common)
        if not length:
            failed_lookup.append(common)
            still_blank.append(
                {
                    "commonName": common,
                    "reason": "no clear Wikipedia total-length figure",
                }
            )
            continue
        scientific = resolve_scientific(common, "")
        stub = length_only_stub(common, scientific, length)
        supplemental.append(stub)
        index[key] = ("supplemental", stub)
        added_stubs.append(common)
        filled.append(
            {
                "id": stub["id"],
                "commonName": common,
                "lengthCm": length,
                "source": "Wikipedia → new length-only supplemental",
            }
        )
        print(f"stub {common}: {length}", flush=True)

    # 3) Any remaining guide/supplemental blanks (except intentional).
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            if has_length(species):
                continue
            sid = species["id"]
            if sid in INTENTIONAL_BLANKS:
                still_blank.append(
                    {
                        "id": sid,
                        "commonName": species["commonName"],
                        "reason": INTENTIONAL_BLANKS[sid],
                    }
                )
                continue
            if sid in FORCE_FILL:
                continue
            length = lookup_length(species["commonName"])
            if length:
                set_length(species, length)
                filled.append(
                    {
                        "id": sid,
                        "commonName": species["commonName"],
                        "lengthCm": length,
                        "source": "Wikipedia → guide",
                    }
                )
                print(f"guide {species['commonName']}: {length}", flush=True)
            else:
                failed_lookup.append(species["commonName"])
                still_blank.append(
                    {
                        "id": sid,
                        "commonName": species["commonName"],
                        "reason": "no clear Wikipedia total-length figure",
                    }
                )

    for species in supplemental:
        if has_length(species):
            continue
        sid = species["id"]
        if sid in INTENTIONAL_BLANKS:
            still_blank.append(
                {
                    "id": sid,
                    "commonName": species["commonName"],
                    "reason": INTENTIONAL_BLANKS[sid],
                }
            )
            continue
        length = lookup_length(species["commonName"])
        if length:
            set_length(species, length)
            filled.append(
                {
                    "id": sid,
                    "commonName": species["commonName"],
                    "lengthCm": length,
                    "source": "Wikipedia → supplemental",
                }
            )
            print(f"supp {species['commonName']}: {length}", flush=True)
        else:
            failed_lookup.append(species["commonName"])
            still_blank.append(
                {
                    "id": sid,
                    "commonName": species["commonName"],
                    "reason": "no clear Wikipedia total-length figure",
                }
            )

    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    SUPP_PATH.write_text(json.dumps(supplemental, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    def coverage_stats() -> dict:
        unique: dict[str, dict] = {}
        by_set: dict[str, list[dict]] = {}
        for coverage in guide["coverages"]:
            rows = coverage["species"]
            by_set[coverage["id"]] = rows
            for species in rows:
                unique[species["id"]] = species
        by_set["supplemental"] = supplemental
        for species in supplemental:
            unique.setdefault(species["id"], species)
        out = {}
        for name, rows in by_set.items():
            with_len = sum(1 for species in rows if has_length(species))
            out[name] = {"withLength": with_len, "total": len(rows)}
        with_len = sum(1 for species in unique.values() if has_length(species))
        out["unique"] = {"withLength": with_len, "total": len(unique)}
        return out

    report = {
        "beforeBlankInBundledCatalog": [
            {"coverage": c, "id": i, "commonName": n} for c, i, n in before_blank
        ],
        "filled": filled,
        "stillBlank": still_blank,
        "addedLengthOnlyStubs": added_stubs,
        "failedLookup": sorted(set(failed_lookup)),
        "coverage": coverage_stats(),
        "intentionalBlanks": INTENTIONAL_BLANKS,
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
