"""Derive the atlas generator's conventions from the stock atlas itself.

The stock Sans Serif atlas is rendered from Arial, and the serif one from Times New Roman
Bold; both fonts ship with the game. Fitting the stock records and pixels against those
fonts recovers the em scale, cell padding, offset conventions and distance-field slope, so a
game update that changes any of them is picked up, and one that breaks the assumptions makes
calibration fail instead of producing a broken atlas.
"""
import math
from dataclasses import dataclass, asdict

import numpy as np
from fontTools.ttLib import TTFont

from .formats import cell_rect
from .sdf import bounds, signed_distance


class CalibrationError(Exception):
    pass


@dataclass
class Calibration:
    em_px: float        # pixels per em in the atlas
    pad: int            # empty pixels around the glyph box in each cell
    xo_scale: float     # XO = (xMin*k - pad) * xo_scale
    baseline: float     # YO = baseline - yMax*k
    slope: float        # stored value = offset + slope * distance_px
    offset: float
    edge_rmse: float    # fit quality on the reference glyphs (0..255 scale)

    def as_dict(self):
        return asdict(self)


def _cell_grid(w, h, pad, k, xmin, ymin):
    X, Y = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
    return (X - pad) / k + xmin, ymin + ((h - Y) - pad) / k


def render_cell(glyph_set, name, cal: Calibration, upm):
    """Render one glyph cell. Returns (record fields, BGRA pixels) or (fields, None) for blank glyphs."""
    k = cal.em_px / upm
    advance = glyph_set[name].width * k
    b = bounds(glyph_set, name)
    if b is None:
        return dict(xo=(0 - cal.pad) * cal.xo_scale, yo=cal.baseline, adv=advance), None
    xmin, ymin, xmax, ymax = b
    w = math.ceil((xmax - xmin) * k) + 2 * cal.pad
    h = math.ceil((ymax - ymin) * k) + 2 * cal.pad
    xs, ys = _cell_grid(w, h, cal.pad, k, xmin, ymin)
    d = signed_distance(glyph_set, name, xs, ys) * k
    v = np.clip(np.round(cal.offset + cal.slope * d), 0, 255).astype(np.uint8)
    px = np.zeros((h, w, 4), np.uint8)
    px[..., 0] = px[..., 1] = px[..., 2] = v
    px[..., 3] = np.where(v > 0, 255, 0)
    return dict(xo=(xmin * k - cal.pad) * cal.xo_scale, yo=cal.baseline - ymax * k, adv=advance, w=w, h=h), px


def _share(mask):
    return float(np.mean(mask)) if len(mask) else 0.0


def calibrate(box, pages, reference_font_path) -> Calibration:
    """box: formats.Box; pages: list of level-0 arrays; reference_font_path: the stock source font."""
    font = TTFont(reference_font_path)
    gs, cmap, upm = font.getGlyphSet(), font.getBestCmap(), font['head'].unitsPerEm
    size = pages[0].shape[0]
    rows = []
    for cp in range(33, 127):
        if cp not in cmap or cp not in box.by_codepoint:
            continue
        b = bounds(gs, cmap[cp])
        if b is None:
            continue
        rows.append((cp, cmap[cp], box.records[box.by_codepoint[cp]], b, gs[cmap[cp]].width))
    if len(rows) < 60:
        raise CalibrationError(f'only {len(rows)} reference glyphs found in the atlas')

    adv_units = np.array([r[4] for r in rows], float)
    adv_px = np.array([r[2][9] for r in rows])
    ratio = adv_px / adv_units * upm
    em = float(np.median(ratio))
    if _share(np.abs(ratio - em) < 0.01) < 0.9:
        raise CalibrationError('advances do not match the reference font (atlas made from a different font?)')
    k = em / upm

    box_w = np.array([(r[3][2] - r[3][0]) * k for r in rows])
    cell_w = np.array([r[2][0] for r in rows])
    pad = int(round((np.median(cell_w - box_w) - 0.5) / 2))
    if pad < 1 or _share(cell_w == np.ceil(box_w) + 2 * pad) < 0.9:
        raise CalibrationError('cell sizes do not follow the expected padding rule')

    ymax = np.array([r[3][3] * k for r in rows])
    yo = np.array([r[2][8] for r in rows])
    baseline = float(np.median(yo + ymax))
    if _share(np.abs(yo + ymax - baseline) < 0.02) < 0.9:
        raise CalibrationError('vertical offsets do not follow the expected rule')

    den = np.array([r[3][0] * k - pad for r in rows])
    xo = np.array([r[2][7] for r in rows])
    ok = np.abs(den) > 1
    xo_scale = float(np.median(xo[ok] / den[ok]))
    if _share(np.abs(xo - xo_scale * den) < 0.1) < 0.85:
        raise CalibrationError('horizontal offsets do not follow the expected rule')

    # distance-field slope/offset and the alpha rule, from a spread of shapes
    sample = [r for r in rows if chr(r[0]) in 'HOxegRs8@&ABDQWabdkmpwyz3579%#']
    dist, val, alpha_ok = [], [], []
    for cp, name, rec, b, _ in sample:
        x, y, w, h = cell_rect(rec, size)
        cell = pages[int(rec[6])][y:y + h, x:x + w]
        xs, ys = _cell_grid(w, h, pad, k, b[0], b[1])
        d = signed_distance(gs, name, xs, ys) * k
        med = np.median(cell[..., :3], axis=-1).astype(float)
        # near-edge pixels only: further out, the stock multi-channel field legitimately
        # differs from a true distance at corners
        band = (med > 0) & (med < 255) & (np.abs(d) < 1.2)
        dist.append(d[band])
        val.append(med[band])
        alpha_ok.append(np.mean((cell[..., 3] > 127) == (cell[..., :3].max(-1) > 0)))
    dist, val = np.concatenate(dist), np.concatenate(val)
    slope, offset = np.polyfit(dist, val, 1)
    rmse = float(np.sqrt(np.mean((val - (slope * dist + offset)) ** 2)))
    if not (abs(offset - 127.5) < 4 and slope > 0 and rmse < 6):
        raise CalibrationError(f'distance field does not match (slope {slope:.1f}, offset {offset:.1f}, rmse {rmse:.1f})')
    if min(alpha_ok) < 0.999:
        raise CalibrationError('alpha channel no longer follows "any colour channel > 0"')
    return Calibration(em, pad, xo_scale, baseline, float(slope), float(offset), rmse)
