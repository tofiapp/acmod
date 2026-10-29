"""Calibration of the simulator against the user's logs (sensor noise, low-gear throttle pulsing); see calibrate.lua.

    python sim/calibrate.py [noise|pulse|all] [seeds]      (default: all 4; jobs run in parallel, ~15 s on 4 cores)
Writes sim/out/calibration.txt.
"""
import multiprocessing as mp
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
R = str(ROOT).replace("\\", "/")


def lib():
    from lupa import luajit21
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    return lua, lua.eval("function(p, ...) return assert(loadfile(p))(...) end")(R + "/sim/calibrate.lua", R, "lib")


def job(args):
    spec, seeds = args
    lua, cal = lib()
    return cal.runJob(lua.table_from(spec), seeds)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    seeds = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    (ROOT / "sim" / "out").mkdir(exist_ok=True)
    lua, cal = lib()
    specs = [dict(j.items()) for j in cal.jobs(mode).values()]
    with mp.Pool(min(4, len(specs))) as pool:
        results = pool.map(job, [(s, seeds) for s in specs])
    cal.report(lua.table_from(results), seeds)


if __name__ == "__main__":
    main()
