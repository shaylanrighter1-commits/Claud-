#!/usr/bin/env python3
"""Runs the unit tests for the pure CORE block of AutoBuilder_MacSploit.lua.

    pip install lupa
    python3 roblox/tests/run_core_tests.py [path/to/AutoBuilder_MacSploit.lua]

The Lua between `-- CORE-BEGIN` and `-- CORE-END` is extracted from the real script (so the code under test is
the code that ships) and run against tests/core_tests.lua in a Lua runtime. This tests the DECISION LOGIC only.
It does not test Roblox itself (raycasts, mouse, hotbar GUI, the game's own placement rules).
"""
import os
import re
import sys

from lupa import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
script = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "AutoBuilder_MacSploit.lua")

source = open(script, encoding="utf-8").read()
match = re.search(r"-- CORE-BEGIN\n(.*?)-- CORE-END", source, re.S)
if not match:
    sys.exit("CORE-BEGIN / CORE-END markers not found in " + script)

lua = LuaRuntime(unpack_returned_tuples=True)
print("Lua runtime:", lua.eval("_VERSION"), "| core block: %d lines" % match.group(1).count("\n"))
lua.globals().Core = lua.execute(match.group(1) + "\nreturn Core")
lua.execute(open(os.path.join(here, "core_tests.lua"), encoding="utf-8").read())
failures = lua.globals().__failures
sys.exit(1 if failures else 0)
