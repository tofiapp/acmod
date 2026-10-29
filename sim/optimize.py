"""Runs several optimizer processes in parallel (different seeds / controller modes) on the TUNING set.

    python sim/optimize.py --mode 2 --procs 4 --rand 30 --nm 60
Results: sim/out/opt-m<mode>-s<seed>.lua (best parameters) and .log
"""
import argparse
import multiprocessing as mp
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def worker(args):
    mode, seed, nrand, nnm, start, anchor = args
    from lupa import luajit21
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    run = lua.eval("function(p, ...) return assert(loadfile(p))(...) end")
    out = str(ROOT / "sim" / "out" / f"opt-m{mode}-s{seed}")
    run(str(ROOT / "sim" / "optimize.lua"), str(ROOT).replace("\\", "/"), str(mode), str(seed), str(nrand), str(nnm),
        out.replace("\\", "/"), start, anchor)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="2")
    ap.add_argument("--procs", type=int, default=4)
    ap.add_argument("--rand", type=int, default=30)
    ap.add_argument("--nm", type=int, default=60)
    ap.add_argument("--start", default="", help="start parameter file(s), comma separated: one per process")
    ap.add_argument("--seed0", type=int, default=1)
    ap.add_argument("--anchor", default="", help="anchor parameter file (evaluate.lua anchor mode)")
    a = ap.parse_args()
    (ROOT / "sim" / "out").mkdir(exist_ok=True)
    # references (oracle, zero throttle) are computed once here, then every worker reads the cache
    from lupa import luajit21
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = '%s/sim/?.lua;%s/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path"
                % (str(ROOT).replace("\\", "/"), str(ROOT).replace("\\", "/")))
    lua.eval("function(root) local e = require('evaluate'); local s, c = e.load(root, 'tuning'); "
             "e.references(root, 'tuning', s, c, e.SCALES, 1.2, 4) end")(str(ROOT).replace("\\", "/"))
    print("references ready")
    modes = [m.strip() for m in a.mode.split(",")]
    jobs = []
    starts = a.start.split(",") if a.start else [""]
    for i in range(a.procs):
        jobs.append((modes[i % len(modes)], a.seed0 + i, a.rand, a.nm, starts[i % len(starts)], a.anchor))
    with mp.Pool(a.procs) as pool:
        for out in pool.imap_unordered(worker, jobs):
            print("finished", out)


if __name__ == "__main__":
    main()
