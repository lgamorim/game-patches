# game-patches

A collection of custom mods, bug fixes, and quality-of-life patches for PC games.

## Layout

Each game gets its own folder under `games/`, and each patch gets its own folder inside that game's folder:

```
games/
  <game-name>/
    README.md              # About the game: which versions and stores are covered, list of patches
    <patch-name>/
      README.md            # What the patch does and how to install it (see templates/patch/README.md)
      ...                  # Patch files: configs, scripts, replacement assets, source, etc.
templates/
  patch/
    README.md              # Starting point for a new patch's README
```

Naming:

- Folder names are lowercase with hyphens, e.g. `games/example-game/skip-intro-videos`.
- A patch fits one of three kinds, recorded in its README:
  - **Fix**: corrects a bug in the game.
  - **QoL**: quality-of-life tweak that keeps the game's design but removes friction.
  - **Mod**: changes or adds gameplay, content, or visuals.

## Adding a patch

1. Create `games/<game-name>/` if it doesn't exist yet, with a short `README.md`.
2. Copy `templates/patch/` to `games/<game-name>/<patch-name>/`.
3. Fill in the README: the game version it was tested on, what it changes, and how to install and uninstall it.
4. Add the patch to the list in the game's `README.md`.

## Games

- [Age of Empires II: Definitive Edition](games/age-of-empires-2-definitive-edition/)
- [XCOM: Enemy Unknown](games/xcom-enemy-unknown/)

## Disclaimer

These patches are unofficial and are not affiliated with or endorsed by the games' developers or publishers. Back up your game files and saves before applying anything. Only files written for this project live here: no original game files or copyrighted game assets are included.

## License

[MIT](LICENSE)
