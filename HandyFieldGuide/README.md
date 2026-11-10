# Handy Field Guide

An iPhone field guide. Open `HandyFieldGuide.xcodeproj` in Xcode, pick the HandyFieldGuide scheme, and run it on an iPhone simulator or a phone. No development team is set, so Xcode will ask for one before a device build.

## Home filters

Location, Month, Zone, and Settings sit in a **bottom toolbar** so the bird list keeps the space above:

1. **Location** — generic bar label (no place name in the toolbar). Menu of **imported** eBird areas only, plus **Manage locations** (rename / delete saved imports) and **Add eBird barchart**. There is no default / curated place list in the menu. With no imports, the home screen prompts you to add a barchart. The active place name stays in the main header.
2. **Month** — picker that defaults to the device’s calendar month. The bar shows the month name only (no “Current” / “This month” wording). Imported eBird lists use that month’s frequencies for “likely” birds.
3. **Zone** — multi-select ground / low / mid / canopy / sky. Birds matching **any** selected zone appear. **Any** clears the filter. Long zone descriptions stay behind a small **i** button.
4. **Settings** — gear opens scarce / near-zero hide and flagged “sp.” / slash taxa toggles (moved off the main list).

Above the bird list for an active import, the **location name** is shown with a **Map** control (opens Apple Maps using a renamed title or a known eBird hotspot name for sample L-codes) and a small **i** that reveals the long coverage prose in a sheet, matching the Zone info pattern.

**Sky** is for birds typically seen overhead (flying, soaring, or hawking), separate from canopy perches.

Likelihood on rows and detail uses plain wording only (**Near-certain**, **Likely**, **Possible**, and related phrases). The UI does not show “Tier 3” style labels.

Each bird also shows a **most likely time of day** (dawn / morning / midday / afternoon / dusk / night) on list rows and on the detail screen. These are broad field periods from typical habits, not clock times. eBird barcharts are monthly, not hourly — uncurated import stubs say so when time-of-day data is missing.

Species detail shows one badge — **Sexually dimorphic** or **Not sexually dimorphic** — instead of a Sexes paragraph. Photographs support **pinch to zoom**, **drag to pan**, double-tap zoom, and long-press for a full-screen viewer. Dimorphic species keep labeled **Male** / **Female** photos when openly licensed Commons images exist; monomorphic species show one photo. A compact **Photo Attr** badge opens photographer, licence, and source (required attribution stays available, just not inline under every image).

## Locations

The Location picker shows **only** places you have imported (or added via the sample). Bundled `guide.json` species notes still enrich matching common names on imports, but Monteverde / Melbourne presets are not offered as selectable lists. With no active import, the app shows an empty state and does not invent birds.

## eBird barchart import

Use **Add eBird barchart** (or **Add sample L436229**) to import an eBird Frequency / barchart `.txt` export (tab-separated text).

- The app reads the eBird location id from the filename when present (for example `L436229`).
- Each month aggregates the four week columns as a **mean**.
- “sp.” and slash taxa are parsed, flagged, and hidden from the main list unless you turn them on in **Settings**.
- Species with selected-month mean frequency below **0.5%** (`0.005`) are hidden by default as scarce / near-zero (toggle in **Settings**).
- Photo and field-note enrichment targets every species whose **any-month** mean frequency is at or above the scarce threshold (**0.5%** / `0.005`), reusing `guide.json` when the common name matches and filling remaining gaps from `ebird_supplemental.json` / Wikimedia Commons (open licences only). Download order still prefers the selected month.
- The sample file is bundled at `HandyFieldGuide/Resources/fixtures/ebird_L436229__2020_2026_1_12_barchart.txt` and copied into the app Documents folder (visible in Files → On My iPhone → Handy Field Guide) for re-import.
- **Manage locations** renames or deletes saved imports (persisted in Documents). Deleting an active import returns to the empty state until you choose or add another import.

Verify parsing on a machine with Python:

```bash
python3 scripts/verify_ebird_barchart.py
```

Rebuild the supplemental Commons catalog (optional, network):

```bash
python3 scripts/enrich_ebird_supplemental.py
```

## Photos

Photos live in `HandyFieldGuide/Resources/images`. Credits are in `HandyFieldGuide/Resources/guide.json`, `HandyFieldGuide/Resources/ebird_supplemental.json`, and under each photo. Licences are public domain, CC0, CC BY, CC BY-SA, or GFDL only — never NC/ND or other non-open licences.

Commons search for gaps (especially dimorphic male/female pairs) uses a **wide query set**: common name, scientific name, alternate names, and sex keywords (including ♂/♀ and Spanish/German labels), plus Commons categories, with a higher result limit. Rebuild helpers:

```bash
python3 scripts/fill_dimorphic_photos.py   # fill / relabel male–female gaps
python3 scripts/enrich_ebird_supplemental.py
python3 scripts/check_guide.py
```

This project was assembled on a Linux machine without Xcode. It has not been compiled or run in the iOS simulator here.
