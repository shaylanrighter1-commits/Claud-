# ABOVE[RUINS] | Auto Builder — MacSploit script

One file: **`AutoBuilder_MacSploit.lua`**. Paste it into MacSploit while you're in the game and Execute.
No installation, nothing in any Roblox service, no Studio.

> **Status: not yet run in MacSploit or in ABOVE[RUINS].** I can't run either here, and I haven't seen the
> game's building code. Automatic placement depends on how the game's own click-to-place behaves, so treat the
> first run as a test (try a 2×2 area). If something fails, the menu's status line says why, and **clicking the
> status line copies the debug log** to your clipboard (it's also printed to the F9 console).
>
> Running scripts through an executor is against Roblox's Terms of Use and can get an account banned; automated
> clicking may also break the game's own rules.

## The whole flow

**EQUIP BLOCK → SELECT AREA (two clicks) → AUTO BUILD → DONE**

| Menu | What it does |
|---|---|
| **SELECT AREA** | click corner A, then the opposite corner B — the orange outline is exactly what will be filled |
| **BLOCK: GRASS BLOCK** | automatic — whatever is in your hand |
| **NEEDED: 36 \| OWNED: 8** | automatic — empty cells left in the area, and how many of that block you have. If the game's number can't be read, click OWNED and type it once |
| **AUTO BUILD** | places the blocks one at a time; the button shows real progress (`BUILDING 8/36`) |
| **STOP** | stops at once (no further clicks) |

RightShift hides/shows the menu. Keep the whole area on screen (not under Roblox's top bar or the bottom hotbar), stay
within the game's placement range, and don't touch the mouse while it builds.

While you click the two corners, SELECT AREA puts your block away (so the game's own click handling can't place stray
blocks at the corners); AUTO BUILD takes it out again by itself.

## How it places blocks

It does **not** call any RemoteEvent/RemoteFunction, hook anything, or change your inventory. It acts like a very fast,
careful player:

1. for the next empty cell it finds a face next to it (the ground or a neighbouring block) that your camera can see,
2. moves the mouse there and confirms the cursor really arrived,
3. clicks with your block in hand,
4. waits to **see a block actually appear in that cell**.

So the game's own building code decides whether each block is placed — range, land ownership, cooldown, and taking one
block from your inventory all happen exactly as when you click yourself. Blocks are real server-side blocks, visible to
everyone. Nothing is created locally; the outline is drawn with adornments (not parts), so the game's click handling can't hit
it and it can't be mistaken for a block.

- Order: bottom layer first, row by row. Cells already filled are skipped (not counted, not charged).
- The progress number counts only blocks it saw appear in the right cell.
- It follows the game's grid: detected from the cube-shaped blocks around you, refined from the block you click as Point A,
  and corrected from the first block it places.

## It stops (and says why) when

- you run out of blocks (`Out of blocks. Placed 8 of 36 …` — get more and press AUTO BUILD again; filled cells are skipped),
- 3 blocks in a row fail to appear (not in hand? out of range? area off screen?),
- a block lands in a different cell than intended,
- the cursor can't be moved/confirmed, or the mouse is locked (shift-lock / first person),
- some cells can't be aimed at (hidden, off screen, behind the menu or one of the game's buttons).

## Safety checks before it starts

- It refuses if the item in your hand looks like a **tool or weapon** (pickaxe, axe, sword …): clicking with those would try
  to break blocks.
- It needs to know your block count (read automatically, or typed into OWNED), so it can stop when you run out.

## Limitations — what can prevent automatic placement

- **Mouse control.** It needs `VirtualInputManager` or the executor's `mousemoveabs` / `mouse1click`. If neither works, the
  menu says it can't control the mouse and nothing is placed. (Tell me which mouse functions your MacSploit has.)
- **How the game places blocks.** It assumes: hold the block, click a face, a block appears next to it. If ABOVE[RUINS] uses
  hold-to-place, a build mode, placement relative to your character, or its own cooldown/anti-macro checks, the game may
  refuse the clicks — then the status line says the game isn't placing blocks.
- **The block must be a Tool in your hand** so it can be detected. If your hotbar isn't made of Roblox Tools, it can't tell what
  you're holding.
- It can't walk for you, and it can't place where the game doesn't allow you to place (other players' land, out of range).
- Areas are capped at 5,000 blocks (`CONFIG.MAX_CELLS`); settings are at the top of the script.
- It never bypasses server checks — anything the server refuses, it can't do.

## For your own Studio game

Real placement for a game you own belongs on the server (validate ownership, take one block per placement, place it). An
earlier Studio version of this project did exactly that: git history, commit `731e306`, folder `roblox/src`.
