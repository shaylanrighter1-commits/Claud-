--[[
	INTEGRATION_EXAMPLES  — reference only, not meant to run as-is.

	Shows where to add ONE line to your existing server code. Function names below
	(validateHarvest, grantItem, inventoryFull, ...) are placeholders for YOUR code.
	Nothing here bypasses or replaces your validation.
]]

local Telemetry = require(game:GetService("ServerScriptService").ARFarmTelemetry)
local R = Telemetry.Reasons

---------------------------------------------------------------------------------
-- A) ProximityPrompt resource (flowers / ores / trees)
---------------------------------------------------------------------------------
local function hookPromptResource(resourceModel: Model, module: string)
	local prompt = resourceModel:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return
	end
	prompt.Triggered:Connect(function(player)
		-- your existing checks, in your order:
		if resourceModel:GetAttribute("Depleted") then
			Telemetry.action(player, module, false, R.DEPLETED, resourceModel)
			return
		end
		-- if not inRange(player, resourceModel)      then Telemetry.action(player, module, false, R.OUT_OF_RANGE, resourceModel) return end
		-- if onCooldown(player, module)              then Telemetry.action(player, module, false, R.COOLDOWN, resourceModel) return end
		-- if inventoryFull(player)                   then Telemetry.action(player, module, false, R.INVENTORY_FULL, resourceModel) return end
		-- grantItem(player, ...)
		Telemetry.action(player, module, true, nil, resourceModel)

		-- Depletion: the client skips targets that are untagged OR have Depleted=true
		-- OR whose prompt is disabled. Any one of these is enough:
		-- resourceModel:SetAttribute("Depleted", true); prompt.Enabled = false
		-- task.delay(RESPAWN, function() resourceModel:SetAttribute("Depleted", false); prompt.Enabled = true end)
	end)
end

---------------------------------------------------------------------------------
-- B) Remote-based harvesting / combat (e.g. a tool fires your own RemoteEvent)
---------------------------------------------------------------------------------
-- yourHitRemote.OnServerEvent:Connect(function(player, target)
-- 	local ok, reason = validateHit(player, target)    -- your existing validation
-- 	Telemetry.action(player, "Wood", ok, reason, target)
-- 	if ok then applyHit(player, target) end
-- end)
--
-- NPC damage — report on every validated/rejected hit against a tagged test NPC:
-- Telemetry.action(player, "NPC", ok, reason, npcModel)

---------------------------------------------------------------------------------
-- C) Anti-cheat — add one line wherever a detector fires (keep normal handling)
---------------------------------------------------------------------------------
-- local function onFlag(player, detectorName, details)
-- 	existingFlagHandler(player, detectorName, details)   -- unchanged: kick/ban/log as usual
-- 	Telemetry.detection(player, detectorName, details)   -- e.g. "SpeedCheck", "InteractRate", "PathLinearity"
-- end

return hookPromptResource
