# Twitch Emotes WoW Forever

Animated emotes, a searchable visual browser, and chat completion for WoW Forever
(Camelot, interface 16001).

## In game

Open the window with `/te`, `/twitch`, or the minimap button. Browse channel groups,
search by name, save favorites, or revisit recently sent emotes. Each Twitch channel
has one group; provider-wide emotes appear under **General**. General, Graycen,
Forsen, Erobb221, xQc, and Asmongold start enabled. There is no automatic first-run
setup. Use **Channels** or **Settings > Choose channels** to change the selection.
Browse and search any installed channel, including disabled ones. Its **Enabled in
chat** checkbox controls display without leaving Browse. Enabled channels have a
purple highlight and checkmark in the group list.

Click an emote to insert its plain name into chat. Type a colon followed by a name
to see suggestions with emote image previews; use Tab or the arrow keys to select, Enter to accept, and Escape
to dismiss. Hover over a chat emote for its name and source; Shift-click to insert it.
The addon sends ordinary text, so other players do not need it to read your messages.

Click an emote in chat for its menu, then choose **Hide this emote** to display that
name as ordinary text across channels and remove it from autocomplete.
Restore individual names under **Browse > Hidden**
or **Settings > Hidden emotes**. Shift-click still inserts a name into your draft.
The text faces `:)`, `:(`, `:O`, `:D`, and `D:` start hidden. Restoring one overrides
that default.

The purple and charcoal window includes a channel sidebar and a channel picker.
Additional channels can be enabled individually. When names overlap,
Settings lets you choose a preferred channel for the image. Identical provider
artwork shares a single texture file across packs.

Settings include an emote-size slider with a live preview (12–40 pixels, 28 by default),
chat channels, enabled groups, animation, the playback
limit (15, 30, or 60 FPS; 60 by default), and minimap visibility. Drag the minimap button to move it.
Animation follows each source's timing; the playback limit cannot add motion absent
from the source. A hovered chat line pauses its animation to keep the tooltip stable;
other visible lines keep animating. Editor completion and insertion pause when WoW restricts scripted
chat input.

## Install

Place the `TwitchEmotes` folder in the Forever client's `Interface/AddOns` directory.
Keep the folder name `TwitchEmotes`. **Fully exit and restart WoW after installing
3.0.0**, including updates from an earlier build: `/reload` alone can leave newly
installed textures as green boxes until the client restarts. Later Lua-only updates
take `/reload`; new textures or a changed TOC require a restart. Preferences and usage are saved
in `ForeverEmotesDB`; compatible existing preferences are imported automatically.
If preferences reset, `/te status` reports the settings received during startup and
whether the active settings still match WoW's saved table.

**Forever beta settings issue:** the current client can write addon settings without
loading them again after a reload or restart. Until Blizzard fixes this, missing
settings fall back to the six groups above. Manual changes work for the current
session but may reset. Automatic first-run setup is postponed until saving works.

## Development

The runtime uses native WoW controls and chat filters. A literal matcher protects
links and URLs. A bounded message cache shares work between chat windows. Animation
updates only visible animated lines and stops its timer when no work remains. The
browser recycles its visible rows.

Provider artwork is downloaded and converted by `scripts/build-7tv-pack.py`. It
uses 64-pixel frames, up to 256 animation frames per sprite grid, and provider
originals at the highest offered resolution. It requires Python 3 and Pillow. Run `python3 scripts/build-7tv-pack.py --help` for pack
and cache options. Generated source records and hashes live in `packs/`.

After rebuilding packs, run `.venv/bin/python scripts/optimize-textures.py --budget BYTES`
from a virtual environment built with `python3 -m venv .venv && .venv/bin/pip install -r
scripts/requirements-build.txt` (Pillow, numpy, imagequant, and the optional libdeflate
binding, which sizes candidates the way the release ZIP compresses them; zlib level 9
stands in without it). The optimizer reads every lossless 64 px TGA sheet from `--source`
(the `dist/TwitchEmotes-3.0.0-tga-baseline.zip` archive when present, otherwise the addon
`Media` directory) and never from a converted BLP. Each animation is snapped (alpha 5 and
below becomes 0, 250 and above becomes 255), temporally stabilised (`--hold 3`, two passes
around the loop seam, identical source frames forced identical), and folded so exact and
near-duplicate frames (`--near 3:1.0`) become one stored cell replayed through a
`sequence` list in `packs/*.json`; `fps` and the number of playback steps never change.
Every height in `--heights 64,48,40,32` crossed with every run-merge threshold in
`--merges 3,5,8` is then encoded as a candidate rung: premultiplied Lanczos resample, the
widest sheet layout the runtime accepts, a libimagequant palette without dithering, run
merging that re-points a pixel to a neighbouring or previous-frame palette index while
the added error stays under the threshold (longer deflate matches), and an indexed BLP2
with the exact 8-bit alpha plane. A rung whose visible-pixel RGB RMS error on black or
white exceeds 5/255 ships as the stabilised TGA instead. Statics keep their height and become BLP2 only when that is smaller within
the same error limit. Each rung is scored by the SSIM of its decoded
frames against the 64 px source (luma at 1440p and 40 UI units), so palette, merge, and
resample loss all count. With a `--budget`, animations start at 64 px, threshold 3, and
step down one at a time to the smaller rung with the least SSIM loss per byte saved, never
below `--floor 0.85`, until the total fits or nothing above the floor is left; the summary
and `--report` JSON show totals, the height and threshold mix, SSIM statistics, and how
many TGAs remain. Candidates are
cached in `--cache` (`.cache/optimize`) by source hash and parameters, so another budget
re-allocates without re-encoding. The optimizer updates every shared reference, records
each entry's source sheet under `lossless`, regenerates the pack Lua, and stages
replacements with rollback; `--dry-run` only measures. Output is deterministic for the
same input and parameters.

Run focused checks with `luajit tests/core_spec.lua`, `luajit tests/runtime_spec.lua`,
and `luajit tests/ui_spec.lua`. The external WoW boundary tests complement in-client
testing; they do not emulate Blizzard's restricted execution engine or renderer.
Run `luajit tests/integration_spec.lua` to load the actual TOC and all packs through
the external WoW boundary. `python3 scripts/package.py` verifies every texture
hash, format, TOC reference, playback sequence, and generated Lua manifest; add
`--output dist/TwitchEmotes-3.0.0.zip` to create a release archive. Members are
deflated in parallel (`--workers`) with libdeflate level 12, zopfli, or zlib level 9,
whichever `--compressor auto` finds installed, always as an ordinary ZIP with fixed
timestamps, so one install packs to the same bytes every time. The finished archive
is reopened to confirm every member's CRC and size.
`python3 tests/test_package.py` covers that verification, each encoder, and the
archive writer.
`.venv/bin/python tests/test_texture_optimizer.py` checks format validation, transparency,
temporal cleanup, sequences, layout, allocation, shared references, quality fallback,
and repeatable conversion. Run
`python3 tests/test_pack_builder.py` after changing the builder or its publication logic.

`scripts/deploy.sh [ssh-host] [addons-dir]` stages and verifies every file before
replacing this addon's folder. It defaults to the author's WoW Forever beta client
on `mizepc`.

## Rights

Copyright (c) 2026 TheMizeGuy. **All Rights Reserved** for the original code and
documentation. See [LICENSE](LICENSE) for personal-use permission and restrictions.
Emote artwork is separate; see [ASSET-NOTICES.md](ASSET-NOTICES.md).
