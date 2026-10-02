#!/usr/bin/env python3
"""Generate icon_DroneCam.dds: 256x256, DXT1, no mipmaps."""
import struct
import math
import sys

W = H = 256


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def make_pixels():
    """Returns a list of (r, g, b) floats in 0..1, row-major."""
    px = [None] * (W * H)
    cx, cy = W / 2.0, H / 2.0

    # Rotor hub positions, as a quadcopter seen from slightly above.
    rotors = [(-58, -34), (58, -34), (-58, 34), (58, 34)]

    for y in range(H):
        for x in range(W):
            fx, fy = x - cx, y - cy

            # Background: deep navy at the top easing to a teal glow low down,
            # with a soft radial vignette so the icon reads on any shelf colour.
            t = y / float(H - 1)
            r = 0.055 + 0.035 * t
            g = 0.105 + 0.230 * t
            b = 0.180 + 0.300 * t

            d = math.sqrt(fx * fx + fy * fy) / (W * 0.62)
            vig = clamp(1.12 - 0.55 * d * d)
            r, g, b = r * vig, g * vig, b * vig

            # Ground line, suggesting a field below the drone.
            if 196 <= y <= 199:
                k = 0.45 if y in (196, 199) else 0.9
                r = r + (0.38 - r) * k
                g = g + (0.62 - g) * k
                b = b + (0.30 - b) * k

            # Rotor discs: thin bright rings.
            for rxo, ryo in rotors:
                rd = math.sqrt((fx - rxo) ** 2 + ((fy - ryo) * 2.1) ** 2)
                ring = abs(rd - 30.0)
                if ring < 3.0:
                    k = clamp(1.0 - ring / 3.0)
                    r = r + (0.92 - r) * k
                    g = g + (0.96 - g) * k
                    b = b + (1.00 - b) * k

            # Arms from the hub out to each rotor.
            for rxo, ryo in rotors:
                vx, vy = rxo, ryo
                ln = math.hypot(vx, vy)
                proj = (fx * vx + fy * vy) / (ln * ln)
                if 0.0 <= proj <= 1.0:
                    px_, py_ = fx - vx * proj, fy - vy * proj
                    dist = math.hypot(px_, py_)
                    if dist < 4.0:
                        k = clamp(1.0 - dist / 4.0)
                        r = r + (0.80 - r) * k
                        g = g + (0.86 - g) * k
                        b = b + (0.95 - b) * k

            # Central body.
            body = math.sqrt((fx / 26.0) ** 2 + (fy / 17.0) ** 2)
            if body < 1.0:
                k = clamp((1.0 - body) * 3.0)
                r = r + (0.97 - r) * k
                g = g + (0.78 - g) * k
                b = b + (0.26 - b) * k

            px[y * W + x] = (clamp(r), clamp(g), clamp(b))

    return px


def to565(c):
    r = int(round(clamp(c[0]) * 31))
    g = int(round(clamp(c[1]) * 63))
    b = int(round(clamp(c[2]) * 31))
    return (r << 11) | (g << 5) | b


def from565(v):
    r = ((v >> 11) & 31) / 31.0
    g = ((v >> 5) & 63) / 63.0
    b = (v & 31) / 31.0
    return (r, g, b)


def encode_dxt1(px):
    out = bytearray()

    for by in range(0, H, 4):
        for bx in range(0, W, 4):
            block = [px[(by + j) * W + (bx + i)] for j in range(4) for i in range(4)]

            # Pick endpoints as the two pixels furthest apart along the block's
            # dominant axis, approximated by luminance extremes.
            lum = [0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] for c in block]
            cmax = block[lum.index(max(lum))]
            cmin = block[lum.index(min(lum))]

            c0, c1 = to565(cmax), to565(cmin)
            if c0 < c1:
                c0, c1 = c1, c0

            e0, e1 = from565(c0), from565(c1)
            if c0 == c1:
                palette = [e0, e1, e0, e1]
            else:
                palette = [
                    e0,
                    e1,
                    tuple((2 * e0[k] + e1[k]) / 3.0 for k in range(3)),
                    tuple((e0[k] + 2 * e1[k]) / 3.0 for k in range(3)),
                ]

            bits = 0
            for n, c in enumerate(block):
                best, bestd = 0, None
                for idx, p in enumerate(palette):
                    d = (c[0] - p[0]) ** 2 + (c[1] - p[1]) ** 2 + (c[2] - p[2]) ** 2
                    if bestd is None or d < bestd:
                        best, bestd = idx, d
                bits |= best << (2 * n)

            out += struct.pack('<HHI', c0, c1, bits)

    return bytes(out)


def dds_header(linear_size):
    DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH, DDSD_PIXELFORMAT, DDSD_LINEARSIZE = 0x1, 0x2, 0x4, 0x1000, 0x80000
    flags = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_LINEARSIZE

    h = bytearray()
    h += b'DDS '
    h += struct.pack('<I', 124)          # dwSize
    h += struct.pack('<I', flags)
    h += struct.pack('<I', H)
    h += struct.pack('<I', W)
    h += struct.pack('<I', linear_size)
    h += struct.pack('<I', 0)            # dwDepth
    h += struct.pack('<I', 1)            # dwMipMapCount
    h += b'\x00' * 44                    # dwReserved1[11]
    # DDS_PIXELFORMAT
    h += struct.pack('<I', 32)           # dwSize
    h += struct.pack('<I', 0x4)          # DDPF_FOURCC
    h += b'DXT1'
    h += b'\x00' * 20                    # bit counts / masks unused for FourCC
    h += struct.pack('<I', 0x1000)       # DDSCAPS_TEXTURE
    h += b'\x00' * 16                    # dwCaps2..4, dwReserved2
    assert len(h) == 128, len(h)
    return bytes(h)


def main(path):
    data = encode_dxt1(make_pixels())
    with open(path, 'wb') as f:
        f.write(dds_header(len(data)))
        f.write(data)
    print('wrote %s (%d bytes)' % (path, 128 + len(data)))


if __name__ == '__main__':
    main(sys.argv[1])
