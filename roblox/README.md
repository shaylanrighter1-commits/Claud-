# ABOVE[RUINS] | WORLDEDIT (MacSploit)

One file: `AutoBuilder_MacSploit.lua`. Paste the whole file into MacSploit and execute.

```
ABOVE[RUINS] | WORLDEDIT
[ SELECT AREA ]
BLOCK: GRASS BLOCK
NEEDED: 100 | OWNED: 150
[ FILL ]                 ->  [ STOP 45/100 ] while it builds  ->  [ RESUME 45/100 ] after a stop
[ CLEAR SELECTION ]
STATUS: READY
```

## What can and cannot work through MacSploit
| WorldEdit feature | Through MacSploit |
|---|---|
| Two-point selection snapped to the block grid, orange outline | **Works** (unchanged) |
| Show what will be filled | **Works**: outline + `NEEDED` (empty cells) + a status line "N to fill, M already filled" |
| Skip occupied cells, never place outside the outline, never duplicate, count only confirmed blocks | **Works** (tested in simulation) |
| Use blocks from your inventory | **Works**, because the game's own placement uses them; the script only clicks |
| All blocks appear instantly (`//set`) | **Not possible.** A client script can only do what you can do: one click = one block. There is no bulk call it is allowed to use. The button is called FILL, not INSTANT FILL, on purpose |
| Fill from 100 blocks away | **Not possible.** The game's server checks the distance on every placement. The script reports `[RANGE]` and never claims otherwise |
| Move the character / camera | It never does |

Instant or remote filling needs a bulk-build feature on the game's **server**, offered by the game (for example by its
developers). This script does not invent or call private remotes. If the game has its own area / bulk tool in its
UI, tell me how it works and the script can drive it through the normal UI.

## How to use
1. `[ SELECT AREA ]`, then click corner A and corner B. The orange outline is exactly what gets filled.
2. Select your block in the hotbar. The menu shows `BLOCK:` and `NEEDED | OWNED`.
3. `[ FILL ]`. The same button says `[ STOP ]` while it builds. If it stops because of a problem, fix it and press
   the button again: it says `[ RESUME x/y ]` and carries on with the same count (nothing is placed twice).
   `[ CLEAR SELECTION ]` forgets the area (and stops a running build).
4. RightShift hides / shows the menu. Click the STATUS line to copy the debug log.
5. **You may move the mouse while it builds.** It takes the cursor back for every click (so the cursor jumps), and
   keeps going. It builds fastest if you leave the mouse alone. It only pauses if the mouse is in the way of one
   click for 20 seconds in a row, or stays locked (first person / shift-lock); then you press `[ RESUME ]`.
   Turning the camera with the right mouse button is waited out. The game aims with the cursor, so if you move the
   mouse at the exact moment of a click, a block can land in a neighbouring cell. If that cell is inside the orange
   area it is tolerated (3 times per build, that cell is retried); outside the area it always stops the build.

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
* `python3 roblox/tests/run_core_tests.py`: 42 tests of the decision logic embedded in the script (build order,
  checking a placed block's cell, counters, duplicate protection, range learning, stop / resume).
* `python3 roblox/tests/run_glue_tests.py`: 34 tests that run the script's real `placeCell` / `runJob` / `autoBuild`
  / `stop` against a simulated world: small areas, existing blocks, hidden cells, island edges, out-of-range,
  interrupted builds, wrong placement, out of blocks, deselected block, grid offset, and a moving mouse (cursor knocked
  off the target, mouse locked for a camera turn, a block landing next door because the mouse moved).
* Mutation checks: deliberately breaking the logic makes these tests fail (a few redundant safety checks are
  intentionally duplicated and not individually detectable).
* Static checks: block balance, no undefined names, no remote / hook references.

**NOT tested: the real game.** The simulated world is my model of Roblox. Nothing here has run inside Roblox or
ABOVE[RUINS]. Raycasts, the executor's mouse events, the custom hotbar reading, and whether the game accepts a click
on a block face as a placement are untested. Expect to need one or two rounds of fixes after the first real run.
If something fails, click the STATUS line, which copies the log, and send it to me.

Known limits: glass-like (translucent) blocks are not recognised as blocks; the aim needs a visible face next to
each cell; running scripts through an executor is against Roblox's Terms of Use and can get an account banned.
