--!nocheck
-- BACKEND: everything the Auto Builder needs from YOUR game, in six small functions.
--
-- As shipped this is a self-contained TEST WORLD, so the whole system runs in an empty Baseplate:
--   * each player gets four "block" Tools (Grass Block, Dirt Block, Stone Block, Wood Planks) in the
--     normal Roblox hotbar, with a block count kept in player attributes;
--   * blocks are real Parts in Workspace.AutoBuilderBlocks;
--   * you may build in a box around the origin.
--
-- To use it in your real game, set TEST_WORLD = false and make these functions call YOUR OWN server code,
-- so your game's rules (land ownership, inventory, saving, anti-cheat) stay in charge:
--
--   Backend.getEquipped(player) -> { id, name, owned } | nil, reason     what the player is holding
--   Backend.getOwned(player, id) -> number                               how many of it they own
--   Backend.take(player, id, n)  -> boolean                              remove n from their inventory (false if they don't have it)
--   Backend.give(player, id, n)                                          put n back (used if a placement fails)
--   Backend.canBuild(player, cell) -> ok, reason                         may THIS player build in THIS cell? (land / permission)
--   Backend.isOccupied(cell) -> boolean                                  is there already a block in this cell?
--   Backend.place(player, id, cell) -> ok, reason                        really place the block (call your own placement function)
--
-- `cell` is {x=,y=,z=} on the grid in Shared.CONFIG (GRID and ORIGIN must match your game's grid).
-- Nothing here trusts the client: it only ever sends two corner cells.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage:WaitForChild("AutoBuilder"):WaitForChild("Shared"))

local Backend = {}
Backend.TEST_WORLD = true

----------------------------------------------------------------------------------------------
-- test world
----------------------------------------------------------------------------------------------
local BLOCKS = {
	grass_block = { name = "Grass Block", color = Color3.fromRGB(86, 168, 62), material = Enum.Material.Grass, start = 300 },
	dirt_block = { name = "Dirt Block", color = Color3.fromRGB(120, 85, 52), material = Enum.Material.Ground, start = 300 },
	stone_block = { name = "Stone Block", color = Color3.fromRGB(125, 128, 135), material = Enum.Material.Slate, start = 300 },
	wood_planks = { name = "Wood Planks", color = Color3.fromRGB(176, 128, 74), material = Enum.Material.WoodPlanks, start = 300 },
}
local ORDER = { "grass_block", "dirt_block", "stone_block", "wood_planks" }

-- where players may build in the test world (cells)
local ZONE = { x = 60, z = 60, yMin = 0, yMax = 40 }

local blockFolder = Workspace:FindFirstChild("AutoBuilderBlocks")
if not blockFolder then
	blockFolder = Instance.new("Folder")
	blockFolder.Name = "AutoBuilderBlocks"
	blockFolder.Parent = Workspace
end

local function owned(player, id)
	return player:GetAttribute("inv_" .. id) or 0
end

local function giveTools(player)
	local pack = player:WaitForChild("Backpack")
	for _, id in ipairs(ORDER) do
		local def = BLOCKS[id]
		local has = pack:FindFirstChild(def.name) or (player.Character and player.Character:FindFirstChild(def.name))
		if not has then
			local tool = Instance.new("Tool")
			tool.Name = def.name
			tool.RequiresHandle = false
			tool.CanBeDropped = false
			tool:SetAttribute("ItemId", id)
			tool.Parent = pack
		end
	end
end

-- called once for every player by the server script
function Backend.setup(player)
	if not Backend.TEST_WORLD then
		return
	end
	for _, id in ipairs(ORDER) do
		if player:GetAttribute("inv_" .. id) == nil then
			player:SetAttribute("inv_" .. id, BLOCKS[id].start)
		end
	end
	player.CharacterAdded:Connect(function()
		giveTools(player)
	end)
	if player.Character then
		giveTools(player)
	end
end

----------------------------------------------------------------------------------------------
-- the six functions
----------------------------------------------------------------------------------------------
function Backend.getEquipped(player)
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return nil, "Equip a block first."
	end
	local id = tool:GetAttribute("ItemId")
	local def = id and BLOCKS[id]
	if not def then
		return nil, "'" .. tool.Name .. "' is not a block that can be placed."
	end
	return { id = id, name = def.name, owned = owned(player, id) }
end

function Backend.getOwned(player, id)
	return owned(player, id)
end

function Backend.take(player, id, n)
	local have = owned(player, id)
	if have < n then
		return false
	end
	player:SetAttribute("inv_" .. id, have - n)
	return true
end

function Backend.give(player, id, n)
	player:SetAttribute("inv_" .. id, owned(player, id) + n)
end

function Backend.canBuild(_, cell)
	if math.abs(cell.x) > ZONE.x or math.abs(cell.z) > ZONE.z or cell.y < ZONE.yMin or cell.y > ZONE.yMax then
		return false, "outside the area where building is allowed"
	end
	return true
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 20
local filterAt = 0
function Backend.isOccupied(cell)
	if os.clock() - filterAt > 0.5 then
		filterAt = os.clock()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				list[#list + 1] = p.Character
			end
		end
		overlap.FilterDescendantsInstances = list
	end
	local g = Shared.CONFIG.GRID
	local x, y, z = Shared.cellCenter(cell)
	-- (a little smaller than the cell, so a neighbour that only touches it doesn't count)
	for _, part in ipairs(Workspace:GetPartBoundsInBox(CFrame.new(x, y, z), Vector3.new(g - 0.5, g - 0.5, g - 0.5), overlap)) do
		if part.CanCollide and not part:IsA("Terrain") then
			return true
		end
	end
	return false
end

function Backend.place(player, id, cell)
	local def = BLOCKS[id]
	if not def then
		return false, "unknown block"
	end
	if Backend.isOccupied(cell) then
		return false, "that spot is taken"
	end
	local g = Shared.CONFIG.GRID
	local x, y, z = Shared.cellCenter(cell)
	local part = Instance.new("Part")
	part.Name = "ARBlock"
	part.Anchored = true
	part.Size = Vector3.new(g, g, g)
	part.CFrame = CFrame.new(x, y, z)
	part.Color = def.color
	part.Material = def.material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("OwnerUserId", player.UserId)
	part.Parent = blockFolder
	return true
end

return Backend
