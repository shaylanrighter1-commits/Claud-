# ABOVE[RUINS] | Auto Builder — MacSploit script

One file: **`AutoBuilder_MacSploit.lua`**. Paste it into MacSploit while you're in the game and Execute.
No installation, nothing in any Roblox service, no Studio. The status line shows the version (`v3 custom-hotbar`)
so you can tell you're running the latest file.

> **Status: not yet run in MacSploit or in ABOVE[RUINS].** I can't run either here and I haven't seen the game's
> hotbar GUI or building code. The hotbar detection is heuristic (see below). If something fails the status line says
> *which part* failed, and **clicking the status line copies the debug log** (it includes a dump of every hotbar slot it
> saw), which is what I need to fix it.
>
> Running scripts through an executor is against Roblox's Terms of Use and can get an account banned; automated clicking
> may also break the game's own rules.

## The flow

**SELECT AREA → select your block in the hotbar → AUTO BUILD**

| Menu | What it does |
|---|---|
| **SELECT AREA** | click corner A, then the opposite corner B — the orange outline is exactly what will be filled |
| **BLOCK: GRASS BLOCK  slot 4** | the item you have selected. Grey word = *detected* only; it turns green **verified** only after a real block has been seen appearing in the world |
| **NEEDED: 10 \| OWNED: 25** | empty cells left in the area; how many of that block you have (read from the hotbar's "x25") |
| **AUTO BUILD** | always clickable once an area is selected. Places blocks one at a time; button shows real progress (`BUILDING 3/10`) |
| **STOP** | stops at once |

Select the block **after** choosing the area (so the game's own click handling can't place blocks at the corners you click).
RightShift hides/shows the menu. Keep the whole area on screen, stay in placement range, don't touch the mouse while it builds.

## How it finds your block (custom hotbar)

ABOVE[RUINS] draws its own hotbar, so there is no Roblox `Tool` to look at. The script reads the hotbar GUI instead:

1. finds the slots — containers that each show a number 1–9 (it needs 3+ in a row),
2. reads each slot's item name and count (`x25`, `25x`, `×25`, or a bare `25`),
3. picks the **selected** slot: the one the game highlights (yellow outline / background / frame); if no highlight is
   recognisable it takes the only slot that is styled differently from the rest; as a last resort it looks for a player
   attribute/value such as `EquippedItem` / `SelectedSlot`,
4. reads your block count live from that slot (and re-finds it if the game redraws the hotbar).

A standard Tool in your hand is used too, if there is one. If the hotbar can't be read at all, AUTO BUILD still runs: type how
many you have into **OWNED** and it proceeds in cautious mode (first click verified, stops immediately if a block gets
removed instead of placed).

## Placement: what "equipped" vs "verified" means

Detecting an item only means *I read the hotbar*. It is **not** proof that placing works. After each click the script
waits to **see a new block appear in the right cell**; only then does it count the block and mark the item *verified*.
Nothing is counted from estimates.

## If it doesn't work: the status line names the part that failed

| Tag | Meaning |
|---|---|
| `[ITEM]` | I couldn't identify the selected hotbar item, read its count, or it's not selected any more |
| `[INPUT]` | the mouse cursor can't be controlled, or my click never reached Roblox / was swallowed by a GUI |
| `[AIM]` | I can't find a visible place to click (area hidden, off screen, behind the menu or the game's buttons) |
| `[PLACEMENT]` | my clicks reached the game on target but it didn't place a block (range, land ownership, cooldown, needs a different action) — or a block disappeared (the item breaks blocks), or one landed in the wrong cell |
| `[DETECTION]` | a block was used up but I couldn't see it in the world (block size / grid mismatch) |

How it tells them apart: before building it moves the cursor and confirms it followed (`[INPUT]`); on each click it checks whether
Roblox's input system saw the click (`[INPUT]` if not) and whether a GUI consumed it; if the click arrived cleanly and no block
appeared, that is the game/server refusing (`[PLACEMENT]`); if your block count dropped but no block was visible it's `[DETECTION]`.

## What actually places the blocks — and what could prevent it

It does **not** call any RemoteEvent/RemoteFunction, hook anything, or change your inventory. It aims at a face next to each
empty cell, moves the mouse there, clicks, and lets the **game's own building code** decide — range, land ownership, cooldown
and taking one block from your inventory all happen exactly as when you click yourself. Blocks are real server-side blocks.

What can stop it (the script can't work around these, and says so):

- **No mouse control.** It needs `VirtualInputManager` or the executor's `mousemoveabs`/`mouse1click`.
- **The game doesn't use "hold block, click a face".** Hold-to-place, a build mode, placement relative to your character, or
  anti-macro checks would make it refuse the clicks (`[PLACEMENT]`). Doing that for real would need the game's own documented
  building interface, which I don't have and won't guess at.
- **Hotbar detection is heuristic.** If your hotbar's highlight isn't recognisable, the log's slot dump shows what it saw —
  send it to me.
- Server-side limits (range, land ownership) apply; it can't place where you can't.
- It can't walk for you. Areas are capped at 5,000 blocks (`CONFIG.MAX_CELLS`).

## Safety

It refuses a held item that looks like a tool (pickaxe, axe, sword …), and stops immediately if a block *disappears* after a
click. STOP sends no further clicks.

## For your own Studio game

Real placement for a game you own belongs on the server (validate ownership, take one block per placement, place it). An earlier
Studio version of this project did exactly that: git history, commit `731e306`, folder `roblox/src`.
