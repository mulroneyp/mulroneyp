#!/usr/bin/env python3
"""Document eBird auth quirks used by Handy Field Guide.

Uses a publicly committed sample token from third-party demos only — never a
personal key. Exit 0 when the documented behaviour still holds:

- ref/region/find → 403 even with that working token
- ref/hotspot/info / geo → 200 with the same token
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

# Public sample from third-party demos — not a personal / Paul key.
SAMPLE_KEY = "vcs68p4j67pt"
API = "https://api.ebird.org/v2"


def status(path: str, key: str | None = SAMPLE_KEY) -> int:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/json",
            "User-Agent": "HandyFieldGuide-verify/1.0",
            **({"X-eBirdApiToken": key} if key else {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as err:
        return int(err.code)


def main() -> int:
    find = status("/ref/region/find?q=Monteverde")
    info = status("/ref/hotspot/info/L436229")
    geo = status("/ref/hotspot/geo?lat=10.3&lng=-84.8&dist=50&fmt=json")
    no_key = status("/ref/hotspot/info/L436229", key=None)

    report = {
        "region_find_with_valid_sample_key": find,
        "hotspot_info_with_valid_sample_key": info,
        "hotspot_geo_with_valid_sample_key": geo,
        "hotspot_info_without_key": no_key,
    }
    print(json.dumps(report, indent=2))

    ok = find == 403 and info == 200 and geo == 200 and no_key == 403
    if not ok:
        print(
            "Unexpected eBird auth behaviour — re-check client assumptions.",
            file=sys.stderr,
        )
        return 1
    print(
        "OK: region/find 403s with a working key; hotspot info/geo authenticate normally."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
