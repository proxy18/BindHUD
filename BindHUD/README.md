# BindHUD

A Windower 4 addon that shows your keyboard binds as an on-screen grid, so you can see which keys and modifiers trigger each bind.

It is display-only. It never sends packets, never runs commands, never types into chat or writes to the chat log, and never blocks keys. Command replies (e.g. `//bh files`) go to the Windower console. It reads your files, draws a text box, and watches the Ctrl/Alt/Shift/Win keys to highlight the layer you are holding.

## Install

1. Copy this `BindHUD` folder to `Windower4/addons/BindHUD/`.
2. In game: `//lua load bindhud`
3. To load it every time, add `lua load bindhud` to `Windower4/scripts/init.txt`, near the top of the addon list (before addons like GearInfo), so it receives mouse events for dragging.

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
| `//bh rescan` | Re-read your files after you edit binds |
| `//bh mode always` | Always show the full grid; the layer you hold lights up green |
| `//bh mode hold` | Show a short list: your plain keys when nothing is held, then only the layer you hold, plus dimmed hints for binds that need one more modifier |
| `//bh size 10` | Font size |
| `//bh width 14` | Longest label before it is cut off |
| `//bh files` | List the files that were read and how many binds each had |
| `//bh pos 50 400` | Move the box to a screen position (pixels from the top-left) |

Drag the box to move it. The position is saved when you let go.

**If the box won't drag:** another addon loaded before BindHUD may be claiming mouse events, and Windower doesn't pass a claimed event on to addons loaded later. Load BindHUD earlier in `scripts/init.txt` (for example right after `lua load skillchains`) instead of loading it by hand. Or place it with `//bh pos <x> <y>`.

In `data/settings.xml`: set `hold_idle` to `hide` to hide the box in hold mode while nothing is held, and `show_next` to `false` to turn off the dimmed hints.

Tip: bind a key to toggle it, e.g. in init.txt: `bind ^h bh`.
