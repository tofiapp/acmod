"""Tests for tools/ac-bridge/ac_export.py that run without AC (struct layout, write guard, CSV content)."""
import ctypes
import importlib.util
import pathlib
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def load():
    spec = importlib.util.spec_from_file_location("ac_export", ROOT / "tools" / "ac-bridge" / "ac_export.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run():
    m = load()
    failed = 0

    def check(name, cond):
        nonlocal failed
        if not cond:
            failed += 1
            print("FAIL: " + name)

    # offsets from Content Manager's AcSharedGraphics (Pack = 4, wide strings)
    check("graphics completedLaps offset", m.Graphics.completedLaps.offset == 132)
    check("graphics tyreCompound offset", m.Graphics.tyreCompound.offset == 176)
    check("graphics normalizedCarPosition offset", m.Graphics.normalizedCarPosition.offset == 248)
    check("physics wheelSlip offset", m.Physics.wheelSlip.offset == 56)
    check("physics localVelocity is last", m.Physics.localVelocity.offset + 12 == ctypes.sizeof(m.Physics))
    with tempfile.TemporaryDirectory() as d:
        m.LOG_DIR = pathlib.Path(d) / "logs"
        p = m._write([[0.0] * len(m.COLUMNS)], "x.csv")
        check("csv written inside the logs folder", pathlib.Path(p).parent == m.LOG_DIR.resolve())
        check("csv header", open(p).readline().startswith("t,packet,lap"))
        for bad in ("../escape.csv", "sub/x.csv", str(pathlib.Path(d) / "outside.csv")):
            try:
                m._safe_path(bad)
                check("refuses " + bad, False)
            except ValueError:
                pass
        check("nothing written outside", sorted(x.name for x in pathlib.Path(d).iterdir()) == ["logs"])
        # export with fake rows: last N seconds and last lap
        m._sampler.rows.clear()
        for i in range(600):
            row = [i / 60, i, 3 if i < 300 else 4] + [0] * (len(m.COLUMNS) - 3)
            m._sampler.rows.append(row)
        m._sampler.start = lambda: None
        p2 = m.export_last_seconds(2)
        check("last seconds rows", len(open(p2).read().strip().splitlines()) == 1 + 121)
        p3 = m.export_last_lap()
        check("last lap rows", len(open(p3).read().strip().splitlines()) == 1 + 300)
    print("bridge export: %s" % ("ok" if failed == 0 else "%d failed" % failed))
    return failed


if __name__ == "__main__":
    raise SystemExit(1 if run() else 0)
