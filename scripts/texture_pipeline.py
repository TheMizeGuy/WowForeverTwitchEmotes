# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Texture optimizer stages: temporal cleanup, resampling, palettization, layout, metrics, cache, allocation.

Every stage works on numpy RGBA arrays shaped (frames, height, width, 4) or (height, width, 4).
The worker entry point process_texture runs in a ProcessPoolExecutor, so it lives here rather
than in optimize-textures.py, whose hyphenated name spawned interpreters cannot import.
"""
import hashlib
import heapq
import io
import json
import math
import os
from pathlib import Path
import tempfile
import zipfile
import zlib

import numpy as np
from PIL import Image

from texture_formats import power_of_two, texture_dimensions, write_blp2

try:
    import imagequant
except ImportError:  # optimize-textures.py reports the missing package before importing this module
    imagequant = None
try:
    import deflate
except ImportError:
    deflate = None

PIPELINE_VERSION = 2
MAX_COLUMNS = 32
MAX_SHEET = 2048
MAX_CELL = 256
MAX_FRAMES = 256
MAX_HEIGHT = 128
SOURCE_HEIGHT = 64
ERROR_LIMIT = 5.0
MERGE_THRESHOLD = 3
DISPLAY_HEIGHT = 75
BACKGROUND = (18, 18, 22)
SSIM_FRAMES = 8
COMPRESSOR = 'libdeflate-12' if deflate else 'zlib-9'
GEOMETRY = ('width', 'height', 'frames', 'cellWidth', 'columns', 'sheetWidth', 'sheetHeight')


def compress(data):
    """The release compressor: libdeflate level 12 when installed, otherwise zlib level 9."""
    return deflate.zlib_compress(data, 12) if deflate else zlib.compress(data, 9)


def next_pow2(number):
    return 1 << max(0, (max(1, number) - 1).bit_length())


def read_rgba(data):
    with Image.open(io.BytesIO(data)) as image:
        return np.asarray(image.convert('RGBA'))


def tga_bytes(sheet):
    buffer = io.BytesIO()
    Image.fromarray(sheet, 'RGBA').save(buffer, format='TGA')
    return buffer.getvalue()


def cut_frames(sheet, count, columns, cell, height, width):
    out = np.empty((count, height, width, 4), np.uint8)
    for i in range(count):
        y, x = (i // columns) * height, (i % columns) * cell
        out[i] = sheet[y:y + height, x:x + width]
    return out


def build_sheet(frames, columns, cell, size):
    width, height = size
    sheet = np.zeros((height, width, 4), np.uint8)
    frame_height, frame_width = frames.shape[1:3]
    for i in range(len(frames)):
        y, x = (i // columns) * frame_height, (i % columns) * cell
        sheet[y:y + frame_height, x:x + frame_width] = frames[i]
    return sheet


def layout(count, cell, height):
    """Widest legal grid: the most columns, then the smallest power-of-two sheet that holds the rows."""
    if not 1 <= count <= MAX_FRAMES or not power_of_two(cell) or cell > MAX_CELL or not 1 <= height <= MAX_HEIGHT:
        raise ValueError('frame grid exceeds the runtime limits')
    columns = min(count, MAX_COLUMNS, MAX_SHEET // cell)
    sheet_width, sheet_height = next_pow2(columns * cell), next_pow2(math.ceil(count / columns) * height)
    if sheet_height > MAX_SHEET:
        raise ValueError('animation does not fit the texture grid limits')
    return columns, sheet_width, sheet_height


# ---------------------------------------------------------------- temporal ----
def alpha_snap(alpha, low=5, high=250):
    out = alpha.copy()
    out[alpha <= low] = 0
    out[alpha >= high] = 255
    return out


def stabilize(frames, hold):
    """Hold each pixel channel at its previous output while the source stays within +-hold of it.

    Two passes so the state entering frame 0 is the wrapped state from the end of the loop.
    Alpha is held the same way, except source alpha 0 and 255 stay exact.
    """
    if hold <= 0 or len(frames) < 2:
        return frames.copy()
    source = frames.astype(np.int16)
    out = np.empty_like(source)
    held = source[0].copy()
    for _ in range(2):
        for i in range(len(source)):
            current = source[i]
            value = np.where(np.abs(current - held) <= hold, held, current)
            alpha = current[:, :, 3]
            value[:, :, 3] = np.where((alpha == 0) | (alpha == 255), alpha, value[:, :, 3])
            held = value
            out[i] = value
    return out.astype(np.uint8)


def source_force(original, stabilized):
    """Identical source frames get identical output: the hold is order dependent, so copy the first member."""
    out = stabilized.copy()
    first = {}
    for i in range(len(original)):
        j = first.setdefault(original[i].tobytes(), i)
        if j != i:
            out[i] = stabilized[j]
    return out


def dedup_exact(frames):
    """Return (unique frames, playback sequence) keeping the first occurrence of each frame."""
    seen, keep, sequence = {}, [], []
    for i in range(len(frames)):
        j = seen.setdefault(frames[i].tobytes(), len(keep))
        if j == len(keep):
            keep.append(i)
        sequence.append(j)
    return frames[keep], sequence


def dedup_near(frames, maxabs, rms):
    """Greedy merge: a frame joins the first unique frame within maxabs per channel and under rms overall."""
    keep, sequence, exact = [], [], {}
    means = frames.reshape(len(frames), -1).astype(np.float32).mean(axis=1)
    for i in range(len(frames)):
        key = frames[i].tobytes()
        j = exact.get(key)
        if j is None:
            frame = frames[i].astype(np.int16)
            for k, index in enumerate(keep):
                if abs(means[i] - means[index]) > maxabs:
                    continue
                delta = np.abs(frame - frames[index].astype(np.int16))
                if delta.max() <= maxabs and math.sqrt(float((delta.astype(np.float32) ** 2).mean())) < rms:
                    j = k
                    break
            if j is None:
                j = len(keep)
                keep.append(i)
            exact[key] = j
        sequence.append(j)
    return frames[keep], sequence


def prepare_animation(frames, hold, near):
    """Alpha snap, stabilise with source forcing, then exact and near dedup into (unique frames, sequence)."""
    frames = frames.copy()
    frames[:, :, :, 3] = alpha_snap(frames[:, :, :, 3])
    stabilized = source_force(frames, stabilize(frames, hold)) if hold else frames
    unique, sequence = dedup_exact(stabilized)
    if near:
        unique, merged = dedup_near(unique, *near)
        sequence = [merged[j] for j in sequence]
    if len(unique) == 1 or sequence == list(range(len(unique))):
        sequence = None
    return unique, sequence


# --------------------------------------------------------------- resampling ---
def resample(frames, height):
    """Premultiplied Lanczos resample to `height`, aspect preserved. Returns (frames, width)."""
    source_height, width = frames.shape[1:3]
    if height == source_height:
        return frames, width
    new_width = max(1, round(width * height / source_height))
    out = np.empty((len(frames), height, new_width, 4), np.uint8)
    for i in range(len(frames)):
        values = frames[i].astype(np.float64)
        alpha = values[:, :, 3:4] / 255.0
        premultiplied = np.concatenate([values[:, :, :3] * alpha, values[:, :, 3:4]], axis=2)
        image = Image.fromarray(np.clip(premultiplied + 0.5, 0, 255).astype(np.uint8), 'RGBA')
        small = np.asarray(image.resize((new_width, height), Image.Resampling.LANCZOS), dtype=np.float64)
        rgb = np.clip(small[:, :, :3] / (np.maximum(small[:, :, 3:4], 1e-6) / 255.0) + 0.5, 0, 255)
        out[i] = np.concatenate([rgb, small[:, :, 3:4]], axis=2).astype(np.uint8)
    return out, new_width


# ------------------------------------------------------------- palettization --
def quantize(sheet):
    """libimagequant palette and index plane; alpha is binarised so palette slots buy only RGB."""
    height, width = sheet.shape[:2]
    flat = np.dstack([sheet[:, :, :3], np.where(sheet[:, :, 3] > 0, 255, 0).astype(np.uint8)])
    indices, palette = imagequant.quantize_raw_rgba_bytes(flat.tobytes(), width, height,
                                                          dithering_level=0.0, max_colors=256)
    palette = np.array(palette, np.uint8).reshape(-1, 4)[:, :3]
    return np.frombuffer(indices, np.uint8).reshape(height, width).copy(), palette


def merge_budget(alpha, threshold):
    scale = np.maximum(alpha.astype(np.float32), 1.0) / 255.0
    return (threshold / scale) ** 2 * 3.0


def merge_runs(indices, rgb, alpha, palette, threshold, cell=None):
    """Re-point a pixel at its left neighbour's (or the previous cell's) palette entry when that costs
    under `threshold` of composited error: longer literal runs and LZ matches for the same look."""
    indices = indices.copy()
    colors, values = palette.astype(np.int32), rgb.astype(np.int32)
    budget = merge_budget(alpha, threshold)
    current = ((values - colors[indices]) ** 2).sum(2).astype(np.float32)
    for x in range(1, indices.shape[1]):
        candidate = indices[:, x - 1]
        distance = ((values[:, x] - colors[candidate]) ** 2).sum(1).astype(np.float32)
        take = (distance <= np.maximum(budget[:, x], current[:, x])) & (candidate != indices[:, x])
        if cell is not None and x >= cell:
            previous = indices[:, x - cell]
            distance2 = ((values[:, x] - colors[previous]) ** 2).sum(1).astype(np.float32)
            take2 = ~take & (distance2 <= np.maximum(budget[:, x], current[:, x])) & (previous != indices[:, x])
            indices[take2, x] = previous[take2]
            current[take2, x] = distance2[take2]
        indices[take, x] = candidate[take]
        current[take, x] = distance[take]
    return indices


def merge_rows(indices, rgb, alpha, palette, threshold):
    """Second pass down the rows: adopt the pixel above when it is cheap, since whole-row matches pay most."""
    indices = indices.copy()
    colors, values = palette.astype(np.int32), rgb.astype(np.int32)
    budget = merge_budget(alpha, threshold)
    current = ((values - colors[indices]) ** 2).sum(2).astype(np.float32)
    for y in range(1, indices.shape[0]):
        candidate = indices[y - 1]
        distance = ((values[y] - colors[candidate]) ** 2).sum(1).astype(np.float32)
        take = (distance <= np.maximum(budget[y], current[y])) & (candidate != indices[y])
        indices[y, take] = candidate[take]
        current[y, take] = distance[take]
    return indices


def visible_rms(rgb, alpha, rgb2, alpha2):
    """RGB RMS over the first image's visible pixels, worst of black and white backgrounds."""
    visible = alpha > 0
    if not visible.any():
        return 0.0
    first, second = rgb[visible].astype(np.float32), rgb2[visible].astype(np.float32)
    weight, weight2 = (alpha[visible].astype(np.float32) / 255.0)[:, None], (alpha2[visible].astype(np.float32) / 255.0)[:, None]
    error = 0.0
    for background in (0.0, 255.0):
        delta = (first * weight + background * (1 - weight)) - (second * weight2 + background * (1 - weight2))
        error = max(error, math.sqrt(float((delta * delta).mean())))
    return error


def palettize(sheet, cell=None, threshold=MERGE_THRESHOLD):
    """Palettize a sheet with exact alpha. Returns (BLP2 bytes, visible RMS error, decoded RGBA sheet)."""
    rgb, alpha = sheet[:, :, :3], sheet[:, :, 3]
    indices, palette = quantize(sheet)
    indices = merge_rows(merge_runs(indices, rgb, alpha, palette, threshold, cell), rgb, alpha, palette, threshold)
    height, width = alpha.shape
    data = write_blp2((width, height), [tuple(int(v) for v in color) for color in palette], indices.tobytes(), alpha.tobytes())
    decoded = np.dstack([palette[indices], alpha]).astype(np.uint8)
    return data, visible_rms(rgb, alpha, palette[indices], alpha), decoded


def encode_sheet(sheet, cell=None, threshold=MERGE_THRESHOLD):
    """Palettize a sheet with exact alpha. Returns (BLP2 bytes, visible RMS error)."""
    return palettize(sheet, cell, threshold)[:2]


def rung_tag(height, threshold):
    return f'{height}t{threshold}'


def parse_tag(tag):
    """A candidate tag is '<height>t<merge threshold>'; a bare height means the default threshold."""
    height, _, threshold = tag.partition('t')
    return int(height), int(threshold) if threshold else MERGE_THRESHOLD


# ------------------------------------------------------------------ SSIM ------
def gaussian_filter(values):
    kernel = np.exp(-((np.arange(11) - 5) ** 2) / (2 * 1.5 ** 2))
    kernel /= kernel.sum()
    for axis in (0, 1):
        pad = min(5, values.shape[axis] - 1)
        widths = [(0, 0), (0, 0)]
        widths[axis] = (pad, pad)
        padded = np.pad(values, widths, mode='reflect')
        if pad < 5:
            widths[axis] = (5 - pad, 5 - pad)
            padded = np.pad(padded, widths, mode='edge')
        out = np.zeros_like(values)
        for i, weight in enumerate(kernel):
            out += weight * (padded[i:i + values.shape[0]] if axis == 0 else padded[:, i:i + values.shape[1]])
        values = out
    return values


def ssim(first, second, limit=255.0):
    """Windowed SSIM (Wang 2004), 11 x 11 gaussian sigma 1.5, reflect padded."""
    c1, c2 = (0.01 * limit) ** 2, (0.03 * limit) ** 2
    mu1, mu2 = gaussian_filter(first), gaussian_filter(second)
    s11 = gaussian_filter(first * first) - mu1 * mu1
    s22 = gaussian_filter(second * second) - mu2 * mu2
    s12 = gaussian_filter(first * second) - mu1 * mu2
    return float(np.mean(((2 * mu1 * mu2 + c1) * (2 * s12 + c2)) / ((mu1 * mu1 + mu2 * mu2 + c1) * (s11 + s22 + c2))))


def display_luma(frame, size):
    """Luma of the frame as the client shows it: bilinear to the display size over the chat background."""
    values = np.asarray(Image.fromarray(frame, 'RGBA').resize(size, Image.Resampling.BILINEAR), dtype=np.float64)
    alpha = values[:, :, 3:4] / 255.0
    rgb = values[:, :, :3] * alpha + np.array(BACKGROUND, np.float64) * (1 - alpha)
    return rgb[:, :, 0] * 0.299 + rgb[:, :, 1] * 0.587 + rgb[:, :, 2] * 0.114


def frame_selection(count, limit=SSIM_FRAMES):
    picks = min(limit, count)
    return [round(i * (count - 1) / max(1, picks - 1)) for i in range(picks)]


def ssim_score(reference, candidate):
    """Mean SSIM between matching frames at 1440p and 40 UI units, the harshest common chat size."""
    height, width = reference.shape[1:3]
    size = (max(1, round(DISPLAY_HEIGHT * width / height)), DISPLAY_HEIGHT)
    return sum(ssim(display_luma(a, size), display_luma(b, size)) for a, b in zip(reference, candidate)) / len(reference)


# ------------------------------------------------------------- candidates -----
def encode_rung(unique, height, threshold=MERGE_THRESHOLD):
    """One rung of an animation: resample, lay out, palettize with a merge threshold; TGA when the palette misses the limit.

    The SSIM scores what the client will draw (the decoded sheet), so palette and merge loss count like resampling loss.
    """
    frames, width = resample(unique, height)
    cell = min(MAX_CELL, next_pow2(width))
    columns, sheet_width, sheet_height = layout(len(frames), cell, height)
    sheet = build_sheet(frames, columns, cell, (sheet_width, sheet_height))
    data, error, decoded = palettize(sheet, cell, threshold)
    suffix = '.blp'
    if error > ERROR_LIMIT:
        data, suffix, decoded = tga_bytes(sheet), '.tga', sheet
    selection = frame_selection(len(unique))
    shown = cut_frames(decoded, len(frames), columns, cell, height, width)
    score = ssim_score(unique[selection], shown[selection])
    meta = dict(width=int(width), height=int(height), frames=len(frames), cellWidth=int(cell), columns=int(columns),
                sheetWidth=int(sheet_width), sheetHeight=int(sheet_height), suffix=suffix, error=float(error),
                ssim=float(score), merge=int(threshold))
    return meta, data, None


def encode_static(sheet, original, geometry):
    """A static: alpha snap and palettize; keep the original TGA unless the BLP is within the limit and smaller."""
    snapped = sheet.copy()
    snapped[:, :, 3] = alpha_snap(snapped[:, :, 3])
    data, error = encode_sheet(snapped)
    compressed, original_compressed = compress(data), compress(original)
    meta = {key: geometry[key] for key in GEOMETRY}
    if error <= ERROR_LIMIT and len(compressed) < len(original_compressed):
        return dict(meta, suffix='.blp', error=float(error), ssim=1.0), data, compressed
    return dict(meta, suffix='.tga', error=0.0, ssim=1.0), original, original_compressed


# ------------------------------------------------------------------ cache -----
def cache_key(lossless, params):
    return hashlib.sha256(json.dumps([lossless, params], sort_keys=True).encode('utf-8')).hexdigest()[:40]


def cache_paths(cache, key, tag):
    base = Path(cache) / key[:2] / (key + '-' + tag)
    return base.with_suffix('.json'), base.with_suffix('.z')


def cache_read(cache, key, tag):
    meta_path, data_path = cache_paths(cache, key, tag)
    if not meta_path.is_file() or not data_path.is_file():
        return None
    return json.loads(meta_path.read_text(encoding='utf-8'))


def cache_write(cache, key, tag, meta, data, compressed=None):
    meta_path, data_path = cache_paths(cache, key, tag)
    compressed = compressed if compressed is not None else compress(data)
    meta = dict(meta, tag=tag, size=len(compressed), sha256=hashlib.sha256(data).hexdigest())
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    for path, payload in ((data_path, compressed), (meta_path, json.dumps(meta, sort_keys=True).encode('utf-8'))):
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as pending:
            pending.write(payload)
        os.replace(pending.name, path)
    return meta


def cache_data(cache, key, tag):
    meta_path, data_path = cache_paths(cache, key, tag)
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    data = zlib.decompress(data_path.read_bytes())
    if hashlib.sha256(data).hexdigest() != meta['sha256']:
        raise ValueError('cache entry is corrupt: ' + str(data_path))
    return data


def cached_size(cache, data):
    """Compressed size of arbitrary bytes, remembered by content hash."""
    digest = hashlib.sha256(data).hexdigest()
    path = Path(cache) / 'sizes' / digest[:2] / digest
    if path.is_file():
        return int(path.read_text())
    size = len(compress(data))
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False, mode='w') as pending:
        pending.write(str(size))
    os.replace(pending.name, path)
    return size


# ----------------------------------------------------------------- worker -----
_archives = {}


def iter_sources(source, addon, tga):
    """Yield candidate lossless bytes: the --source zip or Media directory, then the addon's own TGA."""
    if source:
        kind, path = source
        if kind == 'zip':
            archive = _archives.get(path)
            if archive is None:
                archive = _archives[path] = zipfile.ZipFile(path)
            try:
                yield archive.read('TwitchEmotes/' + tga)
            except KeyError:
                pass
        else:
            file = Path(path) / Path(tga).relative_to('Media')
            if file.is_file():
                yield file.read_bytes()
    file = Path(addon) / tga
    if file.is_file():
        yield file.read_bytes()


def load_source(job, lossless):
    """Return (bytes, sha256) of the texture's lossless 64 px TGA sheet."""
    tga = Path(job['texture']).with_suffix('.tga').as_posix()
    expected = lossless.get('sha256')
    for data in iter_sources(job['source'], job['addon'], tga):
        digest = hashlib.sha256(data).hexdigest()
        if expected and digest != expected:
            continue
        if texture_dimensions(data, '.tga') != (lossless['sheetWidth'], lossless['sheetHeight']):
            raise ValueError('lossless source dimensions differ: ' + tga)
        return data, digest
    raise ValueError('lossless source not found: ' + tga + (' (sha256 ' + expected + ')' if expected else ''))


def process_texture(job):
    """Worker entry: every candidate of one texture through the cache, plus the shipped file's size."""
    cache, params, tags = job['cache'], job['params'], job['tags']
    shipped = (Path(job['addon']) / job['texture']).read_bytes()
    if hashlib.sha256(shipped).hexdigest() != job['texture_sha256']:
        raise ValueError('texture hash differs: ' + job['texture'])
    lossless = dict(job['lossless'])
    key = cache_key(lossless, params) if lossless.get('sha256') else None
    cached = {tag: cache_read(cache, key, tag) for tag in tags} if key else {}
    if not key or any(cached[tag] is None for tag in tags):
        data, lossless['sha256'] = load_source(job, lossless)
        key = cache_key(lossless, params)
        cached = {tag: cache_read(cache, key, tag) for tag in tags}
        missing = [tag for tag in tags if cached[tag] is None]
        if missing:
            sheet = read_rgba(data)
            if job['animated']:
                frames = cut_frames(sheet, lossless['frames'], lossless['columns'], lossless['cellWidth'],
                                    lossless['height'], lossless['width'])
                unique, sequence = prepare_animation(frames, params['hold'], params['near'] and tuple(params['near']))
                for tag in missing:
                    meta, encoded, compressed = encode_rung(unique, *parse_tag(tag))
                    cached[tag] = cache_write(cache, key, tag, dict(meta, sequence=sequence), encoded, compressed)
            else:
                meta, encoded, compressed = encode_static(sheet, data, lossless)
                cached['static'] = cache_write(cache, key, 'static', dict(meta, sequence=None), encoded, compressed)
    return dict(texture=job['texture'], key=key, lossless=lossless, old_size=cached_size(cache, shipped),
                candidates=[cached[tag] for tag in tags])


# ------------------------------------------------------------- allocation -----
def next_step(candidates, index, floor=0.0):
    """The smaller rung with the least SSIM loss per byte saved (ties to the larger saving), or None.

    Any candidate order works: every smaller rung above `floor` competes, not only the next in the list.
    """
    current, best = candidates[index], None
    for j, candidate in enumerate(candidates):
        saved = current['size'] - candidate['size']
        if saved > 0 and candidate['ssim'] >= floor:
            cost = ((current['ssim'] - candidate['ssim']) / saved, -saved)
            if best is None or cost < best[0]:
                best = (cost, j)
    return (best[0][0], best[1]) if best else None


def allocate(rungs, budget, fixed=0, floor=0.0):
    """Start every animation at its first rung; while over budget step down the cheapest SSIM loss per byte.

    A rung whose SSIM falls under `floor` is never chosen, so the worst emote stays above it even when
    that leaves the budget unmet.
    """
    chosen = {texture: 0 for texture in rungs}
    total = fixed + sum(candidates[0]['size'] for candidates in rungs.values())
    if budget <= 0:
        return chosen, total
    heap = []
    for texture in sorted(rungs):
        step = next_step(rungs[texture], 0, floor)
        if step:
            heapq.heappush(heap, (step[0], texture, step[1]))
    while total > budget and heap:
        _, texture, index = heapq.heappop(heap)
        total -= rungs[texture][chosen[texture]]['size'] - rungs[texture][index]['size']
        chosen[texture] = index
        step = next_step(rungs[texture], index, floor)
        if step:
            heapq.heappush(heap, (step[0], texture, step[1]))
    return chosen, total
