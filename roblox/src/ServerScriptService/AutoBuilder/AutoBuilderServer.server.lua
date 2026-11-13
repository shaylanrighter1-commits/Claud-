--!nonstrict
--[[
	AutoBuilderServer — the authority for everything that matters.

	The client only ever sends two corner cells, a few option choices and a speed. This
	script ignores any block counts, ownership or world positions the client might claim
	and re-derives all of it:
	  * what the build contains          (BuildPlanner, from the two cells + options)
	  * whether the player owns the land  (Backend.isCellOwned, every cell, at quote time AND
	                                       again at the moment each block is placed)
	  * whether a cell is already filled  (Backend.isCellOccupied — existing blocks are never
	                                       overwritten, they are skipped and not charged)
	  * how many blocks it costs          (one per cell actually placed)
	  * inventory                         (Backend.takeBlocks BEFORE each placement, refunded
	                                       if the placement fails — blocks can't be duplicated)

	Remotes (all created here, in ReplicatedStorage/AutoBuilderRemotes):
	  GetInfo   RemoteFunction  client -> server   grid, materials, land, inventory, current job
	  Quote     RemoteFunction  client -> server   "what would this build cost?"
	  Start     RemoteFunction  client -> server   begin a build
	  Control   RemoteFunction  client -> server   "pause" | "resume" | "cancel"
	  JobUpdate RemoteEvent     server -> client   progress snapshots
	  Inventory RemoteEvent     server -> client   { [materialId] = count } whenever it changes
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("AutoBuilder")
local Config = require(Shared:WaitForChild("Config"))
local Planner = require(Shared:WaitForChild("BuildPlanner"))

-- To run the Auto Builder inside another game, replace this one line with a module that
-- implements the same functions (the full list is documented at the top of that file).
local Backend = require(script.Parent:WaitForChild("StandaloneBackend"))

local LIMITS = {
	maxBlocks = Config.MAX_BLOCKS_PER_JOB,
	maxDimension = Config.MAX_DIMENSION,
	maxHeight = Config.MAX_HEIGHT,
	maxThickness = Config.MAX_THICKNESS,
}

----------------------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------------------
local remotesFolder = Instance.new("Folder")
remotesFolder.Name = Config.REMOTES_FOLDER
local function newRemote(className, name)
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end
local GetInfo = newRemote("RemoteFunction", "GetInfo")
local Quote = newRemote("RemoteFunction", "Quote")
local Start = newRemote("RemoteFunction", "Start")
local Control = newRemote("RemoteFunction", "Control")
local JobUpdate = newRemote("RemoteEvent", "JobUpdate")
local InventoryUpdate = newRemote("RemoteEvent", "Inventory")

----------------------------------------------------------------------------------
-- Per-player session state
----------------------------------------------------------------------------------
local sessions = {} -- [Player] = { job, busy, buckets, lastCounts }

local function getSession(player)
	local session = sessions[player]
	if not session then
		session = { job = nil, busy = false, buckets = {}, lastCounts = {} }
		sessions[player] = session
	end
	return session
end

-- Token-bucket rate limiter so a client can't flood the server with requests.
local function allow(session, key, perSecond, burst)
	local now = os.clock()
	local bucket = session.buckets[key]
	if not bucket then
		bucket = { tokens = burst, last = now }
		session.buckets[key] = bucket
	end
	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.last) * perSecond)
	bucket.last = now
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

local function fail(code, extra)
	local result = { ok = false, code = code, message = Config.message(code) }
	if extra then
		for k, v in pairs(extra) do
			result[k] = v
		end
	end
	return result
end

----------------------------------------------------------------------------------
-- Input validation: nothing from the client is trusted
----------------------------------------------------------------------------------
local function parseCell(v)
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local x, y, z = v.X, v.Y, v.Z
	for _, n in ipairs({ x, y, z }) do
		if n ~= n or math.abs(n) > Planner.COORD_LIMIT or n % 1 ~= 0 then
			return nil
		end
	end
	return { x = x, y = y, z = z }
end

local function materialsById()
	local map = {}
	for _, m in ipairs(Backend.getMaterials()) do
		map[m.id] = m
	end
	return map
end

local function parseOptions(raw, materials)
	if type(raw) ~= "table" then
		return nil
	end
	local mode = raw.mode
	if type(mode) ~= "string" or not Planner.MODES[mode] then
		return nil
	end
	local materialId = raw.material
	if type(materialId) ~= "string" or not materials[materialId] then
		return nil
	end
	return {
		mode = mode,
		material = materialId,
		layout = (raw.layout == "surround") and "surround" or "straight",
		height = Planner.clampInt(raw.height, 1, Config.MAX_HEIGHT, 1),
		thickness = Planner.clampInt(raw.thickness, 1, Config.MAX_THICKNESS, 1),
	}
end

local function inventoryCounts(player)
	local counts = {}
	for _, m in ipairs(Backend.getMaterials()) do
		counts[m.id] = Backend.getBlockCount(player, m.id)
	end
	return counts
end

local function planInsideWorld(plan)
	local grid = Backend.getGrid()
	local s, o = grid.size, grid.origin
	local lim = Config.WORLD_MAX_ABS_STUDS
	local minX, maxX = o.X + plan.min.x * s, o.X + (plan.max.x + 1) * s
	local minZ, maxZ = o.Z + plan.min.z * s, o.Z + (plan.max.z + 1) * s
	local minY, maxY = o.Y + plan.min.y * s, o.Y + (plan.max.y + 1) * s
	if math.abs(minX) > lim or math.abs(maxX) > lim or math.abs(minZ) > lim or math.abs(maxZ) > lim then
		return false
	end
	return minY >= workspace.FallenPartsDestroyHeight + 8 and maxY <= Config.WORLD_MAX_Y_STUDS
end

--[[
	Full server-side evaluation of a build request. Returns either
	  { ok = false, code, message }
	or
	  { ok = true, plan, opts, material, toPlace, occupied, available }
]]
local function evaluate(player, rawA, rawB, rawOptions)
	local materials = materialsById()
	local a, b = parseCell(rawA), parseCell(rawB)
	local opts = parseOptions(rawOptions, materials)
	if not (a and b and opts) then
		return fail("BAD_REQUEST")
	end

	local allowed, reason = Backend.canUse(player)
	if not allowed then
		local result = fail("NOT_ALLOWED")
		if type(reason) == "string" then
			result.message = reason
		end
		return result
	end
	if not Backend.getPlot(player) then
		return fail("NO_PLOT")
	end

	local plan, code = Planner.plan(a, b, opts, LIMITS)
	if not plan then
		return fail(code or "BAD_REQUEST")
	end
	if not planInsideWorld(plan) then
		return fail("OUTSIDE_WORLD")
	end

	-- Cheap O(1) early-out: a plan outside the land's bounding box can't be owned, so don't
	-- walk up to 20,000 cells just to find that out. (The per-cell check below stays
	-- authoritative, which is what makes odd-shaped land safe.)
	local plot = Backend.getPlot(player)
	if
		not plot
		or not Planner.planInside(
			plan,
			{ x = plot.min.X, y = plot.min.Y, z = plot.min.Z },
			{ x = plot.max.X, y = plot.max.Y, z = plot.max.Z }
		)
	then
		return fail("OUTSIDE_LAND")
	end

	local unowned, occupied, toPlace = 0, 0, 0
	Planner.forEachCell(plan, function(x, y, z)
		local cell = Vector3.new(x, y, z)
		if not Backend.isCellOwned(player, cell) then
			unowned += 1
		elseif Backend.isCellOccupied(cell) then
			occupied += 1
		else
			toPlace += 1
		end
	end)
	if unowned > 0 then
		return fail("OUTSIDE_LAND")
	end

	local material = materials[opts.material]
	return {
		ok = true,
		plan = plan,
		opts = opts,
		material = material,
		toPlace = toPlace,
		occupied = occupied,
		available = Backend.getBlockCount(player, opts.material),
	}
end

----------------------------------------------------------------------------------
-- Jobs
----------------------------------------------------------------------------------
local function snapshot(job)
	local remaining = math.max(0, job.total - job.placed)
	return {
		state = job.state, -- building | paused | done | cancelled | failed
		reason = job.reason, -- for paused: "user" | "resources"
		code = job.code,
		message = job.message,
		label = job.label,
		mode = job.mode,
		materialId = job.materialId,
		materialName = job.materialName,
		placed = job.placed,
		total = job.total,
		skipped = job.skipped,
		remaining = remaining,
		progress = job.total > 0 and (job.placed / job.total) or 1,
		speed = job.speed,
	}
end

local function sendUpdate(job, force)
	if job.silent then
		return
	end
	local now = os.clock()
	if force or now - job.lastSent >= Config.JOB_UPDATE_INTERVAL then
		job.lastSent = now
		job.dirty = false
		JobUpdate:FireClient(job.player, snapshot(job))
	else
		job.dirty = true
	end
end

local function finishJob(job, state, code, silent)
	if job.finished then
		return
	end
	job.finished = true
	job.state = state
	job.reason = nil
	job.code = code
	job.message = code and Config.message(code) or nil
	job.silent = silent
	local session = sessions[job.player]
	if session and session.job == job then
		session.job = nil
	end
	sendUpdate(job, true)
end

local function pauseJob(job, reason)
	job.state = "paused"
	job.reason = reason
	job.budget = 0
	if reason == "resources" then
		local available = Backend.getBlockCount(job.player, job.materialId)
		local missing = math.max(1, job.total - job.placed - available)
		job.code = "NOT_ENOUGH_RESOURCES"
		job.message = Config.missingMessage(missing, job.materialName)
	else
		job.code, job.message = nil, nil
	end
	sendUpdate(job, true)
end

-- Places the next block of the job. Cells that became occupied in the meantime are skipped
-- (and not charged). Returns when one block was placed, or the job stopped/finished.
local function placeOne(job)
	local player, order = job.player, job.order
	while job.state == "building" do
		local i = job.index
		if i > order.n then
			finishJob(job, "done")
			return
		end
		local cell = Vector3.new(order.xs[i], order.ys[i], order.zs[i])

		if not Backend.isCellOwned(player, cell) then
			finishJob(job, "failed", "LAND_CHANGED")
			return
		end

		if Backend.isCellOccupied(cell) then
			job.skipped += 1
			job.total -= 1
			job.index = i + 1
			job.dirty = true -- progress changed: the Heartbeat flush sends it (throttled)
		else
			-- 1) take the block from the inventory first...
			if not Backend.takeBlocks(player, job.materialId, 1) then
				pauseJob(job, "resources")
				return
			end
			-- 2) ...then place it. If placing fails the block is handed back.
			local ok, result = pcall(Backend.placeBlock, player, job.materialId, cell)
			job.index = i + 1
			if ok and result == true then
				job.placed += 1
				job.dirty = true
				job.consecutiveFailures = 0
				if job.index > order.n then
					finishJob(job, "done")
				end
				return
			end
			pcall(Backend.giveBlocks, player, job.materialId, 1)
			if not ok then
				warn("[AutoBuilder] placeBlock error: " .. tostring(result))
			end
			job.skipped += 1
			job.total -= 1
			job.dirty = true
			job.consecutiveFailures += 1
			if job.consecutiveFailures >= 5 then
				finishJob(job, "failed", "PLACE_FAILED")
				return
			end
		end
	end
end

local function countRemaining(job)
	local order = job.order
	local n = 0
	for i = job.index, order.n do
		if not Backend.isCellOccupied(Vector3.new(order.xs[i], order.ys[i], order.zs[i])) then
			n += 1
		end
	end
	return n
end

RunService.Heartbeat:Connect(function(dt)
	for _, session in pairs(sessions) do
		local job = session.job
		if job then
			if job.state == "building" and not job.stepping then
				job.stepping = true
				local ok, err = xpcall(function()
					job.budget = math.min(job.budget + dt * job.speed, Config.MAX_PLACEMENTS_PER_FRAME)
					while job.budget >= 1 and job.state == "building" do
						job.budget -= 1
						placeOne(job)
					end
				end, debug.traceback)
				job.stepping = false
				if not ok then
					warn("[AutoBuilder] build step failed: " .. tostring(err))
					finishJob(job, "failed", "SERVER_ERROR")
				end
			end
			if job.dirty and not job.finished then
				sendUpdate(job, false)
			end
		end
	end
end)

----------------------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------------------
local function handleGetInfo(player)
	local session = getSession(player)
	local allowed, reason = Backend.canUse(player)
	local grid = Backend.getGrid()
	local plot = Backend.getPlot(player)
	return {
		ok = true,
		allowed = allowed and true or false,
		reason = reason,
		grid = { size = grid.size, origin = grid.origin },
		materials = Backend.getMaterials(),
		plot = plot and { min = plot.min, max = plot.max } or nil,
		inventory = inventoryCounts(player),
		job = session.job and snapshot(session.job) or nil,
		limits = LIMITS,
		speed = { min = Config.MIN_SPEED, max = Config.MAX_SPEED, default = Config.DEFAULT_SPEED },
		selectAdjacent = Config.SELECT_ADJACENT_CELL,
	}
end

local function handleQuote(player, rawA, rawB, rawOptions)
	local session = getSession(player)
	if not allow(session, "quote", 8, 12) then
		return fail("RATE_LIMITED")
	end
	local r = evaluate(player, rawA, rawB, rawOptions)
	if not r.ok then
		return { ok = false, code = r.code, message = r.message }
	end
	local missing = math.max(0, r.toPlace - r.available)
	local result = {
		ok = true,
		total = r.plan.count,
		toPlace = r.toPlace,
		occupied = r.occupied,
		required = r.toPlace,
		available = r.available,
		missing = missing,
		materialId = r.opts.material,
		materialName = r.material.name,
		label = Config.buildLabel(r.material.name, r.opts.mode),
		canStart = r.toPlace > 0 and missing == 0,
	}
	if r.toPlace == 0 then
		result.code = "NOTHING_TO_BUILD"
		result.message = Config.message("NOTHING_TO_BUILD")
	end
	return result
end

local function startJob(player, session, rawA, rawB, rawOptions, rawSpeed)
	local r = evaluate(player, rawA, rawB, rawOptions)
	if not r.ok then
		return r
	end
	if session.job then
		return fail("BUSY") -- someone else started one while we were validating
	end
	if r.toPlace == 0 then
		return fail("NOTHING_TO_BUILD")
	end
	local available = Backend.getBlockCount(player, r.opts.material)
	if available < r.toPlace then
		local missing = r.toPlace - available
		return {
			ok = false,
			code = "NOT_ENOUGH_RESOURCES",
			missing = missing,
			message = Config.missingMessage(missing, r.material.name),
		}
	end

	local speed = Config.DEFAULT_SPEED
	if type(rawSpeed) == "number" and rawSpeed == rawSpeed then
		speed = math.clamp(rawSpeed, Config.MIN_SPEED, Config.MAX_SPEED)
	end

	local job = {
		player = player,
		state = "building",
		order = Planner.buildOrder(r.plan),
		index = 1,
		materialId = r.opts.material,
		materialName = r.material.name,
		mode = r.opts.mode,
		label = Config.buildLabel(r.material.name, r.opts.mode),
		placed = 0,
		skipped = 0,
		total = r.toPlace,
		speed = speed,
		budget = 0,
		stepping = false,
		consecutiveFailures = 0,
		lastSent = 0,
		dirty = false,
		finished = false,
	}
	session.job = job
	sendUpdate(job, true)
	return { ok = true, job = snapshot(job) }
end

local function handleStart(player, rawA, rawB, rawOptions, rawSpeed)
	local session = getSession(player)
	if not allow(session, "start", 1, 2) then
		return fail("RATE_LIMITED")
	end
	-- `busy` also blocks a second Start while this one is still validating (adapters may yield).
	if session.job or session.busy then
		return fail("BUSY")
	end
	session.busy = true
	local ok, result = xpcall(startJob, debug.traceback, player, session, rawA, rawB, rawOptions, rawSpeed)
	session.busy = false
	if not ok then
		warn("[AutoBuilder] Start failed: " .. tostring(result))
		return fail("SERVER_ERROR")
	end
	return result
end

local function handleControl(player, action)
	if type(action) ~= "string" then
		return fail("BAD_REQUEST")
	end
	local session = getSession(player)
	if not allow(session, "control", 4, 6) then
		return fail("RATE_LIMITED")
	end
	local job = session.job
	if not job then
		return fail("NO_JOB")
	end

	if action == "pause" then
		if job.state == "building" then
			pauseJob(job, "user")
		end
		return { ok = true }
	elseif action == "resume" then
		if job.state ~= "paused" then
			return { ok = true }
		end
		local needed = countRemaining(job)
		local available = Backend.getBlockCount(player, job.materialId)
		if available < needed then
			local missing = needed - available
			return {
				ok = false,
				code = "NOT_ENOUGH_RESOURCES",
				missing = missing,
				message = Config.missingMessage(missing, job.materialName),
			}
		end
		job.state = "building"
		job.reason, job.code, job.message = nil, nil, nil
		job.budget = 0
		sendUpdate(job, true)
		return { ok = true }
	elseif action == "cancel" then
		-- Blocks are only taken one-by-one as they're placed, so nothing is held back:
		-- whatever hasn't been placed is simply still in the player's inventory.
		finishJob(job, "cancelled")
		return { ok = true }
	end
	return fail("BAD_REQUEST")
end

local function guarded(name, handler)
	return function(player, ...)
		local ok, result = xpcall(handler, debug.traceback, player, ...)
		if ok then
			return result
		end
		warn(string.format("[AutoBuilder] %s failed: %s", name, tostring(result)))
		return fail("SERVER_ERROR")
	end
end

GetInfo.OnServerInvoke = guarded("GetInfo", handleGetInfo)
Quote.OnServerInvoke = guarded("Quote", handleQuote)
Start.OnServerInvoke = guarded("Start", handleStart)
Control.OnServerInvoke = guarded("Control", handleControl)

----------------------------------------------------------------------------------
-- Live inventory: push counts to each client whenever they change, so the
-- "Available / Missing" numbers update as blocks are collected (or spent).
----------------------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(Config.INVENTORY_POLL_SECONDS)
		for _, player in ipairs(Players:GetPlayers()) do
			local session = sessions[player]
			if session then
				local ok, counts = pcall(inventoryCounts, player)
				if ok then
					local changed = false
					for id, n in pairs(counts) do
						if session.lastCounts[id] ~= n then
							changed = true
							break
						end
					end
					if changed then
						session.lastCounts = counts
						InventoryUpdate:FireClient(player, counts)
					end
				end
			end
		end
	end
end)

----------------------------------------------------------------------------------
-- Player lifecycle
----------------------------------------------------------------------------------
local function onPlayerAdded(player)
	getSession(player)
	local ok, err = pcall(Backend.onPlayerAdded, player)
	if not ok then
		warn("[AutoBuilder] Backend.onPlayerAdded failed: " .. tostring(err))
	end
end

Players.PlayerRemoving:Connect(function(player)
	local session = sessions[player]
	if session and session.job then
		finishJob(session.job, "cancelled", nil, true)
	end
	sessions[player] = nil
	local ok, err = pcall(Backend.onPlayerRemoving, player)
	if not ok then
		warn("[AutoBuilder] Backend.onPlayerRemoving failed: " .. tostring(err))
	end
end)

Backend.init()
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Publish the remotes last, so clients never see a half-built folder.
remotesFolder.Parent = ReplicatedStorage
print("[AutoBuilder] Server ready.")
