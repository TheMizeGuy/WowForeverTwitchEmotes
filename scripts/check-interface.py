#!/usr/bin/env python3
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Confirm every client family's manifest declares the interface number of the live Battle.net build."""
import ast
from pathlib import Path
import sys
import urllib.request

VERSIONS_URL = 'https://us.version.battle.net/{}/versions'
# Battle.net product -> the manifests that client may read: its game-type manifest first, then the Mainline
# family fallback for retail (wow) and Forever (wowf); the bare TOC lists every client's number as well.
PRODUCTS = {
    'wow': ('TwitchEmotes_Standard.toc', 'TwitchEmotes_Mainline.toc'),
    'wow_classic': ('TwitchEmotes_Mists.toc',),
    'wow_anniversary': ('TwitchEmotes_TBC.toc',),
    'wow_classic_era': ('TwitchEmotes_Vanilla.toc',),
    'wowf': ('TwitchEmotes_Camelot.toc', 'TwitchEmotes_Mainline.toc'),
}
FALLBACK = 'TwitchEmotes.toc'


def flavor_tocs(package=Path(__file__).with_name('package.py')):
    """Read FLAVOR_TOCS from package.py without importing it, since its imports need Pillow."""
    for node in ast.parse(package.read_text(encoding='utf-8')).body:
        if isinstance(node, ast.Assign) and any(getattr(target, 'id', None) == 'FLAVOR_TOCS' for target in node.targets):
            return ast.literal_eval(node.value)
    raise ValueError('FLAVOR_TOCS not found in ' + str(package))


def live_version(text, region='us'):
    """Return the VersionsName of one region from a Battle.net versions response."""
    rows = [line.split('|') for line in text.splitlines() if line.strip() and not line.startswith('#')]
    if not rows:
        raise ValueError('empty versions response')
    header = [field.split('!')[0] for field in rows[0]]
    for row in rows[1:]:
        fields = dict(zip(header, row))
        if fields.get('Region') == region and fields.get('VersionsName'):
            return fields['VersionsName']
    raise ValueError(f'no {region} version in the response')


def interface_number(version):
    major, minor, patch = (int(part) for part in version.split('.')[:3])
    return major * 10000 + minor * 100 + patch


def check(fetch, tocs, products=PRODUCTS):
    """Return (ok, line) per product; fetch(url) returns the text of a versions response."""
    results = []
    for product, manifests in products.items():
        try:
            version = live_version(fetch(VERSIONS_URL.format(product)))
            interface = interface_number(version)
        except (OSError, ValueError) as error:
            results.append((False, f'{product}: FAILED to read the live version ({error})'))
            continue
        names = manifests + (FALLBACK,)
        missing = [name for name in names if str(interface) not in (part.strip() for part in tocs[name].split(','))]
        if missing:
            results.append((False, f'{product} {version}: interface {interface} MISSING from {", ".join(missing)}'))
        else:
            results.append((True, f'{product} {version}: interface {interface} OK in {", ".join(names)}'))
    return results


def fetch_url(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode('utf-8')


def main(fetch=fetch_url):
    results = check(fetch, flavor_tocs())
    for _, line in results:
        print(line)
    return 0 if all(ok for ok, _ in results) else 1


if __name__ == '__main__':
    sys.exit(main())
