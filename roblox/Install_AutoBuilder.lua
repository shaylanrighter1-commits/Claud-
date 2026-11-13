--[[
	ABOVE[RUINS] | AUTO BUILDER — one-paste installer

	HOW TO USE
	  1. Open (or create) your place in Roblox Studio.
	  2. View tab -> turn on "Command Bar" (a text box appears at the bottom).
	  3. Copy this ENTIRE file, paste it into the Command Bar, press Enter.
	  4. Press Play (F5) and follow the README testing steps.

	It creates:
	  ReplicatedStorage/AutoBuilder/            Config, BuildPlanner
	  ServerScriptService/AutoBuilder/          AutoBuilderServer, StandaloneBackend
	  StarterPlayer/StarterPlayerScripts/AutoBuilderClient/   Main, UI, Preview

	Running it again replaces those scripts with fresh copies (any edits you made to them are overwritten).
]]

local FILES = {
	{
		path = { "ReplicatedStorage", "AutoBuilder" },
		name = "BuildPlanner",
		class = "ModuleScript",
		source = [==[
--!nonstrict
--[[
	BuildPlanner — pure geometry. No Roblox API calls, so it behaves identically on
	the client (orange preview) and the server (authoritative validation + placement).

	Vocabulary
	  cell   integer grid coordinate {x=,y=,z=}. One cell holds one block.
	  box    inclusive cell range {x1,y1,z1,x2,y2,z2}.
	  plan   the exact set of cells a build will fill, stored as a list of DISJOINT boxes.
	         The block count is simply the sum of the box volumes, so what the preview
	         draws, what the requirement calculator counts and what the builder places
	         can never disagree.

	Modes
	  floor   flat slab over the selected rectangle, `thickness` layers tall.
	  wall    vertical wall. layout "straight": runs along the longer side, starting at
	          Point A's edge and growing toward Point B by `thickness`.
	          layout "surround": all four sides of the rectangle.
	  fill    solid volume.
	  hollow  outer shell (walls + floor + ceiling) with an empty inside.

	Height: if Point A and Point B are on different layers, the build's height comes from
	those two points (`heightLocked = true`). Otherwise `options.height` is used.
]]

local BuildPlanner = {}

BuildPlanner.MODES = { floor = true, wall = true, fill = true, hollow = true }
BuildPlanner.LAYOUTS = { straight = true, surround = true }

-- Cell coordinates are packed into one exact double: 16 bits per axis.
local OFFSET = 32768
local SPAN = 65536
BuildPlanner.COORD_LIMIT = 32000

function BuildPlanner.pack(x, y, z)
	return ((y + OFFSET) * SPAN + (z + OFFSET)) * SPAN + (x + OFFSET)
end

function BuildPlanner.unpack(key)
	local xo = key % SPAN
	local rest = (key - xo) / SPAN
	local zo = rest % SPAN
	local yo = (rest - zo) / SPAN
	return xo - OFFSET, yo - OFFSET, zo - OFFSET
end

-- Integer in [lo, hi]; anything that is not a finite number becomes `default`.
function BuildPlanner.clampInt(value, lo, hi, default)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default
	end
	return math.clamp(math.floor(value), lo, hi)
end

local function validCoord(n)
	return type(n) == "number" and n == n and math.abs(n) <= BuildPlanner.COORD_LIMIT and n % 1 == 0
end

local function validCell(c)
	return type(c) == "table" and validCoord(c.x) and validCoord(c.y) and validCoord(c.z)
end

--[[
	BuildPlanner.plan(a, b, options, limits) -> plan | nil, errorCode
	  a, b     cells {x,y,z}
	  options  { mode, height, thickness, layout }
	  limits   { maxBlocks, maxDimension, maxHeight, maxThickness }
	Error codes: "BAD_REQUEST", "TOO_LARGE".
]]
function BuildPlanner.plan(a, b, options, limits)
	if not validCell(a) or not validCell(b) or type(options) ~= "table" or type(limits) ~= "table" then
		return nil, "BAD_REQUEST"
	end
	local mode = options.mode
	if not BuildPlanner.MODES[mode] then
		return nil, "BAD_REQUEST"
	end

	local minX, maxX = math.min(a.x, b.x), math.max(a.x, b.x)
	local minY, maxY = math.min(a.y, b.y), math.max(a.y, b.y)
	local minZ, maxZ = math.min(a.z, b.z), math.max(a.z, b.z)
	local w, selH, d = maxX - minX + 1, maxY - minY + 1, maxZ - minZ + 1

	local heightOpt = BuildPlanner.clampInt(options.height, 1, limits.maxHeight, 1)
	local thickOpt = BuildPlanner.clampInt(options.thickness, 1, limits.maxThickness, 1)
	local layout = (options.layout == "surround") and "surround" or "straight"

	local heightLocked = selH > 1
	local baseY = minY
	local H = heightLocked and selH or heightOpt
	if mode == "floor" then
		H = thickOpt
		heightLocked = false
	end

	if w > limits.maxDimension or d > limits.maxDimension or H > limits.maxHeight then
		return nil, "TOO_LARGE"
	end

	local boxes = {}
	local function add(x1, y1, z1, x2, y2, z2)
		boxes[#boxes + 1] = { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }
	end
	local topY = baseY + H - 1

	if mode == "floor" or mode == "fill" then
		add(minX, baseY, minZ, maxX, topY, maxZ)
	elseif mode == "hollow" then
		if H <= 2 or w <= 2 or d <= 2 then
			add(minX, baseY, minZ, maxX, topY, maxZ) -- too small to have an inside
		else
			add(minX, baseY, minZ, maxX, baseY, maxZ) -- floor
			add(minX, topY, minZ, maxX, topY, maxZ) -- ceiling
			local y1, y2 = baseY + 1, topY - 1
			add(minX, y1, minZ, maxX, y2, minZ) -- south wall (full width)
			add(minX, y1, maxZ, maxX, y2, maxZ) -- north wall (full width)
			add(minX, y1, minZ + 1, minX, y2, maxZ - 1) -- west wall (between the above)
			add(maxX, y1, minZ + 1, maxX, y2, maxZ - 1) -- east wall
		end
	elseif mode == "wall" then
		if layout == "straight" then
			if w >= d then -- wall runs along X
				local t = math.min(thickOpt, d)
				if a.z <= b.z then
					add(minX, baseY, minZ, maxX, topY, minZ + t - 1)
				else
					add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ)
				end
			else -- wall runs along Z
				local t = math.min(thickOpt, w)
				if a.x <= b.x then
					add(minX, baseY, minZ, minX + t - 1, topY, maxZ)
				else
					add(maxX - t + 1, baseY, minZ, maxX, topY, maxZ)
				end
			end
		else -- surround
			local t = thickOpt
			if 2 * t >= math.min(w, d) then
				add(minX, baseY, minZ, maxX, topY, maxZ) -- ring is thick enough to be solid
			else
				add(minX, baseY, minZ, maxX, topY, minZ + t - 1) -- south
				add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ) -- north
				add(minX, baseY, minZ + t, minX + t - 1, topY, maxZ - t) -- west
				add(maxX - t + 1, baseY, minZ + t, maxX, topY, maxZ - t) -- east
			end
		end
	end

	local count = 0
	local bMin = { x = math.huge, y = math.huge, z = math.huge }
	local bMax = { x = -math.huge, y = -math.huge, z = -math.huge }
	for _, box in ipairs(boxes) do
		count += (box.x2 - box.x1 + 1) * (box.y2 - box.y1 + 1) * (box.z2 - box.z1 + 1)
		bMin.x, bMin.y, bMin.z = math.min(bMin.x, box.x1), math.min(bMin.y, box.y1), math.min(bMin.z, box.z1)
		bMax.x, bMax.y, bMax.z = math.max(bMax.x, box.x2), math.max(bMax.y, box.y2), math.max(bMax.z, box.z2)
	end

	if count > limits.maxBlocks then
		return nil, "TOO_LARGE"
	end

	return {
		mode = mode,
		layout = layout,
		boxes = boxes,
		count = count,
		min = bMin,
		max = bMax,
		size = { x = bMax.x - bMin.x + 1, y = bMax.y - bMin.y + 1, z = bMax.z - bMin.z + 1 },
		height = H,
		heightLocked = heightLocked,
		-- the rectangle the player actually clicked (before mode/thickness were applied)
		selectionMin = { x = minX, y = minY, z = minZ },
		selectionMax = { x = maxX, y = maxY, z = maxZ },
	}
end

-- Calls fn(x, y, z) for every cell in the plan (no particular order).
function BuildPlanner.forEachCell(plan, fn)
	for _, box in ipairs(plan.boxes) do
		for y = box.y1, box.y2 do
			for z = box.z1, box.z2 do
				for x = box.x1, box.x2 do
					fn(x, y, z)
				end
			end
		end
	end
end

function BuildPlanner.contains(plan, x, y, z)
	for _, box in ipairs(plan.boxes) do
		if x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2 and z >= box.z1 and z <= box.z2 then
			return true
		end
	end
	return false
end

--[[
	Build order: bottom layer first, then row by row, alternating direction on every row
	(a "snake") so the structure grows in one continuous sweep instead of jumping around.
	Returns { n = count, xs = {...}, ys = {...}, zs = {...} } with parallel arrays.
]]
function BuildPlanner.buildOrder(plan)
	local keys = table.create(plan.count)
	local n = 0
	local minZ = plan.min.z
	for _, box in ipairs(plan.boxes) do
		for y = box.y1, box.y2 do
			for z = box.z1, box.z2 do
				local reversed = (z - minZ) % 2 == 1
				for x = box.x1, box.x2 do
					local xo = x + OFFSET
					if reversed then
						xo = SPAN - 1 - xo
					end
					n += 1
					keys[n] = ((y + OFFSET) * SPAN + (z + OFFSET)) * SPAN + xo
				end
			end
		end
	end
	table.sort(keys)

	local xs, ys, zs = table.create(n), table.create(n), table.create(n)
	for i = 1, n do
		local key = keys[i]
		local xo = key % SPAN
		local rest = (key - xo) / SPAN
		local zo = rest % SPAN
		local yo = (rest - zo) / SPAN
		local z = zo - OFFSET
		if (z - minZ) % 2 == 1 then
			xo = SPAN - 1 - xo
		end
		xs[i], ys[i], zs[i] = xo - OFFSET, yo - OFFSET, z
	end
	return { n = n, xs = xs, ys = ys, zs = zs }
end

----------------------------------------------------------------------------------
-- Grid helpers. Cell (cx,cy,cz) occupies the world cube
--   [origin + c*size, origin + (c+1)*size)   on each axis.
----------------------------------------------------------------------------------

function BuildPlanner.worldToCell(wx, wy, wz, size, ox, oy, oz)
	return math.floor((wx - ox) / size), math.floor((wy - oy) / size), math.floor((wz - oz) / size)
end

function BuildPlanner.cellCenter(cx, cy, cz, size, ox, oy, oz)
	return ox + (cx + 0.5) * size, oy + (cy + 0.5) * size, oz + (cz + 0.5) * size
end

-- World-space center and size of a box, for drawing it.
function BuildPlanner.boxWorld(box, size, ox, oy, oz)
	local x1, y1, z1 = ox + box.x1 * size, oy + box.y1 * size, oz + box.z1 * size
	local x2, y2, z2 = ox + (box.x2 + 1) * size, oy + (box.y2 + 1) * size, oz + (box.z2 + 1) * size
	return (x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2, x2 - x1, y2 - y1, z2 - z1
end

-- True when the whole plan lies inside [boundsMin, boundsMax] (inclusive cells).
function BuildPlanner.planInside(plan, boundsMin, boundsMax)
	return plan.min.x >= boundsMin.x
		and plan.min.y >= boundsMin.y
		and plan.min.z >= boundsMin.z
		and plan.max.x <= boundsMax.x
		and plan.max.y <= boundsMax.y
		and plan.max.z <= boundsMax.z
end

return BuildPlanner
]==],
	},
	{
		path = { "ReplicatedStorage", "AutoBuilder" },
		name = "Config",
		class = "ModuleScript",
		source = [==[
--!nonstrict
--[[
	ABOVE[RUINS] | AUTO BUILDER — shared configuration.

	Lives in ReplicatedStorage/AutoBuilder/Config so the server and the client read
	the same values. Everything marked "SERVER-ENFORCED" is re-checked by the server
	no matter what the client sends, so editing it on a client does nothing.
]]

local Config = {}

Config.TITLE = "ABOVE[RUINS] | AUTO BUILDER"
Config.REMOTES_FOLDER = "AutoBuilderRemotes"

----------------------------------------------------------------------------------
-- Build limits (SERVER-ENFORCED)
----------------------------------------------------------------------------------
Config.MAX_BLOCKS_PER_JOB = 20000 -- most blocks a single build may contain
Config.MAX_DIMENSION = 128 -- longest allowed side (in blocks) on X or Z
Config.MAX_HEIGHT = 64 -- tallest build (layers)
Config.MAX_THICKNESS = 16 -- thickest floor / wall (blocks)

----------------------------------------------------------------------------------
-- Construction speed (blocks placed per second)
----------------------------------------------------------------------------------
Config.DEFAULT_SPEED = 12 -- used when the player has not picked a preset
Config.MIN_SPEED = 1 -- SERVER-ENFORCED clamp
Config.MAX_SPEED = 60 -- SERVER-ENFORCED clamp
Config.MAX_PLACEMENTS_PER_FRAME = 10 -- hard cap so one lag spike cannot dump a huge batch
Config.SPEED_PRESETS = {
	{ label = "SLOW", blocksPerSecond = 5 },
	{ label = "NORMAL", blocksPerSecond = 12 },
	{ label = "FAST", blocksPerSecond = 30 },
	{ label = "TURBO", blocksPerSecond = 60 },
}

----------------------------------------------------------------------------------
-- World limits (SERVER-ENFORCED) — nothing may be built outside these, in studs
----------------------------------------------------------------------------------
Config.WORLD_MAX_ABS_STUDS = 8000 -- |X| and |Z| limit
Config.WORLD_MAX_Y_STUDS = 4000 -- highest allowed Y (lowest is workspace.FallenPartsDestroyHeight + 8)

----------------------------------------------------------------------------------
-- Selection behaviour
----------------------------------------------------------------------------------
-- true : clicking a block selects the EMPTY cell next to the face you clicked
--        (same as placing a block there). Clicking the ground selects the layer above it.
-- false: clicking a block selects that block's own cell.
Config.SELECT_ADJACENT_CELL = true
Config.TOGGLE_KEY = Enum.KeyCode.B -- PC shortcut that opens/closes the menu (set to nil to disable)

----------------------------------------------------------------------------------
-- Network cadence
----------------------------------------------------------------------------------
Config.INVENTORY_POLL_SECONDS = 0.5 -- how often the server checks for inventory changes
Config.JOB_UPDATE_INTERVAL = 0.1 -- max progress updates per second per build = 1 / this

----------------------------------------------------------------------------------
-- Build modes
----------------------------------------------------------------------------------
Config.MODE_ORDER = { "floor", "wall", "fill", "hollow" }
Config.MODE_LABELS = {
	floor = "FLOOR",
	wall = "WALL",
	fill = "FILL",
	hollow = "HOLLOW BOX",
}
Config.MODE_NOUNS = { -- used for "Building: Grass Floor"
	floor = "Floor",
	wall = "Wall",
	fill = "Fill",
	hollow = "Hollow Box",
}
Config.MODE_HELP = {
	floor = "Fills the rectangle with a flat slab. Thickness = how many layers.",
	wall = "Builds a vertical wall. Straight = along the longer side from Point A; Surround = all four sides.",
	fill = "Fills the whole volume solid. Click two points at different heights, or set the Height.",
	hollow = "Builds the outer walls, floor and ceiling and leaves the inside empty.",
}

----------------------------------------------------------------------------------
-- Theme (dark gray / black with orange highlights)
----------------------------------------------------------------------------------
Config.Theme = {
	bg = Color3.fromRGB(16, 16, 18),
	panel = Color3.fromRGB(27, 27, 31),
	panelHi = Color3.fromRGB(38, 38, 44),
	line = Color3.fromRGB(58, 58, 66),
	orange = Color3.fromRGB(255, 140, 20),
	orangeDark = Color3.fromRGB(200, 100, 0),
	text = Color3.fromRGB(236, 236, 238),
	muted = Color3.fromRGB(150, 150, 158),
	dark = Color3.fromRGB(18, 14, 8), -- text on orange
	green = Color3.fromRGB(88, 214, 126),
	red = Color3.fromRGB(240, 82, 72),
	yellow = Color3.fromRGB(255, 205, 70),
	gray = Color3.fromRGB(120, 120, 128),
	font = Enum.Font.Gotham,
	fontBold = Enum.Font.GothamBold,
}

----------------------------------------------------------------------------------
-- Messages. `code` strings are what the server sends back; the text is shown to players.
----------------------------------------------------------------------------------
Config.Messages = {
	NO_PLOT = "You don't own any land to build on.",
	OUTSIDE_LAND = "The build area reaches outside your land.",
	OUTSIDE_WORLD = "The build area is outside the playable world.",
	TOO_LARGE = "That build is too large (limit: %d blocks, %d wide).",
	NOTHING_TO_BUILD = "Nothing to build — every block in this area is already filled.",
	BUSY = "A build is already in progress. Cancel it first.",
	NO_JOB = "There is no active build.",
	BAD_REQUEST = "That build request isn't valid.",
	RATE_LIMITED = "Slow down — too many requests.",
	NOT_ALLOWED = "Auto Builder isn't available right now.",
	NOT_ENOUGH_RESOURCES = "NOT ENOUGH RESOURCES",
	PLACE_FAILED = "Block placement kept failing, so the build was stopped.",
	LAND_CHANGED = "You no longer own this land, so the build was stopped.",
	SERVER_ERROR = "Something went wrong on the server. Please try again.",
	NETWORK = "Couldn't reach the server. Please try again.",
}

function Config.message(code, extra)
	local text = Config.Messages[code]
	if not text then
		return tostring(code or "Unknown error")
	end
	if code == "TOO_LARGE" then
		return string.format(text, Config.MAX_BLOCKS_PER_JOB, Config.MAX_DIMENSION)
	end
	return text
end

----------------------------------------------------------------------------------
-- Small shared text helpers
----------------------------------------------------------------------------------

-- "Grass Block" -> "Grass Blocks";  "Wood Planks" stays "Wood Planks"
function Config.plural(name)
	if string.sub(string.lower(name), -1) == "s" then
		return name
	end
	return name .. "s"
end

-- "Grass Block" + "floor" -> "Grass Floor";  "Wood Planks" + "wall" -> "Wood Planks Wall"
function Config.buildLabel(materialName, mode)
	local short = string.gsub(materialName, "%s+[Bb]locks?$", "")
	return short .. " " .. (Config.MODE_NOUNS[mode] or "Build")
end

-- "NOT ENOUGH RESOURCES — COLLECT 45 MORE GRASS BLOCKS"
function Config.missingMessage(missing, materialName)
	return string.format(
		"%s — COLLECT %d MORE %s",
		Config.Messages.NOT_ENOUGH_RESOURCES,
		missing,
		string.upper(Config.plural(materialName))
	)
end

return Config
]==],
	},
	{
		path = { "ServerScriptService", "AutoBuilder" },
		name = "AutoBuilderServer",
		class = "Script",
		source = [==[
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
]==],
	},
	{
		path = { "ServerScriptService", "AutoBuilder" },
		name = "StandaloneBackend",
		class = "ModuleScript",
		source = [==[
--!nonstrict
--[[
	StandaloneBackend — a complete, self-contained "game" for the Auto Builder to run on.

	Why it exists: the Auto Builder never touches an inventory, a plot or a block directly.
	It only calls the functions in this module. This file implements them with a simple
	test world so you can try everything in a blank Baseplate place:

	  * every player gets their own square plot ("land") to build on
	  * a per-player block inventory (starter blocks + 4 resource crates to collect more)
	  * 4 block types and a real placement function that creates anchored Parts

	TO USE ANOTHER GAME'S SYSTEMS, replace this module (or edit the function bodies) so it
	still returns a table with these functions — AutoBuilderServer needs nothing else:

	  init()                                  one-time setup
	  onPlayerAdded(player)                   set up the player's plot / inventory
	  onPlayerRemoving(player)                clean up
	  canUse(player)            -> bool, reason?   gate the feature (gamepass, safe zone, ...)
	  getGrid()                 -> { size = studs per block, origin = Vector3 }
	  getMaterials()            -> { {id=, name=, color=Color3}, ... }   buildable blocks
	  getBlockCount(player, id) -> number
	  takeBlocks(player, id, n) -> bool       remove n from inventory; false (and change
	                                          nothing) if the player doesn't have n
	  giveBlocks(player, id, n)               put n back (used to refund a failed placement)
	  getPlot(player)           -> { min = Vector3, max = Vector3 } | nil   inclusive cells
	  isCellOwned(player, cell) -> bool       may this player build in this cell?
	  isCellOccupied(cell)      -> bool       is there already a block / structure here?
	  placeBlock(player, id, cell) -> bool    place ONE block. Must NOT touch the inventory
	                                          (the builder already took it) and must return
	                                          false if the cell is blocked.

	`cell` is a Vector3 of integers. Cell (cx,cy,cz) occupies the world cube
	[origin + c*size, origin + (c+1)*size) on each axis.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planner = require(ReplicatedStorage:WaitForChild("AutoBuilder"):WaitForChild("BuildPlanner"))

local Backend = {}

----------------------------------------------------------------------------------
-- Test-world settings
----------------------------------------------------------------------------------
local GRID_SIZE = 4 -- studs per block
local ORIGIN = Vector3.new(0, 1, 0) -- world position of cell (0,0,0)'s min corner = top of the plot pads
local PLOT_WIDTH = 16 -- cells (X and Z)
local PLOT_HEIGHT = 16 -- cells (Y) you may build up to
local PLOT_SPACING = 20 -- cells between plot starts along X (4 cell gap)
local PLOT_FIRST_Z = 8 -- cell row where plots begin (keeps them clear of the spawn)
local CRATE_AMOUNT = 25 -- blocks a resource crate hands out per use
local STARTER_BLOCKS = { grass_block = 75, dirt_block = 100, stone_block = 100, wood_planks = 0 }

local MATERIALS = {
	{ id = "grass_block", name = "Grass Block", color = Color3.fromRGB(91, 154, 76), robloxMaterial = Enum.Material.Grass },
	{ id = "dirt_block", name = "Dirt Block", color = Color3.fromRGB(121, 85, 58), robloxMaterial = Enum.Material.Ground },
	{ id = "stone_block", name = "Stone Block", color = Color3.fromRGB(127, 131, 138), robloxMaterial = Enum.Material.Slate },
	{ id = "wood_planks", name = "Wood Planks", color = Color3.fromRGB(180, 128, 82), robloxMaterial = Enum.Material.WoodPlanks },
}
local MATERIALS_BY_ID = {}
for _, m in ipairs(MATERIALS) do
	MATERIALS_BY_ID[m.id] = m
end

----------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------
local inventories = {} -- [Player] = { [materialId] = count }
local plots = {} -- [Player] = { slot, min, max, pad }
local slotOwner = {} -- [slotIndex] = Player
local placed = {} -- [packedCellKey] = Part
local blocksFolder = nil

local function cellKey(cell)
	return Planner.pack(cell.X, cell.Y, cell.Z)
end

----------------------------------------------------------------------------------
-- Inventory
----------------------------------------------------------------------------------
function Backend.getBlockCount(player, id)
	local inv = inventories[player]
	return inv and inv[id] or 0
end

function Backend.takeBlocks(player, id, n)
	local inv = inventories[player]
	if not inv or not MATERIALS_BY_ID[id] or type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
		return false
	end
	if (inv[id] or 0) < n then
		return false
	end
	inv[id] -= n
	return true
end

function Backend.giveBlocks(player, id, n)
	local inv = inventories[player]
	if not inv or not MATERIALS_BY_ID[id] or type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
		return
	end
	inv[id] = (inv[id] or 0) + n
end

function Backend.getMaterials()
	local list = {}
	for _, m in ipairs(MATERIALS) do
		list[#list + 1] = { id = m.id, name = m.name, color = m.color }
	end
	return list
end

----------------------------------------------------------------------------------
-- Grid, land and world queries
----------------------------------------------------------------------------------
function Backend.getGrid()
	return { size = GRID_SIZE, origin = ORIGIN }
end

function Backend.getPlot(player)
	local plot = plots[player]
	if not plot then
		return nil
	end
	return { min = plot.min, max = plot.max }
end

function Backend.isCellOwned(player, cell)
	local plot = plots[player]
	if not plot then
		return false
	end
	local mn, mx = plot.min, plot.max
	return cell.X >= mn.X and cell.X <= mx.X and cell.Y >= mn.Y and cell.Y <= mx.Y and cell.Z >= mn.Z and cell.Z <= mx.Z
end

function Backend.isCellOccupied(cell)
	return placed[cellKey(cell)] ~= nil
end

function Backend.canUse(player)
	return true
end

----------------------------------------------------------------------------------
-- Block placement (the ONE place a block is created)
----------------------------------------------------------------------------------
function Backend.placeBlock(player, id, cell)
	local def = MATERIALS_BY_ID[id]
	if not def or typeof(cell) ~= "Vector3" then
		return false
	end
	local key = cellKey(cell)
	if placed[key] then
		return false
	end

	local part = Instance.new("Part")
	part.Name = def.name
	part.Anchored = true
	part.CanCollide = true
	part.Size = Vector3.new(GRID_SIZE, GRID_SIZE, GRID_SIZE)
	part.Position = ORIGIN + (cell + Vector3.new(0.5, 0.5, 0.5)) * GRID_SIZE
	part.Material = def.robloxMaterial
	part.Color = def.color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("BlockId", id)
	part:SetAttribute("OwnerUserId", player.UserId)
	part.Parent = blocksFolder

	placed[key] = part
	return true
end

----------------------------------------------------------------------------------
-- Player lifecycle: plot + starter inventory
----------------------------------------------------------------------------------
local function freeSlot()
	local slot = 0
	while slotOwner[slot] do
		slot += 1
	end
	return slot
end

local function createPlot(player)
	local slot = freeSlot()
	slotOwner[slot] = player

	local minCell = Vector3.new(slot * PLOT_SPACING, 0, PLOT_FIRST_Z)
	local maxCell = minCell + Vector3.new(PLOT_WIDTH - 1, PLOT_HEIGHT - 1, PLOT_WIDTH - 1)

	local padSize = PLOT_WIDTH * GRID_SIZE
	local pad = Instance.new("Part")
	pad.Name = "Plot_" .. player.UserId
	pad.Anchored = true
	pad.Size = Vector3.new(padSize, 1, padSize)
	pad.Position = Vector3.new(ORIGIN.X + minCell.X * GRID_SIZE + padSize / 2, ORIGIN.Y - 0.5, ORIGIN.Z + minCell.Z * GRID_SIZE + padSize / 2)
	pad.Material = Enum.Material.Grass
	pad.Color = Color3.fromRGB(78, 140, 64)
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad:SetAttribute("OwnerUserId", player.UserId)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 6, -padSize / 2 + 4)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.Parent = pad
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = player.DisplayName .. "'s Land"
	label.TextColor3 = Color3.fromRGB(255, 140, 20)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = gui

	pad.Parent = workspace

	plots[player] = { slot = slot, min = minCell, max = maxCell, pad = pad }
	return plots[player]
end

local function teleportToPlot(player, plot)
	local character = player.Character
	if not character then
		return
	end
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return
	end
	local center = plot.pad.Position
	local target = Vector3.new(center.X, ORIGIN.Y + 5, ORIGIN.Z + plot.min.Z * GRID_SIZE + 6)
	character:PivotTo(CFrame.lookAt(target, target + Vector3.new(0, 0, 1)))
end

function Backend.onPlayerAdded(player)
	local inv = {}
	for _, m in ipairs(MATERIALS) do
		inv[m.id] = STARTER_BLOCKS[m.id] or 0
	end
	inventories[player] = inv

	local plot = createPlot(player)

	-- Move the player to their land the first time their character spawns.
	local moved = false
	local function onCharacter()
		if moved then
			return
		end
		moved = true
		task.spawn(teleportToPlot, player, plot)
	end
	if player.Character then
		onCharacter()
	end
	player.CharacterAdded:Connect(onCharacter)
end

function Backend.onPlayerRemoving(player)
	local plot = plots[player]
	if plot then
		for key, part in pairs(placed) do
			if part:GetAttribute("OwnerUserId") == player.UserId then
				part:Destroy()
				placed[key] = nil
			end
		end
		plot.pad:Destroy()
		slotOwner[plot.slot] = nil
		plots[player] = nil
	end
	inventories[player] = nil
end

----------------------------------------------------------------------------------
-- Resource crates: walk up and hold E / tap to collect blocks (so you can watch the
-- Auto Builder's "collect more blocks" counters update live).
----------------------------------------------------------------------------------
local function createCrates()
	local folder = Instance.new("Folder")
	folder.Name = "AutoBuilderCrates"
	folder.Parent = workspace

	local lastUse = {} -- [Player] = os.clock()
	for i, def in ipairs(MATERIALS) do
		local crate = Instance.new("Part")
		crate.Name = "Crate_" .. def.id
		crate.Anchored = true
		crate.Size = Vector3.new(6, 3, 6)
		crate.Position = Vector3.new(-18 + (i - 1) * 12, 1.5, 16)
		crate.Material = def.robloxMaterial
		crate.Color = def.color
		crate.TopSurface = Enum.SurfaceType.Smooth
		crate.Parent = folder

		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(160, 30)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 120
		gui.Parent = crate
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = def.name .. " Crate"
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextStrokeTransparency = 0.3
		text.Font = Enum.Font.GothamBold
		text.TextScaled = true
		text.Parent = gui

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Collect " .. CRATE_AMOUNT
		prompt.ObjectText = def.name .. "s"
		prompt.HoldDuration = 0.25
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = crate
		prompt.Triggered:Connect(function(player)
			local now = os.clock()
			if lastUse[player] and now - lastUse[player] < 0.2 then
				return
			end
			lastUse[player] = now
			Backend.giveBlocks(player, def.id, CRATE_AMOUNT)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastUse[player] = nil
	end)
end

function Backend.init()
	blocksFolder = Instance.new("Folder")
	blocksFolder.Name = "AutoBuilderBlocks"
	blocksFolder.Parent = workspace
	createCrates()
end

return Backend
]==],
	},
	{
		path = { "StarterPlayer", "StarterPlayerScripts", "AutoBuilderClient" },
		name = "Main",
		class = "LocalScript",
		source = [==[
--!nonstrict
--[[
	Auto Builder — client controller.

	Flow:  open menu -> SELECT BUILD AREA -> click Point A -> click Point B -> orange preview
	       -> pick mode / material -> see requirements -> START BUILDING -> watch it build.

	This script only PLANS and DISPLAYS. It never places blocks or changes inventory; it
	asks the server, and the server re-validates everything (ownership, counts, cells).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("AutoBuilder")
local Config = require(Shared:WaitForChild("Config"))
local Planner = require(Shared:WaitForChild("BuildPlanner"))
local UI = require(script.Parent:WaitForChild("UI"))
local Preview = require(script.Parent:WaitForChild("Preview"))
local T = Config.Theme

local remotes = ReplicatedStorage:WaitForChild(Config.REMOTES_FOLDER, 30)
if not remotes then
	warn("[AutoBuilder] Server remotes not found. Is AutoBuilderServer running in ServerScriptService?")
	return
end
local GetInfo = remotes:WaitForChild("GetInfo")
local Quote = remotes:WaitForChild("Quote")
local Start = remotes:WaitForChild("Start")
local Control = remotes:WaitForChild("Control")
local JobUpdate = remotes:WaitForChild("JobUpdate")
local InventoryUpdate = remotes:WaitForChild("Inventory")

----------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------
local S = {
	info = nil, -- GetInfo result (grid, materials, plot, limits...)
	phase = "idle", -- idle | pickA | pickB | selected
	a = nil, -- Vector3 cell
	b = nil,
	hover = nil, -- Vector3 cell under the cursor while picking
	hoverPlan = nil,
	hoverValid = false,
	opts = {
		mode = "floor",
		material = nil,
		height = 4,
		thickness = 1,
		layout = "straight",
		speed = Config.DEFAULT_SPEED,
	},
	plan = nil, -- local BuildPlanner plan for the preview
	planCode = nil, -- planner error code, if the plan failed
	planInvalid = false, -- plan reaches outside the player's land
	quote = nil, -- latest server quote
	inventory = {},
	job = nil, -- latest job snapshot from the server
	starting = false,
}

local ui, preview

local function fmt(n)
	local s = string.reverse(tostring(math.floor(n + 0.5)))
	s = string.gsub(s, "(%d%d%d)", "%1,")
	s = string.reverse(s)
	if string.sub(s, 1, 1) == "," then
		s = string.sub(s, 2)
	end
	return s
end

local function jobActive()
	return S.job ~= nil and (S.job.state == "building" or S.job.state == "paused")
end

local function cellTable(v)
	return { x = v.X, y = v.Y, z = v.Z }
end

local function inPlot(cell)
	local plot = S.info and S.info.plot
	if not plot then
		return false
	end
	local mn, mx = plot.min, plot.max
	return cell.X >= mn.X and cell.X <= mx.X and cell.Y >= mn.Y and cell.Y <= mx.Y and cell.Z >= mn.Z and cell.Z <= mx.Z
end

local function planInPlot(plan)
	local plot = S.info and S.info.plot
	return plot ~= nil and Planner.planInside(plan, cellTable(plot.min), cellTable(plot.max))
end

local function remoteOptions()
	local o = S.opts
	return { mode = o.mode, material = o.material, height = o.height, thickness = o.thickness, layout = o.layout }
end

local function dimText(plan)
	return string.format("%d × %d × %d  ·  %s blocks", plan.size.x, plan.size.y, plan.size.z, fmt(plan.count))
end

----------------------------------------------------------------------------------
-- View model: turns state into what the UI should show
----------------------------------------------------------------------------------
local function availableOf(materialId, fallback)
	local n = S.inventory[materialId]
	if n == nil then
		return fallback or 0
	end
	return n
end

local function buildViewModel()
	local info = S.info
	local opts = S.opts
	local active = jobActive()
	local job = S.job
	local vm = { opts = opts, materials = {}, jobActive = active }

	for _, m in ipairs(info.materials) do
		vm.materials[#vm.materials + 1] = { id = m.id, name = m.name, color = m.color, count = S.inventory[m.id] or 0 }
	end

	-- ---- requirements (only meaningful once an area is selected and quoted)
	local quote = S.quote
	local canStart = false
	local banner = nil
	local req = nil
	if S.phase == "selected" and not active then
		if S.planCode then
			banner = { kind = "error", text = Config.message(S.planCode) }
		elseif S.planInvalid then
			banner = { kind = "error", text = Config.message("OUTSIDE_LAND") }
		elseif quote and quote.ok then
			local available = availableOf(quote.materialId, quote.available)
			local missing = math.max(0, quote.required - available)
			req = {
				name = quote.materialName,
				required = quote.required,
				available = available,
				missing = missing,
				occupied = quote.occupied,
			}
			if quote.required == 0 then
				banner = { kind = "warn", text = Config.message("NOTHING_TO_BUILD") }
			elseif missing > 0 then
				banner = { kind = "error", text = Config.missingMessage(missing, quote.materialName) }
			else
				banner = { kind = "ok", text = "ALL MATERIALS AVAILABLE — READY TO BUILD" }
				canStart = not S.starting
			end
		elseif quote then
			banner = { kind = "error", text = quote.message or Config.message(quote.code) }
		end
	end
	vm.req, vm.banner = req, banner

	-- ---- status indicator
	local status
	if not info.allowed then
		status = { kind = "error", text = "UNAVAILABLE", hint = info.reason or Config.message("NOT_ALLOWED") }
	elseif not info.plot then
		status = { kind = "error", text = "NO LAND", hint = Config.message("NO_PLOT") }
	elseif active then
		if job.state == "building" then
			status = { kind = "building", text = "BUILDING", hint = "Placing blocks inside the orange preview." }
		elseif job.reason == "resources" then
			status = { kind = "missing", text = "MISSING MATERIALS", hint = "Collect more blocks, then press RESUME." }
		else
			status = { kind = "paused", text = "PAUSED", hint = "Press RESUME to continue building." }
		end
	elseif S.phase == "pickA" then
		status = { kind = "selecting", text = "SELECT POINT A", hint = "Click a block on your land to set the first corner." }
	elseif S.phase == "pickB" then
		status = {
			kind = "selecting",
			text = "SELECT POINT B",
			hint = "Click the opposite corner. The orange preview follows your cursor.",
		}
	elseif S.phase == "selected" then
		if banner and banner.kind == "error" then
			if req and req.missing > 0 then
				status = { kind = "missing", text = "MISSING MATERIALS", hint = banner.text }
			else
				status = { kind = "error", text = "CAN'T BUILD HERE", hint = banner.text }
			end
		elseif banner and banner.kind == "warn" then
			status = { kind = "error", text = "NOTHING TO BUILD", hint = banner.text }
		elseif canStart or (req and req.missing == 0) then
			status = { kind = "ready", text = "READY TO BUILD", hint = "Press START BUILDING." }
		else
			status = { kind = "idle", text = "CHECKING...", hint = "Calculating what this build needs." }
		end
	elseif job and job.state == "done" then
		status = { kind = "done", text = "BUILD COMPLETE", hint = "Select another area to keep building." }
	elseif job and job.state == "failed" then
		status = { kind = "error", text = "BUILD STOPPED", hint = job.message }
	elseif job and job.state == "cancelled" then
		status = { kind = "idle", text = "BUILD CANCELLED", hint = "Unused blocks are still in your inventory." }
	else
		status = { kind = "ready", text = "READY", hint = "Press SELECT BUILD AREA to begin." }
	end
	vm.status = status

	-- ---- area / selection text
	vm.pointA, vm.pointB = S.a, S.b
	if S.plan then
		vm.sizeText = dimText(S.plan)
	end
	vm.optionsVisible = S.phase == "selected" or active
	vm.optionsLocked = active
	vm.heightLocked = S.plan ~= nil and S.plan.heightLocked
	vm.shownHeight = (S.plan and S.plan.heightLocked) and S.plan.height or nil

	if S.phase == "idle" then
		vm.selectText = "SELECT BUILD AREA"
	elseif S.phase == "selected" then
		vm.selectText = "RESELECT BUILD AREA"
	else
		vm.selectText = "SELECTING..."
	end
	vm.selectEnabled = not active
	vm.resetVisible = S.phase ~= "idle" and not active

	-- ---- job card
	if job then
		vm.job = job
		local titles = {
			building = "AUTO BUILDER ACTIVE",
			paused = "AUTO BUILDER PAUSED",
			done = "BUILD COMPLETE",
			cancelled = "BUILD CANCELLED",
			failed = "BUILD STOPPED",
		}
		vm.jobTitle = titles[job.state] or "AUTO BUILDER"
		if job.state == "building" then
			vm.jobStatus, vm.jobStatusColor, vm.jobBarColor = "Constructing...", "#FF8C14", T.orange
		elseif job.state == "paused" and job.reason == "resources" then
			local remaining = job.remaining or (job.total - job.placed)
			local missing = math.max(0, remaining - availableOf(job.materialId))
			vm.jobStatus = (missing > 0) and Config.missingMessage(missing, job.materialName) or "Materials ready — press RESUME"
			vm.jobStatusColor, vm.jobBarColor = (missing > 0) and "#F05248" or "#58D67E", T.red
		elseif job.state == "paused" then
			vm.jobStatus, vm.jobStatusColor, vm.jobBarColor = "Paused", "#FFCD46", T.yellow
		elseif job.state == "done" then
			vm.jobStatus, vm.jobStatusColor, vm.jobBarColor = "Complete!", "#58D67E", T.green
		elseif job.state == "cancelled" then
			vm.jobStatus, vm.jobStatusColor, vm.jobBarColor = "Cancelled — unused blocks kept", "#9A9AA2", T.gray
		else
			vm.jobStatus, vm.jobStatusColor, vm.jobBarColor = job.message or "Stopped", "#F05248", T.red
		end
	end

	-- ---- footer buttons
	vm.startVisible = not active
	vm.startEnabled = canStart
	vm.pauseVisible = active
	vm.pauseIsResume = active and job.state == "paused"
	if active and job.state == "paused" and job.reason == "resources" then
		-- Resume stays disabled until the player has collected enough blocks to finish.
		local remaining = job.remaining or (job.total - job.placed)
		vm.pauseEnabled = availableOf(job.materialId) >= remaining
	else
		vm.pauseEnabled = active
	end
	vm.cancelEnabled = active or S.phase ~= "idle"
	vm.cancelText = "CANCEL BUILD"
	return vm
end

local function render()
	if ui and S.info then
		ui.render(buildViewModel())
	end
end

----------------------------------------------------------------------------------
-- Preview refresh
----------------------------------------------------------------------------------
local function refreshPreview()
	if not preview then
		return
	end
	if S.phase == "selected" and S.plan then
		preview:setBuild(S.plan, S.planInvalid and "invalid" or "valid", dimText(S.plan))
	elseif S.phase == "pickB" and S.hoverPlan then
		preview:setBuild(S.hoverPlan, S.hoverValid and "hover" or "invalid", dimText(S.hoverPlan))
	else
		preview:setBuild(nil)
	end
	preview:setBuilding(jobActive())
end

----------------------------------------------------------------------------------
-- Server quote (requirements). Debounced; stale answers are ignored.
----------------------------------------------------------------------------------
local quoteToken = 0
local queueQuote
queueQuote = function()
	quoteToken += 1
	local token = quoteToken
	S.quote = nil
	if not (S.phase == "selected" and S.plan and not S.planInvalid and S.opts.material) then
		return
	end
	task.delay(0.15, function()
		if token ~= quoteToken then
			return
		end
		local a, b, opts = S.a, S.b, remoteOptions()
		local ok, result = pcall(function()
			return Quote:InvokeServer(a, b, opts)
		end)
		if token ~= quoteToken then
			return
		end
		if ok and type(result) == "table" and result.code == "RATE_LIMITED" then
			task.delay(0.5, function()
				if token == quoteToken then
					queueQuote()
				end
			end)
			return
		end
		if ok and type(result) == "table" then
			S.quote = result
		else
			S.quote = { ok = false, code = "NETWORK", message = Config.message("NETWORK") }
		end
		render()
	end)
end

-- Recompute the local plan after anything about the selection or options changed.
local function recompute()
	S.plan, S.planCode, S.planInvalid = nil, nil, false
	if S.phase == "selected" and S.a and S.b and S.info then
		local plan, code = Planner.plan(cellTable(S.a), cellTable(S.b), S.opts, S.info.limits)
		S.plan, S.planCode = plan, code
		if plan then
			S.planInvalid = not planInPlot(plan)
		end
	end
	refreshPreview()
	queueQuote()
	render()
end

----------------------------------------------------------------------------------
-- World picking (mouse + touch)
----------------------------------------------------------------------------------
local function raycastAt(x, y, viewportSpace)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = viewportSpace and camera:ViewportPointToRay(x, y) or camera:ScreenPointToRay(x, y)
	local ignore = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			ignore[#ignore + 1] = p.Character
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
end

-- The grid cell a raycast hit refers to (snapped to the block grid).
local function cellFromHit(hit)
	local grid = S.info.grid
	local size = grid.size
	local direction = S.info.selectAdjacent and 1 or -1
	local p = (hit.Position + hit.Normal * (size / 2) * direction - grid.origin) / size
	return Vector3.new(math.floor(p.X), math.floor(p.Y), math.floor(p.Z))
end

local function pointerOverUI(screenX, screenY)
	-- GetMouseLocation includes the top-bar inset; GUI coordinates don't.
	local inset = GuiService:GetGuiInset()
	for _, obj in ipairs(playerGui:GetGuiObjectsAtPosition(screenX - inset.X, screenY - inset.Y)) do
		if obj:IsDescendantOf(ui.gui) then
			return true
		end
	end
	return false
end

local function stopHover()
	-- (hover connection is created once; it simply idles when not picking)
	if preview then
		preview:setHover(nil)
	end
	S.hover, S.hoverPlan = nil, nil
end

local function onPicked(cell)
	if not cell then
		ui.toast("Click a block on your land.", "error")
		return
	end
	if not inPlot(cell) then
		ui.toast("That spot is outside your land.", "error")
		return
	end
	if S.phase == "pickA" then
		S.a = cell
		S.phase = "pickB"
		preview:setPoint("A", cell)
		S.hover, S.hoverPlan = nil, nil
		refreshPreview()
		render()
	elseif S.phase == "pickB" then
		S.b = cell
		S.phase = "selected"
		preview:setPoint("B", cell)
		stopHover()
		preview:showLand(nil)
		recompute()
		ContextActionService:UnbindAction("AutoBuilderSelect")
	end
end

local function picking()
	return S.phase == "pickA" or S.phase == "pickB"
end

-- PC: bound at high priority so the same click can't also fire a held tool / the game's own
-- "place block" click handler while we're choosing corners.
local function bindPicking()
	ContextActionService:BindActionAtPriority("AutoBuilderSelect", function(_, inputState, input)
		if not picking() then
			return Enum.ContextActionResult.Pass
		end
		local loc = UserInputService:GetMouseLocation()
		if pointerOverUI(loc.X, loc.Y) then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			local hit = raycastAt(loc.X, loc.Y, true)
			onPicked(hit and cellFromHit(hit) or nil)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1)

	-- Don't leave a block/tool in hand: its click action would otherwise compete with ours.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools()
	end
end

-- Mouse hover: show the cell under the cursor (and a live preview while choosing Point B).
RunService.RenderStepped:Connect(function()
	if not picking() or not preview or not UserInputService.MouseEnabled then
		return
	end
	local loc = UserInputService:GetMouseLocation()
	if pointerOverUI(loc.X, loc.Y) then
		if S.hover then
			stopHover()
			refreshPreview()
		end
		return
	end
	local hit = raycastAt(loc.X, loc.Y, true)
	local cell = hit and cellFromHit(hit) or nil
	if cell == S.hover then
		return
	end
	S.hover = cell
	if not cell then
		preview:setHover(nil)
		S.hoverPlan = nil
		refreshPreview()
		return
	end
	local valid = inPlot(cell)
	preview:setHover(cell, valid)
	if S.phase == "pickB" and S.a then
		local plan = Planner.plan(cellTable(S.a), cellTable(cell), S.opts, S.info.limits)
		S.hoverPlan = plan
		S.hoverValid = valid and plan ~= nil and planInPlot(plan)
	else
		S.hoverPlan = nil
	end
	refreshPreview()
end)

-- Touch: a quick tap (not a camera drag) picks a corner.
local touchStarts = {}
UserInputService.InputBegan:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.Touch and not processed and picking() then
		touchStarts[input] = { position = input.Position, time = os.clock() }
	end
end)
UserInputService.InputEnded:Connect(function(input)
	local start = touchStarts[input]
	if not start then
		return
	end
	touchStarts[input] = nil
	if not picking() then
		return
	end
	if (input.Position - start.position).Magnitude <= 14 and os.clock() - start.time <= 0.45 then
		local hit = raycastAt(input.Position.X, input.Position.Y, false)
		onPicked(hit and cellFromHit(hit) or nil)
	end
end)

----------------------------------------------------------------------------------
-- Menu callbacks
----------------------------------------------------------------------------------
local function resetSelection()
	ContextActionService:UnbindAction("AutoBuilderSelect")
	S.phase = "idle"
	S.a, S.b = nil, nil
	S.hover, S.hoverPlan = nil, nil
	S.plan, S.planCode, S.planInvalid = nil, nil, false
	S.quote = nil
	quoteToken += 1
	if preview then
		preview:clear()
	end
end

local function startSelecting()
	if jobActive() then
		ui.toast("Finish or cancel the current build first.", "error")
		return
	end
	if not S.info.plot then
		ui.toast(Config.message("NO_PLOT"), "error")
		return
	end
	resetSelection()
	S.job = nil -- hide the previous build's summary card
	S.phase = "pickA"
	preview:showLand(S.info.plot.min, S.info.plot.max)
	bindPicking()
	recompute()
end

local callbacks = {}

callbacks.onSelectArea = startSelecting

callbacks.onReset = function()
	if jobActive() then
		return
	end
	resetSelection()
	render()
end

callbacks.onMode = function(mode)
	S.opts.mode = mode
	recompute()
end
callbacks.onLayout = function(layout)
	S.opts.layout = layout
	recompute()
end
callbacks.onHeight = function(value)
	S.opts.height = value
	recompute()
end
callbacks.onThickness = function(value)
	S.opts.thickness = value
	recompute()
end
callbacks.onMaterial = function(id)
	S.opts.material = id
	recompute()
end
callbacks.onSpeed = function(value)
	S.opts.speed = value
	render()
end

callbacks.onStart = function()
	if S.starting or jobActive() or S.phase ~= "selected" or not S.plan or S.planInvalid then
		return
	end
	S.starting = true
	render()
	local a, b, opts, speed = S.a, S.b, remoteOptions(), S.opts.speed
	local ok, result = pcall(function()
		return Start:InvokeServer(a, b, opts, speed)
	end)
	S.starting = false
	if not ok or type(result) ~= "table" then
		ui.toast(Config.message("NETWORK"), "error")
	elseif not result.ok then
		ui.toast(result.message or Config.message(result.code), "error")
		queueQuote() -- numbers may have changed; refresh them
	else
		-- The server also pushes JobUpdate events; don't let this (older) copy overwrite a newer one.
		if S.job == nil then
			S.job = result.job
		end
		preview:setBuilding(true)
	end
	render()
end

local function control(action)
	local ok, result = pcall(function()
		return Control:InvokeServer(action)
	end)
	if not ok or type(result) ~= "table" then
		ui.toast(Config.message("NETWORK"), "error")
	elseif not result.ok then
		ui.toast(result.message or Config.message(result.code), "error")
	end
end

callbacks.onPause = function()
	control("pause")
end
callbacks.onResume = function()
	control("resume")
end
callbacks.onCancel = function()
	if jobActive() then
		control("cancel")
	elseif S.phase ~= "idle" then
		resetSelection()
		render()
	end
end

----------------------------------------------------------------------------------
-- Server events
----------------------------------------------------------------------------------
local function onJobUpdate(snapshot)
	local previous = S.job and S.job.state
	local previousReason = S.job and S.job.reason
	S.job = snapshot

	if snapshot.state == "done" then
		ui.toast("Build complete!", "success")
		resetSelection() -- removes the orange preview
	elseif snapshot.state == "cancelled" then
		if previous == "building" or previous == "paused" then
			ui.toast("Build cancelled. Unused blocks stay in your inventory.", "info")
		end
		recompute() -- re-quote: what was already placed no longer needs blocks
	elseif snapshot.state == "failed" then
		ui.toast(snapshot.message or "The build was stopped.", "error")
		recompute()
	elseif snapshot.state == "paused" and snapshot.reason == "resources" and previousReason ~= "resources" then
		ui.toast(snapshot.message or "Out of materials — build paused.", "error")
	end
	-- Progress ticks arrive ~10x/second; rebuilding the preview each time would keep
	-- restarting its pulse animation, so only refresh it when the state actually changed.
	if snapshot.state ~= previous or snapshot.reason ~= previousReason then
		refreshPreview()
	end
	render()
end

----------------------------------------------------------------------------------
-- Startup
----------------------------------------------------------------------------------
local function applyInfo(info)
	S.info = info
	S.inventory = info.inventory or {}
	if preview then
		preview:setGrid(info.grid.size, info.grid.origin)
	end
	local valid = false
	for _, m in ipairs(info.materials) do
		if m.id == S.opts.material then
			valid = true
		end
	end
	if not valid then
		S.opts.material = info.materials[1] and info.materials[1].id or nil
	end
	if info.job and not S.job then
		S.job = info.job
	end
end

local function fetchInfo()
	local ok, info = pcall(function()
		return GetInfo:InvokeServer()
	end)
	if ok and type(info) == "table" and info.ok then
		return info
	end
	return nil
end

local info = fetchInfo()
while not info do
	task.wait(1.5)
	info = fetchInfo()
end

ui = UI.new(playerGui, callbacks)
preview = Preview.new()
applyInfo(info)
ui.setMaterials(info.materials)
render()

-- Connected only now that the UI exists, so an early event can't hit a nil `ui`.
JobUpdate.OnClientEvent:Connect(onJobUpdate)
InventoryUpdate.OnClientEvent:Connect(function(counts)
	if type(counts) == "table" then
		S.inventory = counts
		render()
	end
end)

-- If the player's land wasn't ready yet, keep asking until it is.
if not info.plot then
	task.spawn(function()
		while S.info and not S.info.plot do
			task.wait(2)
			local fresh = fetchInfo()
			if fresh then
				applyInfo(fresh)
				render()
			end
		end
	end)
end

if Config.TOGGLE_KEY then
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Config.TOGGLE_KEY then
			ui.toggle()
		end
	end)
end

ui.toast("Auto Builder ready — press SELECT BUILD AREA.", "info")
]==],
	},
	{
		path = { "StarterPlayer", "StarterPlayerScripts", "AutoBuilderClient" },
		name = "Preview",
		class = "ModuleScript",
		source = [==[
--!nonstrict
--[[
	Preview — everything the player sees in the 3D world while planning a build.
	All parts are created on the CLIENT only (nobody else sees them, they never touch the
	server) and have CanQuery = false so clicks and the camera ray pass straight through.

	  * orange translucent boxes + bright orange edges = the exact blocks that will be built
	    (a list of boxes, so a hollow box / wall draws only the parts that get filled)
	  * Point A / Point B markers: glowing cell + vertical beacon + floating label
	  * hover ghost: the cell under the cursor while picking a point
	  * faint outline of the player's land while picking points
	  * a floating "20 x 14 x 1 - 280 blocks" label
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("AutoBuilder")
local Config = require(Shared:WaitForChild("Config"))
local Planner = require(Shared:WaitForChild("BuildPlanner"))

local T = Config.Theme

local Preview = {}
Preview.__index = Preview

local STYLES = {
	valid = { color = T.orange, fill = 0.78, lineT = 0, line = 1 },
	hover = { color = T.orange, fill = 0.9, lineT = 0.25, line = 0.6 },
	invalid = { color = T.red, fill = 0.75, lineT = 0, line = 1 },
}

local function newPart(parent, name)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Locked = true
	part.Massless = true
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function newOutline(part, color, thickness, transparency)
	local box = Instance.new("SelectionBox")
	box.Adornee = part
	box.Color3 = color
	box.LineThickness = thickness
	box.Transparency = transparency or 0
	box.SurfaceTransparency = 1
	box.Parent = part
	return box
end

local function newBillboard(part, text, width, offset)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = part
	gui.Size = UDim2.fromOffset(width, 28)
	gui.StudsOffsetWorldSpace = offset or Vector3.zero
	gui.AlwaysOnTop = true
	gui.MaxDistance = 600
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = T.bg
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.Text = text
	label.TextColor3 = T.orange
	label.Font = T.fontBold
	label.TextSize = 14
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = T.orange
	stroke.Thickness = 1.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = label
	return gui, label
end

function Preview.new()
	local self = setmetatable({}, Preview)

	local folder = Instance.new("Folder")
	folder.Name = "AutoBuilderPreview"
	folder.Parent = workspace
	self.folder = folder

	self.size = 4
	self.origin = Vector3.zero
	self.pool = {} -- reusable { part, outline } entries for build boxes
	self.activeBoxes = 0
	self.building = false
	self.pulseTweens = {}

	-- Point markers
	self.markers = {}
	for _, key in ipairs({ "A", "B" }) do
		local cube = newPart(folder, "Point" .. key)
		cube.Color = T.orange
		cube.Material = Enum.Material.Neon
		cube.Transparency = 0.55
		local outline = newOutline(cube, T.orange, 0.14, 0)
		local beacon = newPart(folder, "Beacon" .. key)
		beacon.Color = T.orange
		beacon.Material = Enum.Material.Neon
		beacon.Transparency = 0.45
		local _, label = newBillboard(cube, "POINT " .. key, 84, Vector3.new(0, 4, 0))
		self.markers[key] = { cube = cube, beacon = beacon, outline = outline }
		cube.Parent = nil
		beacon.Parent = nil
	end

	-- Hover ghost
	local ghost = newPart(folder, "Hover")
	ghost.Transparency = 0.8
	ghost.Color = T.orange
	local ghostOutline = newOutline(ghost, T.orange, 0.08, 0.1)
	ghost.Parent = nil
	self.ghost = { part = ghost, outline = ghostOutline }

	-- Land outline
	local land = newPart(folder, "Land")
	land.Transparency = 1
	local landOutline = newOutline(land, T.orange, 0.06, 0.55)
	land.Parent = nil
	self.land = { part = land, outline = landOutline }

	-- Dimension label
	local anchor = newPart(folder, "DimLabel")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	local _, dimText = newBillboard(anchor, "", 230, Vector3.zero)
	anchor.Parent = nil
	self.dim = { part = anchor, label = dimText }

	return self
end

function Preview:setGrid(size, origin)
	self.size = size
	self.origin = origin
end

local function cellCenter(self, cell)
	return self.origin + (Vector3.new(cell.X, cell.Y, cell.Z) + Vector3.new(0.5, 0.5, 0.5)) * self.size
end

----------------------------------------------------------------------------------
-- Build boxes (the orange preview)
----------------------------------------------------------------------------------
function Preview:_getEntry(i)
	local entry = self.pool[i]
	if not entry then
		local part = newPart(self.folder, "BuildBox")
		part.Color = T.orange
		part.Parent = nil
		entry = { part = part, outline = newOutline(part, T.orange, 0.1, 0) }
		self.pool[i] = entry
	end
	return entry
end

function Preview:_stopPulse()
	for _, tween in ipairs(self.pulseTweens) do
		tween:Cancel()
	end
	self.pulseTweens = {}
end

function Preview:_refreshPulse()
	self:_stopPulse()
	-- stopping a tween leaves the part mid-pulse, so put the fill back to normal first
	for i = 1, self.activeBoxes do
		self.pool[i].part.Transparency = self.fill or 0.78
	end
	if not self.building then
		return
	end
	for i = 1, self.activeBoxes do
		local part = self.pool[i].part
		local tween = TweenService:Create(
			part,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = math.min(0.95, part.Transparency + 0.12) }
		)
		tween:Play()
		self.pulseTweens[#self.pulseTweens + 1] = tween
	end
end

-- plan: BuildPlanner plan | nil.  style: "valid" | "hover" | "invalid".  text: label string.
function Preview:setBuild(plan, style, text)
	self:_stopPulse()
	if not plan then
		for i = 1, self.activeBoxes do
			self.pool[i].part.Parent = nil
		end
		self.activeBoxes = 0
		self.dim.part.Parent = nil
		return
	end

	local st = STYLES[style] or STYLES.valid
	self.fill = st.fill
	local o, s = self.origin, self.size
	local inflate = 0.06 -- sits just outside the real blocks so it never z-fights with them

	for i, box in ipairs(plan.boxes) do
		local entry = self:_getEntry(i)
		local cx, cy, cz, sx, sy, sz = Planner.boxWorld(box, s, o.X, o.Y, o.Z)
		entry.part.Size = Vector3.new(sx + inflate, sy + inflate, sz + inflate)
		entry.part.Position = Vector3.new(cx, cy, cz)
		entry.part.Color = st.color
		entry.part.Transparency = st.fill
		entry.outline.Color3 = st.color
		entry.outline.Transparency = st.lineT
		entry.outline.LineThickness = (style == "hover") and 0.06 or 0.1
		entry.part.Parent = self.folder
	end
	for i = #plan.boxes + 1, self.activeBoxes do
		self.pool[i].part.Parent = nil
	end
	self.activeBoxes = #plan.boxes

	-- Floating size label above the build
	local mx, my, mz = Planner.boxWorld({
		x1 = plan.min.x, y1 = plan.min.y, z1 = plan.min.z,
		x2 = plan.max.x, y2 = plan.max.y, z2 = plan.max.z,
	}, s, o.X, o.Y, o.Z)
	local topY = o.Y + (plan.max.y + 1) * s
	self.dim.part.Position = Vector3.new(mx, topY + 1.5, mz)
	self.dim.label.Text = text or ""
	self.dim.label.TextColor3 = st.color
	self.dim.part.Parent = (text and text ~= "") and self.folder or nil

	self:_refreshPulse()
end

function Preview:setBuilding(on)
	self.building = on and true or false
	self:_refreshPulse()
end

----------------------------------------------------------------------------------
-- Point A / B markers, hover ghost, land outline
----------------------------------------------------------------------------------
function Preview:setPoint(key, cell)
	local m = self.markers[key]
	if not cell then
		m.cube.Parent = nil
		m.beacon.Parent = nil
		return
	end
	local center = cellCenter(self, cell)
	m.cube.Size = Vector3.new(self.size, self.size, self.size) * 1.02
	m.cube.Position = center
	local beaconHeight = self.size * 6
	m.beacon.Size = Vector3.new(0.4, beaconHeight, 0.4)
	m.beacon.Position = center + Vector3.new(0, self.size / 2 + beaconHeight / 2, 0)
	m.cube.Parent = self.folder
	m.beacon.Parent = self.folder
end

function Preview:setHover(cell, valid)
	local g = self.ghost
	if not cell then
		g.part.Parent = nil
		return
	end
	local color = valid and T.orange or T.red
	g.part.Color = color
	g.outline.Color3 = color
	g.part.Size = Vector3.new(self.size, self.size, self.size) * 1.02
	g.part.Position = cellCenter(self, cell)
	g.part.Parent = self.folder
end

-- plotMin / plotMax: inclusive cell bounds (Vector3), or nil to hide.
function Preview:showLand(plotMin, plotMax)
	local land = self.land
	if not plotMin or not plotMax then
		land.part.Parent = nil
		return
	end
	local o, s = self.origin, self.size
	local minW = o + Vector3.new(plotMin.X, plotMin.Y, plotMin.Z) * s
	local maxW = o + Vector3.new(plotMax.X + 1, plotMax.Y + 1, plotMax.Z + 1) * s
	land.part.Size = maxW - minW
	land.part.Position = (minW + maxW) / 2
	land.part.Parent = self.folder
end

function Preview:clear()
	self:setBuild(nil)
	self:setPoint("A", nil)
	self:setPoint("B", nil)
	self:setHover(nil)
	self:showLand(nil)
	self.building = false
end

function Preview:destroy()
	self:_stopPulse()
	self.folder:Destroy()
end

return Preview
]==],
	},
	{
		path = { "StarterPlayer", "StarterPlayerScripts", "AutoBuilderClient" },
		name = "UI",
		class = "ModuleScript",
		source = [==[
--!nonstrict
--[[
	UI — builds the Auto Builder menu entirely from code (no assets to import) and exposes
	one method, ui.render(viewModel), that makes the interface match the current state.

	The UI holds no game logic. It reports what the player clicked through the `callbacks`
	table and the controller (Main.client.lua) decides what to do.

	callbacks: onSelectArea, onReset, onStart, onPause, onResume, onCancel,
	           onMode(mode), onLayout(layout), onHeight(n), onThickness(n),
	           onMaterial(id), onSpeed(blocksPerSecond)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("AutoBuilder"):WaitForChild("Config"))
local T = Config.Theme

local UI = {}

----------------------------------------------------------------------------------
-- Tiny construction helpers
----------------------------------------------------------------------------------
local function create(className, props, children)
	local inst = Instance.new(className)
	if props then
		for key, value in pairs(props) do
			inst[key] = value
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	return inst
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, thickness, transparency)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(left, top, right, bottom)
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, left),
		PaddingTop = UDim.new(0, top),
		PaddingRight = UDim.new(0, right),
		PaddingBottom = UDim.new(0, bottom),
	})
end

local function vlist(gap)
	return create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap),
		FillDirection = Enum.FillDirection.Vertical,
	})
end

local function tween(inst, seconds, props, style, direction)
	TweenService:Create(
		inst,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	):Play()
end

-- Parents `inst` under `parent` and gives it the next LayoutOrder, so children appear
-- in the order they were created.
local orderCounters = setmetatable({}, { __mode = "k" })
local function add(parent, inst)
	local n = (orderCounters[parent] or 0) + 1
	orderCounters[parent] = n
	inst.LayoutOrder = n
	inst.Parent = parent
	return inst
end

local function fmt(n) -- 12345 -> "12,345"
	local s = tostring(math.floor(n + 0.5))
	local out = string.reverse(s)
	out = string.gsub(out, "(%d%d%d)", "%1,")
	out = string.reverse(out)
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

local function makeLabel(parent, text, opts)
	opts = opts or {}
	local fixed = opts.height ~= nil
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, opts.height or 0),
		AutomaticSize = fixed and Enum.AutomaticSize.None or Enum.AutomaticSize.Y,
		Text = text,
		TextColor3 = opts.color or T.text,
		Font = opts.bold and T.fontBold or T.font,
		TextSize = opts.size or 14,
		TextWrapped = true,
		RichText = opts.rich or false,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left,
		TextYAlignment = fixed and Enum.TextYAlignment.Center or Enum.TextYAlignment.Top,
	})
	if parent then
		add(parent, label)
	end
	return label
end

----------------------------------------------------------------------------------
-- Controls
----------------------------------------------------------------------------------
local BUTTON_STYLES = {
	primary = {
		bg = T.orange, text = T.dark, stroke = T.orange,
		offBg = Color3.fromRGB(52, 52, 58), offText = T.muted, offStroke = Color3.fromRGB(70, 70, 78),
	},
	secondary = {
		bg = T.panelHi, text = T.text, stroke = T.orange,
		offBg = T.panel, offText = T.muted, offStroke = T.line,
	},
	danger = {
		bg = Color3.fromRGB(52, 28, 28), text = Color3.fromRGB(255, 130, 120), stroke = T.red,
		offBg = T.panel, offText = T.muted, offStroke = T.line,
	},
}

local function makeButton(text, kind, height)
	local style = BUTTON_STYLES[kind]
	local btn = create("TextButton", {
		BackgroundColor3 = style.bg,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, height or 38),
		Text = text,
		TextColor3 = style.text,
		Font = T.fontBold,
		TextSize = 14,
	}, { corner(8) })
	local outline = stroke(style.stroke, 1.5)
	outline.Parent = btn

	local obj = { instance = btn, enabled = true, hover = false }
	local function apply()
		local bg, textColor, lineColor
		if obj.enabled then
			bg = style.bg
			if obj.hover then
				bg = bg:Lerp(Color3.new(1, 1, 1), 0.12)
			end
			textColor, lineColor = style.text, style.stroke
		else
			bg, textColor, lineColor = style.offBg, style.offText, style.offStroke
		end
		tween(btn, 0.12, { BackgroundColor3 = bg, TextColor3 = textColor })
		tween(outline, 0.12, { Color = lineColor })
	end
	btn.MouseEnter:Connect(function()
		obj.hover = true
		apply()
	end)
	btn.MouseLeave:Connect(function()
		obj.hover = false
		apply()
	end)
	btn.Activated:Connect(function()
		if obj.enabled and obj.onClick then
			obj.onClick()
		end
	end)
	function obj.setEnabled(value)
		value = value and true or false
		if obj.enabled ~= value then
			obj.enabled = value
			apply()
		end
	end
	function obj.setText(value)
		btn.Text = value
	end
	return obj
end

-- Row of mutually exclusive buttons. items = { {value=, label=}, ... }
local function makeSegmented(items, onChange)
	local n = #items
	local gap = 4
	local frame = create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34) })
	local obj = { instance = frame, value = nil, locked = false, onChange = onChange }
	local buttons = {}

	local function refresh()
		for _, b in ipairs(buttons) do
			local selected = b.value == obj.value
			tween(b.btn, 0.12, {
				BackgroundColor3 = selected and T.orange or T.panelHi,
				TextColor3 = selected and T.dark or T.text,
				BackgroundTransparency = obj.locked and 0.55 or 0,
				TextTransparency = obj.locked and 0.5 or 0,
			})
		end
	end

	for i, item in ipairs(items) do
		local btn = create("TextButton", {
			BackgroundColor3 = T.panelHi,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = UDim2.new((i - 1) / n, (i - 1) * gap / n, 0, 0),
			Size = UDim2.new(1 / n, -gap * (n - 1) / n, 1, 0),
			Text = item.label,
			TextColor3 = T.text,
			Font = T.fontBold,
			TextScaled = true,
		}, {
			corner(8),
			create("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 8 }),
			padding(4, 0, 4, 0),
		})
		btn.Parent = frame
		btn.Activated:Connect(function()
			if not obj.locked and obj.onChange then
				obj.onChange(item.value)
			end
		end)
		buttons[i] = { btn = btn, value = item.value }
	end

	function obj.set(value)
		if obj.value == value then
			return
		end
		obj.value = value
		refresh()
	end
	function obj.setLocked(locked)
		locked = locked and true or false
		if obj.locked ~= locked then
			obj.locked = locked
			refresh()
		end
	end
	return obj
end

-- "Label   [-] 4 [+]"
local function makeStepper(labelText, minValue, maxValue, onChange)
	local row = create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34) })
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -140, 1, 0),
		Text = labelText,
		TextColor3 = T.text,
		Font = T.font,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	local box = create("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(132, 34),
		Parent = row,
	})

	local obj = { instance = row, value = minValue, locked = false }

	local function smallButton(text, x)
		return create("TextButton", {
			BackgroundColor3 = T.panelHi,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = UDim2.fromOffset(x, 0),
			Size = UDim2.fromOffset(34, 34),
			Text = text,
			TextColor3 = T.orange,
			Font = T.fontBold,
			TextSize = 20,
			Parent = box,
		}, { corner(8) })
	end
	local minus = smallButton("-", 0)
	local plus = smallButton("+", 98)
	local valueLabel = create("TextLabel", {
		BackgroundColor3 = T.bg,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(36, 0),
		Size = UDim2.fromOffset(60, 34),
		Text = tostring(minValue),
		TextColor3 = T.text,
		Font = T.fontBold,
		TextSize = 16,
		Parent = box,
	}, { corner(8), stroke(T.line, 1) })

	local function step(delta)
		if obj.locked or not onChange then
			return
		end
		local nextValue = math.clamp(obj.value + delta, minValue, maxValue)
		if nextValue ~= obj.value then
			onChange(nextValue)
		end
	end
	minus.Activated:Connect(function()
		step(-1)
	end)
	plus.Activated:Connect(function()
		step(1)
	end)

	function obj.set(value)
		obj.value = value
		valueLabel.Text = tostring(value)
	end
	function obj.setLabel(text)
		label.Text = text
	end
	function obj.setLocked(locked)
		obj.locked = locked and true or false
		local t = obj.locked and 0.5 or 0
		minus.TextTransparency, plus.TextTransparency, valueLabel.TextTransparency = t, t, t
	end
	return obj
end

local function makeBar(height)
	local track = create("Frame", {
		BackgroundColor3 = Color3.fromRGB(12, 12, 14),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
	}, { corner(height / 2), stroke(T.line, 1) })
	local fill = create("Frame", {
		BackgroundColor3 = T.orange,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = track,
	}, { corner(height / 2) })
	local obj = { instance = track }
	function obj.set(fraction, color)
		tween(fill, 0.2, { Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0) })
		if color then
			fill.BackgroundColor3 = color
		end
	end
	return obj
end

local function makeSection(parent, title)
	local frame = create("Frame", {
		BackgroundColor3 = T.panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, { corner(10), stroke(T.line, 1), padding(12, 10, 12, 12), vlist(8) })
	add(parent, frame)
	local titleLabel
	if title then
		titleLabel = makeLabel(frame, title, { bold = true, size = 12, color = T.orange })
	end
	return frame, titleLabel
end

----------------------------------------------------------------------------------
-- UI.new
----------------------------------------------------------------------------------
local STATUS_COLORS = {
	idle = T.gray,
	selecting = T.orange,
	ready = T.green,
	missing = T.red,
	building = T.orange,
	paused = T.yellow,
	error = T.red,
	done = T.green,
}
local PULSING = { selecting = true, building = true }

function UI.new(playerGui, cb)
	local self = {}
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	local TITLE_H, FOOTER_H = 44, 108
	local width = isTouch and math.clamp(viewport.X - 24, 260, 360) or 380
	local height = math.clamp(viewport.Y - 120, 320, 640)
	local state = { open = true, minimized = false }

	local gui = create("ScreenGui", {
		Name = "AutoBuilderGui",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 40,
		IgnoreGuiInset = false,
	})

	------------------------------------------------------------------ window
	local window = create("Frame", {
		Name = "Window",
		BackgroundColor3 = T.bg,
		BorderSizePixel = 0,
		Active = true, -- sinks clicks so they never reach the 3D world / other game systems
		ClipsDescendants = true,
		Size = UDim2.fromOffset(width, height),
		Position = UDim2.fromOffset(isTouch and (viewport.X - width) / 2 or (viewport.X - width - 12), isTouch and 6 or 60),
		Parent = gui,
	}, { corner(14), stroke(T.orange, 2) })
	local windowScale = create("UIScale", { Scale = 1, Parent = window })

	-- title bar (transparent so the window's rounded corners show through)
	local titleBar = create("Frame", {
		Name = "TitleBar",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TITLE_H),
		Parent = window,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -90, 1, -3),
		Text = '<font color="#FF8C14">ABOVE[RUINS]</font>  |  AUTO BUILDER',
		RichText = true,
		TextColor3 = T.text,
		Font = T.fontBold,
		TextSize = isTouch and 13 or 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = titleBar,
	})

	local function titleButton(text, xOffset)
		return create("TextButton", {
			BackgroundColor3 = T.panelHi,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = UDim2.new(1, xOffset, 0.5, -15),
			Size = UDim2.fromOffset(30, 28),
			Text = text,
			TextColor3 = T.text,
			Font = T.fontBold,
			TextSize = 18,
			Parent = titleBar,
		}, { corner(8) })
	end
	local minimizeButton = titleButton("–", -72)
	local closeButton = titleButton("×", -38)
	closeButton.MouseEnter:Connect(function()
		tween(closeButton, 0.12, { BackgroundColor3 = T.red })
	end)
	closeButton.MouseLeave:Connect(function()
		tween(closeButton, 0.12, { BackgroundColor3 = T.panelHi })
	end)
	minimizeButton.MouseEnter:Connect(function()
		tween(minimizeButton, 0.12, { BackgroundColor3 = T.orangeDark })
	end)
	minimizeButton.MouseLeave:Connect(function()
		tween(minimizeButton, 0.12, { BackgroundColor3 = T.panelHi })
	end)

	-- thin progress strip along the bottom of the title bar (visible even when minimized)
	local strip = create("Frame", {
		BackgroundColor3 = T.line,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -3),
		Size = UDim2.new(1, 0, 0, 3),
		Parent = titleBar,
	})
	local stripFill = create("Frame", {
		BackgroundColor3 = T.orange,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = strip,
	})

	------------------------------------------------------------------ body
	local body = create("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TITLE_H),
		Size = UDim2.new(1, 0, 1, -(TITLE_H + FOOTER_H)),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = T.orange,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = window,
	}, { vlist(10), padding(12, 10, 12, 10) })

	------------------------------------------------------------------ status card
	local statusCard = makeSection(body, nil)
	local statusRow = create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22) })
	add(statusCard, statusRow)
	local statusDot = create("Frame", {
		BackgroundColor3 = T.gray,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		Parent = statusRow,
	}, { corner(6) })
	local statusText = create("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -22, 1, 0),
		Text = "READY",
		TextColor3 = T.text,
		Font = T.fontBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = statusRow,
	})
	local statusHint = makeLabel(statusCard, "", { size = 12, color = T.muted })
	local statusPulse = nil
	local currentStatusKind = nil

	------------------------------------------------------------------ area section
	local areaSection = makeSection(body, "BUILD AREA")
	local areaRow = create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40) })
	add(areaSection, areaRow)
	local selectButton = makeButton("SELECT BUILD AREA", "primary", 40)
	selectButton.instance.Parent = areaRow
	local resetButton = makeButton("RESET", "secondary", 40)
	resetButton.instance.AnchorPoint = Vector2.new(1, 0)
	resetButton.instance.Position = UDim2.new(1, 0, 0, 0)
	resetButton.instance.Size = UDim2.new(0, 84, 1, 0)
	resetButton.instance.Parent = areaRow
	local pointALabel = makeLabel(areaSection, "", { rich = true, size = 13, color = T.muted })
	local pointBLabel = makeLabel(areaSection, "", { rich = true, size = 13, color = T.muted })
	local sizeLabel = makeLabel(areaSection, "", { rich = true, size = 13, color = T.muted })

	------------------------------------------------------------------ options section
	local optionsSection = makeSection(body, "BUILD OPTIONS")

	local modeItems = {}
	for _, mode in ipairs(Config.MODE_ORDER) do
		modeItems[#modeItems + 1] = { value = mode, label = Config.MODE_LABELS[mode] }
	end
	local modeSegmented = makeSegmented(modeItems, function(mode)
		cb.onMode(mode)
	end)
	add(optionsSection, modeSegmented.instance)
	local modeHelp = makeLabel(optionsSection, "", { size = 12, color = T.muted })

	local layoutCaption = makeLabel(optionsSection, "WALL LAYOUT", { bold = true, size = 11, color = T.muted })
	local layoutSegmented = makeSegmented({
		{ value = "straight", label = "STRAIGHT WALL" },
		{ value = "surround", label = "SURROUND" },
	}, function(layout)
		cb.onLayout(layout)
	end)
	add(optionsSection, layoutSegmented.instance)

	local heightStepper = makeStepper("Height (layers)", 1, Config.MAX_HEIGHT, function(v)
		cb.onHeight(v)
	end)
	add(optionsSection, heightStepper.instance)
	local heightNote = makeLabel(optionsSection, "Height comes from your two points.", { size = 12, color = T.yellow })

	local thicknessStepper = makeStepper("Thickness", 1, Config.MAX_THICKNESS, function(v)
		cb.onThickness(v)
	end)
	add(optionsSection, thicknessStepper.instance)

	makeLabel(optionsSection, "MATERIAL", { bold = true, size = 11, color = T.muted })
	local chipsFrame = create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		create("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 6),
		}),
	})
	add(optionsSection, chipsFrame)
	local chips = {} -- [materialId] = { button, nameLabel, countLabel, outline, count, name }

	local speedCaption = makeLabel(optionsSection, "BUILD SPEED", { bold = true, size = 11, color = T.muted })
	local speedItems = {}
	for _, preset in ipairs(Config.SPEED_PRESETS) do
		speedItems[#speedItems + 1] = { value = preset.blocksPerSecond, label = preset.label }
	end
	local speedSegmented = makeSegmented(speedItems, function(v)
		cb.onSpeed(v)
	end)
	add(optionsSection, speedSegmented.instance)

	------------------------------------------------------------------ requirements section
	local reqSection = makeSection(body, "BUILD REQUIREMENTS")
	local reqRequired = makeLabel(reqSection, "", { rich = true, size = 14, color = T.muted })
	local reqAvailable = makeLabel(reqSection, "", { rich = true, size = 14, color = T.muted })
	local reqMissing = makeLabel(reqSection, "", { rich = true, size = 14, color = T.muted })
	local reqProgress = makeLabel(reqSection, "", { rich = true, size = 14, color = T.muted })
	local reqBar = makeBar(10)
	add(reqSection, reqBar.instance)
	local reqSkip = makeLabel(reqSection, "", { size = 12, color = T.yellow })
	local bannerFrame = create("Frame", {
		BackgroundColor3 = Color3.fromRGB(46, 24, 24),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, { corner(8), padding(10, 8, 10, 8) })
	local bannerStroke = stroke(T.red, 1.5)
	bannerStroke.Parent = bannerFrame
	add(reqSection, bannerFrame)
	local bannerText = makeLabel(bannerFrame, "", { bold = true, size = 13, color = T.red })

	------------------------------------------------------------------ job section
	local jobSection, jobTitle = makeSection(body, "AUTO BUILDER ACTIVE")
	local jobBuilding = makeLabel(jobSection, "", { rich = true, size = 14, color = T.muted })
	local jobPlaced = makeLabel(jobSection, "", { rich = true, size = 14, color = T.muted })
	local jobProgress = makeLabel(jobSection, "", { rich = true, size = 14, color = T.muted })
	local jobStatus = makeLabel(jobSection, "", { rich = true, size = 14, color = T.muted })
	local jobBar = makeBar(12)
	add(jobSection, jobBar.instance)

	------------------------------------------------------------------ footer
	local footer = create("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 1, -FOOTER_H),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		Parent = window,
	}, { vlist(8), padding(12, 10, 12, 10) })
	-- thin line above the footer (child of the window, not the footer, so the list layout ignores it)
	local divider = create("Frame", {
		BackgroundColor3 = T.line,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -FOOTER_H),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = window,
	})

	local startButton = makeButton("START BUILDING", "primary", 40)
	add(footer, startButton.instance)
	local pauseButton = makeButton("PAUSE", "secondary", 40)
	add(footer, pauseButton.instance)
	local cancelButton = makeButton("CANCEL BUILD", "danger", 40)
	add(footer, cancelButton.instance)

	selectButton.onClick = function()
		cb.onSelectArea()
	end
	resetButton.onClick = function()
		cb.onReset()
	end
	startButton.onClick = function()
		cb.onStart()
	end
	cancelButton.onClick = function()
		cb.onCancel()
	end
	-- pause/resume is one button whose meaning depends on state
	local pauseMode = "pause"
	pauseButton.onClick = function()
		if pauseMode == "resume" then
			cb.onResume()
		else
			cb.onPause()
		end
	end

	------------------------------------------------------------------ reopen button + toast
	local reopen = create("TextButton", {
		Name = "Reopen",
		BackgroundColor3 = T.bg,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(isTouch and 128 or 170, 36),
		Text = "AUTO BUILDER",
		TextColor3 = T.orange,
		Font = T.fontBold,
		TextSize = 14,
		Visible = false,
		Parent = gui,
	}, { corner(10), stroke(T.orange, 2) })

	local toast = create("Frame", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(math.min(440, viewport.X - 24), 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.bg,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, { corner(10), padding(14, 10, 14, 10) })
	local toastStroke = stroke(T.orange, 2)
	toastStroke.Parent = toast
	local toastLabel = create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = "",
		TextColor3 = T.text,
		Font = T.fontBold,
		TextSize = 14,
		TextWrapped = true,
		ZIndex = 21,
		Parent = toast,
	})

	gui.Parent = playerGui
	self.gui = gui

	----------------------------------------------------------------- behaviour
	local function clampWindowPosition(x, y)
		local vp = gui.AbsoluteSize
		local w = window.AbsoluteSize.X
		x = math.clamp(x, 80 - w, math.max(80 - w, vp.X - 80))
		y = math.clamp(y, 0, math.max(0, vp.Y - TITLE_H))
		return x, y
	end

	-- drag by the title bar (mouse or touch)
	local dragging, dragStart, startX, startY = false, nil, 0, 0
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startX, startY = window.Position.X.Offset, window.Position.Y.Offset
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
		then
			local delta = input.Position - dragStart
			local x, y = clampWindowPosition(startX + delta.X, startY + delta.Y)
			window.Position = UDim2.fromOffset(x, y)
		end
	end)

	local function applyMinimized()
		local targetHeight = state.minimized and (TITLE_H + 3) or height
		tween(window, 0.2, { Size = UDim2.fromOffset(width, targetHeight) })
		body.Visible = not state.minimized
		footer.Visible = not state.minimized
		if divider then
			divider.Visible = not state.minimized
		end
		minimizeButton.Text = state.minimized and "+" or "–"
	end

	function self.setMinimized(value)
		state.minimized = value and true or false
		applyMinimized()
	end

	function self.setOpen(open)
		state.open = open and true or false
		if state.open then
			window.Visible = true
			reopen.Visible = false
			windowScale.Scale = 0.92
			tween(windowScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		else
			tween(windowScale, 0.12, { Scale = 0.92 })
			reopen.Visible = true
			task.delay(0.13, function()
				if not state.open then
					window.Visible = false
				end
			end)
		end
	end

	function self.isOpen()
		return state.open
	end

	function self.toggle()
		self.setOpen(not state.open)
	end

	minimizeButton.Activated:Connect(function()
		self.setMinimized(not state.minimized)
	end)
	closeButton.Activated:Connect(function()
		self.setOpen(false)
	end)
	reopen.Activated:Connect(function()
		self.setOpen(true)
		if state.minimized then
			self.setMinimized(false)
		end
	end)

	-- keep the window usable if the screen size changes (rotation, resizing)
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			local vp = camera.ViewportSize
			width = isTouch and math.clamp(vp.X - 24, 260, 360) or 380
			height = math.clamp(vp.Y - 120, 320, 640)
			window.Size = UDim2.fromOffset(width, state.minimized and (TITLE_H + 3) or height)
			local x, y = clampWindowPosition(window.Position.X.Offset, window.Position.Y.Offset)
			window.Position = UDim2.fromOffset(x, y)
		end)
	end

	----------------------------------------------------------------- toast
	local toastToken = 0
	function self.toast(text, kind)
		toastToken += 1
		local token = toastToken
		local color = (kind == "error" and T.red) or (kind == "success" and T.green) or T.orange
		toastLabel.Text = text
		toastStroke.Color = color
		toast.Visible = true
		toast.Position = UDim2.new(0.5, 0, 0, 26)
		toast.BackgroundTransparency = 0.05
		toastLabel.TextTransparency = 0
		toastStroke.Transparency = 0
		tween(toast, 0.2, { Position = UDim2.new(0.5, 0, 0, 12) }, Enum.EasingStyle.Back)
		task.delay(3.4, function()
			if token ~= toastToken then
				return
			end
			tween(toast, 0.3, { BackgroundTransparency = 1 })
			tween(toastLabel, 0.3, { TextTransparency = 1 })
			tween(toastStroke, 0.3, { Transparency = 1 })
			task.delay(0.32, function()
				if token == toastToken then
					toast.Visible = false
				end
			end)
		end)
	end

	----------------------------------------------------------------- materials
	function self.setMaterials(materials)
		for _, chip in pairs(chips) do
			chip.button:Destroy()
		end
		chips = {}
		for _, material in ipairs(materials) do
			local button = create("TextButton", {
				BackgroundColor3 = T.panelHi,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Size = UDim2.new(0.5, -4, 0, 40), -- -4 (not -3) so rounding can't push the second chip onto a new row
				Text = "",
			}, { corner(8) })
			local outline = stroke(T.line, 1.5)
			outline.Parent = button
			create("Frame", {
				BackgroundColor3 = material.color,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 9, 0.5, 0),
				Size = UDim2.fromOffset(18, 18),
				Parent = button,
			}, { corner(4), stroke(Color3.new(0, 0, 0), 1, 0.5) })
			local nameLabel = create("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(34, 0),
				Size = UDim2.new(1, -86, 1, 0),
				Text = material.name,
				TextColor3 = T.text,
				Font = T.font,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = button,
			})
			local countLabel = create("TextLabel", {
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -8, 0, 0),
				Size = UDim2.new(0, 48, 1, 0),
				Text = "0",
				TextColor3 = T.orange,
				Font = T.fontBold,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = button,
			})
			add(chipsFrame, button)
			button.Activated:Connect(function()
				if not button:GetAttribute("Locked") then
					cb.onMaterial(material.id)
				end
			end)
			chips[material.id] = {
				button = button,
				outline = outline,
				countLabel = countLabel,
				nameLabel = nameLabel,
			}
		end
	end

	----------------------------------------------------------------- status
	local function setStatus(kind, text, hint)
		statusText.Text = text or ""
		statusHint.Text = hint or ""
		statusHint.Visible = (hint ~= nil and hint ~= "")
		if kind ~= currentStatusKind then
			currentStatusKind = kind
			if statusPulse then
				statusPulse:Cancel()
				statusPulse = nil
			end
			statusDot.BackgroundTransparency = 0
			tween(statusDot, 0.2, { BackgroundColor3 = STATUS_COLORS[kind] or T.gray })
			if PULSING[kind] then
				statusPulse = TweenService:Create(
					statusDot,
					TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ BackgroundTransparency = 0.7 }
				)
				statusPulse:Play()
			end
		end
	end

	----------------------------------------------------------------- render
	local function plainPoint(prefix, cell)
		if not cell then
			return string.format("%s: <font color=\"#8A8A92\">not set</font>", prefix)
		end
		return string.format("%s: <font color=\"#FFFFFF\">%d, %d, %d</font>", prefix, cell.X, cell.Y, cell.Z)
	end

	local function valueLine(label, value, colorHex)
		return string.format('%s: <font color="%s">%s</font>', label, colorHex or "#FFFFFF", value)
	end

	local lastStripProgress = -1

	function self.render(vm)
		setStatus(vm.status.kind, vm.status.text, vm.status.hint)

		-- area
		selectButton.setText(vm.selectText)
		selectButton.setEnabled(vm.selectEnabled)
		resetButton.instance.Visible = vm.resetVisible
		selectButton.instance.Size = vm.resetVisible and UDim2.new(1, -92, 1, 0) or UDim2.new(1, 0, 1, 0)
		resetButton.setEnabled(vm.selectEnabled)
		pointALabel.Text = plainPoint("Point A", vm.pointA)
		pointBLabel.Text = plainPoint("Point B", vm.pointB)
		sizeLabel.Text = vm.sizeText and valueLine("Build size", vm.sizeText) or ""
		sizeLabel.Visible = vm.sizeText ~= nil

		-- options
		local opts = vm.opts
		optionsSection.Visible = vm.optionsVisible
		modeSegmented.set(opts.mode)
		modeSegmented.setLocked(vm.optionsLocked)
		modeHelp.Text = Config.MODE_HELP[opts.mode] or ""

		local isWall = opts.mode == "wall"
		layoutCaption.Visible = isWall
		layoutSegmented.instance.Visible = isWall
		layoutSegmented.set(opts.layout)
		layoutSegmented.setLocked(vm.optionsLocked)

		local usesHeight = opts.mode ~= "floor"
		heightStepper.instance.Visible = usesHeight
		heightStepper.set(vm.shownHeight or opts.height)
		heightStepper.setLocked(vm.heightLocked or vm.optionsLocked)
		heightNote.Visible = usesHeight and vm.heightLocked

		local usesThickness = opts.mode == "floor" or isWall
		thicknessStepper.instance.Visible = usesThickness
		thicknessStepper.setLabel(opts.mode == "floor" and "Floor thickness (layers)" or "Wall thickness")
		thicknessStepper.set(opts.thickness)
		thicknessStepper.setLocked(vm.optionsLocked)

		for _, material in ipairs(vm.materials) do
			local chip = chips[material.id]
			if chip then
				local selected = material.id == opts.material
				chip.countLabel.Text = fmt(material.count)
				chip.countLabel.TextColor3 = material.count > 0 and T.orange or T.muted
				chip.outline.Color = selected and T.orange or T.line
				chip.outline.Thickness = selected and 2 or 1.5
				chip.button.BackgroundColor3 = selected and T.panelHi:Lerp(T.orange, 0.12) or T.panelHi
				chip.button:SetAttribute("Locked", vm.optionsLocked)
				chip.button.BackgroundTransparency = vm.optionsLocked and 0.5 or 0
			end
		end

		speedCaption.Text = string.format("BUILD SPEED  -  %d blocks / second", opts.speed)
		speedSegmented.set(opts.speed)
		speedSegmented.setLocked(vm.optionsLocked) -- speed is fixed when a build starts

		-- requirements
		local req = vm.req
		reqSection.Visible = req ~= nil or vm.banner ~= nil
		for _, line in ipairs({ reqRequired, reqAvailable, reqMissing, reqProgress }) do
			line.Visible = req ~= nil
		end
		reqBar.instance.Visible = req ~= nil
		if not req then
			reqSkip.Visible = false
		end
		if req then
			local plural = Config.plural(req.name)
			reqRequired.Text = valueLine(plural .. " Required", fmt(req.required))
			reqAvailable.Text = valueLine(plural .. " Available", fmt(req.available))
			reqMissing.Text = valueLine(plural .. " Missing", fmt(req.missing), req.missing > 0 and "#F05248" or "#58D67E")
			reqProgress.Text = valueLine("Progress", fmt(math.min(req.available, req.required)) .. " / " .. fmt(req.required))
			local fraction = req.required > 0 and math.min(1, req.available / req.required) or 0
			reqBar.set(fraction, req.missing > 0 and T.red or T.green)
			reqSkip.Visible = (req.occupied or 0) > 0
			reqSkip.Text = string.format(
				"%s existing block%s in this area will be skipped - nothing is overwritten.",
				fmt(req.occupied or 0),
				(req.occupied == 1) and "" or "s"
			)
		end
		local banner = vm.banner
		bannerFrame.Visible = banner ~= nil
		if banner then
			local color = (banner.kind == "ok" and T.green) or (banner.kind == "warn" and T.yellow) or T.red
			bannerText.Text = banner.text
			bannerText.TextColor3 = color
			bannerStroke.Color = color
			bannerFrame.BackgroundColor3 = (banner.kind == "ok") and Color3.fromRGB(22, 40, 28)
				or (banner.kind == "warn") and Color3.fromRGB(46, 40, 18)
				or Color3.fromRGB(46, 24, 24)
		end

		-- job
		local job = vm.job
		jobSection.Visible = job ~= nil
		local stripProgress = 0
		if job then
			stripProgress = job.progress or 0
			jobTitle.Text = vm.jobTitle
			jobBuilding.Text = valueLine("Building", job.label or "-")
			jobPlaced.Text = valueLine("Blocks Placed", fmt(job.placed) .. " / " .. fmt(job.total))
			jobProgress.Text = valueLine("Progress", string.format("%.1f%%", (job.progress or 0) * 100))
			jobStatus.Text = valueLine("Status", vm.jobStatus or "", vm.jobStatusColor)
			jobBar.set(job.progress or 0, vm.jobBarColor or T.orange)
		end
		if math.abs(stripProgress - lastStripProgress) > 0.001 then
			lastStripProgress = stripProgress
			tween(stripFill, 0.2, { Size = UDim2.new(math.clamp(stripProgress, 0, 1), 0, 1, 0) })
		end
		reopen.Text = (vm.jobActive and string.format("AUTO BUILDER  %d%%", math.floor(stripProgress * 100 + 0.5)))
			or "AUTO BUILDER"

		-- footer buttons
		startButton.instance.Visible = vm.startVisible
		startButton.setEnabled(vm.startEnabled)
		pauseButton.instance.Visible = vm.pauseVisible
		pauseMode = vm.pauseIsResume and "resume" or "pause"
		pauseButton.setText(vm.pauseIsResume and "RESUME BUILDING" or "PAUSE BUILDING")
		pauseButton.setEnabled(vm.pauseEnabled)
		cancelButton.setEnabled(vm.cancelEnabled)
		cancelButton.setText(vm.cancelText)
	end

	function self.destroy()
		gui:Destroy()
	end

	return self
end

return UI
]==],
	},
}

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local function childNamed(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local created = 0
for _, file in ipairs(FILES) do
	local parent = game:GetService(file.path[1])
	for i = 2, #file.path do
		parent = childNamed(parent, file.path[i])
	end
	local old = parent:FindFirstChild(file.name)
	if old then
		old:Destroy()
	end
	local script = Instance.new(file.class)
	script.Name = file.name
	script.Source = file.source
	script.Parent = parent
	created += 1
end

pcall(function()
	ChangeHistoryService:SetWaypoint("Install Auto Builder")
end)
print(string.format("[AutoBuilder] Installed %d scripts. Press Play to test.", created))
