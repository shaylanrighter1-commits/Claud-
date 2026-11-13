--[[
	Auto Builder — planner self-test.

	HOW TO RUN (after installing the Auto Builder):
	  Paste this whole file into Roblox Studio's Command Bar and press Enter.
	  Check the Output window: you want  "PlannerTests: ALL PASSED".

	It checks the geometry module (BuildPlanner) against an independent, brute-force
	description of every build mode, on 1,500 random selections:
	  * the boxes never overlap
	  * the block count equals the exact number of cells that should be filled
	  * the build order visits every cell exactly once, bottom layer first, in a snake pattern
	  * bad input (NaN, fractions, missing fields, oversized builds) is rejected
]]

local Planner = require(game:GetService("ReplicatedStorage").AutoBuilder.BuildPlanner)

local LIMITS = { maxBlocks = 100000, maxDimension = 128, maxHeight = 64, maxThickness = 16 }
local failures = 0
local function check(condition, message)
	if not condition then
		failures += 1
		if failures <= 25 then
			warn("PlannerTests FAIL: " .. message)
		end
	end
end

-- Independent reference: which cells SHOULD a build contain? (written differently on purpose)
local function expectedCells(mode, a, b, o)
	local minX, maxX = math.min(a.x, b.x), math.max(a.x, b.x)
	local minY, maxY = math.min(a.y, b.y), math.max(a.y, b.y)
	local minZ, maxZ = math.min(a.z, b.z), math.max(a.z, b.z)
	local w, d, selH = maxX - minX + 1, maxZ - minZ + 1, maxY - minY + 1
	local H = (selH > 1) and selH or o.height
	local layers = (mode == "floor") and o.thickness or H

	local set, count = {}, 0
	for x = minX, maxX do
		for z = minZ, maxZ do
			for y = minY, minY + layers - 1 do
				local keep = true
				if mode == "hollow" then
					if H > 2 and w > 2 and d > 2 then
						keep = x == minX or x == maxX or z == minZ or z == maxZ or y == minY or y == minY + H - 1
					end
				elseif mode == "wall" then
					if o.layout == "surround" then
						local t = o.thickness
						if 2 * t >= math.min(w, d) then
							keep = true
						else
							keep = x < minX + t or x > maxX - t or z < minZ + t or z > maxZ - t
						end
					elseif w >= d then
						local t = math.min(o.thickness, d)
						keep = (a.z <= b.z) and (z <= minZ + t - 1) or (a.z > b.z and z >= maxZ - t + 1)
					else
						local t = math.min(o.thickness, w)
						keep = (a.x <= b.x) and (x <= minX + t - 1) or (a.x > b.x and x >= maxX - t + 1)
					end
				end
				if keep then
					set[Planner.pack(x, y, z)] = true
					count += 1
				end
			end
		end
	end
	return set, count
end

local rng = Random.new(20260512)
local modes = { "floor", "wall", "fill", "hollow" }
local plans = 0

for _ = 1, 1500 do
	local mode = modes[rng:NextInteger(1, 4)]
	local a = { x = rng:NextInteger(-8, 8), y = rng:NextInteger(0, 3), z = rng:NextInteger(-8, 8) }
	local b = { x = rng:NextInteger(-8, 8), y = rng:NextInteger(0, 3), z = rng:NextInteger(-8, 8) }
	if rng:NextNumber() < 0.5 then
		b.y = a.y -- flat selections are the common case
	end
	local o = {
		mode = mode,
		height = rng:NextInteger(1, 7),
		thickness = rng:NextInteger(1, 5),
		layout = (rng:NextNumber() < 0.5) and "straight" or "surround",
	}
	local label = string.format(
		"%s A(%d,%d,%d) B(%d,%d,%d) h=%d t=%d %s",
		mode, a.x, a.y, a.z, b.x, b.y, b.z, o.height, o.thickness, o.layout
	)

	local plan, code = Planner.plan(a, b, o, LIMITS)
	check(plan ~= nil, "plan rejected (" .. tostring(code) .. "): " .. label)
	if plan then
		plans += 1
		local expected, expectedCount = expectedCells(mode, a, b, o)

		-- boxes are disjoint and cover exactly the expected cells
		local seen, seenCount = {}, 0
		Planner.forEachCell(plan, function(x, y, z)
			local key = Planner.pack(x, y, z)
			check(not seen[key], "cell counted twice: " .. label)
			check(expected[key] == true, string.format("unexpected cell (%d,%d,%d): %s", x, y, z, label))
			seen[key] = true
			seenCount += 1
		end)
		check(seenCount == expectedCount, string.format("cell count %d vs expected %d: %s", seenCount, expectedCount, label))
		check(plan.count == expectedCount, string.format("plan.count %d vs expected %d: %s", plan.count, expectedCount, label))

		-- build order: every cell once, bottom-up, snake rows
		local order = Planner.buildOrder(plan)
		check(order.n == plan.count, "order length: " .. label)
		local visited = {}
		local prevY, prevZ, prevX = nil, nil, nil
		for i = 1, order.n do
			local x, y, z = order.xs[i], order.ys[i], order.zs[i]
			local key = Planner.pack(x, y, z)
			check(expected[key] == true, "order has a cell that should not exist: " .. label)
			check(not visited[key], "order repeats a cell: " .. label)
			visited[key] = true
			if prevY ~= nil then
				check(y >= prevY, "order goes back down a layer: " .. label)
				if y == prevY then
					check(z >= prevZ, "order goes back a row: " .. label)
					if z == prevZ then
						local reversed = (z - plan.min.z) % 2 == 1
						check(reversed and x < prevX or (not reversed and x > prevX), "row is not a snake: " .. label)
					end
				end
			end
			prevX, prevY, prevZ = x, y, z
		end

		-- bounds contain everything
		Planner.forEachCell(plan, function(x, y, z)
			check(
				x >= plan.min.x and x <= plan.max.x and y >= plan.min.y and y <= plan.max.y and z >= plan.min.z and z <= plan.max.z,
				"cell outside plan bounds: " .. label
			)
		end)
	end
end

-- The example from the spec: a 12 x 10 grass floor needs exactly 120 blocks.
do
	local plan = Planner.plan({ x = 0, y = 0, z = 0 }, { x = 11, y = 0, z = 9 }, { mode = "floor", thickness = 1 }, LIMITS)
	check(plan and plan.count == 120, "12x10 floor should be 120 blocks")
end

-- pack / unpack round trip (including negatives)
for _, c in ipairs({ { 0, 0, 0 }, { -1, -1, -1 }, { 31999, -31999, 12345 }, { -500, 70, 8 } }) do
	local x, y, z = Planner.unpack(Planner.pack(c[1], c[2], c[3]))
	check(x == c[1] and y == c[2] and z == c[3], "pack/unpack round trip failed")
end

-- Bad input must be rejected, never crash.
local good = { mode = "floor", thickness = 1 }
local A, B = { x = 0, y = 0, z = 0 }, { x = 3, y = 0, z = 3 }
check(Planner.plan({ x = 0 / 0, y = 0, z = 0 }, B, good, LIMITS) == nil, "NaN accepted")
check(Planner.plan({ x = 0.5, y = 0, z = 0 }, B, good, LIMITS) == nil, "fraction accepted")
check(Planner.plan({ x = math.huge, y = 0, z = 0 }, B, good, LIMITS) == nil, "infinity accepted")
check(Planner.plan({ x = 1, z = 0 }, B, good, LIMITS) == nil, "missing y accepted")
check(Planner.plan(A, B, { mode = "explode" }, LIMITS) == nil, "unknown mode accepted")
check(Planner.plan(A, B, nil, LIMITS) == nil, "nil options accepted")
local _, tooLarge = Planner.plan(A, { x = 500, y = 0, z = 500 }, good, LIMITS)
check(tooLarge == "TOO_LARGE", "oversized build not rejected")
local _, tooMany = Planner.plan(A, { x = 99, y = 0, z = 99 }, good, { maxBlocks = 100, maxDimension = 128, maxHeight = 64, maxThickness = 16 })
check(tooMany == "TOO_LARGE", "block limit not enforced")

if failures == 0 then
	print(string.format("PlannerTests: ALL PASSED (%d random plans checked)", plans))
else
	warn(string.format("PlannerTests: %d FAILURE(S) — see warnings above", failures))
end
