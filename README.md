# WowForeverTwitchEmotes

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
- The retail and Classic code branches stay in place so upstream changes remain easy to merge.

## Credits and license

Twitch Emotes v2 is by Ren (ren9790) and Jons and is published on CurseForge under
"All Rights Reserved". The emote artwork belongs to the respective streamers and to the
Twitch, BTTV and FFZ creators. This repository republishes the addon in full, emote art
included, with the compatibility changes listed above. It adds no license of its own to the
upstream work.
