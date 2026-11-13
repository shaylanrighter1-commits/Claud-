-- Tests for AutoBuilderServer.server.lua: the REAL server script run against a simulated Roblox
-- (fake Players / remotes / scheduler) and a fake Backend. It checks what the server does with whatever a
-- client sends: validation, the item being decided by the server, inventory deduction, out of blocks, STOP and
-- RESUME, permissions, many players. It does NOT test Roblox itself or the client menu.
-- Run: python3 roblox/server_version/tests/run_tests.py
local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passed = passed + 1; print("  ok    " .. name)
	else failed = failed + 1; print("  FAIL  " .. name .. "\n          " .. tostring(err)) end
end
local function eq(a, e, msg) if a ~= e then error((msg or "values differ") .. ": expected " .. tostring(e) .. ", got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected true", 2) end end
local function has(text, part, msg)
	if not string.find(tostring(text), part, 1, true) then error((msg or "text") .. ": expected '" .. part .. "' in: " .. tostring(text), 2) end
end
local function key(c) return c.x .. "," .. c.y .. "," .. c.z end

local function signal()
	local s = { handlers = {} }
	function s:Connect(f) self.handlers[#self.handlers + 1] = f; return { Disconnect = function() end } end
	function s:fire(...) for _, h in ipairs(self.handlers) do h(...) end end
	return s
end

local function boot()
	local now, queue, warnings = 0, {}, {}
	local task = {}
	function task.spawn(f, ...)
		local co = coroutine.create(f)
		local ok, e = coroutine.resume(co, ...)
		if not ok then warnings[#warnings + 1] = "task error: " .. tostring(e) end
		if coroutine.status(co) == "suspended" then queue[#queue + 1] = co end
	end
	function task.wait(t) now = now + (t or 0.03); coroutine.yield(); return t or 0.03 end

	local H = { updates = {}, warnings = warnings, players = {} }
	function H.drain()
		for _ = 1, 400000 do
			if #queue == 0 then return end
			local q = queue; queue = {}
			for _, co in ipairs(q) do
				local ok, e = coroutine.resume(co)
				if not ok then warnings[#warnings + 1] = "coroutine error: " .. tostring(e) end
				if coroutine.status(co) == "suspended" then queue[#queue + 1] = co end
			end
		end
		error("never finished")
	end

	-- fake Backend: a world with an inventory, an equipped item, a build zone
	local W = { filled = {}, inv = {}, equipped = {}, zone = nil, refuse = {}, throwOn = nil, placedBy = {}, itemsUsed = {}, onPlace = nil }
	local Backend = {}
	function Backend.getEquipped(p)
		local id = W.equipped[p]
		if not id then return nil, "Equip a block first." end
		return { id = id, name = (id == "grass_block") and "Grass Block" or "Dirt Block", owned = (W.inv[p] or {})[id] or 0 }
	end
	function Backend.getOwned(p, id) return (W.inv[p] or {})[id] or 0 end
	function Backend.take(p, id, n)
		local have = Backend.getOwned(p, id)
		if have < n then return false end
		W.inv[p][id] = have - n
		return true
	end
	function Backend.give(p, id, n) W.inv[p][id] = Backend.getOwned(p, id) + n end
	function Backend.canBuild(p, c)
		if W.zone and (c.x < W.zone.x0 or c.x > W.zone.x1 or c.z < W.zone.z0 or c.z > W.zone.z1) then return false, "not your land" end
		return true
	end
	function Backend.isOccupied(c) return W.filled[key(c)] ~= nil end
	function Backend.place(p, id, c)
		local k = key(c)
		if W.throwOn == k then error("backend exploded") end
		if W.filled[k] then return false, "taken" end
		if W.refuse[k] then return false, "refused" end
		W.filled[k] = id
		W.placedBy[k] = p
		W.itemsUsed[id] = (W.itemsUsed[id] or 0) + 1
		if W.onPlace then W.onPlace(p, c) end
		return true
	end
	function Backend.setup() end

	-- fake services and remotes
	local folder = { children = {} }
	function folder:FindFirstChild(n) return self.children[n] end
	function folder:WaitForChild(n)
		if n == "Shared" then return { __module = "Shared" } end
		return self.children[n]
	end
	local function mockInstance(class)
		local r = { ClassName = class, Name = "", fired = {} }
		if class == "RemoteEvent" then
			r.OnServerEvent = signal()
			function r:FireClient(p, state) H.updates[p] = H.updates[p] or {}; table.insert(H.updates[p], state) end
		end
		return setmetatable(r, { __newindex = function(t, k, v)
			rawset(t, k, v)
			if k == "Parent" and v and v.children then v.children[t.Name] = t end
		end })
	end
	local playersSvc = { PlayerAdded = signal(), PlayerRemoving = signal(), list = {} }
	function playersSvc:GetPlayers() return self.list end
	local services = {
		Players = playersSvc,
		ReplicatedStorage = { WaitForChild = function(_, n) if n == "AutoBuilder" then return folder end end },
	}
	local modules = { Shared = SharedModule, BuildJob = BuildJobModule, Backend = Backend }
	local env = setmetatable({
		task = task, print = function() end, warn = function(...) warnings[#warnings + 1] = tostring((...)) .. " " .. tostring((select(2, ...))) end,
		os = setmetatable({ clock = function() return now end }, { __index = os }),
		math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, pcall = pcall, tostring = tostring,
		tonumber = tonumber, type = type, select = select, error = error, setmetatable = setmetatable, next = next, coroutine = coroutine,
		game = { GetService = function(_, n) return services[n] end },
		Instance = { new = mockInstance },
		require = function(obj) return modules[obj.__module] end,
		script = { Parent = { WaitForChild = function(_, n) return { __module = n } end } },
	}, { __index = function() return nil end })
	local chunk, err = load(SERVER_SRC, "AutoBuilderServer", "t", env)
	assert(chunk, tostring(err))
	chunk()

	local Action, Query = folder.children.Action, folder.children.Query
	function H.player(name, id, owned)
		local p = { Name = name, Parent = true, UserId = 1 }
		playersSvc.list[#playersSvc.list + 1] = p
		W.inv[p] = { grass_block = owned or 1000, dirt_block = 50 }
		W.equipped[p] = id == nil and "grass_block" or (id ~= false and id or nil)
		playersSvc.PlayerAdded:fire(p)
		return p
	end
	function H.fire(p, ...) Action.OnServerEvent:fire(p, ...) end
	function H.last(p) local u = H.updates[p]; return u and u[#u] end
	function H.query(p, a, b)
		local result
		local co = coroutine.create(function() result = Query.OnServerInvoke(p, a, b) end)
		local ok, e = coroutine.resume(co)
		if not ok then warnings[#warnings + 1] = "query error: " .. tostring(e) end
		if coroutine.status(co) == "suspended" then queue[#queue + 1] = co end
		H.drain()
		return result
	end
	function H.advance(t) now = now + t end
	function H.leave(p)
		for i, q in ipairs(playersSvc.list) do if q == p then table.remove(playersSvc.list, i) end end
		p.Parent = nil
		playersSvc.PlayerRemoving:fire(p)
	end
	H.W, H.Backend = W, Backend
	return H
end
local function clean(H)
	for _, w in ipairs(H.warnings) do
		if string.find(w, "error", 1, true) or string.find(w, "crashed", 1, true) then error("server error: " .. w) end
	end
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local A, B = { x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 4 } -- 25 cells

print("building from anywhere, paid for from the inventory")
test("start: every block placed, inventory down by exactly the number placed, status done", function()
	local H = boot(); local p = H.player("Alice", nil, 100)
	H.fire(p, "start", A, B); H.drain()
	local s = H.last(p)
	eq(s.status, "done"); eq(s.placed, 25); eq(s.total, 25); has(s.message, "DONE")
	eq(count(H.W.filled), 25); eq(H.W.inv[p].grass_block, 75); eq(H.W.itemsUsed.grass_block, 25)
	clean(H)
end)
test("progress is reported while building", function()
	local H = boot(); local p = H.player("Alice")
	H.fire(p, "start", A, B); H.drain()
	local building = 0
	for _, u in ipairs(H.updates[p]) do if u.status == "building" then building = building + 1 end end
	truthy(building >= 1, "no progress updates were sent")
end)
test("a far-away area is just as buildable (there is no distance check, only permission)", function()
	local H = boot(); local p = H.player("Alice")
	local far = { x = 90, y = 3, z = -80 }
	H.fire(p, "start", far, { x = 92, y = 3, z = -78 }); H.drain()
	eq(H.last(p).status, "done"); eq(count(H.W.filled), 9)
end)

print("the server never trusts the client")
test("garbage corners are refused; nothing is placed or charged", function()
	local H = boot(); local p = H.player("Alice", nil, 100)
	local bad = { "x", 5, {}, { x = 1.5, y = 0, z = 0 }, { x = 0 / 0, y = 0, z = 0 }, { x = math.huge, y = 0, z = 0 }, { x = 1e9, y = 0, z = 0 } }
	for _, b in ipairs(bad) do
		H.advance(1)
		H.fire(p, "start", A, b); H.drain()
		eq(H.last(p).status, "error", "should be refused")
	end
	H.advance(1)
	H.fire(p, "start", A, { x = 400, y = 400, z = 400 }); H.drain()
	has(H.last(p).message, "too big")
	eq(count(H.W.filled), 0); eq(H.W.inv[p].grass_block, 100); clean(H)
end)
test("the block used is the one the SERVER sees in the hand, whatever the client claims", function()
	local H = boot(); local p = H.player("Alice")
	H.fire(p, "start", A, { x = 1, y = 0, z = 1 }, "diamond_block", 999999); H.drain()
	eq(H.W.itemsUsed.grass_block, 4); eq(H.W.itemsUsed.diamond_block, nil)
end)
test("nothing equipped: refused", function()
	local H = boot(); local p = H.player("Alice", false)
	H.fire(p, "start", A, B); H.drain()
	eq(H.last(p).status, "error"); has(H.last(p).message, "Equip"); eq(count(H.W.filled), 0)
end)
test("unknown actions and a second start while building are ignored", function()
	local H = boot(); local p = H.player("Alice")
	H.fire(p, "give me blocks", A, B); H.fire(p, 42); H.fire(p, nil)
	H.drain()
	eq(count(H.W.filled), 0)
	H.fire(p, "start", A, B); H.fire(p, "start", A, B); H.fire(p, "start", A, B); H.drain()
	eq(count(H.W.filled), 25); eq(H.W.inv[p].grass_block, 975); clean(H)
end)

test("pressing start again while it is building does nothing (no second builder, no double charge)", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl)
		if count(H.W.filled) == 3 then H.advance(1); H.fire(pl, "start", A, B) end
	end
	H.fire(p, "start", A, B); H.drain()
	eq(H.last(p).status, "done"); eq(count(H.W.filled), 25); eq(H.W.inv[p].grass_block, 975); eq(H.W.itemsUsed.grass_block, 25)
end)

print("materials")
test("out of blocks: stops exactly there, says how many more, RESUME finishes with no waste", function()
	local H = boot(); local p = H.player("Alice", nil, 10)
	H.fire(p, "start", A, B); H.drain()
	local s = H.last(p)
	eq(s.status, "paused"); eq(s.code, "noblocks"); eq(s.placed, 10); has(s.message, "Get 15 more"); has(s.message, "RESUME")
	eq(H.W.inv[p].grass_block, 0); eq(count(H.W.filled), 10)
	H.W.inv[p].grass_block = 15
	H.advance(1)
	H.fire(p, "start", A, B); H.drain()
	s = H.last(p)
	eq(s.status, "done"); eq(s.placed, 25); eq(s.total, 25); eq(count(H.W.filled), 25); eq(H.W.inv[p].grass_block, 0)
end)
test("no blocks at all: refused before anything happens", function()
	local H = boot(); local p = H.player("Alice", nil, 0)
	H.fire(p, "start", A, B); H.drain()
	has(H.last(p).message, "no Grass Block"); eq(count(H.W.filled), 0)
end)
test("a placement that errors inside the game's code returns the block, never loses it", function()
	local H = boot(); local p = H.player("Alice", nil, 100)
	H.W.throwOn = "2,0,0"
	H.fire(p, "start", A, { x = 4, y = 0, z = 0 }); H.drain()
	local s = H.last(p)
	eq(s.status, "paused"); eq(s.code, "failed"); eq(s.placed, 4)
	eq(H.W.inv[p].grass_block, 96, "only the 4 placed blocks may be charged")
end)

print("stop and resume")
test("STOP ends the build before the next block; the same area resumes (counters continue)", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl) if count(H.W.filled) == 7 then H.fire(pl, "stop") end end
	H.fire(p, "start", A, B); H.drain()
	local s = H.last(p)
	eq(s.status, "paused"); eq(s.code, "stopped"); eq(s.placed, 7); eq(count(H.W.filled), 7); has(s.message, "RESUME")
	H.W.onPlace = nil
	H.advance(1)
	H.fire(p, "start", A, B); H.drain()
	s = H.last(p)
	eq(s.status, "done"); eq(s.placed, 25); eq(count(H.W.filled), 25); eq(H.W.inv[p].grass_block, 975)
end)
test("after STOP a different area starts a NEW job from zero", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl) if count(H.W.filled) == 3 then H.fire(pl, "stop") end end
	H.fire(p, "start", A, B); H.drain()
	H.W.onPlace = nil
	H.advance(1)
	H.fire(p, "start", { x = 10, y = 0, z = 10 }, { x = 11, y = 0, z = 11 }); H.drain()
	local s = H.last(p)
	eq(s.status, "done"); eq(s.placed, 4); eq(s.total, 4)
end)
test("switching the item in hand mid-build does not change what is placed", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl) if count(H.W.filled) == 2 then H.W.equipped[pl] = "dirt_block"; H.W.inv[pl].dirt_block = 0 end end
	H.fire(p, "start", A, B); H.drain()
	eq(H.W.itemsUsed.grass_block, 25); eq(H.W.itemsUsed.dirt_block, nil)
end)

print("permission")
test("where the player may not build nothing is placed; the rest is; the message says so", function()
	local H = boot(); local p = H.player("Alice")
	H.W.zone = { x0 = 0, x1 = 2, z0 = 0, z1 = 4 }
	H.fire(p, "start", A, B); H.drain()
	local s = H.last(p)
	eq(s.status, "paused"); eq(s.code, "denied"); eq(s.placed, 15); has(s.message, "NOT ALLOWED"); eq(count(H.W.filled), 15)
	for k in pairs(H.W.filled) do truthy(tonumber(string.match(k, "^(%-?%d+)")) <= 2, "built outside the allowed zone: " .. k) end
	eq(H.W.inv[p].grass_block, 985)
end)

print("the menu's questions")
test("query: needed / owned / name for the selected area", function()
	local H = boot(); local p = H.player("Alice", nil, 40)
	H.W.filled["0,0,0"] = "x"
	local s = H.query(p, A, B)
	eq(s.needed, 24); eq(s.owned, 40); eq(s.name, "Grass Block"); eq(s.message, "READY"); eq(s.resumable, false)
end)
test("query: says how many more blocks are needed", function()
	local H = boot(); local p = H.player("Alice", nil, 10)
	has(H.query(p, A, B).message, "You need 15 more")
end)
test("query: no area -> just the block and owned", function()
	local H = boot(); local p = H.player("Alice", nil, 33)
	local s = H.query(p, nil, nil)
	eq(s.owned, 33); eq(s.name, "Grass Block")
end)
test("query: refuses a bad area; reports forbidden spots; rate-limited, never builds", function()
	local H = boot(); local p = H.player("Alice")
	eq(H.query(p, A, { x = 1.5, y = 0, z = 0 }).status, "error")
	H.advance(1)
	H.W.zone = { x0 = 0, x1 = 1, z0 = 0, z1 = 4 }
	has(H.query(p, A, B).message, "NOT ALLOWED")
	eq(count(H.W.filled), 0)
end)
test("query: a stopped build of exactly this area is resumable", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl) if count(H.W.filled) == 6 then H.fire(pl, "stop") end end
	H.fire(p, "start", A, B); H.drain()
	H.W.onPlace = nil
	H.advance(1)
	local s = H.query(p, A, B)
	eq(s.resumable, true); eq(s.placed, 6); eq(s.needed, 19); eq(s.total, 25)
	H.advance(1)
	eq(H.query(p, A, { x = 9, y = 0, z = 9 }).resumable, false)
end)

print("many players")
test("two players build at once, each charged only for their own blocks", function()
	local H = boot(); local a, b = H.player("Alice"), H.player("Bob")
	H.fire(a, "start", A, B); H.fire(b, "start", { x = 20, y = 0, z = 20 }, { x = 22, y = 0, z = 22 }); H.drain()
	eq(H.last(a).status, "done"); eq(H.last(b).status, "done")
	eq(H.W.inv[a].grass_block, 975); eq(H.W.inv[b].grass_block, 991)
end)
test("more than 10 builds at once: the extra one is told to wait, nothing breaks", function()
	local H = boot(); local ps = {}
	for i = 1, 11 do ps[i] = H.player("P" .. i) end
	for i = 1, 11 do
		H.fire(ps[i], "start", { x = i * 10, y = 0, z = 0 }, { x = i * 10 + 3, y = 0, z = 3 })
	end
	H.drain()
	local busy = 0
	for i = 1, 11 do if H.last(ps[i]).code == "busy" then busy = busy + 1 end end
	eq(busy, 1)
end)
test("a player leaving mid-build stops it cleanly", function()
	local H = boot(); local p = H.player("Alice")
	H.W.onPlace = function(pl) if count(H.W.filled) == 5 then H.leave(pl) end end
	H.fire(p, "start", A, B); H.drain()
	eq(count(H.W.filled), 5); clean(H)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
__failures = failed
