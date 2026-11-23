"""Readers/writers for the AoE2 DE font atlas files.

<set>.box   binary: header (int32 version, int32 glyph count, int32 pages, float px),
            then one 40-byte record per glyph (6 x float W,H,U,S,V,T; int32 page;
            3 x float XO,YO,advance), then one (uint16 codepoint, uint16 index) pair per glyph.
<set>.txt   human-readable dump of the same data, CRLF line endings.
<set>_NNNN.DDS  uncompressed 32-bit BGRA pages with a full mip chain.
<set>_NNNN.png  RGB preview of mip level 0 (not read by the game as far as we know).
"""
import struct

import numpy as np


class FormatError(Exception):
    pass


class Box:
    HEADER = struct.Struct('<iiif')
    RECORD = struct.Struct('<6fi3f')   # W, H, U, S, V, T, page, XO, YO, advance

    def __init__(self, data: bytes):
        if len(data) < 16:
            raise FormatError('.box file too short')
        self.version, self.count, self.pages, self.px = self.HEADER.unpack_from(data, 0)
        if self.version != 2:
            raise FormatError(f'unsupported .box version {self.version} (expected 2)')
        if len(data) != 16 + self.count * 44:
            raise FormatError(f'.box size {len(data)} does not match {self.count} glyphs')
        self.records = [list(self.RECORD.unpack_from(data, 16 + i * 40)) for i in range(self.count)]
        pairs = struct.unpack_from(f'<{2 * self.count}H', data, 16 + self.count * 40)
        self.codepoints = list(pairs[0::2])
        self.indices = list(pairs[1::2])
        if self.indices != list(range(self.count)):
            raise FormatError('.box glyph index table is not sequential')
        self.by_codepoint = {}
        for i, cp in enumerate(self.codepoints):
            self.by_codepoint.setdefault(cp, i)

    def to_bytes(self) -> bytes:
        out = bytearray(self.HEADER.pack(self.version, self.count, self.pages, self.px))
        for r in self.records:
            out += self.RECORD.pack(*r)
        for cp, ix in zip(self.codepoints, self.indices):
            out += struct.pack('<HH', cp, ix)
        return bytes(out)

    def to_txt(self) -> bytes:
        g = lambda x: '%g' % x
        lines = ['Font File Atlas Summary', '-----------------------',
                 f'Version : {self.version}', f'Glyphs : {self.count}',
                 f'Texture Pages : {self.pages}', f'Source Font Pixel Size : {int(self.px)}',
                 '-----------------------', '']
        for cp, r in zip(self.codepoints, self.records):
            label = f"'{chr(cp)}'" if 32 <= cp <= 126 else str(cp)
            lines.append(f'Glyph - {label}    W({int(r[0])}), H({int(r[1])}), UV({g(r[2])}, {g(r[4])}), '
                         f'ST({g(r[3])}, {g(r[5])}), Atlas({int(r[6])}), XO({g(r[7])}), YO({g(r[8])}), '
                         f'HAdvance({g(r[9])})')
        return ('\r\n'.join(lines) + '\r\n').encode('utf-8')


def cell_rect(record, size):
    """(x, y, w, h) of a glyph cell in page pixels."""
    w, h, u, _s, v, _t = record[:6]
    return round(u * size), round(v * size), int(w), int(h)


class Dds:
    """Uncompressed 32-bit BGRA DDS with mips, as used by the font atlases."""

    def __init__(self, data: bytes):
        if data[:4] != b'DDS ' or struct.unpack_from('<I', data, 4)[0] != 124:
            raise FormatError('not a DDS file')
        self.height, self.width = struct.unpack_from('<II', data, 12)
        mips = struct.unpack_from('<I', data, 28)[0] or 1
        pf_flags, fourcc, bpp = struct.unpack_from('<I4sI', data, 80)
        masks = struct.unpack_from('<4I', data, 92)
        if pf_flags != 0x41 or fourcc != b'\0\0\0\0' or bpp != 32 or masks != (0xFF0000, 0xFF00, 0xFF, 0xFF000000):
            raise FormatError('DDS is not uncompressed 32-bit BGRA (the game changed its atlas format)')
        if self.width != self.height:
            raise FormatError('DDS page is not square')
        self.data = bytearray(data)
        self.levels = []
        off, s = 128, self.width
        for _ in range(mips):
            self.levels.append((off, s))
            off += s * s * 4
            s = max(1, s // 2)
        if off != len(data):
            raise FormatError('DDS size does not match its mip chain')

    def level(self, i):
        off, s = self.levels[i]
        return np.frombuffer(bytes(self.data[off:off + s * s * 4]), np.uint8).reshape(s, s, 4).copy()

    def set_level(self, i, arr):
        off, s = self.levels[i]
        assert arr.shape == (s, s, 4) and arr.dtype == np.uint8
        self.data[off:off + s * s * 4] = arr.tobytes()

    def refresh_mips(self, rects):
        """Recompute mip levels only inside the changed level-0 rectangles (rest stays stock)."""
        prev = self.level(0)
        for i in range(1, len(self.levels)):
            cur = self.level(i)
            s = cur.shape[0]
            for x, y, w, h in rects:
                x0, y0 = x >> i, y >> i
                x1, y1 = min(((x + w - 1) >> i) + 1, s), min(((y + h - 1) >> i) + 1, s)
                blk = prev[2 * y0:2 * y1, 2 * x0:2 * x1].astype(np.float32)
                if blk.shape[0] < 2 or blk.shape[1] < 2:   # 1x1 tail of the chain
                    cur[y0:y1, x0:x1] = np.floor(blk.reshape(-1, 4).mean(0) + 0.5).astype(np.uint8)
                    continue
                cur[y0:y1, x0:x1] = np.floor(
                    (blk[0::2, 0::2] + blk[1::2, 0::2] + blk[0::2, 1::2] + blk[1::2, 1::2]) / 4 + 0.5
                ).astype(np.uint8)
            self.set_level(i, cur)
            prev = cur

    def to_bytes(self):
        return bytes(self.data)
