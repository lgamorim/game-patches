# XCOM: Enemy Unknown

Patches for *XCOM: Enemy Unknown* (2012), Firaxis's turn-based tactics game, and its *Enemy Within* expansion (2013).

| | |
|---|---|
| **Stores** | Steam (app 200510). Enemy Within is DLC that installs into the same folder |
| **Versions covered** | Each patch lists the game build it was tested on |

## Where things live

- **Game install (Steam):** `<Steam library>\steamapps\common\XCom-Enemy-Unknown\`
  - Enemy Unknown: `Engine\`, `XComGame\`, `Binaries\Win32\XComGame.exe`
  - Enemy Within: the same layout inside `XEW\`, with `XEW\Binaries\Win32\XComEW.exe`
- **Per-user settings:** `Documents\My Games\XCOM - Enemy Unknown\XComGame\Config\` and `Documents\My Games\XCOM - Enemy Within\XComGame\Config\`

Patches that edit files in the install folder should say so, because a game update or a "Verify integrity of game files" in Steam will undo them.

## Patches

| Patch | Kind | Summary |
|---|---|---|
| [graphics-settings](graphics-settings/) | Mod | Raises the engine's graphics defaults (texture filtering, shadows, post-processing, draw distance, DirectX 11) in `BaseEngine.ini`, for both games |
