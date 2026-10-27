"""KeyDrive simulator runner (LuaJIT through the "lupa" package; on Windows: py -m pip install lupa).

    python sim/run.py                      # tuning scenarios, both controller rates
    python sim/run.py --set hidden         # hidden scenarios (never used for tuning)
    python sim/run.py --scale 0.8,1.2      # grip x0.8, power x1.2
    python sim/run.py --params p.lua       # Lua file returning { throttle = {...}, traction = {...} }
Writes sim/out/report*.json and sim/out/summary*.txt.
"""
import argparse
import pathlib
import sys

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="tuning")
    ap.add_argument("--rates", default="physics,fps")
    ap.add_argument("--scale", default="")
    ap.add_argument("--params", default="")
    a = ap.parse_args()
    (ROOT / "sim" / "out").mkdir(exist_ok=True)
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    run = lua.eval("function(p, ...) return assert(loadfile(p))(...) end")
    params = str(pathlib.Path(a.params).resolve()) if a.params else ""
    passed, total = run(str(ROOT / "sim" / "main.lua"), str(ROOT).replace("\\", "/"), a.set, a.rates, a.scale, params)
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
