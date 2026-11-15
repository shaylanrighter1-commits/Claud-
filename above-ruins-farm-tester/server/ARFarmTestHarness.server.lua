--[[
	ARFarmTestHarness  (Script — put in ServerScriptService next to the ARFarmTelemetry ModuleScript)

	Edit the three marked sections, then publish to your PRIVATE TEST place.
]]

local Telemetry = require(script.Parent:WaitForChild("ARFarmTelemetry"))

-- (1) Who may run the client tool -------------------------------------------------
Telemetry.start({
	TesterUserIds = {
		-- 123456789,
	},
	RequirePrivateServer = true,
})

-- (2) Tag resources so the client can find them ------------------------------------
-- Replace these paths with your real layout. Tag the Model (or BasePart) that the
-- player interacts with. Tag ONLY designated test NPCs for the NPC module.
--
-- Telemetry.tagChildren(workspace.Resources.Flowers, "Flowers")
-- Telemetry.tagChildren(workspace.Resources.Trees,   "Wood")
-- Telemetry.tagChildren(workspace.Resources.Ores,    "Mining")
-- Telemetry.tagChildren(workspace.TestNPCs,          "NPC", function(m) return m:FindFirstChildOfClass("Humanoid") ~= nil end)

-- (3) Report results from your EXISTING code — see INTEGRATION_EXAMPLES.lua ------
-- No remotes or grants are added here. Your current handlers keep doing validation;
-- they just also call Telemetry.action(...) and your anti-cheat calls Telemetry.detection(...).
