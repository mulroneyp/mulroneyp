#!/usr/bin/env python3
"""Assemble guide.json and download the San José starter photos.

The San José species are a small Central Valley sample chosen for this app.
They are not read from Paul's notes export.
"""

from __future__ import annotations

import html
import json
import re
import time
import urllib.parse
import urllib.request
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "BirdFieldGuide" / "Resources"
IMAGE_DIR = RESOURCE / "images"
MELBOURNE_JSON = Path(__file__).resolve().parents[2] / "melbourne-birds" / "data" / "birds.json"
OUT = RESOURCE / "guide.json"
UA = "BirdFieldGuide/1.0 (educational iOS field guide; Wikimedia Commons metadata)"
API = "https://commons.wikimedia.org/w/api.php"

STRATA = [
    {"id": "ground", "label": "Ground", "hint": "Lawns, mud, shore, and the water surface"},
    {"id": "low", "label": "Low", "hint": "Shrubs, reeds, fences, and low branches"},
    {"id": "mid", "label": "Mid", "hint": "Small trees and the open mid-storey"},
    {"id": "canopy", "label": "Canopy", "hint": "Crowns of tall trees"},
]


def plain(value: str) -> str:
    text = re.sub(r"(?i)<br\s*/?>", " ", value or "")
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def api(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=45) as response:
        time.sleep(0.35)
        return json.load(response)


def license_ok(short: str) -> bool:
    text = (short or "").strip().lower().replace("_", " ")
    if any(flag in text for flag in ("nc", "noncommercial", "non-commercial", "nd", "noderiv")):
        return False
    if any(flag in text for flag in ("cc0", "cc-zero", "public domain", "cc by", "cc-by", "gfdl", "free documentation")):
        return True
    return text in {"pd", "no restrictions"}


def search_files(query: str) -> list[str]:
    data = api({
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srnamespace": 6,
        "srlimit": 12,
    })
    names = []
    for hit in data.get("query", {}).get("search", []):
        title = hit.get("title") or ""
        if title.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
            names.append(title)
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
            "iiurlwidth": 1400,
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
                "description": plain((meta.get("ImageDescription") or {}).get("value") or ""),
                "artist": plain((meta.get("Artist") or {}).get("value") or ""),
                "license": short,
                "license_url": plain((meta.get("LicenseUrl") or {}).get("value") or ""),
                "width": info.get("width") or 0,
                "ok": license_ok(short) and bool(info.get("thumburl") or info.get("url")),
            }
    return found


def sex_flags(text: str) -> tuple[bool, bool]:
    male = bool(re.search(r"\bmales?\b", text))
    female = bool(re.search(r"\bfemales?\b", text))
    return male, female


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


def choose_photo(species: dict, role: str) -> dict:
    queries = species["queries"][role]
    titles: list[str] = []
    for query in queries:
        titles.extend(search_files(query))
    # Keep order but drop duplicates.
    seen = set()
    ordered = []
    for title in titles:
        if title not in seen:
            seen.add(title)
            ordered.append(title)
    info = imageinfo(ordered[:24])
    best = None
    best_score = -10_000
    for title in ordered:
        item = info.get(title)
        if not item or not item["ok"]:
            continue
        text = f"{title} {item['description']}".lower()
        if any(word in text for word in ("juvenile", "immature", "chick", "nestling", "egg", "painting", "illustration", "stamp", "captive", "zoo")):
            continue
        score = 0
        if species["scientific"].lower() in text or species["common"].lower() in text:
            score += 10
        male, female = sex_flags(text)
        if role == "male":
            score += 40 if male and not female else -30
        elif role == "female":
            score += 40 if female and not male else -30
        else:
            score += 8 if male == female else 2
        if item["width"] >= 800:
            score += 2
        if score > best_score:
            best_score = score
            best = item
    if best is None or best_score < 8:
        raise RuntimeError(f"No acceptable {role} photo for {species['id']} (best {best_score})")
    return best


def file_page(title: str) -> str:
    name = title.split(":", 1)[-1].replace(" ", "_")
    return "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name)


SAN_JOSE = [
    dict(
        id="clay-colored-thrush",
        common="Clay-colored Thrush",
        scientific="Turdus grayi",
        also_called=["Yigüirro"],
        also_scientific=[],
        aliases=["yiguirro", "clay colored robin"],
        tags=["thrush"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["ground", "low", "mid"],
        summary="The plain thrush of Central Valley lawns and gardens.",
        habitat="Parks and gardens through San José, often hopping on mown grass under trees and then sitting on a low branch. Parque La Sabana, the university campus in San Pedro, and shaded suburban gardens are typical. It is the national bird, and one of the first songs at dawn.",
        sexes="Males and females look alike: plain clay-brown, with a yellowish bill.",
        stratum_note="Feeds on the ground and perches in shrubs and small trees.",
        queries={"either": ["Clay-colored Thrush Turdus grayi", "Yiguirro Turdus grayi"]},
    ),
    dict(
        id="great-tailed-grackle",
        common="Great-tailed Grackle",
        scientific="Quiscalus mexicanus",
        also_called=["Zanate"],
        also_scientific=[],
        aliases=["zanate"],
        tags=["grackle"],
        dimorphic=True,
        status="Resident",
        group="open",
        strata=["ground", "mid"],
        summary="The large, noisy blackbird of car parks and lawns.",
        habitat="Parking areas, plazas, and the open grass of parks such as La Sabana. They walk on the ground and sit in palms and street trees, often in a noisy group. Hard to miss in central San José.",
        sexes="Males are glossy black, with a long keel-shaped tail and a pale eye. Females are smaller and brown, with a shorter tail and a pale eyebrow.",
        stratum_note="Feeds on the ground and perches at mid height in trees and palms.",
        queries={
            "male": ["Great-tailed Grackle male Quiscalus mexicanus", "Quiscalus mexicanus male"],
            "female": ["Great-tailed Grackle female Quiscalus mexicanus", "Quiscalus mexicanus female"],
        },
    ),
    dict(
        id="rufous-collared-sparrow",
        common="Rufous-collared Sparrow",
        scientific="Zonotrichia capensis",
        also_called=["Comemaíz"],
        also_scientific=[],
        aliases=["comemaiz", "rufous collared sparrow"],
        tags=["sparrow"],
        dimorphic=False,
        status="Resident",
        group="open",
        strata=["ground", "low"],
        summary="Small streaked sparrow with a rufous collar, on lawns and edges.",
        habitat="Lawns, garden edges, and weedy corners in the Central Valley. Look on the ground under park trees and along quiet suburban streets, then up on a low fence or shrub.",
        sexes="Males and females look alike.",
        stratum_note="Feeds on the ground and sits in low shrubs and on fences.",
        queries={"either": ["Rufous-collared Sparrow Zonotrichia capensis", "Zonotrichia capensis Costa Rica"]},
    ),
    dict(
        id="blue-gray-tanager",
        common="Blue-gray Tanager",
        scientific="Thraupis episcopus",
        also_called=["Tangara azuleja"],
        also_scientific=[],
        aliases=["blue grey tanager"],
        tags=["tanager"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["mid", "canopy"],
        summary="Pale blue-gray tanager of garden trees.",
        habitat="Gardens, park trees, and the edges of shade in San José. Often with Palm Tanagers in fruiting trees around La Sabana, San Pedro, and suburban yards. It stays in the foliage more than on the lawn.",
        sexes="Males and females look alike.",
        stratum_note="In small trees and the canopy of garden trees.",
        queries={"either": ["Blue-gray Tanager Thraupis episcopus", "Thraupis episcopus"]},
    ),
    dict(
        id="palm-tanager",
        common="Palm Tanager",
        scientific="Thraupis palmarum",
        also_called=[],
        also_scientific=[],
        aliases=[],
        tags=["tanager"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["mid", "canopy"],
        summary="Olive-gray tanager with dark wings, often beside the blue-gray one.",
        habitat="The same park and garden trees as the Blue-gray Tanager, including palms. Common through the Central Valley suburbs. Look in the crown of a fruiting tree rather than on open grass.",
        sexes="Males and females look alike.",
        stratum_note="In the mid-level and canopy of garden trees and palms.",
        queries={"either": ["Palm Tanager Thraupis palmarum", "Thraupis palmarum"]},
    ),
    dict(
        id="great-kiskadee",
        common="Great Kiskadee",
        scientific="Pitangus sulphuratus",
        also_called=["Cristofué"],
        also_scientific=[],
        aliases=["kiskadee", "cristofue"],
        tags=["flycatcher"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["low", "mid"],
        summary="Big yellow-bellied flycatcher that shouts its name.",
        habitat="Park edges, wires, and trees beside ponds and lawns. Regular in La Sabana and along suburban streets. It sits in the open, unlike the smaller flycatchers that stay inside a shrub.",
        sexes="Males and females look alike.",
        stratum_note="On low and mid-level perches, including wires and exposed branches.",
        queries={"either": ["Great Kiskadee Pitangus sulphuratus", "Pitangus sulphuratus"]},
    ),
    dict(
        id="tropical-kingbird",
        common="Tropical Kingbird",
        scientific="Tyrannus melancholicus",
        also_called=[],
        also_scientific=[],
        aliases=["kingbird"],
        tags=["flycatcher"],
        dimorphic=False,
        status="Resident",
        group="open",
        strata=["mid", "canopy"],
        summary="Gray and yellow flycatcher on wires and bare treetops.",
        habitat="Wires, aerials, and the top of a lone tree along streets and the edge of parks. Widespread in the Central Valley. It hunts from a high open perch and returns to the same spot.",
        sexes="Males and females look alike.",
        stratum_note="On exposed mid-level and canopy perches, including wires.",
        queries={"either": ["Tropical Kingbird Tyrannus melancholicus", "Tyrannus melancholicus"]},
    ),
    dict(
        id="hoffmanns-woodpecker",
        common="Hoffmann's Woodpecker",
        scientific="Melanerpes hoffmannii",
        also_called=[],
        also_scientific=[],
        aliases=["hoffmann woodpecker"],
        tags=["woodpecker"],
        dimorphic=True,
        status="Resident",
        group="park",
        strata=["mid", "canopy"],
        summary="The barred woodpecker of Central Valley gardens.",
        habitat="Shade trees, palms, and garden edges through San José and the neighboring Central Valley towns. More a suburb and coffee-edge bird than a deep-forest one. Listen for tapping in a park tree, then look on the trunk.",
        sexes="Males have a red nape. Females have a pale nape without the red. Both show a barred back and a yellowish belly.",
        stratum_note="On trunks and branches from mid height into the canopy.",
        queries={
            "male": ["Hoffmann's Woodpecker male Melanerpes hoffmannii", "Melanerpes hoffmannii male"],
            "female": ["Hoffmann's Woodpecker female Melanerpes hoffmannii", "Melanerpes hoffmannii female"],
        },
    ),
    dict(
        id="crimson-fronted-parakeet",
        common="Crimson-fronted Parakeet",
        scientific="Psittacara finschi",
        also_called=["Perico frentirrojo"],
        also_scientific=["Aratinga finschi"],
        aliases=["perico frentirrojo", "finschi parakeet"],
        tags=["parrot"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["canopy"],
        summary="Noisy green parakeet in flocks over the city.",
        habitat="Flocks cross San José through the day and roost in palms and tall trees, including around La Sabana. You usually hear them before you see them. They feed in the canopy, not on the lawn.",
        sexes="Males and females look alike.",
        stratum_note="In the canopy, and flying over it.",
        queries={"either": ["Crimson-fronted Parakeet Psittacara finschi", "Aratinga finschi"]},
    ),
    dict(
        id="lessons-motmot",
        common="Lesson's Motmot",
        scientific="Momotus lessonii",
        also_called=[],
        also_scientific=["Momotus momota"],
        aliases=["lesson motmot"],
        tags=["motmot"],
        dimorphic=False,
        status="Resident",
        group="shade",
        strata=["low", "mid"],
        summary="Green motmot with a racket tail, in shade rather than on the lawn.",
        habitat="Shaded gardens, coffee edges, and the wooded ravines that cut through the eastern suburbs. Much less a bird of the open Sabana lawn than the thrushes and grackles. Older books lump it with the Blue-crowned Motmot.",
        sexes="Males and females look alike.",
        stratum_note="On low and mid-level perches in shade.",
        queries={"either": ["Lesson's Motmot Momotus lessonii", "Momotus lessonii"]},
    ),
    dict(
        id="rufous-tailed-hummingbird",
        common="Rufous-tailed Hummingbird",
        scientific="Amazilia tzacatl",
        also_called=[],
        also_scientific=[],
        aliases=[],
        tags=["hummingbird"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["low", "mid"],
        summary="The common garden hummingbird, with a rufous tail.",
        habitat="Flowers in gardens, hedges, and park edges across the Central Valley. It defends a bush and returns to the same low perch. More a garden bird than a forest one in San José.",
        sexes="Males and females look alike for field purposes. Females can be slightly duller on the throat.",
        stratum_note="At flowers and low perches, up into small trees.",
        queries={"either": ["Rufous-tailed Hummingbird Amazilia tzacatl", "Amazilia tzacatl"]},
    ),
    dict(
        id="white-winged-dove",
        common="White-winged Dove",
        scientific="Zenaida asiatica",
        also_called=[],
        also_scientific=[],
        aliases=[],
        tags=["dove"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["ground", "mid"],
        summary="A large dove with a white wing stripe, on wires and lawns.",
        habitat="Wires, palms, and the ground under park trees through San José. The white stripe shows when it flies. Common in the city, not only in dry forest.",
        sexes="Males and females look alike.",
        stratum_note="Feeds on the ground and perches at mid height on wires and in trees.",
        queries={"either": ["White-winged Dove Zenaida asiatica", "Zenaida asiatica"]},
    ),
    dict(
        id="inca-dove",
        common="Inca Dove",
        scientific="Columbina inca",
        also_called=[],
        also_scientific=[],
        aliases=[],
        tags=["dove"],
        dimorphic=False,
        status="Resident",
        group="open",
        strata=["ground"],
        summary="Tiny long-tailed dove, scaled gray, walking on quiet ground.",
        habitat="Bare ground and short grass in gardens, courtyards, and quiet streets of the Central Valley. It flushes a short distance and shows rufous in the wings. Not a bird of the forest canopy.",
        sexes="Males and females look alike.",
        stratum_note="On the ground.",
        queries={"either": ["Inca Dove Columbina inca", "Columbina inca"]},
    ),
    dict(
        id="blue-and-white-swallow",
        common="Blue-and-white Swallow",
        scientific="Pygochelidon cyanoleuca",
        also_called=[],
        also_scientific=["Notiochelidon cyanoleuca"],
        aliases=["blue and white swallow"],
        tags=["swallow"],
        dimorphic=False,
        status="Resident",
        group="open",
        strata=["low"],
        summary="Small swallow, blue above and white below, over parks and streets.",
        habitat="Over lawns, rooftops, and the open middle of parks such as La Sabana. They hunt low in the air and rest on wires. Present in the city year-round.",
        sexes="Males and females look alike.",
        stratum_note="In the open air close to the ground, and perched on wires. Not in the canopy.",
        queries={"either": ["Blue-and-white Swallow Pygochelidon cyanoleuca", "Notiochelidon cyanoleuca"]},
    ),
    dict(
        id="yellow-faced-grassquit",
        common="Yellow-faced Grassquit",
        scientific="Tiaris olivaceus",
        also_called=[],
        also_scientific=[],
        aliases=["grassquit"],
        tags=["finch"],
        dimorphic=True,
        status="Resident",
        group="open",
        strata=["ground", "low"],
        summary="Tiny olive finch of weedy edges. The male has a yellow face.",
        habitat="Weedy lots, rough grass, and the unkempt edge of a park or coffee patch. Scarcer on a closely mown plaza than the sparrow. Common in the Central Valley once there is some rank grass.",
        sexes="Males have a bright yellow throat and eyebrow on an olive head. Females are duller olive, without that strong yellow face.",
        stratum_note="On the ground in grass, and in low weeds.",
        queries={
            "male": ["Yellow-faced Grassquit male Tiaris olivaceus", "Tiaris olivaceus male"],
            "female": ["Yellow-faced Grassquit female Tiaris olivaceus", "Tiaris olivaceus female"],
        },
    ),
    dict(
        id="house-wren",
        common="House Wren",
        scientific="Troglodytes aedon",
        also_called=["Southern House Wren"],
        also_scientific=["Troglodytes musculus"],
        aliases=["southern house wren"],
        tags=["wren"],
        dimorphic=False,
        status="Resident",
        group="park",
        strata=["low"],
        summary="Small brown wren with a big song, in shrubs and around eaves.",
        habitat="Garden shrubs, hedges, and the edges of houses through San José. It scolds from a low bush more often than it sits in the open. Some current lists split the Central American birds as Southern House Wren.",
        sexes="Males and females look alike.",
        stratum_note="In shrubs, hedges, and other low cover.",
        queries={"either": ["House Wren Troglodytes aedon Costa Rica", "Southern House Wren Troglodytes musculus"]},
    ),
]


def photo_record(species: dict, role: str, item: dict, width: int, height: int) -> dict:
    label = {"male": "Male", "female": "Female", "either": "Sexes look alike"}[role]
    filename = f"{species['id']}.jpg" if role == "either" else f"{species['id']}-{role}.jpg"
    alt = f"{label} {species['common']}" if role != "either" else f"{species['common']}. Males and females look alike."
    return {
        "role": role,
        "label": label,
        "src": f"images/{filename}",
        "alt": alt,
        "width": width,
        "height": height,
        "author": item["artist"] or "Wikimedia Commons contributor",
        "license": item["license"],
        "licenseUrl": item["license_url"],
        "sourceUrl": file_page(item["title"]),
        "file": item["title"],
    }


def build_san_jose_species() -> list[dict]:
    records = []
    for species in SAN_JOSE:
        roles = ["male", "female"] if species["dimorphic"] else ["either"]
        photos = []
        print(f"\n== {species['common']} ==")
        for role in roles:
            item = choose_photo(species, role)
            suffix = "" if role == "either" else f"-{role}"
            dest = IMAGE_DIR / f"{species['id']}{suffix}.jpg"
            width, height = save_jpeg(item["download"], dest)
            print(f"  {role}: {item['license']} {item['title']}")
            photos.append(photo_record(species, role, item, width, height))
        records.append({
            "id": species["id"],
            "commonName": species["common"],
            "scientificName": species["scientific"],
            "aliases": species["aliases"],
            "alsoCalled": species["also_called"],
            "alsoScientific": species["also_scientific"],
            "tags": species["tags"],
            "dimorphic": species["dimorphic"],
            "origin": "native",
            "status": species["status"],
            "group": species["group"],
            "strata": species["strata"],
            "summary": species["summary"],
            "habitat": species["habitat"],
            "sexes": species["sexes"],
            "stratumNote": species["stratum_note"],
            "photos": photos,
        })
    return records


def district(did, label, aliases, lead, order, notes):
    return {
        "id": did,
        "label": label,
        "aliases": aliases,
        "lead": lead,
        "groupOrder": order,
        "groupNotes": notes,
    }


def main() -> None:
    if not MELBOURNE_JSON.exists():
        raise SystemExit(
            f"Missing {MELBOURNE_JSON}. Edit BirdFieldGuide/Resources/guide.json directly; "
            "the website source was removed after the iOS guide was assembled."
        )
    melbourne = json.loads(MELBOURNE_JSON.read_text(encoding="utf-8"))
    park_order = ["water", "coast", "open", "park", "woodland"]
    guide = {
        "defaultCoverageId": "greater-melbourne",
        "strata": STRATA,
        "coverages": [
            {
                "id": "greater-melbourne",
                "label": "Greater Melbourne",
                "placeTitle": "Greater Melbourne, Australia",
                "country": "Australia",
                "realm": "oceania",
                "summary": "A starter set of residents and regular visitors in the parks, wetlands, bay, and suburbs. Not a full checklist.",
                "sampleNote": None,
                "aliases": ["greater melbourne", "melbourne", "metro melbourne", "melbourne victoria"],
                "groups": melbourne["groups"],
                "districts": [
                    district("all", "Greater Melbourne", ["greater melbourne", "melbourne", "metro melbourne"], "", park_order, {}),
                    district(
                        "bayside",
                        "Bayside",
                        ["bayside", "st kilda", "saint kilda", "elwood", "albert park", "middle park", "south melbourne", "port melbourne", "williamstown", "altona", "brighton", "hampton", "sandringham", "black rock", "beaumaris", "mentone", "parkdale", "mordialloc", "aspendale", "chelsea", "edithvale", "carrum", "seaford", "frankston", "elsternwick"],
                        "On the Port Phillip side of Melbourne.",
                        ["coast", "water", "park", "open", "woodland"],
                        {
                            "coast": "The beach, pier, and breakwater are the places to start.",
                            "water": "Look on the bigger lakes just inland of the beach, not on the open sand. Albert Park Lake is the usual one near St Kilda.",
                            "park": "Foreshore parks and street trees still hold the usual suburban birds.",
                            "open": "Ovals and the grass behind the foreshore.",
                            "woodland": "Not the local beach birds. They need larger treed parks, or a trip toward the creeks and the hills.",
                        },
                    ),
                    district(
                        "inner",
                        "Inner Melbourne",
                        ["inner melbourne", "inner suburbs", "melbourne cbd", "cbd", "carlton", "fitzroy", "collingwood", "richmond", "east melbourne", "parkville", "north melbourne", "west melbourne", "docklands", "southbank", "south yarra", "prahran", "windsor", "abbotsford", "cremorne"],
                        "In the inner suburbs.",
                        ["park", "water", "open", "woodland", "coast"],
                        {
                            "park": "Street trees, small parks, and the Royal Botanic Gardens.",
                            "water": "The Yarra, the botanic gardens lake, and Albert Park Lake are the water in reach of the inner suburbs.",
                            "open": "Ovals and the wide lawns of the botanic gardens and Royal Park.",
                            "woodland": "Thin in the inner grid. Yarra Bend, the treed edges of Royal Park, and the gardens are the better spots.",
                            "coast": "The bay is a short trip south, not the local street.",
                        },
                    ),
                    district(
                        "east",
                        "Eastern suburbs",
                        ["eastern suburbs", "hawthorn", "camberwell", "kew", "balwyn", "surrey hills", "box hill", "mont albert", "burwood", "glen iris", "ashburton", "mount waverley", "glen waverley", "ringwood", "mitcham", "nunawading", "doncaster", "bulleen", "templestowe", "blackburn", "forest hill", "vermont"],
                        "In the eastern suburbs.",
                        ["park", "woodland", "water", "open", "coast"],
                        {
                            "park": "Gardens, nature strips, and the usual eastern parkland.",
                            "woodland": "Creek lines and the larger bush parks. The ranges are further east.",
                            "water": "Park lakes and retarding basins, such as Blackburn Lake, rather than the bay.",
                            "open": "Ovals, golf courses, and the grass around park lakes.",
                            "coast": "The bay is across town. These are not the local street birds.",
                        },
                    ),
                    district(
                        "north",
                        "Northern suburbs",
                        ["northern suburbs", "brunswick", "coburg", "preston", "northcote", "thornbury", "fairfield", "alphington", "ivanhoe", "heidelberg", "reservoir", "pascoe vale", "essendon", "moonee ponds", "ascot vale", "fawkner"],
                        "On the north side of the city.",
                        ["park", "water", "open", "woodland", "coast"],
                        {
                            "park": "Suburban parks, street trees, and the inner-north parks such as Edinburgh Gardens.",
                            "water": "Creek pools and park lakes along the Merri, Darebin, and Moonee Ponds creeks.",
                            "open": "Ovals and the grass beside the creeks.",
                            "woodland": "Along the creeks, and at Yarra Bend and the Darebin Parklands, more than on a bare nature strip.",
                            "coast": "The bay is not the local habitat.",
                        },
                    ),
                    district(
                        "west",
                        "Western suburbs",
                        ["western suburbs", "footscray", "yarraville", "seddon", "maribyrnong", "sunshine", "st albans", "deer park", "point cook", "hoppers crossing", "werribee", "tarneit", "newport", "spotswood", "braybrook", "keilor", "niddrie"],
                        "In the western suburbs.",
                        ["open", "water", "coast", "park", "woodland"],
                        {
                            "open": "Ovals, grasslands, and the wide western paddocks.",
                            "water": "Lakes and wetlands, including Point Cook and the western treatment plant, plus suburban retarding basins.",
                            "coast": "The bay edge is Williamstown, Altona, and the Werribee shore, not the inland estates.",
                            "park": "Street trees and local parks, often sparser than in the east.",
                            "woodland": "Scarcer than in the east. Creek corridors and the larger planted parks are the places to look.",
                        },
                    ),
                    district(
                        "hills",
                        "Dandenong Ranges",
                        ["dandenong ranges", "dandenongs", "belgrave", "olinda", "sassafras", "kallista", "emerald", "ferny creek", "mount dandenong", "upwey", "tecoma", "ferntree gully", "upper ferntree gully", "montrose", "kalorama", "sherbrooke"],
                        "In the Dandenong Ranges and the treed eastern foothills.",
                        ["woodland", "park", "open", "water", "coast"],
                        {
                            "woodland": "This is the main habitat: gullies and the denser bush, which hold birds that are missing from a bare suburban lawn.",
                            "park": "Gardens under tall trees, and the picnic grounds.",
                            "open": "Clearings and picnic lawns. Many open-country birds of the western plains are scarce here.",
                            "water": "Small dams and forest creeks, not the bay or the big suburban lakes.",
                            "coast": "Not here. The bay is a drive back down.",
                        },
                    ),
                    district(
                        "peninsula",
                        "Mornington Peninsula",
                        ["mornington peninsula", "mornington", "mount eliza", "mount martha", "safety beach", "dromana", "rosebud", "rye", "sorrento", "portsea", "flinders", "hastings", "somerville"],
                        "On the Mornington Peninsula, at the southern edge of the area this guide covers.",
                        ["coast", "water", "park", "open", "woodland"],
                        {
                            "coast": "Bay shores, rock shelves, and the piers.",
                            "water": "Peninsula wetlands such as Coolart, not the small eastern suburban lakes.",
                            "park": "Town gardens and foreshore parks.",
                            "open": "Farm paddocks, golf courses, and grass behind the beach.",
                            "woodland": "The better bush is in the larger reserves, not the shopping strip.",
                        },
                    ),
                ],
                "species": melbourne["species"],
            },
            {
                "id": "san-jose",
                "label": "San José",
                "placeTitle": "San José, Costa Rica",
                "country": "Costa Rica",
                "realm": "americas",
                "summary": "A starter sample of birds you can see in Central Valley parks and gardens. Not a full checklist.",
                "sampleNote": "This sample was not taken from a notes export. It is a short list of common Central Valley species so San José works as its own place in the guide. A list from your notes can replace it later.",
                "aliases": ["san jose", "san jose costa rica", "san josé", "chepe"],
                "groups": [
                    {"id": "park", "label": "Parks and gardens"},
                    {"id": "open", "label": "Lawns, wires, and weedy edges"},
                    {"id": "shade", "label": "Shade and ravines"},
                ],
                "districts": [
                    district("all", "San José", ["san jose", "san jose costa rica", "chepe", "central valley"], "", ["park", "open", "shade"], {}),
                    district(
                        "sabana",
                        "La Sabana and the west of the city",
                        ["la sabana", "sabana", "rohrmoser", "mata redonda", "pavas"],
                        "Around La Sabana and the western neighborhoods.",
                        ["park", "open", "shade"],
                        {
                            "park": "The park trees, palms, and the lake edge at La Sabana.",
                            "open": "The big lawns, paths, and parking areas.",
                            "shade": "Less of this habitat on the open lawn. Look in the planted shade and the gardens just off the park.",
                        },
                    ),
                    district(
                        "east",
                        "San Pedro and Curridabat",
                        ["san pedro", "curridabat", "montes de oca", "sabanilla", "zapote", "tres rios"],
                        "In San Pedro, Curridabat, and the eastern suburbs.",
                        ["park", "shade", "open"],
                        {
                            "park": "Campus and garden trees, including the university grounds in San Pedro.",
                            "shade": "The wooded ravines and older gardens are the spot for shade birds.",
                            "open": "Rough grass, wires, and the edges of lots.",
                        },
                    ),
                    district(
                        "west",
                        "Escazú and Santa Ana",
                        ["escazu", "santa ana", "ciudad colon"],
                        "In Escazú and Santa Ana, on the western edge of the valley.",
                        ["park", "shade", "open"],
                        {
                            "park": "Gardens and shade trees in town.",
                            "shade": "Coffee edges and the wooded gullies hold the shade birds.",
                            "open": "Wires, lawns, and weedy edges of the towns.",
                        },
                    ),
                    district(
                        "heredia",
                        "Heredia",
                        ["heredia"],
                        "In Heredia, in the same Central Valley sample as San José. Not a separate checklist.",
                        ["park", "open", "shade"],
                        {
                            "park": "Town parks and garden trees.",
                            "open": "Lawns, wires, and weedy edges.",
                            "shade": "Shaded gardens and the nearby wooded edges.",
                        },
                    ),
                    district(
                        "cartago",
                        "Cartago",
                        ["cartago"],
                        "In Cartago, at the eastern end of the Central Valley. The same starter sample as San José, not a separate checklist.",
                        ["park", "open", "shade"],
                        {
                            "park": "Town gardens and park trees.",
                            "open": "Lawns, wires, and weedy edges.",
                            "shade": "Shaded gardens rather than the open plaza.",
                        },
                    ),
                ],
                "species": build_san_jose_species(),
            },
        ],
        "outside": [
            {"names": ["sydney", "bondi", "parramatta", "newcastle", "wollongong", "canberra", "brisbane", "gold coast", "adelaide", "perth", "hobart", "launceston", "darwin", "cairns", "townsville", "geelong", "ballarat", "bendigo", "shepparton", "traralgon", "warrnambool", "queenscliff", "ocean grove", "barwon heads", "torquay"], "closestCoverageId": "greater-melbourne", "because": "It is outside the greater Melbourne set curated for this guide."},
            {"names": ["monteverde", "la fortuna", "arenal", "tortuguero", "puerto viejo", "limon", "puntarenas", "jaco", "manuel antonio", "quepos", "dominical", "liberia", "tamarindo", "nosara", "samara", "golfito", "corcovado", "panama", "panama city", "managua", "san salvador"], "closestCoverageId": "san-jose", "because": "The San José sample is Central Valley parks and gardens, not this place."},
            {"names": ["san jose california", "san josé california", "san jose ca"], "closestCoverageId": "san-jose", "because": "San Jose, California is a different place from San José, Costa Rica. This guide has no California list."},
            {"names": ["auckland", "wellington", "christchurch"], "closestCoverageId": "greater-melbourne", "because": "New Zealand is outside both curated sets. Greater Melbourne is the nearer coverage in this guide."},
            {"names": ["new york", "london", "paris", "tokyo", "los angeles", "mexico city", "bogota"], "closestCoverageId": "san-jose", "because": "That place is outside both curated sets. The San José sample is the nearer of the two coverages in this guide, and it is not a list for the place you typed."},
        ],
    }
    OUT.write_text(json.dumps(guide, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\nWrote {OUT}")


if __name__ == "__main__":
    main()
