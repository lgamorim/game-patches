"""Rebuild a font atlas set with a replacement font.

Glyphs the replacement font has are re-rendered; every other glyph (CJK, Hangul, Indic,
the game's placeholder box...) keeps its stock pixels and record. Stock glyphs stay where
they are; new cells go into the freed slots and the atlas's empty space, so the page count
and every untouched byte of the pages are preserved.
"""
import io

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image

from .calibrate import Calibration, render_cell
from .formats import Box, Dds, cell_rect


class BuildError(Exception):
    pass


class _Packer:
    """First-fit placement on occupancy bitmaps, keeping a 1-pixel gap between cells."""

    def __init__(self, occupancy):
        self.occ = occupancy
        self.cache = {}
        self.full = {}

    def _integral(self, page):
        if page not in self.cache:
            ii = np.zeros((self.occ[page].shape[0] + 1, self.occ[page].shape[1] + 1), np.int32)
            ii[1:, 1:] = self.occ[page].cumsum(0, dtype=np.int32).cumsum(1, dtype=np.int32)
            self.cache[page] = (ii, [])
        return self.cache[page]

    def place(self, w, h):
        for page in range(len(self.occ)):
            if any(w >= fw and h >= fh for fw, fh in self.full.get(page, [])):
                continue
            ii, recent = self._integral(page)
            sums = ii[h:, w:] - ii[:-h, w:] - ii[h:, :-w] + ii[:-h, :-w]
            for z in np.flatnonzero(sums == 0):
                y, x = divmod(int(z), sums.shape[1])
                if not any(x < rx + rw and rx < x + w and y < ry + rh and ry < y + h for rx, ry, rw, rh in recent):
                    self.occ[page][max(0, y - 1):y + h + 1, max(0, x - 1):x + w + 1] = True
                    recent.append((x - 1, y - 1, w + 2, h + 2))
                    if len(recent) > 40:
                        self.cache.pop(page)
                    return page, x, y
            self.full.setdefault(page, []).append((w, h))
        return None


def load_font(font_path, features=(), variations=None):
    """Open a font; pin variable fonts to an instance; apply single-substitution features.

    The atlas maps one codepoint to one glyph, so features can only be baked in when they
    swap glyphs 1:1, e.g. 'lnum' (lining figures) or 'smcp'. Returns (font, codepoint->glyph)."""
    font = TTFont(font_path)
    if 'fvar' in font:
        from fontTools.varLib.instancer import instantiateVariableFont
        axes = {a.axisTag: a.defaultValue for a in font['fvar'].axes}
        axes.update(variations or {})
        font = instantiateVariableFont(font, axes)
    cmap = dict(font.getBestCmap())
    if not features:
        return font, cmap
    if 'GSUB' not in font:
        raise BuildError(f'{font_path.name} has no OpenType features, so {", ".join(features)} cannot be applied')
    gsub = font['GSUB'].table
    found, lookups = set(), []
    for rec in gsub.FeatureList.FeatureRecord:
        if rec.FeatureTag in features:
            found.add(rec.FeatureTag)
            lookups += [i for i in rec.Feature.LookupListIndex if i not in lookups]
    missing = set(features) - found
    if missing:
        raise BuildError(f'{font_path.name} does not have feature(s): {", ".join(sorted(missing))}')
    swap = {}
    for i in sorted(lookups):
        lookup = gsub.LookupList.Lookup[i]
        for sub in lookup.SubTable:
            kind = lookup.LookupType
            if kind == 7:
                kind, sub = sub.ExtensionLookupType, sub.ExtSubTable
            if kind == 1:
                swap.update(sub.mapping)
    return font, {cp: swap.get(g, g) for cp, g in cmap.items()}


def build(set_name, stock_files, font_path, cal: Calibration, features=(), variations=None, log=print):
    """stock_files: {filename: bytes} for one atlas set. Returns {filename: bytes}."""
    box = Box(stock_files[f'{set_name}.box'])
    dds_names = [f'{set_name}_{i:04d}.DDS' for i in range(box.pages)]
    pages = [Dds(stock_files[n]) for n in dds_names]
    size = pages[0].width
    level0 = [p.level(0) for p in pages]

    font, cmap = load_font(font_path, features, variations)
    gs, upm = font.getGlyphSet(), font['head'].unitsPerEm
    targets = [cp for cp in box.codepoints if cp >= 32 and cp != 0x7F and cp in cmap]
    if not targets:
        raise BuildError('the replacement font has none of the atlas characters')

    log(f'  rendering {len(targets)} glyphs...')
    rendered = {}
    for n, cp in enumerate(targets, 1):
        rendered[cp] = render_cell(gs, cmap[cp], cal, upm)
        if n % 100 == 0:
            log(f'    {n}/{len(targets)}')

    # occupancy from glyphs that keep their stock cell; free the slots of replaced glyphs
    occ = [np.zeros((size, size), bool) for _ in pages]
    changed = [[] for _ in pages]
    for cp, rec in zip(box.codepoints, box.records):
        x, y, w, h = cell_rect(rec, size)
        page = int(rec[6])
        if cp in rendered and rendered[cp][1] is not None:
            level0[page][y:y + h, x:x + w] = 0
            changed[page].append((x, y, w, h))
        else:
            occ[page][max(0, y - 1):y + h + 1, max(0, x - 1):x + w + 1] = True

    log('  packing...')
    packer = _Packer(occ)
    order = sorted((cp for cp in rendered if rendered[cp][1] is not None),
                   key=lambda cp: (-rendered[cp][0]['h'], -rendered[cp][0]['w']))
    for cp in order:
        info, px = rendered[cp]
        spot = packer.place(info['w'], info['h'])
        if spot is None:
            raise BuildError(f'atlas is out of space (glyph U+{cp:04X}); try a narrower font')
        page, x, y = spot
        level0[page][y:y + info['h'], x:x + info['w']] = px
        changed[page].append((x, y, info['w'], info['h']))
        box.records[box.by_codepoint[cp]] = [float(info['w']), float(info['h']),
                                             x / size, (x + info['w']) / size, y / size, (y + info['h']) / size,
                                             page, info['xo'], info['yo'], info['adv']]
    for cp, (info, px) in rendered.items():
        if px is None:   # blank glyphs (space, no-break space...) keep their cell, get new metrics
            rec = box.records[box.by_codepoint[cp]]
            rec[7], rec[8], rec[9] = info['xo'], info['yo'], info['adv']

    log('  writing pages...')
    out = {f'{set_name}.box': box.to_bytes(), f'{set_name}.txt': box.to_txt()}
    for i, (dds, img) in enumerate(zip(pages, level0)):
        dds.set_level(0, img)
        dds.refresh_mips(changed[i])
        out[dds_names[i]] = dds.to_bytes()
        buf = io.BytesIO()
        Image.fromarray(img[..., [2, 1, 0]]).save(buf, format='PNG', optimize=True)
        out[f'{set_name}_{i:04d}.png'] = buf.getvalue()
    _verify(box, level0, size, rendered)
    return out


def _verify(box, level0, size, rendered):
    seen = [np.zeros((size, size), np.uint8) for _ in level0]
    for rec in box.records:
        x, y, w, h = cell_rect(rec, size)
        if x < 0 or y < 0 or x + w > size or y + h > size:
            raise BuildError('a glyph cell lies outside its page')
        if rendered and w > 0 and h > 0:
            seen[int(rec[6])][y:y + h, x:x + w] += 1
    if any((s > 1).any() for s in seen):
        # blank glyphs may share stock cells; only rendered cells must be exclusive
        for cp, (info, px) in rendered.items():
            if px is None:
                continue
            x, y, w, h = cell_rect(box.records[box.by_codepoint[cp]], size)
            if (seen[int(box.records[box.by_codepoint[cp]][6])][y:y + h, x:x + w] > 1).any():
                raise BuildError(f'glyph U+{cp:04X} overlaps another cell')
