# Handy Field Guide

An iPhone field guide. Open `HandyFieldGuide.xcodeproj` in Xcode, pick the HandyFieldGuide scheme, and run it on an iPhone simulator or a phone. No development team is set, so Xcode will ask for one before a device build.

## Home filters

The home screen sets three filters clearly:

1. **Location** — menu of curated places and any imported eBird areas, plus **Add new** to import a barchart.
2. **Month** — picker that defaults to the device’s current calendar month. Imported eBird lists use that month’s frequencies for “likely” birds.
3. **Zone** — ground / low / mid / canopy (or Any). Long zone descriptions stay behind a small **i** button.

Likelihood on rows and detail uses plain wording only (**Near-certain**, **Likely**, **Possible**, and related phrases). The UI does not show “Tier 3” style labels.

Species detail photographs support **pinch to zoom**, **drag to pan**, double-tap zoom, and long-press for a full-screen viewer. **Sexually dimorphic** species show a clearly labeled **Male** photo and **Female** photo when openly licensed Commons images exist; monomorphic species show one photo. Gaps are filled from Wikimedia Commons with attribution where possible.

## Curated places

An empty or default location opens the Children's Eternal Rainforest checklist for Monteverde: 171 species taken from the San Gerardo station list. Likelihood bands there are mid–late November estimates, not eBird frequencies. San Gerardo and Bajo del Tigre are presets on that same list. Greater Melbourne is a second, smaller curated list. If a typed place is outside both, the app says so and shows the closest list it actually has. It does not invent birds.

## eBird barchart import

Use **Add new** (or **Add sample L436229**) to import an eBird Frequency / barchart `.txt` export (tab-separated text).

- The app reads the eBird location id from the filename when present (for example `L436229`).
- Each month aggregates the four week columns as a **mean**.
- “sp.” and slash taxa are parsed, flagged, and hidden from the main list unless you turn them on.
- Species with selected-month mean frequency below **0.5%** (`0.005`) are hidden by default as scarce / near-zero.
- Photo and field-note enrichment for first run targets species with selected-month mean frequency at or above **5%** (`0.05`), plus the top 40 by that month, reusing `guide.json` when the common name matches and filling gaps from `ebird_supplemental.json` / Commons.
- The sample file is bundled at `HandyFieldGuide/Resources/fixtures/ebird_L436229__2020_2026_1_12_barchart.txt` and copied into the app Documents folder (visible in Files → On My iPhone → Handy Field Guide) for re-import.

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
