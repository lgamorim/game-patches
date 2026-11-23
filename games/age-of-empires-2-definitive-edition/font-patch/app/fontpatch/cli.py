"""Command line: status / apply / restore.

Which font goes into which in-game set is configured in fonts.json next to this package:

  {"sansserif": {"font": "fonts/Raleway-Regular.ttf", "features": ["lnum"]},
   "serif":     {"font": "fonts/Lora-Bold.ttf"}}

Every action hashes the installed atlas set first and compares it with the cache:

  cache/<set>/<stock id>/stock/        the stock files, copied from this PC before patching
  cache/<set>/<stock id>/out-<font id>/ the rebuilt files for one font configuration
  cache/<set>/<stock id>/info.json     hashes of both, plus the calibration used

Installed files that match nothing in the cache are treated as a new stock build only if
calibration against the game's own reference font succeeds; anything else is left alone.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path

from . import game
from .build import BuildError, build
from .calibrate import CalibrationError, calibrate
from .formats import Box, Dds, FormatError

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / 'fonts.json'
VERSION = '1.1'
OPTION_HINT = {'sansserif': 'shown when Options > Interface > Sans Serif Font is on',
               'serif': 'shown when Options > Interface > Sans Serif Font is off'}


class PatchError(Exception):
    pass


class FontChoice:
    def __init__(self, path, features=(), variations=None):
        self.path = Path(path)
        if not self.path.is_absolute():
            self.path = ROOT / self.path
        if not self.path.is_file():
            raise PatchError(f'font not found: {self.path}')
        self.features = sorted(features or [])
        self.variations = dict(variations or {})
        recipe = json.dumps({'features': self.features, 'variations': self.variations}, sort_keys=True)
        self.id = hashlib.sha256(self.path.read_bytes() + recipe.encode()).hexdigest()[:12]

    def label(self):
        extra = [f'+{f}' for f in self.features] + [f'{k}={v}' for k, v in self.variations.items()]
        return self.path.name + (f' ({", ".join(extra)})' if extra else '')


def _stock_id(hashes):
    return hashlib.sha256(json.dumps(sorted(hashes.items())).encode()).hexdigest()[:16]


class Cache:
    def __init__(self, set_key):
        self.dir = ROOT / 'cache' / set_key

    def entries(self):
        if not self.dir.is_dir():
            return []
        out = []
        for d in sorted(self.dir.iterdir()):
            info = d / 'info.json'
            if info.is_file():
                out.append((d, json.loads(info.read_text(encoding='utf-8'))))
        return out

    def classify(self, installed, font_id=None):
        """-> (state, entry_dir, info, label): state is patched | other-font | stock | unknown."""
        for d, info in self.entries():
            for fid, o in info.get('outputs', {}).items():
                if o['files'] == installed:
                    return ('patched' if fid == font_id else 'other-font'), d, info, o.get('font', '?')
            if info['stock'] == installed:
                return 'stock', d, info, None
        return 'unknown', None, None, None


def _hash_set(files):
    return {name: game.sha256_file(path) for name, path in files.items()}


def _write_set(folder, data):
    folder.mkdir(parents=True, exist_ok=True)
    for name, blob in data.items():
        (folder / name).write_bytes(blob)
    return {name: hashlib.sha256(blob).hexdigest() for name, blob in data.items()}


def _check_folder(folder, hashes):
    for name, h in hashes.items():
        p = folder / name
        if not p.is_file() or game.sha256_file(p) != h:
            raise PatchError(f'cached file {p} is damaged. Run Steam "Verify integrity of game files" to get '
                             f'stock files back, then delete the cache folder "{folder.parent}" and run again.')


def _install(src_folder, hashes, files):
    """Copy a verified file set over the installed one, then verify the result."""
    if game.game_running():
        raise PatchError('Age of Empires II DE is running. Close it and try again.')
    _check_folder(src_folder, hashes)
    for name, dest in files.items():
        tmp = dest.with_name(dest.name + '.fontpatch-tmp')
        shutil.copyfile(src_folder / name, tmp)
        os.replace(tmp, dest)
    if _hash_set(files) != hashes:
        raise PatchError('files were copied but do not verify. Run Steam "Verify integrity of game files" to recover.')


def _calibrate(stock, set_key, game_dir, log):
    prefix = game.SETS[set_key][0]
    box = Box(stock[f'{prefix}.box'])
    pages = [Dds(stock[f'{prefix}_{i:04d}.DDS']).level(0) for i in range(box.pages)]
    cal = calibrate(box, pages, game.reference_font(game_dir, set_key))
    log(f'  calibration ok: {cal.em_px:.3f} px/em, pad {cal.pad}, edge fit {cal.edge_rmse:.1f}/255')
    return cal


def _ensure_output(entry_dir, info, set_key, choice, game_dir, log, cal=None):
    if choice.id in info.get('outputs', {}):
        return entry_dir / f'out-{choice.id}', info['outputs'][choice.id]['files']
    stock_dir = entry_dir / 'stock'
    _check_folder(stock_dir, info['stock'])
    stock = {n: (stock_dir / n).read_bytes() for n in info['stock']}
    cal = cal or _calibrate(stock, set_key, game_dir, log)
    log(f'  building {choice.label()} for this game version (takes a minute or two)...')
    t = time.time()
    out = build(game.SETS[set_key][0], stock, choice.path, cal, choice.features, choice.variations, log=log)
    hashes = _write_set(entry_dir / f'out-{choice.id}', out)
    info.setdefault('outputs', {})[choice.id] = {'font': choice.label(), 'files': hashes,
                                                 'calibration': cal.as_dict(), 'tool': VERSION}
    (entry_dir / 'info.json').write_text(json.dumps(info, indent=1), encoding='utf-8')
    log(f'  built in {time.time() - t:.0f}s')
    return entry_dir / f'out-{choice.id}', hashes


def _choices(args):
    """{set: FontChoice} to apply, from --set/--font or fonts.json."""
    if args.font:
        if not args.set:
            raise PatchError('--font needs --set (sansserif or serif)')
        feats = [f for f in (args.features or '').split(',') if f]
        return {args.set: FontChoice(args.font, feats)}
    if not CONFIG.is_file():
        raise PatchError(f'{CONFIG.name} not found next to the package')
    try:
        conf = json.loads(CONFIG.read_text(encoding='utf-8'))
    except ValueError as e:
        raise PatchError(f'{CONFIG.name} is not valid JSON: {e}')
    unknown = set(conf) - set(game.SETS)
    if unknown:
        raise PatchError(f'{CONFIG.name}: unknown set(s) {", ".join(sorted(unknown))}; use sansserif and/or serif')
    sets = [args.set] if args.set else [s for s in game.SETS if s in conf]
    return {s: FontChoice(conf[s]['font'], conf[s].get('features'), conf[s].get('variations'))
            for s in sets if s in conf}


def cmd_status(args, log, game_dir):
    choices = _choices(args)
    log(f'Game: {game_dir}')
    for s in ([args.set] if args.set else list(game.SETS)):
        files = game.set_files(game_dir, s)
        choice = choices.get(s)
        state, _, _, label = Cache(s).classify(_hash_set(files), choice.id if choice else None)
        text = {'patched': f'patched with {label}',
                'other-font': f'patched with {label} (fonts.json now asks for {choice.label() if choice else "stock"})',
                'stock': 'stock',
                'unknown': 'unrecognised (a game update not yet patched, or files changed by something else)'}[state]
        log(f'  {s:9} {text}  [{OPTION_HINT[s]}]')
    return 0


def _apply_set(set_key, choice, game_dir, log):
    files = game.set_files(game_dir, set_key)
    cache = Cache(set_key)
    installed = _hash_set(files)
    state, entry, info, _ = cache.classify(installed, choice.id)
    log(f'{set_key}: {choice.label()}')
    if state == 'patched':
        log('  already applied')
        return
    cal = None
    if state == 'unknown':
        log('  new game version: checking its atlas and backing it up...')
        stock = {n: p.read_bytes() for n, p in files.items()}
        if {n: hashlib.sha256(b).hexdigest() for n, b in stock.items()} != installed:
            raise PatchError('atlas files changed while being read; try again')
        try:
            cal = _calibrate(stock, set_key, game_dir, log)
        except (CalibrationError, FormatError) as e:
            raise PatchError(f'the installed {set_key} atlas does not look like a stock one ({e}). '
                             'If you changed these files yourself, run Steam "Verify integrity of game files" first.')
        entry = cache.dir / _stock_id(installed)
        hashes = _write_set(entry / 'stock', stock)
        info = {'stock': hashes, 'outputs': {}, 'game_dir': str(game_dir), 'added': time.strftime('%Y-%m-%d')}
        (entry / 'info.json').write_text(json.dumps(info, indent=1), encoding='utf-8')
    out_dir, out_hashes = _ensure_output(entry, info, set_key, choice, game_dir, log, cal)
    _install(out_dir, out_hashes, files)
    log(f'  applied ({OPTION_HINT[set_key]})')


def cmd_apply(args, log, game_dir):
    choices = _choices(args)
    if not choices:
        raise PatchError(f'nothing to apply: {CONFIG.name} lists no fonts')
    failed = []
    for set_key, choice in choices.items():
        try:
            _apply_set(set_key, choice, game_dir, log)
        except (PatchError, BuildError, FormatError, CalibrationError) as e:
            print(f'ERROR ({set_key}): {e}', file=sys.stderr, flush=True)
            failed.append(set_key)
    return 1 if failed else 0


def cmd_restore(args, log, game_dir):
    failed = []
    for set_key in ([args.set] if args.set else list(game.SETS)):
        files = game.set_files(game_dir, set_key)
        state, entry, info, _ = Cache(set_key).classify(_hash_set(files))
        if state == 'stock':
            log(f'{set_key}: already stock')
        elif state == 'unknown':
            if any(True for _ in Cache(set_key).entries()):
                print(f'ERROR ({set_key}): installed files are not a set this package made. '
                      'Use Steam "Verify integrity of game files".', file=sys.stderr, flush=True)
                failed.append(set_key)
            else:
                log(f'{set_key}: never patched by this package')
        else:
            try:
                _install(entry / 'stock', info['stock'], files)
                log(f'{set_key}: stock font restored')
            except PatchError as e:
                print(f'ERROR ({set_key}): {e}', file=sys.stderr, flush=True)
                failed.append(set_key)
    return 1 if failed else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog='fontpatch', description='Replace AoE2 DE in-game font atlases.')
    p.add_argument('command', choices=['status', 'apply', 'restore'])
    p.add_argument('--game-dir', help='AoE2DE install folder (default: found through Steam)')
    p.add_argument('--set', choices=list(game.SETS), help='only this set (default: every set in fonts.json)')
    p.add_argument('--font', help='use this .ttf/.otf instead of fonts.json (needs --set)')
    p.add_argument('--features', help='with --font: comma-separated 1:1 OpenType features, e.g. lnum')
    p.add_argument('--quiet', action='store_true', help='only print errors')
    args = p.parse_args(argv)
    log = (lambda *a, **k: None) if args.quiet else (lambda *a: print(*a, flush=True))
    try:
        game_dir = game.find_game_dir(args.game_dir)
        return {'status': cmd_status, 'apply': cmd_apply, 'restore': cmd_restore}[args.command](args, log, game_dir)
    except (PatchError, game.GameError, BuildError, FormatError, CalibrationError) as e:
        print(f'ERROR: {e}', file=sys.stderr, flush=True)
        return 1
