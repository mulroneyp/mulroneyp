# App icon source

Bird + binoculars mark for **Handy Field Guide**. Colors follow `GuideColor` in `HandyFieldGuide/Theme.swift` (forest green field, cream bird, rust optics).

## Files

| Path | Role |
|------|------|
| `source-1024.png` | **Authoritative** 1024×1024 master art (opaque RGB) |
| `source.svg` | Editable vector sketch of the same composition |
| `preview-1024.png` | Copy of the master written by the generator |
| `../../HandyFieldGuide/Assets.xcassets/AppIcon.appiconset/` | Xcode AppIcon set (generated PNGs + `Contents.json`) |

## Regenerate asset catalog sizes

From the `HandyFieldGuide/` project root:

```bash
pip install Pillow
python3 scripts/generate_app_icon.py
```

That reads `design/app-icon/source-1024.png`, writes every PNG size into `HandyFieldGuide/Assets.xcassets/AppIcon.appiconset/`, refreshes `Contents.json` (universal 1024 + iPhone/iPad slots), and updates `preview-1024.png`.

Options:

- `--source PATH` — alternate master PNG
- `--out-dir PATH` — write the `.appiconset` elsewhere
- `--preview PATH` — alternate preview output

## Replacing the master art

1. Drop a new opaque **1024×1024** PNG at `source-1024.png` (no transparency; App Store rejects alpha on marketing icons).
2. Optionally update `source.svg` so the vector sketch stays in sync.
3. Run `python3 scripts/generate_app_icon.py`.

## Design notes

- Cream bird on deep green so the silhouette still reads at notification / Settings sizes.
- Bird perched on binoculars — both shapes stay distinct; no text, no purple gradients.
- Keep ~10% safe margin from the square edges for iOS continuous-corner masking.
