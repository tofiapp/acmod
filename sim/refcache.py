"""Fills the oracle / zero-throttle reference caches (sim/out/refcache-<set>-r<RISE>-f<FALL>.lua) in parallel, one
process per scenario x car; only entries that are missing or stale (scenario edited, no pulse fields) are computed.

    python sim/refcache.py [tuning|hidden|both] [rise] [fall]      (default: both 1.2 4)
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
    set_, name, rise, fall = args
    L = lua()
    f = L.eval("""function(root, set, name, rise, fall)
      local e = require('evaluate')
      local scns, cars = e.load(root, set)
      local cache, dirty = e.references(root, set, scns, cars, e.SCALES, rise, fall, name, false)
      if not dirty then return '' end
      local part = {}
      for k, v in pairs(cache) do if k:sub(1, #name + 1) == name .. '|' then part[k] = v end end
      return e.serialize(part)
    end""")
    return f(R, set_, name, rise, fall)


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    rise = float(sys.argv[2]) if len(sys.argv) > 2 else 1.2
    fall = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0
    sets = ("tuning", "hidden") if which == "both" else (which,)
    L = lua()
    names = {s: list(L.eval("function(root, set) local e = require('evaluate'); local a, b = e.load(root, set); "
                            "local n = {}; for _, s in ipairs(a) do for _, c in ipairs(b) do "
                            "n[#n + 1] = s.name .. '|' .. c.name end end; return n end")(R, s).values())
             for s in sets}
    jobs = [(s, n, rise, fall) for s in sets for n in names[s]]
    with mp.Pool(4) as pool:
        parts = pool.map(job, jobs, chunksize=1)
    merge = L.eval("""function(root, set, rise, fall, parts)
      local e = require('evaluate')
      local path = e.refPath(root, set, rise, fall)
      local ok, cache = pcall(dofile, path)
      if not ok or type(cache) ~= 'table' then cache = {} end
      local n = 0
      for _, src in ipairs(parts) do
        if src ~= '' then
          for k, v in pairs(assert(loadstring(src))()) do cache[k] = v; n = n + 1 end
        end
      end
      if n > 0 then local f = assert(io.open(path, 'w')); f:write(e.serialize(cache)); f:close() end
      return n
    end""")
    for s in sets:
        got = [p for (js, _, _, _), p in zip(jobs, parts) if js == s]
        n = merge(R, s, rise, fall, L.table_from(got))
        print("%s: %d reference entries updated" % (s, n))


if __name__ == "__main__":
    main()
