# BindHUD

A Windower 4 addon that shows your keyboard binds on screen, so you can see which key and modifier trigger each spell, ability or toggle.

It is display-only. It never sends packets, never runs commands, never types into chat or writes to the chat log, and never blocks keys. Command replies (e.g. `//bh files`) go to the Windower console. It reads your files, draws the overlay, and watches the Ctrl/Alt/Shift/Win keys to highlight the layer you are holding.

## Views

Switch with `//bh view`.

- **Keyboard** (default): your bound keys in keyboard order, each listing all of its binds. The coloured letter in front of each bind is the modifier to hold: **C** Ctrl, **A** Alt, **S** Shift, **W** Win, **-** none. Holding a modifier lights up the keys for that layer and dims the other binds. The main keys are **packed**: rows stay in keyboard order (F-keys, number row, Q row, A row, Z row) and keys stay left to right, but keys without binds are left out so the board stays compact. The Ins/Del/arrow block and the numpad keep their real grid and appear when you have binds there (see `//bh numpad`). `//bh layout full` shows every key in its real position instead, which is much wider.
- **Cheat sheet**: every action grouped into spells, job abilities, auto and commands, in alphabetical order, with the keys to press. Use it when you know the spell's name but not its key.

Label colours:

- **Spells** (blue): `/ma`, songs, ninjutsu
- **Job abilities** (gold): `/ja`, weapon skills, pet commands, items
- **Auto** (orange): GearSwap toggles and settings whose name starts with "Auto" (Auto Buff, Auto Stun, ...)
- **Commands** (violet): everything else, such as mode cycles, `gs reload` and `/target`

**Fits any screen.** Key sizes are measured from the font in game, and both views fit themselves to your screen's UI resolution. By default the keyboard keeps within 65% of your screen's width and 45% of its height (`//bh fit`). Labels only wrap between words, so keys are always at least wide enough for the longest word on them (very long single words may still break). Within that, it uses the largest text that fits and the widest keys at that size. If that can't fit, it uses the largest layout that fits your screen's width, down to text size 6. On a small screen it can therefore stay larger than the limit. The cheat sheet uses fewer columns on narrow screens. If you set `//bh keywidth` yourself, your setting is used as-is.

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
| `//bh fit 65 45` | Keep the keyboard within this percentage of your screen's width and height (default 65% wide, 45% tall). `//bh fit off` turns it off so `//bh size` and `//bh keywidth` set the size |
| `//bh opacity 80` | How solid the overlay is, from 1 (almost invisible) to 100 (fully solid). Default 60. Applies to the keys, text and title bar. `//bh opacity` on its own shows the current value |
| `//bh layout` | Switch the keyboard between packed (only keys with binds, default) and full (every key in its real position) |
| `//bh targets` | Show or hide targeting binds (`/ta`, `/target`), such as alliance targeting on Ctrl/Alt+F1-F6. Hidden by default |
| `//bh keywidth 8` | Label characters per key. Smaller makes the keyboard narrower (long words break with a hyphen). `//bh keywidth auto` to reset |
| `//bh numpad auto` | Numpad block: `auto` shows it only when a numpad key is bound, `on` always, `off` never |
| `//bh pos 50 400` | Move the overlay to a screen position |
| `//bh rescan` | Re-read your files after you edit binds |
| `//bh files` | List the files that were read and how many binds each had |

Drag the title bar to move the overlay. The position is saved when you let go.

Tip: bind a key to show and hide it, e.g. in init.txt: `bind ^h bh`.
