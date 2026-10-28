"""Prints a plain text picture of LedControl's window per tab (design review aid).

    python3 tests/ledcontrol/dump_ui.py                 # all tabs
    python3 tests/ledcontrol/dump_ui.py Diody Scénáře   # some tabs
"""
import pathlib
import sys
import tempfile

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
APP = ROOT / "apps" / "lua" / "LedControl"
HERE = pathlib.Path(__file__).resolve().parent
TABS = ["Diody", "Otáčky", "Scénáře", "Editor", "Světla", "Nastavení"]

tabs = sys.argv[1:] or TABS
lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
with tempfile.TemporaryDirectory() as tmp:
    run = lua.eval("function(path, app, tmp, mock, helpers, tabs) return assert(loadfile(path))(app, tmp, mock, helpers, tabs) end")
    run(str(HERE / "ui_dump.lua"), str(APP), tmp, str(HERE / "mock_csp.lua"), str(HERE / "helpers.lua"), ",".join(tabs))
