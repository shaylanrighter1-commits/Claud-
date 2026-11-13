--[[
	ABOVE[RUINS] | AUTO BUILDER   (single script for MacSploit)

	HOW TO USE  (walk-around, flat floor)
	  1. Join the game and paste this whole file into MacSploit and Execute. A small menu appears.
	  2. [ SELECT AREA ] -> click corner A, then the opposite corner B. The area is ONE flat layer (the height of
	     corner A - no stacking). Both corners snap to the game's block grid and an orange outline shows the area.
	  3. Select your block in the hotbar (press its number). The menu shows what it detected, NEEDED and OWNED.
	  4. [ AUTO PLACE ]. Now YOU walk around the area (first person is fine) and look at the floor: whenever your
	     crosshair points at a spot of the area that has no block yet, one block is placed there for you. Spots that
	     are already filled are skipped, nothing is placed outside the outline. The same button says [ STOP ] while
	     it runs and [ RESUME ] after a stop. [ CLEAR SELECTION ] forgets the area.
	  RightShift hides / shows the menu.

	WHAT IT DOES NOT DO
	  It never walks, jumps or teleports your character and never moves your camera or your mouse: you walk, you
	  look, it only clicks where your crosshair already points. It is not instant and not remote: the game's server
	  checks the distance and your inventory for every click, so spots out of reach are simply left until you are
	  close enough. It never calls the game's remotes, never touches your inventory, never creates fake or
	  local-only blocks, and never gets around the server's building rules.

	HOW IT FINDS YOUR BLOCK
	  Your hotbar is custom (not Roblox Tool objects), so the script reads the hotbar GUI itself: it finds
	  the numbered slots, reads each slot's item name and "x25" count, and takes the slot the game
	  highlights as selected (yellow outline / background). Standard Tools in hand are used if present.

	HOW IT PLACES BLOCKS
	  Roughly every tenth of a second it looks at what your crosshair points at and works out which grid cell the
	  game would put a block into. If that cell is an empty cell of the area it checks, a moment later, that you
	  are still pointing at it, compares it with the game's own placement preview (when readable), and clicks -
	  exactly what you would do - so the game's building code (range, ownership, inventory, cooldown) decides
	  whether the block is placed. After each click it checks that exactly one new real block appeared in exactly
	  that cell; only then is it counted. A block that lands outside the area stops the build.
	  Failures are labelled: [ITEM] [INPUT] [AIM] [RANGE] [PLACEMENT] [DETECTION].

	NOTE: running scripts through an executor is against Roblox's Terms of Use and can get an account
	banned, and automated clicking may also break the game's own rules. Use at your own risk.
]]

local VERSION = "v6 walk-around auto place"

----------------------------------------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------------------------------------
local CONFIG = {
	DEBUG = true, -- print [AutoBuilder] lines to the console (F9) as well
	CONTAINER = "auto", -- "auto" | "gethui" | "coregui" | "playergui"  (where the menu is parented)
	TOGGLE_KEY = Enum.KeyCode.RightShift,

	SELECT_ADJACENT = true, -- clicking the ground selects the empty cell above it
	FLAT_ONLY = true, -- the area is ONE layer: point B takes point A's height (no stacking)
	MAX_CELLS = 5000, -- biggest area allowed
	DEFAULT_GRID = 4, -- studs per block, used only if the grid can't be detected

	PLACE_DELAY = 0.08, -- pause after each block (seconds); every block is still verified before the next one
	PLACE_TIMEOUT = 1.6, -- how long to wait for a block to appear after a click
	MAX_FAILS = 6, -- this many clicks in a row that reached the game and placed nothing stops the build
	MAX_STRAYS = 5, -- blocks that landed in a neighbouring cell INSIDE the area are tolerated this many times per
	-- build (that cell is tried again). Outside the area it always stops.

	OCC_MIN_FRACTION = 0.45, -- a part counts as a "block" if every side >= this * grid size ...
	OCC_MAX_MULT = 2.01, -- ... and no side is longer than this * grid size
}

----------------------------------------------------------------------------------------------
-- 1. Single-instance guard + logging
----------------------------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if genv.__ARB_AUTOBUILDER then
	pcall(function()
		genv.__ARB_AUTOBUILDER.destroy()
	end)
end
local ARB = { alive = true, conns = {}, destroyers = {} }
genv.__ARB_AUTOBUILDER = ARB

function ARB.destroy()
	ARB.alive = false
	for _, fn in ipairs(ARB.destroyers) do
		pcall(fn)
	end
	ARB.destroyers = {}
	for _, c in ipairs(ARB.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	ARB.conns = {}
end
local function keep(conn)
	ARB.conns[#ARB.conns + 1] = conn
	return conn
end
local function onDestroy(fn)
	ARB.destroyers[#ARB.destroyers + 1] = fn
end

local LOG = { lines = {}, max = 200 }
local function log(level, ...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local line = string.format("[%s] %s", level, table.concat(parts, " "))
	LOG.lines[#LOG.lines + 1] = line
	if #LOG.lines > LOG.max then
		table.remove(LOG.lines, 1)
	end
	if level == "ERROR" or level == "WARN" then
		warn("[AutoBuilder] " .. line)
	elseif CONFIG.DEBUG then
		print("[AutoBuilder] " .. line)
	end
end

local seenErrors = {}
local function safe(label, fn, ...)
	local ok, err = xpcall(fn, function(e)
		return tostring(e) .. " | " .. string.sub(tostring(debug.traceback()), 1, 300)
	end, ...)
	if not ok then
		local key = label .. tostring(err)
		if not seenErrors[key] then
			seenErrors[key] = true
			log("ERROR", label .. " failed: " .. string.sub(tostring(err), 1, 500))
		end
	end
	return ok
end

log("INFO", "script started")

----------------------------------------------------------------------------------------------
-- 1b. CORE LOGIC - plain Lua, no Roblox API at all.
--     Everything that decides WHAT to build, in WHAT order, whether a block that appeared is the RIGHT
--     block, what gets COUNTED, and WHEN to stop lives in this block, so it can be tested outside Roblox.
--     roblox/tests/run_core_tests.py extracts and runs exactly the text between CORE-BEGIN and CORE-END.
--     (Keep it to the subset that both Lua and Luau accept: no +=, no continue, no type annotations.)
----------------------------------------------------------------------------------------------
-- CORE-BEGIN
local Core = {}

function Core.cellKey(c)
	return string.format("%d,%d,%d", c.x, c.y, c.z)
end

function Core.sameCell(a, b)
	return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z
end

function Core.inBounds(c, mn, mx)
	return c.x >= mn.x and c.x <= mx.x and c.y >= mn.y and c.y <= mx.y and c.z >= mn.z and c.z <= mx.z
end

-- the grid cell containing world point p, on the lattice (origin, size)
function Core.worldToCell(p, origin, size)
	return {
		x = math.floor((p.x - origin.x) / size),
		y = math.floor((p.y - origin.y) / size),
		z = math.floor((p.z - origin.z) / size),
	}
end

function Core.dist3(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ONE fixed order. Layers bottom first; then rows along `rowAxis` ("x" or "z"; `descending` flips only the
-- order of the rows); inside every row the other axis always runs in the same (ascending) direction.
function Core.buildOrder(mn, mx, rowAxis, descending)
	local xs, ys, zs, n = {}, {}, {}, 0
	local function emit(x, y, z)
		n = n + 1
		xs[n], ys[n], zs[n] = x, y, z
	end
	for y = mn.y, mx.y do
		if rowAxis == "x" then
			local a, b, step = mn.x, mx.x, 1
			if descending then
				a, b, step = mx.x, mn.x, -1
			end
			for x = a, b, step do
				for z = mn.z, mx.z do
					emit(x, y, z)
				end
			end
		else
			local a, b, step = mn.z, mx.z, 1
			if descending then
				a, b, step = mx.z, mn.z, -1
			end
			for z = a, b, step do
				for x = mn.x, mx.x do
					emit(x, y, z)
				end
			end
		end
	end
	return { n = n, xs = xs, ys = ys, zs = zs }
end

-- After a click: is the block that appeared the RIGHT block, in the RIGHT place?
--   fresh  list of {x,y,z}: centers of NEW, opaque, block-sized parts that appeared near the click
--   ctx    { cell, center, size, origin, first, min, max }
--          first = this is the first block of the job (a small grid offset may be adopted once)
-- returns { kind = "none" }
--      or { kind = "placed", adopt = {x,y,z} | nil, offset = number }
--      or { kind = "misplaced", why = "elsewhere" | "extra" | "cell", landed = cell, outside = bool }
function Core.classifyFresh(fresh, ctx)
	if #fresh == 0 then
		return { kind = "none" }
	end
	local s, c = ctx.size, ctx.center
	local tol = ctx.first and 0.45 or 0.2 -- how far from the cell centre a block may sit (in blocks)
	local match, matchOff
	for _, p in ipairs(fresh) do
		local cheb = math.max(math.abs(p.x - c.x), math.abs(p.y - c.y), math.abs(p.z - c.z))
		if cheb <= s * tol and (matchOff == nil or cheb < matchOff) then
			match, matchOff = p, cheb
		end
	end
	if not match then
		local landed = Core.worldToCell(fresh[1], ctx.origin, s)
		return { kind = "misplaced", why = "elsewhere", landed = landed, outside = not Core.inBounds(landed, ctx.min, ctx.max) }
	end
	for _, p in ipairs(fresh) do
		if p ~= match and Core.dist3(p, match) > s * 0.45 then
			local landed = Core.worldToCell(p, ctx.origin, s)
			return { kind = "misplaced", why = "extra", landed = landed, outside = not Core.inBounds(landed, ctx.min, ctx.max) }
		end
	end
	local origin, adopt = ctx.origin, nil
	if ctx.first and matchOff > s * 0.05 then
		adopt = { x = match.x - c.x, y = match.y - c.y, z = match.z - c.z }
		origin = { x = origin.x + adopt.x, y = origin.y + adopt.y, z = origin.z + adopt.z }
	end
	local landed = Core.worldToCell(match, origin, s)
	if not Core.sameCell(landed, ctx.cell) then
		return { kind = "misplaced", why = "cell", landed = landed, outside = not Core.inBounds(landed, ctx.min, ctx.max) }
	end
	return { kind = "placed", adopt = adopt, offset = matchOff }
end

-- Where does the game's lattice sit? `list` = one axis' offsets of nearby blocks' corners, each in [0, size).
-- Most common value (buckets of size/20, wrapping around 0), and the fraction of blocks that agree.
function Core.consensus(list, size)
	local buckets = {}
	for _, r in ipairs(list) do
		local k = math.floor(r / (size / 20) + 0.5) % 20
		local b = buckets[k]
		if not b then
			b = { sum = 0, n = 0 }
			buckets[k] = b
		end
		if k == 0 and r > size / 2 then
			b.sum = b.sum + (r - size) -- just under `size` is really just under zero
		else
			b.sum = b.sum + r
		end
		b.n = b.n + 1
	end
	local best
	for _, b in pairs(buckets) do
		if not best or b.n > best.n then
			best = b
		end
	end
	if not best then
		return nil, 0
	end
	return ((best.sum / best.n) % size + size) % size, best.n / #list
end

-- Placement distance, learned from what the game accepts and refuses.
--   reach.okMax   farthest distance at which a block was really placed
--   reach.failMin nearest distance at which the game refused a placement that looked like a range refusal
function Core.newReach()
	return { okMax = 0, failMin = nil }
end
function Core.looksOutOfRange(reach, dist)
	return dist > math.max(reach.okMax + 2.5, 14)
end
function Core.reachBlocked(reach, dist)
	return reach.failMin ~= nil and dist >= reach.failMin - 0.5
end

-- WALK MODE. The player walks and looks around; whenever the cursor (in first person: the crosshair) points at
-- a face that would put a block into an EMPTY cell of the selected flat area, one block is placed there.
-- Everything that decides whether to try, what to count and when to stop is here, and unit-tested.
-- job = { mn, mx, placed, total, placedSet, reach, tried, fails, strays, mismatches }

function Core.newWalk(mn, mx)
	return {
		mn = mn, mx = mx, placed = 0, total = 0, placedSet = {}, reach = Core.newReach(),
		tried = {}, fails = 0, strays = 0, mismatches = 0,
	}
end

-- Look at the area: how many cells still need a block? total = placed so far + still empty.
-- env.occupied(cell) -> bool, env.tick(i) -> true if the player pressed STOP.  Returns false if stopped.
function Core.walkPlan(job, env)
	local empty, i = 0, 0
	for y = job.mn.y, job.mx.y do
		for z = job.mn.z, job.mx.z do
			for x = job.mn.x, job.mx.x do
				i = i + 1
				local cell = { x = x, y = y, z = z }
				if not job.placedSet[Core.cellKey(cell)] and not env.occupied(cell) then
					empty = empty + 1
				end
				if env.tick(i) then
					return false
				end
			end
		end
	end
	job.total = job.placed + empty
	return true
end

-- May a block be tried in `cell` right now?  dist = studs from the player to the cell, now = seconds.
-- cfg = { retryDelay, closerBy }.  Returns true, or false + why.
function Core.walkAllow(job, cell, dist, now, cfg)
	if not Core.inBounds(cell, job.mn, job.mx) then
		return false, "outside"
	end
	local k = Core.cellKey(cell)
	if job.placedSet[k] then
		return false, "done"
	end
	if job.placed >= job.total then
		return false, "complete"
	end
	if Core.reachBlocked(job.reach, dist) then
		return false, "range"
	end
	local t = job.tried[k]
	if t and now - t.t < cfg.retryDelay and dist > t.dist - cfg.closerBy then
		return false, "wait" -- just tried here: try again after a moment, or once the player is closer
	end
	return true
end

-- Record what happened after a click.  result:
--   "placed"    a block was SEEN appearing in exactly this cell (the only thing that is ever counted)
--   "failed"    the click reached the game and nothing appeared
--   "stray"     a block appeared in ANOTHER cell inside the area
--   "mismatch"  the game's own placement preview pointed at a different cell, so no click was sent
--   "skip"      nothing was sent (the cursor moved)
--   anything else ("misplaced", "broke", "unseen", "noblocks", "nocursor", ...) stops the job
-- Returns "continue", or "stop", code, extra.
function Core.walkResult(job, cell, dist, now, result, extra, cfg)
	local k = Core.cellKey(cell)
	local reach = job.reach
	if result == "placed" then
		if not job.placedSet[k] then
			job.placed = job.placed + 1
			job.placedSet[k] = true
			if job.placed > job.total then
				job.total = job.placed -- (a cell counted as filled by somebody else was empty after all)
			end
		end
		job.fails, job.mismatches = 0, 0
		job.tried[k] = nil
		if dist > reach.okMax then
			reach.okMax = dist
		end
		if reach.failMin ~= nil and dist >= reach.failMin then
			reach.failMin = nil -- it worked from there after all: my range guess was wrong
		end
		return "continue"
	elseif result == "failed" then
		job.tried[k] = { t = now, dist = dist }
		if Core.looksOutOfRange(reach, dist) then
			if reach.failMin == nil or dist < reach.failMin then
				reach.failMin = dist -- looks like the placement distance: stop trying cells this far away
			end
		else
			job.fails = job.fails + 1
			if job.fails >= cfg.maxFails then
				return "stop", "failed", { why = extra }
			end
		end
		return "continue"
	elseif result == "stray" then
		job.tried[k] = { t = now, dist = dist }
		job.strays = job.strays + 1
		if job.strays > cfg.maxStrays then
			return "stop", "misplaced", extra
		end
		return "continue"
	elseif result == "mismatch" then
		job.tried[k] = { t = now, dist = dist }
		job.mismatches = job.mismatches + 1
		if job.mismatches > cfg.maxMismatches then
			return "stop", "mismatch", extra
		end
		return "continue"
	elseif result == "skip" then
		return "continue"
	end
	return "stop", result, extra
end

-- CORE-END

----------------------------------------------------------------------------------------------
-- 2. Services
----------------------------------------------------------------------------------------------
if not game:IsLoaded() then
	game.Loaded:Wait()
end
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CAS = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait(0.1)
	LocalPlayer = Players.LocalPlayer
end
do
	local okName, name, ver = pcall(function()
		if identifyexecutor then
			return identifyexecutor()
		end
	end)
	log("INFO", "executor:", okName and name and (tostring(name) .. " " .. tostring(ver or "")) or "unknown")
end

----------------------------------------------------------------------------------------------
-- 3. State
----------------------------------------------------------------------------------------------
local ORANGE = Color3.fromRGB(255, 140, 20)
local ORANGE_HI = Color3.fromRGB(255, 176, 48)

local S = {
	grid = { size = CONFIG.DEFAULT_GRID, origin = Vector3.new(0, 0, 0), confirmed = false },
	pick = nil, -- "A" | "B" | nil : what the next world click sets
	a = nil, -- cells are plain tables {x=,y=,z=}
	b = nil,
	hover = nil,
	min = nil, -- selection bounds (cells)
	max = nil,
	count = 0, -- cells in the selection
	order = nil, -- build order {n, xs, ys, zs}
	tooLarge = false,
	block = nil, -- { name = "Grass Block", tool = Tool | nil }
	manualOwned = nil, -- number typed into BLOCKS OWNED (nil = read it from the game)
	manualAt = 0, -- placedAll when manualOwned was typed
	needed = nil, -- empty cells left in the selection (nil = still counting)
	state = "idle", -- idle | building | done
	stoppedRun = nil, -- runId of the build the STOP button ended
	job = nil, -- the build in progress / stopped and resumable: { order, placed, total, placedSet, reach, todo, resumable }
	runId = 0,
	placed = 0,
	total = 0,
	placedAll = 0, -- blocks placed since the script started (for the manual-count estimate)
	status = "Press SELECT AREA to begin.",
	statusKind = "info",
}
onDestroy(function()
	S.runId += 1
	S.state = "idle"
end)

local UI = { ready = false }
local render -- assigned when the menu is built
render = function() end

local function status(text, kind)
	S.areaNote = false -- (any new message replaces the "N to fill, M already filled" note)
	S.status, S.statusKind = text, kind or "info"
	log(kind == "error" and "WARN" or "INFO", text)
	render()
end

local function fmt(n)
	local s = string.reverse(tostring(math.floor(n + 0.5)))
	s = string.gsub(s, "(%d%d%d)", "%1,")
	s = string.reverse(s)
	if string.sub(s, 1, 1) == "," then
		s = string.sub(s, 2)
	end
	return s
end

local function cellCenter(c)
	local s, o = S.grid.size, S.grid.origin
	return Vector3.new(o.X + (c.x + 0.5) * s, o.Y + (c.y + 0.5) * s, o.Z + (c.z + 0.5) * s)
end
local function worldToCell(p)
	local s, o = S.grid.size, S.grid.origin
	return {
		x = math.floor((p.X - o.X) / s),
		y = math.floor((p.Y - o.Y) / s),
		z = math.floor((p.Z - o.Z) / s),
	}
end
local function sameCell(a, b)
	return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z
end
local function wrapHalf(v, s)
	return ((v + s / 2) % s) - s / 2
end

----------------------------------------------------------------------------------------------
-- 4. Looking at the world (read-only): characters, blocks, "is this cell filled?"
----------------------------------------------------------------------------------------------
local Preview = {} -- filled in below; only .folder is needed here

local function characters()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			list[#list + 1] = p.Character
		end
	end
	if Preview.folder then
		list[#list + 1] = Preview.folder
	end
	return list
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 60

local function refreshOverlapFilter()
	overlap.FilterDescendantsInstances = characters()
end

-- Does this part look like one of the game's REAL blocks (not the ground plate, not a flower)?
-- Real blocks are opaque. The game's translucent placement preview ("ghost") and glass-like parts are
-- not blocks: counting them made empty cells look filled and previews look like placed blocks.
local function qualifies(p)
	if not p:IsA("BasePart") or p:IsA("Terrain") or p.Transparency >= 0.15 then
		return false
	end
	local s = S.grid.size
	local sz = p.Size
	return math.min(sz.X, sz.Y, sz.Z) >= s * CONFIG.OCC_MIN_FRACTION and math.max(sz.X, sz.Y, sz.Z) <= s * CONFIG.OCC_MAX_MULT
end

-- Parts a camera ray / mouse pick should look straight through: invisible volumes, and the game's
-- translucent, non-solid placement preview (it would otherwise hide the real face behind it).
local function seeThrough(p)
	return p:IsA("BasePart") and not p:IsA("Terrain") and (p.Transparency >= 0.9 or (p.Transparency >= 0.15 and not p.CanCollide))
end

local function cellOccupied(cell)
	local s = S.grid.size
	for _, p in ipairs(workspace:GetPartBoundsInRadius(cellCenter(cell), s * 0.3, overlap)) do
		if qualifies(p) then
			return true
		end
	end
	return false
end

local function nearbyBlocks(center)
	local set = {}
	for _, p in ipairs(workspace:GetPartBoundsInRadius(center, S.grid.size * 1.5, overlap)) do
		if qualifies(p) then
			set[p] = true
		end
	end
	return set
end

-- Use a placed cube-shaped block to learn the game's real grid (size + where the lattice sits).
local function adoptGrid(part)
	local sz = part.Size
	local size = sz.X
	local corner = part.Position - sz / 2
	local function wrap(v)
		return ((v % size) + size) % size
	end
	S.grid.size = size
	S.grid.origin = Vector3.new(wrap(corner.X), wrap(corner.Y), wrap(corner.Z))
	S.grid.confirmed = true
	log("INFO", string.format("grid: %.2f studs per block, origin (%.2f, %.2f, %.2f) from '%s'", size, S.grid.origin.X, S.grid.origin.Y, S.grid.origin.Z, part.Name))
end

local function isCube(p)
	if not p:IsA("BasePart") or p:IsA("Terrain") then
		return false
	end
	local sz = p.Size
	local mn, mx = math.min(sz.X, sz.Y, sz.Z), math.max(sz.X, sz.Y, sz.Z)
	return mx - mn <= mn * 0.02 and mn >= 1 and mn <= 16
end

-- Look at the cube-shaped parts around you; the most common size is the game's block size.
local function detectGrid()
	local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters()
	params.MaxParts = 400
	local counts, nearest = {}, {}
	for _, p in ipairs(workspace:GetPartBoundsInRadius(hrp.Position, 80, params)) do
		if p.Transparency < 0.15 and isCube(p) then
			local key = math.floor(p.Size.X * 100 + 0.5) / 100
			counts[key] = (counts[key] or 0) + 1
			local d = (p.Position - hrp.Position).Magnitude
			if not nearest[key] or d < nearest[key].d then
				nearest[key] = { d = d, part = p }
			end
		end
	end
	local bestKey, bestN = nil, 0
	for key, n in pairs(counts) do
		if n > bestN then
			bestKey, bestN = key, n
		end
	end
	if bestKey and bestN >= 4 then
		adoptGrid(nearest[bestKey].part)
		return true
	end
	return false
end

----------------------------------------------------------------------------------------------
-- 5. Preview: a clean orange outline. Built from adornments (NOT parts), so nothing here can
--    ever be hit by the game's own click / raycast, and it can't be mistaken for a real block.
----------------------------------------------------------------------------------------------
do
	local folder, areaAnchor, aAnchor, hoverAnchor
	local edges, fillBox, aBox, hoverBox = {}, nil, nil, nil

	local function anchorPart(name)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Locked = true
		p.Transparency = 1
		p.Size = Vector3.new(0.1, 0.1, 0.1)
		return p
	end
	local function adorn(part, color, transparency, onTop)
		local b = Instance.new("BoxHandleAdornment")
		b.Adornee = part
		b.Color3 = color
		b.Transparency = transparency
		b.AlwaysOnTop = onTop
		b.ZIndex = 1
		b.Size = Vector3.new(1, 1, 1)
		b.Parent = part
		return b
	end

	function Preview.init()
		folder = Instance.new("Folder")
		folder.Name = "AutoBuilderPreview"
		folder.Parent = workspace
		onDestroy(function()
			folder:Destroy()
		end)
		Preview.folder = folder
		areaAnchor = anchorPart("Area")
		for i = 1, 12 do
			edges[i] = adorn(areaAnchor, ORANGE, 0, true)
		end
		fillBox = adorn(areaAnchor, ORANGE, 0.88, false)
		aAnchor = anchorPart("PointA")
		aBox = adorn(aAnchor, ORANGE_HI, 0.45, true)
		hoverAnchor = anchorPart("Hover")
		hoverBox = adorn(hoverAnchor, ORANGE, 0.75, true)
	end

	-- mn / mx: cell bounds (inclusive) or nil to hide
	function Preview.setArea(mn, mx)
		if not areaAnchor then
			return
		end
		if not mn then
			areaAnchor.Parent = nil
			return
		end
		local s, o = S.grid.size, S.grid.origin
		local p1 = Vector3.new(o.X + mn.x * s, o.Y + mn.y * s, o.Z + mn.z * s)
		local p2 = Vector3.new(o.X + (mx.x + 1) * s, o.Y + (mx.y + 1) * s, o.Z + (mx.z + 1) * s)
		local size = p2 - p1
		areaAnchor.Position = (p1 + p2) / 2
		local t = math.max(0.12, s * 0.035)
		local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
		local i = 0
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				i += 1
				edges[i].Size, edges[i].CFrame = Vector3.new(size.X + t, t, t), CFrame.new(0, sy * hy, sz * hz)
			end
		end
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				i += 1
				edges[i].Size, edges[i].CFrame = Vector3.new(t, size.Y + t, t), CFrame.new(sx * hx, 0, sz * hz)
			end
		end
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				i += 1
				edges[i].Size, edges[i].CFrame = Vector3.new(t, t, size.Z + t), CFrame.new(sx * hx, sy * hy, 0)
			end
		end
		fillBox.Size = size
		areaAnchor.Parent = folder
	end

	local function setCell(anchor, box, cell)
		if not anchor then
			return
		end
		if not cell then
			anchor.Parent = nil
			return
		end
		local s = S.grid.size
		box.Size = Vector3.new(s, s, s) * 1.02
		anchor.Position = cellCenter(cell)
		anchor.Parent = folder
	end
	function Preview.setA(cell)
		setCell(aAnchor, aBox, cell)
	end
	function Preview.setHover(cell)
		setCell(hoverAnchor, hoverBox, cell)
	end
	function Preview.clear()
		Preview.setArea(nil)
		Preview.setA(nil)
		Preview.setHover(nil)
	end
end

----------------------------------------------------------------------------------------------
-- 6. Selection geometry
----------------------------------------------------------------------------------------------
-- One fixed order (Core.buildOrder, unit-tested): bottom layer first, then row by row (z), and every row
-- left to right (x). No snaking: the same direction every row keeps the build predictable and easy to check.
local function buildOrder(mn, mx)
	return Core.buildOrder(mn, mx, "z", false)
end

local function boundsOf(a, b)
	return {
		x = math.min(a.x, b.x), y = math.min(a.y, b.y), z = math.min(a.z, b.z),
	}, {
		x = math.max(a.x, b.x), y = math.max(a.y, b.y), z = math.max(a.z, b.z),
	}
end

local function dimsText()
	if not S.min then
		return ""
	end
	return string.format("%d×%d×%d", S.max.x - S.min.x + 1, S.max.y - S.min.y + 1, S.max.z - S.min.z + 1)
end

local needScanToken = 0
local function countUnfilled() end -- (defined just below; declared early because setSelection uses it)

local function setSelection()
	S.min, S.max, S.count, S.order, S.tooLarge, S.needed = nil, nil, 0, nil, false, nil
	S.job = nil -- a different (or re-aligned) selection is a different job
	needScanToken += 1
	if S.a and S.b then
		local mn, mx = boundsOf(S.a, S.b)
		local count = (mx.x - mn.x + 1) * (mx.y - mn.y + 1) * (mx.z - mn.z + 1)
		S.min, S.max, S.count = mn, mx, count
		if count > CONFIG.MAX_CELLS then
			S.tooLarge = true
			status(string.format("That area is too big (%s blocks, max %s).", fmt(count), fmt(CONFIG.MAX_CELLS)), "error")
		else
			S.order = buildOrder(mn, mx)
			log("INFO", string.format("area %s = %d cells", dimsText(), count))
			task.spawn(countUnfilled)
		end
	end
	Preview.setArea(S.min, S.max)
	render()
end

-- how many cells in the selection are still empty (yields so it never hitches the game)
countUnfilled = function()
	local order = S.order
	if not order or S.state == "building" then
		return
	end
	needScanToken += 1
	local token = needScanToken
	refreshOverlapFilter()
	local empty = 0
	for i = 1, order.n do
		if not cellOccupied({ x = order.xs[i], y = order.ys[i], z = order.zs[i] }) then
			empty += 1
		end
		if i % 150 == 0 then
			task.wait()
			if token ~= needScanToken or not ARB.alive then
				return
			end
			refreshOverlapFilter()
		end
	end
	if token == needScanToken then
		S.needed = empty
		S.lastCount = os.clock()
		if S.areaNote and S.min then
			S.status, S.statusKind = string.format("Area %s: %d to fill, %d already filled.", dimsText(), empty, S.count - empty), "info"
		end
		render()
	end
end

----------------------------------------------------------------------------------------------
-- 7. Inventory: how many of the selected block do you have? (read-only, or typed in)
----------------------------------------------------------------------------------------------
local function norm(s)
	s = string.lower(tostring(s))
	s = string.gsub(s, "%s*blocks?%s*$", "")
	s = string.gsub(s, "[^%w]", "")
	return s
end
local function cleanName(name)
	local n = string.gsub(name, "%s*[xX]%s*[%d,]+%s*$", "")
	return n
end
local function parseCount(text)
	if type(text) ~= "string" then
		return nil
	end
	local d = string.match(text, "^%s*[xX]%s*([%d,]+)%s*$")
		or string.match(text, "^%s*×%s*([%d,]+)%s*$")
		or string.match(text, "^%s*([%d,]+)%s*[xX]%s*$")
	if d then
		d = string.gsub(d, ",", "")
		return tonumber(d)
	end
	return nil
end
local COUNT_ATTRS = { "Count", "Amount", "Quantity", "Stack", "Stacks", "Qty" }
local function toolCount(tool)
	for _, a in ipairs(COUNT_ATTRS) do
		local v = tool:GetAttribute(a)
		if type(v) == "number" then
			return v
		end
	end
	for _, c in ipairs(tool:GetChildren()) do
		if (c:IsA("IntValue") or c:IsA("NumberValue")) and table.find(COUNT_ATTRS, c.Name) then
			return c.Value
		end
	end
	local n = string.match(tool.Name, "[xX]%s*([%d,]+)%s*$")
	if n then
		return tonumber((string.gsub(n, ",", "")))
	end
	return nil
end
local function guiVisible(inst)
	local cur = inst
	while cur and cur ~= game do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("ScreenGui") and not cur.Enabled then
			return false
		end
		cur = cur.Parent
	end
	return true
end

-- the "x686" text sitting next to the item's name in the hotbar
local function scanGui(name)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local want = norm(name)
	for _, d in ipairs(pg:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and norm(d.Text) == want then
			if not (UI.gui and d:IsDescendantOf(UI.gui)) and guiVisible(d) then
				local node = d.Parent
				for _ = 1, 3 do
					if not node or node == pg then
						break
					end
					for _, sib in ipairs(node:GetDescendants()) do
						if sib ~= d and (sib:IsA("TextLabel") or sib:IsA("TextButton")) and parseCount(sib.Text) then
							return sib
						end
					end
					node = node.Parent
				end
			end
		end
	end
	return nil
end

local function resolveTool()
	local b = S.block
	if not b then
		return nil
	end
	if b.tool and b.tool.Parent then
		return b.tool
	end
	for _, container in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChildOfClass("Backpack") }) do
		if container then
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") and norm(cleanName(t.Name)) == norm(b.name) then
					b.tool = t
					return t
				end
			end
		end
	end
	return nil
end

local guiSource, guiSourceFor, guiScanAt = nil, nil, 0

----------------------------------------------------------------------------------------------
-- 7b. The item in your hand: a standard Tool, OR the game's own custom hotbar.
--     ABOVE[RUINS] draws its hotbar itself, so there is usually no Tool object at all. The hotbar
--     is found from what it looks like on screen: slots that each show a number 1-9, an item name
--     and a count ("x25"). The SELECTED slot is the one the game highlights (yellow outline /
--     background) or, failing that, the only slot that looks different from the rest.
----------------------------------------------------------------------------------------------
local function isOurs(inst)
	return UI.gui ~= nil and inst:IsDescendantOf(UI.gui)
end
local function isYellow(c)
	return c.R >= 0.75 and c.G >= 0.55 and c.B <= 0.5 and (c.R - c.B) >= 0.35
end

local Hotbar = { slots = nil, why = nil, foundAt = -100, lastDump = nil }

-- A hotbar slot is roughly square-ish and neither tiny nor huge. The limits scale with the screen.
local function plausibleSlotSize(gui)
	local sz = gui.AbsoluteSize
	local cam = workspace.CurrentCamera
	local view = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local hi = math.max(170, math.min(view.X, view.Y) * 0.25)
	return sz.X >= 20 and sz.X <= hi and sz.Y >= 20 and sz.Y <= hi
end

-- Find the slots: containers that each hold a visible single-digit label (1-9). The label's own parent is
-- not always the slot (there may be inner frames), so EVERY plausible ancestor is a candidate and the
-- group (candidates sharing a parent) with the most distinct slot numbers wins - that's the hotbar row.
function Hotbar.find()
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil, "no PlayerGui"
	end
	local groups, digitLabels = {}, 0
	local function add(slot, d)
		if slot and slot:IsA("GuiObject") and plausibleSlotSize(slot) and slot.Parent then
			local list = groups[slot.Parent]
			if not list then
				list = {}
				groups[slot.Parent] = list
			end
			list[#list + 1] = { slot = slot, num = tonumber(d.Text), numLabel = d }
		end
	end
	for _, d in ipairs(pg:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and #d.Text == 1 and string.match(d.Text, "^[1-9]$") and not isOurs(d) and guiVisible(d) then
			digitLabels += 1
			-- the label itself is the slot only if it's a button-like thing whose parent is NOT slot-sized
			if plausibleSlotSize(d) and #d:GetChildren() > 0 and not (d.Parent and d.Parent:IsA("GuiObject") and plausibleSlotSize(d.Parent)) then
				add(d, d)
			end
			local anc = d.Parent
			for _ = 1, 4 do
				if not anc or anc == pg then
					break
				end
				add(anc, d)
				anc = anc.Parent
			end
		end
	end
	local best, bestN = nil, 0
	for _, list in pairs(groups) do
		local seen, n = {}, 0
		for _, e in ipairs(list) do
			if not seen[e.num] then
				seen[e.num] = true
				n += 1
			end
		end
		if n > bestN then
			best, bestN = list, n
		end
	end
	if not best or bestN < 3 then
		return nil, string.format("found %d slot-number labels but no row of 3+ slots", digitLabels)
	end
	table.sort(best, function(a, b)
		return a.num < b.num
	end)
	local out, used = {}, {}
	for _, e in ipairs(best) do
		if not used[e.num] then
			used[e.num] = true
			out[#out + 1] = e
		end
	end
	return out
end

-- "x25", "25x", "×25" - or just "25" (only meaningful next to an item in a hotbar slot)
local function parseCountLoose(text)
	local n = parseCount(text)
	if n then
		return n
	end
	local bare = type(text) == "string" and string.match(text, "^%s*([%d,]+)%s*$")
	if bare then
		return tonumber((string.gsub(bare, ",", "")))
	end
	return nil
end

-- name, count, nameLabel, countLabel of one slot
local function readSlot(e)
	local name, count, nameLabel, countLabel
	local looseCount, looseLabel
	for _, d in ipairs(e.slot:GetDescendants()) do
		-- (a second copy of the slot number, e.g. a drop-shadow label, is not a count)
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d ~= e.numLabel and d.Text ~= "" and d.Text ~= tostring(e.num) and guiVisible(d) then
			local t = d.Text
			local c = parseCount(t)
			if c then
				count, countLabel = c, d
			elseif string.match(t, "%a%a") then
				if not name or #t > #name then
					name, nameLabel = t, d
				end
			else
				local bare = parseCountLoose(t)
				if bare then
					looseCount, looseLabel = bare, d
				end
			end
		end
	end
	if not count and looseCount then
		count, countLabel = looseCount, looseLabel -- a bare "25" in the slot, no "x"
	end
	if name then
		local inline = string.match(name, "[xX]%s*([%d,]+)%s*$") -- "Grass Block x25" in one label
		if inline and not count then
			count = tonumber((string.gsub(inline, ",", "")))
		end
		name = cleanName(name)
	end
	return name, count, nameLabel, countLabel
end

-- how strongly does this slot look "selected"? (yellow outline / background / frame)
local function highlightScore(slot)
	local score, why = 0, nil
	local function note(w)
		why = why and (why .. "," .. w) or w
	end
	if slot:IsA("GuiObject") then
		if slot.BackgroundTransparency < 0.9 and isYellow(slot.BackgroundColor3) then
			score += 3
			note("background")
		end
		if slot.BorderSizePixel > 0 and isYellow(slot.BorderColor3) then
			score += 3
			note("border")
		end
		if (slot:IsA("ImageButton") or slot:IsA("ImageLabel")) and slot.ImageTransparency < 0.9 and isYellow(slot.ImageColor3) then
			score += 2
			note("image")
		end
	end
	local width = slot.AbsoluteSize.X
	local checked = 0
	for _, d in ipairs(slot:GetDescendants()) do
		checked += 1
		if checked > 80 then
			break
		end
		if d:IsA("UIStroke") then
			if d.Enabled and d.Transparency < 0.9 and isYellow(d.Color) then
				score += 3
				note("stroke")
			end
		elseif d:IsA("Frame") and d.Visible and d.BackgroundTransparency < 0.7 and isYellow(d.BackgroundColor3) and d.AbsoluteSize.X >= width * 0.5 then
			score += 2
			note("frame")
		end
	end
	return score, why
end

-- a fingerprint of how the slot itself is styled (used to spot the one slot that differs)
local function slotSignature(slot)
	local parts = {}
	if slot:IsA("GuiObject") then
		parts[#parts + 1] = string.format(
			"%s/%.2f/%d/%s/%d",
			tostring(slot.BackgroundColor3), slot.BackgroundTransparency, slot.BorderSizePixel,
			tostring(slot.BorderColor3), math.floor(slot.AbsoluteSize.X + 0.5)
		)
		if slot:IsA("ImageButton") or slot:IsA("ImageLabel") then
			parts[#parts + 1] = tostring(slot.ImageColor3) .. string.format("/%.2f", slot.ImageTransparency)
		end
	end
	for _, c in ipairs(slot:GetChildren()) do
		if c:IsA("UIStroke") then
			parts[#parts + 1] = string.format("S%s/%.1f/%s/%.2f", tostring(c.Color), c.Thickness, tostring(c.Enabled), c.Transparency)
		end
	end
	return table.concat(parts, "|")
end

-- Some games also keep the selection in an attribute / value ("EquippedItem", "SelectedSlot", ...).
local function stateHint(infos)
	local function match(v, key)
		local k = string.lower(key)
		for _, it in ipairs(infos) do
			if type(v) == "string" and it.name and norm(it.name) == norm(v) then
				return it
			elseif type(v) == "number" and it.num == v and (string.find(k, "select") or string.find(k, "equip")) then
				return it -- (a bare number only counts for names like "SelectedSlot", not e.g. "MaxSlots")
			end
		end
	end
	local function wanted(key)
		local k = string.lower(key)
		return string.find(k, "equip") or string.find(k, "select") or string.find(k, "held") or string.find(k, "hand") or string.find(k, "slot")
	end
	for _, holder in ipairs({ LocalPlayer, LocalPlayer.Character }) do
		if holder then
			for key, v in pairs(holder:GetAttributes()) do
				if wanted(key) then
					local it = match(v, key)
					if it then
						return it, "attribute '" .. key .. "'"
					end
				end
			end
			for _, c in ipairs(holder:GetChildren()) do
				if (c:IsA("StringValue") or c:IsA("IntValue") or c:IsA("NumberValue")) and wanted(c.Name) then
					local it = match(c.Value, c.Name)
					if it then
						return it, "value '" .. c.Name .. "'"
					end
				end
			end
		end
	end
	return nil
end

local function ensureSlots(force)
	local stale = Hotbar.slots == nil
	if Hotbar.slots then
		for _, e in ipairs(Hotbar.slots) do
			-- (a GUI detached with Parent = nil keeps its own internal Parent links, so test the whole chain)
			if not e.slot:IsDescendantOf(game) then
				stale = true
				break
			end
		end
	end
	local incomplete = Hotbar.slots ~= nil and #Hotbar.slots < 9 and os.clock() - Hotbar.foundAt > 5
	if (stale or incomplete) and os.clock() - Hotbar.foundAt > (force and 0.4 or 3) then
		Hotbar.foundAt = os.clock()
		local slots, why = Hotbar.find()
		if slots or stale then
			Hotbar.slots, Hotbar.why = slots, why
		end
		if slots and #slots ~= Hotbar.lastCount then
			Hotbar.lastCount = #slots
			log("INFO", "custom hotbar found: " .. #slots .. " slots")
		end
	end
	return Hotbar.slots
end

-- Returns item {name, count, slot, countLabel, source} | nil, reason, dump
function Hotbar.read(force)
	local slots = ensureSlots(force)
	if not slots then
		return nil, "can't find your hotbar (" .. tostring(Hotbar.why) .. ")"
	end
	local infos, freq = {}, {}
	for i, e in ipairs(slots) do
		local name, count, nameLabel, countLabel = readSlot(e)
		local score, why = highlightScore(e.slot)
		local sig = slotSignature(e.slot)
		infos[i] = { num = e.num, name = name, count = count, countLabel = countLabel, score = score, why = why, sig = sig }
		freq[sig] = (freq[sig] or 0) + 1
	end
	local parts = {}
	for _, it in ipairs(infos) do
		parts[#parts + 1] = string.format("%d:%s%s[%d%s]", it.num, it.name or "-", it.count and ("x" .. it.count) or "", it.score, it.why and (" " .. it.why) or "")
	end
	local dump = table.concat(parts, "  ")

	local chosen, how
	local maxScore, maxN = 0, 0
	for _, it in ipairs(infos) do
		if it.score > maxScore then
			maxScore, maxN = it.score, 1
		elseif it.score == maxScore and maxScore > 0 then
			maxN += 1
		end
	end
	if maxScore >= 2 and maxN == 1 then -- (uniqueness is what guards against false positives)
		for _, it in ipairs(infos) do
			if it.score == maxScore then
				chosen, how = it, "highlighted: " .. tostring(it.why)
			end
		end
	end
	if not chosen and #infos >= 4 then -- the only slot styled differently from all the others
		local singles, majority = {}, 0
		for _, it in ipairs(infos) do
			if freq[it.sig] == 1 then
				singles[#singles + 1] = it
			end
			majority = math.max(majority, freq[it.sig])
		end
		if #singles == 1 and majority >= #infos - 1 then
			chosen, how = singles[1], "the only slot that looks different"
		end
	end
	if not chosen then
		local it, src = stateHint(infos)
		if it then
			chosen, how = it, src
		end
	end
	if not chosen then
		return nil, "can't tell which hotbar slot is selected (none stood out)", dump
	end
	if not chosen.name then
		return nil, "hotbar slot " .. chosen.num .. " looks selected but empty", dump
	end
	return {
		name = chosen.name, count = chosen.count, slot = chosen.num, countLabel = chosen.countLabel,
		source = "hotbar slot " .. chosen.num .. " (" .. how .. ")",
	}, nil, dump
end

-- Find an item by name (for re-reading its count after the game redraws the hotbar).
-- Returns count, countLabel, found   (found = a slot with that item name exists; count may still be nil)
function Hotbar.lookup(name, num)
	local slots = ensureSlots(true)
	if not slots then
		return nil, nil, false
	end
	local fallbackCount, fallbackLabel, fallbackFound
	for _, e in ipairs(slots) do
		if e.slot:IsDescendantOf(game) then
			local n, c, _, cl = readSlot(e)
			if n and norm(n) == norm(name) then
				if num == nil or e.num == num then
					return c, cl, true
				end
				fallbackCount, fallbackLabel, fallbackFound = fallbackCount or c, fallbackLabel or cl, true
			end
		end
	end
	return fallbackCount, fallbackLabel, fallbackFound or false
end

-- Has the held item left the inventory display entirely? (e.g. the last block was used up.)
-- "Can't tell" (hotbar not readable right now) is NOT the same as gone.
local function itemGone()
	local b = S.block
	if not b then
		return true
	end
	if b.slot then
		if not ensureSlots(true) then
			return false
		end
		local _, _, found = Hotbar.lookup(b.name, nil)
		return not found
	end
	return resolveTool() == nil
end

----------------------------------------------------------------------------------------------
-- how many of the held block do you have? (read from the game, or typed in)
----------------------------------------------------------------------------------------------
-- returns count, "auto" | "manual"   (nil when the game's number can't be read)
local function readOwned()
	if S.manualOwned ~= nil then
		return math.max(0, S.manualOwned - (S.placedAll - S.manualAt)), "manual"
	end
	local b = S.block
	if not b then
		return nil
	end
	local tool = resolveTool()
	if tool then
		local n = toolCount(tool)
		if n then
			return n, "auto"
		end
	end
	-- custom hotbar: the "x25" text in the item's slot
	if b.countLabel and b.countLabel:IsDescendantOf(game) then
		local n = parseCountLoose(b.countLabel.Text)
		if n then
			return n, "auto"
		end
	end
	if b.slot then -- the game probably redrew the hotbar: look the item up again
		local c, cl = Hotbar.lookup(b.name, b.slot)
		if cl then
			b.countLabel = cl
		end
		if c then
			return c, "auto"
		end
		-- (Deliberately NO whole-screen text search here: from a count-less slot it could latch onto
		-- some OTHER slot's "x64" and report that as your count.)
		return nil
	end
	if guiSourceFor ~= b.name then
		guiSource, guiSourceFor, guiScanAt = nil, b.name, 0
	end
	if (not guiSource or not guiSource.Parent) and os.clock() - guiScanAt > 3 then
		guiScanAt = os.clock()
		guiSource = scanGui(b.name)
		if guiSource then
			log("INFO", "reading '" .. b.name .. "' count from on-screen text '" .. guiSource.Text .. "'")
		end
	end
	if guiSource and guiSource.Parent then
		local n = parseCount(guiSource.Text)
		if n then
			return n, "auto"
		end
	end
	return nil
end

-- Is the item we're building with still the one in hand?
local function ensureEquipped()
	local b = S.block
	if not b then
		return false
	end
	if b.source == "unknown" then
		return true -- you typed the count without a detectable item: nothing to verify against
	end
	if not b.slot then -- standard Tool
		local char = LocalPlayer.Character
		local tool = resolveTool()
		if not char or not tool then
			return false
		end
		if char:FindFirstChildOfClass("Tool") == tool then
			return true
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			pcall(function()
				hum:EquipTool(tool)
			end)
			task.wait(0.3)
		end
		return char:FindFirstChildOfClass("Tool") == tool
	end
	-- custom hotbar: the selected slot must still be this item (a highlight can flicker, so look a few times)
	for _ = 1, 3 do
		local item = Hotbar.read(true)
		if item and norm(item.name) == norm(b.name) then
			b.countLabel = item.countLabel
			return true
		end
		task.wait(0.15)
	end
	return false
end

----------------------------------------------------------------------------------------------
-- 8. Input: move the mouse and click, the way you would (verified, never blind)
----------------------------------------------------------------------------------------------
local Input = { method = nil }
function Input.detect()
	local ok, vim = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if ok and vim then
		Input.vim, Input.method = vim, "VirtualInputManager"
	elseif mouse1click ~= nil then
		Input.method = "executor mouse functions"
	end
	log("INFO", "mouse control:", Input.method or "NOT AVAILABLE")
end

-- VirtualInputManager can exist without actually delivering clicks; if the executor has its own
-- mouse functions, use those instead.
function Input.switchToExecutor()
	if Input.vim and mouse1click ~= nil then
		Input.vim, Input.method = nil, "executor mouse functions"
		log("WARN", "VirtualInputManager didn't work - switching to the executor's mouse functions")
		return true
	end
	return false
end

-- Clicks where the cursor (in first person: the crosshair) already is. Nothing is moved.
-- Returns false (and sends nothing) unless the cursor is still on (x, y).
function Input.click(x, y)
	if (UIS:GetMouseLocation() - Vector2.new(x, y)).Magnitude > 4 then
		return false
	end
	if Input.vim then
		Input.vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
		task.wait(0.04)
		Input.vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
	else
		mouse1click()
	end
	return true
end

-- Did my click actually arrive in Roblox's input system? (Lets a failure be blamed on the right thing:
-- "the click never arrived" is an INPUT problem; "it arrived but no block appeared" is the game's.)
Input.expecting, Input.seen, Input.seenProcessed = false, false, false
keep(UIS.InputBegan:Connect(function(input, processed)
	if Input.expecting and input.UserInputType == Enum.UserInputType.MouseButton1 then
		Input.seen, Input.seenProcessed = true, processed
	end
end))

----------------------------------------------------------------------------------------------
-- 9. Looking: what is the cursor pointing at?
----------------------------------------------------------------------------------------------
local function rayParams()
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.IgnoreWater = true
	p.FilterDescendantsInstances = characters()
	return p
end

local function overFrameAt(f, x, y)
	if not f or not f.Parent or not f.Visible then
		return false
	end
	local p, s = f.AbsolutePosition, f.AbsoluteSize
	return x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y
end

-- would a click here hit one of the game's own buttons instead of the world?
local function gameGuiAt(x, y)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return false
	end
	local inset = GuiService:GetGuiInset()
	local ok, list = pcall(function()
		return pg:GetGuiObjectsAtPosition(x - inset.X, y - inset.Y)
	end)
	if not ok then
		return false
	end
	for _, o in ipairs(list) do
		if not (UI.gui and o:IsDescendantOf(UI.gui)) and (o:IsA("GuiButton") or o.Active) then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------------------------------
-- 9b. The character's parts, and snapping my grid to the game's real blocks
--     (This script never moves, jumps or teleports your character, and never touches your camera.)
----------------------------------------------------------------------------------------------
local function myParts()
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid"), char and char:FindFirstChild("HumanoidRootPart")
end

-- The game's blocks all sit on one lattice. Use the cube-shaped blocks around the selected area to find
-- where that lattice is and snap my grid to it, keeping the same rectangle in the world.
local function calibrateNear()
	if not (S.min and S.a and S.b) then
		return false
	end
	local s, o = S.grid.size, S.grid.origin
	local center = Vector3.new(
		o.X + (S.min.x + S.max.x + 1) / 2 * s, o.Y + (S.min.y + S.max.y + 1) / 2 * s, o.Z + (S.min.z + S.max.z + 1) / 2 * s
	)
	local half = Vector3.new((S.max.x - S.min.x + 1) * s, (S.max.y - S.min.y + 1) * s, (S.max.z - S.min.z + 1) * s).Magnitude / 2
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters()
	params.MaxParts = 500
	local rs, n = { x = {}, y = {}, z = {} }, 0
	for _, p in ipairs(workspace:GetPartBoundsInRadius(center, half + s * 6, params)) do
		if p.Transparency < 0.15 and isCube(p) and math.abs(p.Size.X - s) <= s * 0.03 then
			local corner = p.Position - p.Size / 2
			rs.x[#rs.x + 1] = ((corner.X % s) + s) % s
			rs.y[#rs.y + 1] = ((corner.Y % s) + s) % s
			rs.z[#rs.z + 1] = ((corner.Z % s) + s) % s
			n += 1
		end
	end
	if n < 6 then
		log("INFO", string.format("lattice check: only %d nearby blocks of the right size - not enough to align the grid", n))
		return false
	end
	local nx, fx = Core.consensus(rs.x, s)
	local ny, fy = Core.consensus(rs.y, s)
	local nz, fz = Core.consensus(rs.z, s)
	if fx < 0.5 or fy < 0.5 or fz < 0.5 then
		log("INFO", string.format("lattice check: the nearby blocks don't agree on one grid (%.0f%% / %.0f%% / %.0f%%)", fx * 100, fy * 100, fz * 100))
		return false
	end
	local function circ(a, b)
		local d = math.abs(a - b) % s
		return math.min(d, s - d)
	end
	S.grid.confirmed = true
	if circ(nx, o.X) > s * 0.04 or circ(ny, o.Y) > s * 0.04 or circ(nz, o.Z) > s * 0.04 then
		local aw, bw = cellCenter(S.a), cellCenter(S.b)
		S.grid.origin = Vector3.new(nx, ny, nz)
		S.a, S.b = worldToCell(aw), worldToCell(bw)
		log("INFO", string.format("grid aligned to the %d blocks around the area: origin (%.2f, %.2f, %.2f)", n, nx, ny, nz))
		setSelection() -- same rectangle in the world, on the corrected grid
	end
	return true
end

----------------------------------------------------------------------------------------------
-- 10. Placing one block, and checking that it really happened - in the RIGHT cell
----------------------------------------------------------------------------------------------
-- Every new part that appears while a click is being checked (anywhere), so a block that lands in
-- the wrong place can't hide from me.
local Watch = { active = false, list = {} }
keep(workspace.DescendantAdded:Connect(function(d)
	if Watch.active and d:IsA("BasePart") then
		Watch.list[#Watch.list + 1] = d
	end
end))

local function inCharacter(part)
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- new, opaque, block-sized parts near the target cell (previews and glass don't count; a block somebody else
-- places far away can't be mistaken for the result of my click)
local function collectFresh(center)
	local out = {}
	for _, d in ipairs(Watch.list) do
		if d.Parent and qualifies(d) and not (Preview.folder and d:IsDescendantOf(Preview.folder)) and not inCharacter(d) then
			if (d.Position - center).Magnitude <= S.grid.size * 3 then
				out[#out + 1] = d
			end
		end
	end
	return out
end

-- The game shows a translucent preview of where a click would put the block. If I can find it, compare
-- it with the cell I mean to fill BEFORE clicking.
-- Returns true (fine, or no preview found) + the preview's offset from the cell centre, or false + why.
local function ghostCheck(aim, cell)
	local s = S.grid.size
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters()
	params.MaxParts = 300
	local best, bestD
	for _, p in ipairs(workspace:GetPartBoundsInRadius(aim.world, s * 2.2, params)) do
		if p:IsA("BasePart") and not p:IsA("Terrain") and not p.CanCollide and p.Transparency >= 0.15 and p.Transparency <= 0.98 then
			local sz = p.Size
			local mn, mx = math.min(sz.X, sz.Y, sz.Z), math.max(sz.X, sz.Y, sz.Z)
			if mn >= s * 0.8 and mx <= s * 1.2 and mx - mn <= s * 0.12 then
				local d = (p.Position - aim.world).Magnitude
				if not bestD or d < bestD then
					best, bestD = p, d
				end
			end
		end
	end
	if not best then
		return true -- no readable preview: the check after the click is what protects me
	end
	local off = best.Position - cellCenter(cell)
	if math.max(math.abs(off.X), math.abs(off.Y), math.abs(off.Z)) <= s * 0.6 then
		return true, nil, off
	end
	local gc = worldToCell(best.Position)
	return false, string.format("the game's own placement preview is at cell (%d,%d,%d), not the target (%d,%d,%d)", gc.x, gc.y, gc.z, cell.x, cell.y, cell.z)
end

-- What is the cursor (in first person: the crosshair) pointing at right now? Nothing is moved or aimed by me.
-- Returns { x, y, world, cell }: `cell` is the cell the game would put a block into if you clicked here (the
-- one in front of the face under the cursor), or nil + why.
local function lookTarget()
	local cam = workspace.CurrentCamera
	if not cam then
		return nil, "no camera"
	end
	local loc = UIS:GetMouseLocation()
	if overFrameAt(UI.window, loc.X, loc.Y) or overFrameAt(UI.reopen, loc.X, loc.Y) then
		return nil, "the cursor is over the menu"
	end
	if gameGuiAt(loc.X, loc.Y) then
		return nil, "the cursor is over one of the game's buttons"
	end
	local ray = cam:ViewportPointToRay(loc.X, loc.Y)
	local params = rayParams()
	local ignore = characters()
	local res
	for _ = 1, 6 do
		params.FilterDescendantsInstances = ignore
		res = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		if res and seeThrough(res.Instance) then
			ignore[#ignore + 1] = res.Instance -- the game's see-through placement preview etc.
			res = nil
		else
			break
		end
	end
	if not res then
		return nil, "pointing at the sky"
	end
	local p = res.Position + res.Normal * (S.grid.size / 2)
	return { x = loc.X, y = loc.Y, world = res.Position, cell = worldToCell(p) }
end

-- Click where the cursor is and check what appeared. Returns
--   "placed" | "failed" | "stray" | "skip" | "mismatch" | "misplaced" | "broke" | "unseen" | "stopped" | "nocursor", extra
--   placed    exactly one new real block appeared in exactly this cell (the only thing that is ever counted)
--   failed    the click reached the game but no block appeared (the game / server didn't place one)
--   stray     a block appeared in ANOTHER cell, but inside the selected area
--   misplaced a block appeared outside the area, or more than one appeared
--   broke     a block DISAPPEARED when I clicked (the held item removes blocks instead of placing)
--   unseen    the block count dropped but no new block was seen
--   mismatch  the game's own placement preview points at a different cell: nothing was clicked
--   skip      the cursor moved in the last instant: nothing was clicked
-- `run` is the build this click belongs to: if STOP is pressed (runId changes) NO click is sent.
local function walkPlace(aim, run, areaMin, areaMax)
	local s = S.grid.size
	local cell = aim.cell
	local center = cellCenter(cell)
	if S.runId ~= run then
		return "stopped"
	end

	-- 1) The game shows a translucent preview of where a click would put the block. If I can read it, it must
	--    point at THIS cell.
	local good, ghostWhy, off = ghostCheck(aim, cell)
	if not good then
		return "mismatch", ghostWhy
	end
	-- The preview is the game's own lattice. If it is a small fraction of a block off mine, take it over (once
	-- per job, before any block is placed) instead of placing off-grid.
	if off and S.placed == 0 and not S.ghostAdopted then
		local cheb = math.max(math.abs(off.X), math.abs(off.Y), math.abs(off.Z))
		if cheb > s * 0.05 and cheb <= s * 0.45 then
			S.grid.origin = S.grid.origin + off
			S.ghostAdopted = true
			S.grid.confirmed = true
			log("INFO", string.format("grid aligned to the game's placement preview: shifted (%.2f, %.2f, %.2f)", off.X, off.Y, off.Z))
			Preview.setArea(S.min, S.max)
			return "skip" -- the cell under the cursor may be a different one on the corrected grid: look again
		end
	end

	-- 2) CLICK. Nothing yields between the STOP check above and the click. Input.click looks at the cursor
	--    once more and sends nothing if it is no longer on the spot.
	refreshOverlapFilter()
	local before = nearbyBlocks(center)
	local ownedBefore = readOwned()
	Watch.list, Watch.active = {}, true
	Input.seen, Input.seenProcessed, Input.expecting = false, false, true
	local okClick, clicked = pcall(Input.click, aim.x, aim.y)
	if not okClick or clicked == false then
		Watch.active, Input.expecting = false, false
		if not okClick then
			log("ERROR", "mouse click failed:", clicked)
			if Input.switchToExecutor() then
				return "failed"
			end
			return "nocursor", "this executor's mouse click errored (see console)"
		end
		return "skip"
	end
	task.wait(0.03)

	-- 3) WATCH what appears. A block counts only if it is opaque, block-sized and NEW.
	local fresh, removed, settleUntil = {}, false, nil
	local t0 = os.clock()
	while true do
		task.wait(0.05)
		refreshOverlapFilter()
		for inst in pairs(before) do
			if not inst.Parent then
				removed = true -- a block that was there is gone: this click broke something
				break
			end
		end
		if removed then
			break
		end
		fresh = collectFresh(center)
		if #fresh > 0 and not settleUntil then
			settleUntil = os.clock() + 0.12 -- give a possible second block a moment to show up as well
		end
		if settleUntil and os.clock() >= settleUntil then
			break
		end
		if #fresh == 0 and os.clock() - t0 >= CONFIG.PLACE_TIMEOUT then
			break
		end
	end
	Watch.active, Input.expecting = false, false
	S.lastAttempt = { seen = Input.seen, processed = Input.seenProcessed, overGui = gameGuiAt(aim.x, aim.y) }
	if removed then
		return "broke"
	end
	if #fresh == 0 then
		task.wait(0.3) -- the count label can lag behind the world
		local ownedAfter = readOwned()
		if ownedBefore ~= nil and ownedAfter ~= nil and ownedAfter < ownedBefore then
			return "unseen", string.format("%d -> %d", ownedBefore, ownedAfter)
		end
		return "failed"
	end

	-- 4) VERIFY the position of what appeared with the tested core logic: exactly one new block, in exactly
	--    this cell. (First block of a job: a small grid offset may be adopted once. After that the grid never moves.)
	local pts = {}
	for _, p in ipairs(fresh) do
		pts[#pts + 1] = { x = p.Position.X, y = p.Position.Y, z = p.Position.Z }
	end
	local o, c = S.grid.origin, center
	local verdict = Core.classifyFresh(pts, {
		cell = cell, center = { x = c.X, y = c.Y, z = c.Z }, size = s, origin = { x = o.X, y = o.Y, z = o.Z },
		first = S.placed == 0, min = areaMin, max = areaMax,
	})
	if verdict.kind == "misplaced" then
		local l = verdict.landed
		local text
		if verdict.why == "extra" then
			text = string.format("more than one new block appeared after a single click (one in cell (%d,%d,%d))%s", l.x, l.y, l.z, verdict.outside and " - OUTSIDE the selected area" or "")
		else
			text = string.format(
				"a block landed in cell (%d,%d,%d) instead of (%d,%d,%d)%s", l.x, l.y, l.z, cell.x, cell.y, cell.z,
				verdict.outside and " - OUTSIDE the selected area" or ""
			)
		end
		if verdict.why ~= "extra" and not verdict.outside then
			log("WARN", "stray block inside the area: " .. text)
			return "stray", text -- not counted; that cell gets filled anyway, and this one is tried again later
		end
		return "misplaced", text
	end
	if verdict.adopt then
		S.grid.origin = S.grid.origin + Vector3.new(verdict.adopt.x, verdict.adopt.y, verdict.adopt.z)
		S.grid.confirmed = true
		log("INFO", string.format("grid aligned by the first block: shifted (%.2f, %.2f, %.2f)", verdict.adopt.x, verdict.adopt.y, verdict.adopt.z))
		Preview.setArea(S.min, S.max)
	end
	return "placed"
end

----------------------------------------------------------------------------------------------
-- 11. The block in your hand + the build loop
----------------------------------------------------------------------------------------------
-- Every failure message starts with WHICH part failed, so you can tell them apart:
--   [ITEM]       I couldn't identify / read the item in your hand
--   [INPUT]      my mouse movement or click didn't work or didn't reach Roblox
--   [AIM]        I can't find a place on screen to click
--   [PLACEMENT]  the click reached the game but the game didn't place a block (or placed it elsewhere)
--   [DETECTION]  a block was used up but I couldn't see it in the world
local function diag(tag, text)
	return string.format("[%s] %s", tag, text)
end

local function setHeld(info)
	local n = norm(info.name)
	-- Compared with the last item we KNEW about (not with S.block, which is briefly nil whenever
	-- detection flickers) - so a count you typed in survives a flicker, but not a change of item.
	if S.heldNorm ~= n then
		S.heldNorm = n
		S.manualOwned = nil
		guiSource, guiSourceFor = nil, nil
		log("INFO", string.format("holding: %s  [%s]", info.name, info.source))
	end
	S.block = info
	S.misses = 0
end

-- What are you holding? A standard Tool first, then the selected slot of the game's own hotbar.
-- `force` = re-read the hotbar right now instead of waiting for the usual re-find throttle.
local function detectBlock(force)
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if tool then
		setHeld({ name = cleanName(tool.Name), tool = tool, source = "Tool in hand" })
		S.itemWhy = nil
		return true
	end
	local item, why, dump = Hotbar.read(force)
	if item then
		setHeld({ name = item.name, slot = item.slot, countLabel = item.countLabel, source = item.source })
		S.itemWhy = nil
		return true
	end
	S.itemWhy = why
	if dump and dump ~= Hotbar.lastDump then
		Hotbar.lastDump = dump
		log("INFO", "hotbar (slot:item xcount [highlight score]): " .. dump)
		log("WARN", "item detection: " .. tostring(why))
	elseif not dump and why ~= Hotbar.lastWhy then
		Hotbar.lastWhy = why
		log("WARN", "item detection: " .. tostring(why))
	end
	-- A hotbar item that has stopped being selected isn't "held" any more - but only after several misses
	-- in a row, so a flickering highlight doesn't blank it. (A real Tool that's merely put away stays
	-- remembered so AUTO PLACE can take it out again.)
	if S.block and S.block.slot then
		S.misses = (S.misses or 0) + 1
		if S.misses >= 3 then
			S.block = nil
		end
	end
	return S.block ~= nil
end

-- Safety: clicking with a pickaxe / axe / sword in hand would BREAK blocks instead of placing them,
-- so anything that looks like a tool or weapon is refused.
local TOOL_WORDS = {
	"sword", "pickaxe", "pick", "axe", "shovel", "spade", "hammer", "spear", "dagger", "knife", "wand",
	"staff", "scythe", "sickle", "hoe", "bow", "rod", "club", "mace", "shield", "saw", "drill",
}
local function looksLikeTool(name)
	local padded = " " .. string.lower(name) .. " "
	for _, word in ipairs(TOOL_WORDS) do
		if string.find(padded, "[^%a]" .. word .. "[^%a]") then
			return true
		end
	end
	return false
end

-- Ends the build (if `run` is still the current one) and says why.
local function stopBuild(run, text, kind)
	if S.runId ~= run then
		return
	end
	S.state = "idle"
	status(text, kind)
	S.needed = nil
	task.spawn(countUnfilled)
end

local function failureReason()
	local a = S.lastAttempt
	if a and not a.seen then
		return diag("INPUT", "My clicks never reached Roblox's input system (the executor's mouse events aren't being delivered), so the game never saw them.")
	elseif a and a.processed and a.overGui then
		return diag("INPUT", "My clicks were swallowed by a GUI element in front of the target - the game's UI got the click, not the world.")
	end
	-- (If the click was marked "processed" but nothing was over the target, the game itself consumed the
	-- click through its own input handling - i.e. it reacted and still placed nothing: that's PLACEMENT.)
	return diag("PLACEMENT", "My clicks reached the game, on the target, but it didn't place a block. Usual causes: out of placement range, not your land, a cooldown, the game needs a different action (hold / build mode), or the held item can't be placed. That is the game/server refusing, not the script.")
end

----------------------------------------------------------------------------------------------
-- AUTO PLACE: you walk and look around, and a block is placed wherever your cursor / crosshair points at an
-- EMPTY cell of the selected flat area. The decisions live in the tested CORE (section 1b) so that
--   * placed only ever counts blocks that were SEEN appearing in the cell that was aimed at,
--   * a cell this job filled is never clicked again, an occupied cell is never clicked,
--   * nothing is tried outside the area, and after a stop the SAME job can be resumed (RESUME).
-- Your character and camera are never touched: YOU walk, YOU look; the script only clicks.
----------------------------------------------------------------------------------------------
local function distanceTo(cell)
	local _, hrp = myParts()
	return hrp and (hrp.Position - cellCenter(cell)).Magnitude or 0
end

-- Checks that must pass before EVERY click. nil = fine; else "noblocks" | "unreadable" (these stop the job),
-- "notheld" (the block isn't selected any more: wait until it is) or "stopped".
local function checkBeforeClick(run)
	local owned = readOwned()
	if owned == nil then
		for _ = 1, 4 do -- a redrawn hotbar can make the count unreadable for a moment
			task.wait(0.2)
			if S.runId ~= run then
				return "stopped"
			end
			owned = readOwned()
			if owned ~= nil then
				break
			end
		end
	end
	if owned == nil then
		if itemGone() then
			return "noblocks" -- the stack left your hotbar: that's what running out looks like here
		end
		return "unreadable"
	end
	if owned <= 0 then
		return "noblocks"
	end
	if not ensureEquipped() then
		return "notheld"
	end
	return nil
end

-- What to tell the player, and what they can do about it (every problem stop can be resumed).
local function describeStop(code, extra, job, block)
	local resume = " Then press RESUME."
	if code == "noblocks" then
		return string.format("Out of blocks. Placed %d of %d - get more %s, then press RESUME.", job.placed, job.total, block.name), "error"
	elseif code == "unreadable" then
		return diag("ITEM", "I can't read your " .. block.name .. " count any more (did the hotbar change?). Stopped." .. resume), "error"
	elseif code == "nocursor" then
		return diag("INPUT", tostring(extra) .. "." .. resume), "error"
	elseif code == "misplaced" then
		return diag("PLACEMENT", tostring(extra) .. ". Stopped so I don't build in the wrong place. Look at the area." .. resume), "error"
	elseif code == "broke" then
		return diag("PLACEMENT", "A block DISAPPEARED when I clicked - the held item removes blocks instead of placing them. Stopped before breaking more. Select a placeable block." .. resume), "error"
	elseif code == "unseen" then
		return diag("DETECTION", "A block was used up (" .. tostring(extra) .. ") but I couldn't see it appear in the cell I aimed at, so I stopped. The game's block size / grid probably isn't what I detected - try clicking a placed block as Point A." .. resume), "error"
	elseif code == "mismatch" then
		return diag("PLACEMENT", "The game's own placement preview keeps pointing at a different cell than the one I computed (" .. tostring(extra) .. "), so my grid isn't lined up with the game's. Select the area again, clicking a block that is already placed as Point A."), "error"
	end
	-- "failed": several clicks in a row reached the game and nothing appeared
	return failureReason() .. resume, "error"
end

local function runWalk(run)
	local job = S.job
	local block = S.block -- (kept in a local: S.block can be cleared by the tick once STOP is pressed)
	if not job or not block then
		return
	end
	local cfg = {
		retryDelay = 1.5, closerBy = 2, maxFails = CONFIG.MAX_FAILS, maxStrays = CONFIG.MAX_STRAYS, maxMismatches = 12,
	}
	local areaMin, areaMax = job.mn, job.mx

	local synced = job.placed
	local function sync()
		S.placed, S.total = job.placed, job.total
		if job.placed > synced then
			S.placedAll += job.placed - synced
			synced = job.placed
		end
	end
	local prepEnv = {
		occupied = function(cell)
			return cellOccupied(cell)
		end,
		tick = function(i)
			if i % 150 == 0 then
				task.wait() -- never hitch the game while looking at a big area
				if S.runId ~= run then
					return true
				end
				refreshOverlapFilter()
			end
			return false
		end,
	}

	-- A fresh look at the world: which cells still need a block? (Existing blocks are skipped; blocks this job
	-- already placed keep counting, so a resumed job carries on from where it was.)
	refreshOverlapFilter()
	if not Core.walkPlan(job, prepEnv) then
		job.resumable = true
		return
	end
	sync()
	if job.total == 0 then
		S.needed = 0
		S.job = nil
		return stopBuild(run, "Nothing to place - the area is already full.", "info")
	end
	log("INFO", string.format("%s: %d of %d done, area %s", job.resumable and "auto place RESUMED" or "auto place started", job.placed, job.total, dimsText()))
	job.resumable = false

	local noted = false
	local needReplan, lastPlan = false, os.clock()
	while true do
		if S.runId ~= run then
			job.resumable = true -- STOP: the same button now says RESUME
			return
		end
		-- Look at the world again when it looks finished (that is only believed after a second look: no empty
		-- cell may be left), after a stray block, and every so often (somebody else may be building here too).
		if job.placed >= job.total or needReplan or os.clock() - lastPlan > 10 then
			refreshOverlapFilter()
			if not Core.walkPlan(job, prepEnv) then
				job.resumable = true
				return
			end
			needReplan, lastPlan = false, os.clock()
			sync()
			if job.placed >= job.total then
				break
			end
			render()
		end

		local acted = false
		local target = lookTarget()
		if target then
			local cell = target.cell
			local dist = distanceTo(cell)
			local ok = Core.walkAllow(job, cell, dist, os.clock(), cfg)
			if ok then
				refreshOverlapFilter()
				ok = not cellOccupied(cell) -- somebody built here: never click an occupied cell
			end
			if ok then
				local problem = checkBeforeClick(run)
				if problem == "stopped" then
					job.resumable = true
					return
				elseif problem == "notheld" then
					if not noted then
						noted = true
						status(string.format("Select %s again to carry on.", block.name), "info")
					end
					task.wait(0.3)
					acted = true
				elseif problem then
					job.resumable = true
					local text, kind = describeStop(problem, nil, job, block)
					return stopBuild(run, text, kind)
				else
					noted = false
					-- Steady? Look again a moment later: only click if the same spot is still under the cursor
					-- (you may be turning). Nothing yields between that second look and the click.
					task.wait(0.05)
					if S.runId ~= run then
						job.resumable = true
						return
					end
					local again = lookTarget()
					if again and Core.sameCell(again.cell, cell) and math.abs(again.x - target.x) <= 4 and math.abs(again.y - target.y) <= 4 then
						sync()
						local result, extra = walkPlace(again, run, areaMin, areaMax)
						if result == "stopped" then
							job.resumable = true
							return
						end
						acted = true
						-- (counted even if STOP was pressed during the click: the block really appeared)
						local action, code, info = Core.walkResult(job, cell, dist, os.clock(), result, extra, cfg)
						sync()
						if result == "stray" then
							needReplan = true -- a cell of the area got filled by the stray block: recount
						end
						if result == "placed" and S.verifiedName ~= norm(block.name) then
							S.verifiedName = norm(block.name)
							status("Placement VERIFIED: a real block appeared in the world. Keep walking and looking at the area...", "success")
						end
						render()
						if S.runId ~= run then
							job.resumable = true
							return
						end
						if action == "stop" then
							job.resumable = true
							local text, kind = describeStop(code, info, job, block)
							return stopBuild(run, text, kind)
						end
						task.wait(CONFIG.PLACE_DELAY)
					end
				end
			end
		end
		if not acted then
			task.wait(0.05)
		end
	end

	if S.runId ~= run then
		return
	end
	S.state = "done"
	status(string.format("Done! %d of %d blocks placed (each one confirmed in the world).", job.placed, job.total), "success")
	S.job = nil
	S.a, S.b = nil, nil
	setSelection() -- clears the orange outline
	Preview.clear()
end

local function autoBuild()
	if S.state == "building" then
		return
	end
	if S.pick then
		status("Finish selecting the area first.", "error")
		return
	end
	if not S.order then
		status("Select an area first.", "error")
		return
	end
	if S.worker then
		status("Still stopping the last build - one moment.", "info")
		return
	end
	if S.min.y ~= S.max.y then
		status("Only a flat area (one layer) is supported. Select the area again.", "error")
		return
	end

	-- 1) ITEM: what is in your hand? (a Tool, or the selected slot of the game's own hotbar)
	detectBlock(true) -- (forced: read the hotbar right now, don't wait for the usual throttle)
	if not S.block then
		if S.manualOwned ~= nil then
			-- Can't identify the item, but you typed a block count: go ahead, carefully. The first click
			-- is verified, and the build stops at once if a block gets removed instead of placed.
			S.block = { name = "held item", source = "unknown" }
			log("WARN", "item not detected - continuing because you typed a block count (the item can't be verified)")
		else
			status(diag("ITEM", "I can't tell which hotbar item you're holding: " .. tostring(S.itemWhy or "nothing detected") .. ". Select your block in the hotbar, or type how many you have into OWNED to build anyway. (Click this line to copy the log.)"), "error")
			return
		end
	end
	if S.block.source ~= "unknown" and looksLikeTool(S.block.name) then
		status(diag("ITEM", "'" .. S.block.name .. "' looks like a tool - clicking with it would break blocks. Select the block you want to place."), "error")
		return
	end

	-- 2) INPUT: can I click at all?
	if not Input.method then
		status(diag("INPUT", "This executor offers no way to click the mouse, so I can't place blocks for you."), "error")
		return
	end

	-- 3) still selected, and how many?
	if not ensureEquipped() then
		status(diag("ITEM", "'" .. S.block.name .. "' isn't the selected item any more. Select it in the hotbar."), "error")
		return
	end
	local owned, ownedSource = readOwned()
	if owned == nil then
		status(diag("ITEM", "I found '" .. S.block.name .. "' but can't read how many you have. Type the number into OWNED, then press AUTO PLACE."), "error")
		return
	end
	if owned <= 0 then
		status("You have no " .. S.block.name .. " left.", "error")
		return
	end
	if S.state == "building" or S.worker then
		return -- a second click arrived while the checks above were running
	end

	-- 4) The job: a stopped one is RESUMED (same area, same grid, same count); otherwise a new one starts at zero.
	local resuming = S.job ~= nil and S.job.resumable
	local aligned = false
	if not resuming then
		-- GRID: snap my grid to where the game's own blocks around the area really sit (same rectangle).
		-- Wrong cell positions come from a grid that is off by even a fraction of a block.
		aligned = calibrateNear()
		if not S.order then
			status("Select the area again - it changed while I was aligning the grid.", "error")
			return
		end
		S.ghostAdopted = false
		S.job = Core.newWalk(S.min, S.max)
	end

	log("INFO", string.format(
		"PREFLIGHT ok: item='%s' [%s] owned=%d (%s) | click=%s | grid=%.2f origin=(%.2f,%.2f,%.2f) %s | area=%s (%d cells) | %s",
		S.block.name, S.block.source or "?", owned, tostring(ownedSource), tostring(Input.method), S.grid.size,
		S.grid.origin.X, S.grid.origin.Y, S.grid.origin.Z, aligned and "aligned to nearby blocks" or "not re-aligned",
		dimsText(), S.count, resuming and "RESUMING" or "new job"
	))
	S.runId += 1
	local run = S.runId
	S.state = "building"
	S.worker = true -- true while a build coroutine is still alive (even just unwinding after STOP)
	if not resuming then
		S.placed, S.total = 0, 0 -- a new job: the counter always starts from zero
	end
	status(string.format("%s with %s x%d. Walk around the orange area (first person works) and look at the empty spots: a block is placed wherever your crosshair points at one.", resuming and "Resuming" or "Auto placing", S.block.name, owned), "info")
	task.spawn(function()
		safe("auto place", runWalk, run)
		S.worker = false
		if S.runId == run and S.state == "building" then
			S.state = "idle" -- the loop died unexpectedly; never leave the menu stuck
			if S.job then
				S.job.resumable = true
			end
			status("The build stopped because of an error (see the console). Press RESUME to carry on.", "error")
		end
		if S.stoppedRun == run and S.state ~= "building" then
			status(string.format("Stopped. %d blocks placed.%s", S.placed, S.job and " Press RESUME to carry on." or ""), "info")
		end
	end)
end

----------------------------------------------------------------------------------------------
-- 12. Picking the area (two clicks)
----------------------------------------------------------------------------------------------
local function pointerOverUI()
	local m = UIS:GetMouseLocation()
	return overFrameAt(UI.window, m.X, m.Y) or overFrameAt(UI.reopen, m.X, m.Y)
end

local function pickRay()
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local loc = UIS:GetMouseLocation()
	local ray = cam:ViewportPointToRay(loc.X, loc.Y)
	local ignore = characters()
	local params = rayParams()
	for _ = 1, 8 do
		params.FilterDescendantsInstances = ignore
		local res = workspace:Raycast(ray.Origin, ray.Direction * 1500, params)
		if not res then
			return nil
		end
		if seeThrough(res.Instance) then
			ignore[#ignore + 1] = res.Instance
		else
			return res
		end
	end
	return nil
end

local function cellFromHit(res)
	local s, o = S.grid.size, S.grid.origin
	local dir = CONFIG.SELECT_ADJACENT and 1 or -1
	local p = (res.Position + res.Normal * (s / 2) * dir - o) / s
	return { x = math.floor(p.X), y = math.floor(p.Y), z = math.floor(p.Z) }
end

local ACTION = "AutoBuilderPick"
local casBound = false
local handleClick
local function unbindPick()
	if casBound then
		pcall(function()
			CAS:UnbindAction(ACTION)
		end)
		casBound = false
	end
end
local function stopPicking()
	S.pick, S.hover = nil, nil
	unbindPick()
	Preview.setHover(nil)
end
onDestroy(unbindPick)

local function bindPick()
	unbindPick()
	local ok, err = pcall(function()
		CAS:BindActionAtPriority(ACTION, function(_, state)
			if not S.pick or pointerOverUI() then
				return Enum.ContextActionResult.Pass
			end
			if state == Enum.UserInputState.Begin then
				safe("pick click", handleClick)
			end
			return Enum.ContextActionResult.Sink -- stop the game from also reacting to this click
		end, false, 3000, Enum.UserInputType.MouseButton1)
	end)
	casBound = ok
	if not ok then
		log("WARN", "ContextActionService unavailable, using plain input events:", err)
	end
end
keep(UIS.InputBegan:Connect(function(input, processed)
	if casBound or processed or not S.pick then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not pointerOverUI() then
		safe("pick click", handleClick)
	end
end))

local function startPicking()
	if S.state == "building" then
		status("Press [ STOP ] first.", "error")
		return
	end
	if S.worker then
		status("Still stopping the last build - one moment.", "info")
		return
	end
	S.a, S.b, S.state = nil, nil, "idle"
	Preview.clear()
	setSelection()
	if not S.grid.confirmed then
		detectGrid()
	end
	-- With the block in hand, the game's own click handling could place a block at each corner you
	-- click while choosing the area. Put it away for the selection; AUTO PLACE takes it out again.
	detectBlock()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local putAway = false
	if hum and char:FindFirstChildOfClass("Tool") then
		putAway = pcall(function()
			hum:UnequipTools()
		end)
	end
	S.pick = "A"
	bindPick()
	if putAway then
		status("Click the first corner (Point A). Your block was put away while you choose.", "info")
	elseif S.block and S.block.slot then
		-- a custom-hotbar item can't be put away by a script: deselecting it is up to you
		status("Click the first corner (Point A). Tip: deselect your block while choosing, or the game may place one at each click.", "info")
	else
		status("Click the first corner (Point A).", "info")
	end
end

handleClick = function()
	local res = pickRay()
	if not res then
		status("Click a block or the ground.", "error")
		return
	end
	if S.pick == "A" then
		-- A placed block is the best source for the game's real grid.
		local part = res.Instance
		if part.Transparency < 0.15 and isCube(part) and (not S.grid.confirmed or math.abs(part.Size.X - S.grid.size) < 0.05) then
			adoptGrid(part)
		end
		S.a = cellFromHit(res)
		Preview.setA(S.a)
		S.pick = "B"
		S.hover = nil
		status("Now click the opposite corner (Point B).", "info")
	elseif S.pick == "B" then
		S.b = cellFromHit(res)
		if CONFIG.FLAT_ONLY then
			S.b.y = S.a.y -- flat: one layer, the height of point A
		end
		stopPicking()
		Preview.setA(nil)
		setSelection()
		if S.tooLarge then
			S.a, S.b = nil, nil
			setSelection()
		else
			status(string.format("Area selected: %s. Equip your block and press AUTO PLACE, then walk around the area.", dimsText()), "info")
			S.areaNote = true -- the next count replaces this with "N to fill, M already filled"
			task.spawn(countUnfilled)
		end
	end
end

-- live outline while you choose the second corner
keep(RunService.RenderStepped:Connect(function()
	if not ARB.alive or S.pick ~= "B" or not S.a then
		return
	end
	if pointerOverUI() then
		return
	end
	local res = pickRay()
	local cell = res and cellFromHit(res) or nil
	if cell and CONFIG.FLAT_ONLY then
		cell.y = S.a.y
	end
	if sameCell(cell, S.hover) or (cell == nil and S.hover == nil) then
		return
	end
	S.hover = cell
	Preview.setHover(cell)
	if cell then
		local mn, mx = boundsOf(S.a, cell)
		Preview.setArea(mn, mx)
	end
end))

-- STOP: ends picking, or stops the build right now (no further clicks are sent).
local function stop()
	if S.pick then
		stopPicking()
		Preview.setA(nil)
		Preview.setArea(S.min, S.max)
		status("Selection cancelled.", "info")
	elseif S.state == "building" then
		S.stoppedRun = S.runId
		S.runId += 1 -- the build loop sees this and exits before its next click
		S.state = "idle"
		if S.job then
			S.job.resumable = true -- the same button now says RESUME
		end
		status("Stopping...", "info")
		S.needed = nil
		task.spawn(countUnfilled)
	end
	render()
end

-- CLEAR SELECTION: forgets the area (and stops a build that is running first).
local function clearSelection()
	if S.state == "building" then
		stop()
	end
	if S.pick then
		stopPicking()
		Preview.setA(nil)
	end
	S.a, S.b = nil, nil
	S.state = "idle"
	setSelection() -- clears the area, the stopped job and the orange outline
	Preview.clear()
	status("Selection cleared.", "info")
	render()
end

-- The one big button: AUTO PLACE / RESUME when idle, STOP while it is building.
local function fillOrStop()
	if S.state == "building" then
		stop()
	else
		autoBuild()
	end
end

----------------------------------------------------------------------------------------------
-- 13. The menu (small, draggable, black + orange)
----------------------------------------------------------------------------------------------
local T = {
	bg = Color3.fromRGB(14, 14, 16),
	panel = Color3.fromRGB(26, 26, 30),
	panelHi = Color3.fromRGB(38, 38, 44),
	line = Color3.fromRGB(58, 58, 66),
	text = Color3.fromRGB(236, 236, 238),
	muted = Color3.fromRGB(150, 150, 158),
	dark = Color3.fromRGB(18, 14, 8),
	green = Color3.fromRGB(88, 214, 126),
	red = Color3.fromRGB(240, 82, 72),
	yellow = Color3.fromRGB(255, 205, 70),
	font = Enum.Font.Gotham,
	bold = Enum.Font.GothamBold,
}

local function new(class, props, kids)
	local o = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			o[k] = v
		end
	end
	if kids then
		for _, c in ipairs(kids) do
			c.Parent = o
		end
	end
	return o
end
local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end
local function stroke(color, th)
	return new("UIStroke", { Color = color, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(l, t, r, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
	})
end
local orderCount = setmetatable({}, { __mode = "k" })
local function add(parent, inst)
	local n = (orderCount[parent] or 0) + 1
	orderCount[parent] = n
	inst.LayoutOrder = n
	inst.Parent = parent
	return inst
end

local BSTYLE = {
	primary = { bg = ORANGE, text = T.dark, stroke = ORANGE, offBg = Color3.fromRGB(52, 52, 58), offText = T.muted, offStroke = Color3.fromRGB(70, 70, 78) },
	secondary = { bg = T.panelHi, text = T.text, stroke = ORANGE, offBg = T.panel, offText = T.muted, offStroke = T.line },
	danger = { bg = Color3.fromRGB(52, 28, 28), text = Color3.fromRGB(255, 130, 120), stroke = T.red, offBg = T.panel, offText = T.muted, offStroke = T.line },
}
local function button(text, kind, h)
	local st = BSTYLE[kind]
	local b = new("TextButton", {
		BackgroundColor3 = st.bg, BorderSizePixel = 0, AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, h or 32), Text = text, TextColor3 = st.text,
		Font = T.bold, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd,
	}, { corner(8), pad(6, 0, 6, 0) })
	local sk = stroke(st.stroke, 1.5)
	sk.Parent = b
	local o = { inst = b, enabled = true, hover = false }
	local function paint()
		if o.enabled then
			local bg = st.bg
			if o.hover then
				bg = bg:Lerp(Color3.new(1, 1, 1), 0.12)
			end
			b.BackgroundColor3, b.TextColor3, sk.Color = bg, st.text, st.stroke
		else
			b.BackgroundColor3, b.TextColor3, sk.Color = st.offBg, st.offText, st.offStroke
		end
	end
	b.MouseEnter:Connect(function()
		o.hover = true
		paint()
	end)
	b.MouseLeave:Connect(function()
		o.hover = false
		paint()
	end)
	b.Activated:Connect(function()
		if o.enabled and o.onClick then
			safe("button", o.onClick)
		end
	end)
	function o.setEnabled(v)
		v = v and true or false
		if o.enabled ~= v then
			o.enabled = v
			paint()
		end
	end
	return o
end

local function mountGui(gui)
	local order = { "gethui", "coregui", "playergui" }
	if CONFIG.CONTAINER ~= "auto" then
		order = { string.lower(CONFIG.CONTAINER) }
	end
	for _, kind in ipairs(order) do
		local ok, container = pcall(function()
			if kind == "gethui" then
				return gethui()
			elseif kind == "coregui" then
				return game:GetService("CoreGui")
			else
				return LocalPlayer:WaitForChild("PlayerGui", 10)
			end
		end)
		if ok and container then
			local ok2, err = pcall(function()
				gui.Parent = container
			end)
			if ok2 and gui.Parent == container then
				log("INFO", "menu mounted in:", kind)
				return kind
			end
			log("WARN", "could not parent the menu to " .. kind .. ":", err)
		else
			log("INFO", kind, "is not available here")
		end
	end
	return nil
end

local function buildGui()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local W = 250
	local state = { open = true, minimized = false }

	local gui = new("ScreenGui", {
		Name = "AutoBuilderGui", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999999, IgnoreGuiInset = true,
	})
	UI.gui = gui
	onDestroy(function()
		gui:Destroy()
	end)

	local window = new("Frame", {
		Name = "Window", BackgroundColor3 = T.bg, BorderSizePixel = 0, Active = true,
		Size = UDim2.new(0, W, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(math.max(8, vp.X - W - 16), 90), Parent = gui,
	}, { corner(12), stroke(ORANGE, 2) })
	UI.window = window

	local titleBar = new("Frame", { Name = "TitleBar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), Parent = window })
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -62, 1, 0),
		Text = '<font color="#FF8C14">ABOVE[RUINS]</font> | AUTO BUILDER', RichText = true, TextColor3 = T.text,
		Font = T.bold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Parent = titleBar,
	})
	local function titleButton(text, x)
		return new("TextButton", {
			BackgroundColor3 = T.panelHi, BorderSizePixel = 0, AutoButtonColor = false,
			Position = UDim2.new(1, x, 0.5, -10), Size = UDim2.fromOffset(22, 20), Text = text,
			TextColor3 = T.text, Font = T.bold, TextSize = 14, Parent = titleBar,
		}, { corner(6) })
	end
	local minBtn, closeBtn = titleButton("–", -52), titleButton("×", -26)

	-- Mount NOW, before the rest is built, so the menu shows up immediately.
	local kind = mountGui(gui)
	if not kind then
		log("ERROR", "Could not parent the menu anywhere. Try CONFIG.CONTAINER = 'playergui'.")
	end

	local body = new("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = window,
	}, {
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		pad(10, 2, 10, 10),
	})

	local reopen = new("TextButton", {
		Name = "Reopen", BackgroundColor3 = T.bg, BorderSizePixel = 0, AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -12), Size = UDim2.fromOffset(150, 30),
		Text = "AUTO BUILDER", TextColor3 = ORANGE, Font = T.bold, TextSize = 12, Visible = false, Parent = gui,
	}, { corner(8), stroke(ORANGE, 2) })
	UI.reopen = reopen

	local w = {}

	safe("build: controls", function()
		-- SELECT AREA
		w.areaBtn = button("[ SELECT AREA ]", "secondary", 32)
		w.areaBtn.onClick = startPicking
		add(body, w.areaBtn.inst)

		-- BLOCK: GRASS BLOCK  slot 4   (follows the item you have selected - Tool OR custom hotbar)
		-- The small grey word means "detected" only; it turns green "verified" once a real block has been
		-- seen appearing in the world. Detected is NOT the same as able to place.
		w.blockLabel = new("TextLabel", {
			BackgroundColor3 = T.panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 28),
			Text = "BLOCK: ...", TextColor3 = T.text, Font = T.bold, TextSize = 12, RichText = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, { corner(8), stroke(T.line, 1), pad(8, 0, 8, 0) })
		add(body, w.blockLabel)

		-- NEEDED: 36 | OWNED: 8
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26) })
		add(body, row)
		w.needed = new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0.5, -4, 1, 0), Text = "NEEDED: -", TextColor3 = T.text,
			Font = T.bold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
		})
		local ownWrap = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(0.5, 4, 0, 0), Size = UDim2.new(0.5, -4, 1, 0), Parent = row,
		})
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, -58, 1, 0), Text = "OWNED:", TextColor3 = T.text,
			Font = T.bold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = ownWrap,
		})
		-- Normally filled in automatically. If the game's inventory can't be read, click it and type the number.
		w.owned = new("TextBox", {
			BackgroundColor3 = T.panel, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 1), Size = UDim2.new(0, 56, 1, -2), Text = "", PlaceholderText = "?",
			TextColor3 = T.text, PlaceholderColor3 = T.muted, Font = T.bold, TextSize = 13, ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Center, Parent = ownWrap,
		}, { corner(6), stroke(T.line, 1) })
		w.owned.FocusLost:Connect(function()
			safe("owned box", function()
				local txt = string.gsub(w.owned.Text, "[,%s]", "")
				if txt == tostring(w.ownedShown or "") then
					render() -- just clicked in and out without editing: keep reading the game's real count
					return
				end
				if txt == "" then
					S.manualOwned = nil -- empty = read it from the game again
				else
					local n = tonumber(txt)
					if n and n >= 0 then
						S.manualOwned, S.manualAt = math.floor(n), S.placedAll
						log("INFO", "owned count typed in:", S.manualOwned)
					else
						status("Type a whole number of blocks.", "error")
					end
				end
				render()
			end)
		end)

		-- AUTO PLACE (becomes STOP while it is building, RESUME after a stop)
		w.autoBtn = button("[ AUTO PLACE ]", "primary", 36)
		w.autoBtn.onClick = fillOrStop
		add(body, w.autoBtn.inst)

		-- CLEAR SELECTION
		w.stopBtn = button("[ CLEAR SELECTION ]", "secondary", 28)
		w.stopBtn.onClick = clearSelection
		add(body, w.stopBtn.inst)

		-- one small status line (click it to copy the debug log)
		w.statusBtn = new("TextButton", {
			BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, Text = "", TextColor3 = T.muted, Font = T.font, TextSize = 12,
			TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		})
		add(body, w.statusBtn)
		w.statusBtn.Activated:Connect(function()
			local ok = pcall(function()
				setclipboard(table.concat(LOG.lines, "\n"))
			end)
			log("INFO", ok and "debug log copied to clipboard" or "setclipboard isn't available")
		end)
	end)

	-- window behaviour: drag by the title, minimize, close, reopen, toggle key
	local dragging, dragStart, startX, startY = false, nil, 0, 0
	keep(titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging, dragStart = true, input.Position
			startX, startY = window.Position.X.Offset, window.Position.Y.Offset
		end
	end))
	keep(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end))
	keep(UIS.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Position - dragStart
			local v = gui.AbsoluteSize
			window.Position = UDim2.fromOffset(
				math.clamp(startX + d.X, 40 - W, math.max(40 - W, v.X - 40)),
				math.clamp(startY + d.Y, 0, math.max(0, v.Y - 34))
			)
		end
	end))
	local function setOpen(v)
		state.open = v
		window.Visible = v
		reopen.Visible = not v
	end
	minBtn.Activated:Connect(function()
		state.minimized = not state.minimized
		body.Visible = not state.minimized
		minBtn.Text = state.minimized and "+" or "–"
	end)
	closeBtn.Activated:Connect(function()
		setOpen(false)
	end)
	reopen.Activated:Connect(function()
		setOpen(true)
	end)
	if CONFIG.TOGGLE_KEY then
		keep(UIS.InputBegan:Connect(function(input)
			if input.KeyCode == CONFIG.TOGGLE_KEY and UIS:GetFocusedTextBox() == nil then
				setOpen(not state.open)
			end
		end))
	end
	-- if the game removes the menu, put it back
	task.spawn(function()
		while ARB.alive do
			task.wait(2)
			if not ARB.alive then
				break
			end
			if gui.Parent == nil then
				log("WARN", "menu was removed by the game - re-mounting")
				mountGui(gui)
			end
		end
	end)

	-- show the current state
	local STATUS_COLOR = { info = T.muted, error = T.red, success = T.green }
	render = function()
		if not UI.ready then
			return
		end
		safe("render", function()
			local busy = S.state == "building"
			local owned = readOwned()
			local needed = busy and math.max(0, S.total - S.placed) or S.needed

			w.areaBtn.inst.Text = (S.pick == "A" and "[ CLICK POINT A... ]") or (S.pick == "B" and "[ CLICK POINT B... ]")
				or (S.min and ("[ SELECT AREA  ·  " .. dimsText() .. " ]")) or "[ SELECT AREA ]"
			w.areaBtn.setEnabled(not busy)

			if S.block then
				local verified = S.verifiedName == norm(S.block.name)
				local safeName = string.gsub(string.upper(S.block.name), "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" })
				local tag = verified and "verified"
					or (S.block.source == "unknown" and "unverified")
					or (S.block.slot and ("#" .. S.block.slot .. " detected") or "detected")
				w.blockLabel.Text = string.format('BLOCK: %s  <font color="%s">%s</font>', safeName, verified and "#58D67E" or "#8A8A92", tag)
			else
				w.blockLabel.Text = 'BLOCK: <font color="#F05248">not detected</font>'
			end
			w.needed.Text = "NEEDED: " .. (needed ~= nil and fmt(needed) or (S.order and "..." or "-"))

			if not w.owned:IsFocused() then
				w.ownedShown = owned ~= nil and tostring(owned) or ""
				w.owned.Text = w.ownedShown
			end
			if owned == nil then
				w.owned.TextColor3 = T.text
			elseif needed ~= nil and owned < needed then
				w.owned.TextColor3 = T.red
			else
				w.owned.TextColor3 = T.green
			end

			local label = "[ AUTO PLACE ]"
			if S.state == "building" then
				label = string.format("[ STOP  %s/%s ]", fmt(S.placed), fmt(S.total)) -- the same button stops it
			elseif S.worker then
				label = "[ STOPPING... ]" -- the last click is still being checked; no new build until it ends
			elseif S.job and S.job.resumable then
				label = string.format("[ RESUME  %s/%s ]", fmt(S.placed), fmt(S.total)) -- a stopped job carries on, it doesn't restart
			elseif S.state == "done" then
				label = string.format("[ DONE  %s/%s ]", fmt(S.placed), fmt(S.total))
			end
			w.autoBtn.inst.Text = label
			w.autoBtn.setEnabled(busy or (S.order ~= nil and not S.pick and not S.worker))
			w.stopBtn.setEnabled(busy or S.pick ~= nil or S.a ~= nil or S.min ~= nil)

			w.statusBtn.Text = "STATUS: " .. S.status
			w.statusBtn.TextColor3 = STATUS_COLOR[S.statusKind] or T.muted
			UI.reopen.Text = busy and string.format("AUTO BUILDER  %s/%s", fmt(S.placed), fmt(S.total)) or "AUTO BUILDER"
		end)
	end

	UI.ready = true
	log("INFO", "menu built")
	return kind
end

----------------------------------------------------------------------------------------------
-- 14. Start-up
----------------------------------------------------------------------------------------------
safe("buildGui", buildGui)
safe("Preview.init", Preview.init)
safe("Input.detect", Input.detect)
safe("detectGrid", function()
	if not detectGrid() then
		log("INFO", "grid not detected yet - it will be learned from the first block you click or place")
	end
end)
safe("detectBlock", detectBlock)
render()

-- 4x per second: follow the block in your hand, keep the numbers fresh, and (while you're only
-- planning) re-count the empty cells so NEEDED follows what you place yourself.
task.spawn(function()
	while ARB.alive do
		task.wait(0.25)
		safe("tick", function()
			local idle = S.state ~= "building"
			if idle then
				detectBlock()
			end
			if S.order and not S.pick and idle and S.count <= 3000 and os.clock() - (S.lastCount or 0) > 3 then
				S.lastCount = os.clock()
				task.spawn(countUnfilled)
			end
			render()
		end)
	end
end)

log("INFO", "version " .. VERSION)
status("READY. Select an area, equip your block, press AUTO PLACE.  (" .. VERSION .. ")", "info")
log("INFO", "ready - the menu should be visible now (top-right)")
