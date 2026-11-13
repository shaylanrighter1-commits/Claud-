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
