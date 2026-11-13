-- Integration tests for AutoBuilder_MacSploit.lua: the script's REAL placeCell / attemptCell / runJob /
-- autoBuild / stop code, run against a SIMULATED world (fake Roblox objects, fake mouse, fake blocks).
-- Run with:  python3 roblox/tests/run_glue_tests.py
--
-- What this proves:  the glue around the tested core is wired correctly - the right checks run before every
--   click, a block is counted only when the simulated world shows it in the right cell, STOP / resume / out of
--   range / out of blocks / hidden cells / wrong placement all end the way the menu says they do.
-- What it can NOT prove: anything about the real game - the real raycasts, the real mouse events, the custom
--   hotbar GUI, and whether the game accepts a click as a placement. Those need an in-game test.
--
-- (Provided by the runner: SRC = the script text, with the Luau-only "+=" rewritten to plain Lua; HOOKS = Lua
--  appended to the script so the tests can reach a few of its locals.)

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
local function truthy(v, msg)
	if not v then
		error(msg or "expected true", 2)
	end
end
local function has(text, part, msg)
	if not string.find(tostring(text), part, 1, true) then
		error((msg or "text mismatch") .. ": expected to contain '" .. part .. "' but got: " .. tostring(text), 2)
	end
end

----------------------------------------------------------------------------------------------
-- mock Roblox: a permissive "anything" object, and a real Vector3
----------------------------------------------------------------------------------------------
local D = {}
D.__index = function(t, k)
	if type(k) == "number" then
		return nil
	end
	return t
end
D.__newindex = function() end
D.__call = function(t) return t end
D.__len = function() return 0 end
D.__concat = function() return "?" end
D.__lt = function() return false end
D.__le = function() return false end
D.__eq = function() return false end
for _, op in ipairs({ "add", "sub", "mul", "div", "mod", "pow", "unm", "idiv" }) do
	D["__" .. op] = function(a) return a end
end
local function anything() return setmetatable({}, D) end

local V3 = {}
V3.__index = function(t, k)
	if k == "X" then return rawget(t, "x") elseif k == "Y" then return rawget(t, "y") elseif k == "Z" then return rawget(t, "z")
	elseif k == "Magnitude" then return math.sqrt(t.x * t.x + t.y * t.y + t.z * t.z)
	elseif k == "Unit" then
		local m = math.sqrt(t.x * t.x + t.y * t.y + t.z * t.z)
		return V3.new(t.x / m, t.y / m, t.z / m)
	elseif k == "Dot" then
		return function(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
	end
	return nil
end
V3.__add = function(a, b) return V3.new(a.x + b.x, a.y + b.y, a.z + b.z) end
V3.__sub = function(a, b) return V3.new(a.x - b.x, a.y - b.y, a.z - b.z) end
V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return V3.new(a.x * b, a.y * b, a.z * b) end
	return V3.new(a.x * b.x, a.y * b.y, a.z * b.z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return V3.new(a.x / b, a.y / b, a.z / b) end
	return V3.new(a.x / b.x, a.y / b.y, a.z / b.z)
end
V3.__unm = function(a) return V3.new(-a.x, -a.y, -a.z) end
V3.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function V3.new(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V3) end

local function fakePart(pos, size)
	return {
		Position = pos, Size = V3.new(size, size, size), Transparency = 0, CanCollide = true, Parent = true, Name = "Part",
		IsA = function(_, cls) return cls == "BasePart" end,
		IsDescendantOf = function() return false end,
		FindFirstAncestorOfClass = function() return nil end,
	}
end

----------------------------------------------------------------------------------------------
-- a fresh copy of the script on a fresh simulated world
----------------------------------------------------------------------------------------------
local SIZE = 4
local function key(c) return c.x .. "," .. c.y .. "," .. c.z end

local function boot()
	local now = 0
	local queue = {}
	local warnings = {}
	local task = {}
	function task.spawn(f, ...)
		local co = coroutine.create(f)
		local ok, e = coroutine.resume(co, ...)
		if not ok then warnings[#warnings + 1] = "task error: " .. tostring(e) end
		if coroutine.status(co) == "suspended" then queue[#queue + 1] = co end
	end
	function task.wait(t)
		now = now + (t or 0.03)
		coroutine.yield()
		return t or 0.03
	end
	task.delay = function(_, f, ...) task.spawn(f, ...) end
	task.defer = function(f, ...) task.spawn(f, ...) end

	local genv = {}
	local env = setmetatable({
		task = task, getgenv = function() return genv end,
		warn = function(...) warnings[#warnings + 1] = tostring((...)) end,
		print = function() end, typeof = function(x) return type(x) end,
		os = setmetatable({ clock = function() return now end }, { __index = os }),
		math = math, string = string, table = table, coroutine = coroutine, pcall = pcall, xpcall = xpcall,
		select = select, tostring = tostring, tonumber = tonumber, pairs = pairs, ipairs = ipairs, next = next,
		type = type, error = error, assert = assert, setmetatable = setmetatable, getmetatable = getmetatable,
		rawget = rawget, rawset = rawset, unpack = table.unpack, debug = debug, utf8 = utf8,
		tick = function() return now end, time = function() return now end,
		game = anything(), workspace = anything(), Vector3 = V3, Enum = anything(),
	}, { __index = function(_, k) if type(k) == "string" and k:match("^[A-Z]") then return anything() end return nil end })
	env.Instance = { new = function() return anything() end }

	local chunk, err = load(SRC .. "\n" .. HOOKS, "AutoBuilder", "t", env)
	assert(chunk, "could not load the script: " .. tostring(err))
	chunk()
	queue = {} -- forget the script's own background loop (the 4 Hz tick); the tests drive what they need

	local T = genv.__T
	local W = {
		filled = {}, hidden = {}, refuse = {}, wrongPlace = {}, owned = 1000, range = 1e9, char = V3.new(0, 3, 0),
		shift = V3.new(0, 0, 0), island = nil, ids = {}, clicks = {}, clicksOnFilled = 0, placedCount = 0,
		stopAfter = nil, unequipAfter = nil, countersBroken = nil, warnings = warnings, T = T,
	}
	local function center(c)
		return V3.new((c.x + 0.5) * SIZE, (c.y + 0.5) * SIZE, (c.z + 0.5) * SIZE) + W.shift
	end
	W.center = center

	-- the mocked leaves of the script
	T.set("detectBlock", function()
		T.S.block = { name = "Grass Block", slot = 4, source = "hotbar" }
		return true
	end)
	T.set("ensureEquipped", function() return not (W.unequipAfter and W.placedCount >= W.unequipAfter) end)
	T.set("itemGone", function() return false end)
	T.set("readOwned", function() return W.owned, "simulated" end)
	T.set("calibrateNear", function() return false end)
	T.set("cellOccupied", function(c) return W.filled[key(c)] == true end)
	T.set("myParts", function() return nil, { Position = W.char } end)
	T.set("UIS", { MouseBehavior = env.Enum.MouseBehavior.Default })
	T.set("findAims", function(cell)
		local k = key(cell)
		if W.hidden[k] then
			return nil, "hidden from the camera - tilt / turn the camera so you can see that spot"
		end
		if W.island and not W.island(cell) then
			return nil, "no ground there"
		end
		W.ids[#W.ids + 1] = cell
		return { { x = 100 + #W.ids, y = 200, world = center(cell) } }
	end)
	T.Input.method = "simulated"
	T.Input.selfTest = function() return true end
	T.Input.switchToExecutor = function() return false end
	T.Input.moveTo = function() return true end
	T.Input.click = function(x)
		local cell = W.ids[x - 100]
		local k = key(cell)
		W.clicks[#W.clicks + 1] = k
		T.Input.seen, T.Input.seenProcessed = true, false -- "the game saw the click"
		if W.filled[k] then
			W.clicksOnFilled = W.clicksOnFilled + 1
		end
		-- the counters shown to the player must never exceed the plan, at any moment
		if T.S.state == "building" and T.S.placed > T.S.total then
			W.countersBroken = string.format("placed %d > total %d", T.S.placed, T.S.total)
		end
		if W.owned <= 0 or W.refuse[k] or (W.char - center(cell)).Magnitude > W.range then
			return true -- the game places nothing
		end
		local landed = cell
		if W.wrongPlace[k] then
			landed = { x = cell.x + 1, y = cell.y, z = cell.z }
		end
		if W.filled[key(landed)] then
			return true
		end
		W.filled[key(landed)] = true
		W.owned = W.owned - 1
		W.placedCount = W.placedCount + 1
		T.Watch.list[#T.Watch.list + 1] = fakePart(center(landed), SIZE)
		if W.stopAfter and W.placedCount >= W.stopAfter then
			W.stopAfter = nil
			T.stop() -- the player presses STOP while this click is in flight
		end
		return true
	end

	function W.drain()
		for _ = 1, 200000 do
			if #queue == 0 then
				return
			end
			local q = queue
			queue = {}
			for _, co in ipairs(q) do
				local ok, e = coroutine.resume(co)
				if not ok then warnings[#warnings + 1] = "coroutine error: " .. tostring(e) end
				if coroutine.status(co) == "suspended" then queue[#queue + 1] = co end
			end
		end
		error("the build never finished")
	end
	function W.select(a, b)
		T.S.a, T.S.b = a, b
		T.setSelection()
		W.drain()
	end
	function W.press()
		T.autoBuild()
		W.drain()
	end
	return W
end

local function noScriptErrors(W)
	for _, w in ipairs(W.warnings) do
		-- (the mock GUI can't format everything; only the build itself must be clean)
		if string.find(w, "build failed", 1, true) or string.find(w, "task error", 1, true) or string.find(w, "coroutine error", 1, true) then
			error("script error during the build: " .. w)
		end
	end
end
local function invariants(W, label)
	local S = W.T.S
	eq(W.clicksOnFilled, 0, label .. ": clicked a cell that already had a block")
	eq(W.countersBroken, nil, label .. ": the counters were inconsistent while building")
	eq(S.placed, W.placedCount, label .. ": menu says " .. tostring(S.placed) .. " placed, " .. W.placedCount .. " really placed")
	truthy(S.placed <= S.total, label .. ": placed exceeded total")
	noScriptErrors(W)
end

local A = { x = 0, y = 0, z = 0 }
local B33 = { x = 2, y = 0, z = 2 }

----------------------------------------------------------------------------------------------
print("small areas")
test("3x1x3, empty: every block placed and verified once, menu ends on Done", function()
	local W = boot()
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(S.total, 9); eq(#W.clicks, 9); eq(W.placedCount, 9)
	has(S.status, "Done! 9 of 9")
	invariants(W, "empty")
end)
test("a single-cell area", function()
	local W = boot()
	W.select(A, A)
	W.press()
	eq(W.T.S.placed, 1); eq(W.T.S.state, "done"); eq(#W.clicks, 1)
	invariants(W, "single")
end)
test("the menu job restarts from zero for a new area", function()
	local W = boot()
	W.select(A, B33)
	W.press()
	eq(W.T.S.placed, 9)
	W.select({ x = 0, y = 1, z = 0 }, { x = 1, y = 1, z = 1 }) -- the layer above
	W.press()
	eq(W.T.S.placed, 4); eq(W.T.S.total, 4)
	eq(W.placedCount, 13)
end)
test("rows start at the end farthest from the player (the player stands at z=0 here, so the z=2 row goes first)", function()
	local W = boot()
	W.select(A, B33)
	W.press()
	has(W.clicks[1], ",2", "first click should be in the far row")
	local W2 = boot()
	W2.char = V3.new(0, 3, 20)
	W2.select(A, B33)
	W2.press()
	has(W2.clicks[1], ",0", "first click should be in the z=0 row when standing beyond z=2")
end)

print("existing blocks")
test("existing blocks are skipped and never clicked; NEEDED/total only counts empty cells", function()
	local W = boot()
	W.filled["0,0,0"] = true; W.filled["1,0,1"] = true
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 7); eq(S.total, 7); eq(#W.clicks, 7)
	-- placedCount counts only the blocks the builder placed
	eq(W.placedCount, 7)
	invariants(W, "existing")
end)
test("a full area: nothing to build, nothing clicked", function()
	local W = boot()
	for x = 0, 2 do for z = 0, 2 do W.filled[x .. ",0," .. z] = true end end
	W.select(A, B33)
	W.press()
	eq(#W.clicks, 0)
	has(W.T.S.status, "Nothing to build")
end)

print("gaps (cells that can't be reached from the current view) and resuming")
test("hidden cells: stops with [AIM] and says RESUME; fixing the view and pressing again finishes without repeats", function()
	local W = boot()
	W.hidden["1,0,1"] = true; W.hidden["1,0,2"] = true
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 7); eq(S.total, 9)
	has(S.status, "[AIM]"); has(S.status, "RESUME"); has(S.status, "never touch your camera")
	truthy(S.job and S.job.resumable, "the job should be resumable")
	invariants(W, "gaps")
	W.hidden = {}
	W.clicks = {}
	W.press()
	eq(S.state, "done"); eq(S.placed, 9); eq(S.total, 9); eq(#W.clicks, 2, "only the two missing cells")
	invariants(W, "gaps resumed")
end)
test("selecting a new area discards a stopped job", function()
	local W = boot()
	W.hidden["1,0,1"] = true
	W.select(A, B33)
	W.press()
	truthy(W.T.S.job ~= nil)
	W.select(A, { x = 1, y = 0, z = 1 })
	eq(W.T.S.job, nil)
end)

print("island edges (the character can't be moved, so cells without ground are reported, never forced)")
test("no ground under the last row: stopped with [AIM], those cells never clicked", function()
	local W = boot()
	W.island = function(c) return c.z < 2 end
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 6); eq(#W.clicks, 6)
	has(S.status, "[AIM]")
	for _, k in ipairs(W.clicks) do
		truthy(not string.find(k, ",2$"), "clicked a cell beyond the island edge: " .. k)
	end
	invariants(W, "island")
end)

print("out-of-range positions")
test("far cells are refused by the game: learned as the range, reported OUT OF RANGE, nothing is walked; stepping closer and resuming finishes", function()
	local W = boot()
	W.range = 12
	W.select(A, { x = 4, y = 0, z = 4 }) -- 25 cells; from (0,3,0) the far ones are 25 studs away
	W.press()
	local S = W.T.S
	eq(S.state, "idle")
	has(S.status, "OUT OF RANGE"); has(S.status, "walk closer yourself"); has(S.status, "RESUME")
	truthy(S.placed > 0 and S.placed < 25, "some placed, not all: " .. S.placed)
	invariants(W, "range")
	local before = #W.clicks
	W.char = V3.new(10, 3, 10) -- the player steps to the middle by themselves
	W.press()
	eq(S.state, "done"); eq(S.placed, 25); eq(S.total, 25)
	invariants(W, "range resumed")
	truthy(#W.clicks - before <= 25 - 0, "resume re-clicked placed cells")
end)

print("stopping and interrupted construction")
test("STOP pressed while a click is in flight: the block that really appeared is counted, nothing is clicked afterwards", function()
	local W = boot()
	W.stopAfter = 3
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 3); eq(#W.clicks, 3)
	truthy(S.job and S.job.resumable)
	invariants(W, "stop")
end)
test("pressing the button again after STOP resumes the same job; total clicks == cells", function()
	local W = boot()
	W.stopAfter = 3
	W.select(A, B33)
	W.press()
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(S.total, 9); eq(#W.clicks, 9)
	invariants(W, "stop+resume")
end)
test("interrupted again and again (every 2 blocks): always exact", function()
	local W = boot()
	W.select(A, { x = 3, y = 0, z = 3 })
	for _ = 1, 20 do
		W.stopAfter = W.placedCount + 2
		W.press()
		invariants(W, "round")
		if W.T.S.state == "done" then break end
	end
	eq(W.T.S.state, "done"); eq(W.T.S.placed, 16); eq(#W.clicks, 16)
end)

print("placement problems")
test("a block that lands in a different cell stops the build at once and is not counted", function()
	local W = boot()
	W.char = V3.new(0, 3, 20) -- standing beyond the area: rows are filled z=0 first
	W.wrongPlace["1,0,1"] = true -- lands in (2,0,1)
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 3 + 1, "z=0 row + (0,0,1) only"); eq(#W.clicks, 5)
	eq(W.placedCount, 5, "the wrong block exists in the world, but is NOT counted")
	has(S.status, "[PLACEMENT]"); has(S.status, "instead of (1,0,1)"); has(S.status, "RESUME")
	eq(W.clicksOnFilled, 0); eq(W.countersBroken, nil); noScriptErrors(W)
end)
test("a block that lands OUTSIDE the area says so", function()
	local W = boot()
	W.char = V3.new(0, 3, 20)
	W.wrongPlace["2,0,2"] = true -- lands in (3,0,2), outside
	W.select(A, B33)
	W.press()
	has(W.T.S.status, "OUTSIDE the selected area")
	eq(W.T.S.placed, 8)
end)
test("the game refuses one cell for no visible reason: reported as a placement problem, not an aiming problem", function()
	local W = boot()
	W.refuse["1,0,1"] = true
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 8)
	has(S.status, "[PLACEMENT]"); has(S.status, "RESUME")
	W.refuse = {}
	W.press()
	eq(S.state, "done"); eq(S.placed, 9)
	invariants(W, "refused")
end)

print("blocks you own")
test("out of blocks: stops exactly when they run out, resume after getting more", function()
	local W = boot()
	W.owned = 4
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 4); eq(S.state, "idle")
	has(S.status, "Out of blocks"); has(S.status, "RESUME")
	W.owned = 100
	W.press()
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9)
	invariants(W, "blocks")
end)
test("the block is deselected mid-build: stops with [ITEM] before the next click, resume after selecting it again", function()
	local W = boot()
	W.unequipAfter = 3
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 3); eq(#W.clicks, 3); eq(S.state, "idle")
	has(S.status, "[ITEM]"); has(S.status, "isn't the selected hotbar item")
	W.unequipAfter = nil
	W.press()
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9)
	invariants(W, "unequipped")
end)
test("zero blocks: nothing is clicked", function()
	local W = boot()
	W.owned = 0
	W.select(A, B33)
	W.press()
	eq(#W.clicks, 0)
end)

print("the game's grid")
test("a small grid offset is adopted from the first block (once); every block lands in its own cell", function()
	local W = boot()
	W.shift = V3.new(1.2, 0, 0.8) -- 0.3 / 0.2 of a block: fine for the first block, too much for any later one
	W.select(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9)
	invariants(W, "offset")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
