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


def api_names_check():
    """Every CSP API name the app uses must be in sdk_signatures.txt (looked up in the SDK / official code with
    tools/sdk_signatures.py), so a new call cannot slip in unverified."""
    sys.path.insert(0, str(HERE / "tools"))
    import sdk_signatures
    listed = set()
    for row in (HERE / "sdk_signatures.txt").read_text(encoding="utf-8").splitlines():
        if row and not row.startswith("#"):
            name, _, where = row.partition(" | ")
            if not where.startswith("NOT FOUND"):
                listed.add(name)
    names, methods = sdk_signatures.used_names()
    app_methods = sdk_signatures.app_defined_methods()
    missing = [n for n in names if n not in listed] + [":" + m for m in methods
                                                      if m not in app_methods and ":" + m not in listed]
    for n in missing:
        print(f"API: {n} is used but not verified in sdk_signatures.txt (run tests/ledcontrol/tools/sdk_signatures.py)")
    return len(missing)


def main():
    only = sys.argv[1:]
    bad = syntax_check(luajit21.LuaRuntime(unpack_returned_tuples=True))
    bad += api_names_check()
    failed = 0
    passed = 0
    files = sorted(HERE.glob("test_*.lua"))
    if only:
        files = [f for f in files if any(o in f.stem for o in only)]
    for test in files:
        lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        with tempfile.TemporaryDirectory() as tmp:
            run = lua.eval("function(path, app, tmp, mock, helpers) return assert(loadfile(path))(app, tmp, mock, helpers) end")
            try:
                failed += run(str(test), str(APP), tmp, str(HERE / "mock_csp.lua"), str(HERE / "helpers.lua")) or 0
                passed += lua.globals().LC_PASSED or 0
            except Exception as e:  # a Lua error inside a test file
                print(f"ERROR in {test.name}: {e}")
                failed += 1
    print(f"LedControl: {len(files)} files, {passed} checks passed, {failed} failed, {bad} syntax / API name errors")
    # PNG previews of the display pages recorded by test_display.lua
    import subprocess
    subprocess.run([sys.executable, "-I", str(HERE / "tools" / "render_display.py")], check=False)
    sys.exit(1 if (bad or failed) else 0)


if __name__ == "__main__":
    main()
