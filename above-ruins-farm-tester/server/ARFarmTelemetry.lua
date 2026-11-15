--!strict
--[[
	ARFarmTelemetry  (ModuleScript — put in ServerScriptService)

	Server half of the ABOVE[RUINS] farm-automation test tool.

	What it does:
	  * Exposes ReplicatedStorage.ARFarmTest (Handshake / Telemetry / Marker) ONLY in
	    Studio or private/reserved servers. Public servers never get the folder, so the
	    client tool refuses to farm there.
	  * Authorizes only UserIds listed in Config.TesterUserIds.
	  * Forwards *your* validation results (accepted / rejected + reason) and *your*
	    anti-cheat detections to that tester's client so the tool can correlate them.

	What it does NOT do:
	  * It never grants materials, never skips validation, never touches your anti-cheat.
	    It only observes what your existing code reports via Telemetry.action / .detection.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

export type Config = {
	TesterUserIds: { number },
	RequirePrivateServer: boolean,
	FolderName: string,
	Tags: { [string]: string },
	LogToOutput: boolean,
}

local Telemetry = {}

Telemetry.Config = {
	TesterUserIds = {},          -- e.g. { 123456789, 987654321 }
	RequirePrivateServer = true, -- true: only Studio / private / reserved servers
	FolderName = "ARFarmTest",
	Tags = {                     -- CollectionService tags the client searches for
		Flowers = "ARFarm_Flowers",
		NPC = "ARFarm_NPC",       -- tag designated TEST NPC Models only
		Wood = "ARFarm_Wood",
		Mining = "ARFarm_Mining",
	},
	LogToOutput = true,
} :: Config

-- Standard reject reasons the client understands (any other string is just logged).
Telemetry.Reasons = {
	OK = "OK",
	INVENTORY_FULL = "INVENTORY_FULL",
	DEPLETED = "DEPLETED",
	OUT_OF_RANGE = "OUT_OF_RANGE",
	COOLDOWN = "COOLDOWN",
	INVALID_TARGET = "INVALID_TARGET",
}

local MODULES = { Flowers = true, NPC = true, Wood = true, Mining = true }

local active = false
local folder: Folder? = nil
local telemetryRemote: RemoteEvent? = nil
local testerSet: { [number]: boolean } = {}
local stats: { [Player]: any } = {}
local markerBudget: { [Player]: { t: number, n: number } } = {}

local function log(fmt: string, ...: any)
	if Telemetry.Config.LogToOutput then
		print("[ARFarmTelemetry] " .. string.format(fmt, ...))
	end
end

local function environmentAllowed(): (boolean, string)
	if RunService:IsStudio() then
		return true, "studio"
	end
	if game.PrivateServerId ~= "" then
		return true, "private/reserved server"
	end
	if not Telemetry.Config.RequirePrivateServer then
		return true, "public server (RequirePrivateServer=false)"
	end
	return false, "public server"
end

function Telemetry.isTester(player: Player): boolean
	return active and testerSet[player.UserId] == true
end

local function statFor(player: Player)
	local s = stats[player]
	if not s then
		s = { actions = {}, detections = {} }
		stats[player] = s
	end
	return s
end

local function send(player: Player, msg: { [string]: any })
	if telemetryRemote then
		msg.serverTime = workspace:GetServerTimeNow()
		telemetryRemote:FireClient(player, msg)
	end
end

--[[ Call from your EXISTING resource / combat handlers after your validation runs.
	module   : "Flowers" | "NPC" | "Wood" | "Mining"
	accepted : true if your server granted the action
	reason   : nil/"OK" when accepted, otherwise e.g. Telemetry.Reasons.COOLDOWN
	target   : the resource Model/Part (or NPC Model) the action was for (optional but
	           strongly recommended — the client uses it to match attempts to results) ]]
function Telemetry.action(player: Player, module: string, accepted: boolean, reason: string?, target: Instance?)
	if not Telemetry.isTester(player) then
		return
	end
	if not MODULES[module] then
		warn("[ARFarmTelemetry] unknown module '" .. tostring(module) .. "' (use Flowers/NPC/Wood/Mining)")
		return
	end
	local r = reason or (accepted and "OK" or "REJECTED")
	local s = statFor(player).actions
	local key = module .. (accepted and ":ACCEPTED" or (":REJECTED:" .. r))
	s[key] = (s[key] or 0) + 1
	log("%s %s %s (%s) target=%s", player.Name, module, accepted and "ACCEPTED" or "REJECTED", r,
		target and target:GetFullName() or "?")
	send(player, { type = "action", module = module, accepted = accepted, reason = r, target = target })
end

--[[ Call from your anti-cheat wherever it flags a player (keep your normal handling too). ]]
function Telemetry.detection(player: Player, detector: string, details: string?)
	if not Telemetry.isTester(player) then
		return
	end
	local s = statFor(player).detections
	s[detector] = (s[detector] or 0) + 1
	log("%s DETECTED by %s: %s", player.Name, detector, tostring(details))
	send(player, { type = "detection", detector = detector, details = details })
end

-- Tag helpers so the client finds resources through authorized game data.
function Telemetry.tag(inst: Instance, module: string)
	local tag = Telemetry.Config.Tags[module]
	assert(tag, "unknown module " .. tostring(module))
	CollectionService:AddTag(inst, tag)
end

function Telemetry.untag(inst: Instance, module: string)
	local tag = Telemetry.Config.Tags[module]
	if tag then
		CollectionService:RemoveTag(inst, tag)
	end
end

-- Tags each direct child of `container` (optionally filtered) and keeps tagging new children.
function Telemetry.tagChildren(container: Instance, module: string, predicate: ((Instance) -> boolean)?)
	local function consider(child: Instance)
		if predicate == nil or predicate(child) then
			Telemetry.tag(child, module)
		end
	end
	for _, child in ipairs(container:GetChildren()) do
		consider(child)
	end
	container.ChildAdded:Connect(consider)
end

function Telemetry.summary(player: Player): string
	local s = stats[player]
	if not s then
		return "no data"
	end
	local lines = { "Summary for " .. player.Name }
	for k, v in pairs(s.actions) do
		table.insert(lines, string.format("  action %-28s %d", k, v))
	end
	for k, v in pairs(s.detections) do
		table.insert(lines, string.format("  detect %-28s %d", k, v))
	end
	return table.concat(lines, "\n")
end

function Telemetry.start(overrides: { [string]: any }?)
	if active then
		return
	end
	if overrides then
		for k, v in pairs(overrides) do
			(Telemetry.Config :: any)[k] = v
		end
	end
	for _, id in ipairs(Telemetry.Config.TesterUserIds) do
		testerSet[id] = true
	end

	local ok, why = environmentAllowed()
	if not ok then
		log("inactive (%s). Client tool will report 'harness not found'.", why)
		return
	end
	if next(testerSet) == nil then
		warn("[ARFarmTelemetry] TesterUserIds is empty — nobody will be authorized.")
	end
	active = true

	local f = Instance.new("Folder")
	f.Name = Telemetry.Config.FolderName

	local handshake = Instance.new("RemoteFunction")
	handshake.Name = "Handshake"
	handshake.Parent = f

	local tel = Instance.new("RemoteEvent")
	tel.Name = "Telemetry"
	tel.Parent = f

	local marker = Instance.new("RemoteEvent")
	marker.Name = "Marker"
	marker.Parent = f

	handshake.OnServerInvoke = function(player: Player, info: any)
		if not testerSet[player.UserId] then
			log("handshake refused for %s (%d): not in TesterUserIds", player.Name, player.UserId)
			return { authorized = false, reason = "UserId " .. player.UserId .. " not in TesterUserIds" }
		end
		local exec = type(info) == "table" and tostring(info.executor) or "?"
		log("handshake OK for %s (client executor: %s)", player.Name, exec)
		return { authorized = true, tags = Telemetry.Config.Tags, environment = why }
	end

	-- Client scenario markers (start/stop/scenario switch) so server logs line up with client logs.
	marker.OnServerEvent:Connect(function(player: Player, payload: any)
		if not testerSet[player.UserId] or type(payload) ~= "table" then
			return
		end
		local now = os.clock()
		local b = markerBudget[player]
		if not b or now - b.t > 1 then
			b = { t = now, n = 0 }
			markerBudget[player] = b
		end
		b.n += 1
		if b.n > 20 then
			return
		end
		log("MARK %s event=%s scenario=%s module=%s", player.Name, tostring(payload.event),
			tostring(payload.scenario), tostring(payload.module))
	end)

	Players.PlayerRemoving:Connect(function(player)
		if stats[player] then
			log("%s", Telemetry.summary(player))
		end
		stats[player] = nil
		markerBudget[player] = nil
	end)

	telemetryRemote = tel
	folder = f
	f.Parent = ReplicatedStorage
	log("active (%s). Testers: %d", why, #Telemetry.Config.TesterUserIds)
end

return Telemetry
