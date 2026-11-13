#!/usr/bin/env node
// Builds Install_AutoBuilder.lua: ONE script you paste into Roblox Studio's Command Bar to create all the
// scripts in the right places. Usage:  node roblox/server_version/tools/build-installer.js
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const files = [
  { parent: "RS", class: "ModuleScript", name: "Shared", file: "src/ReplicatedStorage/AutoBuilder/Shared.lua" },
  { parent: "SSS", class: "ModuleScript", name: "BuildJob", file: "src/ServerScriptService/AutoBuilder/BuildJob.lua" },
  { parent: "SSS", class: "ModuleScript", name: "Backend", file: "src/ServerScriptService/AutoBuilder/Backend.lua" },
  { parent: "SSS", class: "Script", name: "AutoBuilderServer", file: "src/ServerScriptService/AutoBuilder/AutoBuilderServer.server.lua" },
  { parent: "SPS", class: "LocalScript", name: "AutoBuilderClient", file: "src/StarterPlayer/StarterPlayerScripts/AutoBuilderClient.client.lua" },
];

let out = `-- ABOVE[RUINS] | AUTO BUILDER (server-authorized) - one-paste installer
-- 1. In Roblox Studio open your place (a Baseplate is fine).   2. View > Command Bar.
-- 3. Paste this ENTIRE file into the Command Bar and press Enter.   4. Press Play.
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SPS = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")

local function folder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end
local rsFolder, sssFolder = folder(RS, "AutoBuilder"), folder(SSS, "AutoBuilder")
local parents = { RS = rsFolder, SSS = sssFolder, SPS = SPS }

local function put(where, class, name, source)
	local parent = parents[where]
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local obj = Instance.new(class)
	obj.Name = name
	obj.Source = source
	obj.Parent = parent
end

`;
for (const f of files) {
  const src = fs.readFileSync(path.join(root, f.file), "utf8").replace(/\r\n/g, "\n");
  if (src.includes("]==]")) throw new Error(f.file + " contains ]==]");
  out += `put("${f.parent}", "${f.class}", "${f.name}", [==[\n${src}]==])\n\n`;
}
out += `print("[AutoBuilder] Installed ${files.length} scripts. Press Play, then use the menu on the right.")\n`;
fs.writeFileSync(path.join(root, "Install_AutoBuilder.lua"), out);
console.log("wrote Install_AutoBuilder.lua (" + out.split("\n").length + " lines)");
