#!/usr/bin/env python3
"""Integration tests: runs the REAL AutoBuilder_MacSploit.lua (placeCell, runJob, autoBuild, stop...) against a
simulated world with fake Roblox objects.

    pip install lupa
    python3 roblox/tests/run_glue_tests.py [path/to/AutoBuilder_MacSploit.lua]

The script is loaded unchanged except that the Luau-only compound assignments (`x += 1`) are rewritten to plain
Lua, and a few lines are appended so the tests can replace the script's leaf functions (mouse, hotbar, raycasts)
with simulated ones. This tests the script's DECISIONS and WIRING. It cannot test Roblox itself or the real game.
"""
import os
import re
import sys

from lupa import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
script = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "AutoBuilder_MacSploit.lua")
source = open(script, encoding="utf-8").read()


def compound(m):
    rhs, comment = m.group(4), ""
    if " --" in rhs:
        i = rhs.index(" --")
        rhs, comment = rhs[:i], rhs[i:]
    return f"{m.group(1)}{m.group(2)} = {m.group(2)} {m.group(3)} ({rhs.strip()}){comment}"


source = re.sub(r"^(\s*)([A-Za-z_][\w\.\[\]\"']*)\s*([\+\-\*/])=\s*(.+)$", compound, source, flags=re.M)

# the locals the tests need to reach, and the ones they replace with simulated versions
SETTABLE = ["detectBlock", "ensureEquipped", "itemGone", "readOwned", "calibrateNear", "cellOccupied", "myParts", "UIS", "findAims"]
hooks = "genv.__T = { S = S, Watch = Watch, Input = Input, stop = stop, autoBuild = autoBuild, setSelection = setSelection,\n"
hooks += "\tset = function(name, value)\n"
for i, name in enumerate(SETTABLE):
    hooks += f"\t\t{'if' if i == 0 else 'elseif'} name == '{name}' then {name} = value\n"
hooks += "\t\telse error('unknown local ' .. tostring(name)) end\n\tend }\n"
hooks = "local genv = (getgenv and getgenv()) or _G\n" + hooks

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().SRC = source
lua.globals().HOOKS = hooks
print("Lua runtime:", lua.eval("_VERSION"))
lua.execute(open(os.path.join(here, "glue_tests.lua"), encoding="utf-8").read())
sys.exit(1 if lua.globals().__failures else 0)
