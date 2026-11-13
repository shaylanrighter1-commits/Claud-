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
