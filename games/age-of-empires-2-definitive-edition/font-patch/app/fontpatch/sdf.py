"""Signed distance fields from TrueType/CFF outlines (pure numpy)."""
import numpy as np
from fontTools.pens.basePen import BasePen
from fontTools.pens.boundsPen import ControlBoundsPen


class _FlatPen(BasePen):
    def __init__(self, glyph_set, steps=16):
        super().__init__(glyph_set)
        self.contours, self.cur, self.steps = [], None, steps

    def _moveTo(self, p):
        self.cur = [p]
        self.contours.append(self.cur)

    def _lineTo(self, p):
        self.cur.append(p)

    def _qCurveToOne(self, p1, p2):
        p0 = self.cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            a, b, c = (1 - t) ** 2, 2 * (1 - t) * t, t * t
            self.cur.append((a * p0[0] + b * p1[0] + c * p2[0], a * p0[1] + b * p1[1] + c * p2[1]))

    def _curveToOne(self, p1, p2, p3):
        p0 = self.cur[-1]
        for i in range(1, self.steps + 1):
            t = i / self.steps
            a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
            self.cur.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                             a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))

    def _closePath(self):
        if self.cur and self.cur[0] != self.cur[-1]:
            self.cur.append(self.cur[0])

    _endPath = _closePath


def bounds(glyph_set, name):
    pen = ControlBoundsPen(glyph_set)
    glyph_set[name].draw(pen)
    return pen.bounds   # None for empty glyphs


def _segments(glyph_set, name):
    pen = _FlatPen(glyph_set)
    glyph_set[name].draw(pen)
    segs = [(a[0], a[1], b[0], b[1]) for c in pen.contours for a, b in zip(c[:-1], c[1:]) if a != b]
    return np.array(segs, float).reshape(-1, 4)


def _winding(segs, x, y):
    x = np.asarray(x)[:, None]
    y = np.asarray(y)[:, None]
    ax, ay, bx, by = (segs[None, :, i] for i in range(4))
    up = (ay <= y) & (by > y)
    dn = (ay > y) & (by <= y)
    cross = (bx - ax) * (y - ay) - (x - ax) * (by - ay)
    return (up & (cross > 0)).sum(1) - (dn & (cross < 0)).sum(1)


def _boundary(segs, max_len=6.0, eps=0.75):
    """Split segments and keep only pieces that separate inside from outside.

    Composite and overlapping contours (common in accented letters) would otherwise
    leave interior edges that show up as seams in the distance field."""
    pieces = []
    for x0, y0, x1, y1 in segs:
        n = max(1, int(np.ceil(np.hypot(x1 - x0, y1 - y0) / max_len)))
        t = np.linspace(0, 1, n + 1)
        xs, ys = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        pieces += [(xs[i], ys[i], xs[i + 1], ys[i + 1]) for i in range(n)]
    p = np.array(pieces, float)
    mx, my = (p[:, 0] + p[:, 2]) / 2, (p[:, 1] + p[:, 3]) / 2
    dx, dy = p[:, 2] - p[:, 0], p[:, 3] - p[:, 1]
    length = np.maximum(np.hypot(dx, dy), 1e-9)
    left = _winding(segs, mx - dy / length * eps, my + dx / length * eps) != 0
    right = _winding(segs, mx + dy / length * eps, my - dx / length * eps) != 0
    return p[left != right]


def signed_distance(glyph_set, name, xs, ys, chunk=4096):
    """Distance in font units at sample points (xs, ys); positive inside the glyph."""
    segs = _segments(glyph_set, name)
    if len(segs) == 0:
        return np.full(xs.shape, -1e9)
    edge = _boundary(segs)
    pts = np.stack([xs.ravel(), ys.ravel()], 1)
    dist = np.empty(len(pts))
    a = edge[None, :, 0:2]
    ab = edge[None, :, 2:4] - a
    ab2 = np.maximum((ab * ab).sum(-1), 1e-12)
    for i in range(0, len(pts), chunk):
        q = pts[i:i + chunk, None, :]
        t = np.clip(((q - a) * ab).sum(-1) / ab2, 0, 1)
        dist[i:i + chunk] = np.sqrt(((q - (a + ab * t[..., None])) ** 2).sum(-1)).min(1)
    inside = _winding(segs, pts[:, 0], pts[:, 1]) != 0
    return np.where(inside, dist, -dist).reshape(xs.shape)
