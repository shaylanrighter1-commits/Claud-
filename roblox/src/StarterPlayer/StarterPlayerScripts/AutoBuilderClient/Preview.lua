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
