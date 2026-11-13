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
