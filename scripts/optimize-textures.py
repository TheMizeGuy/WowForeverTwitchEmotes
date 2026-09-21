#!/usr/bin/env python3
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Fit the emote textures into a byte budget with the least visible loss.

Animations: alpha snap, temporal stabilisation, duplicate frames folded into a playback
sequence, the widest legal sheet layout, libimagequant palettes with run merging, and one
height rung per emote chosen by a global allocation against --budget. Frame timing never
changes. Statics keep their height and become BLP2 only when that is smaller within the
error limit. Every rung is encoded once and cached, so another budget only re-allocates.
"""
import argparse
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import re
import runpy
import statistics
import sys
import tempfile
import time

MISSING = [name for name in ('numpy', 'imagequant') if importlib.util.find_spec(name) is None]
if MISSING:
    raise SystemExit('optimize-textures.py needs ' + ' and '.join(MISSING)
                     + ': python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements-build.txt')

import texture_pipeline as pipeline

builder = runpy.run_path(str(Path(__file__).with_name('build-7tv-pack.py')))
GEOMETRY = ('width', 'height', 'frames', 'fps', 'cellWidth', 'columns', 'sheetWidth', 'sheetHeight')
LOSSLESS = ('width', 'height', 'frames', 'cellWidth', 'columns', 'sheetWidth', 'sheetHeight')
DEFAULT_HEIGHTS = (64, 48, 40, 32)
DEFAULT_MERGES = (3, 5, 8)
DEFAULT_FLOOR = 0.85
BASELINE_ZIP = 'TwitchEmotes-3.0.0-tga-baseline.zip'
BASELINE_DIRS = (Path('/Users/mize/Dev/WowAddons/.worktrees/TwitchEmotes-original/dist'),)
TEXTURE_PATTERN = r'Media/(7tv|bttv|ffz|twitch)/[A-Za-z0-9][A-Za-z0-9_-]*\.(tga|blp)'


def parse_heights(value):
    heights = tuple(int(item) for item in str(value).split(','))
    if heights[0] != pipeline.SOURCE_HEIGHT or any(a <= b or b < 1 for a, b in zip(heights, heights[1:])):
        raise ValueError('heights must start at 64 and strictly decrease')
    return heights


def parse_merges(value):
    merges = tuple(int(item) for item in str(value).split(','))
    if any(a >= b or a < 1 for a, b in zip(merges, merges[1:])) or merges[0] < 1 or merges[-1] > 16:
        raise ValueError('merge thresholds must be 1..16 and strictly increase')
    return merges


def parse_near(value):
    if value == 'off':
        return None
    maxabs, rms = value.split(':')
    maxabs, rms = int(maxabs), float(rms)
    if maxabs < 0 or rms < 0:
        raise ValueError('near takes maxabs:rms, both non-negative, or off')
    return maxabs, rms


def default_source(root):
    for directory in (root / 'dist',) + BASELINE_DIRS:
        if (directory / BASELINE_ZIP).is_file():
            return directory / BASELINE_ZIP
    return root / 'TwitchEmotes' / 'Media'


def source_spec(path):
    path = Path(path)
    if path.is_file():
        return 'zip', str(path)
    if path.is_dir():
        return 'dir', str(path)
    raise ValueError('source must be a zip or a Media directory: ' + str(path))


def load_manifests(root):
    addon = root / 'TwitchEmotes'
    manifests, entries = {}, {}
    for path in sorted((root / 'packs').glob('*.json')):
        pack = json.loads(path.read_text(encoding='utf-8'))
        builder['safe_component'](pack['id'])
        if pack['id'] != path.stem:
            raise ValueError('pack filename differs from ID')
        manifests[path] = pack
        for entry in pack['emotes']:
            relative = entry['texture']
            if not re.fullmatch(TEXTURE_PATTERN, relative):
                raise ValueError('unsafe texture path: ' + relative)
            texture = addon / relative
            if texture.resolve() != texture:
                raise ValueError('linked texture path: ' + relative)
            previous = entries.get(relative)
            if previous and any(previous.get(key) != entry.get(key)
                                for key in ('texture_sha256', 'sequence', 'lossless') + GEOMETRY):
                raise ValueError('conflicting shared texture: ' + relative)
            entries[relative] = entry
    if not entries:
        raise ValueError('no pack textures found')
    return manifests, entries


def lossless_geometry(entry):
    """The 64 px source sheet an entry was optimized from; an unoptimized entry describes it itself."""
    lossless = entry.get('lossless')
    if lossless:
        return {key: lossless[key] for key in ('sha256',) + LOSSLESS}
    if entry['height'] != pipeline.SOURCE_HEIGHT or 'sequence' in entry:
        raise ValueError('entry lacks its lossless source geometry: ' + entry['texture'])
    return dict({key: entry[key] for key in LOSSLESS},
                sha256=entry['texture_sha256'] if entry['texture'].endswith('.tga') else None)


def progress(stream, count):
    started = time.time()
    for index, result in enumerate(stream, 1):
        if index % 100 == 0 or index == count:
            print(f'  encoded {index}/{count} textures ({time.time() - started:.0f} s)', file=sys.stderr, flush=True)
        yield result


def run_jobs(jobs, workers):
    if workers == 1:
        return list(progress(map(pipeline.process_texture, jobs), len(jobs)))
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as executor:
        return list(progress(executor.map(pipeline.process_texture, jobs, chunksize=4), len(jobs)))


def summarize(results, picks, total, budget):
    animations = [picks[item['texture']] for item in results if item['animated']]
    statics = [picks[item['texture']] for item in results if not item['animated']]
    scores = sorted(item['ssim'] for item in animations)
    heights, merges = {}, {}
    for item in animations:
        heights[item['height']] = heights.get(item['height'], 0) + 1
        merges[item['merge']] = merges.get(item['merge'], 0) + 1
    return dict(before=sum(item['old_size'] for item in results), after=total, budget=budget,
                within_budget=budget <= 0 or total <= budget, animations=len(animations), statics=len(statics),
                statics_converted=sum(1 for item in statics if item['suffix'] == '.blp'),
                tga_remaining=sum(1 for item in animations + statics if item['suffix'] == '.tga'),
                heights={str(height): heights[height] for height in sorted(heights, reverse=True)},
                merges={str(merge): merges[merge] for merge in sorted(merges)},
                ssim=dict(mean=statistics.fmean(scores), p05=scores[len(scores) // 20], min=scores[0]) if scores else None,
                compressor=pipeline.COMPRESSOR)


def print_summary(summary):
    mib = 1024 * 1024
    print(f'textures: {summary["before"] / mib:.1f} MiB -> {summary["after"] / mib:.1f} MiB ({summary["compressor"]})'
          + (f', budget {summary["budget"] / mib:.1f} MiB' + ('' if summary['within_budget'] else ' EXCEEDED at the floor')
             if summary['budget'] > 0 else ', no budget'))
    print('animation heights: ' + ', '.join(f'{height} px: {count}' for height, count in summary['heights'].items()))
    print('merge thresholds: ' + ', '.join(f'{merge}: {count}' for merge, count in summary['merges'].items()))
    if summary['ssim']:
        print(f'chosen SSIM: mean {summary["ssim"]["mean"]:.4f}, p05 {summary["ssim"]["p05"]:.4f}, min {summary["ssim"]["min"]:.4f}')
    print(f'statics converted to BLP2: {summary["statics_converted"]}/{summary["statics"]}; TGA files remaining: {summary["tga_remaining"]}')


def optimize(root, source=None, budget=0, heights=DEFAULT_HEIGHTS, hold=3, near=(3, 1.0), workers=8,
             cache=None, report=None, dry_run=False, floor=DEFAULT_FLOOR, merges=DEFAULT_MERGES):
    if not 1 <= workers <= 8:
        raise ValueError('workers must be 1..8')
    if hold < 0 or budget < 0:
        raise ValueError('hold and budget must be non-negative')
    if not 0 <= floor <= 1:
        raise ValueError('floor must be within 0..1')
    root = Path(root).resolve()
    addon = root / 'TwitchEmotes'
    cache = Path(cache) if cache else root / '.cache' / 'optimize'
    source = source_spec(source if source else default_source(root))
    manifests, entries = load_manifests(root)
    animated = dict(hold=hold, near=list(near) if near else None, version=pipeline.PIPELINE_VERSION, compressor=pipeline.COMPRESSOR)
    static = dict(version=pipeline.PIPELINE_VERSION, compressor=pipeline.COMPRESSOR)
    jobs = []
    for relative in sorted(entries):
        entry = entries[relative]
        moving = entry['frames'] > 1
        jobs.append(dict(texture=relative, texture_sha256=entry['texture_sha256'], animated=moving,
                         lossless=lossless_geometry(entry), source=source, addon=str(addon), cache=str(cache),
                         params=animated if moving else static,
                         tags=[pipeline.rung_tag(h, m) for h in heights for m in merges] if moving else ['static']))
    results = run_jobs(jobs, workers)
    for item in results:
        item['animated'] = item['candidates'][0]['tag'] != 'static'
    rungs = {item['texture']: item['candidates'] for item in results if item['animated']}
    fixed = sum(item['candidates'][0]['size'] for item in results if not item['animated'])
    chosen, total = pipeline.allocate(rungs, budget, fixed, floor)
    picks = {item['texture']: item['candidates'][chosen.get(item['texture'], 0)] for item in results}
    summary = dict(summarize(results, picks, total, budget), dry_run=dry_run,
                   parameters=dict(source=source[1], heights=list(heights), merges=list(merges), hold=hold,
                                   near=list(near) if near else None, floor=floor))
    summary['textures'] = {item['texture']: dict({key: picks[item['texture']].get(key) for key in ('tag', 'height', 'merge', 'frames', 'suffix', 'size', 'error', 'ssim')},
                                                 old_size=item['old_size']) for item in results}
    print_summary(summary)
    summary['published'] = publish(root, addon, cache, manifests, entries, results, picks, dry_run)
    if report:
        Path(report).parent.mkdir(parents=True, exist_ok=True)
        Path(report).write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return summary


def publish(root, addon, cache, manifests, entries, results, picks, dry_run):
    """Write the chosen textures and every manifest and Lua module they change; nothing on a dry run."""
    updates, changed = {}, 0
    for item in results:
        relative, pick = item['texture'], picks[item['texture']]
        target = Path(relative).with_suffix(pick['suffix']).as_posix()
        entry = {key: pick[key] for key in LOSSLESS}
        entry.update(texture=target, texture_sha256=pick['sha256'], lossless=item['lossless'])
        updates[relative] = dict(entry=entry, sequence=pick.get('sequence'), key=item['key'], tag=pick['tag'],
                                 write=target != relative or pick['sha256'] != entries[relative]['texture_sha256'])
        changed += updates[relative]['write']
    before = {path: json.dumps(pack, sort_keys=True) for path, pack in manifests.items()}
    for pack in manifests.values():
        for entry in pack['emotes']:
            update = updates[entry['texture']]
            entry.update(update['entry'])
            if update['sequence']:
                entry['sequence'] = update['sequence']
            else:
                entry.pop('sequence', None)
    modified = [path for path in manifests if json.dumps(manifests[path], sort_keys=True) != before[path]]
    rendered = {path: builder['render_lua'](pack, pack['emotes']) for path, pack in manifests.items()}
    stale = [path for path in manifests if path in modified
             or not (addon / 'Packs' / (manifests[path]['id'] + '.lua')).is_file()
             or (addon / 'Packs' / (manifests[path]['id'] + '.lua')).read_text(encoding='utf-8') != rendered[path]]
    if dry_run or not (changed or stale):
        return dict(textures=changed, packs=len(modified), lua=len(stale))
    with tempfile.TemporaryDirectory(prefix='.emote-optimize-', dir=root) as directory:
        stage = Path(directory)
        files = []
        for relative, update in updates.items():
            if not update['write']:
                continue
            target = stage / update['entry']['texture']
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(pipeline.cache_data(cache, update['key'], update['tag']))
            files.append((target, addon / update['entry']['texture']))
            if update['entry']['texture'] != relative:
                files.append((None, addon / relative))
        for path in modified:
            manifest = stage / path.name
            manifest.write_text(json.dumps(manifests[path], ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
            files.append((manifest, path))
        for path in stale:
            lua = stage / (manifests[path]['id'] + '.lua')
            lua.write_text(rendered[path], encoding='utf-8')
            files.append((lua, addon / 'Packs' / lua.name))
        builder['publish_files'](files, stage)
    return dict(textures=changed, packs=len(modified), lua=len(stale))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--source', type=Path, help='zip or Media directory of lossless 64 px TGA sheets (default: the baseline zip, else the addon Media directory)')
    parser.add_argument('--budget', type=int, default=0, help='texture byte budget for animations and statics; 0 never reduces height')
    parser.add_argument('--heights', type=parse_heights, default=DEFAULT_HEIGHTS, help='animation height rungs, highest first (default 64,48,40,32)')
    parser.add_argument('--merges', type=parse_merges, default=DEFAULT_MERGES,
                        help='palette run-merge thresholds tried at every height, ascending (default 3,5,8)')
    parser.add_argument('--hold', type=int, default=3, help='temporal stabilisation threshold; 0 disables')
    parser.add_argument('--near', type=parse_near, default=(3, 1.0), help='near-duplicate frame merge as maxabs:rms, or off')
    parser.add_argument('--floor', type=float, default=DEFAULT_FLOOR,
                        help='lowest SSIM (versus the 64 px frames at 1440p, 40 units) a chosen rung may have (default 0.85)')
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--cache', type=Path, help='encoded candidate cache (default .cache/optimize)')
    parser.add_argument('--report', type=Path, help='JSON report path (default <cache>/report.json)')
    parser.add_argument('--dry-run', action='store_true', help='measure and report without writing textures or manifests')
    args = parser.parse_args()
    cache = args.cache or args.root / '.cache' / 'optimize'
    optimize(args.root, args.source, args.budget, args.heights, args.hold, args.near, args.workers,
             cache, args.report or cache / 'report.json', args.dry_run, args.floor, args.merges)


if __name__ == '__main__':
    main()
