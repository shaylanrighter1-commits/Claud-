-- ABOVE[RUINS] | AUTO BUILDER (server-authorized) - one-paste installer
-- 1. In Roblox Studio open your place (a Baseplate is fine).   2. View > Command Bar.
-- 3. Paste this ENTIRE file into the Command Bar and press Enter.   4. Press Play.
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SPS = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")

local function folder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end
local rsFolder, sssFolder = folder(RS, "AutoBuilder"), folder(SSS, "AutoBuilder")
local parents = { RS = rsFolder, SSS = sssFolder, SPS = SPS }

local function put(where, class, name, source)
	local parent = parents[where]
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local obj = Instance.new(class)
	obj.Name = name
	obj.Source = source
	obj.Parent = parent
end

put("RS", "ModuleScript", "Shared", [==[
--!nocheck
-- Shared by the server and the client: the grid, the settings, and the area maths.
-- Pure Lua on purpose (cells are plain {x=,y=,z=} tables), so it can be unit-tested outside Roblox.
local Shared = {}

Shared.CONFIG = {
	GRID = 4, -- studs per block. MUST match your game's block size.
	ORIGIN = { x = 0, y = 0, z = 0 }, -- world position of the lowest corner of cell (0,0,0). Must match your game's grid.
	MAX_CELLS = 4000, -- biggest area one build may cover
	BLOCKS_PER_SECOND = 30, -- build speed (the server paces itself; raise or lower to taste)
	MAX_COORD = 100000, -- cell coordinates beyond this are rejected
}

function Shared.cellKey(c)
	return string.format("%d,%d,%d", c.x, c.y, c.z)
end

-- the grid cell that contains the world point (x, y, z)
function Shared.worldToCell(x, y, z)
	local g, o = Shared.CONFIG.GRID, Shared.CONFIG.ORIGIN
	return {
		x = math.floor((x - o.x) / g),
		y = math.floor((y - o.y) / g),
		z = math.floor((z - o.z) / g),
	}
end

-- world position of the middle of a cell
function Shared.cellCenter(c)
	local g, o = Shared.CONFIG.GRID, Shared.CONFIG.ORIGIN
	return o.x + (c.x + 0.5) * g, o.y + (c.y + 0.5) * g, o.z + (c.z + 0.5) * g
end

local function isInt(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge and n == math.floor(n)
end

-- A cell sent over the network is never trusted: it must be a table of three whole numbers in range.
function Shared.cleanCell(c)
	if type(c) ~= "table" then
		return nil
	end
	local x, y, z = c.x, c.y, c.z
	local m = Shared.CONFIG.MAX_COORD
	if isInt(x) and isInt(y) and isInt(z) and math.abs(x) <= m and math.abs(y) <= m and math.abs(z) <= m then
		return { x = x, y = y, z = z }
	end
	return nil
end

-- Two corners -> (mn, mx, count), or nil + the reason.
function Shared.area(a, b)
	local ca, cb = Shared.cleanCell(a), Shared.cleanCell(b)
	if not ca or not cb then
		return nil, "That area isn't valid."
	end
	local mn = { x = math.min(ca.x, cb.x), y = math.min(ca.y, cb.y), z = math.min(ca.z, cb.z) }
	local mx = { x = math.max(ca.x, cb.x), y = math.max(ca.y, cb.y), z = math.max(ca.z, cb.z) }
	local count = (mx.x - mn.x + 1) * (mx.y - mn.y + 1) * (mx.z - mn.z + 1)
	if count > Shared.CONFIG.MAX_CELLS then
		return nil, string.format("That area is too big (%d blocks, the limit is %d).", count, Shared.CONFIG.MAX_CELLS)
	end
	return mn, mx, count
end

-- One fixed order: the bottom layer first, then row by row (z), and every row left to right (x).
function Shared.buildOrder(mn, mx)
	local xs, ys, zs, n = {}, {}, {}, 0
	for y = mn.y, mx.y do
		for z = mn.z, mx.z do
			for x = mn.x, mx.x do
				n = n + 1
				xs[n], ys[n], zs[n] = x, y, z
			end
		end
	end
	return { n = n, xs = xs, ys = ys, zs = zs }
end

return Shared
]==])

put("SSS", "ModuleScript", "BuildJob", [==[
--!nocheck
-- The build loop. Plain Lua with NO Roblox API: everything it needs from the world comes through `env`,
-- so the rules below are unit-tested (tests/run_tests.py) without Roblox.
--
-- Rules this module enforces, whatever the backend does:
--   * the block is TAKEN from the inventory first and handed back if the placement fails,
--     so the inventory only ever goes down by the number of blocks that were really placed;
--   * `placed` counts only blocks the backend confirmed, and can never exceed `total`;
--   * a cell this job filled is never placed again; an occupied cell is skipped (never overwritten);
--   * a cell the player isn't allowed to build in is never built;
--   * running out of blocks pauses the job (it can be resumed); STOP leaves the job resumable too.
local BuildJob = {}

local function key(c)
	return string.format("%d,%d,%d", c.x, c.y, c.z)
end

function BuildJob.new(mn, mx, itemId, order)
	return { mn = mn, mx = mx, itemId = itemId, order = order, placed = 0, total = 0, placedSet = {}, todo = {} }
end

-- Look at the world now: which cells still need a block?  total = placed so far + still empty.
-- env.isOccupied(cell) -> bool, env.wait(s), env.stopped() -> bool.   Returns false if STOP was pressed.
function BuildJob.plan(job, env)
	local order, todo = job.order, {}
	for i = 1, order.n do
		local cell = { x = order.xs[i], y = order.ys[i], z = order.zs[i] }
		if not job.placedSet[key(cell)] and not env.isOccupied(cell) then
			todo[#todo + 1] = cell
		end
		if i % 200 == 0 then
			env.wait(0) -- never hold up the server while looking at a big area
			if env.stopped() then
				return false
			end
		end
	end
	job.todo = todo
	job.total = job.placed + #todo
	return true
end

-- env: stopped() isOccupied(cell) canBuild(cell)->ok,why owned()->number|nil take()->bool give()
--      place(cell)->ok,why wait(s) progress(job) log(text)
-- cfg: perBatch (blocks between pauses), batchDelay (seconds), maxFails
-- Returns  "done"
--          "stopped"
--          "paused", code, extra     code = "noblocks" | "failed" | "denied" | "gaps"
function BuildJob.run(job, env, cfg)
	cfg = cfg or {}
	local perBatch, batchDelay, maxFails = cfg.perBatch or 3, cfg.batchDelay or 0.1, cfg.maxFails or 3
	if not BuildJob.plan(job, env) then
		return "stopped"
	end
	env.progress(job)

	local round = 0
	while true do
		round = round + 1
		local todo = job.todo
		local denied, deniedWhy = {}, nil
		local sinceWait = 0
		local deferred, failWhy = {}, nil
		for attempt = 1, 2 do
			deferred = {}
			local fails = 0
			for _, cell in ipairs(todo) do
				if env.stopped() then
					return "stopped"
				end
				if job.placed >= job.total then
					break -- complete: never place one more than this job needs
				end
				local k = key(cell)
				if job.placedSet[k] then
					-- this job already filled it: never place here again
				elseif env.isOccupied(cell) then
					job.total = job.total - 1 -- somebody / something filled it: skip it, never overwrite
				else
					local allowed, why = env.canBuild(cell)
					if not allowed then
						if attempt == 1 then
							denied[#denied + 1] = cell
						end
						deniedWhy = why
					else
						local owned = env.owned()
						if owned == nil or owned < 1 or not env.take() then
							return "paused", "noblocks", { remaining = job.total - job.placed }
						end
						local ok, placeWhy = env.place(cell)
						if ok then
							job.placed = job.placed + 1
							job.placedSet[k] = true
							fails = 0
							env.progress(job)
							sinceWait = sinceWait + 1
							if sinceWait >= perBatch then
								sinceWait = 0
								env.wait(batchDelay)
							end
						else
							env.give() -- the placement failed: the block goes back to the player
							deferred[#deferred + 1] = cell
							failWhy = placeWhy
							fails = fails + 1
							if fails >= maxFails then
								return "paused", "failed", { remaining = #deferred, why = failWhy }
							end
						end
					end
				end
			end
			todo = deferred
			if #deferred == 0 or job.placed >= job.total then
				deferred = {}
				break
			end
			env.wait(0.2)
		end
		if #deferred > 0 then
			return "paused", "failed", { remaining = #deferred, why = failWhy }
		end
		if #denied > 0 then
			return "paused", "denied", { remaining = #denied, why = deniedWhy }
		end
		-- "done" is only believed after a second look at the world: no empty cell may be left.
		if not BuildJob.plan(job, env) then
			return "stopped"
		end
		if #job.todo == 0 then
			env.progress(job)
			return "done"
		end
		if round >= 2 then
			return "paused", "gaps", { remaining = #job.todo }
		end
	end
end

return BuildJob
]==])

put("SSS", "ModuleScript", "Backend", [==[
--!nocheck
-- BACKEND: everything the Auto Builder needs from YOUR game, in six small functions.
--
-- As shipped this is a self-contained TEST WORLD, so the whole system runs in an empty Baseplate:
--   * each player gets four "block" Tools (Grass Block, Dirt Block, Stone Block, Wood Planks) in the
--     normal Roblox hotbar, with a block count kept in player attributes;
--   * blocks are real Parts in Workspace.AutoBuilderBlocks;
--   * you may build in a box around the origin.
--
-- To use it in your real game, set TEST_WORLD = false and make these functions call YOUR OWN server code,
-- so your game's rules (land ownership, inventory, saving, anti-cheat) stay in charge:
--
--   Backend.getEquipped(player) -> { id, name, owned } | nil, reason     what the player is holding
--   Backend.getOwned(player, id) -> number                               how many of it they own
--   Backend.take(player, id, n)  -> boolean                              remove n from their inventory (false if they don't have it)
--   Backend.give(player, id, n)                                          put n back (used if a placement fails)
--   Backend.canBuild(player, cell) -> ok, reason                         may THIS player build in THIS cell? (land / permission)
--   Backend.isOccupied(cell) -> boolean                                  is there already a block in this cell?
--   Backend.place(player, id, cell) -> ok, reason                        really place the block (call your own placement function)
--
-- `cell` is {x=,y=,z=} on the grid in Shared.CONFIG (GRID and ORIGIN must match your game's grid).
-- Nothing here trusts the client: it only ever sends two corner cells.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("AutoBuilder"):WaitForChild("Shared"))

local Backend = {}
Backend.TEST_WORLD = true

----------------------------------------------------------------------------------------------
-- test world
----------------------------------------------------------------------------------------------
local BLOCKS = {
	grass_block = { name = "Grass Block", color = Color3.fromRGB(86, 168, 62), material = Enum.Material.Grass, start = 300 },
	dirt_block = { name = "Dirt Block", color = Color3.fromRGB(120, 85, 52), material = Enum.Material.Ground, start = 300 },
	stone_block = { name = "Stone Block", color = Color3.fromRGB(125, 128, 135), material = Enum.Material.Slate, start = 300 },
	wood_planks = { name = "Wood Planks", color = Color3.fromRGB(176, 128, 74), material = Enum.Material.WoodPlanks, start = 300 },
}
local ORDER = { "grass_block", "dirt_block", "stone_block", "wood_planks" }

-- where players may build in the test world (cells)
local ZONE = { x = 60, z = 60, yMin = 0, yMax = 40 }

local blockFolder = Workspace:FindFirstChild("AutoBuilderBlocks")
if not blockFolder then
	blockFolder = Instance.new("Folder")
	blockFolder.Name = "AutoBuilderBlocks"
	blockFolder.Parent = Workspace
end

local function owned(player, id)
	return player:GetAttribute("inv_" .. id) or 0
end

local function giveTools(player)
	local pack = player:WaitForChild("Backpack")
	for _, id in ipairs(ORDER) do
		local def = BLOCKS[id]
		local has = pack:FindFirstChild(def.name) or (player.Character and player.Character:FindFirstChild(def.name))
		if not has then
			local tool = Instance.new("Tool")
			tool.Name = def.name
			tool.RequiresHandle = false
			tool.CanBeDropped = false
			tool:SetAttribute("ItemId", id)
			tool.Parent = pack
		end
	end
end

-- called once for every player by the server script
function Backend.setup(player)
	if not Backend.TEST_WORLD then
		return
	end
	for _, id in ipairs(ORDER) do
		if player:GetAttribute("inv_" .. id) == nil then
			player:SetAttribute("inv_" .. id, BLOCKS[id].start)
		end
	end
	player.CharacterAdded:Connect(function()
		giveTools(player)
	end)
	if player.Character then
		giveTools(player)
	end
end

----------------------------------------------------------------------------------------------
-- the six functions
----------------------------------------------------------------------------------------------
function Backend.getEquipped(player)
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return nil, "Equip a block first."
	end
	local id = tool:GetAttribute("ItemId")
	local def = id and BLOCKS[id]
	if not def then
		return nil, "'" .. tool.Name .. "' is not a block that can be placed."
	end
	return { id = id, name = def.name, owned = owned(player, id) }
end

function Backend.getOwned(player, id)
	return owned(player, id)
end

function Backend.take(player, id, n)
	local have = owned(player, id)
	if have < n then
		return false
	end
	player:SetAttribute("inv_" .. id, have - n)
	return true
end

function Backend.give(player, id, n)
	player:SetAttribute("inv_" .. id, owned(player, id) + n)
end

function Backend.canBuild(_, cell)
	if math.abs(cell.x) > ZONE.x or math.abs(cell.z) > ZONE.z or cell.y < ZONE.yMin or cell.y > ZONE.yMax then
		return false, "outside the area where building is allowed"
	end
	return true
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 20
local filterAt = 0
function Backend.isOccupied(cell)
	if os.clock() - filterAt > 0.5 then
		filterAt = os.clock()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				list[#list + 1] = p.Character
			end
		end
		overlap.FilterDescendantsInstances = list
	end
	local g = Shared.CONFIG.GRID
	local x, y, z = Shared.cellCenter(cell)
	-- (a little smaller than the cell, so a neighbour that only touches it doesn't count)
	for _, part in ipairs(Workspace:GetPartBoundsInBox(CFrame.new(x, y, z), Vector3.new(g - 0.5, g - 0.5, g - 0.5), overlap)) do
		if part.CanCollide and not part:IsA("Terrain") then
			return true
		end
	end
	return false
end

function Backend.place(player, id, cell)
	local def = BLOCKS[id]
	if not def then
		return false, "unknown block"
	end
	if Backend.isOccupied(cell) then
		return false, "that spot is taken"
	end
	local g = Shared.CONFIG.GRID
	local x, y, z = Shared.cellCenter(cell)
	local part = Instance.new("Part")
	part.Name = "ARBlock"
	part.Anchored = true
	part.Size = Vector3.new(g, g, g)
	part.CFrame = CFrame.new(x, y, z)
	part.Color = def.color
	part.Material = def.material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("OwnerUserId", player.UserId)
	part.Parent = blockFolder
	return true
end

return Backend
]==])

put("SSS", "Script", "AutoBuilderServer", [==[
--!nocheck
-- AUTO BUILDER - server. The server is the only thing that places blocks or touches the inventory.
-- The client sends two corner cells and "start" / "stop"; everything else (what block, how many you own,
-- whether you may build there, the placing itself) is decided here, so the player does not need to be near
-- the construction and nothing the client sends can give free blocks or build where it shouldn't.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("AutoBuilder")
local Shared = require(folder:WaitForChild("Shared"))
local BuildJob = require(script.Parent:WaitForChild("BuildJob"))
local Backend = require(script.Parent:WaitForChild("Backend"))

local function remote(class, name)
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new(class)
		r.Name = name
		r.Parent = folder
	end
	return r
end
local Action = remote("RemoteEvent", "Action") -- client -> server: "start", a, b   |   "stop"
local Update = remote("RemoteEvent", "Update") -- server -> client: state table
local Query = remote("RemoteFunction", "Query") -- client -> server: (a, b) -> state table

local MAX_ACTIVE_BUILDS = 10 -- builds running at once on this server
local sessions = {} -- [player] = { job, running, runId, lastAction, lastQuery, scanning, lastState, lastPush }
local active = 0

local function log(...)
	print("[AutoBuilder]", ...)
end

local function session(player)
	local s = sessions[player]
	if not s then
		s = { job = nil, running = false, runId = 0, lastAction = -math.huge, lastQuery = -math.huge, scanning = false, lastPush = -math.huge }
		sessions[player] = s
	end
	return s
end

local function sameArea(job, mn, mx, itemId)
	return job.itemId == itemId
		and job.mn.x == mn.x and job.mn.y == mn.y and job.mn.z == mn.z
		and job.mx.x == mx.x and job.mx.y == mx.y and job.mx.z == mx.z
end

-- what the menu shows
local function stateFor(player, s, status, code, message)
	local held = Backend.getEquipped(player)
	local job = s.job
	local state = {
		status = status, code = code, message = message,
		name = held and held.name or nil,
		owned = held and held.owned or nil,
		placed = job and job.placed or 0,
		total = job and job.total or 0,
		resumable = job ~= nil and not s.running and status ~= "done",
	}
	if job and (s.running or state.resumable) then
		state.needed = math.max(0, job.total - job.placed)
	end
	return state
end

local function push(player, s, status, code, message, force)
	local now = os.clock()
	if not force and now - s.lastPush < 0.1 then
		return
	end
	s.lastPush = now
	s.lastState = stateFor(player, s, status, code, message)
	Update:FireClient(player, s.lastState)
end

local function describe(code, extra, job, name)
	local left = extra and extra.remaining or 0
	if code == "noblocks" then
		return string.format("OUT OF %s - placed %d of %d. Get %d more, then press RESUME.", string.upper(name or "BLOCKS"), job.placed, job.total, left)
	elseif code == "denied" then
		return string.format("NOT ALLOWED: %d blocks are where you can't build (%s). The rest was built.", left, tostring(extra and extra.why or "no permission"))
	elseif code == "failed" then
		return string.format("%d blocks could not be placed (%s). Your blocks were not used. Press RESUME to try again.", left, tostring(extra and extra.why or "unknown"))
	elseif code == "gaps" then
		return string.format("%d spots still look empty after building. Press RESUME to fill them.", left)
	end
	return "Stopped."
end

local function startBuild(player, s, job)
	active = active + 1
	s.running = true
	s.runId = s.runId + 1
	local run = s.runId
	local name = (Backend.getEquipped(player) or {}).name

	local env = {
		stopped = function()
			return s.runId ~= run or player.Parent == nil
		end,
		isOccupied = function(cell)
			return Backend.isOccupied(cell)
		end,
		canBuild = function(cell)
			return Backend.canBuild(player, cell)
		end,
		owned = function()
			return Backend.getOwned(player, job.itemId)
		end,
		take = function()
			return Backend.take(player, job.itemId, 1)
		end,
		give = function()
			Backend.give(player, job.itemId, 1)
		end,
		place = function(cell)
			local ok, placed, why = pcall(Backend.place, player, job.itemId, cell)
			if not ok then
				warn("[AutoBuilder] place failed:", placed)
				return false, "server error"
			end
			return placed, why
		end,
		wait = function(t)
			task.wait(t)
		end,
		progress = function(j)
			push(player, s, "building", "building", string.format("BUILDING %d/%d", j.placed, j.total))
		end,
		log = log,
	}
	local bps = Shared.CONFIG.BLOCKS_PER_SECOND
	local perBatch = math.max(1, math.floor(bps / 10 + 0.5))
	local cfg = { perBatch = perBatch, batchDelay = perBatch / bps, maxFails = 3 }

	task.spawn(function()
		local ok, outcome, code, extra = pcall(BuildJob.run, job, env, cfg)
		active = active - 1
		s.running = false -- (only one build runs per player at a time, so this thread is the one that set it)
		if player.Parent == nil then
			return
		end
		if not ok then
			warn("[AutoBuilder] build crashed:", outcome)
			push(player, s, "paused", "error", "Something went wrong on the server. Press RESUME to try again.", true)
		elseif outcome == "done" then
			s.job = nil
			local state = stateFor(player, s, "done", "done", string.format("DONE - %d blocks placed.", job.placed))
			state.placed, state.total, state.resumable = job.placed, job.total, false
			s.lastState = state
			Update:FireClient(player, state)
		elseif outcome == "stopped" then
			push(player, s, "paused", "stopped", string.format("STOPPED at %d of %d. Press RESUME to continue.", job.placed, job.total), true)
		else
			push(player, s, "paused", code, describe(code, extra, job, name), true)
		end
		log(player.Name, "build", tostring(outcome), tostring(code), string.format("%d/%d", job.placed, job.total))
	end)
end

Action.OnServerEvent:Connect(function(player, kind, a, b)
	local s = session(player)
	if kind == "stop" then
		if s.running then
			s.runId = s.runId + 1 -- the build loop sees this before its next block
		end
		return
	end
	local now = os.clock()
	if kind ~= "start" or s.running or now - s.lastAction < 0.15 then
		return -- unknown request, a build is already running, or too many requests
	end
	s.lastAction = now

	local mn, mx = Shared.area(a, b)
	if not mn then
		push(player, s, "error", "invalid", tostring(mx), true)
		return
	end
	local held, why = Backend.getEquipped(player) -- what is in the hand is decided HERE, never by the client
	if not held then
		push(player, s, "error", "noitem", tostring(why), true)
		return
	end
	if held.owned < 1 then
		push(player, s, "error", "noblocks", string.format("You have no %s.", held.name), true)
		return
	end
	if active >= MAX_ACTIVE_BUILDS then
		push(player, s, "error", "busy", "The server is busy building for other players. Try again in a moment.", true)
		return
	end
	local job = s.job
	if not (job and sameArea(job, mn, mx, held.id)) then
		job = BuildJob.new(mn, mx, held.id, Shared.buildOrder(mn, mx)) -- a new job: the counters start from zero
		s.job = job
	end
	startBuild(player, s, job)
end)

-- The menu asks about the area it has selected: how many blocks are needed, how many you own, may you build there.
local function scanArea(player, s, mn, mx)
	local order = Shared.buildOrder(mn, mx)
	local empty, denied, deniedWhy = 0, 0, nil
	for i = 1, order.n do
		local cell = { x = order.xs[i], y = order.ys[i], z = order.zs[i] }
		if not Backend.isOccupied(cell) then
			empty = empty + 1
			local ok, why = Backend.canBuild(player, cell)
			if not ok then
				denied = denied + 1
				deniedWhy = why
			end
		end
		if i % 200 == 0 then
			task.wait()
		end
	end
	return empty, denied, deniedWhy
end

Query.OnServerInvoke = function(player, a, b)
	local s = session(player)
	local now = os.clock()
	if s.running or s.scanning or now - s.lastQuery < 0.15 then
		return s.lastState or stateFor(player, s, "idle", "ready", "READY")
	end
	s.lastQuery = now
	local state = stateFor(player, s, "idle", "ready", "READY")
	state.resumable, state.placed, state.total, state.needed = false, 0, 0, nil
	if a == nil or b == nil then
		state.message = state.name and "READY" or "Equip a block first."
		return state
	end
	local mn, mx = Shared.area(a, b)
	if not mn then
		state.status, state.code, state.message = "error", "invalid", tostring(mx)
		return state
	end
	s.scanning = true
	local ok, empty, denied, deniedWhy = pcall(scanArea, player, s, mn, mx)
	s.scanning = false
	if not ok then
		warn("[AutoBuilder] area scan failed:", empty)
		state.status, state.code, state.message = "error", "failed", "Could not look at that area."
		return state
	end
	state.needed = empty
	local held = Backend.getEquipped(player)
	local job = s.job
	if job and held and sameArea(job, mn, mx, held.id) then
		state.resumable = true -- a stopped build of exactly this area: the button says RESUME
		state.placed, state.total = job.placed, job.placed + empty
	else
		state.total = empty
	end
	if denied > 0 then
		state.message = string.format("NOT ALLOWED: %d of these spots are where you can't build (%s).", denied, tostring(deniedWhy))
	elseif empty == 0 then
		state.message = "Nothing to build - the area is already full."
	elseif not state.name then
		state.message = "Equip a block first."
	elseif state.owned and state.owned < empty then
		state.message = string.format("You need %d more %s.", empty - state.owned, state.name)
	else
		state.message = "READY"
	end
	s.lastState = state
	return state
end

local function onPlayer(player)
	session(player)
	if Backend.setup then
		Backend.setup(player)
	end
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, p)
end
Players.PlayerRemoving:Connect(function(player)
	local s = sessions[player]
	if s then
		s.runId = s.runId + 1 -- stops a running build
	end
	sessions[player] = nil
end)

log("ready")
]==])

put("SPS", "LocalScript", "AutoBuilderClient", [==[
--!nocheck
-- AUTO BUILDER - client: the small menu, the two-corner selection and the orange outline.
-- It never moves your character and never touches your camera. It only tells the server which two
-- corners you picked; the server does all the building.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local folder = ReplicatedStorage:WaitForChild("AutoBuilder")
local Shared = require(folder:WaitForChild("Shared"))
local Action = folder:WaitForChild("Action")
local Update = folder:WaitForChild("Update")
local Query = folder:WaitForChild("Query")

local ORANGE = Color3.fromRGB(255, 140, 20)
local GRID = Shared.CONFIG.GRID
local ORIGIN = Shared.CONFIG.ORIGIN

local S = {
	pick = nil, -- nil | "A" | "B"
	a = nil, b = nil, hover = nil,
	info = { status = "idle", message = "READY" }, -- the last state the server told us
	message = "READY", -- the STATUS line
	kind = "info", -- "info" | "error" | "done" : its colour
	sticky = false, -- the message is a result (done / stopped / out of blocks): keep it until the player acts
}

----------------------------------------------------------------------------------------------
-- orange outline (exists only on this client, so it can never be mistaken for a block)
----------------------------------------------------------------------------------------------
local preview = Instance.new("Folder")
preview.Name = "AutoBuilderPreview"
preview.Parent = Workspace

local function outline(color, thickness, fill)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	part.Size = Vector3.new(GRID, GRID, GRID)
	part.Parent = preview
	local box = Instance.new("SelectionBox")
	box.Adornee = part
	box.Color3 = color
	box.SurfaceColor3 = color
	box.LineThickness = thickness
	box.SurfaceTransparency = fill
	box.Transparency = 0
	box.Parent = part
	return part, box
end
local areaPart, areaBox = outline(ORANGE, 0.08, 0.88)
local markPart, markBox = outline(Color3.fromRGB(255, 190, 70), 0.1, 0.6)
areaBox.Visible, markBox.Visible = false, false

local function lowCorner(c)
	return Vector3.new(ORIGIN.x + c.x * GRID, ORIGIN.y + c.y * GRID, ORIGIN.z + c.z * GRID)
end
local function showArea(mn, mx)
	if not mn then
		areaBox.Visible = false
		return
	end
	local lo, hi = lowCorner(mn), lowCorner({ x = mx.x + 1, y = mx.y + 1, z = mx.z + 1 })
	areaPart.Size = hi - lo
	areaPart.Position = (lo + hi) / 2
	areaBox.Visible = true
end
local function showMark(c)
	if not c then
		markBox.Visible = false
		return
	end
	markPart.Position = lowCorner(c) + Vector3.new(GRID, GRID, GRID) / 2
	markBox.Visible = true
end
local function bounds(a, b)
	return { x = math.min(a.x, b.x), y = math.min(a.y, b.y), z = math.min(a.z, b.z) },
		{ x = math.max(a.x, b.x), y = math.max(a.y, b.y), z = math.max(a.z, b.z) }
end

----------------------------------------------------------------------------------------------
-- the menu
----------------------------------------------------------------------------------------------
local W = 232
local gui = Instance.new("ScreenGui")
gui.Name = "AutoBuilder"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.Parent = player:WaitForChild("PlayerGui")

local window = Instance.new("Frame")
window.Name = "Window"
window.Size = UDim2.new(0, W, 0, 0)
window.AutomaticSize = Enum.AutomaticSize.Y
window.Position = UDim2.new(1, -W - 16, 0, 90)
window.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
window.BorderSizePixel = 0
window.Active = true
window.Parent = gui
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 12)
	c.Parent = window
	local st = Instance.new("UIStroke")
	st.Color, st.Thickness = ORANGE, 2
	st.Parent = window
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10), UDim.new(0, 8), UDim.new(0, 10)
	pad.Parent = window
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = window
end

local order = 0
local function label(text, height, bold)
	order = order + 1
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, height)
	l.Text = text
	l.TextColor3 = Color3.fromRGB(236, 236, 238)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = 12
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.RichText = true
	l.Parent = window
	return l
end
local function button(text, color, textColor)
	order = order + 1
	local b = Instance.new("TextButton")
	b.LayoutOrder = order
	b.Size = UDim2.new(1, 0, 0, 32)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Text = text
	b.TextColor3 = textColor
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.Parent = window
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = b
	return b
end

local title = label('<font color="#FF8C14">ABOVE[RUINS]</font> | AUTO BUILDER', 20, true)
local areaBtn = button("[ SELECT AREA ]", Color3.fromRGB(38, 38, 44), Color3.fromRGB(236, 236, 238))
local blockLbl = label("BLOCK: -", 20, true)
local needLbl = label("NEEDED: - | OWNED: -", 20, true)
local buildBtn = button("[ AUTO BUILD ]", ORANGE, Color3.fromRGB(18, 14, 8))
local stopBtn = button("[ STOP ]", Color3.fromRGB(150, 44, 40), Color3.fromRGB(255, 255, 255))

order = order + 1
local barBack = Instance.new("Frame")
barBack.LayoutOrder = order
barBack.Size = UDim2.new(1, 0, 0, 6)
barBack.BackgroundColor3 = Color3.fromRGB(38, 38, 44)
barBack.BorderSizePixel = 0
barBack.Parent = window
local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = ORANGE
barFill.BorderSizePixel = 0
barFill.Parent = barBack

local statusLbl = label("STATUS: READY", 16, false)
statusLbl.TextWrapped = true
statusLbl.AutomaticSize = Enum.AutomaticSize.Y
statusLbl.Size = UDim2.new(1, 0, 0, 16)
statusLbl.TextYAlignment = Enum.TextYAlignment.Top

-- drag the window by its title
do
	local dragging, startMouse, startPos
	title.Active = true
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging, startMouse, startPos = true, input.Position, window.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Position - startMouse
			window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

local function esc(s)
	return (string.gsub(tostring(s), "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function render()
	local info = S.info
	local building = info.status == "building"
	local hasArea = S.a ~= nil and S.b ~= nil and S.pick == nil

	areaBtn.Text = (S.pick == "A" and "[ CLICK CORNER A... ]") or (S.pick == "B" and "[ CLICK CORNER B... ]") or "[ SELECT AREA ]"
	blockLbl.Text = "BLOCK: " .. (info.name and esc(string.upper(info.name)) or '<font color="#F05248">NONE EQUIPPED</font>')

	local needed = info.needed
	local owned = info.owned
	local short = needed ~= nil and owned ~= nil and owned < needed
	needLbl.Text = string.format(
		'NEEDED: %s | OWNED: <font color="%s">%s</font>',
		needed ~= nil and tostring(needed) or "-", short and "#F05248" or "#58D67E", owned ~= nil and tostring(owned) or "-"
	)

	local placed, total = info.placed or 0, info.total or 0
	if building then
		buildBtn.Text = string.format("[ BUILDING  %d/%d ]", placed, total)
	elseif info.resumable and hasArea then
		buildBtn.Text = string.format("[ RESUME  %d/%d ]", placed, total)
	elseif info.status == "done" then
		buildBtn.Text = string.format("[ DONE  %d/%d ]", placed, total)
	else
		buildBtn.Text = "[ AUTO BUILD ]"
	end
	buildBtn.Active = hasArea and not building
	buildBtn.AutoButtonColor = buildBtn.Active
	buildBtn.BackgroundTransparency = buildBtn.Active and 0 or 0.55
	areaBtn.Active = not building
	areaBtn.BackgroundTransparency = building and 0.55 or 0
	stopBtn.BackgroundTransparency = (building or S.pick) and 0 or 0.55

	barFill.Size = UDim2.new(total > 0 and math.clamp(placed / total, 0, 1) or 0, 0, 1, 0)
	statusLbl.Text = "STATUS: " .. esc(S.message)
	statusLbl.TextColor3 = (S.kind == "error" and Color3.fromRGB(240, 82, 72))
		or (S.kind == "done" and Color3.fromRGB(88, 214, 126)) or Color3.fromRGB(200, 200, 205)
end

----------------------------------------------------------------------------------------------
-- picking the two corners (a plain mouse ray: nothing is moved, the camera is not touched)
----------------------------------------------------------------------------------------------
local function pickCell()
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local loc = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(loc.X, loc.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { preview }
	if player.Character then
		ignore[#ignore + 1] = player.Character
	end
	params.FilterDescendantsInstances = ignore
	local res = Workspace:Raycast(ray.Origin, ray.Direction * 4000, params)
	if not res then
		return nil
	end
	-- the empty cell in front of the surface you clicked
	local p = res.Position + res.Normal * (GRID / 2)
	return Shared.worldToCell(p.X, p.Y, p.Z)
end

local function setMessage(text, kind)
	S.message, S.kind = text, kind or "info"
	render()
end

local function stopPicking()
	S.pick, S.hover = nil, nil
	showMark(nil)
end

areaBtn.Activated:Connect(function()
	if S.info.status == "building" then
		return
	end
	S.a, S.b, S.hover = nil, nil, nil
	S.info = { status = "idle", code = "ready", message = "READY", name = S.info.name, owned = S.info.owned }
	S.sticky = false
	showArea(nil)
	showMark(nil)
	S.pick = "A"
	setMessage("Click the first corner (A). Tip: put your block away while choosing.")
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not S.pick or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	local cell = pickCell()
	if not cell then
		setMessage("Click a block or the ground.")
		return
	end
	if S.pick == "A" then
		S.a = cell
		S.pick = "B"
		showMark(cell)
		showArea(cell, cell)
		setMessage("Now click the opposite corner (B).")
	else
		S.b = cell
		local mn, mx, count = Shared.area(S.a, S.b)
		if not mn then
			S.a, S.b = nil, nil
			stopPicking()
			showArea(nil)
			setMessage(tostring(mx))
			return
		end
		stopPicking()
		showArea(mn, mx)
		setMessage(string.format("Area selected: %d x %d x %d (%d blocks). Equip your block and press AUTO BUILD.", mx.x - mn.x + 1, mx.y - mn.y + 1, mx.z - mn.z + 1, count))
	end
end)

-- live outline while you choose corner B
RunService.RenderStepped:Connect(function()
	if S.pick ~= "B" or not S.a then
		return
	end
	local cell = pickCell()
	if cell and (not S.hover or cell.x ~= S.hover.x or cell.y ~= S.hover.y or cell.z ~= S.hover.z) then
		S.hover = cell
		local mn, mx = bounds(S.a, cell)
		showArea(mn, mx)
	end
end)

----------------------------------------------------------------------------------------------
-- talking to the server
----------------------------------------------------------------------------------------------
buildBtn.Activated:Connect(function()
	if S.info.status == "building" or S.pick or not (S.a and S.b) then
		if not (S.a and S.b) and not S.pick then
			setMessage("Select an area first.")
		end
		return
	end
	S.sticky = false
	setMessage("Starting...")
	Action:FireServer("start", S.a, S.b)
end)

stopBtn.Activated:Connect(function()
	if S.pick then
		stopPicking()
		S.a, S.b = nil, nil
		showArea(nil)
		setMessage("Selection cancelled.")
	elseif S.info.status == "building" then
		Action:FireServer("stop")
		setMessage("Stopping...")
	end
end)

Update.OnClientEvent:Connect(function(state)
	if type(state) ~= "table" then
		return
	end
	S.info = state
	S.sticky = state.status ~= "building"
	S.message = tostring(state.message or "")
	if state.status == "done" then
		S.kind = "done"
		S.a, S.b = nil, nil -- finished: the outline goes away
		showArea(nil)
		showMark(nil)
	elseif state.status == "error" or (state.status == "paused" and state.code ~= "stopped") then
		S.kind = "error"
	else
		S.kind = "info"
	end
	render()
end)

-- ask the server what the selected area needs (also keeps BLOCK / OWNED fresh)
task.spawn(function()
	while true do
		if S.info.status ~= "building" and S.info.status ~= "done" and not S.pick then
			local ok, state = pcall(function()
				return Query:InvokeServer(S.a, S.b)
			end)
			if ok and type(state) == "table" and S.info.status ~= "building" and S.info.status ~= "done" and not S.pick then
				S.info = state
				if not S.sticky then
					S.message = tostring(state.message or "READY")
					S.kind = state.status == "error" and "error" or "info"
				end
			end
			render()
		end
		task.wait(0.7)
	end
end)

render()
]==])

print("[AutoBuilder] Installed 5 scripts. Press Play, then use the menu on the right.")
