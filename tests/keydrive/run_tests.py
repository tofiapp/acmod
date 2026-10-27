"""Runs the KeyDrive Lua tests under LuaJIT (via the "lupa" package).

    pip install lupa
    python tests/keydrive/run_tests.py
"""
import pathlib
import sys

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
CORE = ROOT / "extension" / "lua" / "joypad-assist" / "KeyDrive"
APP = ROOT / "apps" / "lua" / "KeyDriveConfig"
KBTEST = ROOT / "apps" / "lua" / "KeyDriveKeyboardTest"
HERE = pathlib.Path(__file__).resolve().parent


def syntax_check(lua):
    bad = 0
    for folder in (CORE, APP, KBTEST):
        if not folder.exists():
            continue
        for path in sorted(folder.rglob("*.lua")):
            ok, err = lua.eval("function(p) local f, e = loadfile(p); return f ~= nil, e end")(str(path))
            if not ok:
                print(f"SYNTAX: {err}")
                bad += 1
    return bad


def main():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    bad = syntax_check(lua)
    run = lua.eval("function(path, core, app, kbtest) return assert(loadfile(path))(path, core, app, kbtest) end")
    failed = run(str(HERE / "test_keydrive.lua"), str(CORE), str(APP), str(KBTEST))
    sys.exit(1 if (bad or failed) else 0)


if __name__ == "__main__":
    main()
