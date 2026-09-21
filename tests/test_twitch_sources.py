# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Fixtures match public twitchemotes.com metadata retrieved 2026-09-20."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from twitch_sources import normalize_twitch


CHANNEL = '''<h3><a href="https://www.twitch.tv/forsen" target="_blank">forsen</a></h3>
<a href="/channels/22484632/emotes/304412445"><img
src="https://static-cdn.jtvnw.net/emoticons/v2/304412445/static/light/2.0"
data-image-id="304412445" class="emote expandable-emote" data-regex="forsenSmug"></a>
<a href="/channels/22484632/emotes/emotesv2_9af1409cc37942b9a94fe9fa39872e90"><img
src="https://static-cdn.jtvnw.net/emoticons/v2/emotesv2_9af1409cc37942b9a94fe9fa39872e90/animated/light/2.0"
data-image-id="emotesv2_9af1409cc37942b9a94fe9fa39872e90" class="emote expandable-emote"
data-regex="forsenCorn"></a>'''
GLOBAL = '''<h3>Global Emotes</h3>
<a href="/global/emotes/354"><img src="https://static-cdn.jtvnw.net/emoticons/v1/354/1.0"
data-regex="4Head" data-image-id="354" class="emote expandable-emote"></a>
<a href="/global/emotes/emotesv2_dcd06b30a5c24f6eb871e8f5edbd44f7"><img
src="https://static-cdn.jtvnw.net/emoticons/v1/emotesv2_dcd06b30a5c24f6eb871e8f5edbd44f7/1.0"
data-regex="DinoDance" data-image-id="emotesv2_dcd06b30a5c24f6eb871e8f5edbd44f7"
class="emote expandable-emote"></a>'''


class TwitchSourcesTests(unittest.TestCase):
    def channel(self, html=CHANNEL, **kwargs):
        return normalize_twitch(html, twitch_id='22484632', login='forsen', title='Forsen', **kwargs)

    def test_channel_pack_preserves_owner_group_and_real_animation_format(self):
        pack = self.channel(priority=32)
        self.assertEqual((pack['id'], pack['group'], pack['groupTitle'], pack['priority']),
                         ('twitch_forsen', 'forsen', 'Forsen', 32))
        self.assertEqual(pack['provider'], 'Twitch')
        self.assertEqual(pack['metadata_api'], 'https://twitchemotes.com/channels/22484632')
        self.assertEqual(len(pack['emotes']), 2)
        static, animated = pack['emotes']
        self.assertEqual(static['id'], 'twitch:304412445')
        self.assertEqual(static['provider_id'], '304412445')
        self.assertEqual(static['provider'], 'twitch')
        self.assertEqual(static['name'], 'forsenSmug')
        self.assertEqual(static['download'], 'https://static-cdn.jtvnw.net/emoticons/v2/304412445/static/dark/3.0')
        self.assertEqual(static['source'], 'https://twitchemotes.com/channels/22484632/emotes/304412445')
        self.assertEqual(static['creator'], 'Forsen')
        self.assertEqual(static['creator_id'], '22484632')
        self.assertEqual(static['attribution'], 'provider owner')
        self.assertEqual(static['format'], 'png')
        self.assertEqual(animated['format'], 'gif')
        self.assertIn('/animated/dark/3.0', animated['download'])

    def test_v1_global_images_use_default_format_to_keep_native_animation(self):
        responses = {
            'https://static-cdn.jtvnw.net/emoticons/v2/354/default/dark/3.0': b'\x89PNG\r\n\x1a\n',
            'https://static-cdn.jtvnw.net/emoticons/v2/emotesv2_dcd06b30a5c24f6eb871e8f5edbd44f7/default/dark/3.0': b'GIF89a',
        }
        pack = normalize_twitch(GLOBAL.encode(), image_reader=responses.__getitem__)
        self.assertEqual((pack['id'], pack['group'], pack['groupTitle']),
                         ('twitch_global', 'general', 'General'))
        self.assertEqual([e['format'] for e in pack['emotes']], ['png', 'gif'])
        self.assertEqual(pack['emotes'][0]['source'], 'https://twitchemotes.com/global/emotes/354')
        self.assertEqual(pack['emotes'][0]['attribution'], 'not supplied')
        self.assertIsNone(pack['emotes'][0]['creator_id'])

    def test_global_v1_requires_image_evidence_instead_of_guessing_animation(self):
        with self.assertRaises(ValueError):
            normalize_twitch(GLOBAL)

    def test_rejects_wrong_channel_identity(self):
        with self.assertRaises(ValueError):
            self.channel(CHANNEL.replace('twitch.tv/forsen', 'twitch.tv/someoneelse'))

    def test_rejects_wrong_channel_id_in_emote_source_link(self):
        with self.assertRaises(ValueError):
            self.channel(CHANNEL.replace('/channels/22484632/', '/channels/123/'))

    def test_rejects_untrusted_image_hosts_and_mismatched_ids(self):
        for html in (CHANNEL.replace('static-cdn.jtvnw.net', 'evil.example'),
                     CHANNEL.replace('/v2/304412445/', '/v2/25/'),
                     CHANNEL.replace('/static/light/2.0', '/static/light/2.0?x=1')):
            with self.subTest(html=html), self.assertRaises(ValueError):
                self.channel(html)

    def test_rejects_empty_or_non_catalog_pages(self):
        for html in ('', '<h1>Temporarily unavailable</h1>', '<img src="logo.png">'):
            with self.subTest(html=html), self.assertRaises(ValueError):
                normalize_twitch(html)

    def test_excludes_unsafe_names_without_losing_safe_emotes(self):
        pack = self.channel(CHANNEL.replace('data-regex="forsenSmug"', 'data-regex="bad|name"'))
        self.assertEqual([e['name'] for e in pack['emotes']], ['forsenCorn'])
        self.assertEqual(pack['excluded'][0]['id'], '304412445')
        self.assertIn('name', pack['excluded'][0]['reason'])

    def test_deduplicates_name_aliases_in_global_catalog(self):
        html = GLOBAL + GLOBAL.replace('354', '355')
        pack = normalize_twitch(html, image_reader=lambda _: b'\x89PNG\r\n\x1a\n')
        self.assertEqual([e['name'] for e in pack['emotes']], ['4Head', 'DinoDance'])
        self.assertTrue(any(e['id'] == '355' for e in pack['excluded']))

    def test_retains_literal_html_escaped_punctuation_names(self):
        html = CHANNEL.replace('data-regex="forsenSmug"', 'data-regex="&lt;3"')
        self.assertEqual(self.channel(html)['emotes'][0]['name'], '<3')

    def test_rejects_invalid_login_and_id_before_constructing_paths(self):
        for kwargs in ({'twitch_id': '../22', 'login': 'forsen'},
                       {'twitch_id': '22', 'login': '../forsen'},
                       {'twitch_id': '22'}, {'login': 'forsen'}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                normalize_twitch(CHANNEL, **kwargs)

    def test_rejects_unrecognized_image_content(self):
        with self.assertRaises(ValueError):
            normalize_twitch(GLOBAL, image_reader=lambda _: b'<html>Error</html>')


if __name__ == '__main__':
    unittest.main()
