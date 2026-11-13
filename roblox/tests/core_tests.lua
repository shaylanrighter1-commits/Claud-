-- Unit tests for the pure CORE block of AutoBuilder_MacSploit.lua.
-- Run with:  python3 roblox/tests/run_core_tests.py
-- These test the DECISION LOGIC (order, verification of a placed block, counters, duplicate protection, range
-- learning, stopping and resuming) against a simulated world. They do NOT test Roblox itself: raycasts, the
-- mouse, the hotbar GUI and the real game's placement rules can only be tested inside the game.

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  ok    " .. name)
	else
		failed = failed + 1
		print("  FAIL  " .. name .. "\n          " .. tostring(err))
	end
end
local function eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end
local function near(actual, expected, tol, msg)
	if math.abs(actual - expected) > tol then
		error((msg or "values differ") .. ": expected " .. tostring(expected) .. " +/- " .. tostring(tol) .. ", got " .. tostring(actual), 2)
	end
end
local function truthy(v, msg)
	if not v then
		error(msg or "expected true", 2)
	end
end

----------------------------------------------------------------------------------------------
-- a simulated world: blocks are 4 studs; cell (x,y,z) has its centre at ((x+.5)*4, ...)
----------------------------------------------------------------------------------------------
local S = 4
local function center(c)
	return { x = (c.x + 0.5) * S, y = (c.y + 0.5) * S, z = (c.z + 0.5) * S }
end
local function key(x, y, z)
	return Core.cellKey({ x = x, y = y, z = z })
end

local A, B33 = { x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 2 } -- 3 x 1 x 3 = 9 cells

print("build order")
test("rows are filled one after another, every row in the SAME direction", function()
	local o = Core.buildOrder(A, B33, "z", false)
	eq(o.n, 9)
	local want = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 0, 2 }, { 1, 2 }, { 2, 2 } }
	for i, w in ipairs(want) do
		eq(o.xs[i], w[1], "x at " .. i)
		eq(o.zs[i], w[2], "z at " .. i)
	end
end)
test("rows can start from the far end (descending) - still same direction inside each row", function()
	local o = Core.buildOrder(A, B33, "z", true)
	eq(o.zs[1], 2); eq(o.xs[1], 0); eq(o.xs[3], 2); eq(o.zs[4], 1); eq(o.xs[4], 0); eq(o.zs[9], 0); eq(o.xs[9], 2)
end)
test("rows along x", function()
	local o = Core.buildOrder(A, { x = 1, y = 0, z = 2 }, "x", false)
	eq(o.n, 6); eq(o.xs[1], 0); eq(o.zs[1], 0); eq(o.zs[3], 2); eq(o.xs[4], 1); eq(o.zs[4], 0)
end)
test("layers: the whole bottom layer before the next one", function()
	local o = Core.buildOrder(A, { x = 1, y = 2, z = 1 }, "z", false)
	eq(o.n, 12)
	for i = 1, 4 do eq(o.ys[i], 0) end
	for i = 5, 8 do eq(o.ys[i], 1) end
	for i = 9, 12 do eq(o.ys[i], 2) end
end)
test("every cell exactly once, none outside the rectangle", function()
	local mn, mx = { x = -3, y = 1, z = 5 }, { x = 4, y = 2, z = 9 }
	local o = Core.buildOrder(mn, mx, "x", true)
	eq(o.n, 8 * 2 * 5)
	local seen = {}
	for i = 1, o.n do
		local c = { x = o.xs[i], y = o.ys[i], z = o.zs[i] }
		truthy(Core.inBounds(c, mn, mx), "cell outside the area")
		local k = Core.cellKey(c)
		truthy(not seen[k], "duplicate cell " .. k)
		seen[k] = true
	end
end)

print("verifying a placed block (position)")
local function ctxFor(cell, first)
	return {
		cell = cell, center = center(cell), size = S, origin = { x = 0, y = 0, z = 0 }, first = first,
		min = { x = 0, y = 0, z = 0 }, max = { x = 2, y = 0, z = 2 },
	}
end
test("a block exactly in the cell counts", function()
	local c = { x = 1, y = 0, z = 1 }
	local r = Core.classifyFresh({ center(c) }, ctxFor(c, false))
	eq(r.kind, "placed")
	eq(r.adopt, nil)
end)
test("nothing appeared", function()
	eq(Core.classifyFresh({}, ctxFor({ x = 0, y = 0, z = 0 }, false)).kind, "none")
end)
test("first block: a small grid offset is adopted once", function()
	local c = { x = 1, y = 0, z = 1 }
	local p = center(c)
	p.x = p.x + 0.3 * S
	local r = Core.classifyFresh({ p }, ctxFor(c, true))
	eq(r.kind, "placed")
	truthy(r.adopt ~= nil, "offset not adopted")
	near(r.adopt.x, 0.3 * S, 1e-9)
end)
test("first block: a half-block offset is NOT accepted (can't tell it from the next cell)", function()
	local c = { x = 1, y = 0, z = 1 }
	local p = center(c)
	p.x = p.x + 0.5 * S
	eq(Core.classifyFresh({ p }, ctxFor(c, true)).kind, "misplaced")
end)
test("later block: within 0.2 of a block is fine, 0.25 is not (grid is never moved mid-build)", function()
	local c = { x = 1, y = 0, z = 1 }
	local ok = center(c)
	ok.z = ok.z + 0.15 * S
	eq(Core.classifyFresh({ ok }, ctxFor(c, false)).kind, "placed")
	local bad = center(c)
	bad.z = bad.z + 0.25 * S
	eq(Core.classifyFresh({ bad }, ctxFor(c, false)).kind, "misplaced")
end)
test("a block in the NEXT cell is wrong, and flagged as outside the area when it is", function()
	local c = { x = 2, y = 0, z = 1 }
	local p = center({ x = 3, y = 0, z = 1 })
	local r = Core.classifyFresh({ p }, ctxFor(c, false))
	eq(r.kind, "misplaced")
	eq(r.landed.x, 3)
	eq(r.outside, true)
	local inside = Core.classifyFresh({ center({ x = 1, y = 0, z = 1 }) }, ctxFor(c, false))
	eq(inside.kind, "misplaced")
	eq(inside.outside, false)
end)
test("a block one layer too high is wrong", function()
	local c = { x = 1, y = 0, z = 1 }
	eq(Core.classifyFresh({ center({ x = 1, y = 1, z = 1 }) }, ctxFor(c, false)).kind, "misplaced")
end)
test("two different new blocks after one click is wrong", function()
	local c = { x = 1, y = 0, z = 1 }
	local r = Core.classifyFresh({ center(c), center({ x = 1, y = 0, z = 2 }) }, ctxFor(c, false))
	eq(r.kind, "misplaced")
	eq(r.why, "extra")
end)
test("two parts of the same block (same spot) are one block", function()
	local c = { x = 1, y = 0, z = 1 }
	local p1, p2 = center(c), center(c)
	p2.y = p2.y + 0.1
	eq(Core.classifyFresh({ p1, p2 }, ctxFor(c, false)).kind, "placed")
end)

print("grid alignment")
test("consensus finds the lattice even with outliers and wrap-around", function()
	local list = {}
	for i = 1, 20 do list[#list + 1] = (i % 2 == 0) and 0.02 or 3.98 end -- both just around 0
	list[#list + 1] = 1.7; list[#list + 1] = 2.9; list[#list + 1] = 0.9
	local v, frac = Core.consensus(list, 4)
	local d = math.min(v, 4 - v)
	near(d, 0, 0.1, "lattice offset")
	truthy(frac > 0.8, "agreement should be high")
end)
test("consensus at 2.0", function()
	local list = {}
	for i = 1, 10 do list[#list + 1] = 2.0 + (i % 3) * 0.01 end
	local v = Core.consensus(list, 4)
	near(v, 2.01, 0.05)
end)
test("blocks that disagree give low agreement", function()
	local list = { 0.1, 0.7, 1.3, 1.9, 2.5, 3.1, 3.7, 0.4 }
	local _, frac = Core.consensus(list, 4)
	truthy(frac < 0.5, "should not claim agreement")
end)

----------------------------------------------------------------------------------------------
-- walk mode: a simulated player looks at cells (in any order, with repeats, even outside the area) and the
-- decision logic decides what to click and what to count.
----------------------------------------------------------------------------------------------
local CFG = { retryDelay = 1.5, closerBy = 2, maxFails = 6, maxStrays = 5, maxMismatches = 12 }
local function newSim(mn, mx)
	return {
		job = Core.newWalk(mn, mx), filled = {}, owned = 1000, range = 1e9, refuse = {}, strayTo = {}, mismatch = {},
		char = { x = 0, y = 3, z = 0 }, now = 0, clicks = {}, clicksOnFilled = 0, clicksOutside = 0, placedCount = 0,
		stopCode = nil,
	}
end
local function simEnv(W)
	return {
		occupied = function(c) return W.filled[Core.cellKey(c)] ~= nil end,
		tick = function() return false end,
	}
end
local function plan(W)
	local ok = Core.walkPlan(W.job, simEnv(W))
	truthy(ok, "plan was stopped")
end
-- the player looks at `cell` for one moment; returns what happened
local function look(W, cell, dt)
	W.now = W.now + (dt or 0.2)
	local job = W.job
	if W.stopCode then return "stopped" end
	local dist = Core.dist3(W.char, center(cell))
	local ok = Core.walkAllow(job, cell, dist, W.now, CFG)
	if not ok then return "not allowed" end
	local k = Core.cellKey(cell)
	if W.filled[k] then return "occupied" end -- the script looks at the world before clicking
	-- ---- the click ----
	W.clicks[#W.clicks + 1] = k
	if W.filled[k] then W.clicksOnFilled = W.clicksOnFilled + 1 end
	if not Core.inBounds(cell, job.mn, job.mx) then W.clicksOutside = W.clicksOutside + 1 end
	local result, extra
	if W.mismatch[k] then
		result, extra = "mismatch", "preview elsewhere"
	elseif W.owned <= 0 then
		result = "noblocks"
	elseif W.refuse[k] or dist > W.range then
		result = "failed"
	elseif W.strayTo[k] then
		local n = W.strayTo[k]
		W.filled[Core.cellKey(n)] = true
		W.owned = W.owned - 1
		result, extra = "stray", "landed next door"
	else
		W.filled[k] = true
		W.owned = W.owned - 1
		W.placedCount = W.placedCount + 1
		result = "placed"
	end
	local action, code, info = Core.walkResult(job, cell, dist, W.now, result, extra, CFG)
	if action == "stop" then W.stopCode = code; return "stop", code, info end
	return result
end
local function invariants(W, label)
	local job = W.job
	truthy(job.placed <= job.total, label .. ": placed (" .. job.placed .. ") exceeded total (" .. job.total .. ")")
	eq(W.clicksOnFilled, 0, label .. ": clicked a cell that already had a block")
	eq(W.clicksOutside, 0, label .. ": clicked outside the area")
	eq(job.placed, W.placedCount, label .. ": counted blocks != blocks really placed in the aimed cell")
end
-- every cell of the area, in a scrambled order (a player wandering about), with extras outside / above
local function wander(mn, mx, rounds)
	local list = {}
	for y = mn.y - 1, mx.y + 1 do
		for z = mn.z - 1, mx.z + 1 do
			for x = mn.x - 1, mx.x + 1 do list[#list + 1] = { x = x, y = y, z = z } end
		end
	end
	local out, seed = {}, 7
	for _ = 1, rounds or 3 do
		for i = #list, 2, -1 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local j = seed % i + 1
			list[i], list[j] = list[j], list[i]
		end
		for _, c in ipairs(list) do out[#out + 1] = c end
	end
	return out
end
print("walk mode: planning")
test("the plan counts only EMPTY cells of the flat area", function()
	local W = newSim(A, B33)
	W.filled["0,0,0"] = true; W.filled["1,0,1"] = true; W.filled["2,0,2"] = true
	plan(W)
	eq(W.job.total, 6); eq(W.job.placed, 0)
end)
test("planning can be interrupted by STOP", function()
	local W = newSim(A, { x = 20, y = 0, z = 20 })
	eq(Core.walkPlan(W.job, { occupied = function() return false end, tick = function(i) return i > 10 end }), false)
end)

print("walk mode: filling by looking around")
test("a wandering player fills a 3x3 area: every cell once, nothing outside it, counts exact", function()
	local W = newSim(A, B33)
	plan(W)
	for _, c in ipairs(wander(A, B33, 4)) do look(W, c) end
	eq(W.job.placed, 9); eq(W.job.total, 9); eq(W.placedCount, 9); eq(#W.clicks, 9)
	invariants(W, "wander")
end)
test("a single-cell area", function()
	local W = newSim(A, A)
	plan(W)
	for _, c in ipairs(wander(A, A, 2)) do look(W, c) end
	eq(W.job.placed, 1); eq(#W.clicks, 1); invariants(W, "single")
end)
test("cells outside the area and in the layer above are never tried (no stacking)", function()
	local W = newSim(A, B33)
	plan(W)
	for y = -1, 2 do for x = -3, 6 do for z = -3, 6 do look(W, { x = x, y = y, z = z }) end end end
	eq(W.job.placed, 9)
	for _, k in ipairs(W.clicks) do truthy(string.find(k, "^%d,0,%d$"), "clicked outside the flat area: " .. k) end
	invariants(W, "outside")
end)
test("existing blocks are never clicked, and are not counted", function()
	local W = newSim(A, B33)
	W.filled["0,0,0"] = true; W.filled["2,0,1"] = true
	plan(W)
	for _, c in ipairs(wander(A, B33, 3)) do look(W, c) end
	eq(W.job.placed, 7); eq(W.job.total, 7); eq(#W.clicks, 7); eq(W.placedCount, 7)
	invariants(W, "existing")
end)
test("looking at the same cell again and again places one block only", function()
	local W = newSim(A, B33)
	plan(W)
	for _ = 1, 50 do look(W, { x = 1, y = 0, z = 1 }, 0.05) end
	eq(#W.clicks, 1); eq(W.job.placed, 1)
end)
test("a full area: nothing to do", function()
	local W = newSim(A, B33)
	for x = 0, 2 do for z = 0, 2 do W.filled[x .. ",0," .. z] = true end end
	plan(W)
	eq(W.job.total, 0)
	for _, c in ipairs(wander(A, B33, 2)) do look(W, c) end
	eq(#W.clicks, 0)
end)

print("walk mode: bookkeeping")
test("a cell this job filled is never clicked again, even if the world is slow to show the block", function()
	local W = newSim(A, B33)
	plan(W)
	look(W, { x = 1, y = 0, z = 1 })
	eq(#W.clicks, 1)
	W.filled["1,0,1"] = nil -- the world "forgets" the block for a moment
	look(W, { x = 1, y = 0, z = 1 }, 5)
	eq(#W.clicks, 1, "clicked a cell it had already filled")
end)
test("a re-plan does not count the cells this job filled as empty again", function()
	local W = newSim(A, B33)
	plan(W)
	for x = 0, 2 do look(W, { x = x, y = 0, z = 0 }) end
	eq(W.job.placed, 3)
	for x = 0, 2 do W.filled[x .. ",0,0"] = nil end -- slow to show
	plan(W)
	eq(W.job.total, 9, "3 placed + 6 empty")
end)
test("when the job is complete nothing more is tried, whatever the player looks at", function()
	local W = newSim(A, B33)
	plan(W)
	W.job.total = 1
	look(W, { x = 0, y = 0, z = 0 })
	eq(W.job.placed, 1)
	look(W, { x = 1, y = 0, z = 0 }, 5)
	eq(#W.clicks, 1)
end)
test("consensus picks the majority lattice whichever way the buckets are iterated", function()
	local a, b = {}, {}
	for i = 1, 6 do a[#a + 1] = 3.0; b[#b + 1] = 0.2 end
	a[#a + 1] = 0.2; a[#a + 1] = 0.2; a[#a + 1] = 0.8
	b[#b + 1] = 3.0; b[#b + 1] = 3.0; b[#b + 1] = 2.4
	near((Core.consensus(a, 4)), 3.0, 0.05, "majority at 3.0")
	near((Core.consensus(b, 4)), 0.2, 0.05, "majority at 0.2")
end)

print("walk mode: placement distance")
test("a refusal far away is learned: far cells are left alone (no click spam), nothing is claimed placed", function()
	local W = newSim(A, { x = 6, y = 0, z = 6 }) -- 49 cells; the player stands at the origin corner
	W.range = 18
	plan(W)
	for _, c in ipairs(wander(A, { x = 6, y = 0, z = 6 }, 6)) do look(W, c, 2) end
	truthy(W.job.placed > 0 and W.job.placed < 49, "some cells in reach, some not: " .. W.job.placed)
	truthy(W.job.reach.failMin ~= nil, "the range was not learned")
	eq(W.stopCode, nil, "a range refusal must not stop the build")
	-- far cells were tried a few times at most, not on every look
	truthy(#W.clicks <= W.job.placed + 12, "too many clicks wasted on far cells: " .. #W.clicks)
	invariants(W, "range")
	W.char = { x = 14, y = 3, z = 14 } -- the player walks to the middle
	for _, c in ipairs(wander(A, { x = 6, y = 0, z = 6 }, 4)) do look(W, c, 2) end
	eq(W.job.placed, 49); invariants(W, "range+walk")
end)
test("cells the game accepts at long range are not held back by a guess", function()
	local W = newSim(A, { x = 6, y = 0, z = 6 })
	plan(W)
	for _, c in ipairs(wander(A, { x = 6, y = 0, z = 6 }, 3)) do look(W, c) end
	eq(W.job.placed, 49)
end)
test("a refused cell is not retried straight away, but is once the player is closer", function()
	local W = newSim(A, B33)
	W.refuse["1,0,1"] = true
	plan(W)
	look(W, { x = 1, y = 0, z = 1 }, 0.1)
	eq(#W.clicks, 1)
	look(W, { x = 1, y = 0, z = 1 }, 0.1) -- 0.1 s later: too soon
	eq(#W.clicks, 1)
	look(W, { x = 1, y = 0, z = 1 }, 2) -- 2 s later: allowed
	eq(#W.clicks, 2)
	W.char = { x = 40, y = 3, z = 40 }
	W.char = { x = 6, y = 3, z = 6 }
	W.refuse = {}
	look(W, { x = 1, y = 0, z = 1 }, 0.1) -- closer by more than 2 studs: allowed even though it was just tried
	truthy(W.job.placedSet["1,0,1"], "should have been placed")
end)
test("several clicks in a row that reach the game and place nothing (near the player) stop the build", function()
	local W = newSim(A, { x = 5, y = 0, z = 0 })
	W.char = { x = 12, y = 3, z = 2 } -- everything within 14 studs: these are not "too far" refusals
	for x = 0, 5 do W.refuse[x .. ",0,0"] = true end
	plan(W)
	for _, c in ipairs(wander(A, { x = 5, y = 0, z = 0 }, 3)) do look(W, c, 2) end
	eq(W.stopCode, "failed"); eq(#W.clicks, 6, "it stops on the 6th failure, not later")
end)

print("walk mode: strays, mismatches, stopping")
test("a block landing in another cell INSIDE the area is not counted, tolerated up to the limit, then stops", function()
	local W = newSim(A, { x = 9, y = 0, z = 1 })
	W.char = { x = 20, y = 3, z = 4 }
	plan(W)
	for x = 0, 9 do W.strayTo[x .. ",0,0"] = { x = x, y = 0, z = 1 } end -- each click on row 0 lands in row 1
	for x = 0, 9 do look(W, { x = x, y = 0, z = 0 }, 2) end
	eq(W.stopCode, "misplaced"); eq(#W.clicks, 6, "5 tolerated strays, the 6th stops")
	eq(W.job.placed, 0, "a stray is never counted as placed")
end)
test("the game's preview pointing at another cell: no click; too many in a row stops with 'mismatch'", function()
	local W = newSim(A, { x = 20, y = 0, z = 0 })
	for x = 0, 20 do W.mismatch[x .. ",0,0"] = true end
	plan(W)
	for x = 0, 20 do look(W, { x = x, y = 0, z = 0 }, 2) end
	eq(W.stopCode, "mismatch"); eq(W.placedCount, 0)
end)
test("a good placement resets the failure counters", function()
	local W = newSim(A, { x = 9, y = 0, z = 0 })
	plan(W)
	W.refuse["0,0,0"] = true; W.refuse["1,0,0"] = true; W.refuse["2,0,0"] = true
	for x = 0, 2 do look(W, { x = x, y = 0, z = 0 }, 2) end
	eq(W.job.fails, 3)
	look(W, { x = 5, y = 0, z = 0 }, 2)
	eq(W.job.fails, 0)
end)
test("out of blocks stops; the same job resumes with the exact counts", function()
	local W = newSim(A, B33)
	W.owned = 4
	plan(W)
	for _, c in ipairs(wander(A, B33, 3)) do look(W, c) end
	eq(W.stopCode, "noblocks"); eq(W.job.placed, 4)
	W.owned = 100; W.stopCode = nil
	plan(W) -- resume: a fresh look at the world
	eq(W.job.total, 9)
	for _, c in ipairs(wander(A, B33, 3)) do look(W, c) end
	eq(W.job.placed, 9); eq(W.placedCount, 9); invariants(W, "blocks")
end)
test("an unknown result stops the build and is reported as it is", function()
	local W = newSim(A, B33)
	plan(W)
	local action, code = Core.walkResult(W.job, A, 5, 1, "broke", "x", CFG)
	eq(action, "stop"); eq(code, "broke")
end)
test("interrupted again and again (re-planning each time): always exact", function()
	local W = newSim(A, { x = 4, y = 0, z = 4 })
	local n = 0
	for round = 1, 60 do
		plan(W)
		W.stopCode = nil
		for _, c in ipairs(wander(A, { x = 4, y = 0, z = 4 }, 1)) do
			look(W, c, 2); n = n + 1
			if W.placedCount % 2 == 1 and round % 2 == 0 then break end
		end
		invariants(W, "round " .. round)
		if W.job.placed >= W.job.total then break end
	end
	eq(W.job.placed, 25); eq(W.job.total, 25)
end)
test("a verified placement is always counted, even if the plan thought the cell was filled", function()
	local W = newSim(A, B33)
	plan(W)
	W.job.total = 0 -- stale plan
	local act = Core.walkResult(W.job, A, 5, 1, "placed", nil, CFG)
	eq(act, "continue"); eq(W.job.placed, 1); eq(W.job.total, 1, "total follows the verified count"); truthy(W.job.placed <= W.job.total)
	local act2 = Core.walkResult(W.job, A, 5, 2, "placed", nil, CFG) -- the same cell again: counted once
	eq(W.job.placed, 1)
end)
test("a new job starts at zero", function()
	local a, b = newSim(A, B33), newSim(A, { x = 1, y = 0, z = 1 })
	plan(a); plan(b)
	for _, c in ipairs(wander(A, B33, 3)) do look(a, c) end
	eq(b.job.placed, 0); eq(b.job.total, 4)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
