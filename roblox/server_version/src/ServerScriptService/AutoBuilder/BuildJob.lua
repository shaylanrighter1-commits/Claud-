--!nocheck
-- The build loop. Plain Lua with NO Roblox API: everything it needs from the world comes through `env`,
-- so the rules below are unit-tested (tests/run_tests.py) without Roblox.
--
-- Rules this module enforces, whatever the backend does:
--   * the block is TAKEN from the inventory first and handed back if the placement fails,
--     so the inventory only ever goes down by the number of blocks that were really placed;
--   * `placed` counts only blocks the backend confirmed, and can never exceed `total`;
--   * a cell this job filled is never placed again; an occupied cell is skipped (never overwritten);
--   * a cell the player isn't allowed to build in is never built;
--   * running out of blocks pauses the job (it can be resumed); STOP leaves the job resumable too.
local BuildJob = {}

local function key(c)
	return string.format("%d,%d,%d", c.x, c.y, c.z)
end

function BuildJob.new(mn, mx, itemId, order)
	return { mn = mn, mx = mx, itemId = itemId, order = order, placed = 0, total = 0, placedSet = {}, todo = {} }
end

-- Look at the world now: which cells still need a block?  total = placed so far + still empty.
-- env.isOccupied(cell) -> bool, env.wait(s), env.stopped() -> bool.   Returns false if STOP was pressed.
function BuildJob.plan(job, env)
	local order, todo = job.order, {}
	for i = 1, order.n do
		local cell = { x = order.xs[i], y = order.ys[i], z = order.zs[i] }
		if not job.placedSet[key(cell)] and not env.isOccupied(cell) then
			todo[#todo + 1] = cell
		end
		if i % 200 == 0 then
			env.wait(0) -- never hold up the server while looking at a big area
			if env.stopped() then
				return false
			end
		end
	end
	job.todo = todo
	job.total = job.placed + #todo
	return true
end

-- env: stopped() isOccupied(cell) canBuild(cell)->ok,why owned()->number|nil take()->bool give()
--      place(cell)->ok,why wait(s) progress(job) log(text)
-- cfg: perBatch (blocks between pauses), batchDelay (seconds), maxFails
-- Returns  "done"
--          "stopped"
--          "paused", code, extra     code = "noblocks" | "failed" | "denied" | "gaps"
function BuildJob.run(job, env, cfg)
	cfg = cfg or {}
	local perBatch, batchDelay, maxFails = cfg.perBatch or 3, cfg.batchDelay or 0.1, cfg.maxFails or 3
	if not BuildJob.plan(job, env) then
		return "stopped"
	end
	env.progress(job)

	local round = 0
	while true do
		round = round + 1
		local todo = job.todo
		local denied, deniedWhy = {}, nil
		local sinceWait = 0
		local deferred, failWhy = {}, nil
		for attempt = 1, 2 do
			deferred = {}
			local fails = 0
			for _, cell in ipairs(todo) do
				if env.stopped() then
					return "stopped"
				end
				if job.placed >= job.total then
					break -- complete: never place one more than this job needs
				end
				local k = key(cell)
				if job.placedSet[k] then
					-- this job already filled it: never place here again
				elseif env.isOccupied(cell) then
					job.total = job.total - 1 -- somebody / something filled it: skip it, never overwrite
				else
					local allowed, why = env.canBuild(cell)
					if not allowed then
						if attempt == 1 then
							denied[#denied + 1] = cell
						end
						deniedWhy = why
					else
						local owned = env.owned()
						if owned == nil or owned < 1 or not env.take() then
							return "paused", "noblocks", { remaining = job.total - job.placed }
						end
						local ok, placeWhy = env.place(cell)
						if ok then
							job.placed = job.placed + 1
							job.placedSet[k] = true
							fails = 0
							env.progress(job)
							sinceWait = sinceWait + 1
							if sinceWait >= perBatch then
								sinceWait = 0
								env.wait(batchDelay)
							end
						else
							env.give() -- the placement failed: the block goes back to the player
							deferred[#deferred + 1] = cell
							failWhy = placeWhy
							fails = fails + 1
							if fails >= maxFails then
								return "paused", "failed", { remaining = #deferred, why = failWhy }
							end
						end
					end
				end
			end
			todo = deferred
			if #deferred == 0 or job.placed >= job.total then
				deferred = {}
				break
			end
			env.wait(0.2)
		end
		if #deferred > 0 then
			return "paused", "failed", { remaining = #deferred, why = failWhy }
		end
		if #denied > 0 then
			return "paused", "denied", { remaining = #denied, why = deniedWhy }
		end
		-- "done" is only believed after a second look at the world: no empty cell may be left.
		if not BuildJob.plan(job, env) then
			return "stopped"
		end
		if #job.todo == 0 then
			env.progress(job)
			return "done"
		end
		if round >= 2 then
			return "paused", "gaps", { remaining = #job.todo }
		end
	end
end

return BuildJob
