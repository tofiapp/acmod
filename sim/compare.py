"""Compares parameter sets on the tuning and hidden sets (all grip/power shifts, physics and fps rates).

    python sim/compare.py default sim/out/cand-a.lua ...      ("default" = the core's own defaults)
Prints pass counts per set/rate; the hidden set is only ever used here, for the final check.
"""
import multiprocessing as mp
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
R = str(ROOT).replace("\\", "/")


def lua():
    from lupa import luajit21
    L = luajit21.LuaRuntime(unpack_returned_tuples=True)
    L.execute("package.path = '%s/sim/?.lua;%s/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path" % (R, R))
    return L


def job(args):
    name, set_, rate = args
    L = lua()
    f = L.eval("""function(root, file, set, rate)
      local e = require('evaluate')
      local p = file == 'default' and { throttle = {}, traction = {} } or dofile(file)
      local cost, passed, runs, fails = e.evaluate(root, set, p, { rates = { rate } })
      local fk = {}
      for k, n in pairs(fails) do fk[#fk + 1] = k .. ' ' .. n end
      table.sort(fk)
      return string.format('%.3f', cost), passed, runs, table.concat(fk, ', ')
    end""")
    cost, passed, runs, fails = f(R, name, set_, rate)
    return name, set_, rate, cost, passed, runs, fails


def main():
    names = sys.argv[1:] or ["default"]
    # references first, single process, per set
    L = lua()
    for s in ("tuning", "hidden"):
        L.eval("function(root, set) local e = require('evaluate'); local a, b = e.load(root, set); "
               "e.references(root, set, a, b, e.SCALES, 1.2, 4) end")(R, s)
    jobs = [(n, s, r) for n in names for s in ("tuning", "hidden") for r in ("physics", "fps")]
    with mp.Pool(4) as pool:
        for res in sorted(pool.map(job, jobs)):
            print("%-28s %-7s %-7s cost %s  %3d/%3d pass  [%s]" % res)


if __name__ == "__main__":
    main()
