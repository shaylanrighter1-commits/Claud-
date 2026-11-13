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
		if not jobActive() then
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
	refreshPreview()
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
