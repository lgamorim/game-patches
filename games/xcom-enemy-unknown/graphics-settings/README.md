# Graphics settings

Raises the game's built-in graphics defaults (texture filtering, shadows, post-processing, draw distance, DirectX 11) by merging a small set of settings into `BaseEngine.ini` and `DefaultEngine.ini`.

| | |
|---|---|
| **Game** | XCOM: Enemy Unknown, and its Enemy Within expansion |
| **Kind** | Mod |
| **Tested on** | Build 848157, Steam, Windows |
| **Requires** | Windows with Windows PowerShell 5.1 (built into Windows 10 and 11). Nothing is downloaded. |

## What it changes

Each game reads its engine defaults from two files in its install folder. `XComGame\Config\DefaultEngine.ini` is built on top of `Engine\Config\BaseEngine.ini`, and where both set a value, `DefaultEngine.ini` wins. The patch changes values in both files. It edits each value on its own line and leaves every other line exactly as it was.

### `BaseEngine.ini`: 42 values, from [`base-engine.ini`](base-engine.ini)

| Section | Setting | Stock | Patched | What it does |
|---|---|---|---|---|
| `[Engine.Engine]` | `bDisablePhysXHardwareSupport` | `True` | `False` | Lets PhysX use hardware (GPU) acceleration where the system supports it |
| `[XAudio2.XAudio2Device]` | `MaxChannels` | `32` | `96` | Sounds that can play at once (Windows audio device) |
| `[ALAudio.ALAudioDevice]` | `MaxChannels` | `32` | `96` | Sounds that can play at once (OpenAL audio device) |
| `[SystemSettings]` | `bHighQualityFOWFiltering` | `False` | `True` | Smoother fog-of-war edges |
| `[SystemSettings]` | `PostProcessQuality` | `0` | `2` | Post-processing quality level |
| `[SystemSettings]` | `FXAAQuality` | `1` | `2` | FXAA anti-aliasing quality level |
| `[SystemSettings]` | `AllowD3D11` | `False` | `True` | Allows the DirectX 11 renderer |
| `[SystemSettings]` | `AllowSubsurfaceScattering` | `False` | `True` | Light passing through skin and other translucent surfaces |
| `[SystemSettings]` | `MaxDrawDistanceScale` | `1` | `2` | How far away objects are still drawn |
| `[SystemSettings]` | `MaxAnisotropy` | `4` | `16` | Anisotropic filtering: sharper textures at shallow angles |
| `[SystemSettings]` | `MaxShadowResolution` | `1120` | `2048` | Largest shadow map for one object's shadow |
| `[SystemSettings]` | `MaxWholeSceneDominantShadowResolution` | `1344` | `2048` | Largest shadow map for the main light's whole-scene shadow |
| `[SystemSettings]` | `ResX` | `1280` | `1920` | Default window width (no effect, see below) |
| `[SystemSettings]` | `ResY` | `720` | `1080` | Default window height (no effect, see below) |
| `[SystemSettings]` | `bEnableVSMShadows` | `False` | `True` | Variance shadow maps: softer shadow edges |
| `[SystemSettings]` | `bEnableForegroundShadowsOnWorld` | `False` | `True` | Foreground objects cast shadows onto the world |
| `[SystemSettings]` | `bEnableForegroundSelfShadowing` | `False` | `True` | Foreground objects shadow themselves |

The other 25 values are `[SystemSettings]` texture groups: `MipFilter` (the filter between mipmap levels) goes from `point` to `aniso` in each, and `World` and `RenderTarget` also go from `MinMagFilter=point` to `aniso`. Sizes and LOD bias are unchanged.

### `DefaultEngine.ini`: 21 values, from [`default-engine.ini`](default-engine.ini)

`DefaultEngine.ini` sets its own `[SystemSettings]` line for 21 texture groups, so `BaseEngine.ini`'s filtering doesn't reach them. In each of those lines the patch changes only `MipFilter`, from `point` to `linear`: the game then blends the two nearest mipmap levels (trilinear filtering) instead of switching abruptly between them, which removes visible bands where texture detail drops with distance. Each game's own sizes, LOD bias and `MinMagFilter` stay as they are; Enemy Unknown and Enemy Within use different sizes for several groups.

### Texture filtering the game ends up using

| Texture groups | Set in | `MinMagFilter` | `MipFilter` |
|---|---|---|---|
| `Character`, `CharacterNormalMap`, `Cinematic`, `EffectsNotFiltered`, `LightAndShadowMap`, `RenderTarget`, `Vehicle`, `VehicleNormalMap`, `Weapon`, `WeaponNormalMap`, `World`, `WorldHIGH`, `WorldNormalMap` | `DefaultEngine.ini` | `aniso` (unchanged) | `point` → `linear` |
| `CharacterSpecular`, `Effects`, `Skybox`, `UI`, `UI3D`, `VehicleSpecular`, `WeaponSpecular`, `WorldSpecular` | `DefaultEngine.ini` | `linear` (unchanged) | `point` → `linear` |
| `Lightmap`, `Shadowmap`, `MobileFlattened`, `ProcBuilding_Face`, `ProcBuilding_LightMap`, `Terrain_Heightmap`, `Terrain_Weightmap` | `BaseEngine.ini` | `aniso` (unchanged) | `point` → `aniso` |

The patch also writes `BaseEngine.ini` lines for the 18 groups that `DefaultEngine.ini` overrides, so all 25 texture groups there get the same `MipFilter`. Those 18 lines have no effect.

Known limitations:

- **`ResX` and `ResY` have no effect.** `DefaultEngine.ini` sets both to `0`, which means the desktop resolution. The patch leaves that on purpose, so the 1920×1080 in `BaseEngine.ini` never applies.
- **`MipFilter=aniso` in `BaseEngine.ini` is unverified.** Unreal Engine 3 documents only `point` and `linear` for `MipFilter`, and GPUs have no anisotropic mode between mipmap levels. Whether the engine reads `aniso` there as `linear` hasn't been confirmed. Of the groups it applies to, only the seven set in `BaseEngine.ini` reach the game; `DefaultEngine.ini` uses `linear`.
- **Applying or restoring resets your in-game graphics options.** The game keeps your settings in `Documents\My Games\XCOM - Enemy Unknown\XComGame\Config\XComEngine.ini` (Enemy Within: `XCOM - Enemy Within`), built from these files. When `BaseEngine.ini` or `DefaultEngine.ini` changes, the game rebuilds that file on its next launch (confirmed on the tested build: the rebuilt file carries the patched values from both). The patched values then take effect, but your resolution and graphics options go back to the game's defaults. Set them again under Options; whatever you change there afterwards is saved in `XComEngine.ini` and wins over the patch.
- Hardware PhysX only works with a GPU and driver that support PhysX for 32-bit games. Otherwise that setting changes nothing.
- **A game update or Steam's "Verify integrity of game files" puts the stock files back**, undoing the patch. Run `Apply.cmd` again afterwards.

## Install

1. Close the game.
2. Put this folder anywhere you like (e.g. `D:\Tools\graphics-settings`, OneDrive, a USB stick) and keep it there after applying: its `backup` folder holds this computer's copy of the stock files.
3. Double-click `Apply.cmd`.
4. Start the game and set your resolution and graphics options again: the game rebuilds its per-user settings from the patched files, which resets them.

It finds the game through Steam and patches Enemy Unknown and, if installed, Enemy Within. Before writing, it backs up each stock file to `backup\enemy-unknown\` or `backup\enemy-within\` in this folder. Files touched:

- `Engine\Config\BaseEngine.ini` and `XComGame\Config\DefaultEngine.ini` (Enemy Unknown)
- `XEW\Engine\Config\BaseEngine.ini` and `XEW\XComGame\Config\DefaultEngine.ini` (Enemy Within)

If you applied an earlier version of this patch, which only changed `BaseEngine.ini`, run `Apply.cmd` again: it leaves `BaseEngine.ini` and its backup alone and patches `DefaultEngine.ini`.

Other scripts:

- `Status.cmd` shows, for each game and each file, whether it is stock, patched, partially patched or patched with other values, and whether a backup exists. It also says whether the game will rebuild `XComEngine.ini` on its next launch.
- `Restore.cmd` puts the stock files back (see [Uninstall](#uninstall)).

To change a value, edit `base-engine.ini` or `default-engine.ini` and run `Apply.cmd` again. With a backup in place, it updates the patched file. Only list values that differ from stock: a stock value in an overlay would make a stock file look partially patched, and Apply would then refuse to back it up.

## Uninstall

1. Close the game and double-click `Restore.cmd`. It copies the backed-up stock files from `backup\` back into the game and verifies them by SHA-256. On the next launch the game rebuilds your per-user settings again, so set your resolution and graphics options once more.
2. Alternatively, or if the `backup` folder is gone: Steam > right-click XCOM: Enemy Unknown > Properties > Installed Files > **Verify integrity of game files** always restores the stock files.

## Command line options

`Apply.cmd`, `Restore.cmd` and `Status.cmd` pass their arguments through to `apply.ps1`:

| Option | Use |
|---|---|
| `--game-dir "D:\SteamLibrary\steamapps\common\XCom-Enemy-Unknown"` | If Steam detection fails. The `XCOM_EU_DIR` environment variable also works. Pointing it at the `XEW` folder patches only Enemy Within. |
| `--target eu` or `--target ew` | Only Enemy Unknown or only Enemy Within. |
| `--quiet` | Only print errors (`Status.cmd` still prints its report). |

The game folder is found in this order: `--game-dir`, then `XCOM_EU_DIR`, then Steam (`SteamPath` in the registry, every library in `steamapps\libraryfolders.vdf`, and the `installdir` in `appmanifest_200510.acf`). If none of these works, it stops and asks for `--game-dir`.

## Notes

### Safety

- Nothing is written while `XComGame.exe` or `XComEW.exe` is running.
- Each file is handled on its own, and classified before anything is written:
  - **stock**: none of the patch's values for that file are present;
  - **patched**: all of them are;
  - **partially patched**: some of them are.
- A backup is taken only of a stock file. An already patched file is never backed up, so applying twice cannot make Restore put the patch back.
- A partially patched file is completed only if a backup already exists. Otherwise the tool refuses for that file and points to "Verify integrity of game files"; the other files are still handled.
- Applying to a patched file changes nothing. Every write goes through a temporary file, and the result is read back to check that every value is present.
- A file that differs from its stock backup only on lines this patch edits holds other values for the same settings, for example from an earlier version of this patch. Apply never backs it up: it stops and asks you to run `Restore.cmd` first, and Restore puts the stock backup back.
- Restore copies the backup back and verifies it by SHA-256. It leaves a stock file alone, for example after a game update replaced the patched one.
- Backups live only in this folder's `backup\`, never in the game folder.
- `XComEngine.ini` in `Documents\My Games` is only ever read, by `Status.cmd`.

### How it works

`apply.ps1` merges two overlays, each a list of entries grouped by `[Section]`:

| Overlay | Game file |
|---|---|
| [`base-engine.ini`](base-engine.ini) | `Engine\Config\BaseEngine.ini` |
| [`default-engine.ini`](default-engine.ini) | `XComGame\Config\DefaultEngine.ini` |

An entry is one of two kinds:

- **`Key=Value`** replaces the value on the key's line, keeping the key's spelling and the spacing around `=`. A missing key is inserted after the last setting of its section, and a missing section is added at the end of the file.
- **`Key.Field=Value`** changes one field inside the key's `(Field=...,Field=...)` value, such as `TEXTUREGROUP_World.MipFilter=linear`. Only top-level fields count: nested `(...)` and quoted text are skipped. The other fields and the spacing stay as they are. These entries never add lines, so a missing key, section or field is an error.

Every other line stays byte-for-byte unchanged. The file keeps its encoding (byte order mark, if any) and line endings. The stock files are ASCII with CRLF line endings.

The merge refuses to guess. Keys repeated in a section (UE3 array style), sections that appear twice, fields that appear twice, and overlay lines using array syntax (`+Key`, `-Key`, `.Key`, `!Key`) all stop it with an error.

### Files

| Path | Contents |
|---|---|
| `Apply.cmd`, `Restore.cmd`, `Status.cmd` | Entry points: each runs `apply.ps1` with its verb |
| `apply.ps1` | All the logic (PowerShell) |
| `base-engine.ini` | The `BaseEngine.ini` settings to merge, with a comment on each |
| `default-engine.ini` | The `DefaultEngine.ini` texture-filter fields to change, with a comment on each |
| `tests\apply.Tests.ps1` | Pester tests for both kinds of merge, state detection, encodings, options and the apply/restore/status flow, on synthetic files |
| `backup\` | Created on first apply: this computer's stock backups (not committed) |

To run the tests: `powershell -NoProfile -Command "Invoke-Pester -Path .\tests"`. They run on the Pester 3.4 that ships with Windows, and on Pester 5.
