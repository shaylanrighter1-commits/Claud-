# ABOVE[RUINS] | AUTO BUILDER — server-authorized version

Select two corners, equip a block, press **AUTO BUILD**. The **server** places the real blocks and takes them
from your inventory, so you can stand anywhere — 100 blocks away is fine. Your character and camera are never touched.

```
ABOVE[RUINS] | AUTO BUILDER
[ SELECT AREA ]
BLOCK: GRASS BLOCK
NEEDED: 120 | OWNED: 300
[ AUTO BUILD ]            ->  [ BUILDING 45/120 ]  ->  [ RESUME 45/120 ] / [ DONE 120/120 ]
[ STOP ]
━━━━━━━━━━━━━━━━━━  (progress bar)
STATUS: BUILDING 45/120
```

## Why this cannot work from MacSploit, and what is needed

From an executor you can only act as the player: the game's **server** decides whether a placement is allowed
(distance, ownership, inventory), and it refuses far-away ones. Getting around that would mean calling the game's
internal remotes with forged positions or moving the character — that is bypassing the server's rules, so it is
not built here.

A hands-free "build from anywhere" feature has to run **on the server**, as part of the game. You need one of:

1. **You own / develop the game** (Studio edit access, or Team Create with script access). Install this version
   (below) and connect the six functions in `Backend.lua` to your own inventory and placement code.
2. **You do not own it, but its developers will add it.** Send them this folder. They only need to connect
   `Backend.lua` to their server code (inventory, land permission, block placement). The game then enforces its
   own rules; the distance rule is replaced by a *permission* rule that the developers control.
3. Neither of the above: it cannot be done properly. (An executor script that fires the game's remotes from a
   distance would only work through a flaw in the game's checks, which this project will not use.)

## Install in Roblox Studio (test it in a blank Baseplate first)

1. Open a Baseplate. **View → Command Bar**.
2. Open `roblox/server_version/Install_AutoBuilder.lua`, copy **all** of it, paste into the Command Bar, press Enter.
   It prints `Installed 5 scripts.` (Rojo users: `rojo serve` with `default.project.json`.)
3. Press **Play**. You get four block Tools in the normal hotbar (Grass Block, Dirt Block, Stone Block, Wood Planks,
   300 each) and the menu on the right.
4. **SELECT AREA** → click corner A, click corner B (an orange outline shows the area). Tip: put the block away
   while choosing, or your game may also react to the click.
5. Equip **Grass Block** (press its number) → **AUTO BUILD**. Walk away, fly far off, it keeps building.
   **STOP** pauses; the button then says **RESUME**. Out of blocks → it pauses and says how many more it needs.

Test-world rules: you may build in a 120 × 120 cell box around the origin, up to 40 cells high.

## What the server does

* The client sends only `start` / `stop` and two corner cells. The server re-checks everything: the corners are
  whole numbers in range, the area is at most `MAX_CELLS` (4000), **the block is whatever the server sees in your
  hand** (never what the client claims), you own it, and you may build in every cell.
* For each empty cell, in a fixed order (bottom layer first): take one block from the inventory → place it → count
  it. If the placement fails the block is handed back. So the inventory goes down by exactly the number of blocks
  placed. Cells that already hold a block are skipped and never overwritten.
* Out of blocks → pauses (`RESUME` continues, nothing is placed twice). After finishing it looks again and fills
  anything still empty before saying DONE.
* Speed: `BLOCKS_PER_SECOND` (30 by default) in `Shared.lua`. Up to 10 builds run at once on a server.

## Using it in your real game (`Backend.lua`)

Set `Backend.TEST_WORLD = false` and make these call your own server code:

| Function | Must do |
|---|---|
| `getEquipped(player)` | what the player holds: `{ id, name, owned }` |
| `getOwned(player, id)` | how many they own |
| `take(player, id, n)` / `give(player, id, n)` | remove / return blocks (false if not enough) |
| `canBuild(player, cell)` | land / permission check for that cell |
| `isOccupied(cell)` | is there already a block |
| `place(player, id, cell)` | really place it, through your game's normal placement function |

`Shared.lua`'s `GRID` and `ORIGIN` must match your game's block grid. If your world streams (StreamingEnabled), the
two corners must be visible to the client when you click them; the server itself does not care about distance.

## What was tested — and what was not

Tested outside Roblox (Lua 5.5 / `lupa`, `python3 roblox/server_version/tests/run_tests.py`):
* 26 tests of the build rules (inventory conservation, no overwrite, no duplicates, permission, out of blocks,
  stop / resume, big areas) and 23 tests that run the **real server script** against a simulated Roblox: garbage from
  the client, the item decided by the server, inventory, out of blocks, stop / resume, permissions, many players,
  a player leaving. Deliberately breaking the code makes these fail (a few redundant safety checks excepted).
* The installer was run against a stub Studio and produces exactly the files in this folder.

**Not tested: Roblox Studio itself.** The test-world backend (real Parts, Tools, attributes, the raycast / overlap
queries) and the whole client menu (UI layout, mouse picking, the orange outline) have never been run in Studio.
Expect to send me red text from the Output window after the first Play.
