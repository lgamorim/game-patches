"""Locating the game and its font files."""
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

from .formats import Box

APP_ID = '813780'   # Age of Empires II: Definitive Edition
GAME_EXE = 'AoE2DE_s.exe'

# atlas set -> (file prefix, the font the stock atlas was rendered from)
SETS = {
    'sansserif': ('combined_sansserif', 'arial.ttf'),
    'serif': ('combined', 'timesbd.ttf'),
}


class GameError(Exception):
    pass


def _steam_libraries():
    roots = []
    if sys.platform == 'win32':
        import winreg
        for hive, key, value in [(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam', 'SteamPath'),
                                 (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
                                 (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Valve\Steam', 'InstallPath')]:
            try:
                with winreg.OpenKey(hive, key) as k:
                    roots.append(Path(winreg.QueryValueEx(k, value)[0]))
            except OSError:
                pass
    libraries = []
    for root in roots:
        libraries.append(root)
        vdf = root / 'steamapps' / 'libraryfolders.vdf'
        if vdf.is_file():
            text = vdf.read_text(encoding='utf-8', errors='replace')
            for m in re.finditer(r'"path"\s+"([^"]+)"', text):
                libraries.append(Path(m.group(1).replace('\\\\', '\\')))
    seen, unique = set(), []
    for lib in libraries:
        key = str(lib).lower()
        if key not in seen:
            seen.add(key)
            unique.append(lib)
    return unique


def find_game_dir(explicit=None):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    if os.environ.get('AOE2DE_DIR'):
        candidates.append(Path(os.environ['AOE2DE_DIR']))
    for lib in _steam_libraries():
        acf = lib / 'steamapps' / f'appmanifest_{APP_ID}.acf'
        installdir = 'AoE2DE'
        if acf.is_file():
            m = re.search(r'"installdir"\s+"([^"]+)"', acf.read_text(encoding='utf-8', errors='replace'))
            if m:
                installdir = m.group(1)
        candidates.append(lib / 'steamapps' / 'common' / installdir)
    for c in candidates:
        if (c / 'resources' / '_common' / 'fonts').is_dir():
            return c
    if explicit:
        raise GameError(f'no AoE2 DE install at "{explicit}" (expected resources\\_common\\fonts inside)')
    raise GameError('could not find AoE2 DE through Steam; pass --game-dir "<path to AoE2DE>"')


def fonts_dir(game_dir):
    return Path(game_dir) / 'resources' / '_common' / 'fonts'


def _resolve(folder, name):
    exact = folder / name
    if exact.exists():
        return exact
    lower = name.lower()
    for p in folder.iterdir() if folder.is_dir() else []:
        if p.name.lower() == lower:
            return p
    return exact


def set_files(game_dir, set_key):
    """Paths of every file in an atlas set, derived from its .box header."""
    prefix = SETS[set_key][0]
    folder = fonts_dir(game_dir)
    box_path = _resolve(folder, f'{prefix}.box')
    if not box_path.is_file():
        raise GameError(f'{box_path.name} not found in {folder}')
    pages = Box(box_path.read_bytes()).pages
    names = [f'{prefix}.box', f'{prefix}.txt']
    names += [f'{prefix}_{i:04d}.DDS' for i in range(pages)]
    names += [f'{prefix}_{i:04d}.png' for i in range(pages)]
    files = {n: _resolve(folder, n) for n in names}
    missing = [n for n, p in files.items() if not p.is_file()]
    if missing:
        raise GameError('missing atlas files: ' + ', '.join(missing))
    return files


def reference_font(game_dir, set_key):
    name = SETS[set_key][1]
    base = Path(game_dir) / 'resources' / '_common' / 'wpfg'
    for folder in (base / 'fonts', base / 'WPFUI' / 'Common' / 'Resources' / 'Fonts'):
        p = _resolve(folder, name)
        if p.is_file():
            return p
    raise GameError(f'reference font {name} not found in the game folder (run Steam "Verify integrity of game files")')


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(chunk), b''):
            h.update(block)
    return h.hexdigest()


def game_running():
    if sys.platform != 'win32':
        return False
    try:
        out = subprocess.run(['tasklist', '/FI', f'IMAGENAME eq {GAME_EXE}', '/NH'],
                             capture_output=True, text=True, creationflags=0x08000000).stdout
        return GAME_EXE.lower() in out.lower()
    except OSError:
        return False
