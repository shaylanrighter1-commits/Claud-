--!nonstrict
--[[
	ABOVE[RUINS] | FARM  — client automation test tool  (MacSploit / macOS)

	Runs ONLY when the ARFarmTest server harness exists (Studio / private servers) and
	authorizes this player. Without it, every toggle refuses and says why.

	Plays by the rules:
	  * Walks with Humanoid:MoveTo at the game's own WalkSpeed (no teleport, no speed change).
	  * Interacts only through ProximityPrompt hold (honors HoldDuration), ClickDetector,
	    equipped Tool:Activate(), or an Integration hook you write for your test build.
	  * Never targets player characters. No hooks, no concealment, no anti-cheat interference.
	  * GUI lives in PlayerGui on purpose: your anti-cheat can see it.

	Hidden console API (run in MacSploit after this script):
	  getgenv().ARFarm.Report()                     -- prints the verification checklist
	  getgenv().ARFarm.SetScenario("jitter")        -- see Scenarios below
	  getgenv().ARFarm.RunSuite({"baseline","jitter","burst"}, 120)
	  getgenv().ARFarm.StopAll()  /  .Destroy()
]]

local VERSION = "1.0.0"

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local ENV = (typeof(getgenv) == "function" and getgenv()) or _G

-- Re-executing the script replaces the old instance (prevents duplicate loops/GUIs).
if type(ENV.ARFarm) == "table" and type(ENV.ARFarm.Destroy) == "function" then
	pcall(ENV.ARFarm.Destroy)
end

local MODULE_ORDER = { "Flowers", "NPC", "Wood", "Mining" }

---------------------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------------------
local Config = {
	HarnessFolder = "ARFarmTest",
	HandshakeTimeout = 10,
	SearchRadius = 300,      -- studs; targets farther away are ignored
	AckWait = 2.0,           -- seconds to wait for the server's accept/reject per attempt
	PendingExpire = 6.0,     -- after this an attempt with no server result = NO_RESPONSE
	BlacklistTime = 20,      -- seconds to skip a target that failed / was depleted
	MoveTimeout = 25,
	StuckTime = 2.5,
	IdleWait = 1.5,
	MinAttemptsForVerdict = 10,
	PromptMethod = "input",  -- "input": InputHoldBegin/End (honors HoldDuration)
	                         -- "fire":  executor fireproximityprompt (opt-in; waits HoldDuration first)
	InventoryFullReasons = { INVENTORY_FULL = true },
	DepletedReasons = { DEPLETED = true, INVALID_TARGET = true },
	Modules = {
		-- range: how close to walk before interacting (clamped to prompt MaxActivationDistance)
		-- maxHits: interactions per target before moving on (trees/ores often need several)
		-- tool: name of a Tool in your Backpack to equip + Activate (nil = use prompt/click)
		Flowers = { range = 6, maxHits = 1, tool = nil },
		Wood = { range = 7, maxHits = 10, tool = nil },
		Mining = { range = 7, maxHits = 10, tool = nil },
		NPC = { range = 6, tool = nil, perTargetTimeout = 45, playerSafetyRadius = 10 },
	},
	-- Optional hooks for YOUR private test build (you know your own remotes; this tool
	-- does not guess them). Signature: function(target, info) -> (sent:boolean, detail:string)
	-- info = { module = "...", invalid = boolean, probe = string? }
	Integration = { Flowers = nil, NPC = nil, Wood = nil, Mining = nil },
}

---------------------------------------------------------------------------------
-- SCENARIOS  (anti-cheat stress patterns; switch with ARFarm.SetScenario)
--   interval  : {kind="fixed",value} | {kind="uniform",min,max} | {kind="gaussian",mean,sd,min,max}
--               | {kind="burst",fast,slow,length}
--   selection : "nearest" | "nearest3" | "random" | "roundrobin" | "farthest"
--   nav       : "direct" | "path" | "detour"
--   interruptChance : chance to abort a walk or release a prompt hold early
--   invalidChance   : chance an action is replaced by an invalid probe (expected: server rejects)
--   probes    : which invalid probes to use: "out_of_range" | "rapid_repeat" | "depleted"
--   rotate    : true = switch module every action (mixed harvesting)
---------------------------------------------------------------------------------
local Scenarios = {
	baseline = { interval = { kind = "fixed", value = 1.0 }, selection = "nearest", nav = "direct" },
	jitter = { interval = { kind = "uniform", min = 0.6, max = 2.4 }, selection = "nearest3", nav = "direct" },
	human = { interval = { kind = "gaussian", mean = 1.6, sd = 0.6, min = 0.4, max = 4 }, selection = "nearest3", nav = "path", interruptChance = 0.05 },
	burst = { interval = { kind = "burst", fast = 0.25, slow = 5, length = 6 }, selection = "nearest", nav = "direct" },
	random_select = { interval = { kind = "uniform", min = 0.8, max = 1.6 }, selection = "random", nav = "path" },
	roundrobin = { interval = { kind = "fixed", value = 1.2 }, selection = "roundrobin", nav = "direct" },
	detour = { interval = { kind = "uniform", min = 0.8, max = 1.8 }, selection = "nearest", nav = "detour" },
	interrupt = { interval = { kind = "uniform", min = 0.8, max = 1.8 }, selection = "nearest", nav = "direct", interruptChance = 0.3 },
	invalid_probe = { interval = { kind = "fixed", value = 1.0 }, selection = "nearest", nav = "direct", invalidChance = 0.35, probes = { "out_of_range", "rapid_repeat", "depleted" } },
	mixed = { interval = { kind = "uniform", min = 0.7, max = 2.0 }, selection = "nearest3", nav = "path", rotate = true, interruptChance = 0.1 },
}

---------------------------------------------------------------------------------
-- SHARED STATE / LOG
---------------------------------------------------------------------------------
local State = { scenario = "baseline", destroyed = false }
local connections = {}
local function track(conn) table.insert(connections, conn) return conn end

local Log = { onStatus = nil, last = "" }
function Log.status(msg, isError)
	if msg == Log.last then return end
	Log.last = msg
	if isError then warn("[ARFarm] " .. msg) else print("[ARFarm] " .. msg) end
	if Log.onStatus then pcall(Log.onStatus, msg, isError) end
end

local function executorName()
	if typeof(identifyexecutor) == "function" then
		local ok, a, b = pcall(identifyexecutor)
		if ok and a then return tostring(a) .. (b and (" " .. tostring(b)) or "") end
	end
	return "unknown"
end

local Caps = {
	executor = executorName(),
	getgenv = typeof(getgenv) == "function",
	fireproximityprompt = typeof(fireproximityprompt) == "function",
	fireclickdetector = typeof(fireclickdetector) == "function",
	setclipboard = typeof(setclipboard) == "function",
}

---------------------------------------------------------------------------------
-- CHARACTER
---------------------------------------------------------------------------------
local Char = {}
function Char.get()
	local c = LP.Character
	if not c then return nil end
	local h = c:FindFirstChildOfClass("Humanoid")
	local r = c:FindFirstChild("HumanoidRootPart")
	if h and r and h.Health > 0 then return c, h, r end
	return nil
end
function Char.waitAlive()
	while true do
		local c, h, r = Char.get()
		if c then return c, h, r end
		task.wait(0.25)
	end
end

---------------------------------------------------------------------------------
-- TARGETS (identification + selection; no movement, no interaction)
---------------------------------------------------------------------------------
local Targets = { blacklist = setmetatable({}, { __mode = "k" }), rr = {} }

function Targets.position(inst)
	if inst:IsA("Model") then return inst:GetPivot().Position end
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Attachment") then return inst.WorldPosition end
	local p = inst:FindFirstChildWhichIsA("BasePart", true)
	return p and p.Position or nil
end

function Targets.ban(inst, seconds)
	Targets.blacklist[inst] = os.clock() + (seconds or Config.BlacklistTime)
end

local function banned(inst)
	local t = Targets.blacklist[inst]
	return t ~= nil and t > os.clock()
end

local function isPlayerCharacter(model)
	if Players:GetPlayerFromCharacter(model) then return true end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character and (p.Character == model or model:IsDescendantOf(p.Character)) then return true end
	end
	return false
end

function Targets.resourceOk(inst, tag)
	if not inst.Parent or not inst:IsDescendantOf(workspace) then return false end
	if tag and not CollectionService:HasTag(inst, tag) then return false end
	if inst:GetAttribute("Depleted") == true then return false end
	if banned(inst) then return false end
	local prompt = inst:IsA("ProximityPrompt") and inst or inst:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt and not prompt.Enabled then return false end
	return Targets.position(inst) ~= nil
end

function Targets.npcOk(model, tag)
	if not model:IsA("Model") or not model:IsDescendantOf(workspace) then return false end
	if tag and not CollectionService:HasTag(model, tag) then return false end
	if isPlayerCharacter(model) then return false end -- hard rule: never players
	if banned(model) then return false end
	local h = model:FindFirstChildOfClass("Humanoid")
	return h ~= nil and h.Health > 0
end

function Targets.collect(tag, okFn, rootPos)
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if okFn(inst, tag) then
			local pos = Targets.position(inst)
			if pos then
				local d = (pos - rootPos).Magnitude
				if d <= Config.SearchRadius then
					out[#out + 1] = { inst = inst, pos = pos, dist = d }
				end
			end
		end
	end
	return out
end

function Targets.pick(module, list, mode)
	if #list == 0 then return nil end
	if mode == "random" then return list[math.random(#list)] end
	if mode == "roundrobin" then
		table.sort(list, function(a, b) return a.inst:GetFullName() < b.inst:GetFullName() end)
		local i = (Targets.rr[module] or 0) % #list + 1
		Targets.rr[module] = i
		return list[i]
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	if mode == "farthest" then return list[#list] end
	if mode == "nearest3" then return list[math.random(math.min(3, #list))] end
	return list[1]
end

---------------------------------------------------------------------------------
-- MOVEMENT (walking only)
---------------------------------------------------------------------------------
local Movement = {}

function Movement.halt()
	local _, h, r = Char.get()
	if h and r then h:MoveTo(r.Position) end
end

local function flatDist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- returns "ARRIVED" | "TIMEOUT" | "STUCK" | "DIED" | "INTERRUPTED"
local function walkDirect(dest, stopDist, deadline, interruptAt)
	local lastIssue, lastPos, lastProgress, jumped = 0, nil, os.clock(), false
	while true do
		local c, h, r = Char.get()
		if not c then return "DIED" end
		local pos, now = r.Position, os.clock()
		if flatDist(dest, pos) <= stopDist then return "ARRIVED" end
		if now >= deadline then return "TIMEOUT" end
		if interruptAt and now >= interruptAt then return "INTERRUPTED" end
		if now - lastIssue > 3 then -- MoveTo self-expires after ~8s; re-issue
			h:MoveTo(dest)
			lastIssue = now
		end
		if not lastPos or (pos - lastPos).Magnitude > 0.75 then
			lastPos, lastProgress = pos, now
		elseif now - lastProgress > Config.StuckTime then
			if jumped then return "STUCK" end
			h.Jump = true
			jumped, lastProgress = true, now
		end
		task.wait(0.1)
	end
end

local function walkPath(dest, stopDist, deadline, interruptAt)
	local _, h, r = Char.get()
	if not r then return "DIED" end
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(function() path:ComputeAsync(r.Position, dest) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return walkDirect(dest, stopDist, deadline, interruptAt) -- no path: fall back
	end
	for _, wp in ipairs(path:GetWaypoints()) do
		local _, h2, r2 = Char.get()
		if not r2 then return "DIED" end
		if flatDist(dest, r2.Position) <= stopDist then return "ARRIVED" end
		if wp.Action == Enum.PathWaypointAction.Jump then h2.Jump = true end
		local res = walkDirect(wp.Position, 2, math.min(deadline, os.clock() + 6), interruptAt)
		if res == "DIED" or res == "INTERRUPTED" or res == "TIMEOUT" then return res end
		if res == "STUCK" then break end
	end
	return walkDirect(dest, stopDist, deadline, interruptAt)
end

-- sc = active scenario; returns same codes as walkDirect
function Movement.goTo(dest, stopDist, sc, timeout)
	local deadline = os.clock() + (timeout or Config.MoveTimeout)
	local interruptAt = nil
	if (sc.interruptChance or 0) > 0 and math.random() < sc.interruptChance then
		interruptAt = os.clock() + 0.5 + math.random() * 2.5
	end
	local res
	if sc.nav == "detour" and math.random() < 0.5 then
		local _, _, r = Char.get()
		if not r then return "DIED" end
		local dir = (dest - r.Position) * Vector3.new(1, 0, 1)
		if dir.Magnitude > 1 then
			local side = Vector3.new(-dir.Unit.Z, 0, dir.Unit.X) * (math.random() < 0.5 and -1 or 1)
			local mid = r.Position + dir * 0.5 + side * (8 + math.random() * 12)
			res = walkDirect(mid, 3, deadline, interruptAt)
			if res == "DIED" or res == "INTERRUPTED" then return Movement.finish(res) end
		end
	end
	if sc.nav == "path" then
		res = walkPath(dest, stopDist, deadline, interruptAt)
	else
		res = walkDirect(dest, stopDist, deadline, interruptAt)
	end
	return Movement.finish(res)
end

function Movement.finish(res)
	Movement.halt()
	if res == "INTERRUPTED" then task.wait(0.5 + math.random() * 1.5) end
	return res
end

function Movement.face(pos)
	local _, _, r = Char.get()
	if not r then return end
	local flat = Vector3.new(pos.X, r.Position.Y, pos.Z)
	if (flat - r.Position).Magnitude > 0.1 then
		r.CFrame = CFrame.lookAt(r.Position, flat) -- rotation only, position unchanged
	end
end

---------------------------------------------------------------------------------
-- INTERACTION (no movement here)
---------------------------------------------------------------------------------
local Interact = { held = nil }

function Interact.release()
	local p = Interact.held
	Interact.held = nil
	if p then pcall(function() p:InputHoldEnd() end) end
end

function Interact.prompt(target)
	local p = target:IsA("ProximityPrompt") and target or target:FindFirstChildWhichIsA("ProximityPrompt", true)
	return (p and p.Enabled) and p or nil
end

function Interact.click(target)
	return target:IsA("ClickDetector") and target or target:FindFirstChildWhichIsA("ClickDetector", true)
end

function Interact.tool(name)
	local c = LP.Character
	local bp = LP:FindFirstChildOfClass("Backpack")
	for _, holder in ipairs({ c, bp }) do
		if holder then
			if name then
				local t = holder:FindFirstChild(name)
				if t and t:IsA("Tool") then return t end
			else
				local t = holder:FindFirstChildOfClass("Tool")
				if t then return t end
			end
		end
	end
	return nil
end

-- Decide HOW a target can be interacted with. Returns method or nil, reason.
function Interact.resolve(module, target)
	if Config.Integration[module] then return "integration" end
	local mc = Config.Modules[module]
	if module == "NPC" then
		if Interact.tool(mc.tool) then return "tool" end
		return nil, mc.tool and ("weapon Tool '" .. mc.tool .. "' not in Backpack") or "no weapon Tool in Backpack and no Integration.NPC hook"
	end
	if mc.tool then
		if Interact.tool(mc.tool) then return "tool" end
		return nil, "Tool '" .. mc.tool .. "' not in Backpack"
	end
	if Interact.prompt(target) then return "prompt" end
	if Interact.click(target) then
		if Caps.fireclickdetector then return "click" end
		return nil, "target uses ClickDetector but executor lacks fireclickdetector"
	end
	return nil, "target has no ProximityPrompt/ClickDetector; set Config.Modules." .. module .. ".tool or Config.Integration." .. module
end

-- Effective interaction range for a target (never larger than the prompt allows).
function Interact.range(module, target, method)
	local r = Config.Modules[module].range
	if method == "prompt" then
		local p = Interact.prompt(target)
		if p then r = math.max(2, math.min(r, p.MaxActivationDistance - 1)) end
	elseif method == "click" then
		local cd = Interact.click(target)
		if cd then r = math.max(2, math.min(r, cd.MaxActivationDistance - 1)) end
	end
	return r
end

-- Performs ONE interaction. opts: { holdFraction?, invalid?, probe? }. Returns sent, detail.
function Interact.perform(module, target, method, opts)
	opts = opts or {}
	if method == "integration" then
		local ok, sent, detail = pcall(Config.Integration[module], target, { module = module, invalid = opts.invalid == true, probe = opts.probe })
		if not ok then return false, "integration error: " .. tostring(sent) end
		return sent == true, tostring(detail or "integration")
	elseif method == "prompt" then
		local p = Interact.prompt(target)
		if not p then return false, "prompt missing/disabled" end
		if Config.PromptMethod == "fire" then
			if not Caps.fireproximityprompt then return false, "PromptMethod=fire but executor lacks fireproximityprompt" end
			task.wait(p.HoldDuration)
			local ok, err = pcall(fireproximityprompt, p)
			return ok, ok and "fireproximityprompt" or ("fireproximityprompt error: " .. tostring(err))
		end
		Interact.held = p
		local ok, err = pcall(function() p:InputHoldBegin() end)
		if not ok then Interact.held = nil return false, "InputHoldBegin error: " .. tostring(err) end
		local frac = opts.holdFraction
		task.wait(p.HoldDuration * (frac or 1) + (frac and 0 or 0.1))
		Interact.release()
		return true, frac and "prompt-hold-released-early" or "prompt-hold"
	elseif method == "click" then
		local cd = Interact.click(target)
		if not cd then return false, "ClickDetector missing" end
		local ok, err = pcall(fireclickdetector, cd)
		return ok, ok and "fireclickdetector" or ("fireclickdetector error: " .. tostring(err))
	elseif method == "tool" then
		local _, h = Char.get()
		if not h then return false, "dead" end
		local tool = Interact.tool(Config.Modules[module].tool)
		if not tool then return false, "tool missing" end
		if tool.Parent ~= LP.Character then
			h:EquipTool(tool)
			task.wait(0.2)
		end
		local ok, err = pcall(function() tool:Activate() end)
		return ok, ok and ("Tool:Activate(" .. tool.Name .. ")") or ("Activate error: " .. tostring(err))
	end
	return false, "unknown method " .. tostring(method)
end

---------------------------------------------------------------------------------
-- RECORDER (attempts <-> server results, detections, per-scenario stats)
---------------------------------------------------------------------------------
local Recorder = {
	nextId = 0, pending = {}, recent = {}, detections = {}, gaps = {}, unmatched = 0,
	byModule = {}, byScenario = {}, detectors = {}, notes = {}, modulesRan = {},
}

local function bump(t, k) t[k] = (t[k] or 0) + 1 end
local function bucket(t, k)
	local b = t[k]
	if not b then b = {} t[k] = b end
	return b
end

function Recorder.attempt(module, target, valid, probe)
	Recorder.nextId += 1
	local rec = {
		id = Recorder.nextId, t = os.clock(), module = module, scenario = State.scenario,
		target = target, targetName = target and target.Name or "?", valid = valid, probe = probe,
		result = "PENDING", method = "?",
	}
	table.insert(Recorder.pending, rec)
	table.insert(Recorder.recent, rec)
	if #Recorder.recent > 200 then table.remove(Recorder.recent, 1) end
	Recorder.modulesRan[module] = true
	return rec
end

function Recorder.resolve(rec, result, reason)
	if rec.result ~= "PENDING" then return end
	rec.result, rec.reason = result, reason
	for i, p in ipairs(Recorder.pending) do
		if p == rec then table.remove(Recorder.pending, i) break end
	end
	bump(bucket(Recorder.byModule, rec.module), result)
	local s = bucket(Recorder.byScenario, rec.scenario)
	bump(s, (rec.valid and "valid_" or "invalid_") .. result)
	bump(s, "attempts")
	if not rec.valid and result == "ACCEPTED" then
		table.insert(Recorder.gaps, string.format("%s %s probe=%s target=%s method=%s", rec.scenario, rec.module, tostring(rec.probe), rec.targetName, rec.method))
		Log.status("VALIDATION GAP: server accepted invalid " .. tostring(rec.probe) .. " (" .. rec.module .. ")", true)
	end
end

local function sameTarget(a, b)
	if a == nil or b == nil then return true end
	if a == b then return true end
	local ok, r = pcall(function() return a:IsAncestorOf(b) or b:IsAncestorOf(a) end)
	return ok and r
end

function Recorder.onServerAction(msg)
	for _, rec in ipairs(Recorder.pending) do
		if rec.module == msg.module and sameTarget(rec.target, msg.target) then
			Recorder.resolve(rec, msg.accepted and "ACCEPTED" or "REJECTED", msg.reason)
			return
		end
	end
	Recorder.unmatched += 1 -- server result with no matching pending attempt (late or manual play)
end

function Recorder.onDetection(msg)
	local det = { t = os.clock(), detector = tostring(msg.detector), details = msg.details, scenario = State.scenario, module = State.currentModule }
	table.insert(Recorder.detections, det)
	bump(Recorder.detectors, det.detector)
	bump(bucket(Recorder.byScenario, det.scenario), "detections")
	Log.status("DETECTED by " .. det.detector .. " (" .. det.scenario .. ")", true)
end

function Recorder.sweep()
	local now = os.clock()
	for i = #Recorder.pending, 1, -1 do
		local rec = Recorder.pending[i]
		if now - rec.t > Config.PendingExpire then Recorder.resolve(rec, "NO_RESPONSE", nil) end
	end
end

function Recorder.await(rec, timeout)
	local deadline = os.clock() + timeout
	while rec.result == "PENDING" and os.clock() < deadline do task.wait(0.05) end
	return rec.result, rec.reason
end

---------------------------------------------------------------------------------
-- HARNESS (authorized server integration)
---------------------------------------------------------------------------------
local Harness = {
	authorized = false, reason = "connecting to test harness...", environment = nil,
	tags = { Flowers = "ARFarm_Flowers", NPC = "ARFarm_NPC", Wood = "ARFarm_Wood", Mining = "ARFarm_Mining" },
	marker = nil,
}

function Harness.connect()
	local folder = ReplicatedStorage:WaitForChild(Config.HarnessFolder, Config.HandshakeTimeout)
	if State.destroyed then return end
	if not folder then
		Harness.reason = "Integration missing: ReplicatedStorage." .. Config.HarnessFolder .. " not found (install server harness; private server only)"
		Log.status(Harness.reason, true)
		return
	end
	local hs = folder:WaitForChild("Handshake", 5)
	local tel = folder:WaitForChild("Telemetry", 5)
	Harness.marker = folder:FindFirstChild("Marker")
	if not (hs and hs:IsA("RemoteFunction") and tel and tel:IsA("RemoteEvent")) then
		Harness.reason = "Integration incomplete: Handshake/Telemetry remotes missing in " .. Config.HarnessFolder
		Log.status(Harness.reason, true)
		return
	end
	local ok, res = pcall(function() return hs:InvokeServer({ version = VERSION, executor = Caps.executor }) end)
	if State.destroyed then return end
	if not ok then
		Harness.reason = "Handshake failed: " .. tostring(res)
		Log.status(Harness.reason, true)
		return
	end
	if type(res) ~= "table" or res.authorized ~= true then
		Harness.reason = "Server refused: " .. tostring(type(res) == "table" and res.reason or res)
		Log.status(Harness.reason, true)
		return
	end
	if type(res.tags) == "table" then
		for k, v in pairs(res.tags) do Harness.tags[k] = v end
	end
	track(tel.OnClientEvent:Connect(function(msg)
		if type(msg) ~= "table" then return end
		if msg.type == "action" then Recorder.onServerAction(msg)
		elseif msg.type == "detection" then Recorder.onDetection(msg) end
	end))
	Harness.environment = res.environment
	Harness.authorized = true
	Harness.reason = "ok"
	Log.status("Harness OK (" .. tostring(res.environment) .. ") · scenario " .. State.scenario, false)
end

function Harness.mark(event, module)
	local m = Harness.marker
	if m and Harness.authorized then
		pcall(function() m:FireServer({ event = event, scenario = State.scenario, module = module }) end)
	end
end

---------------------------------------------------------------------------------
-- SCHEDULING HELPERS
---------------------------------------------------------------------------------
local burstState = { n = 0 }
local function nextInterval(sc)
	local s = sc.interval or { kind = "fixed", value = 1 }
	if s.kind == "fixed" then return s.value end
	if s.kind == "uniform" then return s.min + math.random() * (s.max - s.min) end
	if s.kind == "gaussian" then
		local u1, u2 = math.max(math.random(), 1e-6), math.random()
		local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
		return math.clamp(s.mean + z * s.sd, s.min or 0.05, s.max or s.mean * 4)
	end
	if s.kind == "burst" then
		burstState.n += 1
		if burstState.n >= s.length then burstState.n = 0 return s.slow end
		return s.fast
	end
	return 1
end

local function rollProbe(sc)
	if (sc.invalidChance or 0) <= 0 or not sc.probes or #sc.probes == 0 then return nil end
	if math.random() >= sc.invalidChance then return nil end
	return sc.probes[math.random(#sc.probes)]
end

-- Sends one recorded action (no waiting). Unsent actions are resolved immediately.
local function send(module, target, method, valid, probe, opts)
	local rec = Recorder.attempt(module, target, valid, probe)
	local sent, detail = Interact.perform(module, target, method, opts)
	rec.method = detail
	if not sent then Recorder.resolve(rec, valid and "CLIENT_FAILED" or "NOT_SENT", detail) end
	return rec
end

-- Waits up to AckWait for the server verdict; silence = NO_RESPONSE (late results count as unmatched).
local function finalize(rec)
	local result, reason = Recorder.await(rec, Config.AckWait)
	if result == "PENDING" then
		Recorder.resolve(rec, "NO_RESPONSE", nil)
		result = "NO_RESPONSE"
	end
	return result, reason or rec.reason
end

-- One action + verdict. rapid=true also fires an invalid duplicate right after sending,
-- before any server reply (probe "rapid_repeat"; expected: COOLDOWN rejection).
local function attempt(module, target, method, valid, probe, opts, rapid)
	local rec = send(module, target, method, valid, probe, opts)
	local dup = rapid and send(module, target, method, false, "rapid_repeat") or nil
	local result, reason = finalize(rec)
	if dup then finalize(dup) end
	return result, reason
end

---------------------------------------------------------------------------------
-- FARM MODULES  (identify -> move -> interact; each returns a result code)
---------------------------------------------------------------------------------
local Farm = {}

local function gatherStep(module, sc)
	local tag = Harness.tags[module]
	local _, _, root = Char.waitAlive()
	local pick = Targets.pick(module, Targets.collect(tag, Targets.resourceOk, root.Position), sc.selection)
	if not pick then return "NO_TARGET" end
	local target = pick.inst
	local method, why = Interact.resolve(module, target)
	if not method then return "NO_INTEGRATION", why end
	local range = Interact.range(module, target, method)
	local probe = rollProbe(sc)

	if probe == "out_of_range" then
		-- stop well outside range and try anyway; expected: client-blocked or server-rejected
		local res = Movement.goTo(pick.pos, range * 2.5 + 4, sc)
		if res == "DIED" or res == "INTERRUPTED" then return res end
		if method == "tool" then Movement.face(pick.pos) end
		attempt(module, target, method, false, probe)
		return "PROBED"
	end

	local res = Movement.goTo(pick.pos, range, sc)
	if res == "DIED" or res == "INTERRUPTED" then return res end
	if res ~= "ARRIVED" then
		Targets.ban(target)
		return "MOVE_FAILED", res
	end

	local mc = Config.Modules[module]
	for _ = 1, mc.maxHits do
		if not Targets.resourceOk(target, tag) then break end
		if method == "tool" then Movement.face(pick.pos) end
		local early = method == "prompt" and (sc.interruptChance or 0) > 0 and math.random() < sc.interruptChance
		local rapid = probe == "rapid_repeat" and not early
		if rapid then probe = nil end
		local result, reason = attempt(module, target, method, not early, early and "interrupted_hold" or nil,
			{ holdFraction = early and (0.2 + math.random() * 0.5) or nil }, rapid)
		if result == "CLIENT_FAILED" then
			Targets.ban(target)
			return "CLIENT_FAILED", reason
		end
		if result == "REJECTED" then
			if Config.InventoryFullReasons[reason] then return "INVENTORY_FULL" end
			if Config.DepletedReasons[reason] then Targets.ban(target) break end
		end
		task.wait(nextInterval(sc))
	end

	if probe == "depleted" then
		-- act on the resource we just finished; expected: rejected / not sendable
		attempt(module, target, method, false, probe)
	end
	return "DONE"
end

local function anyPlayerNear(radius)
	local _, _, r = Char.get()
	if not r then return false end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and p.Character then
			local pr = p.Character:FindFirstChild("HumanoidRootPart")
			if pr and (pr.Position - r.Position).Magnitude <= radius then return true end
		end
	end
	return false
end

local function npcStep(sc)
	local tag = Harness.tags.NPC
	local mc = Config.Modules.NPC
	local _, _, root = Char.waitAlive()
	local pick = Targets.pick("NPC", Targets.collect(tag, Targets.npcOk, root.Position), sc.selection)
	if not pick then return "NO_TARGET" end
	local npc = pick.inst
	local method, why = Interact.resolve("NPC", npc)
	if not method then return "NO_INTEGRATION", why end
	local hum = npc:FindFirstChildOfClass("Humanoid")
	local deadline = os.clock() + mc.perTargetTimeout

	while os.clock() < deadline and Targets.npcOk(npc, tag) do
		local pos = Targets.position(npc)
		local _, _, r = Char.get()
		if not r then return "DIED" end
		if not pos then break end
		if (pos - r.Position).Magnitude > mc.range then
			local res = Movement.goTo(pos, mc.range * 0.8, sc, 6) -- short legs: NPC moves
			if res == "DIED" or res == "INTERRUPTED" then return res end
			if res == "STUCK" then Targets.ban(npc) return "MOVE_FAILED", "stuck" end
		elseif anyPlayerNear(mc.playerSafetyRadius) then
			Log.status("NPC: player nearby — holding attacks", false)
			task.wait(0.5)
		else
			Movement.face(pos)
			local probe = rollProbe(sc)
			if probe == "out_of_range" then
				local _, _, r2 = Char.get()
				if r2 then
					local away = (r2.Position - pos) * Vector3.new(1, 0, 1)
					if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
					Movement.goTo(pos + away.Unit * (mc.range * 3 + 4), 2, sc, 4)
					Movement.face(pos)
				end
				attempt("NPC", npc, method, false, probe)
			else
				attempt("NPC", npc, method, true, nil, nil, probe == "rapid_repeat")
			end
			task.wait(nextInterval(sc))
		end
	end

	if hum and hum.Health <= 0 then
		bump(Recorder.notes, "npc_kills")
		return "KILLED"
	end
	if os.clock() >= deadline then
		Targets.ban(npc, 10)
		return "TIMEOUT"
	end
	return "DONE" -- despawned / untagged; respawns are picked up by the next scan
end

Farm.Flowers = function(sc) return gatherStep("Flowers", sc) end
Farm.Wood = function(sc) return gatherStep("Wood", sc) end
Farm.Mining = function(sc) return gatherStep("Mining", sc) end
Farm.NPC = npcStep

---------------------------------------------------------------------------------
-- RUNNER  (single worker thread => no duplicate loops, no movement conflicts)
---------------------------------------------------------------------------------
local Runner = { enabled = {}, thread = nil, onToggle = nil, gen = 0 }
for _, m in ipairs(MODULE_ORDER) do Runner.enabled[m] = false end

local function enabledList()
	local out = {}
	for _, m in ipairs(MODULE_ORDER) do
		if Runner.enabled[m] then out[#out + 1] = m end
	end
	return out
end

local function cancelWorker()
	Runner.gen += 1
	local th = Runner.thread
	Runner.thread = nil
	if th and th ~= coroutine.running() then pcall(task.cancel, th) end
	Interact.release()
	Movement.halt()
	State.currentModule = nil
end

local function setEnabled(module, on, reason, isError)
	Runner.enabled[module] = on
	if Runner.onToggle then pcall(Runner.onToggle, module, on) end
	if reason then Log.status(reason, isError) end
	Harness.mark(on and "module_on" or "module_off", module)
end

local function workerLoop(gen)
	local idx, current = 0, nil
	while gen == Runner.gen do
		local list = enabledList()
		if #list == 0 then break end
		Recorder.sweep()
		local sc = Scenarios[State.scenario] or Scenarios.baseline
		if sc.rotate or current == nil or not Runner.enabled[current] then
			idx = idx % #list + 1
			current = list[idx]
		end
		Char.waitAlive()
		State.currentModule = current
		local ok, res, detail = pcall(Farm[current], sc)
		State.currentModule = nil
		Interact.release()
		if gen ~= Runner.gen then return end -- superseded (cancel failed to stop us)

		if not ok then
			Log.status(current .. " error: " .. tostring(res), true)
			current = nil
			task.wait(2)
		elseif res == "NO_TARGET" then
			Log.status("No eligible " .. current .. " within " .. Config.SearchRadius .. " studs", false)
			current = nil -- let other enabled modules try
			task.wait(Config.IdleWait)
		elseif res == "NO_INTEGRATION" then
			setEnabled(current, false, current .. " OFF — integration missing: " .. tostring(detail), true)
			current = nil
		elseif res == "INVENTORY_FULL" then
			setEnabled(current, false, current .. " OFF — server reports inventory full", true)
			current = nil
		elseif res == "CLIENT_FAILED" or res == "MOVE_FAILED" then
			Log.status(current .. ": " .. res .. " (" .. tostring(detail) .. "), trying next target", true)
			task.wait(0.5)
		elseif res ~= "DIED" then
			Log.status(current .. " running · " .. State.scenario, false)
			if res ~= "DONE" then task.wait(nextInterval(sc)) end
		end
	end
	if gen ~= Runner.gen then return end
	Runner.thread = nil
	State.currentModule = nil
	Movement.halt()
end

local function ensureWorker()
	if State.destroyed then return end
	if Runner.thread and coroutine.status(Runner.thread) ~= "dead" then return end
	if #enabledList() == 0 then return end
	Runner.gen += 1
	Runner.thread = task.spawn(workerLoop, Runner.gen)
end

function Runner.set(module, on)
	if on then
		if not Harness.authorized then
			setEnabled(module, false, module .. " unavailable — " .. Harness.reason, true)
			return false
		end
		setEnabled(module, true, module .. " ON · scenario " .. State.scenario, false)
		ensureWorker()
	else
		local wasCurrent = State.currentModule == module
		setEnabled(module, false, module .. " OFF", false)
		if wasCurrent then
			cancelWorker() -- stop the in-flight action immediately
			ensureWorker() -- resume the remaining modules, if any
		end
	end
	return on
end

local suiteThread = nil
function Runner.stopAll()
	if suiteThread then pcall(task.cancel, suiteThread) suiteThread = nil end
	for _, m in ipairs(MODULE_ORDER) do
		if Runner.enabled[m] then setEnabled(m, false) end
	end
	cancelWorker()
	Log.status("All stopped", false)
end

track(LP.CharacterAdded:Connect(function()
	Interact.release()
	if Runner.thread then
		cancelWorker()
		task.delay(0.5, ensureWorker)
	end
end))

---------------------------------------------------------------------------------
-- REPORT (verification checklist from observed data)
---------------------------------------------------------------------------------
local function buildReport()
	Recorder.sweep()
	local L = {}
	local function add(fmt, ...) L[#L + 1] = string.format(fmt, ...) end
	local function yn(b) return b and "yes" or "no" end
	add("==== ABOVE[RUINS] FARM TEST REPORT  v%s ====", VERSION)
	add("Executor: %s | getgenv %s | fireproximityprompt %s | fireclickdetector %s | setclipboard %s",
		Caps.executor, yn(Caps.getgenv), yn(Caps.fireproximityprompt), yn(Caps.fireclickdetector), yn(Caps.setclipboard))
	add("Harness: %s%s", Harness.authorized and "AUTHORIZED" or "NOT AVAILABLE", Harness.authorized and (" (" .. tostring(Harness.environment) .. ")") or (" — " .. Harness.reason))
	add("")
	add("%-8s %-6s %6s %8s %8s %7s %8s %8s", "MODULE", "TESTED", "TOTAL", "ACCEPT", "REJECT", "NORESP", "CLIFAIL", "NOTSENT")
	for _, m in ipairs(MODULE_ORDER) do
		local b = Recorder.byModule[m] or {}
		local total = 0
		for _, v in pairs(b) do total += v end
		add("%-8s %-6s %6d %8d %8d %7d %8d %8d", m, yn(Recorder.modulesRan[m]), total, b.ACCEPTED or 0, b.REJECTED or 0,
			b.NO_RESPONSE or 0, b.CLIENT_FAILED or 0, b.NOT_SENT or 0)
		if total > 0 and (b.NO_RESPONSE or 0) == total then
			add("         ^ server never reported a result: wire Telemetry.action(...) into your %s handler", m)
		end
	end
	add("")
	add("%-14s %5s %9s %9s %9s %9s %5s  %s", "SCENARIO", "ATT", "V.ACCEPT", "V.REJECT", "I.ACCEPT", "I.REJECT", "DET", "VERDICT")
	local names = {}
	for n in pairs(Recorder.byScenario) do names[#names + 1] = n end
	table.sort(names)
	for _, n in ipairs(names) do
		local s = Recorder.byScenario[n]
		local att, det = s.attempts or 0, s.detections or 0
		local verdict = det > 0 and "DETECTED" or (att >= Config.MinAttemptsForVerdict and "UNDETECTED" or "INSUFFICIENT DATA")
		add("%-14s %5d %9d %9d %9d %9d %5d  %s", n, att, s.valid_ACCEPTED or 0, s.valid_REJECTED or 0,
			s.invalid_ACCEPTED or 0, s.invalid_REJECTED or 0, det, verdict)
	end
	add("")
	add("Detections by detector:")
	local any = false
	for d, c in pairs(Recorder.detectors) do add("  %-24s %d", d, c) any = true end
	if not any then add("  (none received)") end
	add("Validation gaps (invalid attempts the server ACCEPTED):")
	if #Recorder.gaps == 0 then add("  (none)") end
	for _, g in ipairs(Recorder.gaps) do add("  %s", g) end
	add("Unmatched server results: %d | NPC kills: %d | pending: %d", Recorder.unmatched, Recorder.notes.npc_kills or 0, #Recorder.pending)
	return table.concat(L, "\n")
end

---------------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------------
local COLORS = {
	bg = Color3.fromRGB(14, 14, 16),
	row = Color3.fromRGB(22, 22, 26),
	stroke = Color3.fromRGB(38, 38, 44),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(130, 130, 140),
	blue = Color3.fromRGB(0, 162, 255),
	off = Color3.fromRGB(48, 48, 54),
	red = Color3.fromRGB(255, 90, 90),
}
local FONT, FONT_BOLD = Enum.Font.GothamMedium, Enum.Font.GothamBold
local TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function make(class, props, children)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	for _, c in ipairs(children or {}) do c.Parent = o end
	return o
end
local function corner(r) return make("UICorner", { CornerRadius = UDim.new(0, r) }) end

local gui = make("ScreenGui", { Name = "ARFarmTester", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50 })

local WIDTH, TITLE_H, ROW_H = 230, 34, 32
local main = make("Frame", {
	Name = "Main", Size = UDim2.fromOffset(WIDTH, 0), AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(0, 24, 0.3, 0), BackgroundColor3 = COLORS.bg, BorderSizePixel = 0, Parent = gui,
}, {
	corner(10),
	make("UIStroke", { Color = COLORS.stroke, Thickness = 1 }),
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
})

local title = make("Frame", { Name = "Title", Size = UDim2.new(1, 0, 0, TITLE_H), BackgroundTransparency = 1, LayoutOrder = 1, Parent = main })
make("TextLabel", {
	Text = "ABOVE[RUINS] | FARM", Font = FONT_BOLD, TextSize = 13, TextColor3 = COLORS.text,
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -48, 1, 0), Parent = title,
})
local minBtn = make("TextButton", {
	Text = "–", Font = FONT_BOLD, TextSize = 16, TextColor3 = COLORS.dim, AutoButtonColor = false,
	BackgroundColor3 = COLORS.row, Size = UDim2.fromOffset(22, 22), Position = UDim2.new(1, -30, 0.5, -11), Parent = title,
}, { corner(6) })

local body = make("Frame", {
	Name = "Body", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = main,
}, {
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }),
})

local switches = {}
local LABELS = { Flowers = "Flowers", NPC = "NPC Farm", Wood = "Wood", Mining = "Mining" }

local function renderSwitch(sw, on, instant)
	local knobPos = on and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2)
	local trackColor = on and COLORS.blue or COLORS.off
	if instant then
		sw.knob.Position, sw.track.BackgroundColor3 = knobPos, trackColor
	else
		TweenService:Create(sw.knob, TWEEN, { Position = knobPos }):Play()
		TweenService:Create(sw.track, TWEEN, { BackgroundColor3 = trackColor }):Play()
	end
end


for i, m in ipairs(MODULE_ORDER) do
	local row = make("TextButton", {
		Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.row, LayoutOrder = i,
		Size = UDim2.new(1, 0, 0, ROW_H), Parent = body,
	}, { corner(8) })
	make("TextLabel", {
		Text = LABELS[m], Font = FONT, TextSize = 13, TextColor3 = COLORS.text, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -60, 1, 0), Parent = row,
	})
	local trackFrame = make("Frame", {
		BackgroundColor3 = COLORS.off, Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -48, 0.5, -10), Parent = row,
	}, { corner(10) })
	local knob = make("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2), Parent = trackFrame,
	}, { corner(8) })
	switches[m] = { track = trackFrame, knob = knob }
	track(row.MouseButton1Click:Connect(function()
		Runner.set(m, not Runner.enabled[m])
	end))
end

local stopBtn = make("TextButton", {
	Text = "STOP ALL", Font = FONT_BOLD, TextSize = 13, TextColor3 = COLORS.red, AutoButtonColor = false,
	BackgroundColor3 = COLORS.row, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 10, Parent = body,
}, { corner(8), make("UIStroke", { Color = COLORS.stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
track(stopBtn.MouseButton1Click:Connect(function() Runner.stopAll() end))

-- one-line status: the only place errors / "integration missing" surface in the menu
local statusLbl = make("TextLabel", {
	Text = Harness.reason, Font = FONT, TextSize = 11, TextColor3 = COLORS.dim, BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 11, Parent = body,
})
Log.onStatus = function(msg, isError)
	statusLbl.Text = msg
	statusLbl.TextColor3 = isError and COLORS.red or COLORS.dim
end
Runner.onToggle = function(module, on)
	local sw = switches[module]
	if sw then renderSwitch(sw, on, false) end
end

-- minimize
local minimized = false
track(minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	minBtn.Text = minimized and "+" or "–"
end))

-- drag by title bar (mouse + touch)
do
	local dragging, dragStart, startPos = false, nil, nil
	track(title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

-- PlayerGui on purpose (visible to the game's own anti-cheat; no concealment)
gui.Parent = LP:WaitForChild("PlayerGui")

---------------------------------------------------------------------------------
-- HIDDEN CONSOLE API
---------------------------------------------------------------------------------
local API = { Version = VERSION, Config = Config, Scenarios = Scenarios, Caps = Caps }

function API.SetScenario(name)
	if not Scenarios[name] then
		local list = {}
		for n in pairs(Scenarios) do list[#list + 1] = n end
		table.sort(list)
		warn("[ARFarm] unknown scenario '" .. tostring(name) .. "'. Available: " .. table.concat(list, ", "))
		return false
	end
	State.scenario = name
	burstState.n = 0
	Harness.mark("scenario", nil)
	Log.status("Scenario: " .. name, false)
	return true
end

function API.RunSuite(names, secondsEach)
	if suiteThread then pcall(task.cancel, suiteThread) end
	secondsEach = tonumber(secondsEach) or 120
	suiteThread = task.spawn(function()
		for _, n in ipairs(names or {}) do
			if API.SetScenario(n) then task.wait(secondsEach) end
		end
		suiteThread = nil
		Log.status("Suite finished — run ARFarm.Report()", false)
	end)
end

function API.Report(copy)
	local text = buildReport()
	print(text)
	if copy ~= false and Caps.setclipboard then
		pcall(setclipboard, text)
		print("[ARFarm] report copied to clipboard")
	end
	return text
end

function API.Recent(n)
	n = n or 20
	local r = Recorder.recent
	for i = math.max(1, #r - n + 1), #r do
		local a = r[i]
		print(string.format("#%d %-8s %-13s valid=%-5s probe=%-14s %-12s %-15s %s", a.id, a.module, a.scenario,
			tostring(a.valid), tostring(a.probe), a.result, tostring(a.reason), a.method))
	end
end

API.Set = Runner.set
API.StopAll = Runner.stopAll
API.Status = function() return { harness = Harness.reason, scenario = State.scenario, enabled = Runner.enabled, current = State.currentModule } end

function API.Destroy()
	if State.destroyed then return end
	Runner.stopAll()
	State.destroyed = true
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	table.clear(connections)
	pcall(function() gui:Destroy() end)
	if ENV.ARFarm == API then ENV.ARFarm = nil end
end

ENV.ARFarm = API
task.spawn(Harness.connect)
print("[ARFarm] v" .. VERSION .. " loaded · executor: " .. Caps.executor .. " · console: getgenv().ARFarm.Report()")
