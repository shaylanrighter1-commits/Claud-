# ABOVE[RUINS] | Auto Builder — MacSploit script

One file: **`AutoBuilder_MacSploit.lua`**. Paste it into MacSploit while you're in ABOVE[RUINS] and
press Execute. Nothing to install, no Studio, no scripts in ServerScriptService / StarterPlayerScripts /
ReplicatedStorage. Everything runs on your client.

> **Status: not yet run in MacSploit.** I can't run Roblox or an executor here, so this was written and
> reviewed by reading only. If something doesn't work, the in-window **DEBUG LOG** (and the F9 console)
> will say why — send me that text.
>
> Running scripts through an executor is against Roblox's Terms of Use and can get an account banned.

## Run it

1. Join the game. 2. Paste the whole file into MacSploit. 3. Execute.

The window is built and mounted **first**, before anything else, so it appears immediately (top-right).
**RightShift** hides/shows it, **×** closes it (an AUTO BUILDER button appears bottom-left), **–** minimizes,
drag the title bar to move it. Executing the script again replaces the old copy.

## If you don't see the window

The script tries three places in order: `gethui()`, `CoreGui`, then `PlayerGui`, and logs which one worked
(`[AutoBuilder] window mounted in: ...`). It also re-mounts the window if the game deletes it.

- Open the console (**F9** in-game, or MacSploit's console) and look for `[AutoBuilder]` lines.
- Set `CONFIG.CONTAINER = "playergui"` (or `"coregui"` / `"gethui"`) at the top of the script and execute again.
- `[ERROR]` lines mean a specific part failed; every part is isolated, so the rest of the window still loads.
  Open **DEBUG LOG** at the bottom of the window — it pops open by itself on an error. **COPY** puts the log
  on your clipboard.

## Using it

1. **Calibrate the grid (do this first).** I can't know ABOVE[RUINS]'s block size, so press
   **CALIBRATE FROM A BLOCK** and click one *placed block* (not the ground). It reads that block's size and
   position and snaps everything to it. (Or type the size, default 4 studs.)
2. **Select the area.** **SELECT BUILD AREA** → click one corner (Point A) → click the opposite corner (Point B);
   the orange preview follows your cursor. Or walk to a corner and press **A = MY POSITION** / **B = MY POSITION**.
   **RESET SELECTION** clears it. Clicking the ground selects the layer *above* it (switchable under "Click selects").
3. **Choose a mode:** Floor, Wall (straight or surround), Fill, Hollow Box — with height/thickness. The bright
   orange outline + translucent fill show exactly the blocks that will exist.
4. **Material & inventory.** Pick a material (add your own with the name box). It tries to read your count from
   the game (a value, a Tool, or the "x686" text beside the item name in your hotbar) and tells you which source
   it used. If it can't, or reads it wrong, **type the number** in *Available* (that switches to MANUAL; **AUTO**
   switches back).
5. **Requirements** show Required / Available / Missing / Progress, and
   `NOT ENOUGH RESOURCES — COLLECT n MORE ...` when you're short. Blocks already standing in the area are detected
   and subtracted.
6. **START BUILDING** starts *guided tracking*: the next blocks to place glow, and the progress bar follows the
   blocks you place. **PAUSE / RESUME / CANCEL BUILD** work as named. When every cell is filled it says
   "Build complete" and removes the preview.

## What it does NOT do — and what real auto-building would need

It does **not** place blocks, fire any RemoteEvent/RemoteFunction, edit your inventory, or contact the server.
Block placement in a Roblox game happens on the server, which validates every placement (range, ownership,
inventory). A client script can't legitimately do that for you, and I won't guess at or call the game's private
remotes — that would be exploiting the game, and it's against what you asked for too.

Automatic placement becomes possible only through an interface the game itself provides:

- **The game's developer exposes one** — e.g. an official "blueprint / copy-paste / fill" tool, or a documented
  API for builders. Then this script's planner (`PL.plan` + `PL.buildOrder`, which produce the exact cell list in
  build order) could feed that interface, one request at a time, at a rate the game allows. I'd need its
  documentation to wire it in.
- **You are the developer of ABOVE[RUINS].** Then the right place for this is the game itself: a server script
  that checks land ownership, takes one block from the player's inventory per placement, and places it with the
  game's own placement code. An earlier Studio version of this project did exactly that (git history, commit
  `731e306`, folder `roblox/src`).

Until then, the guided tracker is the practical version: you place the blocks, it tells you where and counts them.

## Settings (top of the script)

`CONTAINER`, `TOGGLE_KEY`, `GRID_SIZE`, `GRID_ORIGIN`, `SELECT_ADJACENT`, `MATERIALS`, size limits,
`DETECT_EXISTING`, `MAX_TRACK_CELLS`, and the "what counts as a block" thresholds `OCC_MIN_FRACTION` /
`OCC_MAX_MULT` (ground plates and small decorations like flowers are ignored when detecting existing blocks).

## Known limitations

- Mouse only (it's written for Mac). If the game locks the mouse to the screen center (shift-lock / first
  person), the window can't be clicked — use the third-person free cursor.
- Selecting by click binds the left mouse button while you're picking, so the game shouldn't also react to that
  click; if your hotbar still places a block, put an empty slot in your hand while picking.
- Existing-block detection uses size thresholds; if it mis-counts for this game's blocks, adjust
  `OCC_MIN_FRACTION` / `OCC_MAX_MULT` or turn **DETECT BLOCKS** off (progress tracking needs it on).
- Reading your inventory is best-effort; always sanity-check the number it shows.
