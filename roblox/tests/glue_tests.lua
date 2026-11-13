-- Integration tests for AutoBuilder_MacSploit.lua: the script's REAL walkPlace / runWalk /
-- autoBuild / stop / clearSelection code, run against a SIMULATED world (fake Roblox objects, fake mouse, fake blocks).
-- Run with:  python3 roblox/tests/run_glue_tests.py
--
-- What this proves:  the glue around the tested core is wired correctly - the right checks run before every
--   click, a block is counted only when the simulated world shows it in the right cell, STOP / resume / out of
--   range / out of blocks / hidden cells / wrong placement all end the way the menu says they do.
-- What it can NOT prove: anything about the real game - the real raycast from the crosshair, the real mouse
--   events, the custom hotbar GUI, and whether the game accepts a click as a placement. Those need an in-game test.
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

local V2 = {}
V2.__index = function(t, k)
	if k == "X" then return rawget(t, "x") elseif k == "Y" then return rawget(t, "y")
	elseif k == "Magnitude" then return math.sqrt(t.x * t.x + t.y * t.y) end
	return nil
end
V2.__sub = function(a, b) return V2.new(a.x - b.x, a.y - b.y) end
V2.__add = function(a, b) return V2.new(a.x + b.x, a.y + b.y) end
function V2.new(x, y) return setmetatable({ x = x or 0, y = y or 0 }, V2) end

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
local DWELL = 0.4 -- seconds the simulated player looks at each cell

local function boot()
	local now = 0
	local queue = {}
	local warnings = {}
	local W
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
		game = anything(), workspace = anything(), Vector3 = V3, Vector2 = V2, Enum = anything(),
	}, { __index = function(_, k) if type(k) == "string" and k:match("^[A-Z]") then return anything() end return nil end })
	env.Instance = { new = function() return anything() end }

	local chunk, err = load(SRC .. "\n" .. HOOKS, "AutoBuilder", "t", env)
	assert(chunk, "could not load the script: " .. tostring(err))
	chunk()
	queue = {} -- forget the script's own background loop (the 4 Hz tick); the tests drive what they need

	local T = genv.__T
	W = {
		filled = {}, refuse = {}, wrongPlace = {}, mismatch = {}, owned = 1000, range = 1e9, char = V3.new(0, 3, 0),
		shift = V3.new(0, 0, 0), gaze = {}, alternate = false, clicks = {}, clicksOnFilled = 0, clicksOutside = 0,
		placedCount = 0, stopAfter = nil, clearAfter = nil, toggleAfter = nil, clickTimes = {}, unequipFrom = math.huge, unequipUntil = -1, clickRefusals = 0,
		deadline = 600, script = nil, countersBroken = nil, lastTarget = nil, looks = 0, warnings = warnings, T = T,
	}
	local function center(c)
		return V3.new((c.x + 0.5) * SIZE, (c.y + 0.5) * SIZE, (c.z + 0.5) * SIZE) + W.shift
	end
	W.center = center
	function W.now() return now end

	-- the mocked leaves of the script
	T.set("detectBlock", function()
		T.S.block = { name = "Grass Block", slot = 4, source = "hotbar" }
		return true
	end)
	T.set("ensureEquipped", function() return not (now >= W.unequipFrom and now < W.unequipUntil) end)
	T.set("itemGone", function() return false end)
	T.set("readOwned", function() return W.owned, "simulated" end)
	T.set("calibrateNear", function() return false end)
	T.set("cellOccupied", function(c) return W.filled[key(c)] == true end)
	T.set("myParts", function() return nil, { Position = W.char } end)
	T.set("ghostCheck", function(_, cell)
		if W.mismatch[key(cell)] then return false, "the preview is somewhere else" end
		return true
	end)
	-- The simulated player: looks at the cells in W.gaze, DWELL seconds each (cycling), and walks / does things
	-- on a script of their own (W.script(now)). The crosshair is always at the middle of the screen.
	T.set("lookTarget", function()
		W.looks = W.looks + 1
		if W.script then W.script(now) end
		if now > W.deadline then
			W.deadline = math.huge
			T.stop() -- the test is over: the player gives up
		end
		local n = #W.gaze
		if n == 0 then return nil, "pointing at the sky" end
		local i
		if W.alternate then i = (W.looks % n) + 1 else i = math.floor(now / DWELL) % n + 1 end
		local cell = W.gaze[i]
		if cell == false then return nil, "pointing at the sky" end
		W.lastTarget = { x = 640 + (W.jitterPixels and (W.looks % 2) * 20 or 0), y = 360, world = center(cell), cell = cell }
		return W.lastTarget
	end)
	T.Input.method = "simulated"
	T.Input.switchToExecutor = function() return false end
	T.Input.click = function(x, y)
		if W.clickRefusals > 0 then
			W.clickRefusals = W.clickRefusals - 1
			return false -- the cursor moved in the last instant before the click
		end
		local cell = W.lastTarget.cell
		local k = key(cell)
		W.clicks[#W.clicks + 1] = k
		W.clickTimes[#W.clickTimes + 1] = now
		T.Input.seen, T.Input.seenProcessed = true, false -- "the game saw the click"
		if W.filled[k] then W.clicksOnFilled = W.clicksOnFilled + 1 end
		local S = T.S
		if S.min and (cell.x < S.min.x or cell.x > S.max.x or cell.y < S.min.y or cell.y > S.max.y or cell.z < S.min.z or cell.z > S.max.z) then
			W.clicksOutside = W.clicksOutside + 1
		end
		if S.state == "building" and S.placed > S.total then
			W.countersBroken = string.format("placed %d > total %d", S.placed, S.total)
		end
		if W.owned <= 0 or W.refuse[k] or (W.char - center(cell)).Magnitude > W.range then
			return true -- the game places nothing
		end
		local landed = cell
		if W.wrongPlace[k] then
			landed = W.wrongPlace[k]
			W.wrongPlace[k] = nil -- (it happens once for that cell)
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
		if W.clearAfter and W.placedCount >= W.clearAfter then
			W.clearAfter = nil
			T.clearSelection()
		end
		if W.toggleAfter and W.placedCount >= W.toggleAfter then
			W.toggleAfter = nil
			T.fillOrStop() -- the big button (which says STOP now)
		end
		return true
	end

	function W.drain()
		for _ = 1, 400000 do
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
	-- the player walks around looking at every cell of the area (and some outside it)
	function W.sweep(mn, mx, margin)
		W.gaze = {}
		margin = margin or 0
		for y = mn.y - margin, mx.y + margin do
			for z = mn.z - margin, mx.z + margin do
				for x = mn.x - margin, mx.x + margin do W.gaze[#W.gaze + 1] = { x = x, y = y, z = z } end
			end
		end
	end
	return W
end

local function noScriptErrors(W)
	for _, w in ipairs(W.warnings) do
		if string.find(w, "build failed", 1, true) or string.find(w, "auto place failed", 1, true) or string.find(w, "task error", 1, true) or string.find(w, "coroutine error", 1, true) then
			error("script error during the build: " .. w)
		end
	end
end
local function invariants(W, label)
	local S = W.T.S
	eq(W.clicksOnFilled, 0, label .. ": clicked a cell that already had a block")
	eq(W.clicksOutside, 0, label .. ": clicked outside the selected area")
	eq(W.countersBroken, nil, label .. ": the counters were inconsistent while building")
	eq(S.placed, W.placedCount, label .. ": menu says " .. tostring(S.placed) .. " placed, " .. W.placedCount .. " really placed")
	truthy(S.placed <= S.total, label .. ": placed exceeded total")
	noScriptErrors(W)
end

local A, B33 = { x = 0, y = 0, z = 0 }, { x = 2, y = 0, z = 2 }

----------------------------------------------------------------------------------------------
print("walking around and looking")
test("walk around a 3x3 floor: every empty spot you look at gets one block; the menu ends on Done", function()
	local W = boot()
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(S.total, 9); eq(#W.clicks, 9); eq(W.placedCount, 9)
	has(S.status, "Done! 9 of 9")
	invariants(W, "sweep")
end)
test("a single-cell area", function()
	local W = boot()
	W.select(A, A)
	W.sweep(A, A)
	W.press()
	eq(W.T.S.placed, 1); eq(W.T.S.state, "done"); eq(#W.clicks, 1)
	invariants(W, "single")
end)
test("looking at cells outside the area, or on the layer above (no stacking), never places anything there", function()
	local W = boot()
	W.select(A, B33)
	W.sweep({ x = 0, y = -1, z = 0 }, { x = 2, y = 2, z = 2 }, 3)
	W.press()
	eq(W.T.S.state, "done"); eq(#W.clicks, 9)
	for _, k in ipairs(W.clicks) do truthy(string.find(k, "^%d,0,%d$"), "clicked outside the flat area: " .. k) end
	invariants(W, "outside")
end)
test("existing blocks are never clicked or counted", function()
	local W = boot()
	W.filled["0,0,0"] = true; W.filled["1,0,1"] = true
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 7); eq(S.total, 7); eq(#W.clicks, 7); invariants(W, "existing")
end)
test("a full area: nothing to place", function()
	local W = boot()
	for x = 0, 2 do for z = 0, 2 do W.filled[x .. ",0," .. z] = true end end
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	eq(#W.clicks, 0); has(W.T.S.status, "Nothing to place")
end)
test("pointing at the sky or nothing: waits, clicks nothing, STOP works", function()
	local W = boot()
	W.select(A, B33)
	W.gaze = { false }
	W.deadline = 5
	W.press()
	eq(#W.clicks, 0); eq(W.T.S.state, "idle"); truthy(W.T.S.job and W.T.S.job.resumable)
end)
test("only clicks when you hold still: if the spot under the crosshair changes between two looks, nothing is sent", function()
	local W = boot()
	W.select(A, B33)
	W.sweep(A, B33)
	W.alternate = true -- every look sees a different cell (you are turning fast)
	W.deadline = 10
	W.press()
	eq(#W.clicks, 0, "must not click while the view is moving"); noScriptErrors(W)
end)
test("the cursor itself is moving (third person, mouse in use) even though the same cell is under it: nothing is sent", function()
	local W = boot()
	W.select(A, B33)
	W.sweep(A, B33)
	W.jitterPixels = true
	W.deadline = 10
	W.press()
	eq(#W.clicks, 0); noScriptErrors(W)
end)
test("the click lands in the cell the crosshair pointed at, one block per click, placed == really placed", function()
	local W = boot()
	W.select(A, { x = 4, y = 0, z = 4 })
	W.sweep(A, { x = 4, y = 0, z = 4 })
	W.press()
	eq(W.T.S.placed, 25); eq(W.placedCount, 25); invariants(W, "25")
end)
test("a small grid offset is adopted from the first block (once); every block lands in its own cell", function()
	local W = boot()
	W.shift = V3.new(1.2, 0, 0.8)
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	eq(W.T.S.state, "done"); eq(W.T.S.placed, 9); invariants(W, "offset")
end)

print("the flat area")
test("point B takes point A's height: the area is one layer", function()
	local W = boot()
	local S = W.T.S
	-- the two clicks of SELECT AREA, with a fake mouse ray: A on the floor, B on top of a 2-block wall
	local hits = {
		{ Instance = fakePart(V3.new(6, 0, 6), 40), Position = V3.new(6, 0, 6), Normal = V3.new(0, 1, 0) },
		{ Instance = fakePart(V3.new(30, 8, 30), 40), Position = V3.new(30, 8, 30), Normal = V3.new(0, 1, 0) },
	}
	local n = 0
	W.T.set("pickRay", function() n = n + 1; return hits[n] end)
	S.pick = "A"
	W.T.handleClick()
	S.pick = "B"
	W.T.handleClick()
	truthy(S.a and S.b, "both corners should be set")
	eq(S.a.y, S.b.y, "B must be on A's layer")
	eq(S.min.y, S.max.y)
end)
test("a tall area is refused by AUTO PLACE (no stacking)", function()
	local W = boot()
	W.select(A, { x = 2, y = 3, z = 2 })
	W.press()
	has(W.T.S.status, "flat"); eq(#W.clicks, 0)
end)

print("placement distance (you walk; it never does)")
test("far spots are refused by the game: learned as the range, no spam, no stop; walk closer and they fill", function()
	local W = boot()
	W.range = 18
	W.select(A, { x = 6, y = 0, z = 6 })
	W.sweep(A, { x = 6, y = 0, z = 6 })
	W.script = function(t)
		if t > 60 and W.char.x == 0 then W.char = V3.new(14, 3, 14) end -- the player walks to the middle
	end
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 49)
	truthy(#W.clicks < 49 + 40, "too many clicks wasted on far spots: " .. #W.clicks)
	invariants(W, "range")
end)
test("no spot is ever clicked at a range the game refused, until the player is closer", function()
	local W = boot()
	W.range = 18
	W.select(A, { x = 6, y = 0, z = 6 })
	W.sweep(A, { x = 6, y = 0, z = 6 })
	W.deadline = 60
	W.press()
	local S = W.T.S
	truthy(S.placed > 0 and S.placed < 49, "some in reach, some not: " .. S.placed)
	eq(S.state, "idle"); truthy(S.job.reach.failMin ~= nil)
	invariants(W, "range partial")
end)

print("stopping and resuming")
test("STOP while a click is in flight: the block that really appeared is counted, nothing is clicked afterwards", function()
	local W = boot()
	W.stopAfter = 3
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 3); eq(#W.clicks, 3); truthy(S.job and S.job.resumable)
	invariants(W, "stop")
end)
test("pressing the button again after STOP resumes the same job; total clicks == cells", function()
	local W = boot()
	W.stopAfter = 3
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(S.total, 9); eq(#W.clicks, 9)
	invariants(W, "stop+resume")
end)
test("the big button is STOP while building and RESUME afterwards", function()
	local W = boot()
	W.toggleAfter = 4
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.placed, 4); truthy(S.job and S.job.resumable)
	W.T.fillOrStop()
	W.drain()
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9); invariants(W, "toggle")
end)
test("CLEAR SELECTION during a build stops it at once and clears everything", function()
	local W = boot()
	W.clearAfter = 3
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); eq(S.min, nil); eq(S.job, nil); eq(#W.clicks, 3); eq(S.placed, 3)
	eq(W.clicksOnFilled, 0); noScriptErrors(W)
end)
test("CLEAR SELECTION forgets the area; AUTO PLACE then asks for a new one", function()
	local W = boot()
	W.select(A, B33)
	W.T.clearSelection()
	eq(W.T.S.a, nil); eq(W.T.S.min, nil); eq(W.T.S.job, nil); has(W.T.S.status, "Selection cleared")
	W.press()
	has(W.T.S.status, "Select an area first")
end)
test("selecting a new area discards a stopped job", function()
	local W = boot()
	W.stopAfter = 2
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	truthy(W.T.S.job ~= nil)
	W.select(A, { x = 1, y = 0, z = 1 })
	eq(W.T.S.job, nil)
end)
test("interrupted again and again: always exact", function()
	local W = boot()
	W.select(A, { x = 3, y = 0, z = 3 })
	W.sweep(A, { x = 3, y = 0, z = 3 })
	for _ = 1, 30 do
		W.stopAfter = W.placedCount + 2
		W.press()
		invariants(W, "round")
		if W.T.S.state == "done" then break end
	end
	eq(W.T.S.state, "done"); eq(W.T.S.placed, 16); eq(#W.clicks, 16)
end)

print("your blocks")
test("out of blocks: stops exactly when they run out, resume after getting more", function()
	local W = boot()
	W.owned = 4
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.placed, 4); eq(S.state, "idle"); has(S.status, "Out of blocks"); has(S.status, "RESUME")
	W.owned = 100
	W.press()
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9); invariants(W, "blocks")
end)
test("zero blocks: nothing is clicked", function()
	local W = boot()
	W.owned = 0
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	eq(#W.clicks, 0)
end)
test("the block is deselected for a while: it waits (no clicks, no stop) and carries on when you select it again", function()
	local W = boot()
	W.unequipFrom, W.unequipUntil = 3, 30 -- after 3 s you switch to something else, until 30 s
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "done"); eq(S.placed, 9); eq(#W.clicks, 9)
	invariants(W, "unequipped")
end)
test("while the block is deselected nothing is ever clicked", function()
	local W = boot()
	W.unequipFrom, W.unequipUntil = 5, 1e9
	W.select(A, B33)
	W.sweep(A, B33)
	W.deadline = 20
	W.press()
	truthy(#W.clicks > 0, "it should have clicked before the block was deselected")
	for _, t in ipairs(W.clickTimes) do truthy(t < 5.5, "clicked at " .. t .. " s, after the block was deselected at 5 s") end
	eq(W.T.S.state, "idle"); truthy(W.T.S.job and W.T.S.job.resumable)
end)

print("placement problems")
test("a block that lands in another cell INSIDE the area: not counted, build carries on, that cell is filled later", function()
	local W = boot()
	W.wrongPlace["0,0,0"] = { x = 1, y = 0, z = 0 }
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "done", S.status); eq(W.placedCount, 9, "every cell has a block"); eq(S.placed, 8, "the stray one is not counted")
	eq(W.clicksOnFilled, 0); eq(W.clicksOutside, 0); noScriptErrors(W)
end)
test("a block that lands OUTSIDE the area stops the build and says so", function()
	local W = boot()
	W.wrongPlace["2,0,1"] = { x = 3, y = 0, z = 1 }
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	eq(W.T.S.state, "idle"); has(W.T.S.status, "OUTSIDE the selected area"); has(W.T.S.status, "RESUME")
end)
test("the game refuses spots close to you for no visible reason: reported as a placement problem", function()
	local W = boot()
	W.char = V3.new(6, 3, 6)
	for x = 0, 2 do for z = 0, 2 do W.refuse[x .. ",0," .. z] = true end end
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	local S = W.T.S
	eq(S.state, "idle"); has(S.status, "[PLACEMENT]"); has(S.status, "RESUME"); eq(S.placed, 0)
	W.refuse = {}
	W.press()
	eq(S.state, "done"); eq(S.placed, 9)
end)
test("the game's own placement preview points elsewhere: nothing is clicked", function()
	local W = boot()
	for x = 0, 2 do for z = 0, 2 do W.mismatch[x .. ",0," .. z] = true end end
	W.select(A, B33)
	W.sweep(A, B33)
	W.deadline = 60
	W.press()
	eq(#W.clicks, 0, "no click may be sent when the preview disagrees")
end)
test("a click refused at the last instant (the cursor moved) is not a click and not a failure", function()
	local W = boot()
	W.clickRefusals = 8
	W.select(A, B33)
	W.sweep(A, B33)
	W.press()
	eq(W.T.S.state, "done"); eq(W.T.S.placed, 9); eq(#W.clicks, 9)
	invariants(W, "refusals")
end)

print("the menu")
test("the area note says exactly how many spots will be filled and how many are already filled", function()
	local W = boot()
	W.filled["0,0,0"] = true; W.filled["1,0,1"] = true
	W.T.S.areaNote = true
	W.select(A, B33)
	has(W.T.S.status, "7 to fill, 2 already filled"); eq(W.T.S.needed, 7)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
