# Copyright (c) 2026 TheMizeGuy. All rights reserved.
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

from PIL import Image

MODULE_PATH = Path(__file__).resolve().parents[1] / 'scripts' / 'build-7tv-pack.py'
sys.path.insert(0, str(MODULE_PATH.parent))
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('pack_builder', MODULE_PATH)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class TextureTests(unittest.TestCase):
    def test_narrow_frame_grid_stays_within_runtime_column_limit(self):
        columns, width, height = builder.grid_layout(256, 1)
        self.assertLessEqual(columns, 32)
        self.assertEqual(width, columns)
        self.assertGreaterEqual(height, ((256 + columns - 1) // columns) * 64)
        self.assertLessEqual(height, 2048)

    def test_resizing_keeps_straight_alpha_without_dark_edges(self):
        frame = Image.new('RGBA', (128, 128), (255, 0, 0, 128))
        result = builder.fit_frame(frame, 64)
        self.assertEqual(result.getpixel((32, 32)), (255, 0, 0, 128))

    def test_frame_area_starts_at_left_edge_before_power_of_two_padding(self):
        frame = Image.new('RGBA', (192, 128), (10, 20, 30, 255))
        result = builder.fit_frame(frame, 128)
        self.assertEqual(result.getpixel((0, 0)), (10, 20, 30, 255))
        self.assertEqual(result.getpixel((95, 63)), (10, 20, 30, 255))
        self.assertEqual(result.getpixel((96, 0)), (0, 0, 0, 0))

    def test_wide_image_keeps_aspect_inside_texture_limits(self):
        frame = Image.new('RGBA', (1024, 128), (255, 255, 255, 255))
        result = builder.fit_frame(frame, 256)
        self.assertEqual(result.size, (256, 64))
        self.assertEqual(result.getbbox(), (0, 16, 256, 48))

    def test_sample_positions_follow_elapsed_time_and_preserve_loop(self):
        frames, duration = builder.subsample(['short', 'long'], [100, 900], 4)
        self.assertEqual(frames, ['short', 'long', 'long', 'long'])
        self.assertEqual(duration, 1000)

    def test_sampling_rejects_zero_frame_limit(self):
        with self.assertRaises(ValueError):
            builder.subsample(['one', 'two'], [100, 100], 0)

    def test_conversion_records_frame_crop_separately_from_texture_bounds(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'wide.png'
            target = Path(directory) / 'wide.tga'
            Image.new('RGBA', (192, 128), (0, 255, 0, 128)).save(source)
            metadata = builder.convert(source, target, 64)
            self.assertEqual(metadata.get('width'), 96)
            self.assertEqual(metadata.get('height'), 64)
            self.assertEqual(metadata.get('sheetWidth'), 128)
            self.assertEqual(metadata.get('sheetHeight'), 64)
            self.assertEqual(metadata.get('frames'), 1)
            self.assertEqual(metadata.get('fps'), 0)
            with Image.open(target) as texture:
                self.assertEqual(texture.size, (128, 64))
                self.assertEqual(texture.getpixel((20, 20)), (0, 255, 0, 128))


    def test_animated_conversion_preserves_nonuniform_loop_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'animated.webp'
            target = Path(directory) / 'animated.tga'
            Image.new('RGBA', (64, 64), 'red').save(
                source, format='WEBP', save_all=True, lossless=True,
                append_images=[Image.new('RGBA', (64, 64), 'blue')], duration=[100, 900], loop=0)
            metadata = builder.convert(source, target, 4)
            self.assertEqual(metadata['frames'], 4)
            self.assertEqual(metadata['fps'], 4)
            self.assertEqual(metadata['duration_ms'], 1000)
            self.assertEqual(metadata['sheetHeight'], 128)
            with Image.open(target) as texture:
                self.assertEqual(texture.getpixel((16, 16)), (255, 0, 0, 255))
                self.assertEqual(texture.getpixel((80, 16)), (0, 0, 255, 255))
                self.assertEqual(texture.getpixel((80, 80)), (0, 0, 255, 255))

    def test_long_animation_uses_at_most_64_uniform_samples(self):
        frames, duration = builder.subsample(list(range(100)), [20] * 100, 64)
        self.assertEqual(len(frames), 64)
        self.assertEqual(duration, 2000)
        self.assertEqual(frames[:5], [0, 1, 3, 4, 6])
        self.assertEqual(frames[-1], 98)


    def test_uniform_source_timing_does_not_create_duplicate_frames(self):
        frames, duration = builder.subsample(list(range(7)), [100] * 7, 256)
        self.assertEqual(frames, list(range(7)))
        self.assertEqual(duration, 700)

    def test_fast_animation_is_sampled_at_no_more_than_60_fps(self):
        frames, duration = builder.subsample(list(range(100)), [5] * 100, 256)
        self.assertEqual(len(frames), 30)
        self.assertEqual(duration, 500)
        self.assertEqual(frames[:4], [0, 3, 6, 10])

    def test_long_animation_preserves_up_to_256_frames(self):
        frames, duration = builder.subsample(list(range(500)), [20] * 500, 256)
        self.assertEqual(len(frames), 256)
        self.assertEqual(duration, 10000)
        self.assertEqual(frames[-1], 498)

    def test_one_millisecond_loop_uses_static_preview_to_honor_fps_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'fast.webp'
            target = Path(directory) / 'fast.tga'
            Image.new('RGBA', (64, 64), 'red').save(
                source, format='WEBP', save_all=True, lossless=True,
                append_images=[Image.new('RGBA', (64, 64), 'blue')], duration=[1, 1], loop=0)
            metadata = builder.convert(source, target, 256)
            self.assertEqual(metadata['frames'], 1)
            self.assertEqual(metadata['fps'], 0)
            self.assertEqual(metadata['duration_ms'], 2)
            self.assertEqual(metadata.get('source_duration_ms'), 2)
            self.assertFalse(metadata.get('timing_normalized', True))

    def test_zero_durations_record_source_timing_and_explicit_playback_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'zero.webp'
            target = Path(directory) / 'zero.tga'
            Image.new('RGBA', (64, 64), 'red').save(
                source, format='WEBP', save_all=True, lossless=True,
                append_images=[Image.new('RGBA', (64, 64), 'blue')], duration=[0, 0], loop=0)
            metadata = builder.convert(source, target, 256)
            self.assertEqual(metadata['frames'], 2)
            self.assertEqual(metadata['fps'], 10)
            self.assertEqual(metadata['duration_ms'], 200)
            self.assertEqual(metadata.get('source_duration_ms'), 0)
            self.assertTrue(metadata.get('timing_normalized', False))

    def test_grid_crops_cross_rows_without_reading_frame_padding(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'grid.webp'
            target = Path(directory) / 'grid.tga'
            frames = [Image.new('RGBA', (192, 128), (index + 1, 0, 0, 255)) for index in range(40)]
            frames[0].save(source, format='WEBP', save_all=True, lossless=True,
                           append_images=frames[1:], duration=20, loop=0)
            metadata = builder.convert(source, target, 256)
            self.assertEqual(metadata['width'], 96)
            self.assertEqual(metadata['cellWidth'], 128)
            self.assertEqual(metadata['columns'], 4)
            self.assertEqual(metadata['frames'], 40)
            self.assertEqual(metadata['fps'], 50)
            self.assertEqual(metadata['sheetWidth'], 512)
            self.assertEqual(metadata['sheetHeight'], 1024)
            with Image.open(target) as texture:
                self.assertEqual(texture.getpixel((384, 0)), (4, 0, 0, 255))
                self.assertEqual(texture.getpixel((0, 64)), (5, 0, 0, 255))
                self.assertEqual(texture.getpixel((96, 64)), (0, 0, 0, 0))
                self.assertEqual(texture.getpixel((384, 576)), (40, 0, 0, 255))


def seven_tv_emote(name='wave', identifier='ABC123'):
    return {
        'id': identifier, 'name': name,
        'data': {
            'id': identifier, 'animated': False,
            'owner': {'id': 'CREATOR1', 'username': 'artist', 'display_name': 'Artist'},
            'host': {'url': '//cdn.7tv.app/emote/' + str(identifier), 'files': [
                {'name': '2x.webp', 'width': 64, 'height': 64, 'frame_count': 1, 'format': 'WEBP'},
                {'name': '2x.png', 'width': 64, 'height': 64, 'frame_count': 1, 'format': 'PNG'},
            ]},
        },
    }


def seven_tv_pack(*emotes):
    return builder.normalize_7tv({'id': 'SET1', 'emotes': list(emotes)}, 'channel', 'Channel', 20,
                                 'https://7tv.io/v3/emote-sets/SET1')


def png_bytes(color=(255, 0, 0, 128)):
    output = io.BytesIO()
    Image.new('RGBA', (64, 64), color).save(output, format='PNG')
    return output.getvalue()


class MetadataTests(unittest.TestCase):
    def test_channel_lookup_uses_public_id_and_checks_the_returned_connection(self):
        data = {'id': '123', 'platform': 'TWITCH', 'username': 'sample',
                'emote_set': {'id': 'SET1', 'emotes': [seven_tv_emote()]}}
        with patch.object(builder, 'http_get', return_value=b'123\n') as lookup, \
                patch.object(builder, 'get_json', return_value=data):
            pack = builder.fetch_channel('Sample', None, 'sample_pack', 'Sample', 20)
        lookup.assert_called_once_with('https://decapi.me/twitch/id/sample')
        self.assertEqual(pack['group'], 'sample')
        self.assertEqual(pack['channel_id'], '123')
        self.assertEqual(pack['channel_login'], 'sample')
        data['username'] = 'different'
        with patch.object(builder, 'get_json', return_value=data), self.assertRaisesRegex(ValueError, 'identity'):
            builder.fetch_channel('sample', '123', 'sample', 'Sample', 20)

    def test_channel_without_an_active_set_fails_before_replacing_its_pack(self):
        data = {'id': '123', 'platform': 'TWITCH', 'username': 'sample', 'emote_set': None}
        with patch.object(builder, 'get_json', return_value=data), self.assertRaisesRegex(ValueError, 'active'):
            builder.fetch_channel('sample', '123', 'sample', 'Sample', 20)

    def test_native_catalog_refresh_fetches_configured_identity_and_original_images(self):
        def html(identifier, name, prefix, login=''):
            channel = f'<a href="https://twitch.tv/{login}">Channel</a>' if login else ''
            return (channel + f'<a href="{prefix}{identifier}"><img class="emote" '
                    f'data-image-id="{identifier}" data-regex="{name}" '
                    f'src="https://static-cdn.jtvnw.net/emoticons/v1/{identifier}/1.0"></a>').encode()
        responses = {
            'https://twitchemotes.com/': html('1', 'global', '/global/emotes/'),
            'https://twitchemotes.com/channels/123': html('2', 'channel', '/channels/123/emotes/', 'sample'),
            'https://static-cdn.jtvnw.net/emoticons/v2/1/default/dark/3.0': png_bytes(),
            'https://static-cdn.jtvnw.net/emoticons/v2/2/default/dark/3.0': png_bytes(),
        }
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'channels.json'
            config.write_text(json.dumps({'channels': [{'twitch_id': '123', 'login': 'sample', 'title': 'Sample'}]}))
            with patch.object(builder, 'http_get', side_effect=responses.__getitem__):
                packs = builder.fetch_native_catalogs(config, workers=1)
        self.assertEqual([p['id'] for p in packs], ['twitch_global', 'twitch_sample'])
        self.assertEqual([p['group'] for p in packs], ['general', 'sample'])
        self.assertTrue(all(p['emotes'][0]['download'].endswith('/dark/3.0') for p in packs))

    def test_punctuation_names_are_literal_and_unsafe_text_is_rejected(self):
        for name in ('M&Mjc', ':tf:', 'c++', 'hello.world', 'éSmile', 'quote"name'):
            self.assertEqual(builder.validate_name(name), name)
        for name in ('', 'two words', 'line\nfeed', 'a|Hlink', 'bad\x00', 'bad\x7f', 'invisible\u200b', 'x' * 129):
            with self.subTest(name=repr(name)), self.assertRaises(ValueError):
                builder.validate_name(name)

    def test_provider_ids_cannot_escape_media_or_create_windows_device_files(self):
        for identifier in (None, '../bad', 'a/b', 'a\\b', '.hidden', 'CON', 'NUL', 'a:stream'):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                seven_tv_pack(seven_tv_emote(identifier=identifier))

    def test_provider_image_host_must_match_trusted_cdn(self):
        emote = seven_tv_emote()
        emote['data']['host']['url'] = 'https://example.org/image'
        with self.assertRaises(ValueError):
            seven_tv_pack(emote)

    def test_7tv_alias_keeps_provider_id_and_creator_attribution(self):
        pack = seven_tv_pack(seven_tv_emote('alias!'))
        entry = pack['emotes'][0]
        self.assertEqual(entry['name'], 'alias!')
        self.assertEqual(entry['id'], '7tv:ABC123')
        self.assertEqual(entry['creator'], 'Artist')
        self.assertEqual(entry['creator_id'], 'CREATOR1')
        self.assertEqual(entry['source'], 'https://7tv.app/emotes/ABC123')
        self.assertEqual(entry['download'], 'https://cdn.7tv.app/emote/ABC123/2x.webp')

    def test_7tv_resolved_artwork_id_can_differ_from_set_entry_id(self):
        emote = seven_tv_emote(identifier='RESOLVED')
        emote['id'] = 'OLDENTRY'
        record = seven_tv_pack(emote)['emotes'][0]
        self.assertEqual(record['id'], '7tv:RESOLVED')
        self.assertEqual(record['set_entry_id'], 'OLDENTRY')
        self.assertEqual(record['download'], 'https://cdn.7tv.app/emote/RESOLVED/2x.webp')
        self.assertEqual(record['source'], 'https://7tv.app/emotes/RESOLVED')

    def test_7tv_uses_highest_available_source_then_falls_back_by_resolution(self):
        emote = seven_tv_emote()
        files = emote['data']['host']['files']
        files.extend([{'name': '3x.webp', 'width': 96, 'height': 96, 'frame_count': 1, 'format': 'WEBP'},
                      {'name': '4x.webp', 'width': 128, 'height': 128, 'frame_count': 1, 'format': 'WEBP'}])
        self.assertEqual(seven_tv_pack(emote)['emotes'][0]['download'],
                         'https://cdn.7tv.app/emote/ABC123/4x.webp')
        files.pop()
        self.assertEqual(seven_tv_pack(emote)['emotes'][0]['download'],
                         'https://cdn.7tv.app/emote/ABC123/3x.webp')

    def test_global_and_channel_packs_supply_stable_picker_groups(self):
        global_pack = builder.normalize_bttv([])
        self.assertEqual(global_pack.get('group'), 'general')
        self.assertEqual(global_pack.get('groupTitle'), 'General')
        channel_pack = seven_tv_pack(seven_tv_emote())
        self.assertEqual(channel_pack.get('group'), 'channel')
        self.assertEqual(channel_pack.get('groupTitle'), 'Channel')

    def test_unavailable_7tv_artwork_is_recorded_without_a_broken_texture(self):
        unavailable = seven_tv_emote('gone', 'UNAVAILABLE')
        unavailable['data']['lifecycle'] = 0
        unavailable['data']['host'] = {'url': '', 'files': []}
        pack = seven_tv_pack(seven_tv_emote(), unavailable)
        self.assertEqual([e['name'] for e in pack['emotes']], ['wave'])
        self.assertEqual(pack['excluded'], [{'id': 'UNAVAILABLE', 'name': 'gone',
            'source': 'https://7tv.app/emotes/UNAVAILABLE', 'reason': 'provider supplies no image'}])

    def test_bttv_channel_combines_uploaded_and_shared_emotes_in_one_channel_group(self):
        data = {'id': 'BTTVOWNER', 'channelEmotes': [
            {'id': 'OWN', 'code': 'own', 'imageType': 'gif', 'userId': 'BTTVOWNER'}],
            'sharedEmotes': [{'id': 'SHARED', 'code': 'shared', 'imageType': 'png',
                              'user': {'id': 'ARTIST', 'displayName': 'Artist'}}]}
        pack = builder.normalize_bttv_channel(data, 'swifty', 'Swifty', '23524577')
        self.assertEqual(pack['id'], 'bttv_swifty')
        self.assertEqual(pack['group'], 'swifty')
        self.assertEqual(pack['groupTitle'], 'Swifty')
        self.assertEqual([e['id'] for e in pack['emotes']], ['bttv:OWN', 'bttv:SHARED'])
        self.assertEqual(pack['metadata_api'], 'https://api.betterttv.net/3/cached/users/twitch/23524577')
        self.assertEqual(pack['emotes'][1]['creator'], 'Artist')

    def test_ffz_channel_uses_verified_room_set_and_group(self):
        data = {'room': {'id': 'pikabooirl', 'display_name': 'Pikabooirl', 'twitch_id': 27992608, 'set': 7},
                'sets': {'7': {'emoticons': [{'id': 42, 'name': 'wave',
                    'owner': {'_id': 9, 'display_name': 'Artist'},
                    'urls': {'4': 'https://cdn.frankerfacez.com/emote/42/4'}}]}}}
        pack = builder.normalize_ffz_channel(data, 'pikabooirl', 'Pikabooirl', '27992608')
        self.assertEqual(pack['id'], 'ffz_pikabooirl')
        self.assertEqual(pack['group'], 'pikabooirl')
        self.assertEqual(pack['groupTitle'], 'Pikabooirl')
        self.assertEqual(pack['emotes'][0]['download'], 'https://cdn.frankerfacez.com/emote/42/4')
        with self.assertRaises(ValueError):
            builder.normalize_ffz_channel(data, 'swifty', 'Swifty', '23524577')

    def test_unsafe_creator_display_uses_safe_provider_username_or_id(self):
        emote = seven_tv_emote()
        emote['data']['owner']['display_name'] = '\u061cHidden'
        self.assertEqual(seven_tv_pack(emote)['emotes'][0]['creator'], 'artist')
        emote['data']['owner']['username'] = 'unsafe|name'
        self.assertEqual(seven_tv_pack(emote)['emotes'][0]['creator'], '7TV account CREATOR1')

    def test_native_twitch_sources_only_accept_the_official_cdn(self):
        url = 'https://static-cdn.jtvnw.net/emoticons/v2/emotesv2_example/animated/dark/3.0'
        self.assertEqual(builder.image_url(url, 'twitch'), url)
        with self.assertRaises(ValueError):
            builder.image_url('https://example.org/emote.gif', 'twitch')

    def test_duplicate_7tv_alias_uses_later_provider_entry_and_records_conflict(self):
        pack = seven_tv_pack(seven_tv_emote('same', 'FIRST'), seven_tv_emote('same', 'LAST'))
        self.assertEqual([e['id'] for e in pack['emotes']], ['7tv:LAST'])
        self.assertEqual(pack['excluded'][0]['id'], 'FIRST')
        self.assertEqual(pack['excluded'][0]['selected_id'], '7tv:LAST')
        self.assertEqual(pack['excluded'][0]['reason'], 'duplicate name; later catalog entry wins')

    def test_bttv_retains_owner_id_and_skips_effect_modifiers(self):
        data = [
            {'id': 'EMOTE1', 'code': 'M&Mjc', 'imageType': 'png', 'animated': False,
             'userId': 'USER1', 'modifier': False},
            {'id': 'EFFECT1', 'code': 'h!', 'imageType': 'png', 'animated': False,
             'userId': 'USER1', 'modifier': True},
        ]
        pack = builder.normalize_bttv(data)
        self.assertEqual([e['name'] for e in pack['emotes']], ['M&Mjc'])
        entry = pack['emotes'][0]
        self.assertEqual(entry['id'], 'bttv:EMOTE1')
        self.assertEqual(entry['creator_id'], 'USER1')
        self.assertEqual(entry['creator'], 'BTTV account USER1')
        self.assertEqual(entry['download'], 'https://cdn.betterttv.net/emote/EMOTE1/3x')
        self.assertEqual(pack['excluded'][0]['reason'], 'modifier effect')

    def test_ffz_reads_only_default_sets_and_prefers_explicit_artist(self):
        def emote(identifier, name, **extra):
            return dict(id=identifier, name=name, width=32, height=32,
                        owner={'_id': 9, 'display_name': 'Uploader'},
                        artist={'_id': 8, 'display_name': 'Artist'},
                        urls={'1': f'https://cdn.frankerfacez.com/emote/{identifier}/1',
                              '2': f'https://cdn.frankerfacez.com/emote/{identifier}/2'}, **extra)
        data = {'default_sets': [3], 'sets': {
            '3': {'emoticons': [emote(42, 'wide'), emote(43, 'fx', modifier=True)]},
            '4': {'emoticons': [emote(44, 'subscriberOnly')]},
        }}
        pack = builder.normalize_ffz(data)
        self.assertEqual([e['name'] for e in pack['emotes']], ['wide'])
        self.assertEqual(pack['emotes'][0]['creator'], 'Artist')
        self.assertEqual(pack['emotes'][0]['creator_id'], '8')
        self.assertEqual(pack['emotes'][0]['download'], 'https://cdn.frankerfacez.com/emote/42/2')


def lua_pack():
    return {'id': 'channel', 'title': 'Channel', 'provider': '7TV', 'priority': 20,
            'source': 'https://7tv.app/emote-sets/SET1', 'group': 'channel', 'groupTitle': 'Channel'}


def lua_record(**overrides):
    record = {'name': 'wave', 'id': '7tv:ABC123', 'width': 64, 'height': 40, 'frames': 3, 'fps': 10,
              'cellWidth': 64, 'columns': 2, 'sheetWidth': 128, 'sheetHeight': 128, 'creator': 'Artist',
              'source': 'https://7tv.app/emotes/ABC123', 'texture': 'Media/7tv/ABC123.tga'}
    record.update(overrides)
    return record


class SequenceTests(unittest.TestCase):
    def test_generated_lua_lists_the_playback_sequence_after_the_frame_rate(self):
        self.assertIn(
            '    { name = "wave", id = "7tv:ABC123", width = 64, height = 40, frames = 3, fps = 10, '
            r'sequence = "\000\001\001\002", '
            'cellWidth = 64, columns = 2, sheetWidth = 128, sheetHeight = 128, creator = "Artist", '
            'source = "https://7tv.app/emotes/ABC123", '
            r'path = "Interface\\AddOns\\TwitchEmotes\\Media\\7tv\\ABC123.tga" },',
            builder.render_lua(lua_pack(), [lua_record(sequence=[0, 1, 1, 2])]))

    def test_entries_without_a_meaningful_sequence_keep_the_published_layout(self):
        plain = builder.render_lua(lua_pack(), [lua_record()])
        self.assertNotIn('sequence', plain)
        self.assertEqual(builder.render_lua(lua_pack(), [lua_record(sequence=[0, 1, 2])]), plain)

    def test_generated_lua_rejects_a_manifest_sequence_outside_the_stored_cells(self):
        with self.assertRaises(ValueError):
            builder.render_lua(lua_pack(), [lua_record(sequence=[0, 3])])

    def test_json_sequences_accept_bounded_orders_and_drop_the_identity_order(self):
        self.assertEqual(builder.validate_sequence([0, 1, 1, 2], 3), [0, 1, 1, 2])
        self.assertEqual(builder.validate_sequence([2, 0], 3), [2, 0])
        self.assertEqual(builder.validate_sequence([0] * 256, 256), [0] * 256)
        self.assertIsNone(builder.validate_sequence(None, 3))
        self.assertIsNone(builder.validate_sequence([0, 1, 2], 3))

    def test_json_sequences_reject_unplayable_orders(self):
        for value, frames in (([0], 3), ([0, 1] * 129, 3), ([0, 3], 3), ([0, -1], 3), ([0, 1.0], 3),
                              ([0, True], 3), (['0', '1'], 3), ({'0': 1}, 3), ('\x00\x01', 3), ([0, 0], 1)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                builder.validate_sequence(value, frames)


class BuildTests(unittest.TestCase):
    def test_build_stores_only_a_meaningful_playback_sequence(self):
        original = builder.convert
        for sequence, expected in (([0, 1, 1, 2], [0, 1, 1, 2]), ([0, 1, 2], None)):
            def convert(source, destination, max_frames, sequence=sequence):
                return {**original(source, destination, max_frames), 'frames': 3, 'sequence': sequence}
            with self.subTest(sequence=sequence), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with patch.object(builder, 'convert', convert):
                    builder.build_packs([seven_tv_pack(seven_tv_emote())], root / 'TwitchEmotes',
                                        root / 'packs', root / 'cache',
                                        download=lambda _url: png_bytes(), workers=1)
                manifest = json.loads((root / 'packs' / 'channel.json').read_text())
                self.assertEqual(manifest['emotes'][0].get('sequence'), expected)
                lua = (root / 'TwitchEmotes' / 'Packs' / 'channel.lua').read_text()
                self.assertEqual(r'sequence = "\000\001\001\002"' in lua, expected is not None)

    def test_build_refuses_a_converted_sequence_that_leaves_the_stored_cells(self):
        original = builder.convert
        def convert(source, destination, max_frames):
            return {**original(source, destination, max_frames), 'frames': 3, 'sequence': [0, 9]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(builder, 'convert', convert), self.assertRaises(ValueError):
                builder.build_packs([seven_tv_pack(seven_tv_emote())], root / 'TwitchEmotes',
                                    root / 'packs', root / 'cache',
                                    download=lambda _url: png_bytes(), workers=1)
            self.assertFalse((root / 'packs').exists())

    def test_refresh_removes_replaced_format_only_after_publishing_new_texture(self):
        pack = seven_tv_pack(seven_tv_emote())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            addon, manifests = root / 'TwitchEmotes', root / 'packs'
            builder.build_packs([pack], addon, manifests, root / 'cache', download=lambda _: png_bytes(), workers=1)
            old_tga = addon / 'Media/7tv/ABC123.tga'
            old_blp = old_tga.with_suffix('.blp')
            old_tga.rename(old_blp)
            manifest_path = manifests / 'channel.json'
            manifest = json.loads(manifest_path.read_text())
            manifest['emotes'][0]['texture'] = 'Media/7tv/ABC123.blp'
            manifest_path.write_text(json.dumps(manifest))
            builder.build_packs([pack], addon, manifests, root / 'cache', download=lambda _: png_bytes(), workers=1)
            self.assertTrue(old_tga.is_file())
            self.assertFalse(old_blp.exists())

    def test_publish_failure_restores_deleted_texture_and_replaced_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'old.tga'; old.write_bytes(b'original')
            source = root / 'new.blp'; source.write_bytes(b'converted')
            stage = root / 'stage'; stage.mkdir()
            blocked = root / 'blocked'; blocked.write_text('file')
            with self.assertRaises(OSError):
                builder.publish_files([(None, old), (source, root / 'installed.blp'),
                                       (source, blocked / 'invalid')], stage)
            self.assertEqual(old.read_bytes(), b'original')
            self.assertFalse((root / 'installed.blp').exists())

    def test_aliases_and_packs_share_one_texture_and_manifest_hashes(self):
        first = seven_tv_pack(seven_tv_emote('first'), seven_tv_emote('second'))
        second = seven_tv_pack(seven_tv_emote('third'))
        second['id'] = 'second_pack'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder.build_packs([first, second], root / 'TwitchEmotes', root / 'packs',
                                root / 'cache', download=lambda _url: png_bytes(), workers=1)
            textures = list((root / 'TwitchEmotes' / 'Media').rglob('*.tga'))
            self.assertEqual([p.name for p in textures], ['ABC123.tga'])
            manifest = json.loads((root / 'packs' / 'channel.json').read_text())
            self.assertEqual(len(manifest['emotes']), 2)
            self.assertEqual(manifest['emotes'][0]['texture_sha256'], manifest['emotes'][1]['texture_sha256'])
            self.assertEqual(manifest['emotes'][0]['texture'], 'Media/7tv/ABC123.tga')
            second_manifest = json.loads((root / 'packs' / 'second_pack.json').read_text())
            self.assertEqual(manifest['emotes'][0]['texture_sha256'], second_manifest['emotes'][0]['texture_sha256'])
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            builder.build_packs([first, second], root / 'TwitchEmotes', root / 'packs',
                                root / 'cache', download=lambda _url: png_bytes(), workers=1)
            after = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(after, before)

    def test_failed_conversion_leaves_existing_pack_and_textures_intact(self):
        first = seven_tv_pack(seven_tv_emote())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder.build_packs([first], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                download=lambda _url: png_bytes(), workers=1)
            before = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                      for p in (root / folder).rglob('*') if p.is_file()}
            broken = seven_tv_pack(seven_tv_emote(identifier='BROKEN'))
            with self.assertRaises((ValueError, OSError)):
                builder.build_packs([broken], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                    download=lambda _url: b'not an image', workers=1)
            after = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                     for p in (root / folder).rglob('*') if p.is_file()}
            self.assertEqual(after, before)

    def test_failed_download_does_not_publish_a_partial_pack(self):
        pack = seven_tv_pack(seven_tv_emote('works', 'GOOD'), seven_tv_emote('fails', 'BAD'))
        def download(url):
            if '/BAD/' in url:
                raise OSError('network unavailable')
            return png_bytes()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(OSError):
                builder.build_packs([pack], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                    download=download, workers=1)
            self.assertFalse((root / 'TwitchEmotes' / 'Packs' / 'channel.lua').exists())
            self.assertFalse((root / 'TwitchEmotes' / 'Media').exists())


    def test_publish_io_failure_rolls_back_prior_texture_and_lua_replacements(self):
        pack = seven_tv_pack(seven_tv_emote())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder.build_packs([pack], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                download=lambda _url: png_bytes(), workers=1)
            before = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                      for p in (root / folder).rglob('*') if p.is_file()}
            blocked = root / 'not_a_directory'
            blocked.write_text('occupied')
            changed = seven_tv_pack(seven_tv_emote('changed', 'NEW'))
            with self.assertRaises(OSError):
                builder.build_packs([changed], root / 'TwitchEmotes', blocked, root / 'cache',
                                    download=lambda _url: png_bytes((0, 0, 255, 255)), workers=1)
            after = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                     for p in (root / folder).rglob('*') if p.is_file()}
            self.assertEqual(after, before)


    def test_refresh_cannot_change_shared_texture_without_other_referencing_packs(self):
        first = seven_tv_pack(seven_tv_emote())
        second = seven_tv_pack(seven_tv_emote('alias'))
        second['id'] = 'second_pack'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder.build_packs([first, second], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                download=lambda _url: png_bytes(), workers=1)
            before = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                      for p in (root / folder).rglob('*') if p.is_file()}
            with self.assertRaisesRegex(ValueError, 'shared.*second_pack'):
                builder.build_packs([first], root / 'TwitchEmotes', root / 'packs', root / 'fresh_cache',
                                    download=lambda _url: png_bytes((0, 0, 255, 255)), workers=1)
            after = {p.relative_to(root): p.read_bytes() for folder in ('TwitchEmotes', 'packs')
                     for p in (root / folder).rglob('*') if p.is_file()}
            self.assertEqual(after, before)

    def test_case_colliding_provider_ids_cannot_overwrite_windows_texture(self):
        pack = seven_tv_pack(seven_tv_emote('upper', 'ABC'), seven_tv_emote('lower', 'abc'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'case'):
                builder.build_packs([pack], root / 'TwitchEmotes', root / 'packs', root / 'cache',
                                    download=lambda _url: png_bytes(), workers=1)


    def test_higher_resolution_url_never_reuses_lower_resolution_cached_bytes(self):
        record = seven_tv_pack(seven_tv_emote())['emotes'][0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'ABC123.webp'
            old.write_bytes(png_bytes())
            two_x = builder.cache_source(record, root, lambda _url: png_bytes())
            record['download'] = 'https://cdn.7tv.app/emote/ABC123/4x.webp'
            four_x = builder.cache_source(record, root, lambda _url: png_bytes((0, 0, 255, 255)))
            self.assertNotEqual(two_x, four_x)
            with Image.open(four_x) as image:
                self.assertEqual(image.getpixel((0, 0)), (0, 0, 255, 255))
            with Image.open(two_x) as image:
                self.assertEqual(image.getpixel((0, 0)), (255, 0, 0, 128))


if __name__ == '__main__':
    unittest.main()
