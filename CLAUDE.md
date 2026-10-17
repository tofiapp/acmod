# CLAUDE.md

## Project

MirrorDelta is a Lua app for Assetto Corsa with Custom Shaders Patch (CSP). It has three windows,
each with its own taskbar icon:

- **delta** (`MirrorDelta`): mini sector line, delta line, delta in seconds. Sits above the mirror.
- **timing** (`MirrorDelta Timing`): position, lap, current time, best lap.
- **tyres** (`MirrorDelta Tyres`): tyre core temperature (big number) and tread zones (inner/middle/outer).
- **gear** (`MirrorDelta Gear`): 12-segment RPM bar (range from `car.rpmLimiter`), speed, big gear number.

The user speaks Czech: talk to them in Czech, write code, comments and commit messages in English.
UI labels inside the app and the README are Czech.

## Layout

```
apps/lua/MirrorDelta/
  manifest.ini            windows, flags (NO_BACKGROUND, FLOATING_TITLE_BAR), LAZY = NONE
  MirrorDelta.lua         entry: script.update + one function per window + settings
  src/config.lua          defaults, ac.storage, plain table S; change settings only via config.set()
  src/tracker.lua         lap logic: reference grid, delta, mini sectors, lap events, flash
  src/store.lua           per car + track file (stringify) in ac.FolderID.ScriptConfig
  src/draw.lua            shared vec2/rgbm, rect, text with shadow, measure cache, lap formatting
  src/delta_window.lua    delta window
  src/timing_window.lua   timing window
  src/tyres_window.lua    tyres window (two styles)
  src/gear_window.lua     gear window (car.gear: -1 R, 0 N; car.rpm, car.rpmLimiter, car.speedKmh)
  src/settings_window.lua tabs: Delta, Časy, Pneumatiky, Převody, Barvy
tests/                    mock CSP API + simulated laps, run with LuaJIT via lupa
build.sh / build.ps1      dist/MirrorDelta-<version>.zip with apps/lua/MirrorDelta/...
```

## How the tracker works

- Positions inside a lap are measured from the **timing line**, not spline zero (the AI spline may be
  offset). At every lap event (lapCount change or timer reset while moving forward) the line's spline
  position is interpolated from the previous frame and `t` (ms since crossing). Lap fraction
  `u = (spline - lineSpline) % 1`.
- The current lap is recorded on a grid of `GRID + 1` points (`u = k / GRID`, index `k + 1`),
  interpolated between frames. A finished clean lap waits up to 1.5 s for `ac.onLapCompleted`
  (validity, exact time), then becomes the session and/or all-time reference. The all-time one is saved.
- Delta = `lapTimeMs - grid(u)`, smoothed (0.15 s) with ±20 ms colour hysteresis.
- Mini sectors are boundaries at `j / N` in `u`; times are interpolated; purple needs a clean lap and an
  existing best; best sector lists are kept per sector count.
- Out laps, laps that start or pass through the pit lane, and invalid laps are never references.
  Teleport (`ac.onCarJumped`), replay and session start reset the lap until the next line crossing.
- The lap event is the **timer restart** (`lapTimeMs` drops). AC can change `lapCount` a frame before or
  after the timer; a lapCount change only counts on its own when the timer is already small, and a second
  event within 1.5 s is ignored (an earlier version dropped the lap here, which froze the delta on the out lap).
- AC may report `previousLapTimeMs` one frame late: the lap time must fall inside the crossing frame,
  else the callback time or the timer estimate is used.

## Rules

- **No per-frame allocation.** Reuse `vec2`/`rgbm` (see `draw.lua`), cache strings (tables keyed by
  number or single-entry caches), measure text only when the string changes. `tests/test_app.lua`
  section 6b measures it (JIT off, GC stopped, update + all three windows).
- **Do not invent CSP API.** Verify in https://github.com/ac-custom-shaders-patch/acc-lua-sdk or in the
  official apps (`app-csp-defaults`, `acc-lua-internal`). The car state struct is generated from C++ and is
  not in the public SDK; fields used here were confirmed from official apps, except the tyre temperature
  fields (`tyreCoreTemperature`, `tyreInside/Middle/OutsideTemperature`, `tyreOptimumTemperature`), which
  are checked with `pcall` at runtime. If someone provides `extension/internal/lua-sdk` from a CSP install,
  confirm them there.
- Drawing uses `ui.drawRectFilled(p1, p2, color, rounding)` and `ui.dwriteTextAligned` after
  `ui.setCursor`. Rounded stripes are built by overlapping rects instead of corner flags.
- Font: `Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed` (Windows 10/11).

## Commands

```bash
pip install lupa && python tests/run_tests.py   # syntax check of all Lua files + simulated laps
./build.sh                                      # or build.ps1 on Windows
```

## Defaults the user chose

Delta layout B (sectors top, line middle, number bottom), 24 sectors in 3 groups, line 9.5 px, gap 12 px,
number 30 px, opacity 100 %, intensity off. Timing side by side, best lap purple frame, lap flash on.
Tyres style 1 (big core numbers + zone bar); style 2 = core number + tyre + three zone numbers.
