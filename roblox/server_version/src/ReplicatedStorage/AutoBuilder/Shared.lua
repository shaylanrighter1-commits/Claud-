--!nocheck
-- Shared by the server and the client: the grid, the settings, and the area maths.
-- Pure Lua on purpose (cells are plain {x=,y=,z=} tables), so it can be unit-tested outside Roblox.
local Shared = {}

Shared.CONFIG = {
	GRID = 4, -- studs per block. MUST match your game's block size.
	ORIGIN = { x = 0, y = 0, z = 0 }, -- world position of the lowest corner of cell (0,0,0). Must match your game's grid.
	MAX_CELLS = 4000, -- biggest area one build may cover
	BLOCKS_PER_SECOND = 30, -- build speed (the server paces itself; raise or lower to taste)
	MAX_COORD = 100000, -- cell coordinates beyond this are rejected
}

function Shared.cellKey(c)
	return string.format("%d,%d,%d", c.x, c.y, c.z)
end

-- the grid cell that contains the world point (x, y, z)
function Shared.worldToCell(x, y, z)
	local g, o = Shared.CONFIG.GRID, Shared.CONFIG.ORIGIN
	return {
		x = math.floor((x - o.x) / g),
		y = math.floor((y - o.y) / g),
		z = math.floor((z - o.z) / g),
	}
end

-- world position of the middle of a cell
function Shared.cellCenter(c)
	local g, o = Shared.CONFIG.GRID, Shared.CONFIG.ORIGIN
	return o.x + (c.x + 0.5) * g, o.y + (c.y + 0.5) * g, o.z + (c.z + 0.5) * g
end

local function isInt(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge and n == math.floor(n)
end

-- A cell sent over the network is never trusted: it must be a table of three whole numbers in range.
function Shared.cleanCell(c)
	if type(c) ~= "table" then
		return nil
	end
	local x, y, z = c.x, c.y, c.z
	local m = Shared.CONFIG.MAX_COORD
	if isInt(x) and isInt(y) and isInt(z) and math.abs(x) <= m and math.abs(y) <= m and math.abs(z) <= m then
		return { x = x, y = y, z = z }
	end
	return nil
end

-- Two corners -> (mn, mx, count), or nil + the reason.
function Shared.area(a, b)
	local ca, cb = Shared.cleanCell(a), Shared.cleanCell(b)
	if not ca or not cb then
		return nil, "That area isn't valid."
	end
	local mn = { x = math.min(ca.x, cb.x), y = math.min(ca.y, cb.y), z = math.min(ca.z, cb.z) }
	local mx = { x = math.max(ca.x, cb.x), y = math.max(ca.y, cb.y), z = math.max(ca.z, cb.z) }
	local count = (mx.x - mn.x + 1) * (mx.y - mn.y + 1) * (mx.z - mn.z + 1)
	if count > Shared.CONFIG.MAX_CELLS then
		return nil, string.format("That area is too big (%d blocks, the limit is %d).", count, Shared.CONFIG.MAX_CELLS)
	end
	return mn, mx, count
end

-- One fixed order: the bottom layer first, then row by row (z), and every row left to right (x).
function Shared.buildOrder(mn, mx)
	local xs, ys, zs, n = {}, {}, {}, 0
	for y = mn.y, mx.y do
		for z = mn.z, mx.z do
			for x = mn.x, mx.x do
				n = n + 1
				xs[n], ys[n], zs[n] = x, y, z
			end
		end
	end
	return { n = n, xs = xs, ys = ys, zs = zs }
end

return Shared
