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
