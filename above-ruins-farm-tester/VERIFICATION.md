# Verification checklist

## What has actually been verified

The code has been checked statically. It has not been run in Roblox or MacSploit yet.

| Check | Result |
|---|---|
| `client/ARFarm.lua` parses: Lua grammar, with Luau `+=` rewritten first | ✅ passed |
| Undeclared-global scan of the client: only Roblox/executor globals are used | ✅ passed |
| Server files parse after their Luau type annotations are stripped | ✅ passed |
| Run inside Roblox Studio | ❌ not done. This environment has no Roblox. |
| Run inside MacSploit on macOS | ❌ not done. **You need to run it.** |
| Server accept/reject observed | ❌ not done. It needs your game and the harness wired in. |
| Anti-cheat detections observed | ❌ not done. It needs `Telemetry.detection` in your anti-cheat. |

Every row below that says "pending" gets filled from `getgenv().ARFarm.Report()` after a real session.

## 1. What runs in MacSploit (client)

| Component | Needs executor function? | Status |
|---|---|---|
| Menu: drag, minimize, toggles, STOP ALL, status line | none (plain Roblox GUI) | pending |
| Replacing an old copy on re-execute | `getgenv` (falls back to `_G`) | pending |
| Walking: direct, pathfinding, detour; stuck → jump → give up | none (Humanoid:MoveTo, PathfindingService) | pending |
| ProximityPrompt hold | none (`InputHoldBegin`/`End`); optional `fireproximityprompt` | pending |
| ClickDetector | `fireclickdetector` | pending |
| Tool harvesting and combat | none (`Tool:Activate`) | pending |
| Death and respawn handling | none | pending |
| Report copied to clipboard | `setclipboard` (optional) | pending |

The report's first line shows which of these functions MacSploit actually provides.

## 2. What needs server integration

| Function | Server piece | Without it |
|---|---|---|
| Any farming at all | `ARFarmTest` folder plus handshake. The tester must be in `TesterUserIds`, in a private server or Studio. | Every toggle refuses. The status line names the reason. |
| Finding resources | CollectionService tags (`Telemetry.tagChildren`) | "No eligible X" |
| Accept/reject per action | `Telemetry.action(...)` in your handlers | `NO_RESPONSE`, with a hint in the report |
| Detections | `Telemetry.detection(...)` in your anti-cheat | "(none received)" |
| Inventory-full stop | Handler reports reason `INVENTORY_FULL` | The module keeps trying, and your server keeps rejecting. |
| Remote-based interactions | `Config.Integration[module]` hook, written by you | The module switches off with "integration missing". |

## 3. Modules actually tested (from `Report()`, MODULE table)

| Module | Tested | Attempts | Accepted | Rejected | No response | Client fail |
|---|---|---|---|---|---|---|
| Flowers | | | | | | |
| NPC Farm | | | | | | |
| Wood | | | | | | |
| Mining | | | | | | |

## 4. Scenarios (from `Report()`, SCENARIO table)

| Scenario | Attempts | Valid accepted/rejected | Invalid accepted/rejected | Detections | Verdict |
|---|---|---|---|---|---|
| baseline | | | | | |
| jitter | | | | | |
| human | | | | | |
| burst | | | | | |
| random_select | | | | | |
| roundrobin | | | | | |
| detour | | | | | |
| interrupt | | | | | |
| invalid_probe | | | | | |
| mixed | | | | | |

**Validation gaps** (invalid probes the server accepted): fill these from the report.

**Detectors triggered** (name → count): fill these from the report.

## 5. Manual reliability checks

- [ ] Toggle the same module on and off quickly 10 times. `ARFarm.Status().current` never shows two modules at once, and there is no duplicate movement.
- [ ] Turn a module OFF mid-walk. The character stops within about 0.1 s.
- [ ] Turn a module OFF mid-hold. The prompt is released, and the server receives no trigger.
- [ ] Press STOP ALL with every module on. Everything goes off, walking stops, and the suite is cancelled.
- [ ] Reset the character mid-action. The tool resumes after respawn, and there is no error spam.
- [ ] Run the script twice. Only one menu remains, and only one worker.
- [ ] Join a **public** server. The status line reads "Integration missing ... not found", and nothing farms.
- [ ] Use an account that is not in `TesterUserIds`. The status line reads "Server refused: UserId ... not in TesterUserIds".
- [ ] Stand another player next to a test NPC. Attacks are held.
- [ ] Fill your inventory. The module switches off with "inventory full".
