# ABOVE[RUINS] | Auto Builder — MacSploit script

One file: **`AutoBuilder_MacSploit.lua`**. Paste it into MacSploit while you're in the game and Execute.
The status line shows the version (`v4 exact-cells + range`) so you can tell you're running the latest file.

> **Status: not yet run in MacSploit or in ABOVE[RUINS] by me.** I can't run either here. The hotbar and placement
> logic is built from how your game looks in screenshots; if something fails, the status line names the failing part
> and **clicking it copies the debug log**.
>
> Running scripts through an executor is against Roblox's Terms of Use and can get an account banned; automated
> clicking and walking may also break the game's own rules.

## The flow (menu unchanged)

**SELECT AREA → select your block in the hotbar → AUTO BUILD → STOP**

Rows are filled **left to right, one row after another, bottom layer first**. It builds slowly on purpose
(accuracy over speed). While building it takes over the camera (looking straight down at each cell) and may walk your
character to a safe spot; both are given back when it finishes or you press STOP.

## What was going wrong, and which side it came from

**Client-side (my script's aiming/verification) — fixed in v4:**

| Problem | Effect | Fix |
|---|---|---|
| The game's translucent green **placement preview** was counted as a real block | empty cells looked filled (skipped → gaps) and a preview could be counted as a placed block | only **opaque** parts count as blocks, everywhere |
| The grid origin was **shifted after any nearby block-sized part** | target cells drifted mid-build → "strange positions" | the grid is aligned **once** from the real blocks around the area (and by the first block), then **never moved** |
| Cells in a 1-block **trench** aren't visible from an ordinary camera angle | whole strips were never aimed at | camera looks **straight down** at each cell |
| Snake row order, loose "a block appeared nearby" check | hard to reason about, wrong blocks accepted | fixed row order; a block must be **new, opaque, and exactly in the target cell** |
| No protection against repeats | a cell could be clicked again | per-job registry; a filled cell is never clicked; hard cap `placed ≤ blocks counted at start`; counters reset every job |

**The game's own rules (the script cannot change these, only respect them):**

- **Placement distance.** The game only places within some range of your character. I don't know the number, so the
  script starts from a guess (20 studs, `CONFIG.PLACE_RANGE`), **never clicks beyond it**, and shortens it if the game
  refuses a placement from far away.
- Land ownership, placement cooldown, and which surfaces you may build on — the server decides; refusals show up as
  `[PLACEMENT]`.

## Range: what it does instead of standing still

Before every cell it checks your distance. If the cell is too far it **walks to a safe spot** within range of that cell
and the next few (level solid ground only — pits, edges and walls are rejected; it uses the path finder, else a straight
line only if the whole line is solid and level), then continues. It never stands inside the area being built. If there is
no safe spot, the status says **`[RANGE] OUT OF RANGE: N blocks can't be reached`** and it stops — it does not try anyway.
(Turn walking off with `CONFIG.AUTO_WALK = false`; then it reports OUT OF RANGE instead of moving.)

## How placement is verified (every block)

1. aim: camera above the cell → cursor on a face next to it → **if the game's own preview is visible, it must point at
   this cell, otherwise no click**,
2. click, then watch **every new part that appears anywhere** for ~1.5 s,
3. exactly **one** new opaque block-sized part must be in the target cell (first block of a job may adopt a small grid
   offset; every later block must be within 0.2 of a cell of its exact position),
4. a block anywhere else — including **outside the orange outline** — or two blocks from one click → **STOP** (`[PLACEMENT]`),
5. only then is it counted. If your count dropped but no block was seen → `[DETECTION]` stop.

## Failure tags

`[ITEM]` couldn't identify/read the held item · `[INPUT]` mouse/click problem · `[AIM]` no visible place to click ·
`[RANGE]` out of the placement range with no safe spot · `[PLACEMENT]` the game refused, or a block landed in the wrong
place · `[DETECTION]` a block was used but not seen.

## Honest limits

- It cannot know the game's exact placement range or its placement preview's implementation; both are inferred/learned.
- Walking uses the normal character controls and the game's own movement limits.
- If the game has anti-macro checks, hold-to-place or a build mode, it will refuse the clicks (`[PLACEMENT]`).
- Still never calls remotes or touches your inventory. Areas are capped at 5,000 blocks (`CONFIG.MAX_CELLS`).

## For your own Studio game

The Studio-side equivalent — server-checked range, ownership and inventory, plus moving the character to valid building
positions — is **not** in this file. An earlier Studio version is in git history (commit `731e306`, `roblox/src`) and does
not have movement yet; say the word and I'll add range checks + automatic movement there.
