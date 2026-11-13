#!/usr/bin/env python3
"""Unit tests for the server version's pure modules (Shared.lua, BuildJob.lua).

    pip install lupa
    python3 roblox/server_version/tests/run_tests.py
"""
import os
import sys

from lupa import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "src")
lua = LuaRuntime(unpack_returned_tuples=True)
print("Lua runtime:", lua.eval("_VERSION"))


def load(path):
    return lua.execute(open(path, encoding="utf-8").read())


lua.globals().Shared = load(os.path.join(src, "ReplicatedStorage", "AutoBuilder", "Shared.lua"))
lua.globals().BuildJob = load(os.path.join(src, "ServerScriptService", "AutoBuilder", "BuildJob.lua"))
if len(sys.argv) > 1:  # (used by the mutation checks)
    lua.globals().BuildJob = load(sys.argv[1])
lua.execute(open(os.path.join(here, "job_tests.lua"), encoding="utf-8").read())
failed = lua.globals().__failures

# the real server script, run against a simulated Roblox
lua.globals().SharedModule = lua.globals().Shared
lua.globals().BuildJobModule = lua.globals().BuildJob
lua.globals().SERVER_SRC = open(os.path.join(src, "ServerScriptService", "AutoBuilder", "AutoBuilderServer.server.lua"), encoding="utf-8").read()
lua.execute(open(os.path.join(here, "server_tests.lua"), encoding="utf-8").read())
failed += lua.globals().__failures
sys.exit(1 if failed else 0)
