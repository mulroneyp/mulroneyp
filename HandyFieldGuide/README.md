# Handy Field Guide

An iPhone field guide. Open `HandyFieldGuide.xcodeproj` in Xcode, pick the HandyFieldGuide scheme, and run it on an iPhone simulator or a phone. No development team is set, so Xcode will ask for one before a device build.

## Home filters

Location, Month, and Zone sit in a **bottom toolbar** so the bird list keeps the space above:

1. **Location** — menu of curated places and any imported eBird areas, plus **Manage locations** (rename / delete saved imports) and **Add eBird barchart**. Curated bundled presets stay in the menu and are not deleted.
2. **Month** — picker that defaults to the device’s current calendar month. Imported eBird lists use that month’s frequencies for “likely” birds.
3. **Zone** — multi-select ground / low / mid / canopy / sky. Birds matching **any** selected zone appear. **Any** clears the filter. Long zone descriptions stay behind a small **i** button.

**Sky** is for birds typically seen overhead (flying, soaring, or hawking), separate from canopy perches.

Likelihood on rows and detail uses plain wording only (**Near-certain**, **Likely**, **Possible**, and related phrases). The UI does not show “Tier 3” style labels.

Each bird also shows a **most likely time of day** (dawn / morning / midday / afternoon / dusk / night) on list rows and on the detail screen. These are broad field periods from typical habits, not clock times. eBird barcharts are monthly, not hourly — uncurated import stubs say so when time-of-day data is missing.

Species detail shows one badge — **Sexually dimorphic** or **Not sexually dimorphic** — instead of a Sexes paragraph. Photographs support **pinch to zoom**, **drag to pan**, double-tap zoom, and long-press for a full-screen viewer. Dimorphic species keep labeled **Male** / **Female** photos when openly licensed Commons images exist; monomorphic species show one photo. A compact **Photo Attr** badge opens photographer, licence, and source (required attribution stays available, just not inline under every image).

## Curated places

An empty or default location opens the Children's Eternal Rainforest checklist for Monteverde: 171 species taken from the San Gerardo station list. Likelihood bands there are mid–late November estimates, not eBird frequencies. San Gerardo and Bajo del Tigre are presets on that same list. Greater Melbourne is a second, smaller curated list. If a typed place is outside both, the app says so and shows the closest list it actually has. It does not invent birds.

## eBird barchart import

Use **Add eBird barchart** (or **Add sample L436229**) to import an eBird Frequency / barchart `.txt` export (tab-separated text).

- The app reads the eBird location id from the filename when present (for example `L436229`).
- Each month aggregates the four week columns as a **mean**.
- “sp.” and slash taxa are parsed, flagged, and hidden from the main list unless you turn them on.
- Species with selected-month mean frequency below **0.5%** (`0.005`) are hidden by default as scarce / near-zero.
- Photo and field-note enrichment for first run targets species with selected-month mean frequency at or above **5%** (`0.05`), plus the top 40 by that month, reusing `guide.json` when the common name matches and filling gaps from `ebird_supplemental.json` / Commons.
- The sample file is bundled at `HandyFieldGuide/Resources/fixtures/ebird_L436229__2020_2026_1_12_barchart.txt` and copied into the app Documents folder (visible in Files → On My iPhone → Handy Field Guide) for re-import.
- **Manage locations** renames or deletes saved imports (persisted in Documents). Deleting an active import returns to the default curated Monteverde list; curated presets themselves cannot be deleted.

Verify parsing on a machine with Python:

```bash
python3 scripts/verify_ebird_barchart.py
```

Rebuild the supplemental Commons catalog (optional, network):

```bash
python3 scripts/enrich_ebird_supplemental.py
```

## Photos

Photos live in `HandyFieldGuide/Resources/images`. Credits are in `HandyFieldGuide/Resources/guide.json`, `HandyFieldGuide/Resources/ebird_supplemental.json`, and under each photo. Licences are public domain, CC0, CC BY, CC BY-SA, or GFDL.

This project was assembled on a Linux machine without Xcode. It has not been compiled or run in the iOS simulator here.
