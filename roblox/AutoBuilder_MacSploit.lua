--[[
	ABOVE[RUINS] | AUTO BUILDER  —  client-side build planner  (single script for MacSploit)

	HOW TO USE
	  1. Join ABOVE[RUINS].
	  2. Paste this ENTIRE file into MacSploit and press Execute.
	  3. The window appears at once (top-right). RightShift hides/shows it. If you
	     can't see it, open the Roblox console (F9) and read the [AutoBuilder] lines,
	     or set CONFIG.CONTAINER = "playergui" below and execute again.

	WHAT IT IS
	  A planning + guided-building overlay that runs entirely on YOUR client:
	    * pick Point A and Point B (click a block, or stand there and press "A = MY POSITION")
	    * bright orange outline + translucent preview of exactly what will be built
	    * Floor / Wall / Fill / Hollow Box planning with exact block counts
	    * Required / Available / Missing calculator (reads your inventory if it can,
	      otherwise you type the number)
	    * START turns on GUIDED TRACKING: it highlights the next blocks to place and
	      counts the ones you place yourself, with a progress bar. Pause / Resume / Cancel work.

	WHAT IT DOES NOT DO
	  It never places blocks for you. It does not fire any RemoteEvent/RemoteFunction, does not
	  touch your inventory, and does not talk to the server at all. Real auto-placement would
	  need an official building interface from the game; see README.md.

	NOTE: running scripts through an executor is against Roblox's Terms of Use and can get an
	account banned. Use it at your own risk.
]]

----------------------------------------------------------------------------------------------
-- 0. SETTINGS (safe to edit)
----------------------------------------------------------------------------------------------
local CONFIG = {
	DEBUG = true, -- print [AutoBuilder] messages to the console as well as the in-window log
	CONTAINER = "auto", -- "auto" | "gethui" | "coregui" | "playergui"  (where the window is parented)
	TOGGLE_KEY = Enum.KeyCode.RightShift, -- hide / show the window

	GRID_SIZE = 4, -- studs per block. Press CALIBRATE and click a placed block to set this exactly.
	GRID_ORIGIN = Vector3.new(0, 0, 0), -- a corner of any block (CALIBRATE sets this too)
	SELECT_ADJACENT = true, -- click selects the empty cell next to the clicked face (ground -> layer above)

	MATERIALS = { "Grass Block", "Dirt Block", "Stone Block", "Wood Planks" }, -- add your own names here
	MAX_BLOCKS = 20000, -- biggest plan allowed
	MAX_DIMENSION = 128,
	MAX_HEIGHT = 64,
	MAX_THICKNESS = 16,

	DETECT_EXISTING = true, -- look for blocks already standing in the area (needed for progress tracking)
	MAX_TRACK_CELLS = 15000, -- areas bigger than this can be planned but not tracked
	SCAN_PER_FRAME = 150, -- cells checked per frame while scanning
	OCC_MIN_FRACTION = 0.45, -- a part counts as a "block" if every side >= this * grid size ...
	OCC_MAX_MULT = 2.01, -- ... and no side is longer than this * grid size (ignores ground plates, flowers)
	NEXT_GHOSTS = 12, -- how many upcoming blocks to highlight while tracking
}

----------------------------------------------------------------------------------------------
-- 1. Single-instance guard + logging (before anything that could fail)
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

local LOG = { lines = {}, max = 150, onLine = nil }
local function log(level, ...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local msg = table.concat(parts, " ")
	local line = string.format("[%s] %s", level, msg)
	LOG.lines[#LOG.lines + 1] = line
	if #LOG.lines > LOG.max then
		table.remove(LOG.lines, 1)
	end
	if level == "ERROR" or level == "WARN" then
		warn("[AutoBuilder] " .. line)
	elseif CONFIG.DEBUG then
		print("[AutoBuilder] " .. line)
	end
	if LOG.onLine then
		pcall(LOG.onLine, level, line)
	end
end

local seenErrors = {}
local function safe(label, fn, ...)
	local ok, err = xpcall(fn, function(e)
		return tostring(e) .. " | " .. string.sub(tostring(debug.traceback()), 1, 300)
	end, ...)
	if not ok then
		local key = label .. tostring(err)
		if not seenErrors[key] then -- log each distinct error once so a broken tick can't flood the log
			seenErrors[key] = true
			log("ERROR", label .. " failed: " .. string.sub(tostring(err), 1, 500))
		end
	end
	return ok
end

log("INFO", "script started")

----------------------------------------------------------------------------------------------
-- 2. Services and environment
----------------------------------------------------------------------------------------------
if not game:IsLoaded() then
	game.Loaded:Wait()
end
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CAS = game:GetService("ContextActionService")
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait(0.1)
	LocalPlayer = Players.LocalPlayer
end

do
	local exec = "unknown executor"
	local okName, name, ver = pcall(function()
		if identifyexecutor then
			return identifyexecutor()
		end
	end)
	if okName and name then
		exec = tostring(name) .. (ver and (" " .. tostring(ver)) or "")
	end
	log("INFO", "executor:", exec)
	log("INFO", "gethui:", tostring(gethui ~= nil), "| setclipboard:", tostring(setclipboard ~= nil))
	log("INFO", "player:", LocalPlayer.Name, "| camera:", tostring(workspace.CurrentCamera ~= nil))
end

----------------------------------------------------------------------------------------------
-- 3. Planner (pure geometry): which cells does a build contain?
--    A "plan" is a list of disjoint boxes, so count / preview / tracking always agree.
----------------------------------------------------------------------------------------------
local PL = {}
local MODES = { floor = true, wall = true, fill = true, hollow = true }
local OFFSET, SPAN, COORD_LIMIT = 32768, 65536, 32000
local LIMITS = {
	maxBlocks = CONFIG.MAX_BLOCKS,
	maxDimension = CONFIG.MAX_DIMENSION,
	maxHeight = CONFIG.MAX_HEIGHT,
	maxThickness = CONFIG.MAX_THICKNESS,
}

local function validCoord(n)
	return type(n) == "number" and n == n and math.abs(n) <= COORD_LIMIT and n % 1 == 0
end
local function validCell(c)
	return type(c) == "table" and validCoord(c.x) and validCoord(c.y) and validCoord(c.z)
end
local function clampInt(v, lo, hi, default)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return default
	end
	return math.clamp(math.floor(v), lo, hi)
end

-- returns plan | nil, errorCode ("BAD_REQUEST" | "TOO_LARGE")
function PL.plan(a, b, options, limits)
	if not validCell(a) or not validCell(b) or type(options) ~= "table" then
		return nil, "BAD_REQUEST"
	end
	local mode = options.mode
	if not MODES[mode] then
		return nil, "BAD_REQUEST"
	end
	local minX, maxX = math.min(a.x, b.x), math.max(a.x, b.x)
	local minY, maxY = math.min(a.y, b.y), math.max(a.y, b.y)
	local minZ, maxZ = math.min(a.z, b.z), math.max(a.z, b.z)
	local w, selH, d = maxX - minX + 1, maxY - minY + 1, maxZ - minZ + 1

	local heightOpt = clampInt(options.height, 1, limits.maxHeight, 1)
	local thickOpt = clampInt(options.thickness, 1, limits.maxThickness, 1)
	local layout = (options.layout == "surround") and "surround" or "straight"

	local heightLocked = selH > 1 -- points on different layers: height comes from the points
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
			add(minX, baseY, minZ, maxX, topY, maxZ)
		else
			add(minX, baseY, minZ, maxX, baseY, maxZ) -- floor
			add(minX, topY, minZ, maxX, topY, maxZ) -- ceiling
			local y1, y2 = baseY + 1, topY - 1
			add(minX, y1, minZ, maxX, y2, minZ)
			add(minX, y1, maxZ, maxX, y2, maxZ)
			add(minX, y1, minZ + 1, minX, y2, maxZ - 1)
			add(maxX, y1, minZ + 1, maxX, y2, maxZ - 1)
		end
	elseif mode == "wall" then
		if layout == "straight" then
			if w >= d then
				local t = math.min(thickOpt, d)
				if a.z <= b.z then
					add(minX, baseY, minZ, maxX, topY, minZ + t - 1)
				else
					add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ)
				end
			else
				local t = math.min(thickOpt, w)
				if a.x <= b.x then
					add(minX, baseY, minZ, minX + t - 1, topY, maxZ)
				else
					add(maxX - t + 1, baseY, minZ, maxX, topY, maxZ)
				end
			end
		else
			local t = thickOpt
			if 2 * t >= math.min(w, d) then
				add(minX, baseY, minZ, maxX, topY, maxZ)
			else
				add(minX, baseY, minZ, maxX, topY, minZ + t - 1)
				add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ)
				add(minX, baseY, minZ + t, minX + t - 1, topY, maxZ - t)
				add(maxX - t + 1, baseY, minZ + t, maxX, topY, maxZ - t)
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
		boxes = boxes,
		count = count,
		min = bMin,
		max = bMax,
		size = { x = bMax.x - bMin.x + 1, y = bMax.y - bMin.y + 1, z = bMax.z - bMin.z + 1 },
		height = H,
		heightLocked = heightLocked,
	}
end

-- Bottom layer first, then row by row, alternating direction ("snake").
-- Returns { n, xs, ys, zs } (parallel arrays).
function PL.buildOrder(plan)
	local keys, n = {}, 0
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
	local xs, ys, zs = {}, {}, {}
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

----------------------------------------------------------------------------------------------
-- 4. State
----------------------------------------------------------------------------------------------
local MODE_ORDER = { "floor", "wall", "fill", "hollow" }
local MODE_LABEL = { floor = "FLOOR", wall = "WALL", fill = "FILL", hollow = "HOLLOW BOX" }
local MODE_NOUN = { floor = "Floor", wall = "Wall", fill = "Fill", hollow = "Hollow Box" }
local MODE_HELP = {
	floor = "A flat slab over the rectangle. Thickness = number of layers.",
	wall = "Straight: along the longer side, from Point A toward B. Surround: all four sides.",
	fill = "Solid volume. Use two points at different heights, or set the Height.",
	hollow = "Outer walls, floor and ceiling; the inside stays empty.",
}

local S = {
	grid = { size = CONFIG.GRID_SIZE, origin = CONFIG.GRID_ORIGIN },
	adjacent = CONFIG.SELECT_ADJACENT,
	detect = CONFIG.DETECT_EXISTING,
	a = nil, -- cell {x,y,z}
	b = nil,
	pick = nil, -- what the next world click sets: "A" | "B" | "CAL" | nil
	autoSeq = false, -- after picking A, go straight on to B
	hover = nil,
	hoverPlan = nil,
	materials = {},
	opts = { mode = "floor", material = CONFIG.MATERIALS[1], height = 4, thickness = 1, layout = "straight" },
	plan = nil,
	planCode = nil,
	track = "off", -- off | running | paused | done
	baseline = 0, -- cells already filled when tracking started
	final = nil, -- numbers kept for the "build complete" card after the selection is cleared
}
for _, name in ipairs(CONFIG.MATERIALS) do
	S.materials[#S.materials + 1] = name
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
local function plural(name)
	if string.lower(string.sub(name, -1)) == "s" then
		return name
	end
	return name .. "s"
end
local function buildLabel(name, mode)
	local short = string.gsub(name, "%s+[Bb]locks?$", "")
	return short .. " " .. (MODE_NOUN[mode] or "Build")
end
local function dimText(plan)
	return string.format("%d × %d × %d  ·  %s blocks", plan.size.x, plan.size.y, plan.size.z, fmt(plan.count))
end
local function cellCenter(c)
	local s, o = S.grid.size, S.grid.origin
	return Vector3.new(o.X + (c.x + 0.5) * s, o.Y + (c.y + 0.5) * s, o.Z + (c.z + 0.5) * s)
end

-- forward declarations (defined further down). The harmless defaults mean a click can never
-- hit a nil function even if building the interface fails part-way.
local render, recompute, refreshPreview, toast, resetSelection, derive
render = function() end
toast = function(text)
	log("INFO", "toast:", text)
end

----------------------------------------------------------------------------------------------
-- 5. Preview (client-only parts: nothing here exists for other players or the server)
----------------------------------------------------------------------------------------------
local ORANGE = Color3.fromRGB(255, 140, 20)
local ORANGE_HI = Color3.fromRGB(255, 176, 48)
local RED = Color3.fromRGB(240, 82, 72)

local Preview = {}
do
	local folder, pool, active = nil, {}, 0
	local markers, ghost, bounds, dim, nextPool = {}, nil, nil, nil, {}
	local building = false

	local function newPart(name)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Locked = true
		p.Massless = true
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Transparency = 1
		p.Size = Vector3.new(1, 1, 1)
		p.Parent = folder
		return p
	end
	local function outline(part, color, thickness, transparency)
		local sb = Instance.new("SelectionBox")
		sb.Adornee = part
		sb.Color3 = color
		sb.LineThickness = thickness
		sb.Transparency = transparency or 0
		sb.SurfaceTransparency = 1
		sb.Parent = part
		return sb
	end
	local function billboard(part, text, width, offset)
		local gui = Instance.new("BillboardGui")
		gui.Adornee = part
		gui.Size = UDim2.fromOffset(width, 26)
		gui.StudsOffsetWorldSpace = offset or Vector3.new(0, 0, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 800
		gui.Parent = part
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
		label.BackgroundTransparency = 0.15
		label.BorderSizePixel = 0
		label.Text = text
		label.TextColor3 = ORANGE
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.Parent = gui
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = label
		local st = Instance.new("UIStroke")
		st.Color = ORANGE
		st.Thickness = 1.5
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = label
		return label
	end

	function Preview.init()
		folder = Instance.new("Folder")
		folder.Name = "AutoBuilderPreview"
		folder.Parent = workspace
		onDestroy(function()
			folder:Destroy()
		end)
		Preview.folder = folder

		for _, key in ipairs({ "A", "B" }) do
			local cube = newPart("Point" .. key)
			cube.Color = ORANGE
			cube.Material = Enum.Material.Neon
			cube.Transparency = 0.55
			outline(cube, ORANGE_HI, 0.14, 0)
			billboard(cube, "POINT " .. key, 80, Vector3.new(0, 4, 0))
			local beacon = newPart("Beacon" .. key)
			beacon.Color = ORANGE
			beacon.Material = Enum.Material.Neon
			beacon.Transparency = 0.45
			cube.Parent, beacon.Parent = nil, nil
			markers[key] = { cube = cube, beacon = beacon }
		end

		local g = newPart("Hover")
		g.Color = ORANGE
		g.Transparency = 0.8
		ghost = { part = g, box = outline(g, ORANGE, 0.08, 0.1) }
		g.Parent = nil

		local bp = newPart("Bounds")
		bounds = { part = bp, box = outline(bp, ORANGE_HI, 0.12, 0) }
		bp.Parent = nil

		local dp = newPart("Dimensions")
		dp.Size = Vector3.new(0.2, 0.2, 0.2)
		dim = { part = dp, label = billboard(dp, "", 230) }
		dp.Parent = nil
	end

	local function boxToWorld(box)
		local s, o = S.grid.size, S.grid.origin
		local mn = Vector3.new(o.X + box.x1 * s, o.Y + box.y1 * s, o.Z + box.z1 * s)
		local mx = Vector3.new(o.X + (box.x2 + 1) * s, o.Y + (box.y2 + 1) * s, o.Z + (box.z2 + 1) * s)
		return (mn + mx) / 2, mx - mn
	end

	function Preview.setPulse(on)
		building = on and true or false
		-- gentle pulse is driven from Heartbeat below (no tweens to restart)
	end

	-- plan | nil ; style "valid" | "hover" | "invalid"
	function Preview.setBuild(plan, style, text)
		if not plan then
			for i = 1, active do
				pool[i].part.Parent = nil
			end
			active = 0
			bounds.part.Parent = nil
			dim.part.Parent = nil
			return
		end
		local color = (style == "invalid") and RED or ORANGE
		local fill = (style == "hover") and 0.9 or 0.78
		Preview.baseFill = fill
		for i, box in ipairs(plan.boxes) do
			local entry = pool[i]
			if not entry then
				local part = newPart("BuildBox")
				entry = { part = part, box = outline(part, ORANGE, 0.1, 0) }
				pool[i] = entry
			end
			local center, size = boxToWorld(box)
			entry.part.Size = size + Vector3.new(0.06, 0.06, 0.06)
			entry.part.Position = center
			entry.part.Color = color
			entry.part.Transparency = fill
			entry.box.Color3 = color
			entry.box.Transparency = (style == "hover") and 0.25 or 0
			entry.box.LineThickness = (style == "hover") and 0.06 or 0.1
			entry.part.Parent = folder
		end
		for i = #plan.boxes + 1, active do
			pool[i].part.Parent = nil
		end
		active = #plan.boxes

		-- bright outline around the whole selection rectangle (connects Point A and Point B)
		local center, size = boxToWorld({
			x1 = plan.min.x, y1 = plan.min.y, z1 = plan.min.z,
			x2 = plan.max.x, y2 = plan.max.y, z2 = plan.max.z,
		})
		bounds.part.Size = size + Vector3.new(0.12, 0.12, 0.12)
		bounds.part.Position = center
		bounds.box.Color3 = (style == "invalid") and RED or ORANGE_HI
		bounds.box.Transparency = (style == "hover") and 0.3 or 0
		bounds.part.Parent = folder

		local top = S.grid.origin.Y + (plan.max.y + 1) * S.grid.size
		dim.part.Position = Vector3.new(center.X, top + 1.5, center.Z)
		dim.label.Text = text or ""
		dim.part.Parent = (text and text ~= "") and folder or nil
	end

	function Preview.setPoint(key, cell)
		local m = markers[key]
		if not cell then
			m.cube.Parent, m.beacon.Parent = nil, nil
			return
		end
		local s = S.grid.size
		local c = cellCenter(cell)
		m.cube.Size = Vector3.new(s, s, s) * 1.02
		m.cube.Position = c
		m.beacon.Size = Vector3.new(0.4, s * 6, 0.4)
		m.beacon.Position = c + Vector3.new(0, s / 2 + s * 3, 0)
		m.cube.Parent, m.beacon.Parent = folder, folder
	end

	function Preview.setHover(cell)
		if not cell then
			ghost.part.Parent = nil
			return
		end
		local s = S.grid.size
		ghost.part.Size = Vector3.new(s, s, s) * 1.02
		ghost.part.Position = cellCenter(cell)
		ghost.part.Parent = folder
	end

	-- list of cells {x,y,z} to highlight as "place these next"
	function Preview.setNext(cells)
		local s = S.grid.size
		local n = cells and #cells or 0
		for i = 1, math.max(n, #nextPool) do
			local entry = nextPool[i]
			if i <= n then
				if not entry then
					local part = newPart("Next")
					part.Material = Enum.Material.Neon
					entry = { part = part, box = outline(part, Color3.fromRGB(255, 255, 255), 0.06, 0.1) }
					nextPool[i] = entry
				end
				entry.part.Color = ORANGE_HI
				entry.part.Transparency = (i == 1) and 0.35 or 0.6
				entry.part.Size = Vector3.new(s, s, s) * 0.96
				entry.part.Position = cellCenter(cells[i])
				entry.part.Parent = folder
			elseif entry then
				entry.part.Parent = nil
			end
		end
	end

	function Preview.clear()
		Preview.setBuild(nil)
		Preview.setPoint("A", nil)
		Preview.setPoint("B", nil)
		Preview.setHover(nil)
		Preview.setNext(nil)
		building = false
	end

	-- subtle breathing of the orange fill while tracking
	local t0 = os.clock()
	function Preview.pulseStep()
		if not building or active == 0 then
			return
		end
		local wave = (math.sin((os.clock() - t0) * 4) + 1) / 2
		local tr = (Preview.baseFill or 0.78) + wave * 0.12
		for i = 1, active do
			pool[i].part.Transparency = tr
		end
	end
end

----------------------------------------------------------------------------------------------
-- 6. Inventory (read-only best effort + manual entry)
----------------------------------------------------------------------------------------------
local UI = { ready = false }
local Inv = { mode = {}, manual = {}, source = {} } -- per material name

local function norm(s)
	s = string.lower(tostring(s))
	s = string.gsub(s, "%s*blocks?%s*$", "")
	s = string.gsub(s, "[^%w]", "")
	return s
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
local function isOurs(inst)
	return UI.gui ~= nil and inst:IsDescendantOf(UI.gui)
end

local COUNT_ATTRS = { "Count", "Amount", "Quantity", "Stack", "Stacks", "Qty" }

-- (1) IntValue / NumberValue on the player whose name matches the material
local function scanValues(name)
	local want = norm(name)
	for _, d in ipairs(LocalPlayer:GetDescendants()) do
		if (d:IsA("IntValue") or d:IsA("NumberValue")) and norm(d.Name) == want and not isOurs(d) then
			return {
				desc = "value " .. d:GetFullName(),
				read = function()
					return d.Parent and d.Value or nil
				end,
			}
		end
	end
end

-- (2) a Tool in Backpack/Character named after the material, with a readable count
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
local function scanTools(name)
	local want = norm(name)
	local containers = {} -- (built by appending: a nil Backpack mid-respawn must not hide the Character)
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then
		containers[#containers + 1] = backpack
	end
	if LocalPlayer.Character then
		containers[#containers + 1] = LocalPlayer.Character
	end
	for _, container in ipairs(containers) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") then
					local base = string.gsub(tool.Name, "%s*[xX]%s*[%d,]+%s*$", "")
					if norm(base) == want and toolCount(tool) ~= nil then
						return {
							desc = "tool '" .. tool.Name .. "'",
							read = function()
								return tool.Parent and toolCount(tool) or nil
							end,
						}
					end
				end
			end
		end
	end
end

-- (3) the number shown next to the item name in the hotbar / inventory GUI ("Grass Block" ... "x686")
local function scanGui(name)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local want = norm(name)
	for _, d in ipairs(pg:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and norm(d.Text) == want then
			if not isOurs(d) and guiVisible(d) then
				local node = d.Parent
				for _ = 1, 3 do
					if not node or node == pg then
						break
					end
					for _, sib in ipairs(node:GetDescendants()) do
						if sib ~= d and (sib:IsA("TextLabel") or sib:IsA("TextButton")) and parseCount(sib.Text) then
							return {
								desc = "on-screen text '" .. sib.Text .. "' next to '" .. d.Text .. "'",
								read = function()
									if not sib.Parent then
										return nil
									end
									return parseCount(sib.Text)
								end,
							}
						end
					end
					node = node.Parent
				end
			end
		end
	end
end

function Inv.rescan(name)
	local src
	local ok, err = pcall(function()
		src = scanValues(name) or scanTools(name) or scanGui(name)
	end)
	if not ok then
		log("WARN", "inventory scan error:", err)
	end
	Inv.source[name] = src
	if src then
		log("INFO", "inventory for '" .. name .. "' read from " .. src.desc .. " (verify it looks right)")
	else
		log("INFO", "no readable inventory data for '" .. name .. "' - type the amount in manually")
	end
	return src
end
function Inv.autoValue(name)
	local src = Inv.source[name]
	if not src then
		return nil
	end
	local ok, v = pcall(src.read)
	if ok and type(v) == "number" then
		return v
	end
	Inv.source[name] = nil -- the thing we were reading disappeared
	return nil
end
-- returns count, "auto" | "manual"
function Inv.get(name)
	if Inv.mode[name] ~= "manual" then
		local v = Inv.autoValue(name)
		if v ~= nil then
			return v, "auto"
		end
	end
	return Inv.manual[name] or 0, "manual"
end

----------------------------------------------------------------------------------------------
-- 7. World scan: which cells of the plan already contain a block? (read-only spatial queries)
----------------------------------------------------------------------------------------------
local Scan = { order = nil, n = 0, filled = {}, filledCount = 0, i = 1, done = false, passes = 0, tooLarge = false }
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 50 -- a cell crowded with small decorations must not hide the real block

function Scan.reset(plan)
	Scan.filled, Scan.filledCount, Scan.i, Scan.done, Scan.passes = {}, 0, 1, false, 0
	Scan.order, Scan.n, Scan.tooLarge = nil, 0, false
	if plan then
		if plan.count > CONFIG.MAX_TRACK_CELLS then
			Scan.tooLarge = true
		else
			Scan.order = PL.buildOrder(plan)
			Scan.n = Scan.order.n
		end
	end
end

local function updateOverlapFilter()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			list[#list + 1] = p.Character
		end
	end
	if Preview.folder then
		list[#list + 1] = Preview.folder
	end
	overlap.FilterDescendantsInstances = list
end

local function cellOccupied(x, y, z)
	local s = S.grid.size
	local parts = workspace:GetPartBoundsInRadius(cellCenter({ x = x, y = y, z = z }), s * 0.3, overlap)
	local minSide, maxSide = s * CONFIG.OCC_MIN_FRACTION, s * CONFIG.OCC_MAX_MULT
	for _, p in ipairs(parts) do
		if p:IsA("BasePart") and not p:IsA("Terrain") and p.Transparency < 0.9 then
			local sz = p.Size
			if math.min(sz.X, sz.Y, sz.Z) >= minSide and math.max(sz.X, sz.Y, sz.Z) <= maxSide then
				return true
			end
		end
	end
	return false
end

function Scan.step(count)
	local o = Scan.order
	if not o then
		return
	end
	updateOverlapFilter()
	for _ = 1, count do
		if Scan.i > o.n then
			Scan.done = true
			Scan.passes += 1
			Scan.lastDone = os.clock()
			if S.track == "running" then
				Scan.i = 1 -- keep cycling so progress follows what you place
			else
				return
			end
		end
		local i = Scan.i
		local now = cellOccupied(o.xs[i], o.ys[i], o.zs[i])
		local was = Scan.filled[i] == true
		if now and not was then
			Scan.filledCount += 1
		elseif was and not now then
			Scan.filledCount -= 1
		end
		Scan.filled[i] = now
		Scan.i = i + 1
	end
end

keep(RunService.Heartbeat:Connect(function()
	if not ARB.alive then
		return
	end
	Preview.pulseStep()
	if Scan.order and S.detect and (not Scan.done or S.track == "running") then
		local ok, err = pcall(Scan.step, CONFIG.SCAN_PER_FRAME)
		if not ok then
			S.detect = false
			log("ERROR", "block detection failed and was turned off:", err)
		end
	end
end))

----------------------------------------------------------------------------------------------
-- 8. Picking cells in the world (mouse) + "my position"
----------------------------------------------------------------------------------------------
local function overFrame(f)
	if not f or not f.Parent or not f.Visible then
		return false
	end
	local p, s, m = f.AbsolutePosition, f.AbsoluteSize, UIS:GetMouseLocation()
	return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
end
local function pointerOverUI()
	return overFrame(UI.window) or overFrame(UI.reopen)
end

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

-- Ray under the mouse; skips invisible volumes (zone/boundary boxes) so you click what you SEE.
local function pickRay()
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local loc = UIS:GetMouseLocation()
	local ray = cam:ViewportPointToRay(loc.X, loc.Y)
	local ignore = characters()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	for _ = 1, 8 do
		params.FilterDescendantsInstances = ignore
		local res = workspace:Raycast(ray.Origin, ray.Direction * 1500, params)
		if not res then
			return nil
		end
		local inst = res.Instance
		if inst:IsA("BasePart") and not inst:IsA("Terrain") and inst.Transparency >= 0.9 then
			ignore[#ignore + 1] = inst
		else
			return res
		end
	end
	return nil
end

local function cellFromHit(res)
	local s, o = S.grid.size, S.grid.origin
	local dir = S.adjacent and 1 or -1
	local p = (res.Position + res.Normal * (s / 2) * dir - o) / s
	return { x = math.floor(p.X), y = math.floor(p.Y), z = math.floor(p.Z) }
end

-- the grid cell you're standing in (feet level)
local function myCell()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil, "your character isn't loaded yet"
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters()
	local res = workspace:Raycast(hrp.Position, Vector3.new(0, -30, 0), params)
	local footY
	if res then
		footY = res.Position.Y
	else
		local hum = char:FindFirstChildOfClass("Humanoid")
		footY = hrp.Position.Y - hrp.Size.Y / 2 - (hum and hum.HipHeight or 2)
	end
	local s, o = S.grid.size, S.grid.origin
	return {
		x = math.floor((hrp.Position.X - o.X) / s),
		y = math.floor((footY + 0.05 - o.Y) / s),
		z = math.floor((hrp.Position.Z - o.Z) / s),
	}
end

local ACTION = "AutoBuilderPick"
local casBound = false
local function unbindPick()
	if casBound then
		pcall(function()
			CAS:UnbindAction(ACTION)
		end)
		casBound = false
	end
end

local handleClick
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
			return Enum.ContextActionResult.Sink -- keep the game from also reacting to this click
		end, false, 3000, Enum.UserInputType.MouseButton1)
	end)
	casBound = ok
	if not ok then
		log("WARN", "ContextActionService bind failed, using plain input events instead:", err)
	end
end
onDestroy(unbindPick)

-- fallback path when CAS isn't available
keep(UIS.InputBegan:Connect(function(input, processed)
	if casBound or processed or not S.pick then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not pointerOverUI() then
		safe("pick click", handleClick)
	end
end))

local function stopPicking()
	S.pick, S.autoSeq, S.hover, S.hoverPlan = nil, false, nil, nil
	unbindPick()
	Preview.setHover(nil)
end

local function startPicking(which, auto)
	S.pick, S.autoSeq, S.hover, S.hoverPlan = which, auto and true or false, nil, nil
	bindPick()
	log("INFO", "picking:", which)
	refreshPreview()
	render()
end

local function setPoint(which, cell)
	if which == "A" then
		S.a = cell
	else
		S.b = cell
	end
	Preview.setPoint(which, cell)
	log("INFO", string.format("Point %s = cell (%d, %d, %d)", which, cell.x, cell.y, cell.z))
	if S.pick == which then
		if which == "A" and S.autoSeq and not S.b then
			S.pick = "B"
			S.hover, S.hoverPlan = nil, nil
		else
			stopPicking()
		end
	end
	recompute()
end

local function calibrateFrom(inst)
	if not (inst and inst:IsA("BasePart")) or inst:IsA("Terrain") then
		toast("That isn't a block. Click a placed block.", "error")
		return
	end
	local sz = inst.Size
	local mn, mx = math.min(sz.X, sz.Y, sz.Z), math.max(sz.X, sz.Y, sz.Z)
	if mx > mn * 1.05 then
		log("WARN", string.format("'%s' is %.2f x %.2f x %.2f - not a cube, grid unchanged", inst.Name, sz.X, sz.Y, sz.Z))
		toast(string.format("'%s' isn't cube-shaped (%.1f×%.1f×%.1f). Click a single block.", inst.Name, sz.X, sz.Y, sz.Z), "error")
		return
	end
	local size = sz.X
	local corner = inst.Position - sz / 2
	local function wrap(v)
		return ((v % size) + size) % size
	end
	resetSelection()
	S.grid.size = size
	S.grid.origin = Vector3.new(wrap(corner.X), wrap(corner.Y), wrap(corner.Z))
	local rot = inst.Orientation
	if math.abs(rot.Y % 90) > 1 or math.abs(rot.X) > 1 or math.abs(rot.Z) > 1 then
		log("WARN", "that block is rotated - the grid may not line up with the world axes")
	end
	log("INFO", string.format("grid calibrated from '%s': size %.3f, origin (%.3f, %.3f, %.3f)", inst.Name, size, S.grid.origin.X, S.grid.origin.Y, S.grid.origin.Z))
	toast(string.format("Grid set: %.2f studs per block.", size), "success")
end

handleClick = function()
	local res = pickRay()
	if not res then
		toast("Click a block or the ground.", "error")
		return
	end
	if S.pick == "CAL" then
		stopPicking()
		calibrateFrom(res.Instance)
		recompute()
		return
	end
	setPoint(S.pick, cellFromHit(res))
end

-- live preview while choosing the second corner
keep(RunService.RenderStepped:Connect(function()
	if not ARB.alive or not S.pick or S.pick == "CAL" then
		return
	end
	if pointerOverUI() then
		if S.hover then
			S.hover, S.hoverPlan = nil, nil
			Preview.setHover(nil)
			refreshPreview()
		end
		return
	end
	local res = pickRay()
	local cell = res and cellFromHit(res) or nil
	local same = (cell == nil and S.hover == nil)
		or (cell ~= nil and S.hover ~= nil and cell.x == S.hover.x and cell.y == S.hover.y and cell.z == S.hover.z)
	if same then
		return
	end
	S.hover = cell
	Preview.setHover(cell)
	S.hoverPlan = nil
	if cell then
		local fixed = (S.pick == "B") and S.a or (S.pick == "A") and S.b or nil
		if fixed then
			local pa, pb = fixed, cell
			if S.pick == "A" then
				pa, pb = cell, fixed
			end
			S.hoverPlan = PL.plan(pa, pb, S.opts, LIMITS)
		end
	end
	refreshPreview()
end))

----------------------------------------------------------------------------------------------
-- 9. Selection / planning / tracking logic
----------------------------------------------------------------------------------------------
refreshPreview = function()
	if S.plan then
		Preview.setBuild(S.plan, "valid", dimText(S.plan))
	elseif S.hoverPlan and S.pick then
		Preview.setBuild(S.hoverPlan, "hover", dimText(S.hoverPlan))
	else
		Preview.setBuild(nil)
	end
	Preview.setPulse(S.track == "running")
end

local function trackStopVisuals()
	Preview.setNext(nil)
end

recompute = function()
	if S.track ~= "off" then -- any change to the selection or options ends tracking / clears the old result
		S.track, S.final = "off", nil
		trackStopVisuals()
	end
	S.plan, S.planCode = nil, nil
	if S.a and S.b then
		local plan, code = PL.plan(S.a, S.b, S.opts, LIMITS)
		S.plan, S.planCode = plan, code
		if plan then
			log("INFO", string.format("plan: %s, %s", MODE_LABEL[plan.mode], dimText(plan)))
		else
			log("WARN", "plan rejected:", code)
		end
	end
	Scan.reset(S.plan)
	refreshPreview()
	render()
end

resetSelection = function()
	stopPicking()
	S.a, S.b, S.plan, S.planCode = nil, nil, nil, nil
	S.track, S.final = "off", nil
	Scan.reset(nil)
	Preview.clear()
	render()
end

local function trackStart()
	if not S.plan then
		toast("Select an area first.", "error")
		return
	end
	if not S.detect then
		toast("Turn DETECT BLOCKS on to track progress.", "error")
		return
	end
	if Scan.tooLarge or not Scan.order then
		toast("That area is too large to track.", "error")
		return
	end
	-- Always take a fresh, complete reading right now, so blocks you placed since the last scan
	-- (or before pressing START again after Pause/Cancel) don't count as build progress.
	Scan.i = 1
	pcall(Scan.step, Scan.n)
	if Scan.filledCount >= Scan.n then
		toast("Every block in this area already exists.", "error")
		return
	end
	S.baseline = Scan.filledCount
	S.track = "running"
	Scan.i = 1
	log("INFO", string.format("tracking started: %d to place, %d already filled", Scan.n - S.baseline, S.baseline))
	local short = derive().missing
	if short > 0 then
		toast(string.format("Tracking started — but you're short %s %s.", fmt(short), plural(S.opts.material)), "info")
	else
		toast("Tracking started — place the highlighted blocks.", "success")
	end
	refreshPreview()
	render()
end

local function trackPause()
	if S.track ~= "running" then
		return
	end
	S.track = "paused"
	trackStopVisuals()
	log("INFO", "tracking paused")
	refreshPreview()
	render()
end

local function trackResume()
	if S.track ~= "paused" then
		return
	end
	S.track = "running"
	Scan.i = 1
	log("INFO", "tracking resumed")
	refreshPreview()
	render()
end

local function trackCancel()
	if S.pick then
		stopPicking()
		log("INFO", "picking cancelled")
	elseif S.track == "running" or S.track == "paused" then
		S.track = "off"
		trackStopVisuals()
		log("INFO", "tracking cancelled (selection kept)")
		toast("Tracking cancelled.", "info")
	end
	refreshPreview()
	render()
end

local function trackComplete()
	local toPlace = math.max(1, Scan.n - S.baseline)
	S.final = { placed = toPlace, toPlace = toPlace }
	S.track = "done"
	log("INFO", "build complete")
	toast("Build complete!", "success")
	-- remove the orange preview and clear the selection (the result card keeps the numbers)
	stopPicking()
	S.a, S.b, S.plan, S.planCode = nil, nil, nil, nil
	Scan.reset(nil)
	Preview.clear()
	render()
end

local function updateGhosts()
	if S.track ~= "running" or not Scan.order then
		return
	end
	local list, o = {}, Scan.order
	for i = 1, o.n do
		if not Scan.filled[i] then
			list[#list + 1] = { x = o.xs[i], y = o.ys[i], z = o.zs[i] }
			if #list >= CONFIG.NEXT_GHOSTS then
				break
			end
		end
	end
	Preview.setNext(list)
end

-- numbers shown by the calculator
derive = function()
	local d = { total = S.plan and S.plan.count or 0 }
	d.scanReady = Scan.order ~= nil and S.detect and (Scan.passes > 0 or S.track == "running" or S.track == "paused")
	d.filled = d.scanReady and Scan.filledCount or 0
	d.required = math.max(0, d.total - d.filled)
	local avail, kind = Inv.get(S.opts.material)
	-- manual counts don't update by themselves, so estimate what's left while you build
	if kind == "manual" and (S.track == "running" or S.track == "paused") then
		avail = math.max(0, avail - math.max(0, Scan.filledCount - S.baseline))
		d.estimated = true
	end
	d.avail, d.kind = avail, kind
	d.missing = math.max(0, d.required - avail)
	if S.track == "done" and S.final then
		d.placed, d.toPlace, d.progress = S.final.placed, S.final.toPlace, 1
	elseif S.track == "running" or S.track == "paused" then
		local toPlace = math.max(1, Scan.n - S.baseline)
		d.placed = math.clamp(Scan.filledCount - S.baseline, 0, toPlace)
		d.toPlace = toPlace
		d.progress = d.placed / toPlace
	end
	return d
end

----------------------------------------------------------------------------------------------
-- 10. GUI
----------------------------------------------------------------------------------------------
local T = {
	bg = Color3.fromRGB(14, 14, 16),
	panel = Color3.fromRGB(26, 26, 30),
	panelHi = Color3.fromRGB(38, 38, 44),
	line = Color3.fromRGB(58, 58, 66),
	orange = ORANGE,
	orangeDark = Color3.fromRGB(190, 95, 0),
	text = Color3.fromRGB(236, 236, 238),
	muted = Color3.fromRGB(150, 150, 158),
	dark = Color3.fromRGB(18, 14, 8),
	green = Color3.fromRGB(88, 214, 126),
	red = RED,
	yellow = Color3.fromRGB(255, 205, 70),
	gray = Color3.fromRGB(120, 120, 128),
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
local function stroke(color, th, tr)
	return new("UIStroke", { Color = color, Thickness = th or 1, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(l, t, r, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
	})
end
local function vlist(gap)
	return new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap) })
end
local orderCount = setmetatable({}, { __mode = "k" })
local function add(parent, inst)
	local n = (orderCount[parent] or 0) + 1
	orderCount[parent] = n
	inst.LayoutOrder = n
	inst.Parent = parent
	return inst
end
local function label(parent, text, o)
	o = o or {}
	local fixed = o.height ~= nil
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, o.height or 0),
		AutomaticSize = fixed and Enum.AutomaticSize.None or Enum.AutomaticSize.Y,
		Text = text,
		TextColor3 = o.color or T.text,
		Font = o.bold and T.bold or T.font,
		TextSize = o.size or 14,
		TextWrapped = true,
		RichText = o.rich or false,
		TextXAlignment = o.align or Enum.TextXAlignment.Left,
		TextYAlignment = fixed and Enum.TextYAlignment.Center or Enum.TextYAlignment.Top,
	})
	if parent then
		add(parent, l)
	end
	return l
end

local BSTYLE = {
	primary = { bg = T.orange, text = T.dark, stroke = T.orange, offBg = Color3.fromRGB(52, 52, 58), offText = T.muted, offStroke = Color3.fromRGB(70, 70, 78) },
	secondary = { bg = T.panelHi, text = T.text, stroke = T.orange, offBg = T.panel, offText = T.muted, offStroke = T.line },
	danger = { bg = Color3.fromRGB(52, 28, 28), text = Color3.fromRGB(255, 130, 120), stroke = T.red, offBg = T.panel, offText = T.muted, offStroke = T.line },
}
local function button(text, kind, h)
	local st = BSTYLE[kind]
	local b = new("TextButton", {
		BackgroundColor3 = st.bg, BorderSizePixel = 0, AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, h or 36), Text = text, TextColor3 = st.text,
		Font = T.bold, TextSize = 13,
	}, { corner(8) })
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
			safe("button '" .. tostring(text) .. "'", o.onClick)
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

local function segmented(items, onChange)
	local n, gap = #items, 4
	local frame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) })
	local o = { inst = frame, value = nil, locked = false }
	local btns = {}
	local function paint()
		for _, bt in ipairs(btns) do
			local sel = bt.value == o.value
			bt.btn.BackgroundColor3 = sel and T.orange or T.panelHi
			bt.btn.TextColor3 = sel and T.dark or T.text
			bt.btn.BackgroundTransparency = o.locked and 0.55 or 0
			bt.btn.TextTransparency = o.locked and 0.5 or 0
		end
	end
	for i, item in ipairs(items) do
		local btn = new("TextButton", {
			BackgroundColor3 = T.panelHi, BorderSizePixel = 0, AutoButtonColor = false,
			Position = UDim2.new((i - 1) / n, (i - 1) * gap / n, 0, 0),
			Size = UDim2.new(1 / n, -gap * (n - 1) / n, 1, 0),
			Text = item.label, TextColor3 = T.text, Font = T.bold, TextScaled = true, Parent = frame,
		}, { corner(8), new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 8 }), pad(4, 0, 4, 0) })
		btn.Activated:Connect(function()
			if not o.locked then
				safe("segmented", onChange, item.value)
			end
		end)
		btns[i] = { btn = btn, value = item.value }
	end
	function o.set(v)
		if o.value ~= v then
			o.value = v
			paint()
		end
	end
	function o.setLocked(v)
		v = v and true or false
		if o.locked ~= v then
			o.locked = v
			paint()
		end
	end
	return o
end

local function stepper(text, lo, hi, onChange)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) })
	local lbl = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -140, 1, 0), Text = text, TextColor3 = T.text,
		Font = T.font, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
	})
	local box = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(132, 32), Parent = row,
	})
	local o = { inst = row, value = lo, locked = false }
	local function small(t, x)
		return new("TextButton", {
			BackgroundColor3 = T.panelHi, BorderSizePixel = 0, AutoButtonColor = false,
			Position = UDim2.fromOffset(x, 0), Size = UDim2.fromOffset(34, 32), Text = t,
			TextColor3 = T.orange, Font = T.bold, TextSize = 20, Parent = box,
		}, { corner(8) })
	end
	local minus, plus = small("-", 0), small("+", 98)
	local val = new("TextLabel", {
		BackgroundColor3 = T.bg, BorderSizePixel = 0, Position = UDim2.fromOffset(36, 0),
		Size = UDim2.fromOffset(60, 32), Text = tostring(lo), TextColor3 = T.text, Font = T.bold,
		TextSize = 16, Parent = box,
	}, { corner(8), stroke(T.line, 1) })
	local function step(d)
		if o.locked then
			return
		end
		local nv = math.clamp(o.value + d, lo, hi)
		if nv ~= o.value then
			safe("stepper", onChange, nv)
		end
	end
	minus.Activated:Connect(function()
		step(-1)
	end)
	plus.Activated:Connect(function()
		step(1)
	end)
	function o.set(v)
		o.value = v
		val.Text = tostring(v)
	end
	function o.setLabel(t)
		lbl.Text = t
	end
	function o.setLocked(v)
		o.locked = v and true or false
		local tr = o.locked and 0.5 or 0
		minus.TextTransparency, plus.TextTransparency, val.TextTransparency = tr, tr, tr
	end
	return o
end

local function textbox(placeholder, text, width, onCommit)
	local tb = new("TextBox", {
		BackgroundColor3 = T.bg, BorderSizePixel = 0, Size = UDim2.new(0, width, 0, 32),
		Text = text or "", PlaceholderText = placeholder, TextColor3 = T.text, PlaceholderColor3 = T.muted,
		Font = T.font, TextSize = 14, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
	}, { corner(8), stroke(T.line, 1), pad(8, 0, 8, 0) })
	tb.FocusLost:Connect(function()
		safe("textbox", onCommit, tb.Text)
	end)
	return tb
end

local function bar(h)
	local track = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(12, 12, 14), BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, h),
	}, { corner(h / 2), stroke(T.line, 1) })
	local fill = new("Frame", {
		BackgroundColor3 = T.orange, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0), Parent = track,
	}, { corner(h / 2) })
	local o = { inst = track }
	function o.set(f, color)
		fill.Size = UDim2.new(math.clamp(f, 0, 1), 0, 1, 0)
		if color then
			fill.BackgroundColor3 = color
		end
	end
	return o
end

local function section(parent, title)
	local f = new("Frame", {
		BackgroundColor3 = T.panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, { corner(10), stroke(T.line, 1), pad(12, 10, 12, 12), vlist(8) })
	add(parent, f)
	local tl
	if title then
		tl = label(f, title, { bold = true, size = 12, color = T.orange })
	end
	return f, tl
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
				log("INFO", "window mounted in:", kind)
				return kind
			end
			log("WARN", "could not parent the window to " .. kind .. ":", err)
		else
			log("INFO", kind, "is not available here")
		end
	end
	return nil
end

local function buildGui()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local W = 380
	local H = math.clamp(vp.Y - 110, 360, 680)
	local TITLE_H, FOOTER_H = 44, 100
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
		Name = "Window", BackgroundColor3 = T.bg, BorderSizePixel = 0, Active = true, ClipsDescendants = true,
		Size = UDim2.fromOffset(W, H), Position = UDim2.fromOffset(math.max(8, vp.X - W - 16), 70), Parent = gui,
	}, { corner(14), stroke(T.orange, 2) })
	UI.window = window

	local titleBar = new("Frame", { Name = "TitleBar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TITLE_H), Parent = window })
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -90, 1, -3),
		Text = '<font color="#FF8C14">ABOVE[RUINS]</font>  |  AUTO BUILDER', RichText = true, TextColor3 = T.text,
		Font = T.bold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Parent = titleBar,
	})
	local function titleButton(text, x)
		return new("TextButton", {
			BackgroundColor3 = T.panelHi, BorderSizePixel = 0, AutoButtonColor = false,
			Position = UDim2.new(1, x, 0.5, -15), Size = UDim2.fromOffset(30, 28), Text = text,
			TextColor3 = T.text, Font = T.bold, TextSize = 18, Parent = titleBar,
		}, { corner(8) })
	end
	local minBtn, closeBtn = titleButton("–", -72), titleButton("×", -38)
	local strip = new("Frame", {
		BackgroundColor3 = T.line, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -3),
		Size = UDim2.new(1, 0, 0, 3), Parent = titleBar,
	})
	local stripFill = new("Frame", { BackgroundColor3 = T.orange, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0), Parent = strip })

	-- Mount NOW (before the rest of the interface is built) so the window shows up immediately.
	local kind = mountGui(gui)
	if not kind then
		log("ERROR", "Could not parent the window anywhere. Try CONFIG.CONTAINER = 'playergui'.")
	end

	local reopen = new("TextButton", {
		Name = "Reopen", BackgroundColor3 = T.bg, BorderSizePixel = 0, AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -12), Size = UDim2.fromOffset(170, 36),
		Text = "AUTO BUILDER", TextColor3 = T.orange, Font = T.bold, TextSize = 14, Visible = false, Parent = gui,
	}, { corner(10), stroke(T.orange, 2) })
	UI.reopen = reopen

	local toastFrame = new("Frame", {
		Name = "Toast", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(math.min(440, vp.X - 24), 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.bg, BorderSizePixel = 0, Visible = false, ZIndex = 20, Parent = gui,
	}, { corner(10), pad(14, 10, 14, 10) })
	local toastStroke = stroke(T.orange, 2)
	toastStroke.Parent = toastFrame
	local toastLabel = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Text = "", TextColor3 = T.text, Font = T.bold, TextSize = 14, TextWrapped = true, ZIndex = 21, Parent = toastFrame,
	})
	local toastToken = 0
	toast = function(text, kindName)
		toastToken += 1
		local token = toastToken
		toastLabel.Text = text
		toastStroke.Color = (kindName == "error" and T.red) or (kindName == "success" and T.green) or T.orange
		toastFrame.Visible = true
		task.delay(3.6, function()
			if token == toastToken then
				toastFrame.Visible = false
			end
		end)
	end

	-- window behaviour: drag / minimize / close / reopen / toggle key
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
			local x = math.clamp(startX + d.X, 80 - W, math.max(80 - W, v.X - 80))
			local y = math.clamp(startY + d.Y, 0, math.max(0, v.Y - TITLE_H))
			window.Position = UDim2.fromOffset(x, y)
		end
	end))

	local body, footer -- assigned below
	local function applyMin()
		window.Size = UDim2.fromOffset(W, state.minimized and (TITLE_H + 3) or H)
		if body then
			body.Visible = not state.minimized
		end
		if footer then
			footer.Visible = not state.minimized
		end
		minBtn.Text = state.minimized and "+" or "–"
	end
	local function setOpen(v)
		state.open = v
		window.Visible = v
		reopen.Visible = not v
	end
	minBtn.Activated:Connect(function()
		state.minimized = not state.minimized
		applyMin()
	end)
	closeBtn.Activated:Connect(function()
		setOpen(false)
	end)
	reopen.Activated:Connect(function()
		setOpen(true)
	end)
	if CONFIG.TOGGLE_KEY then
		keep(UIS.InputBegan:Connect(function(input, processed)
			-- (not `processed`: some games sink Shift for shift-lock; just don't fire while typing)
			if input.KeyCode == CONFIG.TOGGLE_KEY and UIS:GetFocusedTextBox() == nil then
				setOpen(not state.open)
			end
		end))
	end

	-- keep it on screen if the game window is resized, and re-mount if the game removes it
	task.spawn(function()
		while ARB.alive do
			task.wait(2)
			if not ARB.alive then
				break -- this copy was replaced by a newer execution; don't touch the destroyed window
			end
			if gui.Parent == nil then
				log("WARN", "window was removed by the game - re-mounting")
				mountGui(gui)
			end
		end
	end)

	----------------------------------------------------------------------------- body
	body = new("ScrollingFrame", {
		Name = "Body", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, TITLE_H),
		Size = UDim2.new(1, 0, 1, -(TITLE_H + FOOTER_H)), CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = T.orange,
		ScrollingDirection = Enum.ScrollingDirection.Y, Parent = window,
	}, { vlist(10), pad(12, 10, 12, 10) })

	local w = {} -- widget references used by render()

	safe("build: status", function()
		local card = section(body, nil)
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22) })
		add(card, row)
		w.dot = new("Frame", {
			BackgroundColor3 = T.gray, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(12, 12), Parent = row,
		}, { corner(6) })
		w.statusText = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -22, 1, 0),
			Text = "READY", TextColor3 = T.text, Font = T.bold, TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
		})
		w.statusHint = label(card, "", { size = 12, color = T.muted })
	end)

	safe("build: grid", function()
		local sec = section(body, "BLOCK GRID")
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) })
		add(sec, row)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(1, -90, 1, 0), Text = "Block size (studs)",
			TextColor3 = T.text, Font = T.font, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
		})
		w.gridBox = textbox("4", tostring(S.grid.size), 80, function(txt)
			local n = tonumber(txt)
			if n and n >= 0.25 and n <= 64 then
				if n ~= S.grid.size then
					resetSelection()
					S.grid.size = n
					log("INFO", "grid size set to", n, "(selection reset)")
				end
			else
				toast("Enter a block size between 0.25 and 64.", "error")
			end
			render()
		end)
		w.gridBox.AnchorPoint = Vector2.new(1, 0)
		w.gridBox.Position = UDim2.new(1, 0, 0, 0)
		w.gridBox.Parent = row
		w.calBtn = button("CALIBRATE FROM A BLOCK (CLICK ONE)", "secondary", 34)
		w.calBtn.onClick = function()
			startPicking("CAL", false)
		end
		add(sec, w.calBtn.inst)
		w.originLabel = label(sec, "", { size = 12, color = T.muted })
		label(sec, "CLICK SELECTS", { bold = true, size = 11, color = T.muted })
		w.adjSeg = segmented({
			{ value = true, label = "CELL ABOVE THE FACE" },
			{ value = false, label = "THE CLICKED BLOCK" },
		}, function(v)
			S.adjacent = v
			render()
		end)
		add(sec, w.adjSeg.inst)
		label(sec, "DETECT BLOCKS (needed for progress)", { bold = true, size = 11, color = T.muted })
		w.detectSeg = segmented({ { value = true, label = "ON" }, { value = false, label = "OFF" } }, function(v)
			S.detect = v
			log("INFO", "block detection", v and "ON" or "OFF")
			render()
		end)
		add(sec, w.detectSeg.inst)
	end)

	safe("build: area", function()
		local sec = section(body, "BUILD AREA")
		w.selectBtn = button("SELECT BUILD AREA  (CLICK A, THEN B)", "primary", 38)
		w.selectBtn.onClick = function()
			resetSelection()
			startPicking("A", true)
		end
		add(sec, w.selectBtn.inst)
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34) })
		add(sec, row)
		w.hereA = button("A = MY POSITION", "secondary", 34)
		w.hereA.inst.Size = UDim2.new(0.5, -3, 1, 0)
		w.hereA.inst.Parent = row
		w.hereB = button("B = MY POSITION", "secondary", 34)
		w.hereB.inst.Size = UDim2.new(0.5, -3, 1, 0)
		w.hereB.inst.Position = UDim2.new(0.5, 3, 0, 0)
		w.hereB.inst.Parent = row
		local function here(which)
			local cell, why = myCell()
			if not cell then
				toast("Can't read your position: " .. tostring(why), "error")
				log("WARN", "my position failed:", why)
				return
			end
			setPoint(which, cell)
		end
		w.hereA.onClick = function()
			here("A")
		end
		w.hereB.onClick = function()
			here("B")
		end
		w.resetBtn = button("RESET SELECTION", "secondary", 32)
		w.resetBtn.onClick = function()
			resetSelection()
			log("INFO", "selection reset")
		end
		add(sec, w.resetBtn.inst)
		w.pointA = label(sec, "", { rich = true, size = 13, color = T.muted })
		w.pointB = label(sec, "", { rich = true, size = 13, color = T.muted })
		w.sizeLabel = label(sec, "", { rich = true, size = 13, color = T.muted })
	end)

	safe("build: options", function()
		w.optSec = section(body, "BUILD OPTIONS")
		local items = {}
		for _, m in ipairs(MODE_ORDER) do
			items[#items + 1] = { value = m, label = MODE_LABEL[m] }
		end
		w.modeSeg = segmented(items, function(m)
			S.opts.mode = m
			recompute()
		end)
		add(w.optSec, w.modeSeg.inst)
		w.modeHelp = label(w.optSec, "", { size = 12, color = T.muted })
		w.layoutCap = label(w.optSec, "WALL LAYOUT", { bold = true, size = 11, color = T.muted })
		w.layoutSeg = segmented({
			{ value = "straight", label = "STRAIGHT WALL" },
			{ value = "surround", label = "SURROUND" },
		}, function(v)
			S.opts.layout = v
			recompute()
		end)
		add(w.optSec, w.layoutSeg.inst)
		w.heightStep = stepper("Height (layers)", 1, CONFIG.MAX_HEIGHT, function(v)
			S.opts.height = v
			recompute()
		end)
		add(w.optSec, w.heightStep.inst)
		w.heightNote = label(w.optSec, "Height comes from your two points.", { size = 12, color = T.yellow })
		w.thickStep = stepper("Thickness", 1, CONFIG.MAX_THICKNESS, function(v)
			S.opts.thickness = v
			recompute()
		end)
		add(w.optSec, w.thickStep.inst)
	end)

	safe("build: materials", function()
		w.matSec = section(body, "MATERIAL & INVENTORY")
		w.chipsFrame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, {
			new("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder, FillDirection = Enum.FillDirection.Horizontal,
				Wraps = true, Padding = UDim.new(0, 6),
			}),
		})
		add(w.matSec, w.chipsFrame)
		w.chips = {}

		local addRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) })
		add(w.matSec, addRow)
		w.customBox = textbox("custom block name", "", 220, function() end)
		w.customBox.Parent = addRow
		w.addBtn = button("ADD", "secondary", 32)
		w.addBtn.inst.AnchorPoint = Vector2.new(1, 0)
		w.addBtn.inst.Position = UDim2.new(1, 0, 0, 0)
		w.addBtn.inst.Size = UDim2.new(0, 84, 1, 0)
		w.addBtn.inst.Parent = addRow
		w.addBtn.onClick = function()
			local name = string.gsub(w.customBox.Text, "^%s+", "")
			name = string.gsub(name, "%s+$", "")
			if name == "" then
				return
			end
			for _, existing in ipairs(S.materials) do
				if string.lower(existing) == string.lower(name) then
					S.opts.material = existing
					w.customBox.Text = ""
					render()
					return
				end
			end
			S.materials[#S.materials + 1] = name
			S.opts.material = name
			w.customBox.Text = ""
			log("INFO", "added material:", name)
			Inv.rescan(name)
			render()
		end

		local invRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) })
		add(w.matSec, invRow)
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0, 90, 1, 0), Text = "Available", TextColor3 = T.text,
			Font = T.font, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Parent = invRow,
		})
		w.availBox = textbox("0", "0", 110, function(txt)
			if S.track == "running" or S.track == "paused" then
				render() -- the box shows an estimate while tracking; don't store it as your real count
				return
			end
			local n = tonumber((string.gsub(txt, ",", "")))
			if n and n >= 0 then
				Inv.manual[S.opts.material] = math.floor(n)
				Inv.mode[S.opts.material] = "manual"
				log("INFO", "manual inventory:", S.opts.material, "=", math.floor(n))
			else
				toast("Type a whole number for how many you have.", "error")
			end
			render()
		end)
		w.availBox.Position = UDim2.fromOffset(92, 0)
		w.availBox.Parent = invRow
		w.autoBtn = button("AUTO", "secondary", 32)
		w.autoBtn.inst.AnchorPoint = Vector2.new(1, 0)
		w.autoBtn.inst.Position = UDim2.new(1, 0, 0, 0)
		w.autoBtn.inst.Size = UDim2.new(0, 84, 1, 0)
		w.autoBtn.inst.Parent = invRow
		w.autoBtn.onClick = function()
			Inv.mode[S.opts.material] = nil
			Inv.rescan(S.opts.material)
			if Inv.source[S.opts.material] == nil then
				toast("No readable inventory found - type the amount manually.", "error")
			end
			render()
		end
		w.invSource = label(w.matSec, "", { size = 12, color = T.muted })
	end)

	safe("build: requirements", function()
		w.reqSec = section(body, "BUILD REQUIREMENTS")
		w.reqTotal = label(w.reqSec, "", { rich = true, size = 13, color = T.muted })
		w.reqFilled = label(w.reqSec, "", { rich = true, size = 13, color = T.muted })
		w.reqRequired = label(w.reqSec, "", { rich = true, size = 14, color = T.muted })
		w.reqAvail = label(w.reqSec, "", { rich = true, size = 14, color = T.muted })
		w.reqMissing = label(w.reqSec, "", { rich = true, size = 14, color = T.muted })
		w.reqProgress = label(w.reqSec, "", { rich = true, size = 14, color = T.muted })
		w.reqBar = bar(10)
		add(w.reqSec, w.reqBar.inst)
		w.banner = new("Frame", {
			BackgroundColor3 = Color3.fromRGB(46, 24, 24), BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, { corner(8), pad(10, 8, 10, 8) })
		w.bannerStroke = stroke(T.red, 1.5)
		w.bannerStroke.Parent = w.banner
		add(w.reqSec, w.banner)
		w.bannerText = label(w.banner, "", { bold = true, size = 13, color = T.red })
	end)

	safe("build: progress", function()
		w.progSec, w.progTitle = section(body, "AUTO BUILDER ACTIVE")
		w.progBuilding = label(w.progSec, "", { rich = true, size = 14, color = T.muted })
		w.progPlaced = label(w.progSec, "", { rich = true, size = 14, color = T.muted })
		w.progPct = label(w.progSec, "", { rich = true, size = 14, color = T.muted })
		w.progStatus = label(w.progSec, "", { rich = true, size = 14, color = T.muted })
		w.progBar = bar(12)
		add(w.progSec, w.progBar.inst)
		label(w.progSec, "Guided mode: you place the blocks; this counts them as they appear.", { size = 11, color = T.muted })
	end)

	safe("build: debug log", function()
		local sec = section(body, "DEBUG LOG")
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30) })
		add(sec, row)
		local showBtn = button("SHOW / HIDE", "secondary", 30)
		showBtn.inst.Size = UDim2.new(0.34, -3, 1, 0)
		showBtn.inst.Parent = row
		local copyBtn = button("COPY", "secondary", 30)
		copyBtn.inst.Size = UDim2.new(0.33, -3, 1, 0)
		copyBtn.inst.Position = UDim2.new(0.34, 3, 0, 0)
		copyBtn.inst.Parent = row
		local clearBtn = button("CLEAR", "secondary", 30)
		clearBtn.inst.Size = UDim2.new(0.33, -3, 1, 0)
		clearBtn.inst.Position = UDim2.new(0.67, 3, 0, 0)
		clearBtn.inst.Parent = row
		w.logBox = new("TextLabel", {
			BackgroundColor3 = T.bg, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, Text = "", TextColor3 = T.muted, Font = Enum.Font.Code,
			TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top, Visible = false,
		}, { corner(6), pad(8, 6, 8, 6) })
		add(sec, w.logBox)
		local function refreshLog()
			local first = math.max(1, #LOG.lines - 39)
			w.logBox.Text = table.concat(LOG.lines, "\n", first, #LOG.lines)
		end
		showBtn.onClick = function()
			w.logBox.Visible = not w.logBox.Visible
			refreshLog()
		end
		copyBtn.onClick = function()
			local ok, err = pcall(function()
				setclipboard(table.concat(LOG.lines, "\n"))
			end)
			toast(ok and "Log copied to clipboard." or "Couldn't copy (no setclipboard).", ok and "success" or "error")
			if not ok then
				log("WARN", "copy failed:", err)
			end
		end
		clearBtn.onClick = function()
			LOG.lines = {}
			refreshLog()
		end
		LOG.onLine = function(level)
			if level == "ERROR" then
				w.logBox.Visible = true -- surface problems without being asked
			end
			if w.logBox.Visible then
				refreshLog()
			end
		end
		refreshLog()
	end)

	----------------------------------------------------------------------------- footer
	footer = new("Frame", {
		Name = "Footer", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -FOOTER_H),
		Size = UDim2.new(1, 0, 0, FOOTER_H), Parent = window,
	}, { pad(12, 10, 12, 8) })
	new("Frame", {
		BackgroundColor3 = T.line, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -FOOTER_H),
		Size = UDim2.new(1, 0, 0, 1), Parent = window,
	})
	local function footerButton(text, kindName, col, rowIdx)
		local b = button(text, kindName, 38)
		b.inst.Size = UDim2.new(0.5, -3, 0, 38)
		b.inst.Position = UDim2.new(col * 0.5, col == 0 and 0 or 3, 0, rowIdx * 44)
		b.inst.Parent = footer
		return b
	end
	safe("build: footer", function()
		w.startBtn = footerButton("START BUILDING", "primary", 0, 0)
		w.pauseBtn = footerButton("PAUSE", "secondary", 1, 0)
		w.resumeBtn = footerButton("RESUME", "secondary", 0, 1)
		w.cancelBtn = footerButton("CANCEL BUILD", "danger", 1, 1)
		w.startBtn.onClick = trackStart
		w.pauseBtn.onClick = trackPause
		w.resumeBtn.onClick = trackResume
		w.cancelBtn.onClick = trackCancel
	end)

	----------------------------------------------------------------------------- chips
	local function rebuildChips()
		for _, c in pairs(w.chips or {}) do
			c.btn:Destroy()
		end
		w.chips = {}
		for _, name in ipairs(S.materials) do
			local b = new("TextButton", {
				BackgroundColor3 = T.panelHi, BorderSizePixel = 0, AutoButtonColor = false,
				Size = UDim2.new(0.5, -4, 0, 38), Text = "",
			}, { corner(8) })
			local sk = stroke(T.line, 1.5)
			sk.Parent = b
			new("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -66, 1, 0),
				Text = name, TextColor3 = T.text, Font = T.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd, Parent = b,
			})
			local count = new("TextLabel", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0),
				Size = UDim2.new(0, 52, 1, 0), Text = "", TextColor3 = T.orange, Font = T.bold, TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Right, Parent = b,
			})
			add(w.chipsFrame, b)
			b.Activated:Connect(function()
				if S.track == "running" or S.track == "paused" then
					return
				end
				S.opts.material = name
				if Inv.source[name] == nil and Inv.mode[name] ~= "manual" then
					Inv.rescan(name)
				end
				render()
			end)
			w.chips[name] = { btn = b, stroke = sk, count = count }
		end
		w.chipCount = #S.materials
	end

	----------------------------------------------------------------------------- render
	local STATUS_COLOR = {
		idle = T.gray, selecting = T.orange, ready = T.green, missing = T.red,
		building = T.orange, paused = T.yellow, error = T.red, done = T.green,
	}
	local function pointText(prefix, c)
		if not c then
			return prefix .. ': <font color="#8A8A92">not set</font>'
		end
		return string.format('%s: <font color="#FFFFFF">%d, %d, %d</font>', prefix, c.x, c.y, c.z)
	end
	local function line(labelText, value, hex)
		return string.format('%s: <font color="%s">%s</font>', labelText, hex or "#FFFFFF", value)
	end

	render = function()
		if not UI.ready then
			return
		end
		local tracking = S.track == "running" or S.track == "paused"
		local d = derive()
		local name = S.opts.material
		local plural_ = plural(name)

		safe("render: status", function()
			local kindName, text, hint
			if S.pick == "A" then
				kindName, text, hint = "selecting", "SELECT POINT A", "Click a block/the ground at one corner, or press A = MY POSITION."
			elseif S.pick == "B" then
				kindName, text, hint = "selecting", "SELECT POINT B", "Click the opposite corner. The preview follows your cursor."
			elseif S.pick == "CAL" then
				kindName, text, hint = "selecting", "CALIBRATE GRID", "Click ONE placed block (not the ground)."
			elseif S.track == "running" then
				kindName, text, hint = "building", "TRACKING BUILD", "Place the highlighted blocks. Progress updates by itself."
			elseif S.track == "paused" then
				kindName, text, hint = "paused", "PAUSED", "Press RESUME to continue tracking."
			elseif S.track == "done" then
				kindName, text, hint = "done", "BUILD COMPLETE", "Select another area to keep going."
			elseif S.a and S.b then
				if S.planCode then
					kindName, text, hint = "error", "CAN'T PLAN THAT", S.planCode == "TOO_LARGE" and "That area is too large." or "Invalid selection."
				elseif d.missing > 0 and d.required > 0 then
					kindName, text, hint = "missing", "MISSING MATERIALS", string.format("You need %s more %s.", fmt(d.missing), plural_)
				elseif d.scanReady and d.required == 0 then
					kindName, text, hint = "error", "NOTHING TO BUILD", "Every cell in this area is already filled."
				else
					kindName, text, hint = "ready", "READY TO BUILD", "Press START BUILDING to begin guided tracking."
				end
			elseif S.a or S.b then
				kindName, text, hint = "idle", "ONE POINT SET", "Set the other corner (SELECT BUILD AREA or B = MY POSITION)."
			else
				kindName, text, hint = "ready", "READY", "Press SELECT BUILD AREA to begin."
			end
			w.statusText.Text = text
			w.statusHint.Text = hint
			w.statusHint.Visible = hint ~= ""
			w.dot.BackgroundColor3 = STATUS_COLOR[kindName] or T.gray
		end)

		safe("render: grid", function()
			if not w.gridBox:IsFocused() then
				w.gridBox.Text = tostring(math.floor(S.grid.size * 1000 + 0.5) / 1000)
			end
			local o = S.grid.origin
			w.originLabel.Text = string.format("Grid origin: %.2f, %.2f, %.2f", o.X, o.Y, o.Z)
			w.adjSeg.set(S.adjacent)
			w.detectSeg.set(S.detect)
			w.calBtn.setEnabled(not tracking)
			w.detectSeg.setLocked(tracking)
		end)

		safe("render: area", function()
			w.pointA.Text = pointText("Point A", S.a)
			w.pointB.Text = pointText("Point B", S.b)
			w.sizeLabel.Visible = S.plan ~= nil
			if S.plan then
				w.sizeLabel.Text = line("Build size", dimText(S.plan))
			end
			w.selectBtn.setEnabled(not tracking)
			w.hereA.setEnabled(not tracking)
			w.hereB.setEnabled(not tracking)
			w.resetBtn.setEnabled(not tracking and (S.a ~= nil or S.b ~= nil))
		end)

		safe("render: options", function()
			local show = S.plan ~= nil or (S.a ~= nil and S.b ~= nil)
			w.optSec.Visible = show
			local mode = S.opts.mode
			w.modeSeg.set(mode)
			w.modeSeg.setLocked(tracking)
			w.modeHelp.Text = MODE_HELP[mode]
			local isWall = mode == "wall"
			w.layoutCap.Visible = isWall
			w.layoutSeg.inst.Visible = isWall
			w.layoutSeg.set(S.opts.layout)
			w.layoutSeg.setLocked(tracking)
			w.heightStep.inst.Visible = mode ~= "floor"
			w.heightStep.set((S.plan and S.plan.heightLocked) and S.plan.height or S.opts.height)
			w.heightStep.setLocked((S.plan ~= nil and S.plan.heightLocked) or tracking)
			w.heightNote.Visible = mode ~= "floor" and S.plan ~= nil and S.plan.heightLocked
			w.thickStep.inst.Visible = mode == "floor" or isWall
			w.thickStep.setLabel(mode == "floor" and "Floor thickness (layers)" or "Wall thickness")
			w.thickStep.set(S.opts.thickness)
			w.thickStep.setLocked(tracking)
		end)

		safe("render: materials", function()
			if w.chipCount ~= #S.materials then
				rebuildChips()
			end
			for _, m in ipairs(S.materials) do
				local chip = w.chips[m]
				if chip then
					local sel = m == name
					local n, kindName = Inv.get(m)
					local known = kindName == "auto" or Inv.manual[m] ~= nil
					chip.count.Text = known and fmt(n) or "?"
					chip.stroke.Color = sel and T.orange or T.line
					chip.stroke.Thickness = sel and 2 or 1.5
					chip.btn.BackgroundColor3 = sel and T.panelHi:Lerp(T.orange, 0.12) or T.panelHi
				end
			end
			if not w.availBox:IsFocused() then
				w.availBox.Text = tostring(math.floor(d.avail))
			end
			w.autoBtn.setEnabled(Inv.source[name] ~= nil or Inv.mode[name] == "manual")
			if d.kind == "auto" then
				w.invSource.Text = "Source: AUTO — " .. (Inv.source[name] and Inv.source[name].desc or "?") .. ". Verify it matches your hotbar."
			else
				w.invSource.Text = "Source: MANUAL. Type how many " .. plural_ .. " you have (the game's inventory couldn't be read)."
			end
		end)

		safe("render: requirements", function()
			local show = S.plan ~= nil and not tracking and S.track ~= "done"
			w.reqSec.Visible = show
			if not show then
				return
			end
			w.reqTotal.Text = line("Cells in build", fmt(d.total))
			w.reqFilled.Visible = d.scanReady
			w.reqFilled.Text = line("Already filled (detected)", fmt(d.filled))
			w.reqRequired.Text = line(plural_ .. " Required", fmt(d.required))
			w.reqAvail.Text = line(plural_ .. " Available", fmt(d.avail) .. (d.kind == "manual" and " (manual)" or ""))
			w.reqMissing.Text = line(plural_ .. " Missing", fmt(d.missing), d.missing > 0 and "#F05248" or "#58D67E")
			w.reqProgress.Text = line("Progress", fmt(math.min(d.avail, d.required)) .. " / " .. fmt(d.required))
			w.reqBar.set(d.required > 0 and math.min(1, d.avail / d.required) or 0, d.missing > 0 and T.red or T.green)
			local bannerKind, bannerMsg
			if S.planCode then
				bannerKind, bannerMsg = "error", S.planCode == "TOO_LARGE" and "AREA TOO LARGE TO PLAN" or "INVALID SELECTION"
			elseif d.scanReady and d.required == 0 then
				bannerKind, bannerMsg = "warn", "NOTHING TO BUILD — THE AREA IS ALREADY FILLED"
			elseif d.missing > 0 then
				bannerKind = "error"
				bannerMsg = string.format("NOT ENOUGH RESOURCES — COLLECT %s MORE %s", fmt(d.missing), string.upper(plural_))
			elseif Scan.tooLarge then
				bannerKind, bannerMsg = "warn", "ALL MATERIALS AVAILABLE — AREA TOO LARGE FOR LIVE TRACKING"
			else
				bannerKind, bannerMsg = "ok", "ALL MATERIALS AVAILABLE — READY TO BUILD"
			end
			local col = (bannerKind == "ok" and T.green) or (bannerKind == "warn" and T.yellow) or T.red
			w.bannerText.Text = bannerMsg
			w.bannerText.TextColor3 = col
			w.bannerStroke.Color = col
			w.banner.BackgroundColor3 = (bannerKind == "ok") and Color3.fromRGB(22, 40, 28)
				or (bannerKind == "warn") and Color3.fromRGB(46, 40, 18) or Color3.fromRGB(46, 24, 24)
		end)

		safe("render: progress", function()
			local show = S.track ~= "off"
			w.progSec.Visible = show
			if not show then
				stripFill.Size = UDim2.new(0, 0, 1, 0)
				reopen.Text = "AUTO BUILDER"
				return
			end
			local titles = { running = "AUTO BUILDER ACTIVE", paused = "AUTO BUILDER PAUSED", done = "BUILD COMPLETE" }
			local statuses = { running = "Tracking...", paused = "Paused", done = "Complete!" }
			local colors = { running = "#FF8C14", paused = "#FFCD46", done = "#58D67E" }
			w.progTitle.Text = titles[S.track]
			w.progBuilding.Text = line("Building", buildLabel(name, S.opts.mode))
			w.progPlaced.Text = line("Blocks Placed", fmt(d.placed or 0) .. " / " .. fmt(d.toPlace or 0))
			w.progPct.Text = line("Progress", string.format("%.1f%%", (d.progress or 0) * 100))
			w.progStatus.Text = line("Status", statuses[S.track], colors[S.track])
			w.progBar.set(d.progress or 0, S.track == "paused" and T.yellow or (S.track == "done" and T.green or T.orange))
			stripFill.Size = UDim2.new(math.clamp(d.progress or 0, 0, 1), 0, 1, 0)
			reopen.Text = tracking and string.format("AUTO BUILDER  %d%%", math.floor((d.progress or 0) * 100 + 0.5)) or "AUTO BUILDER"
		end)

		safe("render: buttons", function()
			local canStart = S.plan ~= nil and S.track ~= "running" and S.track ~= "paused" and S.detect
				and Scan.order ~= nil and not S.pick
			w.startBtn.setEnabled(canStart)
			w.pauseBtn.setEnabled(S.track == "running")
			w.resumeBtn.setEnabled(S.track == "paused")
			w.cancelBtn.setEnabled(S.track == "running" or S.track == "paused" or S.pick ~= nil)
		end)
	end

	UI.ready = true
	safe("build: chips", rebuildChips)
	applyMin()
	log("INFO", "interface built")
	return kind
end

----------------------------------------------------------------------------------------------
-- 11. Start-up
----------------------------------------------------------------------------------------------
local okGui = safe("buildGui", buildGui)
local okPreview = safe("Preview.init", Preview.init)
if not okPreview then
	log("ERROR", "3D preview could not be created; the planner still works, but you won't see the outline.")
end
if okGui then
	safe("first render", function()
		Inv.rescan(S.opts.material)
		render()
		toast("Auto Builder loaded. Press SELECT BUILD AREA.  (RightShift hides/shows)", "success")
	end)
end

-- 4x per second: follow inventory changes, tracking progress and the "next blocks" highlights
task.spawn(function()
	while ARB.alive do
		task.wait(0.25)
		safe("tick", function()
			-- While just planning (not tracking), re-check the area every few seconds so the
			-- "already filled / required" numbers follow what you place. Big areas skip this and
			-- are read fresh when you press START instead.
			if S.plan and S.track == "off" and not S.pick and S.detect and Scan.order and Scan.done
				and Scan.n <= 3000 and os.clock() - (Scan.lastDone or 0) > 3 then
				Scan.done, Scan.i = false, 1
			end
			if S.track == "running" then
				if Scan.order and Scan.filledCount >= Scan.n and Scan.n > 0 then
					trackComplete()
					return
				end
				updateGhosts()
			end
			render()
		end)
	end
end)

log("INFO", "ready - window should be visible now (top-right). RightShift toggles it.")
