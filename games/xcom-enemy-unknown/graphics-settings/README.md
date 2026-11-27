# Graphics settings

Raises the game's built-in graphics defaults (texture filtering, shadows, post-processing, draw distance, DirectX 11) by merging a small set of settings into `BaseEngine.ini`.

| | |
|---|---|
| **Game** | XCOM: Enemy Unknown, and its Enemy Within expansion |
| **Kind** | Mod |
| **Tested on** | Build 848157, Steam, Windows |
| **Requires** | Windows with Windows PowerShell 5.1 (built into Windows 10 and 11). Nothing is downloaded. |

## What it changes

The game reads its engine defaults from `Engine\Config\BaseEngine.ini`. This patch changes 42 values in that file. It replaces each value on its own line and leaves every other line exactly as it was:

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
| `[SystemSettings]` | `ResX` | `1280` | `1920` | Default window width (see limitations) |
| `[SystemSettings]` | `ResY` | `720` | `1080` | Default window height (see limitations) |
| `[SystemSettings]` | `bEnableVSMShadows` | `False` | `True` | Variance shadow maps: softer shadow edges |
| `[SystemSettings]` | `bEnableForegroundShadowsOnWorld` | `False` | `True` | Foreground objects cast shadows onto the world |
| `[SystemSettings]` | `bEnableForegroundSelfShadowing` | `False` | `True` | Foreground objects shadow themselves |

The other 25 settings are `[SystemSettings]` texture groups. For each one the patch sets the filter between mipmap levels (`MipFilter`) to `aniso`; stock is `point`. `World` and `RenderTarget` also go from `MinMagFilter=point` to `aniso`. Sizes and LOD bias are unchanged.

| Texture group | Stock `MinMagFilter` / `MipFilter` | Patched | Takes effect? |
|---|---|---|---|
| `World` | `point` / `point` | `aniso` / `aniso` | No, see below |
| `WorldNormalMap`, `WorldSpecular` | `aniso` / `point` | `aniso` / `aniso` | No, see below |
| `Character`, `CharacterNormalMap`, `CharacterSpecular` | `aniso` / `point` | `aniso` / `aniso` | No, see below |
| `Weapon`, `WeaponNormalMap`, `WeaponSpecular` | `aniso` / `point` | `aniso` / `aniso` | No, see below |
| `Vehicle`, `VehicleNormalMap`, `VehicleSpecular` | `aniso` / `point` | `aniso` / `aniso` | No, see below |
| `Cinematic`, `EffectsNotFiltered`, `Skybox`, `UI` | `aniso` / `point` | `aniso` / `aniso` | No, see below |
| `Effects` | `linear` / `point` | `linear` / `aniso` | No, see below |
| `RenderTarget` | `point` / `point` | `aniso` / `aniso` | No, see below |
| `Lightmap`, `Shadowmap`, `MobileFlattened` | `aniso` / `point` | `aniso` / `aniso` | Yes |
| `ProcBuilding_Face`, `ProcBuilding_LightMap` | `aniso` / `point` | `aniso` / `aniso` | Yes |
| `Terrain_Heightmap`, `Terrain_Weightmap` | `aniso` / `point` | `aniso` / `aniso` | Yes |

[`settings.ini`](settings.ini) lists every value with a comment.

Known limitations:

- **Some settings are overridden by the game's own config.** `XComGame\Config\DefaultEngine.ini` is built on top of `BaseEngine.ini` and sets its own `[SystemSettings]` values for `ResX`, `ResY` (both `0`, meaning the desktop resolution) and for the texture groups marked "No" above. The game uses those values, so this patch's values for those keys have no effect. That was checked on both the Enemy Unknown and Enemy Within installs. The patch still writes those values, so all 25 texture groups in `BaseEngine.ini` get the same `MipFilter`.
- **Applying or restoring resets your in-game graphics options.** The game keeps your settings in `Documents\My Games\XCOM - Enemy Unknown\XComGame\Config\XComEngine.ini` (Enemy Within: `XCOM - Enemy Within`), built from these files. When `BaseEngine.ini` changes, the game rebuilds that file on its next launch (confirmed on the tested build). The patched values then take effect, but your resolution and graphics options go back to the game's defaults. Set them again under Options; whatever you change there afterwards is saved in `XComEngine.ini` and wins over the patch.
- Hardware PhysX only works with a GPU and driver that support PhysX for 32-bit games. Otherwise that setting changes nothing.
- **A game update or Steam's "Verify integrity of game files" puts the stock `BaseEngine.ini` back**, undoing the patch. Run `Apply.cmd` again afterwards.

## Install

1. Close the game.
2. Put this folder anywhere you like (e.g. `D:\Tools\graphics-settings`, OneDrive, a USB stick) and keep it there after applying: its `backup` folder holds this computer's copy of the stock files.
3. Double-click `Apply.cmd`.
4. Start the game and set your resolution and graphics options again: the game rebuilds its per-user settings from the patched file, which resets them.

It finds the game through Steam and patches Enemy Unknown and, if installed, Enemy Within. Before writing, it backs up each stock file to `backup\enemy-unknown\` or `backup\enemy-within\` in this folder. Files touched:

- `Engine\Config\BaseEngine.ini` (Enemy Unknown)
- `XEW\Engine\Config\BaseEngine.ini` (Enemy Within)

Other scripts:

- `Status.cmd` shows, for each game, whether it is stock, patched or partially patched, and whether a backup exists.
- `Restore.cmd` puts the stock files back (see [Uninstall](#uninstall)).

To change a value, edit `settings.ini` and run `Apply.cmd` again. With a backup in place, it updates the patched file. Only list values that differ from stock: a stock value in `settings.ini` would make a stock file look partially patched, and Apply would then refuse to back it up.

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
- Each file is classified before anything is written:
  - **stock**: none of the patch's values are present;
  - **patched**: all of them are;
  - **partially patched**: some of them are.
- A backup is taken only of a stock file. An already patched file is never backed up, so applying twice cannot make Restore put the patch back.
- A partially patched file is completed only if a backup already exists. Otherwise the tool refuses and points to "Verify integrity of game files".
- Applying to a patched file changes nothing. Every write goes through a temporary file, and the result is read back to check that all 42 values are present.
- Restore copies the backup back and verifies it by SHA-256. It leaves a stock file alone, for example after a game update replaced the patched one.
- Backups live only in this folder's `backup\`, never in the game folder.

### How it works

`apply.ps1` merges [`settings.ini`](settings.ini), an overlay of `Key=Value` lines grouped by `[Section]`, into the game file:

1. Each overlay key that exists in its section has its value replaced on that line. The key's spelling and the spacing around `=` are kept.
2. A missing key is inserted after the last setting of its section. A missing section is added at the end of the file.
3. Every other line stays byte-for-byte unchanged. The file keeps its encoding (byte order mark, if any) and line endings. The stock files are ASCII with CRLF line endings.

The merge refuses to guess. Keys repeated in a section (UE3 array style), sections that appear twice, and overlay lines using array syntax (`+Key`, `-Key`, `.Key`, `!Key`) all stop it with an error.

### Files

| Path | Contents |
|---|---|
| `Apply.cmd`, `Restore.cmd`, `Status.cmd` | Entry points: each runs `apply.ps1` with its verb |
| `apply.ps1` | All the logic (PowerShell) |
| `settings.ini` | The settings to merge, with a comment on each |
| `tests\apply.Tests.ps1` | Pester tests for the merge, state detection, encodings, options and the apply/restore/status flow, on synthetic files |
| `backup\` | Created on first apply: this computer's stock backups (not committed) |

To run the tests: `powershell -NoProfile -Command "Invoke-Pester -Path .\tests"`. They run on the Pester 3.4 that ships with Windows, and on Pester 5.
