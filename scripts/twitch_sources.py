# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Normalize public Twitch catalog metadata without OAuth or bundled assets.

The public HTML catalog at twitchemotes.com supplies names, Twitch IDs and
CDN URLs. Artwork is fetched separately from Twitch's original CDN. A channel
account is attributed as the provider owner; this does not identify its artist
or imply permission to redistribute its artwork.
"""
from html.parser import HTMLParser
import re
import unicodedata
from urllib.parse import urlsplit


CATALOG_ORIGIN = 'https://twitchemotes.com'
TWITCH_CDN_HOST = 'static-cdn.jtvnw.net'
_EMOTE_ID = r'(?:[0-9]{1,20}|emotesv2_[a-f0-9]{32})'


class _CatalogParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.anchor = None
        self.channels = set()
        self.emotes = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'a':
            self.anchor = attrs.get('href')
            match = re.fullmatch(r'https://(?:www\.)?twitch\.tv/([A-Za-z0-9_]+)', self.anchor or '')
            if match:
                self.channels.add(match[1].lower())
        elif tag == 'img' and 'emote' in attrs.get('class', '').split():
            self.emotes.append((attrs, self.anchor))

    def handle_endtag(self, tag):
        if tag == 'a':
            self.anchor = None


def _text(value, limit=256):
    if (not isinstance(value, str) or not value or len(value.encode('utf-8')) > limit
            or any(c == '|' or unicodedata.category(c).startswith('C') for c in value)):
        raise ValueError('unsafe metadata text')
    return value


def _image_format(data):
    if isinstance(data, bytes):
        if data.startswith(b'\x89PNG\r\n\x1a\n'):
            return 'png'
        if data.startswith((b'GIF87a', b'GIF89a')):
            return 'gif'
        if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
            return 'webp'
    raise ValueError('Twitch image response is not PNG, GIF or WebP')


def normalize_twitch(html, *, twitch_id=None, login=None, title=None, priority=20, image_reader=None):
    """Return a builder pack from a public channel page or the global home page.

    ``image_reader(url) -> bytes`` is required for v1 catalog images because
    their static thumbnails do not indicate whether an animated original exists.
    The reader is the sole network boundary; it can use the caller's cache.
    Channel pages with explicit v2 formats do not need an image reader.
    """
    if twitch_id is None and login is None:
        channel = False
        pack_id, group, group_title = 'twitch_global', 'general', 'General'
        title = _text(title or 'Twitch Global')
        catalog_url = CATALOG_ORIGIN + '/'
        source = catalog_url
        emote_prefix = '/global/emotes/'
    else:
        channel = True
        if (not isinstance(twitch_id, str) or not re.fullmatch(r'[0-9]{1,20}', twitch_id)
                or not isinstance(login, str) or not re.fullmatch(r'[A-Za-z0-9_]{1,25}', login)):
            raise ValueError('a channel requires a numeric Twitch ID and a valid login')
        login = login.lower()
        title = _text(title or login)
        pack_id, group, group_title = 'twitch_' + login, login, title
        catalog_url = CATALOG_ORIGIN + '/channels/' + twitch_id
        source = 'https://www.twitch.tv/' + login
        emote_prefix = '/channels/' + twitch_id + '/emotes/'

    if isinstance(html, bytes):
        html = html.decode('utf-8')
    if not isinstance(html, str) or not html or len(html) > 16 * 1024 * 1024:
        raise ValueError('empty or oversized Twitch catalog')
    parser = _CatalogParser()
    parser.feed(html)
    parser.close()
    if channel and parser.channels != {login}:
        raise ValueError('Twitch catalog channel identity does not match requested login')
    if not parser.emotes:
        raise ValueError('Twitch catalog has no emote metadata')

    pack = {'id': pack_id, 'title': title, 'provider': 'Twitch', 'priority': priority,
            'source': source, 'metadata_api': catalog_url, 'group': group,
            'groupTitle': group_title, 'emotes': [], 'excluded': []}
    seen_ids, seen_names = set(), set()
    for attrs, link in parser.emotes:
        identifier, name = attrs.get('data-image-id', ''), attrs.get('data-regex', '')
        if not re.fullmatch(_EMOTE_ID, identifier):
            raise ValueError('invalid Twitch emote ID')
        if link not in (emote_prefix + identifier, CATALOG_ORIGIN + emote_prefix + identifier):
            raise ValueError('Twitch emote link does not match its channel and ID')
        parsed = urlsplit(attrs.get('src', ''))
        if (parsed.scheme != 'https' or parsed.netloc != TWITCH_CDN_HOST
                or parsed.query or parsed.fragment):
            raise ValueError('untrusted Twitch image URL')
        legacy = re.fullmatch(r'/emoticons/v1/(' + _EMOTE_ID + r')/(?:1\.0|2\.0|3\.0)', parsed.path)
        modern = re.fullmatch(r'/emoticons/v2/(' + _EMOTE_ID
                              + r')/(static|animated|default)/(?:light|dark)/(?:1\.0|2\.0|3\.0)', parsed.path)
        match = legacy or modern
        if not match or match[1] != identifier:
            raise ValueError('Twitch image path does not match its emote ID')
        try:
            _text(name, 128)
            if any(c.isspace() for c in name):
                raise ValueError('name contains whitespace')
        except ValueError:
            pack['excluded'].append({'id': identifier, 'name': name, 'reason': 'unsafe emote name'})
            continue
        if identifier in seen_ids or name in seen_names:
            pack['excluded'].append({'id': identifier, 'name': name, 'reason': 'duplicate emote ID or name'})
            continue
        mode = 'default' if legacy else modern[2]
        download = f'https://{TWITCH_CDN_HOST}/emoticons/v2/{identifier}/{mode}/dark/3.0'
        if mode == 'default':
            if image_reader is None:
                raise ValueError('legacy Twitch images require image_reader to verify their actual format')
            extension = _image_format(image_reader(download))
        else:
            extension = 'gif' if mode == 'animated' else 'png'
        pack['emotes'].append({'id': 'twitch:' + identifier, 'provider': 'twitch',
                               'provider_id': identifier, 'name': name,
                               'source': CATALOG_ORIGIN + emote_prefix + identifier,
                               'download': download, 'format': extension,
                               'creator': title if channel else 'Not supplied by provider',
                               'creator_id': twitch_id if channel else None,
                               'attribution': 'provider owner' if channel else 'not supplied'})
        seen_ids.add(identifier)
        seen_names.add(name)
    return pack
