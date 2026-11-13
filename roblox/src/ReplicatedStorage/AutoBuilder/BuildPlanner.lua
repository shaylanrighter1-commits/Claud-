--!nonstrict
--[[
	BuildPlanner — pure geometry. No Roblox API calls, so it behaves identically on
	the client (orange preview) and the server (authoritative validation + placement).

	Vocabulary
	  cell   integer grid coordinate {x=,y=,z=}. One cell holds one block.
	  box    inclusive cell range {x1,y1,z1,x2,y2,z2}.
	  plan   the exact set of cells a build will fill, stored as a list of DISJOINT boxes.
	         The block count is simply the sum of the box volumes, so what the preview
	         draws, what the requirement calculator counts and what the builder places
	         can never disagree.

	Modes
	  floor   flat slab over the selected rectangle, `thickness` layers tall.
	  wall    vertical wall. layout "straight": runs along the longer side, starting at
	          Point A's edge and growing toward Point B by `thickness`.
	          layout "surround": all four sides of the rectangle.
	  fill    solid volume.
	  hollow  outer shell (walls + floor + ceiling) with an empty inside.

	Height: if Point A and Point B are on different layers, the build's height comes from
	those two points (`heightLocked = true`). Otherwise `options.height` is used.
]]

local BuildPlanner = {}

BuildPlanner.MODES = { floor = true, wall = true, fill = true, hollow = true }
BuildPlanner.LAYOUTS = { straight = true, surround = true }

-- Cell coordinates are packed into one exact double: 16 bits per axis.
local OFFSET = 32768
local SPAN = 65536
BuildPlanner.COORD_LIMIT = 32000

function BuildPlanner.pack(x, y, z)
	return ((y + OFFSET) * SPAN + (z + OFFSET)) * SPAN + (x + OFFSET)
end

function BuildPlanner.unpack(key)
	local xo = key % SPAN
	local rest = (key - xo) / SPAN
	local zo = rest % SPAN
	local yo = (rest - zo) / SPAN
	return xo - OFFSET, yo - OFFSET, zo - OFFSET
end

-- Integer in [lo, hi]; anything that is not a finite number becomes `default`.
function BuildPlanner.clampInt(value, lo, hi, default)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default
	end
	return math.clamp(math.floor(value), lo, hi)
end

local function validCoord(n)
	return type(n) == "number" and n == n and math.abs(n) <= BuildPlanner.COORD_LIMIT and n % 1 == 0
end

local function validCell(c)
	return type(c) == "table" and validCoord(c.x) and validCoord(c.y) and validCoord(c.z)
end

--[[
	BuildPlanner.plan(a, b, options, limits) -> plan | nil, errorCode
	  a, b     cells {x,y,z}
	  options  { mode, height, thickness, layout }
	  limits   { maxBlocks, maxDimension, maxHeight, maxThickness }
	Error codes: "BAD_REQUEST", "TOO_LARGE".
]]
function BuildPlanner.plan(a, b, options, limits)
	if not validCell(a) or not validCell(b) or type(options) ~= "table" or type(limits) ~= "table" then
		return nil, "BAD_REQUEST"
	end
	local mode = options.mode
	if not BuildPlanner.MODES[mode] then
		return nil, "BAD_REQUEST"
	end

	local minX, maxX = math.min(a.x, b.x), math.max(a.x, b.x)
	local minY, maxY = math.min(a.y, b.y), math.max(a.y, b.y)
	local minZ, maxZ = math.min(a.z, b.z), math.max(a.z, b.z)
	local w, selH, d = maxX - minX + 1, maxY - minY + 1, maxZ - minZ + 1

	local heightOpt = BuildPlanner.clampInt(options.height, 1, limits.maxHeight, 1)
	local thickOpt = BuildPlanner.clampInt(options.thickness, 1, limits.maxThickness, 1)
	local layout = (options.layout == "surround") and "surround" or "straight"

	local heightLocked = selH > 1
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
			add(minX, baseY, minZ, maxX, topY, maxZ) -- too small to have an inside
		else
			add(minX, baseY, minZ, maxX, baseY, maxZ) -- floor
			add(minX, topY, minZ, maxX, topY, maxZ) -- ceiling
			local y1, y2 = baseY + 1, topY - 1
			add(minX, y1, minZ, maxX, y2, minZ) -- south wall (full width)
			add(minX, y1, maxZ, maxX, y2, maxZ) -- north wall (full width)
			add(minX, y1, minZ + 1, minX, y2, maxZ - 1) -- west wall (between the above)
			add(maxX, y1, minZ + 1, maxX, y2, maxZ - 1) -- east wall
		end
	elseif mode == "wall" then
		if layout == "straight" then
			if w >= d then -- wall runs along X
				local t = math.min(thickOpt, d)
				if a.z <= b.z then
					add(minX, baseY, minZ, maxX, topY, minZ + t - 1)
				else
					add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ)
				end
			else -- wall runs along Z
				local t = math.min(thickOpt, w)
				if a.x <= b.x then
					add(minX, baseY, minZ, minX + t - 1, topY, maxZ)
				else
					add(maxX - t + 1, baseY, minZ, maxX, topY, maxZ)
				end
			end
		else -- surround
			local t = thickOpt
			if 2 * t >= math.min(w, d) then
				add(minX, baseY, minZ, maxX, topY, maxZ) -- ring is thick enough to be solid
			else
				add(minX, baseY, minZ, maxX, topY, minZ + t - 1) -- south
				add(minX, baseY, maxZ - t + 1, maxX, topY, maxZ) -- north
				add(minX, baseY, minZ + t, minX + t - 1, topY, maxZ - t) -- west
				add(maxX - t + 1, baseY, minZ + t, maxX, topY, maxZ - t) -- east
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
		layout = layout,
		boxes = boxes,
		count = count,
		min = bMin,
		max = bMax,
		size = { x = bMax.x - bMin.x + 1, y = bMax.y - bMin.y + 1, z = bMax.z - bMin.z + 1 },
		height = H,
		heightLocked = heightLocked,
		-- the rectangle the player actually clicked (before mode/thickness were applied)
		selectionMin = { x = minX, y = minY, z = minZ },
		selectionMax = { x = maxX, y = maxY, z = maxZ },
	}
end

-- Calls fn(x, y, z) for every cell in the plan (no particular order).
function BuildPlanner.forEachCell(plan, fn)
	for _, box in ipairs(plan.boxes) do
		for y = box.y1, box.y2 do
			for z = box.z1, box.z2 do
				for x = box.x1, box.x2 do
					fn(x, y, z)
				end
			end
		end
	end
end

function BuildPlanner.contains(plan, x, y, z)
	for _, box in ipairs(plan.boxes) do
		if x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2 and z >= box.z1 and z <= box.z2 then
			return true
		end
	end
	return false
end

--[[
	Build order: bottom layer first, then row by row, alternating direction on every row
	(a "snake") so the structure grows in one continuous sweep instead of jumping around.
	Returns { n = count, xs = {...}, ys = {...}, zs = {...} } with parallel arrays.
]]
function BuildPlanner.buildOrder(plan)
	local keys = table.create(plan.count)
	local n = 0
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

	local xs, ys, zs = table.create(n), table.create(n), table.create(n)
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

----------------------------------------------------------------------------------
-- Grid helpers. Cell (cx,cy,cz) occupies the world cube
--   [origin + c*size, origin + (c+1)*size)   on each axis.
----------------------------------------------------------------------------------

function BuildPlanner.worldToCell(wx, wy, wz, size, ox, oy, oz)
	return math.floor((wx - ox) / size), math.floor((wy - oy) / size), math.floor((wz - oz) / size)
end

function BuildPlanner.cellCenter(cx, cy, cz, size, ox, oy, oz)
	return ox + (cx + 0.5) * size, oy + (cy + 0.5) * size, oz + (cz + 0.5) * size
end

-- World-space center and size of a box, for drawing it.
function BuildPlanner.boxWorld(box, size, ox, oy, oz)
	local x1, y1, z1 = ox + box.x1 * size, oy + box.y1 * size, oz + box.z1 * size
	local x2, y2, z2 = ox + (box.x2 + 1) * size, oy + (box.y2 + 1) * size, oz + (box.z2 + 1) * size
	return (x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2, x2 - x1, y2 - y1, z2 - z1
end

-- True when the whole plan lies inside [boundsMin, boundsMax] (inclusive cells).
function BuildPlanner.planInside(plan, boundsMin, boundsMax)
	return plan.min.x >= boundsMin.x
		and plan.min.y >= boundsMin.y
		and plan.min.z >= boundsMin.z
		and plan.max.x <= boundsMax.x
		and plan.max.y <= boundsMax.y
		and plan.max.z <= boundsMax.z
end

return BuildPlanner
