# Copyright (c) 2026 TheMizeGuy. All rights reserved.
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import struct
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import texture_formats
import texture_pipeline as pipeline

spec = importlib.util.spec_from_file_location('optimizer', SCRIPTS / 'optimize-textures.py')
optimizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(optimizer)
HEIGHTS = (64, 48, 32)


def decode_palette(data):
    width, height = struct.unpack_from('<II', data, 12)
    pixels = width * height
    offset = struct.unpack_from('<I', data, 20)[0]
    rgba = bytearray()
    for i, index in enumerate(data[offset:offset + pixels]):
        blue, green, red, _ = data[148 + index * 4:152 + index * 4]
        rgba.extend((red, green, blue, data[offset + pixels + i]))
    return Image.frombytes('RGBA', (width, height), bytes(rgba))


def shape_frame(shift=0, tint=0, rng=None):
    """A 64 x 64 flat-shaded disc with a soft edge on transparent; rng adds pixel noise instead."""
    frame = np.zeros((64, 64, 4), np.uint8)
    if rng is not None:
        frame[:] = rng.integers(0, 256, (64, 64, 4), dtype=np.uint8)
        frame[:, :, 3] = 255
        return frame
    y, x = np.mgrid[0:64, 0:64]
    distance = np.sqrt((x - 32 - shift) ** 2 + (y - 32) ** 2)
    frame[distance <= 24] = (200 + tint, 40 + tint, 60, 255)
    frame[(distance > 24) & (distance <= 26)] = (200 + tint, 40 + tint, 60, 128)
    frame[(abs(x - 32 - shift) <= 8) & (abs(y - 32) <= 8)] = (30, 30, 220 + tint, 255)
    return frame


def soft_frame(shift=0, seed=1):
    """A 64 px frame downscaled from a 128 px smooth-noise disc with a square, so its edges are anti-aliased."""
    rng = np.random.default_rng(seed)
    field = pipeline.gaussian_filter(rng.random((128, 128)))
    field = (field - field.min()) / (field.max() - field.min())
    frame = np.zeros((128, 128, 4), np.uint8)
    y, x = np.mgrid[0:128, 0:128]
    disc = np.sqrt((x - 64 - shift * 2) ** 2 + (y - 64) ** 2) <= 50
    rolled = np.roll(field, shift * 2, axis=1)
    for channel, (low, high) in enumerate(((40, 220), (160, 30), (60, 90))):
        frame[disc, channel] = np.round(low + (high - low) * rolled[disc]).astype(np.uint8)
    frame[disc, 3] = 255
    frame[(abs(x - 64 - shift * 2) <= 16) & (abs(y - 64) <= 16)] = (30, 30, 220, 255)
    return pipeline.resample(frame[None], 64)[0][0]


def visible_difference(played, expected):
    """(max abs, RMS) of the RGB difference over the expected frame's visible pixels."""
    visible = expected[:, :, 3] > 0
    delta = played[visible][:, :3].astype(int) - expected[visible][:, :3].astype(int)
    return int(np.abs(delta).max()), float(np.sqrt((delta ** 2).mean()))


def sheet_of(frames, columns=2):
    """Lay frames in a 64 px grid like build-7tv-pack.py: columns * 64 wide, power-of-two tall."""
    rows = -(-len(frames) // columns)
    sheet = np.zeros((pipeline.next_pow2(rows * 64), columns * 64, 4), np.uint8)
    for i, frame in enumerate(frames):
        sheet[(i // columns) * 64:(i // columns + 1) * 64, (i % columns) * 64:(i % columns + 1) * 64] = frame
    return sheet


def fixture(root, animation=None, static=None):
    """Two packs sharing one animation plus one static in the first pack; lossless sources kept in root/source."""
    addon = root / 'TwitchEmotes'
    for directory in (addon / 'Media/7tv', addon / 'Packs', root / 'packs', root / 'source/7tv'):
        directory.mkdir(parents=True, exist_ok=True)
    if animation is None:
        animation = [soft_frame(), soft_frame(shift=6), soft_frame(), soft_frame(shift=14)]
    if static is None:
        rng = random.Random(3)
        colors = [(rng.randrange(256), rng.randrange(256), rng.randrange(256), 255) for _ in range(200)]
        static = np.array([rng.choice(colors) for _ in range(64 * 64)], np.uint8).reshape(64, 64, 4)
    textures = {}
    for name, sheet in (('animation', sheet_of(animation)), ('static', sheet_of([static], 1))):
        for path in (addon / 'Media/7tv' / (name + '.tga'), root / 'source/7tv' / (name + '.tga')):
            Image.fromarray(sheet, 'RGBA').save(path, compression='tga_rle')
        textures[name] = hashlib.sha256((addon / 'Media/7tv' / (name + '.tga')).read_bytes()).hexdigest()
    moving = dict(name='first', id='7tv:animation', texture='Media/7tv/animation.tga', texture_sha256=textures['animation'],
                  source_sha256='original', width=64, height=64, frames=4, fps=10, cellWidth=64, columns=2,
                  sheetWidth=128, sheetHeight=128, creator='Artist', source='https://7tv.app/emotes/animation')
    still = dict(moving, name='still', id='7tv:static', texture='Media/7tv/static.tga', texture_sha256=textures['static'],
                 frames=1, fps=0, columns=1, sheetWidth=64, sheetHeight=64)
    packs = []
    for pack_id, emotes in (('first', [moving, dict(moving, name='alias'), still]), ('second', [dict(moving, name='third')])):
        pack = dict(id=pack_id, title=pack_id, provider='7TV', priority=20, group=pack_id, groupTitle=pack_id,
                    source='https://7tv.app/', emotes=emotes)
        (root / 'packs' / (pack_id + '.json')).write_text(json.dumps(pack))
        (addon / 'Packs' / (pack_id + '.lua')).write_text(optimizer.builder['render_lua'](pack, pack['emotes']))
        packs.append(pack)
    return packs, animation, static


def snapshot(root):
    return {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file() and 'source' not in p.parts}


def run(root, **options):
    settings = dict(source=root / 'source', budget=0, heights=HEIGHTS, workers=1, cache=root.parent / 'cache')
    settings.update(options)
    return optimizer.optimize(root, **settings)


class TextureFormatTests(unittest.TestCase):
    def test_indexed_format_preserves_alpha_colors_orientation_and_frame_boundaries(self):
        image = Image.new('RGBA', (64, 128))
        image.putdata([(255 if y < 64 else 0, 80, 0 if y < 64 else 255, x * 4)
                       for y in range(128) for x in range(64)])
        data, error = texture_formats.encode_indexed(image)
        self.assertEqual(texture_formats.texture_dimensions(data, '.blp'), (64, 128))
        self.assertEqual(decode_palette(data).tobytes(), image.tobytes())
        self.assertEqual(texture_formats.decode_blp2(data).tobytes(), image.tobytes())
        self.assertEqual(error, 0)
        self.assertEqual(data[:12], b'BLP2\x01\x00\x00\x00\x01\x08\x08\x00')

    def test_blp_validation_rejects_corruption_in_mips_payload_and_dimensions(self):
        data, _ = texture_formats.encode_indexed(Image.new('RGBA', (64, 64), 'red'))
        for offset, value in [(0, 0), (4, 2), (8, 2), (9, 4), (10, 0), (11, 1),
                              (12, 63), (20, 0), (24, 1), (85, 0), (88, 1)]:
            corrupted = bytearray(data)
            corrupted[offset] = value
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                texture_formats.texture_dimensions(corrupted, '.blp')
        for corrupt in (data[:18], data[:-1], data + b'junk'):
            with self.assertRaises(ValueError):
                texture_formats.texture_dimensions(corrupt, '.blp')

    def test_quality_error_excludes_empty_padding(self):
        rng = random.Random(12)
        image = Image.new('RGBA', (64, 64))
        image.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256), 255)
                       for _ in range(4096)])
        _, direct_error = texture_formats.encode_indexed(image)
        padded = Image.new('RGBA', (128, 128))
        padded.paste(image, (0, 0))
        _, padded_error = texture_formats.encode_indexed(padded)
        self.assertGreater(direct_error, 5)
        self.assertGreater(padded_error, 5)

    def test_blp2_writer_rejects_mismatched_planes_and_missing_palette_entries(self):
        with self.assertRaises(ValueError):
            texture_formats.write_blp2((64, 64), [(0, 0, 0)], bytes(64 * 64), bytes(64 * 63))
        with self.assertRaises(ValueError):
            texture_formats.write_blp2((64, 64), [(0, 0, 0)], bytes([1]) * 4096, bytes(4096))
        with self.assertRaises(ValueError):
            texture_formats.write_blp2((96, 64), [(0, 0, 0)], bytes(96 * 64), bytes(96 * 64))


class PipelineTests(unittest.TestCase):
    def test_alpha_snap_clears_faint_and_saturates_near_opaque(self):
        alpha = np.array([0, 5, 6, 128, 249, 250, 255], np.uint8)
        self.assertEqual(pipeline.alpha_snap(alpha).tolist(), [0, 0, 6, 128, 249, 255, 255])

    def test_stabilize_holds_jitter_and_keeps_real_motion_and_exact_alpha(self):
        frames = np.zeros((6, 2, 2, 4), np.uint8)
        frames[:, 0, 0, 0] = [100, 101, 99, 102, 100, 98]
        frames[:, 0, 1, 0] = [100, 110, 120, 130, 140, 150]
        frames[:, 1, 0, 3] = [200, 203, 197, 200, 202, 199]
        frames[:, 1, 1, 3] = [255, 254, 0, 0, 255, 253]
        held = pipeline.stabilize(frames, 3)
        self.assertEqual(held[:, 0, 0, 0].tolist(), [100] * 6)
        self.assertEqual(held[:, 0, 1, 0].tolist(), [100, 110, 120, 130, 140, 150])
        self.assertEqual(held[:, 1, 0, 3].tolist(), [200] * 6)
        self.assertEqual(held[:, 1, 1, 3].tolist(), [255, 255, 0, 0, 255, 255])
        self.assertEqual(pipeline.stabilize(frames, 0).tolist(), frames.tolist())

    def test_stabilize_second_pass_makes_the_loop_seam_consistent(self):
        frames = np.zeros((4, 1, 1, 4), np.uint8)
        frames[:, 0, 0, 0] = [100, 103, 106, 103]
        held = pipeline.stabilize(frames, 3)
        self.assertEqual(held[:, 0, 0, 0].tolist(), [100, 100, 106, 106])
        forced = pipeline.source_force(frames, held)
        self.assertEqual(forced[:, 0, 0, 0].tolist(), [100, 100, 106, 100])

    def test_dedup_exact_then_near_build_the_playback_sequence(self):
        base, other, far = shape_frame(), shape_frame(shift=6), shape_frame(shift=14)
        near = base.copy()
        near[20:30, 20:30, 0] += 2
        unique, sequence = pipeline.dedup_exact(np.stack([base, other, base, near, other]))
        self.assertEqual(sequence, [0, 1, 0, 2, 1])
        self.assertEqual(len(unique), 3)
        unique, sequence = pipeline.dedup_near(np.stack([base, other, base, near, other, far]), 3, 1.0)
        self.assertEqual(sequence, [0, 1, 0, 0, 1, 2])
        self.assertEqual(unique[0].tolist(), base.tolist())
        self.assertEqual(unique[2].tolist(), far.tolist())
        unique, sequence = pipeline.dedup_near(np.stack([base, near]), 1, 1.0)
        self.assertEqual(sequence, [0, 1])

    def test_prepare_animation_drops_identity_sequences(self):
        distinct = np.stack([shape_frame(), shape_frame(shift=6), shape_frame(shift=14)])
        unique, sequence = pipeline.prepare_animation(distinct, 3, (3, 1.0))
        self.assertIsNone(sequence)
        self.assertEqual(len(unique), 3)
        unique, sequence = pipeline.prepare_animation(np.stack([shape_frame(), shape_frame(shift=6), shape_frame(tint=2)]), 3, (3, 1.0))
        self.assertEqual(sequence, [0, 1, 0])
        self.assertEqual(len(unique), 2)
        unique, sequence = pipeline.prepare_animation(np.stack([shape_frame(), shape_frame(shift=6), shape_frame(tint=2)]), 0, None)
        self.assertIsNone(sequence)
        self.assertEqual(len(unique), 3)
        unique, sequence = pipeline.prepare_animation(np.stack([shape_frame(), shape_frame(tint=2), shape_frame()]), 3, (3, 1.0))
        self.assertIsNone(sequence)
        self.assertEqual(len(unique), 1)

    def test_layout_uses_the_widest_legal_grid_on_power_of_two_sheets(self):
        self.assertEqual(pipeline.layout(60, 64, 64), (32, 2048, 128))
        self.assertEqual(pipeline.layout(9, 256, 64), (8, 2048, 128))
        self.assertEqual(pipeline.layout(256, 256, 64), (8, 2048, 2048))
        self.assertEqual(pipeline.layout(3, 64, 32), (3, 256, 32))
        self.assertEqual(pipeline.layout(1, 128, 64), (1, 128, 64))
        self.assertEqual(pipeline.layout(256, 1, 64), (32, 32, 512))
        for count, cell, height in ((0, 64, 64), (257, 64, 64), (4, 512, 64), (4, 96, 64), (256, 256, 128)):
            with self.subTest(count=count, cell=cell, height=height), self.assertRaises(ValueError):
                pipeline.layout(count, cell, height)

    def test_encode_rung_caps_cells_at_256_and_keeps_visible_width_left_aligned(self):
        wide = np.zeros((2, 64, 256, 4), np.uint8)
        wide[:, :, :200] = (10, 200, 30, 255)
        wide[1, :, :100] = (200, 10, 30, 255)
        wide[:, :, :, 3] = 255
        meta, data, _ = pipeline.encode_rung(wide, 64)
        self.assertEqual((meta['width'], meta['cellWidth'], meta['columns'], meta['sheetWidth'], meta['sheetHeight']), (256, 256, 2, 512, 64))
        meta, data, _ = pipeline.encode_rung(wide, 32)
        self.assertEqual((meta['width'], meta['height'], meta['cellWidth'], meta['sheetWidth'], meta['sheetHeight']), (128, 32, 128, 256, 32))
        decoded = np.asarray(texture_formats.decode_blp2(data))
        self.assertTrue((decoded[:, :, 3] == 255).all())
        self.assertGreater(decoded[:, 130:176, 0].mean(), 150)
        self.assertGreater(decoded[:, 182:226, 1].mean(), 150)
        self.assertLess(decoded[:, 232:, :3].mean(), 30)

    def test_blp2_round_trip_keeps_exact_alpha_and_flat_colors(self):
        frames = np.stack([shape_frame(), shape_frame(shift=6)])
        frames[0, 10:20, 10:20, 3] = np.arange(100, dtype=np.uint8).reshape(10, 10) + 100
        meta, data, _ = pipeline.encode_rung(frames, 64)
        self.assertEqual(meta['suffix'], '.blp')
        decoded = np.asarray(texture_formats.decode_blp2(data))
        expected = pipeline.build_sheet(frames, meta['columns'], meta['cellWidth'], (meta['sheetWidth'], meta['sheetHeight']))
        self.assertEqual(decoded[:, :, 3].tolist(), expected[:, :, 3].tolist())
        visible = expected[:, :, 3] > 0
        self.assertEqual(decoded[visible][:, :3].tolist(), expected[visible][:, :3].tolist())
        self.assertEqual(meta['error'], 0.0)
        self.assertEqual(meta['ssim'], 1.0)

    def test_visible_rms_matches_the_black_and_white_background_metric(self):
        rng = np.random.default_rng(5)
        rgba = rng.integers(0, 256, (32, 32, 4), dtype=np.uint8)
        rgba[:8, :, 3] = 0
        other = rgba.copy()
        other[:, :, :3] = np.clip(other[:, :, :3].astype(np.int16) + rng.integers(-12, 13, (32, 32, 3)), 0, 255).astype(np.uint8)
        error = pipeline.visible_rms(rgba[:, :, :3], rgba[:, :, 3], other[:, :, :3], other[:, :, 3])
        reference = texture_formats.visible_error(Image.fromarray(rgba, 'RGBA'), Image.fromarray(other, 'RGBA'))
        self.assertGreater(error, 1.0)
        self.assertAlmostEqual(error, reference, delta=0.15)
        self.assertEqual(pipeline.visible_rms(rgba[:, :, :3], np.zeros((32, 32), np.uint8), other[:, :, :3], other[:, :, 3]), 0.0)

    def test_resample_keeps_aspect_and_premultiplied_edges_stay_colored(self):
        frames = np.zeros((1, 64, 48, 4), np.uint8)
        frames[0, :, :24] = (220, 30, 30, 255)
        small, width = pipeline.resample(frames, 32)
        self.assertEqual((small.shape, width), ((1, 32, 24, 4), 24))
        edge = small[0][(small[0, :, :, 3] > 0) & (small[0, :, :, 3] < 255)]
        self.assertGreater(len(edge), 0)
        self.assertTrue((edge[:, 0] >= 200).all())
        same, width = pipeline.resample(frames, 64)
        self.assertIs(same, frames)

    def test_ssim_scores_resolution_loss_only(self):
        frames = np.stack([shape_frame(), shape_frame(shift=6)])
        self.assertEqual(pipeline.ssim_score(frames, frames), 1.0)
        scores = [pipeline.ssim_score(frames, pipeline.resample(pipeline.resample(frames, height)[0], 64)[0]) for height in (48, 32, 16)]
        self.assertTrue(1.0 > scores[0] > scores[1] > scores[2] > 0.5, scores)
        self.assertEqual(pipeline.frame_selection(20), [0, 3, 5, 8, 11, 14, 16, 19])
        self.assertEqual(pipeline.frame_selection(3), [0, 1, 2])

    def test_allocation_steps_the_cheapest_ssim_loss_per_byte_first(self):
        def rungs(sizes, scores):
            return [dict(size=size, ssim=score) for size, score in zip(sizes, scores)]
        textures = dict(a=rungs([100, 60, 30], [1.0, 0.99, 0.95]), b=rungs([100, 90, 50], [1.0, 0.98, 0.90]),
                        c=rungs([100, 110, 50], [1.0, 0.995, 0.97]))
        self.assertEqual(pipeline.allocate(textures, 0, 5), ({'a': 0, 'b': 0, 'c': 0}, 305))
        self.assertEqual(pipeline.allocate(textures, 280, 5), ({'a': 1, 'b': 0, 'c': 0}, 265))
        self.assertEqual(pipeline.allocate(textures, 250, 5), ({'a': 1, 'b': 0, 'c': 2}, 215))
        self.assertEqual(pipeline.allocate(textures, 200, 5), ({'a': 2, 'b': 0, 'c': 2}, 185))
        self.assertEqual(pipeline.allocate(textures, 1, 5), ({'a': 2, 'b': 2, 'c': 2}, 135))
        self.assertIsNone(pipeline.next_step(textures['c'], 2))

    def test_rung_tags_carry_height_and_merge_threshold(self):
        self.assertEqual(pipeline.rung_tag(48, 5), '48t5')
        self.assertEqual(pipeline.parse_tag('48t5'), (48, 5))
        self.assertEqual(pipeline.parse_tag('64'), (64, pipeline.MERGE_THRESHOLD))

    def test_stronger_merge_threshold_shrinks_a_sheet_and_scores_below_the_lossless_rung(self):
        # 16 flat colours plus a 6-level speckle on red: 32 colours palettize exactly, and a 6-level
        # neighbour is outside threshold 3 (3 * 3^2 = 27 < 36) but inside threshold 8
        rng = random.Random(9)
        base = [(r, g, b, 255) for r in (40, 120) for g in (30, 90, 150, 210) for b in (60, 200)]
        frames = np.zeros((4, 64, 64, 4), np.uint8)
        for i in range(4):
            for y in range(64):
                for x in range(64):
                    r, g, b, a = base[(x // 8 + y // 8 + i) % 16]
                    frames[i, y, x] = (r + rng.choice((0, 6)), g, b, a)
        gentle, gentle_data, _ = pipeline.encode_rung(frames, 64, 3)
        strong, strong_data, _ = pipeline.encode_rung(frames, 64, 8)
        self.assertEqual((gentle['merge'], strong['merge'], gentle['suffix'], strong['suffix']), (3, 8, '.blp', '.blp'))
        self.assertEqual(gentle['error'], 0.0)
        self.assertLess(len(pipeline.compress(strong_data)), len(pipeline.compress(gentle_data)))
        self.assertLess(strong['ssim'], gentle['ssim'])
        self.assertEqual(gentle['ssim'], 1.0)

    def test_allocation_floor_keeps_every_emote_above_the_ssim_floor(self):
        def rungs(sizes, scores):
            return [dict(size=size, ssim=score) for size, score in zip(sizes, scores)]
        textures = dict(a=rungs([100, 60, 30], [1.0, 0.99, 0.80]), b=rungs([100, 90, 50], [1.0, 0.98, 0.90]))
        # b's last rung is the cheapest loss per byte but a's is under the floor, so only b reaches it
        self.assertEqual(pipeline.allocate(textures, 1, 0, floor=0.85), ({'a': 1, 'b': 2}, 110))
        self.assertEqual(pipeline.allocate(textures, 1, 0), ({'a': 2, 'b': 2}, 80))
        self.assertIsNone(pipeline.next_step(textures['a'], 1, 0.85))


class OptimizeTests(unittest.TestCase):
    def test_shared_animation_gets_sequence_height_and_lua_and_reruns_are_byte_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            packs, animation, static = fixture(root)
            source = hashlib.sha256((root / 'source/7tv/animation.tga').read_bytes()).hexdigest()
            summary = run(root)
            self.assertEqual(summary['published'], dict(textures=2, packs=2, lua=2))
            self.assertEqual(summary['heights'], {'64': 1})
            self.assertEqual((summary['statics_converted'], summary['tga_remaining']), (1, 0))
            # the 64 px rung scores the decoded sheet, so palette loss keeps it just under 1
            self.assertTrue(all(0.99 < summary['ssim'][key] <= 1.0 for key in ('mean', 'p05', 'min')), summary['ssim'])
            for old in packs:
                new = json.loads((root / 'packs' / (old['id'] + '.json')).read_text())
                for a, b in zip(old['emotes'], new['emotes']):
                    self.assertEqual({k: v for k, v in a.items() if k not in ('texture', 'texture_sha256', 'frames', 'columns', 'sheetWidth', 'sheetHeight')},
                                     {k: v for k, v in b.items() if k not in ('texture', 'texture_sha256', 'frames', 'columns', 'sheetWidth', 'sheetHeight', 'sequence', 'lossless')})
                    data = (root / 'TwitchEmotes' / b['texture']).read_bytes()
                    self.assertEqual(b['texture_sha256'], hashlib.sha256(data).hexdigest())
                    self.assertEqual(texture_formats.texture_dimensions(data, '.blp'), (b['sheetWidth'], b['sheetHeight']))
                    if a['frames'] > 1:
                        self.assertEqual(b['texture'], 'Media/7tv/animation.blp')
                        self.assertEqual((b['frames'], b['sequence'], b['columns'], b['sheetWidth'], b['sheetHeight']), (3, [0, 1, 0, 2], 3, 256, 64))
                        self.assertEqual(b['lossless'], dict(sha256=source, width=64, height=64, frames=4, cellWidth=64, columns=2, sheetWidth=128, sheetHeight=128))
                        decoded = np.asarray(texture_formats.decode_blp2(data))
                        cells = pipeline.cut_frames(decoded, 3, 3, 64, 64, 64)
                        self.assertEqual(cells[0].tolist(), cells[b['sequence'][2]].tolist())
                        for played, expected in zip(cells[b['sequence']], animation):
                            alpha = pipeline.alpha_snap(expected[:, :, 3])
                            exact = (alpha == 0) | (alpha == 255)
                            self.assertEqual(alpha[exact].tolist(), played[:, :, 3][exact].tolist())
                            self.assertLessEqual(np.abs(alpha.astype(int) - played[:, :, 3].astype(int)).max(), 3)
                            self.assertLess(pipeline.visible_rms(expected[:, :, :3], alpha, played[:, :, :3], played[:, :, 3]), 5)
                    else:
                        self.assertEqual(b['texture'], 'Media/7tv/static.blp')
                        self.assertNotIn('sequence', b)
                        decoded = np.asarray(texture_formats.decode_blp2(data))
                        self.assertEqual(decoded[:, :, 3].tolist(), static[:, :, 3].tolist())
                        self.assertLess(pipeline.visible_rms(static[:, :, :3], static[:, :, 3], decoded[:, :, :3], decoded[:, :, 3]), 2)
                self.assertEqual((root / 'TwitchEmotes/Packs' / (old['id'] + '.lua')).read_text(),
                                 optimizer.builder['render_lua'](new, new['emotes']))
            self.assertFalse((root / 'TwitchEmotes/Media/7tv/animation.tga').exists())
            self.assertFalse((root / 'TwitchEmotes/Media/7tv/static.tga').exists())
            first = snapshot(root)
            self.assertEqual(run(root)['published'], dict(textures=0, packs=0, lua=0))
            self.assertEqual(snapshot(root), first)
            floor = run(root, budget=1)
            self.assertFalse(floor['within_budget'])
            self.assertEqual(floor['heights'], {'32': 1})
            entry = json.loads((root / 'packs/first.json').read_text())['emotes'][0]
            self.assertEqual((entry['height'], entry['width'], entry['cellWidth'], entry['frames'], entry['sequence']), (32, 32, 32, 3, [0, 1, 0, 2]))
            self.assertLess(floor['after'], summary['after'])
            self.assertEqual(run(root, workers=2)['heights'], {'64': 1})
            self.assertEqual(snapshot(root), first)

    def test_dry_run_reports_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            fixture(root)
            before = snapshot(root)
            summary = run(root, dry_run=True, budget=1, report=root.parent / 'report.json')
            self.assertEqual(snapshot(root), before)
            self.assertEqual(summary['heights'], {'32': 1})
            report = json.loads((root.parent / 'report.json').read_text())
            self.assertEqual(report['textures']['Media/7tv/animation.tga']['height'], 32)
            self.assertTrue(report['dry_run'])

    def test_noisy_textures_fall_back_to_stabilised_tga_and_untouched_statics(self):
        rng = np.random.default_rng(9)
        noise = [shape_frame(rng=rng) for _ in range(3)]
        static = shape_frame(rng=rng)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            fixture(root, animation=noise + [noise[1]], static=static)
            static_bytes = (root / 'TwitchEmotes/Media/7tv/static.tga').read_bytes()
            summary = run(root)
            self.assertEqual((summary['statics_converted'], summary['tga_remaining']), (0, 2))
            self.assertEqual((root / 'TwitchEmotes/Media/7tv/static.tga').read_bytes(), static_bytes)
            entry = json.loads((root / 'packs/second.json').read_text())['emotes'][0]
            self.assertEqual(entry['texture'], 'Media/7tv/animation.tga')
            self.assertEqual((entry['frames'], entry['sequence'], entry['columns'], entry['sheetWidth']), (3, [0, 1, 2, 1], 3, 256))
            data = (root / 'TwitchEmotes' / entry['texture']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry['texture_sha256'])
            self.assertEqual(texture_formats.texture_dimensions(data, '.tga'), (256, 64))
            cells = pipeline.cut_frames(pipeline.read_rgba(data), 3, 3, 64, 64, 64)
            for played, expected in zip(cells[entry['sequence']], noise + [noise[1]]):
                self.assertLessEqual(visible_difference(played, expected)[0], 3)
            self.assertGreater(summary['textures']['Media/7tv/animation.tga']['error'], 0)

    def test_hash_mismatch_and_missing_source_abort_before_any_published_file_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            fixture(root)
            (root / 'TwitchEmotes/Media/7tv/animation.tga').write_bytes(b'changed externally')
            before = snapshot(root)
            with self.assertRaisesRegex(ValueError, 'hash'):
                run(root)
            self.assertEqual(before, snapshot(root))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            fixture(root)
            run(root)
            (root / 'source/7tv/animation.tga').unlink()
            before = snapshot(root)
            with self.assertRaisesRegex(ValueError, 'lossless source'):
                run(root, cache=root.parent / 'fresh-cache')
            self.assertEqual(before, snapshot(root))

    def test_option_parsers(self):
        self.assertEqual(optimizer.parse_heights('64,48'), (64, 48))
        self.assertEqual(optimizer.parse_near('off'), None)
        self.assertEqual(optimizer.parse_near('3:1.0'), (3, 1.0))
        for value in ('48,64', '64,64', '64,0', '56'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                optimizer.parse_heights(value)
        with self.assertRaises(ValueError):
            optimizer.parse_near('-1:2')


if __name__ == '__main__':
    unittest.main()
