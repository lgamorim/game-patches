# Age of Empires II: Definitive Edition

Patches for *Age of Empires II: Definitive Edition* (2019), the remaster of the classic real-time strategy game.

| | |
|---|---|
| **Stores** | Steam (app 813780), Microsoft Store / Xbox app |
| **Versions covered** | Each patch lists the game build it was tested on |

## Where things live

- **Game install (Steam):** `<Steam library>\steamapps\common\AoE2DE\`
- **User data and local mods:** `%USERPROFILE%\Games\Age of Empires 2 DE\<profile ID>\`, with local mods in `mods\local\`

Prefer shipping a patch as a local mod in `mods\local\`, which the game loads without touching the install folder. Patches that must edit files in the install folder should say so, because a game update or a "Verify integrity of game files" in Steam will undo them.

## Patches

| Patch | Kind | Summary |
|---|---|---|
| [font-patch](font-patch/) | QoL | Replaces the two in-game fonts (default: Raleway and Lora Bold) by rebuilding the game's font atlases |
