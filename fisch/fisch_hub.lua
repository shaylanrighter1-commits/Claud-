--[[
  FISCH | AUTO HUB  -  interface prototype (MacSploit / Luau)

  CONNECTED (works now, uses only standard Roblox player APIs):
    - Menu: drag, tabs, minimize, close, reopen (button or RightShift)
    - Equip Rod: equips a rod Tool from your Backpack and checks that it equipped
    - Rod status: live, from your character/backpack
    - Waypoints: save the spot you're standing on under an island name
      (refuses mid-air or in water) and keep it in a file between sessions
    - Guide: shows distance and which way to turn toward a saved waypoint
      while you travel there yourself (boat, walking, in-game travel)
    - Stop All, Show/Hide Status, auto-stop on respawn or when the rod is unequipped

  NOT CONNECTED (the buttons show a message and do nothing):
    - Auto cast / bite detection / reeling  (AutoFish backend below is empty)
    - Fish caught counter                   (Fisch has no public catch signal)
    - Teleport                              (no supported scripted travel)
  The prototype never reports a catch, reward or arrival it didn't observe.
]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local HttpService      = game:GetService("HttpService")

local player = Players.LocalPlayer

-- Replace a previous copy if the script is executed again.
local env = (getgenv and getgenv()) or _G
if env.FischHub and env.FischHub.destroy then pcall(env.FischHub.destroy) end

local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

---------------------------------------------------------------- theme / helpers
local C = {
	bg        = Color3.fromRGB(16, 18, 24),
	panel     = Color3.fromRGB(25, 28, 36),
	item      = Color3.fromRGB(34, 38, 49),
	accent    = Color3.fromRGB(58, 130, 246),
	accentDim = Color3.fromRGB(36, 78, 150),
	text      = Color3.fromRGB(232, 236, 244),
	sub       = Color3.fromRGB(142, 150, 168),
	good      = Color3.fromRGB(72, 200, 122),
	warn      = Color3.fromRGB(240, 172, 64),
	bad       = Color3.fromRGB(232, 84, 84),
}
local WHITE = Color3.new(1, 1, 1)

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function round(o, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o)
	return o
end
local function pad(o, l, r, t, b)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingRight = UDim.new(0, r or l),
		PaddingTop = UDim.new(0, t or 0), PaddingBottom = UDim.new(0, b or t or 0),
	}, o)
end
local function tween(o, t, props)
	local tw = TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
local function list(o, padding, horizontal)
	return make("UIListLayout", {
		Padding = UDim.new(0, padding),
		FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, o)
end

local function button(parent, text, color, order)
	local base = color or C.item
	local hot = base:Lerp(WHITE, 0.12)
	local b = round(make("TextButton", {
		Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = base, BorderSizePixel = 0,
		AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = C.text, Text = text, LayoutOrder = order or 0,
	}, parent), 7)
	b.MouseEnter:Connect(function() tween(b, 0.12, { BackgroundColor3 = hot }) end)
	b.MouseLeave:Connect(function() tween(b, 0.12, { BackgroundColor3 = base }) end)
	return b
end

local function label(parent, text, color, order, height)
	return make("TextLabel", {
		Size = UDim2.new(1, 0, 0, height or 18), BackgroundTransparency = 1,
		Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = color or C.sub,
		TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, RichText = true,
		Text = text, LayoutOrder = order or 0,
	}, parent)
end

local function card(parent, text, color, order, height)
	local f = round(make("Frame", {
		Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = C.panel,
		BorderSizePixel = 0, LayoutOrder = order or 0,
	}, parent), 7)
	pad(f, 8, 8, 4)
	local l = label(f, text, color)
	l.Size = UDim2.fromScale(1, 1)
	l.TextSize = 11
	return f, l
end

local function toggleRow(parent, text, order, onClick)
	local row = round(make("TextButton", {
		Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.item, BorderSizePixel = 0,
		AutoButtonColor = false, Text = "", LayoutOrder = order or 0,
	}, parent), 7)
	local l = make("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -64, 1, 0),
		Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left, Text = text,
	}, row)
	local track = round(make("Frame", {
		Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -48, 0.5, -10),
		BackgroundColor3 = C.bg, BorderSizePixel = 0,
	}, row), 10)
	local knob = round(make("Frame", {
		Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2),
		BackgroundColor3 = C.sub, BorderSizePixel = 0,
	}, track), 8)
	row.MouseButton1Click:Connect(onClick)
	return function(on, newText)
		tween(track, 0.15, { BackgroundColor3 = on and C.accent or C.bg })
		tween(knob, 0.15, {
			Position = on and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2),
			BackgroundColor3 = on and WHITE or C.sub,
		})
		if newText then l.Text = newText end
	end
end

---------------------------------------------------------------- screen gui
local gui = make("ScreenGui", {
	Name = "FischHub", ResetOnSpawn = false, DisplayOrder = 50,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
if gethui then pcall(function() gui.Parent = gethui() end) end
if not gui.Parent then pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local W, H, TITLE_H = 300, 380, 34
local state = { autoFish = false, guide = nil, minimized = false, open = true }

local main = round(make("Frame", {
	Size = UDim2.fromOffset(W, 0), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
	BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true,
}, gui), 10)
make("UIStroke", { Color = C.accentDim, Thickness = 1, Transparency = 0.25 }, main)

-- title bar
local titleBar = round(make("Frame", {
	Size = UDim2.new(1, 0, 0, TITLE_H), BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, main), 10)
make("Frame", { Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10),
	BackgroundColor3 = C.panel, BorderSizePixel = 0 }, titleBar)
make("Frame", { Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = C.accent, BorderSizePixel = 0 }, titleBar)
make("TextLabel", {
	BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -80, 1, 0),
	Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text, RichText = true,
	TextXAlignment = Enum.TextXAlignment.Left, Text = 'FISCH <font color="#3A82F6">| AUTO HUB</font>',
}, titleBar)

local function titleButton(text, x)
	local b = round(make("TextButton", {
		Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, x, 0.5, -12),
		BackgroundColor3 = C.item, BorderSizePixel = 0, AutoButtonColor = false,
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text, Text = text,
	}, titleBar), 6)
	b.MouseEnter:Connect(function() tween(b, 0.12, { BackgroundColor3 = C.accentDim }) end)
	b.MouseLeave:Connect(function() tween(b, 0.12, { BackgroundColor3 = C.item }) end)
	return b
end
local minBtn   = titleButton("–", -58)
local closeBtn = titleButton("×", -30)

-- tabs
local tabBar = round(make("Frame", {
	Position = UDim2.fromOffset(10, TITLE_H + 10), Size = UDim2.new(1, -20, 0, 28),
	BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, main), 7)
pad(tabBar, 3, 3, 3)
list(tabBar, 3, true)

local pages = make("Frame", {
	Position = UDim2.fromOffset(10, TITLE_H + 46), Size = UDim2.new(1, -20, 1, -(TITLE_H + 46 + 46)),
	BackgroundTransparency = 1,
}, main)

-- status bar
local statusBar = round(make("Frame", {
	Position = UDim2.new(0, 10, 1, -38), Size = UDim2.new(1, -20, 0, 30),
	BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, main), 7)
pad(statusBar, 8, 8, 2)
local statusLabel = label(statusBar, "Ready.", C.sub)
statusLabel.Size = UDim2.fromScale(1, 1)
statusLabel.TextSize = 11

local function setStatus(msg, color)
	statusLabel.Text = msg
	statusLabel.TextColor3 = color or C.sub
end

local tabs, tabOrder = {}, 0
local function addTab(name)
	tabOrder = tabOrder + 1
	local b = round(make("TextButton", {
		Size = UDim2.new(1 / 3, -2, 1, 0), BackgroundColor3 = C.panel, BorderSizePixel = 0,
		AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = C.sub, Text = name, LayoutOrder = tabOrder,
	}, tabBar), 5)
	local page = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, pages)
	tabs[name] = { btn = b, page = page }
	return b, page
end
local function selectTab(name)
	for n, t in pairs(tabs) do
		local on = (n == name)
		t.page.Visible = on
		tween(t.btn, 0.15, { BackgroundColor3 = on and C.accent or C.panel, TextColor3 = on and WHITE or C.sub })
	end
end

---------------------------------------------------------------- rod helpers (CONNECTED)
local function isRod(o)
	return o:IsA("Tool") and string.find(string.lower(o.Name), "rod", 1, true) ~= nil
end
local function findRod(container)
	if not container then return nil end
	for _, o in ipairs(container:GetChildren()) do
		if isRod(o) then return o end
	end
	return nil
end
local function equippedRod() return findRod(player.Character) end
local function backpackRod() return findRod(player:FindFirstChildOfClass("Backpack")) end

-- Equips via the standard Humanoid API and reports success only if the rod is actually held.
local function equipRod()
	local held = equippedRod()
	if held then return true, "Rod equipped: " .. held.Name end
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false, "No living character." end
	local rod = backpackRod()
	if not rod then return false, "No rod found in your backpack." end
	hum:EquipTool(rod)
	for _ = 1, 10 do
		if equippedRod() then return true, "Equipped " .. rod.Name .. "." end
		task.wait(0.05)
	end
	return false, "Equip didn't take effect."
end

---------------------------------------------------------------- AUTO FISH BACKEND (NOT CONNECTED)
-- Casting, bite detection and reeling would depend on Fisch's own undocumented
-- interface, or on its private remotes. Neither is used, so this stays empty:
-- nothing is automated and no catches are ever reported.
local AutoFish = { connected = false }
function AutoFish.start()
	return false, "Cast/bite/reel not connected."
end
function AutoFish.stop() end

---------------------------------------------------------------- FISHING TAB
local fishTab, fishPage = addTab("Fishing")
list(fishPage, 6)

local autoSetters = {}
local fishStatusLabel, rodLabel

local function setFishStatus(msg, color)
	fishStatusLabel.Text = "Status: " .. msg
	setStatus(msg, color)
end
local function renderAuto()
	for _, set in ipairs(autoSetters) do
		set(state.autoFish, "AUTO FISH: " .. (state.autoFish and "ON" or "OFF"))
	end
end
local function setAutoFish(on, reason)
	if not on then
		if state.autoFish then AutoFish.stop() end
		state.autoFish = false
		renderAuto()
		setFishStatus(reason or "Idle.", reason and C.warn or C.sub)
		return
	end
	task.spawn(function()
		setFishStatus("Equipping rod…")
		local rodOk, rodMsg = equipRod()
		if not rodOk then
			state.autoFish = false
			renderAuto()
			setFishStatus(rodMsg, C.bad)
			return
		end
		local started, msg = AutoFish.start()
		-- The switch shows ON only if the backend really started.
		state.autoFish = started
		renderAuto()
		if started then
			setFishStatus("Running.", C.good)
		else
			setFishStatus(rodMsg .. " " .. msg, C.warn)
		end
	end)
end

table.insert(autoSetters, toggleRow(fishPage, "AUTO FISH: OFF", 1, function()
	setAutoFish(not state.autoFish)
end))
card(fishPage, '<font color="#F0AC40"><b>NOT CONNECTED:</b></font> auto cast, bite detection and reeling. '
	.. "Switching ON only equips your rod.", C.sub, 2, 40)
fishStatusLabel = label(fishPage, "Status: Idle.", C.text, 3)
rodLabel        = label(fishPage, "Rod: checking…", C.sub, 4)
label(fishPage, "Fish caught: n/a (not connected)", C.sub, 5)

local equipBtn = button(fishPage, "EQUIP ROD", C.accent, 6)
local stopBtn  = button(fishPage, "STOP", C.bad, 7)

local function refreshRod()
	local held, bag = equippedRod(), backpackRod()
	if held then
		rodLabel.Text = "Rod: " .. held.Name .. ' <font color="#48C87A">(equipped)</font>'
	elseif bag then
		rodLabel.Text = "Rod: " .. bag.Name .. " (in backpack)"
	else
		rodLabel.Text = "Rod: none found"
	end
end

equipBtn.MouseButton1Click:Connect(function()
	task.spawn(function()
		local ok, msg = equipRod()
		refreshRod()
		setFishStatus(msg, ok and C.good or C.bad)
	end)
end)
stopBtn.MouseButton1Click:Connect(function()
	setAutoFish(false, "Stopped.")
end)

---------------------------------------------------------------- TELEPORTS TAB
-- Island names only. There are no coordinates here: you save your own while
-- standing at each place. Rename or extend the list freely.
local ISLANDS = {
	"Moosewood", "Roslit Bay", "Mushgrove Swamp", "Snowcap Island", "Sunstone Island",
	"Terrapin Island", "Forsaken Shores", "Statue of Sovereignty", "Ancient Isle",
	"Keeper's Altar", "Vertigo", "The Depths", "Desolate Deep", "Brine Pool",
}
local SAVE_FILE = "FischHub_waypoints.json"
local saved = {} -- name -> {x, y, z}

if isfile and readfile then
	pcall(function()
		if isfile(SAVE_FILE) then
			local data = HttpService:JSONDecode(readfile(SAVE_FILE))
			if type(data) == "table" then saved = data end
		end
	end)
end
local function persist()
	if not writefile then return false end
	return (pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(saved)) end))
end

local tpTab, tpPage = addTab("Teleports")

local search = round(make("TextBox", {
	Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C.item, BorderSizePixel = 0,
	Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.text, PlaceholderColor3 = C.sub,
	PlaceholderText = "Search destinations…", Text = "", ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
}, tpPage), 7)
pad(search, 8)

local destList = round(make("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 1, -34 - 62),
	BackgroundColor3 = C.panel, BorderSizePixel = 0, ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, tpPage), 7)
pad(destList, 4, 7, 4)
list(destList, 3)

local guideLabel = label(tpPage, "Guide: off", C.sub)
guideLabel.Position = UDim2.new(0, 0, 1, -58)
guideLabel.Size = UDim2.new(1, 0, 0, 24)

local btnRow = make("Frame", {
	Position = UDim2.new(0, 0, 1, -28), Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1,
}, tpPage)
list(btnRow, 4, true)
local function rowButton(text, color, order)
	local b = button(btnRow, text, color, order)
	b.Size = UDim2.new(0.25, -3, 1, 0)
	b.TextSize = 11
	return b
end
local saveBtn  = rowButton("SAVE HERE", C.item, 1)
local guideBtn = rowButton("GUIDE", C.accent, 2)
local clearBtn = rowButton("CLEAR", C.item, 3)
local tpBtn    = rowButton("TELEPORT", C.item, 4)

local selected = nil

local function entryNames()
	local names, known, extra = {}, {}, {}
	for _, n in ipairs(ISLANDS) do table.insert(names, n); known[n] = true end
	for n in pairs(saved) do if not known[n] then table.insert(extra, n) end end
	table.sort(extra)
	for _, n in ipairs(extra) do table.insert(names, n) end
	return names
end

local rebuildList
rebuildList = function()
	for _, c in ipairs(destList:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	local q = string.lower(search.Text)
	local shown = 0
	for i, name in ipairs(entryNames()) do
		if q == "" or string.find(string.lower(name), q, 1, true) then
			shown = shown + 1
			local isSel = (name == selected)
			local b = round(make("TextButton", {
				Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = isSel and C.accentDim or C.item,
				BorderSizePixel = 0, AutoButtonColor = false, Text = "", LayoutOrder = i,
			}, destList), 6)
			make("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -80, 1, 0),
				Font = isSel and Enum.Font.GothamBold or Enum.Font.Gotham, TextSize = 12, TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = name,
			}, b)
			make("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.new(1, -72, 0, 0), Size = UDim2.fromOffset(64, 26),
				Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = saved[name] and C.good or C.sub, Text = saved[name] and "saved" or "no coords",
			}, b)
			b.MouseButton1Click:Connect(function()
				selected = name
				rebuildList()
				if saved[name] then
					setStatus("Selected " .. name .. ". Press GUIDE for directions.")
				else
					setStatus(name .. " has no coordinates yet. Go there and press SAVE HERE.", C.warn)
				end
			end)
		end
	end
	if shown == 0 then
		local l = label(destList, "No matches. Press SAVE HERE to save your current spot under this name.", C.sub, 0, 36)
		l.TextSize = 11
	end
end
search:GetPropertyChangedSignal("Text"):Connect(function()
	selected = nil
	rebuildList()
end)

local function stopGuide(msg, color)
	state.guide = nil
	guideBtn.Text = "GUIDE"
	guideLabel.Text = "Guide: off"
	guideLabel.TextColor3 = C.sub
	if msg then setStatus(msg, color) end
end

local function currentName()
	if selected then return selected end
	local typed = string.match(search.Text, "^%s*(.-)%s*$")
	if typed and typed ~= "" then return typed end
	return nil
end

saveBtn.MouseButton1Click:Connect(function()
	local name = currentName()
	if not name then setStatus("Select a destination or type a name first.", C.warn) return end
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then setStatus("No living character to read a position from.", C.bad) return end
	if hum.FloorMaterial == Enum.Material.Air or hum.FloorMaterial == Enum.Material.Water then
		setStatus("Stand on solid ground to save a spot (not mid-air or in water).", C.warn)
		return
	end
	local p = root.Position
	local wp = { math.floor(p.X + 0.5), math.floor(p.Y + 0.5), math.floor(p.Z + 0.5) }
	saved[name] = wp
	local stored = persist()
	selected = name
	rebuildList()
	setStatus(string.format("Saved %s (%d, %d, %d)%s", name, wp[1], wp[2], wp[3],
		stored and "." or ". This session only (no file access)."), C.good)
end)

guideBtn.MouseButton1Click:Connect(function()
	if state.guide and (state.guide == selected or not selected) then stopGuide("Guide off.") return end
	if not selected then setStatus("Select a destination first.", C.warn) return end
	if not saved[selected] then
		setStatus("No coordinates for " .. selected .. ". Visit it once and press SAVE HERE.", C.warn)
		return
	end
	state.guide = selected
	guideBtn.Text = "STOP"
	setStatus("Guiding to " .. selected .. ". Travel there by boat or on foot.", C.sub)
end)

clearBtn.MouseButton1Click:Connect(function()
	if not selected or not saved[selected] then setStatus("Nothing saved for this selection.", C.warn) return end
	local name = selected
	saved[name] = nil
	persist()
	if state.guide == name then stopGuide() end
	if not table.find(ISLANDS, name) then selected = nil end
	rebuildList()
	setStatus("Cleared " .. name .. ".")
end)

tpBtn.MouseButton1Click:Connect(function()
	setStatus("Teleport not connected: there's no supported scripted travel. Use GUIDE and travel in-game.", C.warn)
end)

-- Guide: reads only your own position and camera, updates 5x per second.
local lastGuide = 0
bind(RunService.Heartbeat, function()
	if not state.guide then return end
	local now = os.clock()
	if now - lastGuide < 0.2 then return end
	lastGuide = now

	local wp = saved[state.guide]
	if not wp then stopGuide("Guide target was removed.", C.warn) return end
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if not root or not cam then guideLabel.Text = "Guide: waiting for character…" return end

	local offset = Vector3.new(wp[1], wp[2], wp[3]) - root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local dist = flat.Magnitude
	if dist < 25 then
		stopGuide("Arrived near " .. state.guide .. ".", C.good)
		return
	end
	local look = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then return end
	look, flat = look.Unit, flat.Unit
	local angle = math.deg(math.atan2(look:Cross(flat).Y, look:Dot(flat)))
	local turn
	if math.abs(angle) < 15 then
		turn = "straight ahead"
	elseif angle < 0 then
		turn = string.format("turn right %d°", math.floor(-angle + 0.5))
	else
		turn = string.format("turn left %d°", math.floor(angle + 0.5))
	end
	guideLabel.Text = string.format("→ %s · %d studs · %s", state.guide, math.floor(dist + 0.5), turn)
	guideLabel.TextColor3 = C.text
end)

---------------------------------------------------------------- SETTINGS TAB
local setTab, setPage = addTab("Settings")
list(setPage, 6)

local function stopAll()
	setAutoFish(false, "Stopped everything.")
	stopGuide("Stopped everything.", C.warn)
end

table.insert(autoSetters, toggleRow(setPage, "AUTO FISH: OFF", 1, function()
	setAutoFish(not state.autoFish)
end))

local statusVisible = true
local setStatusToggle
setStatusToggle = toggleRow(setPage, "SHOW STATUS", 2, function()
	statusVisible = not statusVisible
	statusBar.Visible = statusVisible
	setStatusToggle(statusVisible)
end)

local minimizeBtn = button(setPage, "MINIMIZE GUI", C.item, 3)
local stopAllBtn  = button(setPage, "STOP ALL", C.bad, 4)
card(setPage,
	'<font color="#48C87A"><b>Connected:</b></font> menu, equip rod, saved spots, guide, stop.\n'
	.. '<font color="#F0AC40"><b>Not connected:</b></font> auto cast/bite/reel, catch counter, teleport.\n'
	.. "RightShift shows/hides the menu.", C.sub, 5, 62)

stopAllBtn.MouseButton1Click:Connect(stopAll)

---------------------------------------------------------------- window controls
local function setMinimized(m)
	state.minimized = m
	minBtn.Text = m and "+" or "–"
	tween(main, 0.2, { Size = UDim2.fromOffset(W, m and TITLE_H or H) })
end

local reopen = round(make("TextButton", {
	Size = UDim2.fromOffset(96, 28), Position = UDim2.new(0, 12, 0.5, -14),
	BackgroundColor3 = C.accent, BorderSizePixel = 0, AutoButtonColor = false, Visible = false,
	Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = WHITE, Text = "FISCH HUB",
}, gui), 14)

local function setOpen(open)
	state.open = open
	if open then
		reopen.Visible = false
		main.Visible = true
		tween(main, 0.2, { Size = UDim2.fromOffset(W, state.minimized and TITLE_H or H) })
	else
		reopen.Visible = true
		tween(main, 0.15, { Size = UDim2.fromOffset(W, 0) }).Completed:Connect(function()
			if not state.open then main.Visible = false end
		end)
	end
end

minBtn.MouseButton1Click:Connect(function() setMinimized(not state.minimized) end)
minimizeBtn.MouseButton1Click:Connect(function() setMinimized(true) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
reopen.MouseButton1Click:Connect(function() setOpen(true) end)
bind(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then setOpen(not state.open) end
end)

-- dragging by the title bar
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, main.Position
	end
end)
bind(UserInputService.InputChanged, function(input)
	local t = input.UserInputType
	if dragging and (t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
bind(UserInputService.InputEnded, function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then dragging = false end
end)

for name, t in pairs(tabs) do
	t.btn.MouseButton1Click:Connect(function() selectTab(name) end)
end

---------------------------------------------------------------- safety: respawn / unequip
local function hookCharacter(ch)
	ch.ChildAdded:Connect(function(o) if isRod(o) then refreshRod() end end)
	ch.ChildRemoved:Connect(function(o)
		if isRod(o) then
			refreshRod()
			if state.autoFish then setAutoFish(false, "Rod unequipped. Auto Fish stopped.") end
		end
	end)
	local hum = ch:WaitForChild("Humanoid", 5)
	if hum then
		hum.Died:Connect(function()
			if state.autoFish then setAutoFish(false, "Character died. Auto Fish stopped.") end
		end)
	end
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		bp.ChildAdded:Connect(refreshRod)
		bp.ChildRemoved:Connect(refreshRod)
	end
	refreshRod()
end
bind(player.CharacterAdded, function(ch)
	if state.autoFish then setAutoFish(false, "Respawned. Auto Fish stopped.") end
	task.spawn(hookCharacter, ch)
end)
if player.Character then task.spawn(hookCharacter, player.Character) end

---------------------------------------------------------------- start
env.FischHub = {
	destroy = function()
		for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
		AutoFish.stop()
		gui:Destroy()
	end,
}

rebuildList()
selectTab("Fishing")
setStatusToggle(true)
renderAuto()
tween(main, 0.25, { Size = UDim2.fromOffset(W, H) })
setStatus("Loaded. Auto fishing and teleport aren't connected. See Settings.", C.sub)
