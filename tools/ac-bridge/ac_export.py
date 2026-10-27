"""CSV export of Assetto Corsa telemetry for the user's MCP bridge (C:\\AC-Claude\\ac_telemetry_mcp.py).

Reads AC's shared memory (Local\\acpmf_physics, Local\\acpmf_graphics) READ-ONLY in a background thread (~60 Hz,
last 10 minutes kept in memory) and writes CSV files ONLY into C:\\AC-Claude\\logs: the folder is fixed, file names are
generated here, nothing else on the disk is touched (every path is resolved and checked to lie inside that folder).

Integration into the bridge (FastMCP server object called `mcp`):

    import ac_export
    ac_export.register(mcp)       # adds the tools export_last_seconds(seconds) and export_last_lap()

Stand-alone test (AC running):  py ac_export.py --seconds 30
Struct layouts follow Content Manager's AcSharedPhysics / AcSharedGraphics (Pack = 4, wide strings).
"""
import argparse
import collections
import csv
import ctypes
import datetime
import mmap
import os
import pathlib
import sys
import threading
import time

LOG_DIR = pathlib.Path(r"C:\AC-Claude\logs")
SAMPLE_HZ = 60
KEEP_SECONDS = 600


class Physics(ctypes.Structure):
    _pack_ = 4
    _fields_ = [
        ("packetId", ctypes.c_int), ("gas", ctypes.c_float), ("brake", ctypes.c_float), ("fuel", ctypes.c_float),
        ("gear", ctypes.c_int), ("rpms", ctypes.c_int), ("steerAngle", ctypes.c_float), ("speedKmh", ctypes.c_float),
        ("velocity", ctypes.c_float * 3), ("accG", ctypes.c_float * 3), ("wheelSlip", ctypes.c_float * 4),
        ("wheelLoad", ctypes.c_float * 4), ("wheelsPressure", ctypes.c_float * 4),
        ("wheelAngularSpeed", ctypes.c_float * 4), ("tyreWear", ctypes.c_float * 4),
        ("tyreDirtyLevel", ctypes.c_float * 4), ("tyreCoreTemperature", ctypes.c_float * 4),
        ("camberRAD", ctypes.c_float * 4), ("suspensionTravel", ctypes.c_float * 4), ("drs", ctypes.c_float),
        ("tc", ctypes.c_float), ("heading", ctypes.c_float), ("pitch", ctypes.c_float), ("roll", ctypes.c_float),
        ("cgHeight", ctypes.c_float), ("carDamage", ctypes.c_float * 5), ("numberOfTyresOut", ctypes.c_int),
        ("pitLimiterOn", ctypes.c_int), ("abs", ctypes.c_float), ("kersCharge", ctypes.c_float),
        ("kersInput", ctypes.c_float), ("autoShifterOn", ctypes.c_int), ("rideHeight", ctypes.c_float * 2),
        ("turboBoost", ctypes.c_float), ("ballast", ctypes.c_float), ("airDensity", ctypes.c_float),
        ("airTemp", ctypes.c_float), ("roadTemp", ctypes.c_float), ("localAngularVel", ctypes.c_float * 3),
        ("finalFF", ctypes.c_float), ("performanceMeter", ctypes.c_float), ("engineBrake", ctypes.c_int),
        ("ersRecoveryLevel", ctypes.c_int), ("ersPowerLevel", ctypes.c_int), ("ersHeatCharging", ctypes.c_int),
        ("ersIsCharging", ctypes.c_int), ("kersCurrentKJ", ctypes.c_float), ("drsAvailable", ctypes.c_int),
        ("drsEnabled", ctypes.c_int), ("brakeTemp", ctypes.c_float * 4), ("clutch", ctypes.c_float),
        ("tyreTempI", ctypes.c_float * 4), ("tyreTempM", ctypes.c_float * 4), ("tyreTempO", ctypes.c_float * 4),
        ("isAIControlled", ctypes.c_int), ("tyreContactPoint", ctypes.c_float * 12),
        ("tyreContactNormal", ctypes.c_float * 12), ("tyreContactHeading", ctypes.c_float * 12),
        ("brakeBias", ctypes.c_float), ("localVelocity", ctypes.c_float * 3),
    ]


class Graphics(ctypes.Structure):
    _pack_ = 4
    _fields_ = [
        ("packetId", ctypes.c_int), ("status", ctypes.c_int), ("session", ctypes.c_int),
        ("currentTime", ctypes.c_uint16 * 15), ("lastTime", ctypes.c_uint16 * 15), ("bestTime", ctypes.c_uint16 * 15),
        ("split", ctypes.c_uint16 * 15), ("completedLaps", ctypes.c_int), ("position", ctypes.c_int),
        ("iCurrentTime", ctypes.c_int), ("iLastTime", ctypes.c_int), ("iBestTime", ctypes.c_int),
        ("sessionTimeLeft", ctypes.c_float), ("distanceTraveled", ctypes.c_float), ("isInPit", ctypes.c_int),
        ("currentSectorIndex", ctypes.c_int), ("lastSectorTime", ctypes.c_int), ("numberOfLaps", ctypes.c_int),
        ("tyreCompound", ctypes.c_uint16 * 33), ("replayTimeMultiplier", ctypes.c_float),
        ("normalizedCarPosition", ctypes.c_float), ("carCoordinates", ctypes.c_float * 3),
        ("penaltyTime", ctypes.c_float), ("flag", ctypes.c_int), ("idealLineOn", ctypes.c_int),
        ("isInPitLane", ctypes.c_int), ("surfaceGrip", ctypes.c_float), ("mandatoryPitDone", ctypes.c_int),
    ]


WHEELS = ("fl", "fr", "rl", "rr")
COLUMNS = (["t", "packet", "lap", "lap_ms", "pos", "in_pit", "in_pit_lane", "surface_grip", "gas", "brake", "clutch",
            "gear", "rpm", "steer", "speed_kmh", "acc_x", "acc_y", "acc_z", "vel_x", "vel_y", "vel_z",
            "yaw_rate", "tc", "abs", "tyres_out", "pit_limiter"]
           + ["slip_" + w for w in WHEELS] + ["load_" + w for w in WHEELS] + ["omega_" + w for w in WHEELS]
           + ["core_t_" + w for w in WHEELS])


def _row(t, p, g):
    return ([round(t, 4), p.packetId, g.completedLaps, g.iCurrentTime, round(g.normalizedCarPosition, 5), g.isInPit,
             g.isInPitLane, round(g.surfaceGrip, 4), round(p.gas, 4), round(p.brake, 4), round(p.clutch, 4), p.gear,
             p.rpms, round(p.steerAngle, 4), round(p.speedKmh, 3)]
            + [round(x, 4) for x in p.accG] + [round(x, 4) for x in p.localVelocity]
            + [round(p.localAngularVel[1], 5), round(p.tc, 3), round(p.abs, 3), p.numberOfTyresOut, p.pitLimiterOn]
            + [round(x, 4) for x in p.wheelSlip] + [round(x, 1) for x in p.wheelLoad]
            + [round(x, 3) for x in p.wheelAngularSpeed] + [round(x, 1) for x in p.tyreCoreTemperature])


class Sampler:
    """Reads the shared memory in a daemon thread; keeps the last KEEP_SECONDS of new physics packets."""

    def __init__(self):
        self.rows = collections.deque(maxlen=SAMPLE_HZ * KEEP_SECONDS)
        self.lock = threading.Lock()
        self.error = None
        self._thread = None

    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._loop, name="ac-export-sampler", daemon=True)
            self._thread.start()

    def _loop(self):
        try:
            # read-only views of AC's maps (Windows named shared memory)
            pm = mmap.mmap(-1, ctypes.sizeof(Physics), tagname="Local\\acpmf_physics", access=mmap.ACCESS_READ)
            gm = mmap.mmap(-1, ctypes.sizeof(Graphics), tagname="Local\\acpmf_graphics", access=mmap.ACCESS_READ)
        except Exception as e:  # not on Windows, or AC not reachable
            self.error = f"shared memory not available: {e}"
            return
        last = None
        t0 = time.monotonic()
        while True:
            p = Physics.from_buffer_copy(pm[:ctypes.sizeof(Physics)])
            g = Graphics.from_buffer_copy(gm[:ctypes.sizeof(Graphics)])
            if p.packetId != last:
                last = p.packetId
                with self.lock:
                    self.rows.append(_row(time.monotonic() - t0, p, g))
            time.sleep(1.0 / SAMPLE_HZ)

    def snapshot(self):
        with self.lock:
            return list(self.rows)


_sampler = Sampler()


def _safe_path(name):
    """Only ever a file directly inside LOG_DIR (no user-given paths)."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    base = LOG_DIR.resolve()
    path = (base / name).resolve()
    if path.parent != base:
        raise ValueError("refusing to write outside " + str(base))
    return path


def _write(rows, name):
    path = _safe_path(name)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        w.writerows(rows)
    return str(path)


def _stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def export_last_seconds(seconds=60):
    """CSV of the last `seconds` of driving (max 600) into C:\\AC-Claude\\logs. Returns the file path."""
    _sampler.start()
    rows = _sampler.snapshot()
    if not rows:
        return _sampler.error or "no data yet (is AC running and the car on track?)"
    seconds = max(1, min(int(seconds), KEEP_SECONDS))
    t_end = rows[-1][0]
    sel = [r for r in rows if r[0] >= t_end - seconds]
    return _write(sel, f"ac-{_stamp()}-last{seconds}s.csv")


def export_last_lap():
    """CSV of the last completed lap into C:\\AC-Claude\\logs. Returns the file path."""
    _sampler.start()
    rows = _sampler.snapshot()
    if not rows:
        return _sampler.error or "no data yet (is AC running and the car on track?)"
    current = rows[-1][2]
    sel = [r for r in rows if r[2] == current - 1]
    if not sel:
        return "no completed lap in the last %d s" % KEEP_SECONDS
    return _write(sel, f"ac-{_stamp()}-lap{current}.csv")


def register(mcp):
    """Adds the export tools to a FastMCP server and starts the sampler."""
    _sampler.start()
    mcp.tool()(export_last_seconds)
    mcp.tool()(export_last_lap)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seconds", type=int, default=30, help="sample this long, then export it")
    a = ap.parse_args()
    _sampler.start()
    time.sleep(a.seconds + 0.5)
    print(export_last_seconds(a.seconds))


if __name__ == "__main__":
    sys.exit(main())
