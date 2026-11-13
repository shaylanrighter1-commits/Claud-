# ABOVE[RUINS] | Auto Builder

A complete Auto Builder system for Roblox, written from scratch in Luau. Pick two corners on your
land, see an orange construction preview, choose a block type, see exactly how many blocks it
costs, and watch the structure build itself block by block — spending real blocks from your
inventory.

> **Status: not yet run in Roblox Studio.** This was written and reviewed without access to Studio
> (and without your game's source — only the screenshot). The code has been read through carefully,
> but treat the first Play test as the real test and send me any red text from the Output window.
> The optional self-test in `tests/PlannerTests.lua` checks the geometry/counting logic in Studio.

It ships with its own **test world** (a plot of land per player, an inventory, four block types,
resource crates) so you can try everything in a blank Baseplate. Nothing here reads ABOVE[RUINS]'s
real inventory or building code — see [Using it in your real game](#using-it-in-your-real-game).

---

## 1. Install (pick one)

### A. One paste (easiest)
1. Open a Baseplate place in Roblox Studio.
2. **View → Command Bar** (turn it on).
3. Open `roblox/Install_AutoBuilder.lua`, copy **everything**, paste into the Command Bar, press **Enter**.
4. Output should print `[AutoBuilder] Installed 7 scripts.`

If pasting that much text is slow or fails, use option B or C.

### B. Rojo
```bash
cd roblox
rojo serve        # then Connect from the Rojo plugin in Studio
```
`default.project.json` maps `src/` to the right services.

### C. By hand
Create these and paste each file's contents (`roblox/src/...`) into a script of the stated type:

| Where in Studio | Name | Type | File |
|---|---|---|---|
| ReplicatedStorage → **AutoBuilder** (Folder) | `Config` | ModuleScript | `ReplicatedStorage/AutoBuilder/Config.lua` |
| ReplicatedStorage → AutoBuilder | `BuildPlanner` | ModuleScript | `ReplicatedStorage/AutoBuilder/BuildPlanner.lua` |
| ServerScriptService → **AutoBuilder** (Folder) | `AutoBuilderServer` | **Script** | `ServerScriptService/AutoBuilder/AutoBuilderServer.server.lua` |
| ServerScriptService → AutoBuilder | `StandaloneBackend` | ModuleScript | `ServerScriptService/AutoBuilder/StandaloneBackend.lua` |
| StarterPlayer → StarterPlayerScripts → **AutoBuilderClient** (Folder) | `Main` | **LocalScript** | `.../AutoBuilderClient/Main.client.lua` |
| StarterPlayerScripts → AutoBuilderClient | `UI` | ModuleScript | `.../AutoBuilderClient/UI.lua` |
| StarterPlayerScripts → AutoBuilderClient | `Preview` | ModuleScript | `.../AutoBuilderClient/Preview.lua` |

Names matter — the scripts find each other by name.

---

## 2. Try it (about 2 minutes)

Press **Play (F5)**. You spawn on a green plot with your name floating over it. Four colored
**resource crates** sit behind you. The menu is on the right (**B** toggles it; **×** closes it and
leaves an AUTO BUILDER button top-left; **–** minimizes; drag the title bar to move it).

1. Click **SELECT BUILD AREA**. Status says *SELECT POINT A*.
2. Click a block/ground near one corner of your plot → an orange **POINT A** marker + beam appears.
3. Move the mouse: an orange preview stretches from A to your cursor (red if it would leave your land).
4. Click the opposite corner → **POINT B**. The preview locks in and **Build Options** appear.
5. Choose **FLOOR**, thickness 1, **Grass Block**. For a 12 × 10 area the panel reads:
   ```
   BUILD REQUIREMENTS
   Grass Blocks Required: 120
   Grass Blocks Available: 75
   Grass Blocks Missing: 45
   Progress: 75 / 120
   NOT ENOUGH RESOURCES — COLLECT 45 MORE GRASS BLOCKS
   ```
   **START BUILDING** is greyed out. (You start with 75 grass, 100 dirt, 100 stone, 0 planks.)
6. Walk to the **Grass Block Crate**, hold **E** (tap on mobile) — each use gives 25. Watch *Available*
   count up live. At 120 the banner turns green and START unlocks.
7. Press **START BUILDING**. Blocks appear one by one in a snake pattern, bottom layer first:
   ```
   AUTO BUILDER ACTIVE
   Building: Grass Floor
   Blocks Placed: 45 / 120
   Progress: 37.5%
   Status: Constructing...
   ```
   Your inventory drops by exactly one per block. When it finishes the orange preview disappears.
8. Try **PAUSE / RESUME**, **CANCEL BUILD** (placed blocks stay; unplaced blocks were never taken),
   the other modes, **SLOW → TURBO** speeds, and selecting over blocks you already built (they're
   skipped and not charged — nothing is ever overwritten).

**Simulate running out mid-build** (Play → in the Command Bar switch to the *Server* context):
```lua
local B = require(game.ServerScriptService.AutoBuilder.StandaloneBackend)
B.takeBlocks(game.Players:GetPlayers()[1], "grass_block", 30)
```
The build pauses with *NOT ENOUGH RESOURCES — COLLECT n MORE…*; collect blocks and press **RESUME**.

**Mobile:** use Studio's *Device Emulator* (or a phone). Tap SELECT BUILD AREA, then **tap** (don't
drag) a block for each corner — dragging still rotates the camera.

**Optional self-test:** paste `tests/PlannerTests.lua` into the Command Bar. Expect
`PlannerTests: ALL PASSED`.

---

## 3. Build modes

| Mode | What it builds | Settings |
|---|---|---|
| **Floor** | Flat slab over the rectangle | Thickness (layers, builds upward from the A/B layer) |
| **Wall** | Vertical wall. *Straight*: along the longer side, starting at Point A's edge and growing toward B. *Surround*: all four sides | Height, Thickness, Layout |
| **Fill** | Solid block of the whole volume | Height |
| **Hollow Box** | Outer walls + floor + ceiling, empty inside (very small boxes just fill solid) | Height |

*Height:* if Point A and B are on different layers, the height comes from the two points (the
stepper locks and says so). If they're on the same layer, use the Height stepper.

The orange preview shows **exactly the blocks that will be built** — a hollow box draws its six
shell pieces, a wall draws only the wall. The preview, the block count and the placement all come from the
same `BuildPlanner` plan, so they can't disagree.

---

## 4. How it works

```
ReplicatedStorage/AutoBuilder
  Config            all tunables, theme, messages (shared)
  BuildPlanner      pure geometry: cells, counts, build order  (client preview + server truth)
ServerScriptService/AutoBuilder
  AutoBuilderServer remotes, validation, jobs, placement loop, inventory pushes
  StandaloneBackend test world: plots, inventory, blocks, crates   <-- the only game-specific file
StarterPlayerScripts/AutoBuilderClient
  Main              selection state machine, input (mouse + touch), talks to the server
  UI                the menu (built in code, no assets)
  Preview           orange boxes, A/B markers, hover ghost, size label (client-only parts)
```

**Server is the authority.** The client sends only two cells, a few option choices and a speed.
`AutoBuilderServer` ignores any counts/ownership the client claims and, for every request:

- validates types/ranges (finite integers, known mode/material, clamped sizes and speed),
- rebuilds the plan itself and checks the size limits,
- checks **every cell** is on land the player owns **and** inside the world,
- counts only cells that are still **empty** (existing blocks are skipped, never overwritten),
- refuses to start unless the player holds **every block needed**,
- one build per player at a time; per-remote rate limits.

**No free or duplicated blocks.** Per block the server does: *take 1 from inventory → place it → if
placing failed, give the 1 back*. Ownership and emptiness are re-checked at the moment of each
placement. If the player runs out, the build pauses (it never places on credit). Cancel just stops —
blocks are only ever taken one at a time as they are placed, so unused materials are untouched.
Leaving the game cancels the build.

---

## 5. Configuration (`ReplicatedStorage/AutoBuilder/Config`)

| Setting | Default | Meaning |
|---|---|---|
| `DEFAULT_SPEED` / `SPEED_PRESETS` | 12 / 5-12-30-60 blocks/sec | Construction speed. Server clamps to `MIN_SPEED`–`MAX_SPEED` |
| `MAX_BLOCKS_PER_JOB`, `MAX_DIMENSION`, `MAX_HEIGHT`, `MAX_THICKNESS` | 20000 / 128 / 64 / 16 | Server-enforced size limits |
| `SELECT_ADJACENT_CELL` | `true` | Click the ground → select the layer *above* it (like placing a block). `false` = the clicked block's own cell |
| `TOGGLE_KEY` | `B` | Menu shortcut (`nil` disables) |
| `WORLD_MAX_ABS_STUDS`, `WORLD_MAX_Y_STUDS` | 8000 / 4000 | Playable-world limits |
| `Theme` | dark + orange | Colors/fonts for the menu and preview |

Test-world settings (grid size, plot size, starter blocks, crate amount, block types) are at the top
of `StandaloneBackend.lua`.

---

## 6. Using it in your real game

I did not have ABOVE[RUINS]'s code, so I did not hook into its inventory, land or block-placement
systems — and I won't pretend to. The Auto Builder only ever calls the functions below, all in one
module. To integrate: write a module with the same functions backed by your game's systems, then change
the single `require(... "StandaloneBackend")` line in `AutoBuilderServer.server.lua`.

| Function | What it must do |
|---|---|
| `init()` | one-time setup |
| `onPlayerAdded(player)` / `onPlayerRemoving(player)` | set up / clean up per-player state (a real game usually does nothing here) |
| `canUse(player)` → `bool, reason?` | gate the feature (gamepass, safe zone…) |
| `getGrid()` → `{size, origin}` | studs per block and the world position of cell (0,0,0)'s min corner, so the preview snaps to *your* grid |
| `getMaterials()` → `{ {id, name, color}, … }` | the buildable blocks that exist in your game |
| `getBlockCount(player, id)` | how many the player holds |
| `takeBlocks(player, id, n)` → `bool` | remove `n` **atomically**; return `false` and change nothing if they don't have `n` |
| `giveBlocks(player, id, n)` | put `n` back (refund for a failed placement) |
| `getPlot(player)` → `{min, max}` or `nil` | the player's land as inclusive grid-cell bounds (for the client preview) |
| `isCellOwned(player, cell)` → `bool` | may this player build in this cell? (authoritative; handle non-rectangular land here) |
| `isCellOccupied(cell)` → `bool` | is a block/structure already there? |
| `placeBlock(player, id, cell)` → `bool` | place ONE block using your game's real placement function. It must **not** deduct inventory itself (the builder already did) and must return `false` if the cell is blocked |

`cell` is a `Vector3` of integers: cell `c` occupies the world cube `[origin + c*size, origin + (c+1)*size)`.
If you send me your inventory / land / placement scripts I can write this module for you.

---

## 7. Known limitations

- **Untested in Studio** (see the status note up top). Most likely trouble spots: UI layout on unusual
  screen sizes, and the click-capture while the player holds a placeable block (selection mode binds the
  click at high priority and unequips tools, but a game with its own click-to-place code may still need
  a one-line check against `ContextActionService`/`gameProcessed`).
- The orange outline in your screenshot looks like your land's boundary box. The Auto Builder draws a faint
  version of your land's outline only while picking corners, and the orange build preview itself; it does not
  touch whatever draws the boundary in your game.
- A build doesn't survive the player leaving or the server restarting.
- Land is assumed rectangular in the *client* preview (`getPlot`); the *server* check is per-cell, so odd-shaped land
  is safe as long as `isCellOwned` is correct.
- 20,000 anchored parts is a lot for clients; lower `MAX_BLOCKS_PER_JOB` for big public servers.

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| No menu | Output should show `[AutoBuilder] Server ready.` If not, the server Script isn't running or a script is misnamed. Press **B**. |
| "Server remotes not found" | `AutoBuilderServer` must be a **Script** (not Module/Local) inside ServerScriptService/AutoBuilder. |
| "That spot is outside your land." | Pick corners on *your* green plot (the faint orange outline while selecting). |
| START stays grey | Read the banner — usually missing blocks; collect from a crate. |
| Blocks don't appear | Look in `workspace.AutoBuilderBlocks`; check Output for `[AutoBuilder]` warnings. |
