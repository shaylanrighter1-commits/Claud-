--[[
	ABOVE[RUINS] | AUTO BUILDER   (single script for MacSploit)

	HOW TO USE
	  1. Join the game, stand near the spot, camera angled so the whole area is on screen.
	  2. Paste this whole file into MacSploit and Execute. A small menu appears (top-right).
	  3. Put the block you want in your hand (press its hotbar number). The menu shows it.
	  4. SELECT AREA -> click corner A, then the opposite corner B (orange outline = what gets filled).
	  5. AUTO BUILD. It places the blocks one at a time and skips cells that are already filled.
	     It stops if you run out of blocks or placement fails, and tells you why. STOP stops it at once.
	  RightShift hides / shows the menu.   Don't touch the mouse while it is building.

	HOW IT PLACES BLOCKS
	  It never calls the game's remotes and never touches your inventory. For each empty cell it works out
	  where on screen a face next to that cell is, moves the mouse there and clicks with your block in hand
	  - exactly what you would do - so the game's own building code (range, ownership, inventory, cooldown)
	  decides whether the block is placed. After each click it checks that a block really appeared in the
	  right cell. If clicks stop working, or blocks land in the wrong place, it stops and tells you why.

	NOTE: running scripts through an executor is against Roblox's Terms of Use and can get an account
	banned, and automated clicking may also break the game's own rules. Use at your own risk.
]]

----------------------------------------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------------------------------------
local CONFIG = {
	DEBUG = true, -- print [AutoBuilder] lines to the console (F9) as well
	CONTAINER = "auto", -- "auto" | "gethui" | "coregui" | "playergui"  (where the menu is parented)
	TOGGLE_KEY = Enum.KeyCode.RightShift,

	SELECT_ADJACENT = true, -- clicking the ground selects the empty cell above it
	MAX_CELLS = 5000, -- biggest area allowed
	DEFAULT_GRID = 4, -- studs per block, used only if the grid can't be detected

	PLACE_DELAY = 0.12, -- pause between blocks (seconds)
	PLACE_TIMEOUT = 1.2, -- how long to wait for a block to appear after a click
	MAX_REACH = 80, -- ignore targets farther than this from your character (studs)
	MAX_FAILS = 3, -- this many failed blocks in a row stops the build

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

-- does this part look like one of the game's blocks (not the ground plate, not a flower)?
local function qualifies(p)
	if not p:IsA("BasePart") or p:IsA("Terrain") or p.Transparency >= 0.9 then
		return false
	end
	local s = S.grid.size
	local sz = p.Size
	return math.min(sz.X, sz.Y, sz.Z) >= s * CONFIG.OCC_MIN_FRACTION and math.max(sz.X, sz.Y, sz.Z) <= s * CONFIG.OCC_MAX_MULT
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
		if p.Transparency < 0.9 and isCube(p) then
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
local function buildOrder(mn, mx)
	local xs, ys, zs, n = {}, {}, {}, 0
	for y = mn.y, mx.y do -- bottom layer first
		local row = 0
		for z = mn.z, mx.z do -- row by row, alternating direction ("snake")
			local x1, x2, step = mn.x, mx.x, 1
			if row % 2 == 1 then
				x1, x2, step = mx.x, mn.x, -1
			end
			for x = x1, x2, step do
				n += 1
				xs[n], ys[n], zs[n] = x, y, z
			end
			row += 1
		end
	end
	return { n = n, xs = xs, ys = ys, zs = zs }
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

local function ensureEquipped()
	local b = S.block
	if not b then
		return false
	end
	local char = LocalPlayer.Character
	if not char then
		return false
	end
	local tool = resolveTool()
	if not tool then
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

----------------------------------------------------------------------------------------------
-- 8. Input: move the mouse and click, the way you would (verified, never blind)
----------------------------------------------------------------------------------------------
local Input = { method = nil, off = Vector2.new(0, 0) }
function Input.detect()
	local ok, vim = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if ok and vim then
		Input.vim, Input.method = vim, "VirtualInputManager"
	elseif mousemoveabs ~= nil and mouse1click ~= nil then
		Input.method = "executor mouse functions"
	end
	log("INFO", "mouse control:", Input.method or "NOT AVAILABLE")
end

local function rawMove(x, y)
	if Input.vim then
		Input.vim:SendMouseMoveEvent(x, y, game)
	else
		mousemoveabs(x, y)
	end
end

-- Moves the cursor and confirms (with GetMouseLocation) that it really is there before returning true.
function Input.moveTo(x, y)
	for _ = 1, 5 do
		rawMove(x + Input.off.X, y + Input.off.Y)
		task.wait(0.03)
		local err = Vector2.new(x, y) - UIS:GetMouseLocation()
		if math.abs(err.X) <= 3 and math.abs(err.Y) <= 3 then
			return true
		end
		Input.off = Input.off + err -- learn the offset between what we send and where the cursor lands
		if Input.off.Magnitude > 200 then
			Input.off = Vector2.new(0, 0)
			return false
		end
	end
	Input.off = Vector2.new(0, 0)
	return false
end

function Input.click(x, y)
	if Input.vim then
		Input.vim:SendMouseButtonEvent(x + Input.off.X, y + Input.off.Y, 0, true, game, 1)
		task.wait(0.04)
		Input.vim:SendMouseButtonEvent(x + Input.off.X, y + Input.off.Y, 0, false, game, 1)
	else
		mouse1click()
	end
end

----------------------------------------------------------------------------------------------
-- 9. Aiming: where on screen is a face next to this cell?
----------------------------------------------------------------------------------------------
local function rayParams()
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.IgnoreWater = true
	p.FilterDescendantsInstances = characters()
	return p
end

-- first thing you can SEE along camera -> point (skips invisible volumes and characters)
local function visibleHit(point)
	local cam = workspace.CurrentCamera
	local origin = cam.CFrame.Position
	local dir = point - origin
	local dist = dir.Magnitude
	if dist < 1 then
		return nil
	end
	local params = rayParams()
	local ignore = characters()
	for _ = 1, 6 do
		params.FilterDescendantsInstances = ignore
		local res = workspace:Raycast(origin, dir.Unit * (dist + S.grid.size), params)
		if not res then
			return nil
		end
		if res.Instance:IsA("BasePart") and not res.Instance:IsA("Terrain") and res.Instance.Transparency >= 0.9 then
			ignore[#ignore + 1] = res.Instance
		else
			return res
		end
	end
	return nil
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

local DIRS = {
	Vector3.new(0, -1, 0), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0),
	Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(0, 1, 0),
}

-- Returns {x, y} screen position to click so the game's own "place block" lands in `cell`,
-- or nil + the reason it can't be aimed right now.
local function findAim(cell)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil, "no camera"
	end
	local s = S.grid.size
	local c = cellCenter(cell)
	local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	if hrp and (hrp.Position - c).Magnitude > CONFIG.MAX_REACH then
		return nil, "too far from you - walk closer"
	end
	local why = "hidden from the camera - move it so you can see the area"
	local view = cam.ViewportSize

	local function screenOf(point)
		local sp, on = cam:WorldToViewportPoint(point)
		if not on or sp.Z <= 0 or sp.X < 8 or sp.Y < 8 or sp.X > view.X - 8 or sp.Y > view.Y - 8 then
			why = "off screen - keep the whole area in view"
			return nil
		end
		if overFrameAt(UI.window, sp.X, sp.Y) or overFrameAt(UI.reopen, sp.X, sp.Y) then
			why = "behind the Auto Builder menu - drag it out of the way"
			return nil
		end
		if gameGuiAt(sp.X, sp.Y) then
			why = "behind one of the game's buttons"
			return nil
		end
		return sp
	end

	-- 1) a face of a neighbouring block / the ground that touches this cell
	for _, d in ipairs(DIRS) do
		local fp = c + d * (s / 2)
		local res = visibleHit(fp)
		if res and (res.Position - fp).Magnitude <= s * 0.3 and res.Normal:Dot(-d) > 0.8 then
			local sp = screenOf(res.Position)
			if sp then
				return { x = sp.X, y = sp.Y }
			end
		end
	end

	-- 2) ground that isn't exactly on the grid: aim at the surface right under the cell
	local down = workspace:Raycast(c + Vector3.new(0, s, 0), Vector3.new(0, -s * 2.5, 0), rayParams())
	if down and down.Normal.Y > 0.8 and math.abs(down.Position.Y - (c.Y - s / 2)) <= s * 0.8 then
		local p = Vector3.new(c.X, down.Position.Y, c.Z)
		local res = visibleHit(p)
		if res and (res.Position - p).Magnitude <= s * 0.3 and res.Normal.Y > 0.8 then
			local sp = screenOf(res.Position)
			if sp then
				return { x = sp.X, y = sp.Y }
			end
		end
	end
	return nil, why
end

----------------------------------------------------------------------------------------------
-- 10. Placing one block, and checking that it really happened
----------------------------------------------------------------------------------------------
-- returns "placed" | "failed" | "noaim" | "nocursor" | "misplaced", extra
local function placeCell(cell)
	local aim, why = findAim(cell)
	if not aim then
		return "noaim", why
	end
	local s = S.grid.size
	local center = cellCenter(cell)
	refreshOverlapFilter()
	local before = nearbyBlocks(center)

	if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
		return "nocursor", "the mouse is locked (shift-lock / first person) - switch to a free cursor"
	end
	local okMove, moved = pcall(Input.moveTo, aim.x, aim.y)
	if not okMove then
		log("ERROR", "mouse move failed:", moved)
		return "nocursor", "this executor's mouse control errored (see console)"
	end
	if not moved then
		return "nocursor", "couldn't move the mouse to the target"
	end
	local okClick, clickErr = pcall(Input.click, aim.x, aim.y)
	if not okClick then
		log("ERROR", "mouse click failed:", clickErr)
		return "nocursor", "this executor's mouse click errored (see console)"
	end

	local newPart
	local t0 = os.clock()
	while os.clock() - t0 < CONFIG.PLACE_TIMEOUT and not newPart do
		task.wait(0.05)
		refreshOverlapFilter()
		for inst in pairs(nearbyBlocks(center)) do
			if not before[inst] then
				newPart = inst
				break
			end
		end
	end
	if not newPart then
		return "failed"
	end

	-- A block appeared. Is the game's grid where we think it is?
	local off = newPart.Position - center
	local wrapped = Vector3.new(wrapHalf(off.X, s), wrapHalf(off.Y, s), wrapHalf(off.Z, s))
	if math.max(math.abs(wrapped.X), math.abs(wrapped.Y), math.abs(wrapped.Z)) > s * 0.08 then
		S.grid.origin = S.grid.origin + wrapped
		log("INFO", string.format("grid corrected by (%.2f, %.2f, %.2f)", wrapped.X, wrapped.Y, wrapped.Z))
		Preview.setArea(S.min, S.max)
	end
	local landed = worldToCell(newPart.Position)
	if not sameCell(landed, cell) then
		return "misplaced", string.format("a block landed in cell (%d,%d,%d) instead of (%d,%d,%d)", landed.x, landed.y, landed.z, cell.x, cell.y, cell.z)
	end
	return "placed"
end

----------------------------------------------------------------------------------------------
-- 11. The block in your hand + the build loop
----------------------------------------------------------------------------------------------
-- The block you're holding IS the block that gets placed. This follows your hotbar automatically.
local function detectBlock()
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return S.block ~= nil -- nothing in hand right now: keep the last one so AUTO BUILD can re-equip it
	end
	local name = cleanName(tool.Name)
	if not S.block or S.block.name ~= name then
		S.manualOwned = nil -- a different block: a count typed in for the old one no longer applies
		guiSource, guiSourceFor = nil, nil
		log("INFO", "holding:", name)
	end
	S.block = { name = name, tool = tool }
	return true
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

local function runBuild(run)
	local order = S.order
	if not order then
		return
	end
	refreshOverlapFilter()

	-- Fresh look at the world: which cells are still empty? (Existing blocks are skipped.)
	local todo = {}
	for i = 1, order.n do
		if not cellOccupied({ x = order.xs[i], y = order.ys[i], z = order.zs[i] }) then
			todo[#todo + 1] = i
		end
		if i % 150 == 0 then
			task.wait()
			if S.runId ~= run then
				return
			end
			refreshOverlapFilter()
		end
	end
	S.total, S.placed = #todo, 0
	if S.total == 0 then
		S.needed = 0
		stopBuild(run, "Nothing to build - the area is already full.", "info")
		return
	end
	log("INFO", string.format("build started: %d blocks to place (%d cells in the area)", S.total, order.n))

	local fails = 0
	for pass = 1, 2 do
		local deferred, lastWhy = {}, nil
		for _, i in ipairs(todo) do
			if S.runId ~= run then
				return
			end
			local cell = { x = order.xs[i], y = order.ys[i], z = order.zs[i] }
			refreshOverlapFilter()

			if cellOccupied(cell) then
				S.total -= 1 -- filled in the meantime: skip it, don't spend a block
			else
				local owned = readOwned()
				if owned ~= nil and owned <= 0 then
					return stopBuild(run, string.format("Out of blocks. Placed %d of %d - get more, then press AUTO BUILD to carry on.", S.placed, S.total), "error")
				end
				if not ensureEquipped() then
					return stopBuild(run, "Stopped: hold '" .. S.block.name .. "' in your hand.", "error")
				end
				if S.runId ~= run then
					return
				end

				local result, extra = placeCell(cell)
				if result == "failed" then
					task.wait(0.25) -- one retry (the game may have a short placement cooldown)
					if S.runId ~= run then
						return
					end
					result, extra = placeCell(cell)
				end

				if S.runId ~= run then
					-- STOP was pressed while that click was in flight. If the block really appeared,
					-- still count it - but only when no newer build has started in the meantime.
					if result == "placed" and S.runId == run + 1 and S.state ~= "building" then
						S.placed += 1
						S.placedAll += 1
					end
					return
				end

				if result == "placed" then
					S.placed += 1 -- counted only because a block was seen appearing in this cell
					S.placedAll += 1
					fails = 0
					render()
					task.wait(CONFIG.PLACE_DELAY)
				elseif result == "noaim" then
					deferred[#deferred + 1] = i
					lastWhy = extra
				elseif result == "misplaced" or result == "nocursor" then
					return stopBuild(run, "Stopped: " .. tostring(extra) .. ".", "error")
				else -- "failed": the click didn't produce a block
					deferred[#deferred + 1] = i
					fails += 1
					if fails >= CONFIG.MAX_FAILS then
						return stopBuild(run, "Stopped: the game isn't placing blocks. Check: block in hand, in range, area on screen, blocks left.", "error")
					end
				end
			end
		end
		todo = deferred
		if #todo == 0 then
			break
		end
		if pass == 2 then
			return stopBuild(run, string.format("Stopped: %d blocks couldn't be placed (%s).", #todo, lastWhy or "the game didn't accept them"), "error")
		end
		log("INFO", string.format("pass %d done, retrying %d cells", pass, #todo))
		task.wait(0.3)
	end

	if S.runId ~= run then
		return
	end
	S.state = "done"
	status(string.format("Done! %d blocks placed.", S.placed), "success")
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
	detectBlock()
	if not S.block then
		status("Equip a block in your hotbar first.", "error")
		return
	end
	if not Input.method then
		status("This executor can't control the mouse, so I can't place blocks for you.", "error")
		return
	end
	if not ensureEquipped() then
		status("Hold '" .. S.block.name .. "' in your hand first.", "error")
		return
	end
	if looksLikeTool(S.block.name) then
		status("'" .. S.block.name .. "' looks like a tool - clicking with it could break blocks. Hold the block you want to place.", "error")
		return
	end
	local owned = readOwned()
	if owned == nil then
		-- Not being able to read the count also means I can't tell this is a stackable block, and I
		-- can't stop when you run out - so ask for it once.
		status("I can't read how many " .. S.block.name .. " you have. Type the number into OWNED, then press AUTO BUILD.", "error")
		return
	end
	if owned <= 0 then
		status("You have no " .. S.block.name .. " left.", "error")
		return
	end
	if S.state == "building" then
		return -- a second click arrived while the checks above were running
	end
	S.runId += 1
	local run = S.runId
	S.state = "building"
	S.placed, S.total = 0, 0
	status("Building...", "info")
	task.spawn(function()
		safe("build", runBuild, run)
		if S.runId == run and S.state == "building" then
			S.state = "idle" -- the loop died unexpectedly; never leave the menu stuck
			status("The build stopped because of an error (see the console).", "error")
		end
		if S.stoppedRun == run and S.state ~= "building" then
			status(string.format("Stopped. %d blocks placed.", S.placed), "info")
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
		if res.Instance:IsA("BasePart") and not res.Instance:IsA("Terrain") and res.Instance.Transparency >= 0.9 then
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
		status("Press STOP first.", "error")
		return
	end
	S.a, S.b, S.state = nil, nil, "idle"
	Preview.clear()
	setSelection()
	if not S.grid.confirmed then
		detectGrid()
	end
	S.pick = "A"
	bindPick()
	status("Click the first corner (Point A).", "info")
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
		if isCube(part) and (not S.grid.confirmed or math.abs(part.Size.X - S.grid.size) < 0.05) then
			adoptGrid(part)
		end
		S.a = cellFromHit(res)
		Preview.setA(S.a)
		S.pick = "B"
		S.hover = nil
		status("Now click the opposite corner (Point B).", "info")
	elseif S.pick == "B" then
		S.b = cellFromHit(res)
		stopPicking()
		Preview.setA(nil)
		setSelection()
		if S.tooLarge then
			S.a, S.b = nil, nil
			setSelection()
		else
			status(string.format("Area selected: %s. Hold your block and press AUTO BUILD.", dimsText()), "info")
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
		status("Stopping...", "info")
		S.needed = nil
		task.spawn(countUnfilled)
	end
	render()
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
		Text = '<font color="#FF8C14">ABOVE[RUINS]</font> AUTO BUILDER', RichText = true, TextColor3 = T.text,
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
		w.areaBtn = button("SELECT AREA", "secondary", 32)
		w.areaBtn.onClick = startPicking
		add(body, w.areaBtn.inst)

		-- BLOCK: GRASS BLOCK   (follows whatever is in your hand)
		w.blockLabel = new("TextLabel", {
			BackgroundColor3 = T.panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 28),
			Text = "BLOCK: EQUIP ONE", TextColor3 = T.text, Font = T.bold, TextSize = 13,
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

		-- AUTO BUILD
		w.autoBtn = button("AUTO BUILD", "primary", 36)
		w.autoBtn.onClick = autoBuild
		add(body, w.autoBtn.inst)

		-- STOP
		w.stopBtn = button("STOP", "danger", 30)
		w.stopBtn.onClick = stop
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

			w.areaBtn.inst.Text = (S.pick == "A" and "CLICK POINT A...") or (S.pick == "B" and "CLICK POINT B...")
				or (S.min and ("SELECT AREA  ·  " .. dimsText())) or "SELECT AREA"
			w.areaBtn.setEnabled(not busy)

			w.blockLabel.Text = S.block and ("BLOCK: " .. string.upper(S.block.name)) or "BLOCK: EQUIP ONE"
			w.needed.Text = "NEEDED: " .. (needed ~= nil and fmt(needed) or (S.order and "..." or "-"))

			if not w.owned:IsFocused() then
				w.owned.Text = owned ~= nil and tostring(owned) or ""
			end
			if owned == nil then
				w.owned.TextColor3 = T.text
			elseif needed ~= nil and owned < needed then
				w.owned.TextColor3 = T.red
			else
				w.owned.TextColor3 = T.green
			end

			local label = "AUTO BUILD"
			if S.state == "building" then
				label = string.format("BUILDING  %s/%s", fmt(S.placed), fmt(S.total))
			elseif S.state == "done" then
				label = string.format("DONE  %s/%s", fmt(S.placed), fmt(S.total))
			end
			w.autoBtn.inst.Text = label
			w.autoBtn.setEnabled(S.order ~= nil and not busy and not S.pick)
			w.stopBtn.setEnabled(busy or S.pick ~= nil)

			w.statusBtn.Text = S.status
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

status("Hold a block, press SELECT AREA, then AUTO BUILD.  (RightShift hides the menu)", "info")
log("INFO", "ready - the menu should be visible now (top-right)")
