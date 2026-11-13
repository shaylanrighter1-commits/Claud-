--!nonstrict
--[[
	ABOVE[RUINS] | AUTO BUILDER — shared configuration.

	Lives in ReplicatedStorage/AutoBuilder/Config so the server and the client read
	the same values. Everything marked "SERVER-ENFORCED" is re-checked by the server
	no matter what the client sends, so editing it on a client does nothing.
]]

local Config = {}

Config.TITLE = "ABOVE[RUINS] | AUTO BUILDER"
Config.REMOTES_FOLDER = "AutoBuilderRemotes"

----------------------------------------------------------------------------------
-- Build limits (SERVER-ENFORCED)
----------------------------------------------------------------------------------
Config.MAX_BLOCKS_PER_JOB = 20000 -- most blocks a single build may contain
Config.MAX_DIMENSION = 128 -- longest allowed side (in blocks) on X or Z
Config.MAX_HEIGHT = 64 -- tallest build (layers)
Config.MAX_THICKNESS = 16 -- thickest floor / wall (blocks)

----------------------------------------------------------------------------------
-- Construction speed (blocks placed per second)
----------------------------------------------------------------------------------
Config.DEFAULT_SPEED = 12 -- used when the player has not picked a preset
Config.MIN_SPEED = 1 -- SERVER-ENFORCED clamp
Config.MAX_SPEED = 60 -- SERVER-ENFORCED clamp
Config.MAX_PLACEMENTS_PER_FRAME = 10 -- hard cap so one lag spike cannot dump a huge batch
Config.SPEED_PRESETS = {
	{ label = "SLOW", blocksPerSecond = 5 },
	{ label = "NORMAL", blocksPerSecond = 12 },
	{ label = "FAST", blocksPerSecond = 30 },
	{ label = "TURBO", blocksPerSecond = 60 },
}

----------------------------------------------------------------------------------
-- World limits (SERVER-ENFORCED) — nothing may be built outside these, in studs
----------------------------------------------------------------------------------
Config.WORLD_MAX_ABS_STUDS = 8000 -- |X| and |Z| limit
Config.WORLD_MAX_Y_STUDS = 4000 -- highest allowed Y (lowest is workspace.FallenPartsDestroyHeight + 8)

----------------------------------------------------------------------------------
-- Selection behaviour
----------------------------------------------------------------------------------
-- true : clicking a block selects the EMPTY cell next to the face you clicked
--        (same as placing a block there). Clicking the ground selects the layer above it.
-- false: clicking a block selects that block's own cell.
Config.SELECT_ADJACENT_CELL = true
Config.TOGGLE_KEY = Enum.KeyCode.B -- PC shortcut that opens/closes the menu (set to nil to disable)

----------------------------------------------------------------------------------
-- Network cadence
----------------------------------------------------------------------------------
Config.INVENTORY_POLL_SECONDS = 0.5 -- how often the server checks for inventory changes
Config.JOB_UPDATE_INTERVAL = 0.1 -- max progress updates per second per build = 1 / this

----------------------------------------------------------------------------------
-- Build modes
----------------------------------------------------------------------------------
Config.MODE_ORDER = { "floor", "wall", "fill", "hollow" }
Config.MODE_LABELS = {
	floor = "FLOOR",
	wall = "WALL",
	fill = "FILL",
	hollow = "HOLLOW BOX",
}
Config.MODE_NOUNS = { -- used for "Building: Grass Floor"
	floor = "Floor",
	wall = "Wall",
	fill = "Fill",
	hollow = "Hollow Box",
}
Config.MODE_HELP = {
	floor = "Fills the rectangle with a flat slab. Thickness = how many layers.",
	wall = "Builds a vertical wall. Straight = along the longer side from Point A; Surround = all four sides.",
	fill = "Fills the whole volume solid. Click two points at different heights, or set the Height.",
	hollow = "Builds the outer walls, floor and ceiling and leaves the inside empty.",
}

----------------------------------------------------------------------------------
-- Theme (dark gray / black with orange highlights)
----------------------------------------------------------------------------------
Config.Theme = {
	bg = Color3.fromRGB(16, 16, 18),
	panel = Color3.fromRGB(27, 27, 31),
	panelHi = Color3.fromRGB(38, 38, 44),
	line = Color3.fromRGB(58, 58, 66),
	orange = Color3.fromRGB(255, 140, 20),
	orangeDark = Color3.fromRGB(200, 100, 0),
	text = Color3.fromRGB(236, 236, 238),
	muted = Color3.fromRGB(150, 150, 158),
	dark = Color3.fromRGB(18, 14, 8), -- text on orange
	green = Color3.fromRGB(88, 214, 126),
	red = Color3.fromRGB(240, 82, 72),
	yellow = Color3.fromRGB(255, 205, 70),
	gray = Color3.fromRGB(120, 120, 128),
	font = Enum.Font.Gotham,
	fontBold = Enum.Font.GothamBold,
}

----------------------------------------------------------------------------------
-- Messages. `code` strings are what the server sends back; the text is shown to players.
----------------------------------------------------------------------------------
Config.Messages = {
	NO_PLOT = "You don't own any land to build on.",
	OUTSIDE_LAND = "The build area reaches outside your land.",
	OUTSIDE_WORLD = "The build area is outside the playable world.",
	TOO_LARGE = "That build is too large (limit: %d blocks, %d wide).",
	NOTHING_TO_BUILD = "Nothing to build — every block in this area is already filled.",
	BUSY = "A build is already in progress. Cancel it first.",
	NO_JOB = "There is no active build.",
	BAD_REQUEST = "That build request isn't valid.",
	RATE_LIMITED = "Slow down — too many requests.",
	NOT_ALLOWED = "Auto Builder isn't available right now.",
	NOT_ENOUGH_RESOURCES = "NOT ENOUGH RESOURCES",
	PLACE_FAILED = "Block placement kept failing, so the build was stopped.",
	LAND_CHANGED = "You no longer own this land, so the build was stopped.",
	SERVER_ERROR = "Something went wrong on the server. Please try again.",
	NETWORK = "Couldn't reach the server. Please try again.",
}

function Config.message(code, extra)
	local text = Config.Messages[code]
	if not text then
		return tostring(code or "Unknown error")
	end
	if code == "TOO_LARGE" then
		return string.format(text, Config.MAX_BLOCKS_PER_JOB, Config.MAX_DIMENSION)
	end
	return text
end

----------------------------------------------------------------------------------
-- Small shared text helpers
----------------------------------------------------------------------------------

-- "Grass Block" -> "Grass Blocks";  "Wood Planks" stays "Wood Planks"
function Config.plural(name)
	if string.sub(string.lower(name), -1) == "s" then
		return name
	end
	return name .. "s"
end

-- "Grass Block" + "floor" -> "Grass Floor";  "Wood Planks" + "wall" -> "Wood Planks Wall"
function Config.buildLabel(materialName, mode)
	local short = string.gsub(materialName, "%s+[Bb]locks?$", "")
	return short .. " " .. (Config.MODE_NOUNS[mode] or "Build")
end

-- "NOT ENOUGH RESOURCES — COLLECT 45 MORE GRASS BLOCKS"
function Config.missingMessage(missing, materialName)
	return string.format(
		"%s — COLLECT %d MORE %s",
		Config.Messages.NOT_ENOUGH_RESOURCES,
		missing,
		string.upper(Config.plural(materialName))
	)
end

return Config
