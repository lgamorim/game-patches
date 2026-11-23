# Font patch

Replaces the game's two in-game fonts with fonts of your choice by rebuilding the game's font atlases.

| | |
|---|---|
| **Game** | Age of Empires II: Definitive Edition |
| **Kind** | QoL |
| **Tested on** | Update 188329 (27 October 2026), Steam, Windows |
| **Requires** | Windows, and an internet connection on first run: it downloads Python 3.12 from python.org (about 11 MB) and numpy, fontTools and Pillow from PyPI (about 22 MB) |

## What it changes

The game draws text from pre-rendered font atlases in `resources\_common\fonts`, one set per font option:

| Font option | Stock font | Atlas files | Configured replacement |
|---|---|---|---|
| Options > Interface > Sans Serif Font **on** | Arial | `combined_sansserif.*` | Raleway Regular, with lining figures |
| Options > Interface > Sans Serif Font **off** | Times New Roman Bold | `combined.*` | Lora Bold |

- Only characters the replacement font has are redrawn. Chinese, Japanese, Korean, Indic and Greek characters it lacks keep the game's own glyphs.
- It keeps working across game updates: each computer rebuilds the atlases from the game version it has installed. The first build for a new game version takes a few minutes, and the result is cached.
- Steam puts the original fonts back when the game updates or when you verify game files. See [Re-apply automatically after updates](#re-apply-automatically-after-updates).

## Install

1. Close the game.
2. Put this folder anywhere you like (e.g. `D:\Tools\font-patch`, OneDrive, a USB stick) and keep it there after applying: its `cache` folder holds this computer's backup of the original font files.
3. Double-click `Apply.cmd`.

The tool backs up the original atlas files to `cache\` before writing anything. Files touched:

- `resources\_common\fonts\combined_sansserif.box`, `.txt`, `_NNNN.DDS`, `_NNNN.png`
- `resources\_common\fonts\combined.box`, `.txt`, `_NNNN.DDS`, `_NNNN.png`

Other scripts:

- `Status.cmd` shows what is installed for each font option.
- `Restore.cmd` puts the game's original fonts back (see [Uninstall](#uninstall)).

### Choosing fonts

Edit `fonts.json`, then run `Apply.cmd` again:

```json
{
  "sansserif": {"font": "fonts/Raleway-Regular.ttf", "features": ["lnum"]},
  "serif":     {"font": "fonts/Lora-Bold.ttf"}
}
```

- `font`: a `.ttf` or `.otf` path, relative to this folder or absolute. Included: `Raleway-Regular`, `Raleway-Medium`, `Lora-Regular`, `Lora-Bold`. Raleway Regular is fairly thin at small sizes; Raleway Medium reads more like Arial.
- `features`: OpenType features to bake in, as long as they swap glyphs one-for-one. `lnum` matters for Raleway: its default digits are old-style (3, 4, 5, 7 and 9 drop below the line), which looks odd in resource counters.
- `variations`: for variable fonts, e.g. `{"wght": 500}`.
- Remove a line to leave that font option stock.

Each font configuration is built once per game version and cached.

### Re-apply automatically after updates

Set the game's Steam launch options (right-click the game > Properties > General > Launch Options) to:

```
"C:\full\path\to\font-patch\Launch.cmd" %command%
```

On each launch it checks the font files. If they're already patched, it does nothing. If it has seen this game version before, it re-applies in about a second. If the game version is new, a console window shows the rebuild for a few minutes before the game starts. If anything fails, the game still starts.

### Command line

`Apply.cmd`, `Restore.cmd` and `Status.cmd` pass their arguments through:

| Option | Use |
|---|---|
| `--game-dir "D:\SteamLibrary\steamapps\common\AoE2DE"` | If Steam detection fails. The `AOE2DE_DIR` environment variable also works. |
| `--set sansserif` or `--set serif` | Only one of the two font options. |
| `--set serif --font "C:\path\Some.ttf" [--features lnum]` | A one-off font, ignoring `fonts.json`. |
| `--quiet` | Only print errors. |

## Uninstall

1. Close the game and double-click `Restore.cmd`. It copies the backed-up originals from `cache\` back into the game.
2. If you set the Steam launch option, clear it.
3. Alternatively, or if the `cache` folder is gone: Steam > right-click the game > Properties > Installed Files > **Verify integrity of game files** always restores the original files.

## Notes

### Safety

- Before writing, the installed files are hashed and compared with the cache. Files that are neither a stock set nor a set this tool made are never overwritten.
- A new game version is accepted as stock only if it calibrates against the game's own copies of Arial and Times New Roman Bold. Files changed by something else fail that check.
- Every copy is verified by SHA-256 afterwards, and nothing is written while the game is running.
- On first run, `setup.ps1` downloads everything into the `runtime` folder. Nothing is installed system-wide.
  - Python is kept only if `python.exe` and `python312.dll` carry a valid Authenticode signature from the Python Software Foundation.
  - numpy, fontTools and Pillow are kept only if each wheel matches the SHA-256 hash pinned in `setup.ps1`, as published on PyPI.
  - To change library versions, update the pins in `setup.ps1` and delete `runtime\site`.

### How it works

1. **Calibrate** (`calibrate.py`): fit the stock atlas against the game's own copy of the font it was rendered from, to recover the pixel scale, cell padding, offset rules and distance-field slope. If a game update breaks these assumptions, calibration fails instead of producing a broken atlas.
2. **Render** (`calibrate.py`, `sdf.py`): draw each glyph of the replacement font as a signed distance field with the same conventions.
3. **Pack** (`build.py`): free the cells of replaced glyphs and place the new cells in freed and empty space, so the page count and every untouched pixel stay as they were.
4. **Write** (`formats.py`): the `.box` glyph table, its `.txt` dump, the DDS pages with refreshed mipmaps, and PNG previews.

### Files

| Path | Contents |
|---|---|
| `Apply.cmd`, `Restore.cmd`, `Status.cmd`, `Launch.cmd`, `_run.cmd` | Entry points |
| `setup.ps1` | Downloads the Python runtime and libraries on first run |
| `fonts.json` | Which font goes into which font option |
| `app\fontpatch\` | The builder (Python) |
| `fonts\` | The included fonts and their licences, all SIL Open Font License 1.1 |
| `runtime\` | Created on first run: the Python runtime, with numpy 2.2.6, fontTools 4.60.1 and Pillow 11.3.0 in `runtime\site\` (not committed) |
| `cache\` | Created on first run: this computer's backups and builds (not committed) |
