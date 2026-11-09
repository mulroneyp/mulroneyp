# Melbourne birds

A walker's field guide to birds you are likely to see around greater Melbourne: parks, wetlands, the bay, and the suburbs.

It is a starter set of 77 species, not a full checklist of the region. Common and scientific names follow BirdLife Australia's current usage. Where a familiar book or the global AviList uses a different name, the other name is on the bird's page and in search.

Each species has habitat notes for local walks, and icons for the height where you usually see it: ground (including the water surface), low shrubs and branches, mid-level, or canopy. A bird can have more than one icon.

Sexes that look different each have a photo. Where males and females look alike, there is one photo, labelled as such.

## Run it

From this folder:

```bash
python3 -m http.server 8765
```

Open http://127.0.0.1:8765

Opening `index.html` directly will not load the list, because the page fetches `data/birds.json`.

## Photos and credit

Images in `images/` are resized copies of Wikimedia Commons files. Licences are public domain, CC0, CC BY, CC BY-SA, or GFDL. The photographer, licence, and a link to the original file are stored in `data/birds.json` and shown under each photo. Resized copies stay under the same licence as the original.

`scripts/species_data.py` holds the species text. `scripts/fetch_images.py` can rebuild the images and `data/birds.json` from Commons. `scripts/image_overrides.json` is optional and pins a specific Commons file when the automatic choice is wrong.
