# Handy Field Guide

An iPhone field guide. Open `HandyFieldGuide.xcodeproj` in Xcode, pick the HandyFieldGuide scheme, and run it on an iPhone simulator or a phone. No development team is set, so Xcode will ask for one before a device build.

## Home filters

The app title **Handy Field Guide** sits at the top of the home screen (inline navigation title), with **i** (when a place is active; coverage prose) and the **Settings** gear **right-aligned on that title row**. Directly under it, two rows of value labels (no bottom menu bar, and no secondary place / list-name line above the bird list). The Location and Month value boxes are the **same width** (a fixed trailing column reserves space for **Map** on the Location row and **Life List** under Map on the Month row):

1. **Location** — tappable label showing the chosen place name (or **Choose Location**). Menu of **imported** eBird areas only, plus **Manage locations** (rename / delete saved imports) and **Add location** (eBird API hotspot search or barchart `.txt`). Paste a free API key under **Settings → eBird API** (Keychain; never committed). There is no default / curated place list in the menu. With no imports, the home screen prompts you to add a location. When a place is active, **Map** sits on the same row, always shows the word **Map** (not icon-only), and stays **top-aligned** with the Location value pill when the name wraps to two lines; it opens Apple Maps using a renamed title or a known eBird hotspot name for sample L-codes.
2. **Month** — tappable label showing the month name. Picker defaults to the device’s calendar month (no “Current” / “This month” wording). Imported eBird lists use that month’s frequencies for “likely” birds. On the same trailing column under Map: **Life List** opens your imported eBird life list as a **full-screen peer** to the Field Guide (not a popup or sheet).

There is **no Zone control** on the home screen. Habitat zones (ground / low / mid / canopy / sky) still appear as labels on list rows and on bird detail; the home list is not filtered by zone.

## Life List

**Life List** is a full-screen peer to the Field Guide home (same overall list format — not a modal). On **iPad and Mac** (regular width) it uses the same **NavigationSplitView** pattern as the Field Guide: the life-list sidebar on the left and a larger photo + recorded info for the selected bird on the right. The sidebar list is **leading-aligned** (not centered) to match the Field Guide column. On iPhone it keeps a push stack. Its header controls mirror the Field Guide chrome:

1. **Country** — tappable filter (**Global** or a country from the import).
2. **Map** — opens an in-app map with pins (no title/subtitle labels) for **every** unique life-list first/last sighting location under the current Country / Global filter. Coordinates prefer imported hotspot lat/lng, then eBird hotspot match by LocID / region list (when an API key is saved), then place-name geocoding; successes are cached on device. Only places that cannot be resolved (for example private sites with no usable name) stay unpinned — the banner reports that shortfall. There is no artificial pin-count cap.
3. **Bird Count Total** — display-only count for the current country filter (not a button).
4. **Field Guide** — returns to the Field Guide home.

Rows use the same overall list formatting as the Field Guide list (thumbnail + serif common name + italic scientific name), and show:

- **Bird name**
- **Latest Record** date and location (when present)

Import an eBird **Life List CSV** from My eBird → Sightings Lists → Download, or a **My Data** export:

- Classic life-list CSV (`Date`, `Location`, `Countable`, …): `Date` / `Location` fill **Latest Record**.
- **My Data** (`Submission ID`, …): aggregates observations per species; the UI shows the imported date/location as **Latest Record**.

**Sync:** The list JSON and attached photos use the same Birdlists ubiquity layout as imported locations — iCloud Drive → Handy Field Guide → Birdlists → `life-list.json` and `life-list-photos/`, with a local `Documents/Birdlists/` mirror for offline. Photos sync across iPhone, iPad, and Mac when the same iCloud account is signed in; large JPEGs may lag until ubiquity finishes downloading, and photos are unavailable on another device until that download completes (or if iCloud Drive is off for the app). Legacy `Documents/life-list-photos/` files are migrated into Birdlists on load.

On the detail pane, layout follows size class: on **iPad / Mac** (regular width) the bird **name** and **Latest Record** share one top line with the scientific name below — no second copy of the name in the nav title. On **iPhone** (compact), **Latest Record** stacks under the scientific name. Detail photos use the same **ZoomablePhoto** chrome as the Field Guide (pinch / double-tap zoom, long-press full screen). Each species can hold **multiple** Photos-library attaches plus Field Guide **Stock** images (male / female when present); on iPad / Mac two-up when there are two or more. **Add photo from library** (multi-select) and **Remove photo** sit on the same action row — Remove deletes the selected library photo (tap a My photo badge row to select). On **iPad / Mac** you can also **drag and drop** image files onto the Life List detail to append them; on **iPhone**, **Paste photo** accepts images copied from Photos (resized smaller before store). Each photo shows a badge: **My photo** (brighter green background) for library attaches, or **Stock** for Field Guide / open-licence Commons images. Library attaches are stored as a `photos` array in `life-list.json` (with JPEG files under `life-list-photos/`) so they survive iCloud sync; older single-photo documents migrate on load.

```bash
python3 scripts/verify_ebird_life_list.py
```

**Sky** is for birds typically seen overhead (flying, soaring, or hawking), separate from canopy perches.

Likelihood on rows and detail uses plain wording only (**Near-certain**, **Likely**, **Possible**, and related phrases). The UI does not show “Tier 3” style labels.

When curated, a bird shows its **most likely time of day** (dawn / morning / midday / afternoon / dusk / night) on list rows and on the detail screen. These are broad field periods from typical habits, not clock times. If time-of-day is unknown, the section is omitted entirely — never invented from monthly eBird columns.

When a published total length is known, list rows and the detail screen show one short line, always in the same form: **Length 14–18 cm**. On the detail screen that line sits in a **Size** section with a sparrow-to-ostrich scale (sparrow, myna, pigeon, crow, duck, heron, ostrich) and a mark for where this bird falls. Lengths are the bundled figures. If a bird has no length, the line and the scale are left off.

Species detail shows one badge — **Sexually dimorphic** (“Sexes do not look alike”) or **Not sexually dimorphic** (“Sexes look alike”) — instead of a Sexes paragraph. Photographs support **pinch to zoom**, **drag to pan**, double-tap zoom, and long-press for a full-screen viewer. Dimorphic species keep labeled **Male** / **Female** photos when openly licensed Commons images exist; monomorphic species show one photo. A compact **Photo Attr** badge opens photographer, licence, and source (required attribution stays available, just not inline under every image). You can also attach **your own photo** from the Photos library; on **iPad / Mac** by **drag and drop** onto the photo area, and on **iPhone** by **Paste photo** after copying in Photos (images are resized smaller before store). Those are badged **My photo** (same green treatment as Life List) and stored in the on-device `species-photos` cache for that role. **Remove my photo** clears a library attach so a bundled stock image can return when one exists. Under each photo, **Find another photo** (or **Find another male/female photo**) opens a Wikimedia Commons picker for another open-licence image; the full-screen viewer also offers **Find another**. Chosen Commons photos replace the on-device cache for that species/role and update Photo Attr.

## Locations

The Location picker shows **only** places you have imported (or added via the sample). Bundled `guide.json` species notes still enrich matching common names on imports, but Monteverde / Melbourne presets are not offered as selectable lists. With no active import, the app shows an empty state and does not invent birds.

## eBird import (API + barchart file)

### API key

1. Get a free key at [ebird.org/api/keygen](https://ebird.org/api/keygen).
2. Open **Settings → eBird API**, paste the key, and tap **Save key**.
3. The key is stored in the device Keychain only (clear / replace anytime). It is never written to Birdlists JSON or the git repo.

### Import via eBird API

Use **Add location → Import via eBird API**. Search by hotspot name, region code (`CR`, `US-CA`), or L-code; pick a hotspot; optionally merge nearby hotspots (**max** frequency per species, never sum).

Place-name search geocodes the query and uses `api.ebird.org` hotspot/geo + region lists. It does **not** call `ref/region/find` (that endpoint returns HTTP 403 even with a valid personal key). The API token is sent only to `api.ebird.org` as `X-eBirdApiToken` — never to the `ebird.org` website histogram host.

Frequency prefers eBird’s bar-chart histogram download (`/barchartData`, 48 weekly columns). If that website endpoint hits a sign-in or bot wall, the app falls back to the official API species list plus monthly historic samples. Hotspot `lat`/`lng` drive the Map link when present. After save, lists live in iCloud Birdlists + the local mirror and work offline; on-import photo fetch fills gaps as with file import.

### Barchart `.txt` file

Use **Import barchart .txt** (or **Add sample L436229**) for an eBird Frequency / barchart `.txt` export (tab-separated text).

- The app reads the eBird location id from the filename when present (for example `L436229`).
- The saved / displayed list name drops a trailing `.txt` (case-insensitive) when the name comes from the export filename.
- Each month aggregates the four week columns as a **mean**.
- “sp.” and slash taxa are parsed, flagged, and hidden from the main list unless you turn them on in **Settings**.
- Species with selected-month mean frequency below **0.5%** (`0.005`) are hidden by default as scarce / near-zero (toggle in **Settings**).
- Photo and field-note enrichment targets every species whose **any-month** mean frequency is at or above the scarce threshold (**0.5%** / `0.005`), reusing `guide.json` when the common name matches and filling remaining gaps from `ebird_supplemental.json` / Wikimedia Commons (open licences only). Download order still prefers the selected month.
- The sample file is bundled at `HandyFieldGuide/Resources/fixtures/ebird_L436229__2020_2026_1_12_barchart.txt` and copied into the app Documents folder (visible in Files → On My iPhone → Handy Field Guide) for re-import.
- **Imported bird lists** persist under **Birdlists** in the app’s iCloud Documents container (`iCloud.com.mulroneyp.handyfieldguide` → `Documents/Birdlists/imported-locations.json`), shown in Files as **iCloud Drive → Handy Field Guide → Birdlists** when iCloud Drive is on. Ubiquity keeps a **local on-device copy**, so already-imported lists open with **no network**. If iCloud is signed out or unavailable, the app uses the sandbox mirror `Documents/Birdlists/` and promotes it to iCloud when available. Legacy `Documents/imported-locations.json` is migrated into Birdlists on first launch (legacy file is not wiped if the copy fails). Species photo cache stays in local Documents and is unchanged.
- **Manage locations** renames or deletes saved imports against that Birdlists store. Deleting an active import returns to the empty state until you choose or add another import.

Verify parsing on a machine with Python:

```bash
python3 scripts/verify_ebird_barchart.py
```

Rebuild the supplemental Commons catalog (optional, network):

```bash
python3 scripts/enrich_ebird_supplemental.py
```

Fill published total-length ranges for guide / supplemental gaps and scarce import taxa (optional, network; Wikipedia):

```bash
python3 scripts/fill_bird_lengths.py
```

Resplendent Quetzal stays blank on purpose (body vs plume streamers). Hybrid / slash forms are not given a single-species length. Scarce names without a clear species page also stay blank.

## Photos

Photos live in `HandyFieldGuide/Resources/images`. Credits are in `HandyFieldGuide/Resources/guide.json`, `HandyFieldGuide/Resources/ebird_supplemental.json`, and under each photo. Licences are public domain, CC0, CC BY, CC BY-SA, or GFDL only — never NC/ND or other non-open licences.

After an eBird barchart import, the app looks up open-licence Wikimedia Commons photos for species that still lack a local image. Downloads are cached under the app Documents folder (`species-photos/`, keyed by species id) and reused across locations. A progress sheet shows count done / total, percent, and an updating time-remaining estimate; cancel stops further network work without undoing the import. Dimorphic species try male + female and fall back to a single photo when only one open-licence image is found. Bundled / offline photos stay preferred; new fetches fill gaps only. Network failures are partial and non-blocking (timeouts + Commons rate limiting).

On bird detail, **Find another photo** (Commons search, not Macaulay) lets you replace a poor image: the sheet ranks open-licence candidates, you pick one, and the JPEG plus attribution land in `species-photos` and prefer over the bundled default for that role thereafter. Missing-photo species get **Find a photo** / **Find male photo** / **Find female photo** chips instead.

Commons search for gaps (especially dimorphic male/female pairs) uses a **wide query set**: common name, scientific name, alternate names, and sex keywords (including ♂/♀ and Spanish/German labels), plus Commons categories, with a higher result limit. Rebuild helpers:

```bash
python3 scripts/fill_dimorphic_photos.py   # fill / relabel male–female gaps
python3 scripts/enrich_ebird_supplemental.py
python3 scripts/check_guide.py
```

This project was assembled on a Linux machine without Xcode. It has not been compiled or run in the iOS simulator here.
