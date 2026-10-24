"""Runs the LedControl Lua tests under LuaJIT (via the "lupa" package): a syntax check of every app file, then each
tests/ledcontrol/test_*.lua in its own fresh Lua runtime.

    pip install lupa
    python tests/ledcontrol/run_tests.py            # all test files
    python tests/ledcontrol/run_tests.py scenarios  # only test_scenarios.lua
"""
import pathlib
import sys
import tempfile

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
APP = ROOT / "apps" / "lua" / "LedControl"
HERE = pathlib.Path(__file__).resolve().parent


def syntax_check(lua):
    bad = 0
    for path in sorted(APP.rglob("*.lua")):
        ok, err = lua.eval("function(p) local f, e = loadfile(p); return f ~= nil, e end")(str(path))
        if not ok:
            print(f"SYNTAX: {err}")
            bad += 1
    return bad


def main():
    only = sys.argv[1:]
    bad = syntax_check(luajit21.LuaRuntime(unpack_returned_tuples=True))
    failed = 0
    files = sorted(HERE.glob("test_*.lua"))
    if only:
        files = [f for f in files if any(o in f.stem for o in only)]
    for test in files:
        lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        with tempfile.TemporaryDirectory() as tmp:
            run = lua.eval("function(path, app, tmp, mock, helpers) return assert(loadfile(path))(app, tmp, mock, helpers) end")
            try:
                failed += run(str(test), str(APP), tmp, str(HERE / "mock_csp.lua"), str(HERE / "helpers.lua")) or 0
            except Exception as e:  # a Lua error inside a test file
                print(f"ERROR in {test.name}: {e}")
                failed += 1
    sys.exit(1 if (bad or failed) else 0)


if __name__ == "__main__":
    main()
