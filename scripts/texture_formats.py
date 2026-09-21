# Copyright (c) 2026 TheMizeGuy. All rights reserved.
"""TGA and single-level indexed BLP2 textures used by the emote packs."""
import math
import struct

from PIL import Image, ImageChops, ImageStat

BLP_HEADER_SIZE = 1172
BLP_MAGIC = b'BLP2\x01\x00\x00\x00\x01\x08\x08\x00'


def power_of_two(number):
    return 1 <= number <= 2048 and not number & (number - 1)


def texture_dimensions(data, suffix):
    if suffix == '.tga':
        if len(data) < 18 or data[2] not in (2, 10) or data[16] != 32:
            raise ValueError('unsupported TGA texture')
        width, height = struct.unpack_from('<HH', data, 12)
    elif suffix == '.blp':
        if len(data) < BLP_HEADER_SIZE or data[:12] != BLP_MAGIC:
            raise ValueError('unsupported indexed BLP2 texture')
        width, height = struct.unpack_from('<II', data, 12)
        offsets = struct.unpack_from('<16I', data, 20)
        lengths = struct.unpack_from('<16I', data, 84)
        payload_size = width * height * 2
        if (offsets != (BLP_HEADER_SIZE,) + (0,) * 15
                or lengths != (payload_size,) + (0,) * 15
                or len(data) != BLP_HEADER_SIZE + payload_size):
            raise ValueError('invalid BLP2 mip layout or payload length')
    else:
        raise ValueError('unsupported texture extension')
    if not power_of_two(width) or not power_of_two(height):
        raise ValueError('texture requires power-of-two dimensions up to 2048')
    return width, height


def write_blp2(size, palette, indices, alpha):
    """Pack a single-mip palettized BLP2: 256 BGRA palette slots, index plane, exact 8-bit alpha plane.

    palette is up to 256 (r, g, b) tuples; indices and alpha are row-major bytes of width * height.
    """
    width, height = size
    if not power_of_two(width) or not power_of_two(height):
        raise ValueError('texture requires power-of-two dimensions up to 2048')
    if len(palette) > 256 or len(indices) != width * height or len(alpha) != width * height:
        raise ValueError('palette, index plane, and alpha plane must match the texture size')
    if indices and max(indices) >= len(palette):
        raise ValueError('index plane references a missing palette entry')
    slots = list(palette) + [(0, 0, 0)] * (256 - len(palette))
    palette_bytes = bytes(value for red, green, blue in slots for value in (blue, green, red, 0))
    payload = bytes(indices) + bytes(alpha)
    header = struct.pack('<4sI4B2I16I16I', b'BLP2', 1, 1, 8, 8, 0, width, height,
                         BLP_HEADER_SIZE, *([0] * 15), len(payload), *([0] * 15))
    return header + palette_bytes + payload


def read_blp2(data):
    """Return (size, palette, indices, alpha) of a texture written by write_blp2."""
    width, height = texture_dimensions(data, '.blp')
    palette = [(data[i + 2], data[i + 1], data[i]) for i in range(148, 148 + 1024, 4)]
    pixels = width * height
    return (width, height), palette, data[BLP_HEADER_SIZE:BLP_HEADER_SIZE + pixels], data[BLP_HEADER_SIZE + pixels:]


def decode_blp2(data):
    """Rebuild the RGBA image a client shows for a texture written by write_blp2."""
    size, palette, indices, alpha = read_blp2(data)
    image = Image.new('RGBA', size)
    image.putdata([palette[index] + (value,) for index, value in zip(indices, alpha)])
    return image


def encode_indexed(image):
    """Return a BLP2 and visible-pixel RGB RMS error; alpha is copied exactly."""
    rgba = image.convert('RGBA')
    indexed = rgba.convert('RGB').quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    palette = (indexed.getpalette() + [0] * 768)[:768]
    alpha = rgba.getchannel('A')
    data = write_blp2(rgba.size, [tuple(palette[i * 3:i * 3 + 3]) for i in range(256)],
                      indexed.tobytes(), alpha.tobytes())
    reconstructed = indexed.convert('RGBA')
    reconstructed.putalpha(alpha)
    return data, visible_error(rgba, reconstructed)


def visible_error(original, converted):
    """Worst RGB RMS over the original's visible pixels, composited on black and on white."""
    alpha = original.getchannel('A')
    visible = alpha.point(lambda value: 255 if value else 0)
    error = 0
    if visible.getbbox():
        for color in ('black', 'white'):
            background = Image.new('RGBA', original.size, color)
            first = Image.alpha_composite(background, original).convert('RGB')
            second = Image.alpha_composite(background, converted).convert('RGB')
            stats = ImageStat.Stat(ImageChops.difference(first, second), visible)
            error = max(error, math.sqrt(sum(value * value for value in stats.rms) / 3))
    return error
