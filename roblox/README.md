# ABOVE[RUINS] | Auto Builder — MacSploit script

One file: **`AutoBuilder_MacSploit.lua`**. Paste it into MacSploit while you're in the game and Execute.
No installation, nothing in any Roblox service, no Studio.

> **Status: not yet run in MacSploit or in ABOVE[RUINS].** I can't run either here, and I haven't seen the
> game's building code. The automatic placement relies on how the game's own click-to-place behaves, so
> treat the first run as a test (try a 2×2 area). If something fails, the menu's status line says why and
> **clicking the status line copies the debug log** to your clipboard (also printed to the F9 console).
>
> Running scripts through an executor is against Roblox's Terms of Use and can get an account banned;
> automated clicking may also break the game's own rules.

## Use it

1. Stand near the spot, camera angled so **the whole area is on screen**.
2. Execute the script — the menu appears top-right (**RightShift** hides/shows it, **–** minimizes, drag the title).
3. **SELECT AREA** → click corner **A** → click the opposite corner **B**. The orange outline is exactly what will be
   filled. (A and B at different heights fill a 3D box.)
4. Hold the block in your hand (press its hotbar number), then press **SELECT BLOCK**.
   *(If nothing is in your hand, each press steps through the tools in your backpack.)*
5. **AUTO BUILD**. The button shows progress (`BUILDING 8/36`). **PAUSE / RESUME** and **CANCEL** work any time.
   Don't touch the mouse while it builds.

The menu shows **BLOCKS NEEDED** (empty cells left in the area) and **BLOCKS OWNED**. Owned is read from the game
when possible (a Tool's count, or the "x686" text beside the item in your hotbar). If it can't read it, or reads it
wrong, **type the number** into the box (clear the box to go back to automatic).

## How it places blocks (and why it's "authorized")

It does **not** call any RemoteEvent/RemoteFunction, hook anything, or change your inventory. Instead it acts like a
very fast, careful player:

1. for the next empty cell it finds a face next to that cell (the ground or a neighbouring block) that your camera can see,
2. moves the mouse there (and confirms the cursor really arrived),
3. clicks with your block in hand,
4. waits for a block to actually appear in that cell.

So the **game's own building code decides** whether each block is placed — range, land ownership, cooldown, and taking
one block from your inventory all happen exactly as when you click yourself. Nothing is created locally; the orange
outline is drawn with adornments (not parts), so it can't be hit by the game's click handling or mistaken for a block.

What that gives you: blocks placed one at a time in an organized order (bottom layer first, row by row), cells that are
already filled are skipped, it stops when you run out and **continues by itself when you get more**, and it never
places on credit — if a click doesn't produce a block, nothing is counted.

## Safety stops (it pauses and tells you instead of carrying on)

- The cursor can't be moved/confirmed, or the mouse is locked (shift-lock / first person).
- A block lands in a different cell than intended.
- 3 blocks in a row fail to appear (not in hand? out of range? area off screen? out of blocks?).
- The block isn't in your hand (it tries to re-equip it first).
- Targets are hidden, off screen, behind the menu, or behind one of the game's own buttons — those are retried, then reported.

## The game's grid

It detects the block size and where the grid sits from the cube-shaped blocks around you, refines it from the first block
you click, and corrects itself from the first block it places. If your area looks shifted, click a *placed block* as
Point A.

## Limits / things that can go wrong

- Needs a way to move the mouse: it tries `VirtualInputManager`, then the executor's `mousemoveabs`/`mouse1click`. If
  neither works the menu says so (and I'd need to know which functions your MacSploit exposes).
- Assumes the game places a block when you click with it in hand and aim at a face. If ABOVE[RUINS] uses a different
  scheme (hold-to-place, a build mode, placement relative to your character), it will report "the game isn't placing
  blocks" and I'd need to see how it behaves.
- It can't walk for you: stay within the game's placement range of the area.
- Areas are capped at 5,000 blocks (`CONFIG.MAX_CELLS`). Settings are at the top of the script.
- Nothing about this bypasses server validation — which also means anything the server refuses, it can't do.
