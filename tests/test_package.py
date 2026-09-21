# Copyright (c) 2026 TheMizeGuy. All rights reserved.
import copy
import hashlib
import json
import os
from pathlib import Path
import random
import runpy
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib

from PIL import Image

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import package
import texture_formats

MODULES = ('Core.lua', 'Text.lua', 'Animation.lua', 'UI.lua', 'Completion.lua', 'Runtime.lua')
TOC_HEADER = ['## Interface: 16001', '## Title: Twitch Emotes', '## Author: TheMizeGuy',
              '## Version: 3.0.0', '## X-License: All Rights Reserved', '']
builder = {}


def render_lua(pack):
    if not builder:
        builder.update(runpy.run_path(str(SCRIPTS / 'build-7tv-pack.py')))
    return builder['render_lua'](pack, pack['emotes'])


def available_compressors():
    return [name for name in package.COMPRESSORS if package.compressor_module(name) is not None]


def noise(size, seed):
    rng = random.Random(seed)
    image = Image.new('RGBA', size)
    image.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256), rng.choice((0, 255)))
                   for _ in range(size[0] * size[1])])
    return image


def write_texture(path, image, indexed):
    if indexed:
        path.write_bytes(texture_formats.encode_indexed(image)[0])
    else:
        image.save(path, compression='tga_rle')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(root, pack):
    (root / 'packs' / (pack['id'] + '.json')).write_text(json.dumps(pack), encoding='utf-8')
    (root / 'TwitchEmotes/Packs' / (pack['id'] + '.lua')).write_text(render_lua(pack), encoding='utf-8')


def fixture(root):
    """Build the smallest install tree that verify() accepts, with one animation and one static."""
    addon = root / 'TwitchEmotes'
    (addon / 'Media/7tv').mkdir(parents=True)
    (addon / 'Media/UI').mkdir(parents=True)
    (addon / 'Packs').mkdir()
    (root / 'packs').mkdir()
    (root / 'assets').mkdir()
    (root / 'LICENSE').write_bytes(b'All Rights Reserved\n')
    (addon / 'LICENSE').write_bytes(b'All Rights Reserved\n')
    (addon / 'ASSET-NOTICES.md').write_text('# Asset notices\n')
    for name in MODULES:
        (addon / name).write_text('local addonName, E = ...\nreturn E\n')
    toc = '\n'.join(TOC_HEADER + list(MODULES) + ['Packs\\first.lua', ''])
    (addon / 'TwitchEmotes.toc').write_text(toc)
    (addon / 'TwitchEmotes_Camelot.toc').write_text(toc)
    icon_digest = write_texture(addon / 'Media/UI/TwitchGlitch.tga', noise((64, 64), 1), False)
    (root / 'assets/twitch-glitch.json').write_text(json.dumps(
        {'texture': 'Media/UI/TwitchGlitch.tga', 'texture_sha256': icon_digest}))
    animation = dict(name='catJAM', id='7tv:catjam', texture='Media/7tv/catjam.blp',
                     texture_sha256=write_texture(addon / 'Media/7tv/catjam.blp', noise((256, 128), 2), True),
                     width=48, height=32, frames=8, fps=30, cellWidth=64, columns=4,
                     sheetWidth=256, sheetHeight=128, sequence=[0, 1, 1, 2, 3, 3],
                     creator='Artist', source='https://7tv.app/emotes/catjam')
    static = dict(name='gz', id='7tv:gz', texture='Media/7tv/gz.tga',
                  texture_sha256=write_texture(addon / 'Media/7tv/gz.tga', noise((64, 64), 3), False),
                  width=64, height=64, frames=1, fps=0, cellWidth=64, columns=1,
                  sheetWidth=64, sheetHeight=64, creator='Artist', source='https://7tv.app/emotes/gz')
    pack = dict(id='first', title='First', provider='7TV', priority=20, group='first',
                groupTitle='First', source='https://7tv.app/', emotes=[animation, static])
    publish(root, pack)
    return pack


class VerifyTests(unittest.TestCase):
    def test_fixture_install_verifies_and_lists_every_shipped_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            files = package.verify(root)
            self.assertEqual(files, sorted(files))
            self.assertEqual(set(files), set(MODULES) | {
                'Packs/first.lua', 'TwitchEmotes.toc', 'TwitchEmotes_Camelot.toc', 'LICENSE',
                'ASSET-NOTICES.md', 'Media/7tv/catjam.blp', 'Media/7tv/gz.tga', 'Media/UI/TwitchGlitch.tga'})

    def test_playback_sequences_must_index_stored_frames(self):
        broken = ([0], list(range(257)), [0, 8], [0, -1], [0, 1.0], [0, True], 'ab', 4, [[0], [1]])
        for sequence in broken:
            with self.subTest(sequence=sequence), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                pack = fixture(root)
                pack['emotes'][0]['sequence'] = sequence
                publish(root, pack)
                with self.assertRaisesRegex(ValueError, 'sequence'):
                    package.verify(root)

    def test_a_sequence_needs_at_least_two_stored_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = fixture(root)
            pack['emotes'][0].update(frames=1, sequence=[0, 0])
            publish(root, pack)
            with self.assertRaisesRegex(ValueError, 'sequence'):
                package.verify(root)

    def test_valid_sequences_and_absent_sequences_pass(self):
        for sequence in ([0, 0], [7, 0, 3], list(range(8)) * 32, None):
            with self.subTest(sequence=sequence), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                pack = fixture(root)
                if sequence is None:
                    del pack['emotes'][0]['sequence']
                else:
                    pack['emotes'][0]['sequence'] = sequence
                publish(root, pack)
                self.assertIn('Packs/first.lua', package.verify(root))

    def test_shared_texture_with_a_different_sequence_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = fixture(root)
            alias = copy.deepcopy(pack['emotes'][0])
            alias.update(name='catJAM2', id='7tv:catjam2', sequence=[0, 1, 2, 3])
            pack['emotes'].append(alias)
            publish(root, pack)
            with self.assertRaisesRegex(ValueError, 'conflicting shared texture'):
                package.verify(root)

    def test_tampered_texture_and_missing_module_still_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            (root / 'TwitchEmotes/Media/7tv/gz.tga').write_bytes(
                (root / 'TwitchEmotes/Media/7tv/gz.tga').read_bytes()[:-1] + b'\x01')
            with self.assertRaisesRegex(ValueError, 'texture hash differs'):
                package.verify(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            (root / 'TwitchEmotes/UI.lua').unlink()
            with self.assertRaisesRegex(ValueError, 'missing or unsafe module'):
                package.verify(root)


class CompressorTests(unittest.TestCase):
    def test_auto_prefers_the_strongest_installed_encoder(self):
        self.assertEqual(package.select_compressor('auto'), available_compressors()[0])
        self.assertIn('zlib', available_compressors())

    def test_requesting_a_missing_encoder_raises(self):
        for name in package.COMPRESSORS:
            if package.compressor_module(name) is None:
                with self.assertRaisesRegex(ValueError, 'not installed'):
                    package.select_compressor(name)

    def test_every_encoder_round_trips_and_incompressible_data_is_stored(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'member.bin'
            text = (b'E:RegisterPack({ emotes = {} })\n' * 400)
            for compressor in available_compressors():
                with self.subTest(compressor=compressor):
                    path.write_bytes(text)
                    name, method, crc, size, blob = package.compress_member(('m', path, compressor))
                    self.assertEqual((name, method, crc, size), ('m', zipfile.ZIP_DEFLATED, zlib.crc32(text), len(text)))
                    self.assertLess(len(blob), len(text))
                    self.assertEqual(zlib.decompress(blob, -15), text)
                    for stored in (os.urandom(4096), b''):
                        path.write_bytes(stored)
                        _, method, crc, size, blob = package.compress_member(('m', path, compressor))
                        self.assertEqual((method, crc, size, blob),
                                         (zipfile.ZIP_STORED, zlib.crc32(stored), len(stored), stored))

    def test_an_empty_member_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'empty.zip'
            with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
                package.write_precompressed(archive, 'TwitchEmotes/empty.txt', zipfile.ZIP_STORED, 0, 0, b'')
            with zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read('TwitchEmotes/empty.txt'), b'')


class ArchiveTests(unittest.TestCase):
    def build(self, root, files, output, compressor, workers=1):
        package.build_zip(root, output, files, compressor, workers)
        return output.read_bytes()

    def assert_standard_archive(self, root, output, files):
        report = subprocess.run(['unzip', '-t', str(output)], capture_output=True, text=True)
        self.assertEqual(report.returncode, 0, report.stdout + report.stderr)
        self.assertIn('No errors detected', report.stdout)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual([member.filename for member in archive.infolist()],
                             ['TwitchEmotes/' + name for name in files])
            for member in archive.infolist():
                data = (root / 'TwitchEmotes' / member.filename.split('/', 1)[1]).read_bytes()
                self.assertEqual(archive.read(member), data)
                self.assertEqual((member.file_size, member.CRC), (len(data), zlib.crc32(data)))
                self.assertIn(member.compress_type, (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED))
                if member.compress_type == zipfile.ZIP_STORED:
                    self.assertEqual(member.compress_size, member.file_size)
                else:
                    self.assertLess(member.compress_size, member.file_size)
                self.assertEqual(member.extra, b'')
                self.assertFalse(member.flag_bits & 0x08)
                self.assertEqual(member.date_time, package.ZIP_TIMESTAMP)

    def test_release_archive_is_standard_reproducible_and_encoder_independent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            files = package.verify(root)
            contents = {}
            for compressor in available_compressors():
                with self.subTest(compressor=compressor):
                    output = root / 'dist' / (compressor + '.zip')
                    contents[compressor] = self.build(root, files, output, compressor)
                    self.assert_standard_archive(root, output, files)
                    self.assertEqual(contents[compressor], self.build(root, files, output, compressor))
            with zipfile.ZipFile(root / 'dist' / (available_compressors()[0] + '.zip')) as archive:
                extracted = {member.filename: archive.read(member) for member in archive.infolist()}
            for compressor, data in contents.items():
                with zipfile.ZipFile(root / 'dist' / (compressor + '.zip')) as archive:
                    self.assertEqual({m.filename: archive.read(m) for m in archive.infolist()}, extracted)

    def test_worker_pool_produces_the_same_archive_as_a_single_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            files = package.verify(root)
            compressor = package.select_compressor('auto')
            serial = self.build(root, files, root / 'dist/serial.zip', compressor, workers=1)
            parallel = self.build(root, files, root / 'dist/parallel.zip', compressor, workers=3)
            self.assertEqual(serial, parallel)

    def test_audit_rejects_an_archive_that_lost_a_member(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            files = package.verify(root)
            output = root / 'dist/short.zip'
            self.build(root, files, output, package.select_compressor('auto'))
            names = ['TwitchEmotes/' + name for name in files]
            with self.assertRaisesRegex(ValueError, 'ZIP members differ'):
                package.audit_zip(output, root, names[:-1])


if __name__ == '__main__':
    unittest.main()
