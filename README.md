# Twitch Emotes WoW Forever

Twitch Emotes for the World of Warcraft: Forever client (beta build 1.60.x, interface 16001).

This is a port of the retail "Twitch Emotes v2" addon. Type an emote name such as `KEKW` or
`peepoHappy` in chat and the client replaces it with the image. Typing `:` opens autocomplete.
The addon also handles animated emotes, a minimap menu of emote packs, and usage statistics.

## Status

Beta. Built against WoW Forever build 1.60.1.69893 (`wow_classic_beta`, September 2026). The
client is a fork of the retail 12.x engine, so the addon runs the same code paths it uses on
retail Midnight.

## Install

Copy the `TwitchEmotes` folder into the Forever client's AddOns directory:

```
C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\TwitchEmotes
```

The folder must keep the name `TwitchEmotes`: every emote texture path inside the addon points
at `Interface\AddOns\TwitchEmotes\Emotes\...`.

A brand-new addon is picked up at the character selection screen, not by `/reload`. Log out to
character select and back in. After editing a `.toc` file, restart the client.

`scripts/deploy.sh [ssh-host] [addons-dir]` streams the folder to a Windows machine over ssh
and checks the file count. `addons-dir` defaults to the path above and `ssh-host` to the
author's machine, so pass both when deploying to your own.

## Channel emote packs

On top of the upstream packs the addon ships two Twitch channels' active 7TV sets, generated on
2026-09-18:

| Pack | Emotes | Animated | Skipped names |
|---|---|---|---|
| graycen | 986 | 634 | 14 |
| erobb221 | 967 | 420 | 11 |

Channel emotes take precedence over upstream emotes of the same name, as they do on Twitch. The
packs load in the order above, so when both channels use the same name the erobb221 version
wins (72 names). Skipped names are ones the addon's word splitter can never match, such as
`!spin`, `DidHe?` or `plink-182`.

Each pack is a texture folder under `TwitchEmotes/Emotes/<pack>/` plus a generated
`TwitchEmotes/Emotes_<pack>.lua`, both produced by `scripts/build-7tv-pack.py`:

```
python3 scripts/build-7tv-pack.py --login erobb221 --pack erobb221
python3 scripts/build-7tv-pack.py --login graycen --pack graycen
```

The script needs Pillow. It downloads the current set (cached under `.cache/7tv/`), scales each
emote to 32 px tall on a power-of-two canvas, stacks animated emotes into a vertical sprite
sheet of at most 64 frames, writes RLE TGA files, prunes textures that left the set, and emits
the Lua tables plus alphabetical groups for the minimap menu. Re-run it whenever a channel's set
changes, then list the new `Emotes_<pack>.lua` in both TOCs. The two packs add about 210 MB of
textures to the addon.

## What changed from the retail addon

- Two `.toc` files at interface 16001: `TwitchEmotes_Camelot.toc` (Forever's own suffix) and
  `TwitchEmotes.toc` (fallback). The Classic-flavor TOCs were dropped.
- The chat pre-send hook (`ChatFrame.OnEditBoxPreSendText`) is chosen by feature detection
  instead of `build >= 120000`. Forever reports build 1.60.x but has the Midnight chat
  messaging restrictions, so the old `C_ChatInfo.SendChatMessage` wrapper would have been
  blocked in combat.
- No hard dependency on CVar-gated deprecated globals: `getglobal` became `_G[...]`, chat
  filters register through `ChatFrameUtil.AddMessageEventFilter`, and the `BNSendWhisper`
  wrapper is skipped on the 12.x engine where the pre-send hook already covers Battle.net
  whispers. Where an old global is still named, it is a fallback for other clients.
- Chat filters are registered only for `CHAT_MSG_*` settings keys instead of every key in the
  settings table.
- Hooks on `ItemTextPageText`, `OpenMailBodyText` and `SendMail` are guarded so a missing frame
  or API cannot abort the addon at load. All three exist on Forever.
- Pressing Tab while the emote suggestion box is open no longer cycles whisper targets. The
  addon uses Blizzard's `ChatEdit_CustomTabPressed` hook, chained to any existing definition.
- The "Usage data" button closes the modern Settings panel.
- Animated emote frames may be wider than tall. The texture escape is built height first and
  the width follows the frame's aspect ratio, in chat, in the autocomplete list and in the
  minimap menu, which also shows frame 0 of an animated emote instead of its whole sheet.
- Channel packs appear as one minimap menu entry each, with alphabetical groups one level down.
- The retail and Classic code branches stay in place so upstream changes remain easy to merge.

## Credits and license

Twitch Emotes v2 is by Ren (ren9790) and Jons and is published on CurseForge under
"All Rights Reserved". The emote artwork belongs to the respective streamers and to the
Twitch, BTTV and FFZ creators; the channel packs are the channels' 7TV sets, owned by the emote
artists who uploaded them. This repository republishes the addon in full, emote art included,
with the compatibility changes listed above. It adds no license of its own to the upstream work.
