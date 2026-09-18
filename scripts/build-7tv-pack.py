#!/usr/bin/env python3
"""Build a TwitchEmotes emote pack from a Twitch channel's active 7TV emote set.

Downloads every emote in the set, converts it to the addon's texture format
(32 px tall RLE TGA, power-of-two canvas, animated emotes as a vertical sprite
sheet of at most --max-frames frames) and writes Emotes_<pack>.lua, which adds
the emotes to the addon's lookup tables and groups them for the minimap menu.

Usage: scripts/build-7tv-pack.py --login erobb221 --pack erobb221
Requires Pillow. Downloads are cached under .cache/7tv/ so re-runs only fetch
new or changed emotes.
"""
import argparse
import concurrent.futures
import datetime as dt
import json
import math
import re
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image, ImageSequence, features

FRAME_HEIGHT = 32
CANVAS_WIDTHS = (32, 64, 128)
MAX_SHEET_HEIGHT = 2048
# The addon splits chat on these characters and then uses the emote name as a raw Lua
# pattern, so names outside this set can never match or would break the pattern.
SAFE_NAME = re.compile(r"^[A-Za-z0-9_:]+$")
GROUP_SIZE = 44
USER_AGENT = "WowForeverTwitchEmotes/1.0 (+https://github.com/TheMizeGuy/WowForeverTwitchEmotes)"


def http_get(url, retries=4):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except Exception as exc:  # noqa: BLE001 - retry on any transport error
            last = exc
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"download failed for {url}: {last}")


def resolve_twitch_id(login):
    data = json.loads(http_get(f"https://api.ivr.fi/v2/twitch/user?login={login}"))
    if not data:
        raise SystemExit(f"no Twitch user named {login}")
    return data[0]["id"]


def fetch_emote_set(twitch_id):
    user = json.loads(http_get(f"https://7tv.io/v3/users/twitch/{twitch_id}"))
    emote_set = user.get("emote_set") or {}
    if not emote_set.get("emotes"):
        raise SystemExit("7TV returned no active emote set for that channel")
    return user, emote_set


def pick_file(emote, webp_ok):
    data = emote["data"]
    files = {f["name"]: f for f in data["host"]["files"]}
    animated = bool(data.get("animated"))
    if webp_ok and "2x.webp" in files:
        name = "2x.webp"
    elif animated and "2x.gif" in files:
        name = "2x.gif"
    elif "2x.png" in files:
        name = "2x.png"
    else:
        name = next(iter(files)) if files else None
    if name is None:
        return None, None
    return "https:" + data["host"]["url"] + "/" + name, name.rsplit(".", 1)[1]


def next_pow2(n):
    return 1 << max(0, math.ceil(math.log2(max(1, n))))


def load_frames(path):
    """Return (frames as RGBA images, per-frame durations in ms)."""
    frames, durations = [], []
    with Image.open(path) as img:
        for frame in ImageSequence.Iterator(img):
            frames.append(frame.convert("RGBA"))
            durations.append(int(frame.info.get("duration") or 100))
    return frames, durations


def fit_frame(frame, canvas_w):
    """Scale a frame to FRAME_HEIGHT tall (or narrower if too wide) and center it."""
    w, h = frame.size
    scale = FRAME_HEIGHT / h
    new_w = max(1, round(w * scale))
    new_h = FRAME_HEIGHT
    if new_w > canvas_w:
        scale = canvas_w / w
        new_w = canvas_w
        new_h = max(1, round(h * scale))
    resized = frame.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_w, FRAME_HEIGHT), (0, 0, 0, 0))
    canvas.paste(resized, ((canvas_w - new_w) // 2, (FRAME_HEIGHT - new_h) // 2), resized)
    return canvas


def canvas_width_for(frame):
    w, h = frame.size
    scaled_w = round(w * FRAME_HEIGHT / h)
    for cw in CANVAS_WIDTHS:
        if scaled_w <= cw:
            return cw
    return CANVAS_WIDTHS[-1]


def subsample(frames, durations, max_frames):
    total_ms = sum(durations)
    if len(frames) <= max_frames:
        return frames, total_ms
    picks = [round(i * (len(frames) - 1) / (max_frames - 1)) for i in range(max_frames)]
    return [frames[i] for i in picks], total_ms


def convert(src, dest, max_frames):
    """Write dest TGA; return metadata dict for animated emotes or the size suffix for static."""
    frames, durations = load_frames(src)
    canvas_w = canvas_width_for(frames[0])
    if len(frames) <= 1:
        fit_frame(frames[0], canvas_w).save(dest, format="TGA", rle=True)
        return {"static": True, "size": f"28:{28 * canvas_w // FRAME_HEIGHT}"}
    frames, total_ms = subsample(frames, durations, max_frames)
    n = len(frames)
    sheet_h = max(64, next_pow2(n * FRAME_HEIGHT))
    if sheet_h > MAX_SHEET_HEIGHT:
        raise ValueError(f"sheet height {sheet_h} exceeds {MAX_SHEET_HEIGHT}")
    sheet = Image.new("RGBA", (canvas_w, sheet_h), (0, 0, 0, 0))
    for i, frame in enumerate(frames):
        sheet.paste(fit_frame(frame, canvas_w), (0, i * FRAME_HEIGHT))
    sheet.save(dest, format="TGA", rle=True)
    framerate = n / max(0.1, total_ms / 1000.0)
    return {
        "static": False,
        "nFrames": n,
        "frameWidth": canvas_w,
        "frameHeight": FRAME_HEIGHT,
        "imageWidth": canvas_w,
        "imageHeight": sheet_h,
        "framerate": round(framerate, 2),
    }


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_existing_keys(emotes_lua):
    text = emotes_lua.read_text(encoding="utf-8", errors="replace")
    return set(re.findall(r'^\s*\["([^"]+)"\]\s*=', text, flags=re.M))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--login", help="Twitch login of the channel")
    ap.add_argument("--twitch-id", help="Twitch user id (skips the login lookup)")
    ap.add_argument("--pack", required=True, help="pack name: texture folder and Lua file suffix")
    ap.add_argument("--addon-dir", default=str(Path(__file__).resolve().parent.parent / "TwitchEmotes"))
    ap.add_argument("--cache-dir", default=str(Path(__file__).resolve().parent.parent / ".cache" / "7tv"))
    ap.add_argument("--max-frames", type=int, default=MAX_SHEET_HEIGHT // FRAME_HEIGHT)
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()

    if not args.twitch_id and not args.login:
        ap.error("pass --login or --twitch-id")
    twitch_id = args.twitch_id or resolve_twitch_id(args.login)
    user, emote_set = fetch_emote_set(twitch_id)
    webp_ok = bool(features.check("webp"))
    print(f"set {emote_set['id']} ({emote_set.get('name')}): {len(emote_set['emotes'])} emotes; webp decode: {webp_ok}")

    addon_dir = Path(args.addon_dir)
    tex_dir = addon_dir / "Emotes" / args.pack
    tex_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    existing = read_existing_keys(addon_dir / "Emotes.lua")

    jobs, skipped_names, seen_files, seen_emotes = [], [], {}, set()
    for emote in emote_set["emotes"]:
        name = emote["name"]
        # 7TV occasionally lists the same emote twice; keep the first occurrence.
        if (emote["id"], name) in seen_emotes:
            continue
        seen_emotes.add((emote["id"], name))
        if not SAFE_NAME.match(name):
            skipped_names.append(name)
            continue
        url, ext = pick_file(emote, webp_ok)
        if not url:
            skipped_names.append(name)
            continue
        file_stem = re.sub(r"[^A-Za-z0-9_-]", "_", name)
        key = file_stem.lower()
        # Windows paths are case-insensitive, so "Pog" and "POG" need distinct file names.
        if key in seen_files:
            seen_files[key] += 1
            file_stem = f"{file_stem}_{seen_files[key]}"
        else:
            seen_files[key] = 1
        jobs.append((emote, name, url, cache_dir / f"{emote['id']}.{ext}", tex_dir / f"{file_stem}.tga"))

    def fetch(job):
        _emote, _name, url, cached, _dest = job
        if not cached.exists() or cached.stat().st_size == 0:
            cached.write_bytes(http_get(url))
        return job

    print(f"downloading {len(jobs)} emotes ...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        list(pool.map(fetch, jobs))

    results, failures = [], []
    for emote, name, _url, cached, dest in jobs:
        try:
            meta = convert(cached, dest, args.max_frames)
        except Exception as exc:  # noqa: BLE001 - report and continue with the rest of the set
            failures.append((name, str(exc)))
            continue
        results.append((name, dest.name, meta))

    results.sort(key=lambda r: r[0].lower())
    # Remove textures from an earlier run that are no longer in the set.
    keep = {fname for _n, fname, _m in results}
    stale = [p for p in tex_dir.glob("*.tga") if p.name not in keep]
    for p in stale:
        p.unlink()
    if stale:
        print(f"removed {len(stale)} stale textures")
    overrides = sorted(n for n, _f, _m in results if n in existing)
    prefix = f"Interface\\\\AddOns\\\\TwitchEmotes\\\\Emotes\\\\{args.pack}\\\\"
    today = dt.date.today().isoformat()
    lines = [
        f"-- Generated by scripts/build-7tv-pack.py on {today} from the 7TV emote set",
        f"-- {emote_set['id']} ({emote_set.get('name')}) of Twitch channel {user.get('username')} ({twitch_id}).",
        "-- Do not edit by hand; re-run the script to refresh.",
        f"local P = \"{prefix}\"",
        "local pack = TwitchEmotes_defaultpack",
        "local names = TwitchEmotes_emoticons",
        "local anim = TwitchEmotes_animation_metadata",
        "",
    ]
    for name, fname, meta in results:
        key = lua_string(name)
        if meta["static"]:
            lines.append(f"pack[{key}] = P .. \"{fname}:{meta['size']}\"")
        else:
            lines.append(f"pack[{key}] = P .. \"{fname}\"")
            lines.append(
                f"anim[P .. \"{fname}\"] = {{nFrames = {meta['nFrames']}, frameWidth = {meta['frameWidth']}, "
                f"frameHeight = {meta['frameHeight']}, imageWidth = {meta['imageWidth']}, "
                f"imageHeight = {meta['imageHeight']}, framerate = {meta['framerate']}}}"
            )
        lines.append(f"names[{key}] = {key}")
    lines.append("")
    lines.append("-- Minimap menu groups: alphabetical chunks, each entry is {label, emote, emote, ...}.")
    lines.append(f"TwitchEmotes_{args.pack}_groups = {{")
    names_sorted = [n for n, _f, _m in results]
    for i in range(0, len(names_sorted), GROUP_SIZE):
        chunk = names_sorted[i:i + GROUP_SIZE]
        label = f"{chunk[0]} - {chunk[-1]}" if len(chunk) > 1 else chunk[0]
        lines.append("\t{" + ", ".join([lua_string(label)] + [lua_string(n) for n in chunk]) + "},")
    lines.append("}")
    lines.append("")
    lines.append("-- Register the pack for the minimap menu (TwitchEmotes.lua reads TwitchEmotes_pack_menus).")
    lines.append("TwitchEmotes_pack_menus = TwitchEmotes_pack_menus or {}")
    lines.append(
        f"table.insert(TwitchEmotes_pack_menus, {{label = {lua_string(user.get('username', args.pack) + ' (7TV)')}, "
        f"groups = TwitchEmotes_{args.pack}_groups}})"
    )
    lines.append("")
    (addon_dir / f"Emotes_{args.pack}.lua").write_text("\n".join(lines), encoding="utf-8")

    animated = sum(1 for _n, _f, m in results if not m["static"])
    print(f"wrote {len(results)} emotes ({animated} animated) to Emotes/{args.pack}/ and Emotes_{args.pack}.lua")
    print(f"overrides {len(overrides)} existing emote names: {', '.join(overrides[:40])}{' ...' if len(overrides) > 40 else ''}")
    if skipped_names:
        print(f"skipped {len(skipped_names)} names the addon cannot match: {', '.join(skipped_names)}")
    if failures:
        print(f"FAILED {len(failures)}:")
        for name, err in failures:
            print(f"  {name}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
