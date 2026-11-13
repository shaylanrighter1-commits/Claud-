# ABOVE[RUINS] | AUTO BUILDER (MacSploit)

One file: `AutoBuilder_MacSploit.lua`. Paste the whole file into MacSploit and execute.

```
ABOVE[RUINS] | AUTO BUILDER
[ SELECT AREA ]
BLOCK: GRASS BLOCK
NEEDED: 100 | OWNED: 150
[ AUTO PLACE ]           ->  [ STOP 45/100 ] while it runs  ->  [ RESUME 45/100 ] after a stop
[ CLEAR SELECTION ]
STATUS: READY
```

## How it works: you walk, it places
1. `[ SELECT AREA ]`, click corner A, then corner B. The area is **one flat layer** (point B takes point A's height,
   so there is no stacking). The orange outline shows it; the status line says how many spots are empty and how many
   are already filled.
2. Select your block in the hotbar (the menu shows `BLOCK:` and `NEEDED | OWNED`).
3. `[ AUTO PLACE ]`. Now **you** walk around the area (first person is fine) and look at the floor. Whenever your
   crosshair points at a spot of the area that has no block yet, one block is placed there, exactly as if you had
   clicked. Look at every spot (the status line and the orange outline show what is left); it says Done when the whole
   area is filled.
4. The same button is `[ STOP ]` while it runs and `[ RESUME ]` after a stop. `[ CLEAR SELECTION ]` forgets the area.
5. RightShift hides / shows the menu. Click the STATUS line to copy the debug log.

What it does with each look (about every tenth of a second): works out which grid cell the game would put a block into
at the crosshair; if that is an empty spot of the area, checks again 50 ms later that you are still pointing at it
(so nothing is clicked while you turn), compares it with the game's own placement preview when that can be read, and
only then clicks. It **never moves your mouse, camera or character**; it only clicks where you are already pointing.

## What can and cannot work through MacSploit
| Wish | Through MacSploit |
|---|---|
| Two-point selection snapped to the block grid, orange outline, flat area | **Works** |
| Skip occupied spots, never place outside the outline, never duplicate, count only confirmed blocks | **Works** (tested in simulation) |
| Place blocks as you walk and look around | **Works** (this version) - one click per block, with the game's own checks |
| Use blocks from your inventory | **Works**, because the game's own placement uses them; the script only clicks |
| All blocks appear instantly, or filling from 100 blocks away | **Not possible.** The game's server checks distance and inventory on every placement. Spots out of reach are simply skipped until you are close enough |

Instant or remote filling needs a bulk-build feature on the game's **server** (offered by the game's developers).
This script does not invent or call private remotes.

## What it never does
* Never walks, jumps or teleports your character. Never touches your camera.
* Never calls the game's remotes, never touches your inventory, never bypasses server rules.
* Never counts a block it did not see appear: a block is counted only when exactly one new, opaque,
  block-sized part appears in exactly the cell that was aimed at.

## What it does
For each empty cell it finds a visible face next to it (from your camera exactly as you left it), moves the mouse
there, clicks with your block in hand, and checks the result. Existing blocks are skipped. Rows are filled in one
fixed order (bottom layer first, rows starting at the end farthest from you, every row in the same direction).

## Why the earlier versions went wrong, and what changed
| Problem you saw | Cause | Fix |
|---|---|---|
| Walked off the island | v4 auto-walked | walking and camera control **removed**; if a cell is out of reach it stops and tells you |
| Blocks in the wrong cells, gaps | the game's translucent placement preview was accepted as a block; the grid origin could drift; trench cells were invisible to the camera | preview is ignored; grid is only aligned once (first block, <= 0.45 block) then never moved; every block must land in the aimed cell or the build stops |
| Wrong progress | counted clicks / re-counted | `placed` counts only verified blocks, can never exceed `total`, resets for each new job |
| Block not recognised | custom hotbar, no Tool objects | hotbar GUI is read directly (name, count, highlighted slot) |

Client-side aiming (camera, cursor, visible faces) is the script's job; the placement distance, ownership and
cooldowns are the **game's**. The script cannot know the real range: it learns it from refusals and then reports
`[RANGE] OUT OF RANGE`. Cells your camera cannot see are reported as `[AIM]`: tilt / turn the camera and resume.

Failure tags: `[ITEM] [INPUT] [AIM] [RANGE] [PLACEMENT] [DETECTION]`.

## What was tested, and what was NOT
**Tested outside Roblox (simulated, Lua 5.5 via `lupa`):**
* `python3 roblox/tests/run_core_tests.py`: 41 tests of the decision logic embedded in the script (build order,
  checking a placed block's cell, which spots may be tried, counters, duplicate protection, range learning, strays).
* `python3 roblox/tests/run_glue_tests.py`: 31 tests that run the script's real `walkPlace` / `runWalk` /
  `autoBuild` / `stop` against a simulated player and world: walking around a floor, existing blocks, nothing outside
  the area or on the layer above, only clicking when you hold still, out-of-range spots, stop / resume / clear,
  out of blocks, a deselected block, wrong placement (inside / outside the area), the flat selection, grid offset.
* Mutation checks: deliberately breaking the logic makes these tests fail (a few redundant safety checks are
  intentionally duplicated and not individually detectable).
* Static checks: block balance, no undefined names, no remote / hook references.

**NOT tested: the real game.** The simulated world is my model of Roblox. Nothing here has run inside Roblox or
ABOVE[RUINS]. The raycast from your crosshair (especially in first person, where the mouse is locked to the screen centre),
the executor's click events, the custom hotbar reading, and whether the game accepts a click on a block face as a
placement are untested. Expect to need one or two rounds of fixes after the first real run.
If something fails, click the STATUS line, which copies the log, and send it to me.

Known limits: glass-like (translucent) blocks are not recognised as blocks; you have to look at each spot yourself;
running scripts through an executor is against Roblox's Terms of Use and can get an account banned.
