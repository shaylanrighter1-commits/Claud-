# ABOVE[RUINS] | FARM — automation test tool

This tool is for testing anti-cheat in your private test server. It runs farming automation in a real Roblox client (through MacSploit on macOS) and records what your server actually did with each action:

* Did the server accept it?
* Did the server reject it, and why?
* Which anti-cheat detectors fired?

The tool runs only where you have installed the server harness, and only for accounts you have authorized.

```
client/ARFarm.lua                     run in MacSploit (single file, ~1.1k lines)
server/ARFarmTelemetry.lua            ModuleScript → ServerScriptService
server/ARFarmTestHarness.server.lua   Script       → ServerScriptService (edit config here)
server/INTEGRATION_EXAMPLES.lua       where to add one line to your existing handlers / anti-cheat
VERIFICATION.md                       checklist (fill from ARFarm.Report())
```

## How it fits together

```
your resource handlers ──Telemetry.action(player, module, ok, reason, target)──┐
your anti-cheat        ──Telemetry.detection(player, detector, details)────────┤
                                                                               ▼
                         ReplicatedStorage.ARFarmTest.Telemetry (tester only, private servers only)
                                                                               ▼
client: find tagged target → walk (Humanoid:MoveTo) → interact (prompt/click/tool/hook) → match server verdict
```

* **Finding resources:** the client finds resources by CollectionService tags that your server applies: `ARFarm_Flowers`, `ARFarm_Wood`, `ARFarm_Mining` and `ARFarm_NPC`. It does not guess names or paths.
* **Interacting:** the client tries these, in order:
  1. Your `Config.Integration[module]` hook.
  2. A configured Tool, using `Tool:Activate()`.
  3. A ProximityPrompt, using `InputHoldBegin`/`InputHoldEnd` and holding for the full `HoldDuration`.
  4. A ClickDetector, using `fireclickdetector`.

  It never invents RemoteEvent names. If none of these apply, the module switches itself off and shows the reason.
* **Rules it keeps:** it walks at your own WalkSpeed and never teleports. It never targets players. It adds no hooks and hides nothing. The GUI goes in PlayerGui, so your anti-cheat can see it.

## Setup (Studio, once)

1. Put `ARFarmTelemetry` (ModuleScript) and `ARFarmTestHarness` (Script) in **ServerScriptService**.
2. In `ARFarmTestHarness`:
   * Add your tester UserIds to `TesterUserIds`.
   * Add `Telemetry.tagChildren(...)` lines for your real resource folders.
   * For NPCs, tag **test NPCs only**.
3. In your existing handlers, add `Telemetry.action(...)` after validation runs. In your anti-cheat, add `Telemetry.detection(...)`. `INTEGRATION_EXAMPLES.lua` shows where each line goes.
   * Use the standard reasons `INVENTORY_FULL`, `DEPLETED`, `COOLDOWN`, `OUT_OF_RANGE` and `INVALID_TARGET`, so the client can react to them.
   * To mark a resource depleted, do any one of these: remove its tag, set the `Depleted` attribute, or disable its prompt.
4. Publish to your **test place**. The harness only switches on in Studio and in private or reserved servers. A public server never creates the remotes.

## Run on macOS with MacSploit

1. Join a **private server** of the test place with a tester account. Use an alt account: running any executor carries account risk under Roblox's rules, even in your own game.
2. Open MacSploit and attach it to the Roblox client. Make sure your MacSploit build matches the current Roblox version.
3. Run the client in one of two ways:
   * Paste all of `client/ARFarm.lua` into the MacSploit editor and press **Execute**.
   * Or save it to MacSploit's workspace folder and run `loadstring(readfile("ARFarm.lua"))()`.
4. The menu appears. Its status line should read `Harness OK (private/reserved server)`. If it shows a red reason instead, that is what is missing.
5. Toggle modules. **STOP ALL** cancels the worker at once, releases any held prompt and stops walking. Running the script again replaces the old copy, so no duplicate loops are left behind.

## Hidden diagnostics (MacSploit console / F9)

```lua
getgenv().ARFarm.SetScenario("jitter")      -- baseline jitter human burst random_select roundrobin detour interrupt invalid_probe mixed
getgenv().ARFarm.RunSuite({"baseline","jitter","burst","detour","interrupt","invalid_probe","mixed"}, 120)
getgenv().ARFarm.Report()                   -- prints the checklist (copies it too, if setclipboard exists)
getgenv().ARFarm.Recent(30)                 -- last 30 attempts with server verdicts
getgenv().ARFarm.Config.Modules.Wood.tool = "Axe"   -- harvest with a Tool instead of a prompt
getgenv().ARFarm.Destroy()
```

### Scenarios

Each scenario is one table in `Scenarios`, so you can add your own. A scenario can change:

* **Timing:** fixed, uniform jitter, gaussian or burst.
* **Target choice:** nearest, nearest-3 random, random, round-robin or farthest.
* **Navigation:** direct, pathfinding or detour.
* **Interruptions:** walks cut short, and prompt holds released early.
* **Mixed harvesting:** switching module on every action.
* **Invalid probes** (the server is expected to reject these):
  * `out_of_range` acts from about 2.5× the allowed range.
  * `rapid_repeat` sends a duplicate before the first reply comes back.
  * `depleted` acts on a resource that was just finished.

### How results are counted

* **`UNDETECTED`:** a scenario ran at least 10 attempts with no detection.
* **Validation gap:** an invalid probe that the server **accepted**.
* **`NO_RESPONSE`:** your handler never called `Telemetry.action` within 2 s.

## Known limitations (unverified until you run it)

* **`InputHoldBegin`/`InputHoldEnd`:** these are standard Roblox API, but I could not confirm that they trigger every prompt setup in your game. If they don't, set `Config.PromptMethod = "fire"` to use MacSploit's `fireproximityprompt` (the tool still waits the full `HoldDuration` first). Otherwise, write an `Integration` hook.
* **`Tool:Activate()`:** this only works if your weapon or tool scripts respond to `Activated`. If they fire a remote from mouse input, write an `Integration` hook that calls *your* remote.
* **Players near NPCs:** the NPC module refuses to swing while another player is within 10 studs. It does this because your weapon's server-side hit detection, not this tool, decides what gets hit.
* **Matching results to attempts:** results are matched by module and target, oldest first. A server result that arrives after 2 s counts as "unmatched" rather than being assigned to the wrong attempt.
