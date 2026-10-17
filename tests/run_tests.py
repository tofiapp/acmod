"""Runs the MirrorDelta Lua tests under LuaJIT (via the "lupa" package).

    pip install lupa
    python tests/run_tests.py
"""
import pathlib
import sys
import tempfile

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "lua" / "MirrorDelta"


def syntax_check(lua):
    bad = 0
    for path in sorted(APP.rglob("*.lua")):
        ok, err = lua.eval("function(p) local f, e = loadfile(p); return f ~= nil, e end")(str(path))
        if not ok:
            print(f"SYNTAX: {err}")
            bad += 1
    return bad


def main():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    bad = syntax_check(lua)
    with tempfile.TemporaryDirectory() as tmp:
        run = lua.eval("function(path, app, tmp) return assert(loadfile(path))(app, tmp) end")
        failed = run(str(ROOT / "tests" / "test_app.lua"), str(APP), tmp)
    sys.exit(1 if (bad or failed) else 0)


if __name__ == "__main__":
    main()
