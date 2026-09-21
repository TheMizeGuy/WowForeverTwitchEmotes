# Artwork and attribution

The CurseForge project icon is a high-resolution illustrated remaster of
[FeelsOkayMan on 7TV](https://7tv.app/emotes/01GB46137R000BJ5HR8F6XV8J1), whose
provider account is TrippyColour. Its source and final image hashes are recorded
in `assets/curseforge-icon.json`. The underlying emote artwork remains with its
respective rights holders and is excluded from TheMizeGuy's code copyright.

The minimap's white Twitch Glitch logo comes from [Twitch's official brand
assets](https://brand.twitch.com/). It remains the property of Twitch Interactive,
Inc. The source archive, original image hash and converted texture hash are
recorded in `assets/twitch-glitch.json`. The logo is used inside the addon to
identify Twitch emotes; this addon is not affiliated with or endorsed by Twitch.
TheMizeGuy's code copyright does not cover the Twitch logo.

The emote artwork in `TwitchEmotes/Media/` comes from Twitch, 7TV, BetterTTV, and
FrankerFaceZ. TheMizeGuy's code copyright does not claim ownership of this
artwork or grant rights to it. Provider accounts identify the attribution
available through each catalog; an uploader account is not a verification of
original authorship.

Each file in `packs/` records the provider catalog, emote and set-entry IDs,
aliases, source page and download URL, available creator attribution, decoded
source dimensions, converted dimensions, animation timing, and SHA-256 hashes
of both source bytes and the shipped texture. Identical provider artwork IDs
share one texture across aliases and packs.

| Pack | Catalog | Manifest |
| --- | --- | --- |
| 7TV Global | [7TV global API](https://7tv.io/v3/emote-sets/global) | [seventv_global.json](packs/seventv_global.json) |
| BTTV Global | [BetterTTV global API](https://api.betterttv.net/3/cached/emotes/global) | [bttv_global.json](packs/bttv_global.json) |
| FFZ Global | [FrankerFaceZ global API](https://api.frankerfacez.com/v1/set/global) | [ffz_global.json](packs/ffz_global.json) |
| Graycen | [7TV channel API](https://7tv.io/v3/users/twitch/25743612) | [graycen.json](packs/graycen.json) |
| erobb221 | [7TV channel API](https://7tv.io/v3/users/twitch/96858382) | [erobb221.json](packs/erobb221.json) |
| Ahlaundoh | [7TV channel API](https://7tv.io/v3/users/twitch/32093909) | [ahlaundoh.json](packs/ahlaundoh.json) |
| summit1g | [7TV channel API](https://7tv.io/v3/users/twitch/26490481) | [summit1g.json](packs/summit1g.json) |
| Ziqoftw | [7TV channel API](https://7tv.io/v3/users/twitch/20567961) | [ziqoftw.json](packs/ziqoftw.json) |
| Xaryu | [7TV channel API](https://7tv.io/v3/users/twitch/32085830) | [xaryu.json](packs/xaryu.json) |
| Pikabooirl | [BTTV channel API](https://api.betterttv.net/3/cached/users/twitch/27992608), [FFZ room API](https://api.frankerfacez.com/v1/room/id/27992608) | [bttv_pikabooirl.json](packs/bttv_pikabooirl.json), [ffz_pikabooirl.json](packs/ffz_pikabooirl.json) |
| Swifty | [BTTV channel API](https://api.betterttv.net/3/cached/users/twitch/23524577) | [bttv_swifty.json](packs/bttv_swifty.json) |
| Twitch Global | [Public Twitch catalog](https://twitchemotes.com/) | [twitch_global.json](packs/twitch_global.json) |
| Native Twitch channels | [Verified channel identities and catalog URLs](scripts/twitch-channels.json) | `packs/twitch_<login>.json` |

Native Twitch names and emote IDs come from the public third-party catalog
at twitchemotes.com. Every native image is downloaded from Twitch's original
`static-cdn.jtvnw.net` CDN. Channel accounts are listed as provider owners;
the catalog does not identify individual artists. Seven channel identities
without usable native metadata are recorded in the channel configuration's
`unavailable` list, with the observed reason.

Pikabooirl's 7TV lookup returned no account, and Swifty's verified 7TV connection
had no active emote set. Their available BTTV/FFZ catalogs supply the additional
provider emotes. Swifty's FFZ set was empty. Both channels also have native
Twitch packs. Summit's unavailable `CenaPls` image and conflicting aliases
within the Summit and Xaryu catalogs are recorded in their manifests; the later
catalog entry determines a duplicate alias. Identical names in separate packs
remain available under their channel groups.

7TV attributes artwork to the owner field when present. Some entries supply
no owner; those are marked `not supplied`. BetterTTV's public global catalog
supplies owner IDs without display names; those are retained as `BTTV account
<ID>`. FrankerFaceZ uses an explicit artist field when supplied, falling back
to the owner. Modifier effects that require provider-specific rendering are
excluded from the BetterTTV and FrankerFaceZ packs and listed in their manifests.
7TV artwork, including zero-width artwork, is presented as ordinary standalone
emotes; overlay composition is not part of this addon.

The builder requests the highest available source resolution: 4x, then 3x, 2x,
and 1x for 7TV and FrankerFaceZ, BetterTTV's 3x images, and Twitch's 3.0 images.
Source downloads are
cached by their exact URL so a smaller image cannot stand in for a larger one.
Images are scaled into 64-pixel-high frames, preserving their proportions within
a maximum width of 256 pixels, with transparent padding where needed.

Animations retain up to 256 frames and are sampled at a uniform rate of at most
60 FPS, preserving positive source frame durations. Missing or nonpositive frame
durations use a 100-millisecond fallback; the manifest records both source and
playback duration and marks that normalization. Loops too short for two samples
at 60 FPS use a static preview. Uniformly timed sources retain
their native frame count unless a limit requires fewer samples; varying frame
durations may require repeated images on the uniform timeline. Frames occupy a
row-major grid with an explicit column count and padded cell width. Each texture
uses a power-of-two canvas no larger than 2048 by 2048 pixels. Static artwork uses
RGBA TGA. Suitable animations use indexed BLP2 with a shared 256-color palette
and an exact 8-bit alpha plane; animations exceeding the visible-pixel RGB error
limit retain TGA. This encoding changes neither frame count nor source timing.
Semi-transparent pixels retain straight alpha.

Public availability and attribution do not establish a redistribution license.
This repository does not assert a blanket license over provider artwork. Rights
remain with the applicable rights holders. The provider source links and hashes
make the specific bundled files identifiable for attribution and removal.
