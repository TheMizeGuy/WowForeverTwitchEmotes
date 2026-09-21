#!/usr/bin/env python3
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Build provider-sourced emote packs for TwitchEmotes.

Requires Pillow. Use --all for every bundled channel and global catalog, or
--login CHANNEL --pack NAME for a 7TV channel. The --provider option also
supports Twitch, BTTV, FFZ, and individual global catalogs. Downloads are
cached; generated Lua, TGA textures, and provenance JSON are staged before
publishing. Native Twitch channel identities are in scripts/twitch-channels.json.
"""
import argparse
import bisect
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

from PIL import Image, features

FRAME_HEIGHT = 64
MAX_FRAME_WIDTH = 256
MAX_SHEET_SIZE = 2048
MAX_FRAMES = 256
MAX_FPS = 60
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
USER_AGENT = 'TwitchEmotes/3.0 (+https://github.com/TheMizeGuy/WowForeverTwitchEmotes)'
PROVIDER_LABELS = {'7tv': '7TV', 'bttv': 'BTTV', 'ffz': 'FFZ', 'twitch': 'Twitch'}
CDN_HOSTS = {'7tv': 'cdn.7tv.app', 'bttv': 'cdn.betterttv.net', 'ffz': 'cdn.frankerfacez.com',
             'twitch': 'static-cdn.jtvnw.net'}
GLOBAL_APIS = {
    '7tv-global': 'https://7tv.io/v3/emote-sets/global',
    'bttv-global': 'https://api.betterttv.net/3/cached/emotes/global',
    'ffz-global': 'https://api.frankerfacez.com/v1/set/global',
}
CHANNEL_IDS = {
    'graycen': '25743612', 'erobb221': '96858382', 'ahlaundoh': '32093909',
    'summit1g': '26490481', 'ziqoftw': '20567961', 'xaryu': '32085830',
    'pikabooirl': '27992608', 'swifty': '23524577',
}
BUNDLED_7TV_CHANNELS = (
    ('graycen', 'Graycen', 20), ('erobb221', 'erobb221', 30),
    ('ahlaundoh', 'Ahlaundoh', 20), ('summit1g', 'summit1g', 20),
    ('ziqoftw', 'Ziqoftw', 20), ('xaryu', 'Xaryu', 20),
)
BUNDLED_FALLBACKS = (('bttv', 'pikabooirl', 'Pikabooirl'),
                     ('ffz', 'pikabooirl', 'Pikabooirl'), ('bttv', 'swifty', 'Swifty'))


def safe_component(value):
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        raise ValueError('path component must be a string or integer ID')
    value = str(value)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', value):
        raise ValueError(f'unsafe path component: {value!r}')
    if re.fullmatch(r'CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]', value, flags=re.I):
        raise ValueError(f'reserved Windows path component: {value!r}')
    return value


def validate_text(value, limit=256):
    if not isinstance(value, str) or not value or len(value.encode('utf-8')) > limit:
        raise ValueError('metadata text must be a nonempty bounded string')
    if any(c == '|' or unicodedata.category(c).startswith('C') for c in value):
        raise ValueError(f'unsafe metadata text: {value!r}')
    return value


def validate_name(value):
    validate_text(value, 128)
    if any(c.isspace() for c in value):
        raise ValueError(f'emote name contains whitespace: {value!r}')
    return value


def validate_sequence(value, frames):
    # Playback order over the stored cells; the identity order is dropped so entries stay unchanged.
    if value is None:
        return None
    if not isinstance(frames, int) or isinstance(frames, bool) or frames < 2:
        raise ValueError('a frame sequence requires at least two stored frames')
    if not isinstance(value, (list, tuple)) or not 2 <= len(value) <= MAX_FRAMES:
        raise ValueError('a frame sequence must replay 2..256 stored cells')
    steps = []
    for step in value:
        if not isinstance(step, int) or isinstance(step, bool) or not 0 <= step < frames:
            raise ValueError(f'frame sequence step outside 0..{frames - 1}: {step!r}')
        steps.append(step)
    return None if steps == list(range(frames)) else steps


def image_url(value, provider):
    if value.startswith('//'):
        value = 'https:' + value
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != 'https' or parsed.netloc != CDN_HOSTS[provider]
            or parsed.fragment or parsed.query or len(value) > 512
            or any(c.isspace() or ord(c) < 32 for c in value)):
        raise ValueError(f'unexpected {provider} image URL: {value!r}')
    return value


def http_get(url, retries=3):
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(request, timeout=40) as response:
                data = response.read(MAX_DOWNLOAD_BYTES + 1)
            if not data or len(data) > MAX_DOWNLOAD_BYTES:
                raise ValueError(f'empty or oversized download: {url}')
            return data
        except urllib.error.HTTPError as exc:
            if exc.code not in (408, 429, 500, 502, 503, 504) or attempt == retries - 1:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries - 1:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError(f'download failed: {url}')


def get_json(url):
    return json.loads(http_get(url))


def base_pack(pack_id, title, provider, priority, source, metadata_api):
    return {'id': safe_component(pack_id), 'title': validate_text(title),
            'provider': PROVIDER_LABELS[provider], 'priority': priority,
            'group': 'general' if pack_id.endswith('_global') else pack_id,
            'groupTitle': 'General' if pack_id.endswith('_global') else title,
            'source': source, 'metadata_api': metadata_api, 'emotes': [], 'excluded': []}


def attribution(owner, provider, role='provider owner'):
    owner = owner or {}
    identifier = owner.get('id', owner.get('_id'))
    identifier = safe_component(identifier) if identifier is not None else None
    name = None
    for field in ('display_name', 'displayName', 'username', 'name'):
        try:
            name = validate_text(owner.get(field))
            break
        except ValueError:
            continue
    if not name and identifier:
        name = f'{PROVIDER_LABELS[provider]} account {identifier}'
    elif not name:
        name = 'Not supplied by provider'
    return {'creator': name, 'creator_id': identifier,
            'attribution': role if identifier or owner else 'not supplied'}


def entry(provider, identifier, name, url, extension, source, owner, role='provider owner'):
    identifier = safe_component(identifier)
    return {'id': provider + ':' + identifier, 'provider_id': identifier,
            'provider': provider, 'name': validate_name(name), 'source': source,
            'download': image_url(url, provider), 'format': extension,
            **attribution(owner, provider, role)}


def normalize_7tv(data, pack_id, title, priority, metadata_api):
    data = data.get('emote_set', data)
    set_id = safe_component(data['id'])
    pack = base_pack(pack_id, title, '7tv', priority, 'https://7tv.app/emote-sets/' + set_id, metadata_api)
    formats = ['webp', 'gif', 'png'] if features.check('webp') else ['gif', 'png']
    preferences = [f'{size}x.{extension}' for size in (4, 3, 2, 1) for extension in formats]
    for emote in data['emotes']:
        set_entry_id = safe_component(emote['id'])
        details = emote['data']
        identifier = safe_component(details['id'])
        host = details['host']
        files = {file['name']: file for file in host['files']}
        if details.get('lifecycle') == 0 and not files and not host['url']:
            pack['excluded'].append({'id': identifier, 'name': validate_name(emote['name']),
                                     'source': 'https://7tv.app/emotes/' + identifier,
                                     'reason': 'provider supplies no image'})
            continue
        filename = next((name for name in preferences if name in files), None)
        if filename is None:
            raise ValueError(f'no supported source image for 7TV emote {identifier}')
        record = entry('7tv', identifier, emote['name'], host['url'] + '/' + filename,
                       filename.rsplit('.', 1)[1], 'https://7tv.app/emotes/' + identifier,
                       details.get('owner'))
        record['set_entry_id'] = set_entry_id
        pack['emotes'].append(record)
    names = {}
    for record in pack['emotes']:
        prior = names.get(record['name'])
        if prior and prior['id'] != record['id']:
            pack['excluded'].append({'id': prior['provider_id'], 'name': prior['name'],
                                     'source': prior['source'], 'selected_id': record['id'],
                                     'reason': 'duplicate name; later catalog entry wins'})
        names[record['name']] = record
    pack['emotes'] = list(names.values())
    return pack


def normalize_bttv(data):
    pack = base_pack('bttv_global', 'BTTV Global', 'bttv', 10, 'https://betterttv.com/emotes/global',
                     GLOBAL_APIS['bttv-global'])
    for emote in data:
        identifier = safe_component(emote['id'])
        if emote.get('modifier'):
            pack['excluded'].append({'id': identifier, 'name': emote['code'], 'reason': 'modifier effect'})
            continue
        extension = emote['imageType']
        if extension not in ('png', 'gif', 'webp'):
            raise ValueError(f'unsupported BTTV image type: {extension!r}')
        owner = emote.get('user') or {'id': emote.get('userId')}
        pack['emotes'].append(entry('bttv', identifier, emote['code'],
                                    f'https://cdn.betterttv.net/emote/{identifier}/3x', extension,
                                    'https://betterttv.com/emotes/' + identifier, owner))
    return pack


def normalize_ffz(data):
    pack = base_pack('ffz_global', 'FFZ Global', 'ffz', 11, 'https://www.frankerfacez.com/emoticons/',
                     GLOBAL_APIS['ffz-global'])
    for set_id in data['default_sets']:
        for emote in data['sets'][str(set_id)]['emoticons']:
            identifier = safe_component(emote['id'])
            if emote.get('modifier'):
                pack['excluded'].append({'id': identifier, 'name': emote['name'], 'reason': 'modifier effect'})
                continue
            urls = emote.get('animated') or emote['urls']
            size = next((size for size in ('4', '3', '2', '1') if size in urls), None)
            if size is None:
                raise ValueError(f'no supported FFZ image size: {identifier}')
            owner = emote.get('artist') or emote.get('owner')
            role = 'provider artist' if emote.get('artist') else 'provider owner'
            pack['emotes'].append(entry('ffz', identifier, emote['name'], urls[size],
                                        'gif' if emote.get('animated') else 'png',
                                        'https://www.frankerfacez.com/emoticon/' + identifier,
                                        owner, role))
    return pack


def normalize_bttv_channel(data, login, title, twitch_id):
    login = safe_component(login.lower())
    pack = normalize_bttv(data.get('channelEmotes', []) + data.get('sharedEmotes', []))
    api = 'https://api.betterttv.net/3/cached/users/twitch/' + safe_component(twitch_id)
    pack.update(id='bttv_' + login, title=validate_text(title + ' (BTTV)'), priority=20,
                group=login, groupTitle=validate_text(title), source=api, metadata_api=api,
                channel_login=login, channel_id=str(twitch_id))
    return pack


def normalize_ffz_channel(data, login, title, twitch_id):
    login = safe_component(login.lower())
    room = data['room']
    if room['id'].lower() != login or str(room['twitch_id']) != str(twitch_id):
        raise ValueError('FFZ room does not match the requested Twitch channel')
    pack = normalize_ffz({'default_sets': [room['set']], 'sets': data['sets']})
    api = 'https://api.frankerfacez.com/v1/room/id/' + safe_component(twitch_id)
    pack.update(id='ffz_' + login, title=validate_text(title + ' (FFZ)'), priority=21,
                group=login, groupTitle=validate_text(title), source=api, metadata_api=api,
                channel_login=login, channel_id=str(twitch_id))
    return pack


def next_pow2(number):
    return 1 << max(0, (max(1, number) - 1).bit_length())


def load_frames(path):
    frames, durations = [], []
    raw_durations, normalized = [], False
    with Image.open(path) as source:
        count = getattr(source, 'n_frames', 1)
        if count > 4096 or source.width * source.height * count > 64 * 1024 * 1024:
            raise ValueError(f'source image exceeds decoding bounds: {path.name}')
        source_size = source.size
        cell_width = canvas_width_for(source)
        start = 1 if source.info.get('default_image') else 0
        for index in range(start, count):
            source.seek(index)
            # Keep only the scaled frame while decoding high-resolution animations.
            frames.append(fit_frame(source.convert('RGBA'), cell_width))
            duration = source.info.get('duration')
            known = isinstance(duration, (int, float)) and math.isfinite(duration) and duration >= 0
            raw_durations.append(float(duration) if known else None)
            valid = known and duration > 0
            durations.append(float(duration) if valid else 100.0)
            normalized = normalized or not valid
    source_duration = sum(raw_durations) if all(value is not None for value in raw_durations) else None
    timing = {'source_duration_ms': source_duration if len(frames) > 1 else 0,
              'timing_normalized': normalized and len(frames) > 1}
    return frames, durations, source_size, timing


def fit_frame(frame, canvas_w):
    width, height = frame.size
    scale = min(FRAME_HEIGHT / height, canvas_w / width)
    resized = frame.resize((max(1, round(width * scale)), max(1, round(height * scale))), Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA', (canvas_w, FRAME_HEIGHT), (0, 0, 0, 0))
    canvas.alpha_composite(resized, (0, (FRAME_HEIGHT - resized.height) // 2))
    return canvas


def canvas_width_for(frame):
    scaled_w = max(1, round(frame.width * FRAME_HEIGHT / frame.height))
    return next_pow2(min(MAX_FRAME_WIDTH, scaled_w))


def subsample(frames, durations, max_frames):
    if not 2 <= max_frames <= MAX_FRAMES:
        raise ValueError('max_frames must be between 2 and 256')
    if (not frames or len(frames) != len(durations)
            or any(not math.isfinite(d) or d <= 0 for d in durations)):
        raise ValueError('frames require matching positive durations')
    total_ms = sum(durations)
    if len(frames) == 1:
        return frames, total_ms
    uniform = all(duration == durations[0] for duration in durations)
    desired = len(frames) if uniform else math.ceil(total_ms / min(durations))
    count = min(max_frames, desired, max(1, int(total_ms * MAX_FPS / 1000)))
    if uniform and count == len(frames):
        return frames, total_ms
    ends, elapsed = [], 0
    for duration in durations:
        elapsed += duration
        ends.append(elapsed)
    return [frames[bisect.bisect_right(ends, index * total_ms / count)] for index in range(count)], total_ms


def grid_layout(frame_count, cell_width):
    candidates = []
    columns = 1
    while columns <= min(frame_count, 32) and columns * cell_width <= MAX_SHEET_SIZE:
        rows = math.ceil(frame_count / columns)
        width, height = columns * cell_width, next_pow2(rows * FRAME_HEIGHT)
        if height <= MAX_SHEET_SIZE:
            candidates.append((width * height, max(width, height), abs(width - height), columns, width, height))
        columns *= 2
    if not candidates:
        raise ValueError('animation does not fit the texture grid limits')
    _, _, _, columns, width, height = min(candidates)
    return columns, width, height


def convert(src, dest, max_frames):
    frames, durations, (source_width, source_height), timing = load_frames(src)
    source_frames = len(frames)
    cell_width = frames[0].width
    width = min(MAX_FRAME_WIDTH, max(1, round(source_width * FRAME_HEIGHT / source_height)))
    frames, total_ms = subsample(frames, durations, max_frames)
    count = len(frames)
    columns, sheet_w, sheet_h = grid_layout(count, cell_width)
    sheet = Image.new('RGBA', (sheet_w, sheet_h), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        sheet.paste(frame, ((index % columns) * cell_width, (index // columns) * FRAME_HEIGHT))
    sheet.save(dest, format='TGA', compression='tga_rle')
    return {'width': width, 'height': FRAME_HEIGHT, 'frames': count,
            'fps': count * 1000 / total_ms if count > 1 else 0,
            'cellWidth': cell_width, 'columns': columns, 'sheetWidth': sheet_w, 'sheetHeight': sheet_h,
            'source_width': source_width, 'source_height': source_height,
            'source_frames': source_frames, 'duration_ms': total_ms if source_frames > 1 else 0,
            **timing}


def lua_string(value):
    value = value.replace('\\', '\\\\').replace('"', '\\"')
    return '"' + ''.join(f'\\{ord(c):03d}' if ord(c) < 32 or ord(c) == 127 else c for c in value) + '"'


def lua_sequence(steps):
    return '"' + ''.join(f'\\{step:03d}' for step in steps) + '"'


def render_lua(pack, records):
    def literal(value):
        if isinstance(value, (list, tuple)):
            return lua_sequence(value)
        return lua_string(value) if isinstance(value, str) else repr(value)
    lines = ['local addonName, E = ...', '-- Generated from provider sources; see packs/' + pack['id'] + '.json.',
             'E:RegisterPack({']
    for key in ('id', 'title', 'provider', 'priority', 'source', 'group', 'groupTitle'):
        lines.append(f'  {key} = {literal(pack[key])},')
    lines.append('  emotes = {')
    for record in records:
        values = {key: record[key] for key in ('name', 'id', 'width', 'height', 'frames', 'fps')}
        steps = validate_sequence(record.get('sequence'), record['frames'])
        if steps:
            values['sequence'] = steps
        values.update((key, record[key]) for key in ('cellWidth', 'columns', 'sheetWidth', 'sheetHeight',
                                                     'creator', 'source'))
        values['path'] = 'Interface\\AddOns\\TwitchEmotes\\' + record['texture'].replace('/', '\\')
        lines.append('    { ' + ', '.join(f'{key} = {literal(value)}' for key, value in values.items()) + ' },')
    lines.extend(['  },', '})', ''])
    return '\n'.join(lines)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cache_source(record, cache_dir, download):
    provider, identifier = record['provider'], record['provider_id']
    extension = record['format']
    url_hash = hashlib.sha256(record['download'].encode('utf-8')).hexdigest()[:16]
    cached = cache_dir / provider / (identifier + '-' + url_hash + '.' + extension)
    legacy = cache_dir / (identifier + '.' + extension)
    if cached.is_file() and cached.stat().st_size:
        return cached
    if (provider == '7tv' and record['download'].endswith('/2x.' + extension)
            and legacy.is_file() and legacy.stat().st_size):
        return legacy
    cached.parent.mkdir(parents=True, exist_ok=True)
    data = download(record['download'])
    if not data or len(data) > MAX_DOWNLOAD_BYTES:
        raise ValueError(f'empty or oversized image: {record["id"]}')
    with tempfile.NamedTemporaryFile(dir=cached.parent, delete=False) as pending:
        pending.write(data)
        pending_path = Path(pending.name)
    try:
        with Image.open(pending_path) as image:
            image.verify()
        pending_path.replace(cached)
    finally:
        pending_path.unlink(missing_ok=True)
    return cached


def publish_files(files, stage):
    backups = stage / 'backups'
    backups.mkdir()
    published = []
    try:
        for index, (source, destination) in enumerate(files):
            destination.parent.mkdir(parents=True, exist_ok=True)
            backup = backups / str(index)
            if destination.exists():
                shutil.copy2(destination, backup)
            if source is None:
                destination.unlink()
            else:
                os.replace(source, destination)
            published.append((destination, backup))
    except OSError:
        for destination, backup in reversed(published):
            if backup.exists():
                os.replace(backup, destination)
            else:
                destination.unlink(missing_ok=True)
        raise


def build_packs(packs, addon_dir, manifest_dir, cache_dir, max_frames=MAX_FRAMES, workers=6, download=http_get):
    if not 2 <= max_frames <= MAX_FRAMES or not 1 <= workers <= 16:
        raise ValueError('max_frames must be 2..256 and workers must be 1..16')
    if not packs or len(packs) > 100 or len({pack['id'].lower() for pack in packs}) != len(packs):
        raise ValueError('provide 1..100 uniquely named packs')
    unique, names_by_pack, path_ids = {}, {}, {}
    for pack in packs:
        safe_component(pack['id'])
        if not pack['emotes'] or len(pack['emotes']) > 10000:
            raise ValueError(f'pack {pack["id"]} requires 1..10000 emotes')
        names = {}
        for record in pack['emotes']:
            validate_name(record['name'])
            safe_component(record['provider_id'])
            image_url(record['download'], record['provider'])
            folded_id = record['id'].casefold()
            if folded_id in path_ids and path_ids[folded_id] != record['id']:
                raise ValueError(f'case-colliding texture IDs: {record["id"]}')
            path_ids[folded_id] = record['id']
            previous = names.get(record['name'])
            if previous and previous['id'] != record['id']:
                raise ValueError(f'ambiguous emote name in {pack["id"]}: {record["name"]}')
            prior_asset = unique.get(record['id'])
            if prior_asset and prior_asset['download'] != record['download']:
                raise ValueError(f'conflicting source URLs for {record["id"]}')
            names[record['name']] = record
            unique[record['id']] = record
        names_by_pack[pack['id']] = names
    addon_dir, manifest_dir, cache_dir = Path(addon_dir), Path(manifest_dir), Path(cache_dir)
    addon_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.emote-build-', dir=addon_dir.parent) as directory:
        stage = Path(directory)
        assets = {}
        files = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            jobs = {executor.submit(cache_source, record, cache_dir, download): key for key, record in unique.items()}
            for job in concurrent.futures.as_completed(jobs):
                key, source = jobs[job], job.result()
                record = unique[key]
                relative = Path('Media') / record['provider'] / (record['provider_id'] + '.tga')
                texture = stage / relative
                texture.parent.mkdir(parents=True, exist_ok=True)
                try:
                    metadata = convert(source, texture, max_frames)
                except (OSError, ValueError) as exc:
                    raise ValueError(f'conversion failed for {key}: {exc}') from exc
                steps = validate_sequence(metadata.pop('sequence', None), metadata['frames'])
                if steps:
                    metadata['sequence'] = steps
                assets[key] = {**metadata, 'texture': relative.as_posix(), 'source_sha256': sha256(source),
                               'texture_sha256': sha256(texture)}
                files.append((texture, addon_dir / relative))
        replaced = {pack['id'] for pack in packs}
        old_textures, retained_textures = set(), set()
        for existing in manifest_dir.glob('*.json'):
            prior = json.loads(existing.read_text(encoding='utf-8'))
            if existing.stem in replaced:
                old_textures.update(record['texture'] for record in prior['emotes'])
                continue
            for record in prior['emotes']:
                retained_textures.add(record['texture'])
                changed = assets.get(record['id'])
                if changed and changed['texture_sha256'] != record['texture_sha256']:
                    raise ValueError(f'shared texture {record["id"]} also requires rebuilding {existing.stem}')
        manifests = []
        for pack in packs:
            records = [{**record, **assets[record['id']]} for record in
                       sorted(names_by_pack[pack['id']].values(), key=lambda item: (item['name'].casefold(), item['name']))]
            manifest = {**pack, 'schema': 1, 'generator': 'scripts/build-7tv-pack.py', 'emotes': records}
            lua_path = stage / (pack['id'] + '.lua')
            lua_path.write_text(render_lua(pack, records), encoding='utf-8')
            manifest_path = stage / (pack['id'] + '.json')
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
            files.extend([(lua_path, addon_dir / 'Packs' / lua_path.name), (manifest_path, manifest_dir / manifest_path.name)])
            manifests.append(manifest)
        retained_textures.update(record['texture'] for manifest in manifests for record in manifest['emotes'])
        for relative in sorted(old_textures - retained_textures):
            if not re.fullmatch(r'Media/(7tv|bttv|ffz|twitch)/[A-Za-z0-9][A-Za-z0-9_-]*\.(tga|blp)', relative):
                raise ValueError('unsafe obsolete texture path: ' + relative)
            obsolete = addon_dir / relative
            if obsolete.resolve() != addon_dir.resolve() / relative:
                raise ValueError('linked obsolete texture: ' + relative)
            if obsolete.exists():
                files.append((None, obsolete))
        publish_files(files, stage)
    return manifests


def validate_login(login):
    if not isinstance(login, str) or not re.fullmatch(r'[A-Za-z0-9_]{1,25}', login):
        raise ValueError('provide a valid Twitch login')
    return login.lower()


def resolve_twitch_id(login, twitch_id=None):
    if login is not None:
        login = validate_login(login)
    if not twitch_id:
        twitch_id = CHANNEL_IDS.get(login)
    if not twitch_id and login:
        twitch_id = http_get('https://decapi.me/twitch/id/' + login).decode('utf-8').strip()
    if not re.fullmatch(r'[0-9]{1,20}', str(twitch_id)):
        raise ValueError('Twitch user IDs must contain 1..20 digits')
    return str(twitch_id)


def fetch_channel(login, twitch_id, pack_id, title, priority):
    login = validate_login(login) if login else None
    twitch_id = resolve_twitch_id(login, twitch_id)
    url = 'https://7tv.io/v3/users/twitch/' + twitch_id
    data = get_json(url)
    actual_login = validate_login(data['username'])
    if (str(data['id']) != twitch_id or data['platform'] != 'TWITCH'
            or login and actual_login != login):
        raise ValueError('7TV connection identity does not match the requested Twitch channel')
    if not data.get('emote_set'):
        raise ValueError(f'7TV channel {actual_login} has no active emote set')
    title = title or data.get('display_name') or actual_login
    pack = normalize_7tv(data, pack_id, title, priority, url)
    pack.update(group=actual_login, groupTitle=validate_text(title),
                channel_login=actual_login, channel_id=twitch_id)
    return pack


def fetch_provider_channel(provider, login, title=None, twitch_id=None, priority=20):
    login = validate_login(login)
    twitch_id = resolve_twitch_id(login, twitch_id)
    title = title or login
    if provider == 'bttv':
        url = 'https://api.betterttv.net/3/cached/users/twitch/' + twitch_id
        return normalize_bttv_channel(get_json(url), login, title, twitch_id)
    if provider == 'ffz':
        url = 'https://api.frankerfacez.com/v1/room/id/' + twitch_id
        return normalize_ffz_channel(get_json(url), login, title, twitch_id)
    if provider == 'twitch':
        from twitch_sources import normalize_twitch
        url = 'https://twitchemotes.com/channels/' + twitch_id
        return normalize_twitch(http_get(url), twitch_id=twitch_id, login=login, title=title,
                                priority=priority, image_reader=http_get)
    raise ValueError('unsupported channel provider')


def fetch_native_catalogs(config_path, workers=6):
    from twitch_sources import normalize_twitch
    channels = json.loads(Path(config_path).read_text(encoding='utf-8'))['channels']
    if not 1 <= workers <= 16 or not 1 <= len(channels) <= 99:
        raise ValueError('native catalogs require 1..99 channels and 1..16 workers')
    global_pack = normalize_twitch(http_get('https://twitchemotes.com/'), image_reader=http_get)
    def fetch(channel):
        return fetch_provider_channel('twitch', channel['login'], channel['title'], channel['twitch_id'])
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        return [global_pack, *executor.map(fetch, channels)]


def fetch_global(provider):
    if provider == 'twitch-global':
        from twitch_sources import normalize_twitch
        return normalize_twitch(http_get('https://twitchemotes.com/'), image_reader=http_get)
    data = get_json(GLOBAL_APIS[provider])
    if provider == '7tv-global':
        return normalize_7tv(data, 'seventv_global', '7TV Global', 12, GLOBAL_APIS[provider])
    return normalize_bttv(data) if provider == 'bttv-global' else normalize_ffz(data)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--all', action='store_true', help='build every bundled provider and channel catalog')
    parser.add_argument('--provider', choices=('7tv', 'bttv', 'ffz', 'twitch', *GLOBAL_APIS, 'twitch-global'), default='7tv')
    parser.add_argument('--login')
    parser.add_argument('--twitch-id')
    parser.add_argument('--pack')
    parser.add_argument('--title')
    parser.add_argument('--priority', type=int, default=20)
    parser.add_argument('--addon-dir', type=Path, default=root / 'TwitchEmotes')
    parser.add_argument('--manifest-dir', type=Path, default=root / 'packs')
    parser.add_argument('--cache-dir', type=Path, default=root / '.cache' / '7tv')
    parser.add_argument('--max-frames', type=int, default=MAX_FRAMES)
    parser.add_argument('--workers', type=int, default=6)
    args = parser.parse_args()
    if args.all:
        packs = [fetch_global(provider) for provider in GLOBAL_APIS]
        packs += [fetch_channel(login, None, login, title, priority)
                  for login, title, priority in BUNDLED_7TV_CHANNELS]
        packs += [fetch_provider_channel(provider, login, title)
                  for provider, login, title in BUNDLED_FALLBACKS]
        packs += fetch_native_catalogs(root / 'scripts' / 'twitch-channels.json', args.workers)
    elif args.provider.endswith('-global'):
        packs = [fetch_global(args.provider)]
    elif args.provider != '7tv':
        if not args.login:
            parser.error('channel packs require --login')
        packs = [fetch_provider_channel(args.provider, args.login, args.title, args.twitch_id, args.priority)]
    else:
        if not args.pack or not (args.login or args.twitch_id):
            parser.error('7TV channel packs require --pack and --login or --twitch-id')
        packs = [fetch_channel(args.login, args.twitch_id, args.pack, args.title, args.priority)]
    print('Building ' + ', '.join(f'{pack["id"]}: {len(pack["emotes"])} emotes' for pack in packs), flush=True)
    manifests = build_packs(packs, args.addon_dir, args.manifest_dir, args.cache_dir,
                            args.max_frames, args.workers)
    for pack in manifests:
        print(f'{pack["id"]}: {len(pack["emotes"])} aliases, '
              f'{sum(emote["frames"] > 1 for emote in pack["emotes"])} animated; '
              f'{len(pack["excluded"])} catalog entries excluded')
    print(f'Published {len({emote["id"] for pack in manifests for emote in pack["emotes"]})} unique textures')


if __name__ == '__main__':
    try:
        main()
    except (KeyError, TypeError, ValueError, OSError) as error:
        print(f'Build failed; generated packs were not published: {error}', file=sys.stderr)
        sys.exit(1)
