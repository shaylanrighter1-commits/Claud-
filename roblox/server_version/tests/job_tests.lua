-- Unit tests for Shared.lua and BuildJob.lua (pure Lua, no Roblox). Run: python3 roblox/server_version/tests/run_tests.py
-- They test the RULES: inventory conservation (blocks leave the inventory only when a block is really placed),
-- no overwriting, no duplicates, permission, out of blocks, stop / resume, counters. They do not test Roblox.
local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passed = passed + 1; print("  ok    " .. name)
	else failed = failed + 1; print("  FAIL  " .. name .. "\n          " .. tostring(err)) end
end
local function eq(a, e, msg) if a ~= e then error((msg or "values differ") .. ": expected " .. tostring(e) .. ", got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected true", 2) end end

local function key(c) return c.x .. "," .. c.y .. "," .. c.z end

print("shared: areas and order")
test("order: bottom layer first, rows by z, x left to right, every cell once", function()
	local o = Shared.buildOrder({ x = 0, y = 0, z = 0 }, { x = 2, y = 1, z = 1 })
	eq(o.n, 12)
	local seen = {}
	for i = 1, o.n do
		local k = o.xs[i] .. "," .. o.ys[i] .. "," .. o.zs[i]
		truthy(not seen[k], "duplicate " .. k); seen[k] = true
	end
	eq(o.xs[1], 0); eq(o.xs[2], 1); eq(o.xs[3], 2); eq(o.zs[4], 1); eq(o.ys[7], 1, "second layer starts after the first")
end)
test("area: corners in any order give the same box", function()
	local mn, mx, n = Shared.area({ x = 5, y = 2, z = -3 }, { x = 1, y = 0, z = 4 })
	eq(mn.x, 1); eq(mn.y, 0); eq(mn.z, -3); eq(mx.x, 5); eq(mx.y, 2); eq(mx.z, 4); eq(n, 5 * 3 * 8)
end)
test("area: bad input from the network is rejected", function()
	local bad = { nil, 5, "x", {}, { x = 1, y = 2 }, { x = 1.5, y = 0, z = 0 }, { x = 0 / 0, y = 0, z = 0 },
		{ x = math.huge, y = 0, z = 0 }, { x = "1", y = 0, z = 0 }, { x = 1e9, y = 0, z = 0 }, { x = 0, y = -1e9, z = 0 } }
	local good = { x = 0, y = 0, z = 0 }
	for i = 1, 11 do
		local mn = Shared.area(bad[i], good)
		eq(mn, nil, "case " .. i .. " should be rejected")
		eq((Shared.area(good, bad[i])), nil, "case " .. i .. " (b) should be rejected")
	end
end)
test("area: too big is rejected with a reason", function()
	local mn, why = Shared.area({ x = 0, y = 0, z = 0 }, { x = 99, y = 99, z = 99 })
	eq(mn, nil); truthy(string.find(why, "too big"))
end)
test("area: the limit itself is allowed", function()
	local mn = Shared.area({ x = 0, y = 0, z = 0 }, { x = 19, y = 9, z = 19 }) -- 20 x 10 x 20 = 4000, exactly the limit
	truthy(mn ~= nil)
end)
test("cell <-> world round trip, including negative cells", function()
	for _, c in ipairs({ { x = 0, y = 0, z = 0 }, { x = -1, y = -5, z = 7 }, { x = 12, y = 3, z = -20 } }) do
		local x, y, z = Shared.cellCenter(c)
		local back = Shared.worldToCell(x, y, z)
		eq(back.x, c.x); eq(back.y, c.y); eq(back.z, c.z)
	end
end)

----------------------------------------------------------------------------------------------
local function newWorld()
	return {
		filled = {}, owned = 1000, start = 1000, denied = {}, refuse = {}, stopNow = false, stopAfter = nil,
		fillAfter = nil, placedKeys = {}, placedCount = 0, doublePlace = 0, waits = 0, maxSeenPlaced = 0, broken = nil, attempts = {},
	}
end
local function makeEnv(W)
	local env = {}
	env.stopped = function() return W.stopNow end
	env.isOccupied = function(c) return W.filled[key(c)] ~= nil end
	env.canBuild = function(c)
		if W.denied[key(c)] then return false, "not your land" end
		return true
	end
	env.owned = function() return W.owned end
	env.take = function()
		if W.owned < 1 then return false end
		W.owned = W.owned - 1
		return true
	end
	env.give = function() W.owned = W.owned + 1 end
	env.place = function(c)
		local k = key(c)
		W.attempts[#W.attempts + 1] = k
		if W.filled[k] then W.doublePlace = W.doublePlace + 1; return false, "taken" end
		if W.refuse[k] then return false, "refused by the game" end
		W.filled[k] = true
		W.placedKeys[k] = true
		W.placedCount = W.placedCount + 1
		if W.stopAfter and W.placedCount >= W.stopAfter then W.stopNow = true; W.stopAfter = nil end
		if W.fillAfter and W.placedCount >= W.fillAfter.count then
			for _, kk in ipairs(W.fillAfter.cells) do W.filled[kk] = "other" end
			W.fillAfter = nil
		end
		return true
	end
	env.wait = function() W.waits = W.waits + 1 end
	env.progress = function(j)
		if j.placed > j.total then W.broken = "placed " .. j.placed .. " > total " .. j.total end
		W.maxSeenPlaced = math.max(W.maxSeenPlaced, j.placed)
	end
	env.log = function() end
	return env
end
local function newJob(mn, mx)
	return BuildJob.new(mn, mx, "grass_block", Shared.buildOrder(mn, mx))
end
local function run(W, job, cfg)
	W.stopNow = false
	return BuildJob.run(job, makeEnv(W), cfg or { perBatch = 3, batchDelay = 0.1, maxFails = 3 })
end
-- must hold after EVERY run
local function invariants(W, job, label)
	eq(W.broken, nil, label .. ": counters inconsistent")
	truthy(job.placed <= job.total, label .. ": placed exceeded total")
	eq(job.placed, W.placedCount, label .. ": counted != really placed")
	eq(W.start - W.owned, W.placedCount, label .. ": the inventory went down by " .. (W.start - W.owned) .. " but " .. W.placedCount .. " blocks were placed")
	eq(W.doublePlace, 0, label .. ": placed into a cell that already had a block")
end
local A, B33 = { x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 2 }

print("building")
test("3x1x3 empty: all placed, inventory down by exactly 9", function()
	local W, job = newWorld(), newJob(A, B33)
	eq(run(W, job), "done"); eq(job.placed, 9); eq(job.total, 9); eq(W.owned, 991)
	invariants(W, job, "empty")
end)
test("a single cell", function()
	local W, job = newWorld(), newJob(A, A)
	eq(run(W, job), "done"); eq(W.owned, 999); invariants(W, job, "single")
end)
test("existing blocks are never overwritten or charged", function()
	local W, job = newWorld(), newJob(A, B33)
	W.filled["0,0,0"] = "other"; W.filled["1,0,1"] = "other"
	eq(run(W, job), "done"); eq(job.placed, 7); eq(job.total, 7); eq(W.owned, 993)
	eq(W.filled["0,0,0"], "other", "an existing block was replaced")
	invariants(W, job, "existing")
end)
test("a full area: nothing placed, nothing charged", function()
	local W, job = newWorld(), newJob(A, B33)
	for x = 0, 2 do for z = 0, 2 do W.filled[x .. ",0," .. z] = "other" end end
	eq(run(W, job), "done"); eq(W.placedCount, 0); eq(W.owned, 1000)
end)
test("someone else builds in the area while I build: those cells are skipped, no overwrite, exact counts", function()
	local W, job = newWorld(), newJob({ x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 0 })
	W.fillAfter = { count = 1, cells = { "3,0,0", "4,0,0" } }
	eq(run(W, job), "done"); eq(job.placed, 3); eq(job.total, 3); eq(W.owned, 997)
	eq(W.filled["3,0,0"], "other"); invariants(W, job, "concurrent")
end)
test("a big area (4000 cells) finishes, one block per cell", function()
	local W, job = newWorld(), newJob({ x = 0, y = 0, z = 0 }, { x = 19, y = 9, z = 19 })
	W.owned = 5000; W.start = 5000
	eq(run(W, job), "done"); eq(job.placed, 4000); eq(#W.attempts, 4000); invariants(W, job, "big")
end)
test("speed pacing: it pauses between small batches instead of flooding the server", function()
	local W, job = newWorld(), newJob({ x = 0, y = 0, z = 0 }, { x = 29, y = 0, z = 0 })
	run(W, job, { perBatch = 3, batchDelay = 0.1, maxFails = 3 })
	truthy(W.waits >= 10, "expected at least 10 pauses for 30 blocks, got " .. W.waits)
end)

print("materials")
test("out of blocks: pauses exactly when they run out and says how many are still needed", function()
	local W, job = newWorld(), newJob(A, B33)
	W.owned = 4; W.start = 4
	local res, code, extra = run(W, job)
	eq(res, "paused"); eq(code, "noblocks"); eq(extra.remaining, 5); eq(job.placed, 4); eq(W.owned, 0)
	invariants(W, job, "out")
	W.owned = 100; W.start = 100 + 4 -- (the 4 already placed were paid for before)
	eq(run(W, job), "done"); eq(job.placed, 9); eq(W.placedCount, 9)
	eq(W.doublePlace, 0)
end)
test("zero blocks: nothing placed", function()
	local W, job = newWorld(), newJob(A, B33)
	W.owned = 0; W.start = 0
	local res, code = run(W, job)
	eq(res, "paused"); eq(code, "noblocks"); eq(W.placedCount, 0)
end)
test("take() refusing (inventory changed under us) pauses; nothing placed for free", function()
	local W, job = newWorld(), newJob(A, B33)
	local env = makeEnv(W)
	local real = env.take
	local n = 0
	env.take = function() n = n + 1; if n > 3 then return false end return real() end
	local res, code = BuildJob.run(job, env, { perBatch = 3, batchDelay = 0.1, maxFails = 3 })
	eq(res, "paused"); eq(code, "noblocks"); eq(W.placedCount, 3); eq(W.start - W.owned, 3)
end)

test("an unreadable inventory count pauses at once: nothing is placed on a guess", function()
	local W, job = newWorld(), newJob(A, B33)
	local env = makeEnv(W)
	env.owned = function() return nil end
	local res, code = BuildJob.run(job, env, {})
	eq(res, "paused"); eq(code, "noblocks"); eq(W.placedCount, 0); eq(W.owned, 1000)
end)

print("failures: the player's blocks come back")
test("a refused placement hands the block back; the rest still builds; resume finishes", function()
	local W, job = newWorld(), newJob(A, B33)
	W.refuse["1,0,1"] = true
	local res, code, extra = run(W, job)
	eq(res, "paused"); eq(code, "failed"); eq(extra.remaining, 1); eq(job.placed, 8)
	invariants(W, job, "refused") -- includes: the inventory only went down by 8
	W.refuse = {}
	eq(run(W, job), "done"); eq(job.placed, 9); invariants(W, job, "refused+resume")
end)
test("three failures in a row pause at once (not 1000 retries)", function()
	local W, job = newWorld(), newJob({ x = 0, y = 0, z = 0 }, { x = 9, y = 0, z = 0 })
	for x = 0, 9 do W.refuse[x .. ",0,0"] = true end
	local res, code = run(W, job)
	eq(res, "paused"); eq(code, "failed"); truthy(#W.attempts <= 3, "attempts: " .. #W.attempts); eq(W.owned, 1000)
end)

print("permission")
test("cells the player may not build in are never built; the rest is; the pause says so", function()
	local W, job = newWorld(), newJob(A, B33)
	W.denied["2,0,0"] = true; W.denied["2,0,1"] = true; W.denied["2,0,2"] = true
	local res, code, extra = run(W, job)
	eq(res, "paused"); eq(code, "denied"); eq(extra.remaining, 3); eq(job.placed, 6)
	for _, k in ipairs(W.attempts) do truthy(not W.denied[k], "tried to build in a forbidden cell " .. k) end
	invariants(W, job, "denied")
	W.denied = {}
	eq(run(W, job), "done"); eq(job.placed, 9)
end)

print("stop / resume")
test("STOP: stops before the next block; resume carries on; no repeats", function()
	local W, job = newWorld(), newJob(A, B33)
	W.stopAfter = 4
	eq(run(W, job), "stopped"); eq(job.placed, 4); invariants(W, job, "stop")
	eq(run(W, job), "done"); eq(job.placed, 9); eq(#W.attempts, 9); invariants(W, job, "stop+resume")
end)
test("interrupted again and again: always exact", function()
	local W, job = newWorld(), newJob(A, { x = 4, y = 0, z = 4 })
	for _ = 1, 40 do
		W.stopAfter = W.placedCount + 2
		local res = run(W, job)
		invariants(W, job, "round")
		if res == "done" then break end
	end
	eq(job.placed, 25); eq(W.owned, 975)
end)
test("STOP before anything: nothing happens", function()
	local W, job = newWorld(), newJob(A, B33)
	W.stopNow = true
	local env = makeEnv(W)
	env.stopped = function() return true end
	eq(BuildJob.run(job, env, {}), "stopped"); eq(W.placedCount, 0); eq(W.owned, 1000)
end)

print("bookkeeping")
test("a cell this job filled is never placed again, even if the world is slow to show the block", function()
	local W, job = newWorld(), newJob(A, B33)
	W.stopAfter = 4
	eq(run(W, job), "stopped")
	local mine = {}
	for k in pairs(W.placedKeys) do mine[k] = true; W.filled[k] = nil end -- the world "forgets" them for a moment
	W.attempts = {}
	eq(run(W, job), "done")
	for _, k in ipairs(W.attempts) do truthy(not mine[k], "placed again: " .. k) end
end)
test("a block somebody removed during the build is noticed by the final look and filled", function()
	local W, job = newWorld(), newJob({ x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 0 })
	W.filled["4,0,0"] = "other" -- there when the build starts ...
	local env = makeEnv(W)
	local place = env.place
	env.place = function(c) -- ... and gone after the second block
		local ok, why = place(c)
		if W.placedCount == 2 then W.filled["4,0,0"] = nil end
		return ok, why
	end
	eq(BuildJob.run(job, env, { perBatch = 3, batchDelay = 0.1, maxFails = 3 }), "done")
	eq(W.filled["4,0,0"], true, "the cell that became empty was never filled")
	eq(job.placed, 5); invariants(W, job, "removed")
end)

print("counters")
test("a new job starts at zero; its total is only the empty cells", function()
	local W1, j1 = newWorld(), newJob(A, B33)
	run(W1, j1)
	local W2, j2 = newWorld(), newJob(A, { x = 1, y = 0, z = 1 })
	run(W2, j2)
	eq(j2.placed, 4); eq(j2.total, 4)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
