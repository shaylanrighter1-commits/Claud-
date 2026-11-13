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

local function newWorld()
	return {
		filled = {}, -- [cellKey] = true  (blocks that exist)
		hidden = {}, -- cells the camera can't see: the builder finds no place to click
		refuse = {}, -- cells the game refuses for some reason other than distance
		wrongPlace = {}, -- cells where the click makes the block land somewhere else
		owned = 1000,
		range = 1e9, -- the game's real placement distance
		char = { x = 0, y = 3, z = 0 },
		island = nil, -- function(cell) -> bool : is there ground? (island edge)
		attempts = {}, -- every click, in order
		clicksOnFilled = 0, -- clicks on a cell that already had a block: must stay 0
		placedCount = 0, -- blocks that really got placed
		stopNow = false,
		stopAfter = nil, -- press STOP while the click after this many placements is in flight
		logs = {},
		moves = 0, -- the builder has no way to move the character; this must stay 0
	}
end

local function makeEnv(world)
	local env = {}
	env.stopped = function()
		return world.stopNow
	end
	env.tick = function()
		return world.stopNow
	end
	env.occupied = function(c)
		return world.filled[Core.cellKey(c)] == true
	end
	env.distance = function(c)
		return Core.dist3(world.char, center(c))
	end
	env.wait = function() end
	env.progress = function() end
	env.log = function(t)
		world.logs[#world.logs + 1] = t
	end
	env.attempt = function(c, dist)
		local k = Core.cellKey(c)
		world.attempts[#world.attempts + 1] = { key = k, dist = dist }
		if world.filled[k] then
			world.clicksOnFilled = world.clicksOnFilled + 1
		end
		if world.owned <= 0 then
			return "noblocks"
		end
		if world.hidden[k] then
			return "noaim", "hidden from the camera"
		end
		if world.island and not world.island(c) then
			return "noaim", "no ground there"
		end
		if world.refuse[k] then
			return "failed"
		end
		if dist > world.range then
			return "failed"
		end
		if world.wrongPlace[k] then
			return "misplaced", "landed elsewhere"
		end
		if world.stopAfter ~= nil and world.placedCount >= world.stopAfter then
			world.stopNow = true -- STOP is pressed while this click is in flight; the block still appears
			world.stopAfter = nil
		end
		world.filled[k] = true
		world.owned = world.owned - 1
		world.placedCount = world.placedCount + 1
		return "placed"
	end
	return env
end

local function newJob(mn, mx, rowAxis, desc)
	return {
		order = Core.buildOrder(mn, mx, rowAxis or "z", desc or false),
		placed = 0, total = 0, placedSet = {}, reach = Core.newReach(),
	}
end

-- one run of AUTO BUILD (or RESUME) on an existing job
local function runJob(world, job)
	local env = makeEnv(world)
	world.stopNow = false
	if not Core.prepare(env, job) then
		return "stopped"
	end
	return Core.run(env, job, { maxFails = 3 })
end

local function countFilled(world)
	local n = 0
	for _ in pairs(world.filled) do
		n = n + 1
	end
	return n
end
local function attemptedTwice(world)
	local seen = {}
	for _, a in ipairs(world.attempts) do
		if seen[a.key] and world.filled[a.key] then
			return a.key
		end
		seen[a.key] = true
	end
	return nil
end
-- invariants that must hold after EVERY run, whatever happened
local function invariants(world, job, label)
	truthy(job.placed <= job.total, label .. ": placed (" .. job.placed .. ") exceeded total (" .. job.total .. ")")
	eq(world.clicksOnFilled, 0, label .. ": clicked a cell that already had a block")
	eq(world.moves, 0, label .. ": the character was moved")
	eq(job.placed, world.placedCount, label .. ": counted blocks != blocks really placed")
	eq(attemptedTwice(world), nil, label .. ": a cell was attempted again after it was filled")
end

local A = { x = 0, y = 0, z = 0 }
local B33 = { x = 2, y = 0, z = 2 } -- 3 x 1 x 3 = 9 cells

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

print("building: small areas")
test("3x1x3, empty: every cell filled once, counts exact", function()
	local w, job = newWorld(), newJob(A, B33)
	eq(runJob(w, job), "done")
	eq(job.placed, 9); eq(job.total, 9); eq(countFilled(w), 9); eq(#w.attempts, 9)
	invariants(w, job, "empty")
end)
test("a single-cell area", function()
	local w, job = newWorld(), newJob(A, A)
	eq(runJob(w, job), "done")
	eq(job.placed, 1); eq(job.total, 1)
	invariants(w, job, "1 cell")
end)
test("placed in exactly the planned order", function()
	local w, job = newWorld(), newJob(A, B33)
	runJob(w, job)
	local want = { "0,0,0", "1,0,0", "2,0,0", "0,0,1", "1,0,1", "2,0,1", "0,0,2", "1,0,2", "2,0,2" }
	for i, k in ipairs(want) do
		eq(w.attempts[i].key, k, "attempt " .. i)
	end
end)
test("a 7x1x21 area (like the real one)", function()
	local w, job = newWorld(), newJob(A, { x = 6, y = 0, z = 20 })
	eq(runJob(w, job), "done")
	eq(job.placed, 147); eq(job.total, 147)
	invariants(w, job, "7x1x21")
end)

print("building: existing blocks")
test("cells that already hold blocks are skipped and never clicked", function()
	local w, job = newWorld(), newJob(A, B33)
	for _, k in ipairs({ "0,0,0", "1,0,0", "2,0,1", "1,0,2" }) do w.filled[k] = true end
	eq(runJob(w, job), "done")
	eq(job.placed, 5); eq(job.total, 5); eq(countFilled(w), 9)
	invariants(w, job, "existing")
end)
test("a fully built area: nothing to do, nothing clicked", function()
	local w, job = newWorld(), newJob(A, B33)
	for i = 0, 2 do for j = 0, 2 do w.filled[key(i, 0, j)] = true end end
	eq(runJob(w, job), "done")
	eq(job.placed, 0); eq(job.total, 0); eq(#w.attempts, 0)
end)
test("somebody fills a cell while I'm building: it is skipped, total drops, nothing is double counted", function()
	local w, job = newWorld(), newJob(A, B33)
	local env = makeEnv(w)
	local placedNow = 0
	local baseAttempt = env.attempt
	env.attempt = function(c, d)
		local r, e = baseAttempt(c, d)
		if r == "placed" then
			placedNow = placedNow + 1
			if placedNow == 2 then w.filled["2,0,2"] = true end -- another player builds there
		end
		return r, e
	end
	w.stopNow = false
	truthy(Core.prepare(env, job))
	eq(Core.run(env, job, { maxFails = 3 }), "done")
	eq(job.placed, 8); eq(job.total, 8); eq(countFilled(w), 9)
	eq(w.clicksOnFilled, 0)
end)

print("building: gaps (cells I can't see) and resuming")
test("hidden cells stop the build with 'aim'; fixing the view and resuming finishes it, no repeats", function()
	local w, job = newWorld(), newJob(A, B33)
	w.hidden["1,0,1"] = true; w.hidden["1,0,2"] = true
	local res, code, extra = runJob(w, job)
	eq(res, "stop"); eq(code, "aim"); eq(extra.remaining, 2)
	eq(job.placed, 7); eq(job.total, 9)
	invariants(w, job, "gaps")
	w.hidden = {} -- the user tilts the camera; presses AUTO BUILD again (resume)
	w.attempts = {}
	eq(runJob(w, job), "done")
	eq(job.placed, 9); eq(job.total, 9); eq(#w.attempts, 2, "only the 2 missing cells are clicked")
	invariants(w, job, "gaps resumed")
end)
test("a whole row of gaps (the trench problem) is reported, not silently skipped", function()
	local w, job = newWorld(), newJob(A, { x = 6, y = 0, z = 6 })
	for x = 0, 6 do w.hidden[key(x, 0, 3)] = true end
	local res, code, extra = runJob(w, job)
	eq(res, "stop"); eq(code, "aim"); eq(extra.remaining, 7)
	eq(job.placed, 42)
end)

print("building: island edges (no character movement exists at all)")
test("cells beyond the island edge are never filled and the character never moves", function()
	local w, job = newWorld(), newJob(A, { x = 3, y = 0, z = 5 })
	w.island = function(c) return c.z <= 3 end -- ground only up to z = 3
	local res, code = runJob(w, job)
	eq(res, "stop"); eq(code, "aim")
	for x = 0, 3 do
		truthy(w.filled[key(x, 0, 3)], "island cells should be filled")
		truthy(not w.filled[key(x, 0, 4)], "off-island cell must stay empty")
		truthy(not w.filled[key(x, 0, 5)], "off-island cell must stay empty")
	end
	eq(job.placed, 16)
	invariants(w, job, "island")
end)

print("building: placement distance")
test("a refusal far away is learned as the range: no more clicks that far, reported OUT OF RANGE", function()
	local w, job = newWorld(), newJob(A, { x = 0, y = 0, z = 14 }) -- a line of 15 cells going away from the player
	w.range = 22
	local res, code, extra = runJob(w, job)
	eq(res, "stop"); eq(code, "range")
	local beyond = 0
	for _, a in ipairs(w.attempts) do
		if a.dist > 22 then beyond = beyond + 1 end
	end
	truthy(beyond <= 1, "clicked beyond the range " .. beyond .. " times (should be at most the single probe)")
	truthy(job.placed >= 5 and job.placed < 15, "placed " .. job.placed)
	truthy(job.reach.failMin ~= nil, "range should have been learned")
	invariants(w, job, "range")
	-- the user walks closer and resumes
	w.char = { x = 0, y = 3, z = 40 }
	w.attempts = {}
	eq(runJob(w, job), "done")
	eq(job.placed, 15); eq(job.total, 15)
	invariants(w, job, "range resumed")
end)
test("cells the game accepts at long range are NOT held back by a guess", function()
	local w, job = newWorld(), newJob(A, { x = 0, y = 0, z = 14 })
	w.range = 1e9
	eq(runJob(w, job), "done")
	eq(job.placed, 15)
end)
test("a refusal NEAR the player is a placement problem, not 'range': 3 in a row stop the build", function()
	local w, job = newWorld(), newJob(A, B33)
	w.refuse["0,0,0"] = true; w.refuse["1,0,0"] = true; w.refuse["2,0,0"] = true
	local res, code = runJob(w, job)
	eq(res, "stop"); eq(code, "failed")
	eq(#w.attempts, 3, "stops after the third refusal")
	eq(job.placed, 0)
end)

print("building: stopping, interruption and resuming")
test("STOP during a click: the block that really appeared is counted, nothing after it", function()
	local w, job = newWorld(), newJob(A, B33)
	w.stopAfter = 4
	eq(runJob(w, job), "stopped")
	eq(w.placedCount, 5); eq(job.placed, 5)
	invariants(w, job, "interrupted")
	w.attempts = {}
	eq(runJob(w, job), "done") -- resume
	eq(job.placed, 9); eq(job.total, 9); eq(#w.attempts, 4); eq(countFilled(w), 9)
	invariants(w, job, "resumed")
end)
test("STOP before anything: nothing placed, nothing counted", function()
	local w, job = newWorld(), newJob(A, B33)
	w.stopAfter = 0
	eq(runJob(w, job), "stopped")
	eq(job.placed, w.placedCount)
	invariants(w, job, "stop-first")
end)
test("interrupted over and over (every 2 blocks), each resume skips what exists - still exact", function()
	local w, job = newWorld(), newJob(A, { x = 4, y = 0, z = 4 }) -- 25 cells
	local rounds = 0
	while true do
		w.stopAfter = 1
		local res = runJob(w, job)
		rounds = rounds + 1
		invariants(w, job, "round " .. rounds)
		if res == "done" or rounds > 40 then break end
		w.stopAfter = nil
		w.stopNow = false
	end
	eq(job.placed, 25); eq(job.total, 25); eq(countFilled(w), 25)
end)

print("building: wrong placement and running out")
test("a block that lands in the wrong place stops the build at once", function()
	local w, job = newWorld(), newJob(A, B33)
	w.wrongPlace["2,0,0"] = true -- the 3rd cell
	local res, code, extra = runJob(w, job)
	eq(res, "stop"); eq(code, "misplaced")
	eq(#w.attempts, 3, "nothing is attempted after the wrong placement")
	eq(job.placed, 2)
end)
test("out of blocks stops; resuming with more blocks finishes, exact totals", function()
	local w, job = newWorld(), newJob(A, B33)
	w.owned = 4
	local res, code = runJob(w, job)
	eq(res, "stop"); eq(code, "noblocks")
	eq(job.placed, 4); eq(job.total, 9)
	invariants(w, job, "no blocks")
	w.owned = 100
	w.attempts = {}
	eq(runJob(w, job), "done")
	eq(job.placed, 9); eq(#w.attempts, 5)
	invariants(w, job, "no blocks resumed")
end)

print("counters and duplicates (even if the placement layer misbehaves)")
test("a placement layer that always claims success: each cell is attempted once, placed never exceeds total", function()
	local w, job = newWorld(), newJob(A, B33)
	local env = makeEnv(w)
	local calls = {}
	env.attempt = function(c)
		local k = Core.cellKey(c)
		calls[k] = (calls[k] or 0) + 1
		return "placed" -- lies: the world never gets the block
	end
	w.stopNow = false
	truthy(Core.prepare(env, job))
	eq(Core.run(env, job, { maxFails = 3 }), "done")
	eq(job.placed, 9); eq(job.total, 9)
	for k, n in pairs(calls) do eq(n, 1, "cell " .. k .. " attempted " .. n .. " times") end
end)
test("every new job starts from zero", function()
	local w1, j1 = newWorld(), newJob(A, B33)
	runJob(w1, j1)
	local w2, j2 = newWorld(), newJob(A, { x = 1, y = 0, z = 1 })
	runJob(w2, j2)
	eq(j2.placed, 4); eq(j2.total, 4)
end)

print("planning and bookkeeping details")
test("the plan counts only EMPTY cells before any click (existing blocks are not NEEDED)", function()
	local w, job = newWorld(), newJob(A, B33)
	w.filled["0,0,0"] = true; w.filled["1,0,1"] = true; w.filled["2,0,2"] = true
	truthy(Core.prepare(makeEnv(w), job))
	eq(#job.todo, 6, "cells to fill"); eq(job.total, 6, "total before the first click"); eq(job.placed, 0)
	for _, c in ipairs(job.todo) do
		truthy(not w.filled[Core.cellKey(c)], "an occupied cell was planned")
	end
end)
test("a cell this job filled is never planned or clicked again, even if the world is slow to show the block", function()
	local w, job = newWorld(), newJob(A, B33)
	w.stopAfter = 3
	runJob(w, job) -- STOP after 4 placed
	local placedKeys = {}
	for k in pairs(job.placedSet) do placedKeys[k] = true; w.filled[k] = nil end -- the world forgets them for a moment
	w.attempts = {}
	w.stopNow = false
	w.stopAfter = nil
	truthy(Core.prepare(makeEnv(w), job))
	for _, c in ipairs(job.todo) do
		truthy(not placedKeys[Core.cellKey(c)], "a placed cell was planned again")
	end
	eq(job.total, job.placed + #job.todo, "total = placed + still to place")
	eq(runJob(w, job), "done")
	for _, a in ipairs(w.attempts) do
		truthy(not placedKeys[a.key], "clicked an already placed cell again: " .. a.key)
	end
end)
test("consensus picks the majority lattice whichever way the buckets are iterated", function()
	-- majority at a high bucket, minorities at low ones ... and the other way round
	local a, b = {}, {}
	for i = 1, 6 do a[#a + 1] = 3.0; b[#b + 1] = 0.2 end
	a[#a + 1] = 0.2; a[#a + 1] = 0.2; a[#a + 1] = 0.8
	b[#b + 1] = 3.0; b[#b + 1] = 3.0; b[#b + 1] = 2.4
	local va = Core.consensus(a, 4)
	local vb = Core.consensus(b, 4)
	near(va, 3.0, 0.05, "majority at 3.0"); near(vb, 0.2, 0.05, "majority at 0.2")
end)

print("defence in depth: the run loop protects itself even from a bad plan")
test("a cell listed twice in the plan is clicked once and counted once", function()
	local w, job = newWorld(), newJob(A, B33)
	local c1, c2 = { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }
	job.todo = { c1, c1, c2 }
	job.total = 2
	eq(Core.run(makeEnv(w), job, { maxFails = 3 }), "done")
	eq(job.placed, 2); eq(job.total, 2); eq(w.placedCount, 2); eq(#w.attempts, 2)
	invariants(w, job, "duplicate in plan")
end)
test("never places more blocks than the plan's total", function()
	local w, job = newWorld(), newJob(A, B33)
	job.todo = { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, { x = 2, y = 0, z = 0 } }
	job.total = 2
	eq(Core.run(makeEnv(w), job, { maxFails = 3 }), "done")
	eq(job.placed, 2); eq(w.placedCount, 2, "blocks really placed")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
