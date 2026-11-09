#!/usr/bin/env python3
"""Download small, openly licensed photos for the Melbourne bird guide.

Reads scripts/species_data.py, queries Wikimedia Commons and English
Wikipedia, keeps public-domain, CC0, CC BY, CC BY-SA, and GFDL files, writes
resized JPEGs under images/, and writes data/birds.json with attribution.

Optional overrides live in scripts/image_overrides.json:
  { "species-id": { "male": "File:Example.jpg", "female": "File:Other.jpg" } }
Use "either" for a monomorphic species.
"""

from __future__ import annotations

import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

from species_data import GROUPS, SPECIES, STRATA

ROOT = Path(__file__).resolve().parents[1]
IMAGE_DIR = ROOT / "images"
DATA_PATH = ROOT / "data" / "birds.json"
CACHE_PATH = ROOT / "data" / "photo-cache.json"
OVERRIDE_PATH = Path(__file__).resolve().parent / "image_overrides.json"
CONTACT_DIR = Path("/tmp/bird-contact")

UA = (
    "MelbourneBirdFieldGuide/1.0 "
    "(educational static field guide; image metadata from Wikimedia Commons) "
    "Python-urllib"
)
COMMONS = "https://commons.wikimedia.org/w/api.php"
WIKI = "https://en.wikipedia.org/w/api.php"

ALLOWED_MIME = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/webp",
    "image/gif",
    "image/tiff",
}


def plain(value: str) -> str:
    if not value:
        return ""
    text = re.sub(r"(?i)<br\s*/?>", " ", value)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def api(base: str, params: dict) -> dict:
    params = dict(params)
    params["format"] = "json"
    url = base + "?" + urllib.parse.urlencode(params)
    last_error = None
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as response:
                time.sleep(0.45)
                return json.load(response)
        except urllib.error.HTTPError as exc:
            last_error = exc
            wait = 25 * (attempt + 1) if exc.code == 429 else 2 * (attempt + 1)
            print(f"  HTTP {exc.code}, waiting {wait}s", flush=True)
            time.sleep(wait)
        except Exception as exc:  # noqa: BLE001 - retry network errors
            last_error = exc
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"API failed for {url[:140]}: {last_error}")


def license_ok(short: str) -> bool:
    text = (short or "").strip().lower().replace("_", " ")
    if any(flag in text for flag in ("nc", "noncommercial", "non-commercial", "nd", "noderiv")):
        return False
    if "cc0" in text or "cc-zero" in text or "public domain" in text:
        return True
    if "cc by" in text or "cc-by" in text:
        return True
    if "gfdl" in text or "gnu free documentation" in text or "free documentation license" in text:
        return True
    return text in {"pd", "no restrictions"}


def meta_value(info: dict, key: str) -> str:
    raw = (info.get("extmetadata") or {}).get(key) or {}
    return plain(raw.get("value") or "")


def wiki_files(title: str) -> list[str]:
    data = api(
        WIKI,
        {
            "action": "query",
            "titles": title,
            "prop": "images",
            "imlimit": "40",
            "redirects": "1",
        },
    )
    pages = (data.get("query") or {}).get("pages") or {}
    names = []
    for page in pages.values():
        for image in page.get("images") or []:
            name = image.get("title") or ""
            lower = name.lower()
            if lower.endswith(".svg") or "logo" in lower or "commons-logo" in lower:
                continue
            if any(skip in lower for skip in ("loudspeaker", "edit-clear", "symbol", "icon", "map", "locator")):
                continue
            names.append(name)
    return names


def search_files(query: str, limit: int = 12) -> list[str]:
    data = api(
        COMMONS,
        {
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srnamespace": "6",
            "srlimit": str(limit),
        },
    )
    return [row["title"] for row in (data.get("query") or {}).get("search") or []]


def imageinfo(titles: list[str]) -> dict[str, dict]:
    found: dict[str, dict] = {}
    unique = []
    seen = set()
    for title in titles:
        if not title.startswith("File:"):
            title = "File:" + title
        if title not in seen:
            seen.add(title)
            unique.append(title)
    for start in range(0, len(unique), 4):
        chunk = unique[start : start + 4]
        data = api(
            COMMONS,
            {
                "action": "query",
                "titles": "|".join(chunk),
                "prop": "imageinfo",
                "iiprop": "url|size|mime|extmetadata",
                "iiurlwidth": "1400",
            },
        )
        pages = (data.get("query") or {}).get("pages") or {}
        for page in pages.values():
            infos = page.get("imageinfo") or []
            if not infos:
                continue
            info = infos[0]
            title = page.get("title") or ""
            short = meta_value(info, "LicenseShortName")
            mime = (info.get("mime") or "").lower()
            found[title] = {
                "title": title,
                "mime": mime,
                "width": info.get("thumbwidth") or info.get("width") or 0,
                "height": info.get("thumbheight") or info.get("height") or 0,
                "full_width": info.get("width") or 0,
                "download": info.get("thumburl") or info.get("url"),
                "description": meta_value(info, "ImageDescription"),
                "artist": meta_value(info, "Artist"),
                "credit": meta_value(info, "Credit"),
                "license": short,
                "license_url": meta_value(info, "LicenseUrl"),
                "ok": license_ok(short) and mime in ALLOWED_MIME and bool(info.get("thumburl") or info.get("url")),
            }
        time.sleep(0.15)
    return found


def sex_flags(text: str) -> tuple[bool, bool]:
    male = bool(re.search(r"\bmales?\b", text))
    female = bool(re.search(r"\bfemales?\b", text))
    return male, female


def score_candidate(item: dict, species: dict, role: str, from_wiki: bool) -> int:
    if not item["ok"]:
        return -1000
    title = item["title"].lower()
    text = f"{title} {item['description'].lower()} {item['credit'].lower()}"
    score = 0
    scientific = species["scientific"].lower()
    common = species["common"].lower()
    if scientific in text:
        score += 14
    elif scientific.split()[0] in text:
        score += 4
    if common in text:
        score += 8
    if any(place in text for place in ("victoria", "melbourne", "port phillip", "australia")):
        score += 4
    if "victoria" in text or "melbourne" in text:
        score += 4
    license_name = item["license"].lower()
    if "cc0" in license_name or "public domain" in license_name:
        score += 2
    if from_wiki:
        score += 8
    if item["full_width"] >= 1200:
        score += 3
    if re.search(
        r"\b(chicks?|ducklings?|cygnets?|juveniles?|immatures?|fledglings?|nestlings?|subadults?|young|eggs?|nests?|paintings?|illustrations?|drawings?|artworks?|engravings?|icons?|skeletons?|skulls?|stamps?|coins?|logos?|taxidermy|taxidermied|hybrids?|albinos?|leucistic|diagrams?|plates?)\b",
        text,
    ):
        score -= 45
    if re.search(r"\b(distribution|occurrence|occurence|gbif|locator|chart|graph)\b", text) or "range map" in text:
        score -= 80
    if "museum specimen" in text:
        score -= 40
    if re.search(r"\bhead\b", title) or "-head" in title or "headshot" in title:
        score -= 28
    if "in flight" in text or "flying" in text:
        score -= 8
    for word in species.get("avoid") or []:
        if word in text:
            score -= 35
    if title.endswith(".svg") or "svg" in item["mime"]:
        score -= 200
    male, female = sex_flags(text)
    if role == "male":
        if male and not female:
            score += 36
        elif male and female:
            score -= 8
        else:
            score -= 28
        if female and not male:
            score -= 50
    elif role == "female":
        if female and not male:
            score += 36
        elif male and female:
            score -= 8
        else:
            score -= 28
        if male and not female:
            score -= 50
    else:
        if male != female:
            score -= 4
    if "eclipse" in text or "non-breeding" in text or "nonbreeding" in text:
        score -= 12
    return score


def queries_for(species: dict, role: str) -> list[str]:
    custom = (species.get("queries") or {}).get(role) or (species.get("queries") or {}).get("either")
    if custom:
        return list(custom)
    common = species["common"]
    scientific = species["scientific"]
    if role == "either":
        return [f"{common} {scientific}", common]
    word = "male" if role == "male" else "female"
    return [f"{common} {word}", f"{scientific} {word}"]


def choose(species: dict, role: str, overrides: dict) -> tuple[dict | None, list[dict]]:
    forced = (overrides.get(species["id"]) or {}).get(role)
    titles: list[tuple[str, bool]] = []
    if forced:
        titles.append((forced if forced.startswith("File:") else "File:" + forced, False))
    for name in wiki_files(species["wiki"]):
        titles.append((name, True))
    for query in queries_for(species, role):
        for name in search_files(query):
            titles.append((name, False))
        time.sleep(0.1)
    info = imageinfo([title for title, _wiki in titles])
    wiki_set = {title for title, flag in titles if flag}
    ranked = []
    for title, item in info.items():
        item = dict(item)
        item["score"] = score_candidate(item, species, role, title in wiki_set)
        if forced and title == (forced if forced.startswith("File:") else "File:" + forced):
            item["score"] += 500
        ranked.append(item)
    ranked.sort(key=lambda row: (row["score"], row["full_width"]), reverse=True)
    best = ranked[0] if ranked and ranked[0]["score"] > 0 else None
    return best, ranked[:6]


def download_jpeg(url: str, dest: Path) -> tuple[int, int]:
    last_error = None
    data = b""
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as response:
                data = response.read()
            break
        except urllib.error.HTTPError as exc:
            last_error = exc
            wait = 20 * (attempt + 1) if exc.code == 429 else 2 * (attempt + 1)
            print(f"  download HTTP {exc.code}, waiting {wait}s", flush=True)
            time.sleep(wait)
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            time.sleep(2 * (attempt + 1))
    else:
        raise RuntimeError(f"Download failed {url[:120]}: {last_error}")
    image = Image.open(BytesIO(data))
    image = ImageOps.exif_transpose(image)
    if image.mode != "RGB":
        image = image.convert("RGB")
    image.thumbnail((1000, 1000), Image.Resampling.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    image.save(dest, "JPEG", quality=74, optimize=True, progressive=True)
    return image.size


def file_page(title: str) -> str:
    name = title.split(":", 1)[-1].replace(" ", "_")
    return "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name)


def load_cache() -> dict:
    if CACHE_PATH.exists():
        return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    return {}


def save_cache(cache: dict) -> None:
    CACHE_PATH.write_text(json.dumps(cache, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def filenames_for(species: dict) -> list[str]:
    roles = ["male", "female"] if species["dimorphic"] else ["either"]
    names = []
    for role in roles:
        suffix = "" if role == "either" else f"-{role}"
        names.append(f"{species['id']}{suffix}.jpg")
    return names


def build_species(overrides: dict, only: set[str] | None) -> list[dict]:
    records = []
    problems = []
    cache = load_cache()
    for species in SPECIES:
        if only and species["id"] not in only:
            continue
        expected = filenames_for(species)
        cached = cache.get(species["id"]) or []
        cached_names = [photo["src"].split("/")[-1] for photo in cached]
        if (
            cached
            and cached_names == expected
            and all((IMAGE_DIR / name).exists() for name in expected)
            and not overrides.get(species["id"])
        ):
            print(f"\n== {species['common']} == cached", flush=True)
            records.append((species, cached))
            continue
        roles = ["male", "female"] if species["dimorphic"] else ["either"]
        photos = []
        used = set()
        print(f"\n== {species['common']} ==", flush=True)
        for role in roles:
            try:
                best, ranked = choose(species, role, overrides)
            except Exception as exc:  # noqa: BLE001 - keep going after a Commons failure
                problems.append(f"{species['id']} {role}: {exc}")
                print(f"  !! {exc}", flush=True)
                continue
            for row in ranked[:3]:
                flag = "OK" if row["ok"] else "no"
                print(f"  {role:6} {row['score']:4} {flag:2} {row['license'][:22]:22} {row['title'][:90]}")
            if best is None or best["title"] in used or best["score"] < 15:
                problems.append(f"{species['id']} {role}: no acceptable photo")
                print(f"  !! missing {role}")
                continue
            # Dimorphic photos must actually be labelled with that sex.
            if role in {"male", "female"} and best["score"] < 40 and not (overrides.get(species["id"]) or {}).get(role):
                text = f"{best['title']} {best['description']}".lower()
                male, female = sex_flags(text)
                if role == "male" and not (male and not female):
                    problems.append(f"{species['id']} male: weak sex label ({best['title']})")
                if role == "female" and not (female and not male):
                    problems.append(f"{species['id']} female: weak sex label ({best['title']})")
            suffix = "" if role == "either" else f"-{role}"
            filename = f"{species['id']}{suffix}.jpg"
            dest = IMAGE_DIR / filename
            try:
                width, height = download_jpeg(best["download"], dest)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{species['id']} {role}: download {exc}")
                print(f"  !! download {exc}")
                continue
            used.add(best["title"])
            label = {"male": "Male", "female": "Female", "either": "Sexes look alike"}[role]
            photos.append(
                {
                    "role": role,
                    "label": label,
                    "src": f"images/{filename}",
                    "alt": f"{label} {species['common']}" if role != "either" else f"{species['common']}. Males and females look alike.",
                    "width": width,
                    "height": height,
                    "author": best["artist"] or "Wikimedia Commons contributor",
                    "license": best["license"],
                    "licenseUrl": best["license_url"],
                    "sourceUrl": file_page(best["title"]),
                    "file": best["title"],
                }
            )
            print(f"  saved {filename} ({width}x{height}) {best['title']}", flush=True)
            time.sleep(0.4)
        if photos and [photo["src"].split("/")[-1] for photo in photos] == expected:
            cache[species["id"]] = photos
            save_cache(cache)
        records.append((species, photos))
    if problems:
        print("\nPROBLEMS")
        for line in problems:
            print(" -", line)
    return records


def public_record(species: dict, photos: list[dict]) -> dict:
    return {
        "id": species["id"],
        "commonName": species["common"],
        "scientificName": species["scientific"],
        "aliases": species.get("aliases") or [],
        "alsoCalled": species.get("also_called") or [],
        "alsoScientific": species.get("also_scientific") or [],
        "tags": species.get("tags") or [],
        "dimorphic": species["dimorphic"],
        "origin": species.get("origin") or "native",
        "status": species["status"],
        "group": species["group"],
        "strata": species["strata"],
        "summary": species["summary"],
        "habitat": species["habitat"],
        "sexes": species["sexes"],
        "stratumNote": species["stratum_note"],
        "photos": photos,
    }


def write_data(records: list[tuple[dict, list[dict]]]) -> None:
    payload = {
        "place": "Greater Melbourne, Victoria, Australia",
        "groups": [{"id": key, "label": label} for key, label in GROUPS],
        "strata": [{"id": key, "label": label, "hint": hint} for key, label, hint in STRATA],
        "species": [public_record(species, photos) for species, photos in records],
    }
    DATA_PATH.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\nWrote {DATA_PATH} ({len(payload['species'])} species)")


def contact_sheets() -> None:
    data = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    cells = []
    for species in data["species"]:
        for photo in species["photos"]:
            cells.append((species, photo))
    CONTACT_DIR.mkdir(parents=True, exist_ok=True)
    font = ImageFont.load_default()
    per_page = 6
    for page_index in range(0, len(cells), per_page):
        chunk = cells[page_index : page_index + per_page]
        sheet = Image.new("RGB", (1200, 1500), (243, 239, 228))
        draw = ImageDraw.Draw(sheet)
        for index, (species, photo) in enumerate(chunk):
            col = index % 2
            row = index // 2
            x = 30 + col * 590
            y = 20 + row * 490
            path = ROOT / photo["src"]
            image = Image.open(path).convert("RGB")
            image.thumbnail((540, 380), Image.Resampling.LANCZOS)
            sheet.paste(image, (x, y))
            caption = f"{species['commonName']} — {photo['label']}"
            draw.text((x, y + 390), caption[:70], fill=(20, 30, 24), font=font)
            draw.text((x, y + 408), photo["file"][:78], fill=(60, 70, 60), font=font)
        out = CONTACT_DIR / f"sheet-{page_index // per_page + 1:02d}.jpg"
        sheet.save(out, "JPEG", quality=80)
        print(out)


def main() -> None:
    only = set()
    args = sys.argv[1:]
    if "--only" in args:
        only = set(args[args.index("--only") + 1].split(","))
    if args == ["--contact"]:
        contact_sheets()
        return
    overrides = {}
    if OVERRIDE_PATH.exists():
        overrides = json.loads(OVERRIDE_PATH.read_text(encoding="utf-8"))
    records = build_species(overrides, only or None)
    if only and DATA_PATH.exists():
        existing = json.loads(DATA_PATH.read_text(encoding="utf-8"))
        by_id = {row["id"]: row for row in existing["species"]}
        for species, photos in records:
            by_id[species["id"]] = public_record(species, photos)
        order = [species["id"] for species in SPECIES]
        existing["species"] = [by_id[key] for key in order if key in by_id]
        DATA_PATH.write_text(json.dumps(existing, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    else:
        write_data(records)
    contact_sheets()


if __name__ == "__main__":
    main()
