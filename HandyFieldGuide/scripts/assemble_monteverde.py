#!/usr/bin/env python3
"""Build the Monteverde coverage and download openly licensed photos.

Species names come from monteverde_species.py, which was checked against the
Children's Eternal Rainforest checklist. Melbourne stays as a second coverage.
The invented San José sample is dropped.
"""

from __future__ import annotations

import json
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
from monteverde_species import SPECIES

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "HandyFieldGuide" / "Resources"
IMAGE_DIR = RESOURCE / "images"
GUIDE_PATH = RESOURCE / "guide.json"
PROGRESS_PATH = Path(__file__).resolve().parent / "photo_progress.json"

UA = "HandyFieldGuide/1.0 (educational iOS field guide; Wikimedia Commons metadata)"
API = "https://commons.wikimedia.org/w/api.php"

REUSE_IDS = {
    "clay-colored-thrush",
    "blue-gray-tanager",
    "great-kiskadee",
    "rufous-tailed-hummingbird",
    "tropical-kingbird",
    "yellow-faced-grassquit",
    "crimson-fronted-parakeet",
    "house-wren",
}

STRATA = [
    {"id": "ground", "label": "Ground", "hint": "On the ground, a lawn, mud, or the water"},
    {"id": "low", "label": "Low", "hint": "Shrubs, low branches, and the understory"},
    {"id": "mid", "label": "Mid", "hint": "The middle of the forest, or a small tree"},
    {"id": "canopy", "label": "Canopy", "hint": "Crowns of tall trees"},
    {"id": "sky", "label": "Sky", "hint": "Overhead — flying, soaring, or hawking in open air"},
]

GROUPS = [
    {"id": "certain", "label": "Near-certain"},
    {"id": "tanager", "label": "Tanagers, honeycreepers, and finches"},
    {"id": "toucan", "label": "Toucans, barbets, trogons, motmots, and woodpeckers"},
    {"id": "hummer", "label": "More hummingbirds"},
    {"id": "song", "label": "Flycatchers, wrens, thrushes, and jays"},
    {"id": "mixed", "label": "Pigeons, parrots, raptors, and others"},
    {"id": "migrant", "label": "November migrants"},
    {"id": "interior", "label": "Possible, worth patience"},
    {"id": "lucky", "label": "Lucky finds"},
]
GROUP_ORDER = [group["id"] for group in GROUPS]

SOAR = {
    "Turkey Vulture",
    "Black Vulture",
    "White-collared Swift",
    "Broad-winged Hawk",
    "Short-tailed Hawk",
    "Barred Hawk",
    "White Hawk",
    "King Vulture",
    "Ornate Hawk-Eagle",
    "Black Hawk-Eagle",
}
OWLS = {"Mottled Owl", "Spectacled Owl", "Crested Owl"}

_rate_lock = threading.Lock()
_next_request = 0.0
_progress_lock = threading.Lock()


def plain(value: str) -> str:
    text = re.sub(r"(?i)<br\s*/?>", " ", value or "")
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"\s+", " ", text).replace("&amp;", "&").replace("&#039;", "'").replace("&quot;", '"').strip()


def api(params: dict) -> dict:
    global _next_request
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    last_error = None
    for attempt in range(5):
        with _rate_lock:
            wait = _next_request - time.time()
            if wait > 0:
                time.sleep(wait)
            _next_request = time.time() + 0.85
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except Exception as exc:  # noqa: BLE001 - retry then surface
            last_error = exc
            pause = 8 * (attempt + 1)
            if getattr(exc, "code", None) == 429:
                pause = 30 * (attempt + 1)
            time.sleep(pause)
    raise RuntimeError(f"Commons API failed: {last_error}")


# Open licences only: PD / CC0 / CC BY / CC BY-SA / GFDL (and Commons synonyms).
# Never accept NC, ND, or other non-open short names.
_OPEN_LICENSE_FLAGS = (
    "cc0",
    "cc-zero",
    "public domain",
    "publicdomain",
    "pdm",
    "cc by",
    "cc-by",
    "gfdl",
    "free documentation",
)
_OPEN_LICENSE_EXACT = {
    "pd",
    "pdm",
    "no restrictions",
    "copyrighted free use",  # Wikimedia synonym for unrestricted reuse
}


def license_ok(short: str) -> bool:
    """Return True only for PD, CC0, CC BY, CC BY-SA, GFDL (and synonyms)."""
    text = (short or "").strip().lower().replace("_", "-")
    spaced = text.replace("-", " ")
    # Reject non-open Creative Commons variants first (NC / ND).
    if re.search(r"\bnc\b|noncommercial|non-commercial", spaced):
        return False
    if re.search(r"\bnd\b|noderiv|no derivatives|no-deriv", spaced):
        return False
    haystacks = (text, spaced)
    if any(flag in hay for hay in haystacks for flag in _OPEN_LICENSE_FLAGS):
        return True
    return spaced in _OPEN_LICENSE_EXACT or text in _OPEN_LICENSE_EXACT


def slug(name: str) -> str:
    text = name.lower().replace("'", "")
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def load_progress() -> dict:
    if PROGRESS_PATH.exists():
        return json.loads(PROGRESS_PATH.read_text(encoding="utf-8"))
    return {}


def save_progress(progress: dict) -> None:
    PROGRESS_PATH.write_text(json.dumps(progress, indent=2, ensure_ascii=False), encoding="utf-8")


def search_files(query: str, limit: int = 40) -> list[str]:
    """Search Commons file namespace; wider default limit than the old 16."""
    query = (query or "").strip()
    if not query or query in {"—", "-", "?"} or "—" in query:
        return []
    data = api({
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srnamespace": 6,
        "srlimit": min(max(limit, 1), 50),
    })
    names = []
    for hit in data.get("query", {}).get("search", []):
        title = hit.get("title") or ""
        if title.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
            names.append(title)
    return names


def category_files(title: str, limit: int = 50) -> list[str]:
    title = (title or "").strip()
    if not title or "—" in title:
        return []
    if not title.startswith("Category:"):
        title = f"Category:{title}"
    data = api({
        "action": "query",
        "list": "categorymembers",
        "cmtitle": title,
        "cmtype": "file",
        "cmlimit": min(max(limit, 1), 50),
    })
    names = []
    for hit in data.get("query", {}).get("categorymembers", []):
        name = hit.get("title") or ""
        if name.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
            names.append(name)
    return names


def imageinfo(titles: list[str]) -> dict[str, dict]:
    found = {}
    for start in range(0, len(titles), 8):
        chunk = titles[start:start + 8]
        if not chunk:
            continue
        data = api({
            "action": "query",
            "titles": "|".join(chunk),
            "prop": "imageinfo",
            "iiprop": "url|size|mime|extmetadata",
            "iiurlwidth": 1200,
        })
        for page in (data.get("query") or {}).get("pages", {}).values():
            infos = page.get("imageinfo") or []
            if not infos:
                continue
            info = infos[0]
            meta = info.get("extmetadata") or {}
            short = plain((meta.get("LicenseShortName") or {}).get("value") or "")
            title = page.get("title") or ""
            found[title] = {
                "title": title,
                "mime": (info.get("mime") or "").lower(),
                "download": info.get("thumburl") or info.get("url"),
                "description": plain((meta.get("ImageDescription") or {}).get("value") or "")[:400],
                "artist": plain((meta.get("Artist") or {}).get("value") or "")[:180],
                "license": short,
                "license_url": plain((meta.get("LicenseUrl") or {}).get("value") or ""),
                "width": info.get("width") or 0,
                "ok": license_ok(short) and bool(info.get("thumburl") or info.get("url")),
            }
    return found


def sex_flags(text: str) -> tuple[bool, bool]:
    male = bool(re.search(r"\bmales?\b|♂|\bmacho\b|\bmännchen\b", text, re.I))
    female = bool(re.search(r"\bfemales?\b|♀|\bhembra\b|\bweibchen\b", text, re.I))
    return male, female


def hard_skip(text: str) -> bool:
    if any(word in text for word in (
        "juvenile", "immature", "chick", "nestling", "fledgling", "egg",
        "painting", "illustration", "stamp", "drawing", "artwork", "icon",
        "range map", "distribution", "locator", "diagram", "skeleton",
        "museum specimen", "study skin", "taxiderm",
        "keulemans", "monograph", "biologia centrali", "castelnau",
        "lithograph", "engraving", "hand-colored", "hand colored",
        "naturalis", "rmnh", "specimen", "employee", "uniform",
    )):
        return True
    return bool(re.search(r"\bplates?\b", text))


_STOP_NAME_TOKENS = {
    "the", "a", "an", "and", "or", "of", "common", "northern", "southern",
    "eastern", "western", "american", "bird", "birds",
}


def name_tokens(value: str) -> list[str]:
    return [
        token
        for token in re.findall(r"[a-z]+", (value or "").lower())
        if len(token) >= 4 and token not in _STOP_NAME_TOKENS
    ]


def species_name_needles(species: dict) -> list[str]:
    """Common, scientific, and alt names used to keep search on the right taxon."""
    needles: list[str] = []
    for value in (
        species.get("common"),
        species.get("scientific"),
        *(species.get("also_called") or []),
        *(species.get("also_scientific") or []),
        *(species.get("aliases") or []),
    ):
        text = (value or "").strip().lower()
        if text and text not in {"—", "-", "?"} and text not in needles:
            needles.append(text)
    return needles


def name_match(text: str, species: dict) -> bool:
    """True when the Commons hit is about this species (not a vague family match)."""
    text = text.lower()
    needles = species_name_needles(species)
    if any(needle and needle in text for needle in needles):
        return True
    # Multi-token common / alias: require at least two distinctive tokens.
    for label in [species.get("common") or "", *(species.get("also_called") or [])]:
        tokens = name_tokens(label)
        if len(tokens) >= 2 and sum(1 for token in tokens if token in text) >= 2:
            return True
    # Binomial: genus + species epithet both present.
    sci = (species.get("scientific") or "").strip().lower()
    parts = sci.split()
    if len(parts) >= 2 and parts[0] in text and parts[1] in text:
        return True
    return False


def sex_keywords(role: str) -> list[str]:
    if role == "male":
        return ["male", "adult male", "♂", "macho", "männchen"]
    if role == "female":
        return ["female", "adult female", "♀", "hembra", "weibchen"]
    return []


def build_photo_queries(species: dict, role: str) -> list[str]:
    """Broader Commons queries: scientific, common, alt names, and sex keywords.

    Kept intentionally prioritized and capped so gap fills stay practical under
    Commons rate limits, while still wider than the old common+sci pair.
    """
    sci = (species.get("scientific") or "").strip()
    common = (species.get("common") or "").strip()
    also_sci = [item.strip() for item in (species.get("also_scientific") or []) if item and item.strip()]
    also_called = [item.strip() for item in (species.get("also_called") or []) if item and item.strip()]
    aliases = [item.strip() for item in (species.get("aliases") or []) if item and item.strip()]
    labels = []
    for value in [common, *also_called, *aliases]:
        if value and value not in labels and value not in {"—", "-"}:
            labels.append(value)
    binomials = []
    for value in [sci, *also_sci]:
        if value and value not in binomials and value not in {"—", "-", "?"} and " " in value:
            binomials.append(value)

    queries: list[str] = []

    def add(query: str) -> None:
        query = " ".join((query or "").split())
        if query and query not in queries and "—" not in query:
            queries.append(query)

    primary_sex = {"male": "male", "female": "female"}.get(role)
    extra_sex = [word for word in sex_keywords(role) if word != primary_sex][:2]
    if primary_sex:
        for binomial in binomials[:3]:
            add(f"{binomial} {primary_sex}")
            add(f'"{binomial}" {primary_sex}')
        for label in labels[:4]:
            add(f"{label} {primary_sex}")
            add(f'"{label}" {primary_sex}')
        for sex in extra_sex:
            for binomial in binomials[:2]:
                add(f"{binomial} {sex}")
            for label in labels[:2]:
                add(f"{label} {sex}")
    for binomial in binomials[:3]:
        add(binomial)
        for label in labels[:3]:
            add(f"{label} {binomial}")
    for label in labels[:4]:
        add(label)
    return queries[:18]


def candidate_file_titles(species: dict, role: str, avoid: set[str] | None = None) -> list[str]:
    avoid = avoid or set()
    titles: list[str] = []
    sci = (species.get("scientific") or "").strip()
    for binomial in [sci, *(species.get("also_scientific") or [])][:3]:
        binomial = (binomial or "").strip()
        if not binomial or "—" in binomial:
            continue
        titles.extend(category_files(f"Category:{binomial}"))
        if role == "male":
            titles.extend(category_files(f"Category:Male {binomial}"))
        elif role == "female":
            titles.extend(category_files(f"Category:Female {binomial}"))
    for alias in (species.get("also_called") or [])[:2]:
        titles.extend(category_files(f"Category:{alias}"))
    for query in build_photo_queries(species, role):
        titles.extend(search_files(query, limit=30))

    seen = set()
    ordered = []
    for title in titles:
        if title not in seen and title not in avoid:
            seen.add(title)
            ordered.append(title)
    return ordered


def score_candidate(species: dict, role: str, item: dict) -> int | None:
    text = f"{item.get('title', '')} {item.get('description', '')}".lower()
    if hard_skip(text) or not name_match(text, species):
        return None
    score = 12
    male, female = sex_flags(text)
    if role == "male":
        score += 36 if male and not female else -28
    elif role == "female":
        score += 36 if female and not male else -28
    else:
        score += 6
        if male ^ female:
            score -= 4
    if "captive" in text or "zoo" in text or "aviary" in text:
        score -= 8
    if (item.get("width") or 0) >= 800:
        score += 2
    return score


def choose_photo(species: dict, role: str, avoid: set[str]) -> dict:
    ordered = candidate_file_titles(species, role, avoid)
    best = None
    best_score = -10_000
    # Inspect in chunks so a strong early hit can stop the walk.
    for start in range(0, min(len(ordered), 72), 12):
        chunk = ordered[start:start + 12]
        info = imageinfo(chunk)
        for title in chunk:
            item = info.get(title)
            if not item or not item["ok"]:
                continue
            score = score_candidate(species, role, item)
            if score is None:
                continue
            if score > best_score:
                best_score = score
                best = item
        if role in {"male", "female"} and best_score >= 48:
            break
        if role == "either" and best_score >= 18:
            break
    if best is None or best_score < 8:
        label = best["title"] if best else "none"
        raise RuntimeError(f"No acceptable {role} photo for {species['common']} (best {best_score}: {label})")
    best = dict(best)
    best["score"] = best_score
    return best


_NON_EPITHETS = {
    "perched", "flying", "adult", "male", "female", "juvenile", "immature",
    "captive", "zoo", "aviary", "costa", "rica", "panama", "mexico", "ecuador",
    "colombia", "brazil", "from", "with", "near", "park", "forest", "lodge",
    "station", "biological", "national", "reserve", "flickr", "photo", "image",
    "bird", "birds", "species", "genus", "family", "feeding", "singing",
}


def binomial_from_text(text: str) -> str:
    """Extract a plausible Genus species binomial; skip English caption junk."""
    for match in re.finditer(r"\b([A-Z][a-z]{2,}) ([a-z]{3,})\b", text or ""):
        genus, epithet = match.group(1), match.group(2)
        if epithet in _NON_EPITHETS or genus.lower() in _NON_EPITHETS:
            continue
        if epithet.endswith("ing") or epithet.endswith("ed"):
            # Avoid caption verbs/adjectives ("perched", "feeding") unless classic Latin.
            if epithet not in {"cristatus", "variegatus", "lineatus"}:
                continue
        return f"{genus} {epithet}"
    return ""


def resolve_scientific(common: str, hinted: str = "") -> str:
    """Resolve a scientific name via hint, Wikidata P225, then careful text mining."""
    hinted = (hinted or "").strip()
    if hinted and hinted not in {"—", "-", "?"} and " " in hinted:
        if binomial_from_text(hinted) == hinted or re.match(r"^[A-Z][a-z]+ [a-z]+$", hinted):
            if hinted.split()[-1].lower() not in _NON_EPITHETS:
                return hinted
    title = common.replace(" ", "_")
    # Wikidata taxon name (P225) via enwiki sitelink — most reliable.
    url = (
        "https://www.wikidata.org/w/api.php?"
        + urllib.parse.urlencode({
            "action": "wbgetentities",
            "sites": "enwiki",
            "titles": title,
            "props": "claims",
            "format": "json",
        })
    )
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
        time.sleep(0.25)
        entities = data.get("entities") or {}
        for entity in entities.values():
            if entity.get("missing") is not None:
                continue
            claims = (entity.get("claims") or {}).get("P225") or []
            for claim in claims:
                value = (
                    ((claim.get("mainsnak") or {}).get("datavalue") or {}).get("value")
                )
                if isinstance(value, str) and " " in value:
                    return value
    except Exception:  # noqa: BLE001
        pass
    # Commons filenames sometimes embed the binomial.
    for file_title in search_files(common, limit=20)[:12]:
        found = binomial_from_text(file_title.replace("File:", ""))
        if found:
            return found
    # Wikipedia summary extract as last resort.
    summary_url = "https://en.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title)
    request = urllib.request.Request(summary_url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
        time.sleep(0.2)
        blob = f"{data.get('description') or ''} {data.get('extract') or ''}"
        found = binomial_from_text(blob)
        if found:
            return found
    except Exception:  # noqa: BLE001
        return ""
    return ""


def file_page(title: str) -> str:
    name = title.split(":", 1)[-1].replace(" ", "_")
    return "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name)


def save_jpeg(url: str, dest: Path) -> tuple[int, int]:
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
    image = ImageOps.exif_transpose(Image.open(BytesIO(raw)))
    if image.mode != "RGB":
        image = image.convert("RGB")
    image.thumbnail((1000, 1000), Image.Resampling.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    image.save(dest, "JPEG", quality=74, optimize=True, progressive=True)
    return image.size


def photo_record(species_id: str, common: str, role: str, item: dict, width: int, height: int) -> dict:
    label = {
        "male": "Male",
        "female": "Female",
        "either": "Sexes look alike",
        "unsexed": "Sex not labeled",
        "illustration": "Historical illustration",
    }[role]
    filename = f"{species_id}.jpg" if role in {"either", "unsexed", "illustration"} else f"{species_id}-{role}.jpg"
    if role == "either":
        alt = f"{common}. Males and females look alike."
    elif role == "unsexed":
        alt = f"{common}. The source photo is not labeled male or female."
    elif role == "illustration":
        alt = f"Historical illustration of {common}."
    else:
        alt = f"{label} {common}"
    return {
        "role": role,
        "label": label,
        "src": f"images/{filename}",
        "alt": alt,
        "width": width,
        "height": height,
        "author": item.get("artist") or "Wikimedia Commons contributor",
        "license": item["license"],
        "licenseUrl": item.get("license_url") or item.get("licenseUrl") or "",
        "sourceUrl": item.get("sourceUrl") or file_page(item["title"]),
        "file": item.get("file") or item["title"],
    }


def stratum_note(species: dict) -> str:
    name = species["common"]
    if name in OWLS:
        return "A night bird. By day it roosts in dense cover, so this is the roost and the hunting perch."
    if name == "Costa Rican Pygmy-Owl":
        return "Often calls in the day from the mid-level. Small birds may mob it."
    if name in SOAR:
        if "canopy" in species["strata"]:
            return "Often overhead, and sometimes on a high perch in the canopy."
        return "Usually overhead in open air, not in the shrub layer."
    labels = {
        "ground": "the ground",
        "low": "low branches and the understory",
        "mid": "the mid-level",
        "canopy": "the canopy",
        "sky": "open air overhead",
    }
    parts = [labels[item] for item in species["strata"]]
    if len(parts) == 1:
        where = parts[0]
    elif len(parts) == 2:
        where = f"{parts[0]} and {parts[1]}"
    else:
        where = ", ".join(parts[:-1]) + ", and " + parts[-1]
    return f"Usually in {where}."


def short_summary(species: dict) -> str:
    prefix = "Children's Eternal Rainforest, on the San Gerardo list for mid-late November. "
    text = species["habitat"]
    rest = text[len(prefix):] if text.startswith(prefix) else text
    sentence = rest.split(". ")[0].strip().rstrip(".")
    if len(sentence) > 140:
        sentence = sentence[:137].rsplit(" ", 1)[0]
    return sentence


def reuse_photos(old: dict) -> dict[str, list[dict]]:
    found: dict[str, list[dict]] = {}
    for coverage in old["coverages"]:
        for species in coverage["species"]:
            if species["id"] in REUSE_IDS:
                found[species["id"]] = species["photos"]
    missing = REUSE_IDS - set(found)
    if missing:
        raise SystemExit(f"Missing reusable photo records: {sorted(missing)}")
    return found


def download_one(species: dict, reused: dict[str, list[dict]], progress: dict) -> dict:
    species_id = slug(species["common"])
    roles = ["male", "female"] if species["dimorphic"] else ["either"]
    key = species_id
    with _progress_lock:
        cached = progress.get(key)
    if cached and cached.get("ok") and len(cached.get("photos") or []) == len(roles):
        print(f"keep {species['common']}", flush=True)
        return cached["record"]

    if species_id in reused:
        photos = []
        for photo in reused[species_id]:
            path = RESOURCE / photo["src"]
            if not path.exists():
                raise RuntimeError(f"Reusable image missing: {path}")
            photos.append(photo)
        record = make_record(species, species_id, photos)
        with _progress_lock:
            progress[key] = {"ok": True, "record": record, "photos": photos}
            save_progress(progress)
        print(f"reuse {species['common']}", flush=True)
        return record

    photos = []
    used_titles: set[str] = set()
    for role in roles:
        item = choose_photo(species, role, used_titles)
        used_titles.add(item["title"])
        filename = f"{species_id}.jpg" if role == "either" else f"{species_id}-{role}.jpg"
        dest = IMAGE_DIR / filename
        width, height = save_jpeg(item["download"], dest)
        photos.append(photo_record(species_id, species["common"], role, item, width, height))
        print(f"  {species['common']} {role}: {item['license']} {item['title']}", flush=True)
    record = make_record(species, species_id, photos)
    with _progress_lock:
        progress[key] = {"ok": True, "record": record, "photos": photos}
        save_progress(progress)
    return record


def make_record(species: dict, species_id: str, photos: list[dict]) -> dict:
    aliases = []
    for name in species["also_called"]:
        aliases.append(name.lower())
    return {
        "id": species_id,
        "commonName": species["common"],
        "scientificName": species["scientific"],
        "aliases": aliases,
        "alsoCalled": species["also_called"],
        "alsoScientific": species["also_scientific"],
        "tags": [species["group"], species["tier"].split("·")[0].strip().lower().replace(" ", "-")],
        "dimorphic": species["dimorphic"],
        "origin": "native",
        "status": species["tier"],
        "group": species["group"],
        "strata": species["strata"],
        "summary": short_summary(species),
        "habitat": species["habitat"],
        "sexes": species["sexes"],
        "stratumNote": stratum_note(species),
        "photos": photos,
    }


def district(did, label, aliases, lead, notes):
    return {
        "id": did,
        "label": label,
        "aliases": aliases,
        "lead": lead,
        "groupOrder": GROUP_ORDER,
        "groupNotes": notes,
    }


def monteverde_coverage(species_records: list[dict]) -> dict:
    return {
        "id": "monteverde",
        "label": "Children's Eternal Rainforest",
        "placeTitle": "Monteverde, Costa Rica",
        "country": "Costa Rica",
        "realm": "americas",
        "summary": (
            "171 species from the San Gerardo station list for the Children's Eternal Rainforest. "
            "Tiers are mid-late November estimates, not eBird frequencies, and not a promise that every bird is present every day."
        ),
        "sampleNote": None,
        "aliases": [
            "monteverde",
            "childrens eternal rainforest",
            "children s eternal rainforest",
            "bosque eterno de los ninos",
            "santa elena",
        ],
        "groups": GROUPS,
        "districts": [
            district(
                "all",
                "Children's Eternal Rainforest",
                [
                    "monteverde",
                    "childrens eternal rainforest",
                    "children s eternal rainforest",
                    "bosque eterno de los ninos",
                    "santa elena",
                ],
                "",
                {},
            ),
            district(
                "san-gerardo",
                "San Gerardo",
                ["san gerardo", "san gerardo station"],
                "San Gerardo is mid-elevation Caribbean-slope forest. This is the station the checklist was drawn from.",
                {},
            ),
            district(
                "bajo-del-tigre",
                "Bajo del Tigre",
                ["bajo del tigre", "bajo tigre"],
                "Bajo del Tigre is drier secondary forest. Expect fewer Tier 3 and Tier 4 forest-interior birds than at San Gerardo. The same checklist is shown, because this guide does not invent a second list.",
                {
                    "interior": "Less expected here than at San Gerardo. The forest is drier and more secondary.",
                    "lucky": "Less expected here than at San Gerardo.",
                },
            ),
        ],
        "species": species_records,
    }


def outside_places() -> list[dict]:
    return [
        {
            "names": [
                "sydney", "bondi", "parramatta", "newcastle", "wollongong", "canberra",
                "brisbane", "gold coast", "adelaide", "perth", "hobart", "launceston",
                "darwin", "cairns", "townsville", "geelong", "ballarat", "bendigo",
                "shepparton", "traralgon", "warrnambool", "queenscliff", "ocean grove",
                "barwon heads", "torquay",
            ],
            "closestCoverageId": "greater-melbourne",
            "because": "It is outside the greater Melbourne set curated for this guide.",
        },
        {
            "names": [
                "costa rica", "san jose", "san jose costa rica", "escazu", "heredia",
                "alajuela", "cartago", "la fortuna", "arenal", "tortuguero", "puerto viejo",
                "limon", "puntarenas", "jaco", "manuel antonio", "quepos", "dominical",
                "liberia", "tamarindo", "nosara", "samara", "golfito", "corcovado",
                "san gerardo de dota", "savegre", "hotel bougainvillea",
            ],
            "closestCoverageId": "monteverde",
            "because": "The curated Costa Rica list is the Children's Eternal Rainforest checklist from San Gerardo, not a country list and not this place.",
        },
        {
            "names": ["panama", "panama city", "bocas del toro", "managua", "san salvador", "guatemala city"],
            "closestCoverageId": "monteverde",
            "because": "The curated Central America list is the Children's Eternal Rainforest checklist, not this place.",
        },
        {
            "names": ["san jose california", "san jose ca"],
            "closestCoverageId": "monteverde",
            "because": "San Jose, California is a different place. This guide has no California list.",
        },
        {
            "names": ["auckland", "wellington", "christchurch"],
            "closestCoverageId": "greater-melbourne",
            "because": "New Zealand is outside both curated sets. Greater Melbourne is the nearer coverage in this guide.",
        },
    ]


def prune_images(guide: dict) -> None:
    used = set()
    for coverage in guide["coverages"]:
        for species in coverage["species"]:
            for photo in species["photos"]:
                used.add(Path(photo["src"]).name)
    for path in IMAGE_DIR.glob("*.jpg"):
        if path.name not in used:
            path.unlink()
            print(f"removed unused {path.name}", flush=True)


def main() -> None:
    old = json.loads(GUIDE_PATH.read_text(encoding="utf-8"))
    melbourne = next(item for item in old["coverages"] if item["id"] == "greater-melbourne")
    reused = reuse_photos(old)
    progress = load_progress()
    failures = []
    records_by_id = {}

    def work(species: dict):
        try:
            return download_one(species, reused, progress)
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {species['common']}: {exc}", flush=True)
            return {"id": slug(species["common"]), "error": str(exc), "common": species["common"]}

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(work, species) for species in SPECIES]
        for future in as_completed(futures):
            result = future.result()
            if result.get("error"):
                failures.append(result)
            else:
                records_by_id[result["id"]] = result

    ordered = []
    for species in SPECIES:
        species_id = slug(species["common"])
        if species_id not in records_by_id:
            continue
        ordered.append(records_by_id[species_id])

    if len(ordered) != len(SPECIES):
        names = ", ".join(item["common"] for item in failures)
        print(f"\n{len(failures)} species still need a photo: {names}", flush=True)
        raise SystemExit(1)

    guide = {
        "defaultCoverageId": "monteverde",
        "strata": STRATA,
        "coverages": [monteverde_coverage(ordered), melbourne],
        "outside": outside_places(),
    }
    GUIDE_PATH.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    prune_images(guide)
    print(f"wrote {GUIDE_PATH} with {len(ordered)} Monteverde species", flush=True)


if __name__ == "__main__":
    main()
