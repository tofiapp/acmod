# CLAUDE.md

## Project

MirrorDelta is a Lua app for Assetto Corsa with Custom Shaders Patch (CSP). It has three windows,
each with its own taskbar icon:

- **delta** (`MirrorDelta`): mini sector line, delta line, delta in seconds. Sits above the mirror.
- **timing** (`MirrorDelta Timing`): position, lap, current time, best lap.
- **tyres** (`MirrorDelta Tyres`): tyre core temperature (big number) and tread zones (inner/middle/outer).
- **gear** (`MirrorDelta Gear`): 12-segment RPM bar lighting from both edges to the centre (range from
  `car.rpmLimiter`), gear on a rounded tile coloured by revs (white/yellow/red, blinking blue at the limiter),
  calm speed (changes only by whole steps) on a dark bar under it. Font: bundled Unbounded Bold.

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
  src/damage_window.lua   damage window (car.damage[0..3] front/rear/left/right, car.engineLifeLeft 0..1000)
  src/gear_window.lua     gear window (car.gear: -1 R, 0 N; car.rpm, car.rpmLimiter, car.speedKmh)
  src/settings_window.lua tabs: Delta, Časy, Pneumatiky, Převody, Poškození, Barvy, Diagnostika
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

## Diagnostics

The delta did not start in the user's practice sessions although the simulated tests pass, so the
tracker keeps `T.diag` (line crossings, timed laps, references, last reset reason, last rejected lap
reason, jumps, session starts, first script error). `T.update` runs the logic under `pcall`; an error is
stored and shown in the settings tab Diagnostika and as a red line in the delta window. Ask the user for a
screenshot of that tab before guessing.

The raw scale of `car.damage` is unknown (AC units); `damageFull` (default 50) maps it to full red and the
Poškození tab shows the live raw values for calibration.

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
- Font: `Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed` (Windows 10/11) for delta, timing and tyres.
  The gear window uses `Unbounded:apps/lua/MirrorDelta/fonts;Weight=Bold` (bundled TTF + OFL.txt; the
  `Name:dir` form with a path relative to the AC root is how official CSP code loads its own fonts).

## Commands

```bash
pip install lupa && python tests/run_tests.py   # syntax check of all Lua files + simulated laps
./build.sh                                      # or build.ps1 on Windows
```

## Defaults the user chose

Delta layout B (sectors top, line middle, number bottom), 24 sectors in 3 groups, line 9.5 px, gap 12 px,
number 30 px, opacity 100 %, intensity off. Timing side by side, best lap purple frame, lap flash on.
Tyres style 1 (big core numbers + zone bar); style 2 = core number + tyre + three zone numbers.
Gear: rounded style, speed on a dark bar as wide as the gear tile, speed step 3 km/h, font Unbounded.

## KeyDrive (separate project, work in progress)

Smart keyboard input for AC as a CSP Gamepad FX script; independent of MirrorDelta (do not touch its code).
Research and verified API: `docs/keydrive-research.md`.

```
extension/lua/joypad-assist/KeyDrive/
  manifest.ini, settings.ini   Gamepad FX script (settings.ini = CM settings, section KEYDRIVE)
  assist.lua                   physics thread: reads keys, writes ac.getJoypadState().gas/brake/steer
  module_render.lua            render thread (ac.loadRenderThreadModule): diagnostic overlay via script.drawUI
  src/ramp.lua                 rate limiters in units/s (dt based)
  src/keys.lua                 AC keyboard binds and keyboard steering rates from cfg/controls.ini ([KEYBOARD] GAS/BRAKE/LEFT/RIGHT, [GEARUP]/[GEARDN]/
                               [HANDBRAKE] KEY; CM writes hex "0x53"), ac.isKeyDown. In gamepad mode AC does not
                               forward keyboard gear keys (user report), so assist.lua sets state.gearUp/gearDown/handbrake
  src/traction.lua             throttle traction "remembering foot": load-weighted ndSlip of the driven wheels (1 = tyre
                               peak; fallback wheel speed ratio), filtered 30 ms; absolute cap A; at a crossing caused by
                               real throttle (> 30 %) remembers 95 % of the sent level per gear, pulls A to 85 % of it
                               (to the 0.3 floor only if the slip persists 0.4 s), holds still between 80-100 % of the
                               target, returns quickly to 92 % of the memory, then creeps 0.08/s. Memory recovers
                               0.02/s; a new press or gear starts at the memory. Target must stay <= 1.
  src/brake.lua                brake lock limiter on LONGITUDINAL slip only: max -slipRatio / peakRatio over grounded wheels
                               (peakRatio learned from straight-running wheels: |slipRatio| / ndSlip, default 0.13),
                               predicted 0.04 s; multiplier k on the ramped brake (K_UP 4, K_DOWN 15, floor 0.15);
                               remembers the level where the lock value crossed the target; off below 10 km/h; car ABS
                               on -> left to it. (v0.4 used combined ndSlip: steering into a corner took the brake away.)
  src/steering.lua             grip window in road wheel degrees: delta from wheels[0..1].look, betaF / betaR from
                               wheels[i].velocity (car.look/side, sign of side voted against the output); window
                               betaF +- alphaPeak * target only reduces the request; countersteer = wheels along betaF
                               when |betaR| > alphaPeak and betaF, betaR share the sign. Learns degPerUnit and
                               alphaPeak (|slipAngle| / ndSlip at slipRatio ~ 0). Off below 20 km/h, fades in to 40.
  src/curve.lua                "x:y x:y" piecewise linear curve (STEER_SPEED_CURVE; spaces, not commas: CSP INI lists)
  src/recorder.lua             render thread: 60 s ring buffer at 40 Hz (keys, outputs, car, 4 wheels, body slip,
                               collisions, event flags) -> keydrive-log.csv every 10 s, keydrive-incident-N.csv 3 s
                               after SPIN/CRASH/OFF, in Documents/Assetto Corsa/logs/keydrive (fallback: script folder;
                               v0.6 and older wrote into the script folder, which a reinstall wipes). Ask the user for
                               these files instead of guessing.
  src/shared.lua               ac.connect layout 'KeyDrive.Live.v7' (same layout on every side)
tests/keydrive/                own mock + tests: python tests/keydrive/run_tests.py
build-keydrive.sh / .ps1       dist/KeyDrive-<version>.zip (extension/... + apps/lua/KeyDriveConfig/...)
```

Status: phase 3, second attempt (v0.3.0). History of user feedback:
- v0.1: plain ramp spun the wheels all the time in gamepad mode (AC's keyboard mode has its own hidden throttle help);
  keyboard gear keys were not applied in gamepad mode (fixed by forwarding [GEARUP]/[GEARDN]).
- v0.2 (own longitudinal slip ratio, limit down to 0): first gear "power keeps dropping, cannot accelerate", and at
  200 km/h in 4th it gave full throttle in a corner (longitudinal slip cannot see a rear axle sliding sideways).
- v0.3: AC's ndSlip (combined), prediction, floor, target 100 % of peak, and the recorder. A launch model in
  tests/keydrive showed that a target above the tyre peak oscillates and that a 50 % floor cannot stop a spin
  in first gear of a strong car.
- incident log from the user (v0.3): traction fine (rear ndSlip ~0.9-1.05); placeholder brake reached 100 % in
  0.15 s, fronts locked above ~60 % brake (ndSlip up to 8), avg -1.24 g locked vs -1.6 g possible; downshifts
  under braking locked the rears; the OFF incident was understeer (front ndSlip 1.2-1.5) -> phase 5 steer limit.
- v0.4: phase 4 brake (ramp 400/800 %/s, MAX_BRAKE, trail-brake release by |steer|, lock limiter). Brake model in
  tests: no locked wheels, 20 % shorter stop.
Analysis helpers for the CSV logs are quick Python scripts (csv module); group samples by key_brake phases.
- incident 4 (v0.4): no locks in straight braking (49 % -> 0 %), but the brake limiter cut the brake to 13 % when
  steering into corners (combined ndSlip), the car arrived too fast, fronts at 10-35 deg slip (peak 7.2), spin + crash.
  Logs: slipAngle has the opposite sign of the steering; front peak 7.2 deg; ndSlip = |slipRatio| / 0.13 straight.
- v0.5: brake on longitudinal slip, phase 5 steering (rate curve, grip window, countersteer). Single-track model in
  tests: fronts held at 0.99 of peak, +15 % lateral force; countersteer recovers a slide. A countersteer to the window
  edge (first attempt) pushed the nose further into the spin.
- v0.5 user verdict: "the car grabs the steering", throttle "not acceptable", "I want it smooth", "not 20 times from
  20 to 0 and back". Log incident 4: in 1st/2nd gear the traction cut the throttle 50-100 % of the time, swinging
  97 -> 22 -> 75 -> 22 % (prediction + fast K_DOWN), triggered also by the clutch bite after selecting first.
- v0.6 = smoothness first: every output is slew-limited. Throttle: assists may lower it at most 1.5 /s, only the
  driver's lift uses THROTTLE_FALL_RATE. Steering: the assist never moves the wheels faster than the key rate (except
  an opt-in countersteer and 0.6 s after it); COUNTERSTEER_ASSIST default 0, STEER_TARGET default 120.
  Launch model with realistic first-gear inertia (J 8): slip ~1.0 of peak, one spike, gas eases 1.0 -> 0.6 in 0.35 s.
Rule learned the hard way: the user values predictability and smoothness over maximum grip. Never let an assist
step an output; prefer gentle, slow corrections and opt-in for anything that moves controls on its own.
- v0.6 user verdict: no steering intervention at all; the throttle "pulses slowly". Logs (incident 1 + log): (a) in
  higher gears k = 1 but the throttle swung 80-94 % with every steering tap: the corner cap; (b) in first gear the
  car takes ~70 %, the PI loop climbed to 72 %, spun, fell to the floor 0.4, climbed back in 0.5 s: ~1 s limit cycle;
  (c) the 0.5 s shift hold let a real spin after selecting first (60 % throttle) grow to ndSlip 65.
- v0.7: defaults STEER_LIMIT_STRENGTH 0, COUNTERSTEER_ASSIST 0, CORNER_THROTTLE_REDUCTION 0; traction rewritten as the
  remembering foot (see traction.lua), shift hold removed. Launch model: one spike, then steady 81 -> 91 % creeping,
  gas std 0.03 (was 0.17); logs moved to Documents/Assetto Corsa/logs/keydrive.
- v0.7 user: steering "feels completely different from plain keyboard". v0.7.1: STEER_STYLE 0 (default) uses AC's
  own keyboard rates from controls.ini [KEYBOARD] STEERING_SPEED (1.75), STEERING_OPPOSITE_DIRECTION_SPEED (2.5),
  STEER_RESET_SPEED (1.8) (names from Content Manager's ControlsSettings.cs); STEER_STYLE 1 = KeyDrive's speed curve.
Next: user test of v0.7.1, then phase 6 (modes, tyre temperature).
