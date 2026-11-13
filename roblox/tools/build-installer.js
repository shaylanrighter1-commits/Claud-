#!/usr/bin/env node
/*
 * Builds roblox/Install_AutoBuilder.lua — ONE file you paste into Roblox Studio's
 * Command Bar to create every script in the right place.
 *
 *   node roblox/tools/build-installer.js
 *
 * File naming (same convention Rojo uses):
 *   Name.server.lua  -> Script
 *   Name.client.lua  -> LocalScript
 *   Name.lua         -> ModuleScript
 */
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const srcDir = path.join(root, "src");
const outFile = path.join(root, "Install_AutoBuilder.lua");

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
  return out.sort();
}

const files = walk(srcDir).map((full) => {
  const parts = path.relative(srcDir, full).split(path.sep);
  const fileName = parts.pop();
  let name = fileName.replace(/\.lua$/, "");
  let className = "ModuleScript";
  if (name.endsWith(".server")) {
    className = "Script";
    name = name.slice(0, -".server".length);
  } else if (name.endsWith(".client")) {
    className = "LocalScript";
    name = name.slice(0, -".client".length);
  }
  return { parts, name, className, source: fs.readFileSync(full, "utf8").replace(/\r\n/g, "\n") };
});

// Pick a long-bracket level that never appears inside any source file.
let level = 2;
const clash = (n) => files.some((f) => f.source.includes("]" + "=".repeat(n) + "]"));
while (clash(level)) level++;
const open = "[" + "=".repeat(level) + "[";
const close = "]" + "=".repeat(level) + "]";

const entries = files
  .map(
    (f) =>
      `\t{\n\t\tpath = { ${f.parts.map((p) => JSON.stringify(p)).join(", ")} },\n` +
      `\t\tname = ${JSON.stringify(f.name)},\n\t\tclass = ${JSON.stringify(f.className)},\n` +
      `\t\tsource = ${open}\n${f.source}${close},\n\t},`
  )
  .join("\n");

const installer = `--[[
	ABOVE[RUINS] | AUTO BUILDER — one-paste installer

	HOW TO USE
	  1. Open (or create) your place in Roblox Studio.
	  2. View tab -> turn on "Command Bar" (a text box appears at the bottom).
	  3. Copy this ENTIRE file, paste it into the Command Bar, press Enter.
	  4. Press Play (F5) and follow the README testing steps.

	It creates:
	  ReplicatedStorage/AutoBuilder/            Config, BuildPlanner
	  ServerScriptService/AutoBuilder/          AutoBuilderServer, StandaloneBackend
	  StarterPlayer/StarterPlayerScripts/AutoBuilderClient/   Main, UI, Preview

	Running it again replaces those scripts with fresh copies (any edits you made to them are overwritten).
]]

local FILES = {
${entries}
}

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local function childNamed(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local created = 0
for _, file in ipairs(FILES) do
	local parent = game:GetService(file.path[1])
	for i = 2, #file.path do
		parent = childNamed(parent, file.path[i])
	end
	local old = parent:FindFirstChild(file.name)
	if old then
		old:Destroy()
	end
	local script = Instance.new(file.class)
	script.Name = file.name
	script.Source = file.source
	script.Parent = parent
	created += 1
end

pcall(function()
	ChangeHistoryService:SetWaypoint("Install Auto Builder")
end)
print(string.format("[AutoBuilder] Installed %d scripts. Press Play to test.", created))
`;

fs.writeFileSync(outFile, installer);
console.log(
  `Wrote ${path.relative(process.cwd(), outFile)}: ${files.length} scripts, ` +
    `${(Buffer.byteLength(installer) / 1024).toFixed(1)} KB, long-bracket level ${level}`
);
