#!/usr/bin/env python3
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""Verify the installable addon and optionally create a release ZIP."""
import argparse
import hashlib
import importlib
import json
import multiprocessing
import os
from pathlib import Path
import runpy
import struct
import subprocess
import zipfile
import zlib

from texture_formats import texture_dimensions

COMPRESSORS = ('libdeflate', 'zopfli', 'zlib')
ENCODER_MODULES = {'libdeflate': 'deflate', 'zopfli': 'zopfli.zlib', 'zlib': 'zlib'}
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def compressor_module(compressor):
    """Return the module backing one --compressor choice, or None when it is not installed."""
    try:
        return importlib.import_module(ENCODER_MODULES[compressor])
    except ImportError:
        return None


def select_compressor(choice):
    if choice == 'auto':
        return next(name for name in COMPRESSORS if compressor_module(name) is not None)
    if compressor_module(choice) is None:
        raise ValueError('compressor is not installed: ' + choice)
    return choice


def deflate_raw(data, compressor):
    """Compress to a raw DEFLATE stream, the payload a method-8 ZIP member carries."""
    module = compressor_module(compressor)
    if compressor == 'libdeflate':
        return module.deflate_compress(data, 12)
    if compressor == 'zopfli':
        return module.compress(data, numiterations=15, blocksplittingmax=0)[2:-4]
    return module.compress(data, 9)[2:-4]


def compress_member(job):
    """Deflate one member in a worker process, keeping the original bytes when deflate loses."""
    name, path, compressor = job
    data = Path(path).read_bytes()
    blob = deflate_raw(data, compressor)
    if len(blob) >= len(data):
        return name, zipfile.ZIP_STORED, zlib.crc32(data), len(data), data
    return name, zipfile.ZIP_DEFLATED, zlib.crc32(data), len(data), blob


def compressed_members(jobs, workers):
    if workers < 2:
        yield from map(compress_member, jobs)
        return
    with multiprocessing.Pool(workers) as pool:
        yield from pool.imap(compress_member, jobs, chunksize=1)


class Precompressed:
    """Pass-through encoder: zipfile stores the payload and counts it as the compressed size."""

    def compress(self, data):
        return data

    def flush(self):
        return b''


def write_precompressed(archive, name, method, crc, size, blob):
    """Add already-deflated bytes as an ordinary ZIP member with a fixed timestamp."""
    info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
    info.compress_type = method
    info.create_system = 3
    info.external_attr = 0o644 << 16
    with archive.open(info, 'w') as member:
        member._compressor = Precompressed()
        member.write(blob)
        member._crc, member._file_size = crc, size
    return info


def audit_zip(output, root, names):
    """Read the finished archive back and compare every member with its source file."""
    with zipfile.ZipFile(output) as archive:
        corrupt = archive.testzip()
        if corrupt is not None:
            raise ValueError('corrupt ZIP member: ' + corrupt)
        members = archive.infolist()
        if [member.filename for member in members] != names:
            raise ValueError('ZIP members differ from the verified install')
        for member in members:
            data = (root / member.filename).read_bytes()
            if member.file_size != len(data) or member.CRC != zlib.crc32(data):
                raise ValueError('ZIP member differs from its source file: ' + member.filename)
            if member.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise ValueError('unsupported compression method: ' + member.filename)
            if member.extra or member.flag_bits & 0x08:
                raise ValueError('non-standard ZIP member: ' + member.filename)


def build_zip(root, output, files, compressor, workers):
    names = ['TwitchEmotes/' + name for name in files]
    jobs = [(name, root / name, compressor) for name in names]
    print(f'Compressing {len(jobs)} files with {compressor} in {workers} process(es)')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for member in compressed_members(jobs, workers):
            write_precompressed(archive, *member)
    audit_zip(output, root, names)
    size = output.stat().st_size
    print(f'Packaged {output} ({size / 1024**2:.1f} MiB, {size / 1000**2:.1f} MB)')
    return size


def playback_sequence(entry):
    """Return the entry's playback order over stored frame cells as a tuple, () when absent."""
    sequence = entry.get('sequence')
    if sequence is None:
        return ()
    if not isinstance(sequence, list) or not 2 <= len(sequence) <= 256 or entry['frames'] < 2:
        raise ValueError('invalid playback sequence: ' + entry['id'])
    if any(type(step) is not int or not 0 <= step < entry['frames'] for step in sequence):
        raise ValueError('invalid playback sequence: ' + entry['id'])
    return tuple(sequence)


def verify(root):
    addon = root / 'TwitchEmotes'
    toc = (addon / 'TwitchEmotes_Camelot.toc').read_text()
    if toc != (addon / 'TwitchEmotes.toc').read_text():
        raise ValueError('client and fallback TOCs differ')
    for directive in ('## Interface: 16001', '## Author: TheMizeGuy', '## X-License: All Rights Reserved'):
        if directive not in toc.splitlines():
            raise ValueError('missing TOC metadata: ' + directive)
    files = [line.strip().replace('\\', '/') for line in toc.splitlines()
             if line.strip() and not line.startswith('#')]
    if len(files) != len(set(files)):
        raise ValueError('duplicate TOC entries')
    required = {'Core.lua', 'Text.lua', 'Animation.lua', 'UI.lua', 'Completion.lua', 'Runtime.lua'}
    if {file for file in files if not file.startswith('Packs/')} != required:
        raise ValueError('unexpected runtime modules')
    for file in files:
        path = addon / file
        if not path.is_file() or path.is_symlink() or '..' in Path(file).parts:
            raise ValueError('missing or unsafe module: ' + file)
        subprocess.run(['luajit', '-bl', str(path)], check=True, stdout=subprocess.DEVNULL)
    expected = set(files) | {'TwitchEmotes.toc', 'TwitchEmotes_Camelot.toc', 'LICENSE', 'ASSET-NOTICES.md'}
    render_lua = runpy.run_path(str(Path(__file__).with_name('build-7tv-pack.py')))['render_lua']
    checked, aliases, groups = {}, 0, set()
    for file in files:
        if not file.startswith('Packs/'):
            continue
        pack = json.loads((root / 'packs' / (Path(file).stem + '.json')).read_text(encoding='utf-8'))
        if (addon / file).read_text(encoding='utf-8') != render_lua(pack, pack['emotes']):
            raise ValueError('generated Lua differs from pack manifest: ' + file)
        groups.add(pack.get('group', pack['id']))
        aliases += len(pack['emotes'])
        for entry in pack['emotes']:
            relative = entry['texture']
            if not relative.startswith('Media/') or '..' in Path(relative).parts:
                raise ValueError('unsafe texture path: ' + relative)
            expected.add(relative)
            keys = ('texture_sha256', 'width', 'height', 'frames', 'fps', 'cellWidth', 'columns',
                    'sheetWidth', 'sheetHeight')
            identity = tuple(entry[key] for key in keys) + (playback_sequence(entry),)
            if relative in checked:
                if checked[relative] != identity:
                    raise ValueError('conflicting shared texture: ' + relative)
                continue
            path = addon / relative
            if path.is_symlink():
                raise ValueError('linked texture: ' + relative)
            data = path.read_bytes()
            if texture_dimensions(data, path.suffix) != (entry['sheetWidth'], entry['sheetHeight']):
                raise ValueError('texture dimensions differ: ' + relative)
            digest = hashlib.sha256(data).hexdigest()
            if digest != entry['texture_sha256']:
                raise ValueError('texture hash differs: ' + relative)
            checked[relative] = identity
    icon = json.loads((root / 'assets/twitch-glitch.json').read_text())
    if icon['texture'] != 'Media/UI/TwitchGlitch.tga':
        raise ValueError('unexpected minimap icon path')
    icon_path = addon / icon['texture']
    if icon_path.is_symlink():
        raise ValueError('linked minimap icon')
    icon_bytes = icon_path.read_bytes()
    if len(icon_bytes) < 18 or icon_bytes[2] not in (2, 10) or icon_bytes[16] != 32:
        raise ValueError('unsupported minimap icon format')
    if struct.unpack_from('<HH', icon_bytes, 12) != (64, 64):
        raise ValueError('minimap icon must use a 64 x 64 canvas')
    if hashlib.sha256(icon_bytes).hexdigest() != icon['texture_sha256']:
        raise ValueError('minimap icon hash differs')
    expected.add(icon['texture'])
    actual = {path.relative_to(addon).as_posix() for path in addon.rglob('*') if path.is_file()
              and path.name != '.DS_Store' and not path.name.startswith('._')}
    if actual != expected:
        raise ValueError(f'install content mismatch; extra={sorted(actual-expected)}, missing={sorted(expected-actual)}')
    if (addon / 'LICENSE').read_bytes() != (root / 'LICENSE').read_bytes():
        raise ValueError('shipped code license differs')
    total = sum((addon / name).stat().st_size for name in actual)
    print(f'Verified {len(files)} Lua modules, {aliases} aliases, {len(checked)} textures, '
          f'{len(groups)} groups, 1 UI icon, {total / 1024**3:.2f} GiB')
    return sorted(actual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, help='create this ZIP after verification')
    parser.add_argument('--compressor', choices=('auto',) + COMPRESSORS, default='auto',
                        help='DEFLATE encoder for ZIP members; auto prefers libdeflate, then zopfli, then zlib')
    parser.add_argument('--workers', type=int, default=min(8, os.cpu_count() or 1),
                        help='parallel compression processes')
    args = parser.parse_args()
    if args.workers < 1:
        raise ValueError('workers must be at least 1')
    compressor = select_compressor(args.compressor) if args.output else None
    files = verify(args.root)
    if args.output:
        build_zip(args.root, args.output, files, compressor, args.workers)


if __name__ == '__main__':
    main()
