# BindHUD

A Windower 4 addon that shows your keyboard binds on screen, so you can see which key and modifier trigger each spell, ability or toggle.

It is display-only. It never sends packets, never runs commands, never types into chat or writes to the chat log, and never blocks keys. Command replies (e.g. `//bh files`) go to the Windower console. It reads your files, draws the overlay, and watches the Ctrl/Alt/Shift/Win keys to highlight the layer you are holding.

## Views

Switch with `//bh view`.

- **Keyboard** (default): a full keyboard with every key in its real position. Each bound key lists all of its binds. The coloured letter in front of each bind is the modifier to hold: **C** Ctrl, **A** Alt, **S** Shift, **W** Win, **-** none. Holding a modifier lights up the keys for that layer and dims the other binds. The Ins/Del/arrow block appears when you have binds there, and the numpad when a numpad key is bound (see `//bh numpad`).
- **Cheat sheet**: every action grouped into spells, abilities, toggles, cycles, modes and other, in alphabetical order, with the keys to press. Use it when you know the spell's name but not its key.

Label colours: spell (blue), ability / weapon skill (gold), toggle (orange), cycle (violet), mode (teal), other (grey).

## Install

1. Copy this `BindHUD` folder to `Windower4/addons/BindHUD/`.
2. In game: `//lua load bindhud`
3. To load it every time, add `lua load bindhud` to `Windower4/scripts/init.txt`.

## What it reads

- `scripts/init.txt`, plus any script it `exec`s
- Any file with "globals" in its name in `GearSwap/data/` or `GearSwap/data/<YourName>/` (e.g. `Globals.lua`, `YourName-Globals.lua`, `user-globals.lua`). Another character's globals file (`Othername-Globals.lua`) is skipped.
- The GearSwap job file GearSwap would load for your current job (`Name_JOB.lua`, `JOB.lua`, and so on, searched in the same order GearSwap uses)
- Every file that job file `include()`s, such as Mote-Include or Sel-Include and their globals
- A `_Gear` sidecar (`Name_JOB_Gear.lua` or `JOB_Gear.lua`)
- Any extra files listed in `extra_files` in `data/settings.xml` (comma separated; `{name}` and `{job}` are filled in)

Commented-out binds are ignored. If the same key and modifiers are bound twice, the bind loaded last is shown. The overlay rescans automatically when you change jobs.

**Limits:** BindHUD reads your files; it does not run them. A bind inside an `if` (for example, only when your subjob is SCH) is always shown. A bind whose key is built from a variable can't be read.

## Commands (`//bh` or `//bindhud`)

| Command | What it does |
|---|---|
| `//bh` | Show or hide the overlay |
| `//bh view` | Switch between the keyboard and the cheat sheet (or `//bh view keyboard`, `//bh view cheatsheet`) |
| `//bh peek` | Switch between always shown (default) and peek, where it only appears while you hold a modifier |
| `//bh size 10` | Text size; the keys resize to fit |
| `//bh keywidth 8` | Label characters per key. Smaller makes the keyboard narrower (long words break with a hyphen). `//bh keywidth auto` to reset |
| `//bh numpad auto` | Numpad block: `auto` shows it only when a numpad key is bound, `on` always, `off` never |
| `//bh pos 50 400` | Move the overlay to a screen position |
| `//bh rescan` | Re-read your files after you edit binds |
| `//bh files` | List the files that were read and how many binds each had |

Drag the title bar to move the overlay. The position is saved when you let go.

Tip: bind a key to show and hide it, e.g. in init.txt: `bind ^h bh`.
