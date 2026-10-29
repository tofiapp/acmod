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
  assist.lua                   physics thread, thin game wrapper: settings, keys, joypad state -> cores; brake still here
  core/                        PURE Lua 5.1/LuaJIT (no CSP API, no CSP globals like math.clamp; test 27 runs them in a
                               bare env). Instances with params tables (DEFAULTS) so sim/ and the optimizer can run many.
  core/throttle.lua            Throttle.new(params, tractionParams):update(dt, keyGas, car, latG, steer) -> 0..1: corner
                               cap (off) -> key ramp -> traction cap -> final slew (assists fall <= ASSIST_FALL /s: 1.5 mode 1, 3.3 tuned mode 2;
                               a spin never slower); MODE 2 cap recovery scales with RISE / RISE_REF (1.2)
  core/steering.lua            Steering.new(params):update(dt, kLeft, kRight, car) -> -1..1: AC keyboard copy (KB_* rates
                               from controls.ini, RATE, SLOWDOWN) or CURVE style, then the optional assist; :follow(v)
  core/ramp.lua, curve.lua     rate limiters (units/s), "x:y x:y" curves (STEER_SPEED_CURVE; spaces, not commas)
  core/traction.lua            throttle traction "remembering foot": load-weighted ndSlip of the driven wheels (1 = tyre
                               peak; fallback wheel speed ratio), filtered 30 ms; absolute cap A; memory per gear AND
                               500 rpm band (lazy recovery 0.015/s); limit = lower of the current and next band, cap
                               eases down K_PRE 1.2/s before the revs get there. Crossing (throttle > 30 %): 95 % of
                               the level; when the wheels grip again: middle of start and end level. Pull to 85 % of
                               the memory (0.3 floor after 0.4 s), hold between 80-100 % of the target, quick return
                               to 92 %, memory creeps 0.08/s with spare grip. Target must stay <= 1. Memory survives
                               teleports (reset only on script reload).
  core/traction.lua MODE 2     (v0.10 default, TRACTION_MODE = 2) regulator: cap A follows the slip (prediction PRED x
                               rising slip rate, K_DOWN proportional, FALL_MAX), anti-windup (A <= request + AW), tracks
                               the request with plenty of grip (TRACK, 0 = off: 0.5 untuned caused spins), LAT_SPLIT = regulates load-weighted |slipRatio| /
                               learned peak ratio against sqrt(target^2 - lateral^2) (corners), guard: combined ndSlip
                               over the target always cuts (lateral slide), optional low-speed reference V_REF, memory.
  core/tuned.lua               optimizer result used by MODE 2 (data only)
  core/steer_assist.lua        grip window in road wheel degrees: delta from wheels[0..1].look, betaF / betaR from
                               wheels[i].velocity (car.look/side, sign of side voted against the output); window
                               betaF +- alphaPeak * target only reduces the request; countersteer = wheels along betaF
                               when |betaR| > alphaPeak and betaF, betaR share the sign. Learns degPerUnit and
                               alphaPeak (|slipAngle| / ndSlip at slipRatio ~ 0). Off below 20 km/h, fades in to 40.
  src/keys.lua                 AC keyboard binds and keyboard steering rates from cfg/controls.ini ([KEYBOARD] GAS/BRAKE/LEFT/RIGHT, [GEARUP]/[GEARDN]/
                               [HANDBRAKE] KEY; CM writes hex "0x53"), ac.isKeyDown. In gamepad mode AC does not
                               forward keyboard gear keys (user report), so assist.lua sets state.gearUp/gearDown/handbrake
                               + TRACTION_KEY (settings.ini, default X; letter/digit, F1-F12 or key code): own switch,
                               edge-triggered in assist.lua, ignored with Ctrl/Alt held or when it equals a driving
                               key; throttleCore:setParams({TRACTION=false}); ac.setMessage; tcState 5 (badge in
                               module_render even with diagnostics hidden; sim/replay.lua skips tc_state 5 rows)
  src/brake.lua                brake lock limiter on LONGITUDINAL slip only: max -slipRatio / peakRatio over grounded wheels
                               (peakRatio learned from straight-running wheels: |slipRatio| / ndSlip, default 0.13),
                               predicted 0.04 s; multiplier k on the ramped brake (K_UP 4, K_DOWN 15, floor 0.15);
                               remembers the level where the lock value crossed the target; off below 10 km/h; car ABS
                               on -> left to it. (v0.4 used combined ndSlip: steering into a corner took the brake away.)
  src/recorder.lua             render thread: 60 s ring buffer at 40 Hz (keys, outputs, car, 4 wheels, body slip,
                               collisions, event flags) -> keydrive-log.csv every 10 s, keydrive-incident-N.csv 3 s
                               after SPIN/CRASH/OFF, in Documents/Assetto Corsa/logs/keydrive (fallback: script folder;
                               v0.6 and older wrote into the script folder, which a reinstall wipes). Ask the user for
                               these files instead of guessing.
  src/shared.lua               ac.connect layout 'KeyDrive.Live.v11' (v10: + keyboardCaptured from the render module; v11: + cfg* fields from the KeyDriveConfig app, strength; recorder column 'strength') (same layout on every side)
apps/lua/KeyDriveKeyboardTest/ input method test, variant A (LAZY = FULL): with Input method = Keyboard drives gas/brake/
                               steer via ac.overrideCarControls (combineAxis = false), compares car.gas/brake/steer with
                               what it wrote (SEDÍ/NESEDÍ per channel), logs/keydrive/kb-test.csv; writeSafe() hands the car
                               back (steer math.huge, combineAxis true, kers Skip) on off, input change and onRelease
apps/lua/KeyDriveConfig/       companion app. Window "KeyDrive" (src/settings.lua, v0.12.1): "Zobrazit diagnostiku" and
                               "Síla zásahu" 0..100 (50 = as tuned) -> live.cfgDiagSet/cfgShowDiag, cfgStrengthSet/cfgStrength (ac.storage
                               'keydrive', each control sent only once touched; v0.13 keys strength13*); assist.lua
                               strengthScales (v0.13): 0 = x1.25 / x1.67 (= v0.12 default), 50 = tuned, 100 = x0.85 / x0.75; src/shared.lua is a COPY of the core's (test 32 compares them).
                               Window "KeyDrive Reference" + src/reference.lua, records
                               in NORMAL keyboard mode (KeyDrive inactive) keys, car.steer, front wheel angle, pedals,
                               speed, slip -> Documents/Assetto Corsa/logs/keydrive/ac-reference.csv (first line '#' meta:
                               input method, AC keyboard rates, car). Use it to copy AC's own keyboard filter.
sim/                           simulator (phase 3-5): model.lua (car), tyre.lua, runner.lua (333 Hz physics, controller at
                               physics rate or 50-165 fps, sensor noise/delay, oracle), metrics.lua (THRESHOLDS: USER vs
                               PROPOSAL), scenarios/ (tuning) + scenarios/hidden/ (NEVER tune on it), cars/ (rwd_supra
                               calibrated to the user's logs), evaluate.lua + optimize.lua/.py, run.py -> sim/out/
.claude/agents/                sim-engineer, throttle-tuner, telemetry-analyst, reviewer (short summaries)
tools/ac-bridge/ac_export.py   CSV export for the user's MCP bridge: reads AC shared memory read-only, writes ONLY into
                               C:\AC-Claude\logs (generated names, path guard); register(mcp) adds two tools
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
- logs sent after v0.7.1 were still v0.6 (old columns, script folder): spins in 1st/2nd always started at
  5000-5600 rpm (torque peak) with ~75 % throttle; more throttle was fine below. v0.8: memory per gear and rpm band,
  easing off before the band. Torque-peak model in tests: second launch spins less and is faster.
- v0.8 user: steering "absolutely not good, something completely different" than plain keyboard even with AC's three
  rates. Unknown what else AC does. v0.8.1: STEER_STYLE 0 = auto: if AC computes the keyboard steering itself in
  gamepad mode, the incoming state.steer (differing from KeyDrive's last write, pointing the key's way) wins votes and
  is passed through untouched; else emulation (STEER_STYLE 2). Recorder logs in_gas/in_brake/in_steer, steer_from_ac,
  ac_votes: check them in the next log to learn what AC sends.
- v0.8.1 user: panel says "KeyDrive" (AC sends no keyboard steering in gamepad mode); steering "steers like a
  joystick, not like normal". v0.8.2 adds the reference recorder app; next step: fit AC's keyboard steering (and its
  hidden throttle/brake help) from ac-reference.csv, then copy it in STEER_STYLE 0.
- ac-reference.csv received: AC's keyboard steering = outward STEERING_SPEED x speed factor (1.05 /s at 55 km/h ...
  0.17 /s from 215 km/h), reset 3.15 /s, opposite 4.4 /s (details in docs/keydrive-research.md, also AC's keyboard
  throttle/brake help). v0.9: STEER_STYLE 0 copies it exactly (AC_SPEED_CURVE in assist.lua).
- v0.9 user: steering "super". Throttle: launch crawls, then full power kicks in, a long uncontrolled slide because
  the throttle stayed on. Log (incident 4, v0.9): (a) during a spin the car moved backwards relative to its nose
  (localVelocity.z < -1) and traction switched itself off ("reverse") -> gas 1.0 mid-spin; (b) cap fell to 0.05
  (crossing set A = out below the floor) and stayed, launches crawled; (c) real first-gear spins (slipRatio 3-8 at
  5-12 km/h, AC's ndSlip consistent with the ratio even at low speed) took 0.6 s to catch at 1.5 /s.
  v0.9.1: traction only off in reverse/neutral GEAR; A never below FLOOR; slip > 2x target -> K_DOWN_SEVERE 5 and the
  sent throttle may fall 4 /s. A low-speed slip measure was tried and dropped (model launch worse, AC data consistent).
- New plan (user, ultracode): input method decision first, then pure Lua core modules, a simulator in sim/ with
  scenarios + oracle, metrics with pass thresholds, an optimizer, calibration from real driving through the user's MCP
  bridge (C:\AC-Claude, writes only into C:\AC-Claude\logs), subagents in .claude/agents/. README: README-KeyDrive.md.
- Input method research (docs/keydrive-research.md, last section): user chose B (Gamepad FX) as the base plus a test of A.
  v0.9.2: STEER_RATE (% of AC's keyboard rates) and STEER_SPEED_SLOWDOWN (% of AC's slowdown with speed) for the AC copy;
  KeyDriveKeyboardTest app. Next: user runs the keyboard test + v0.9.1/0.9.2 throttle.
- Phase 2 (v0.9.3): pure cores in core/ (see layout). Refactor verified bit-exact against v0.9.2 with a differential
  test (6 settings x 12 random traces x 20000 steps, max diff 0).
- Phases 3-7: simulator (reviewed twice, calibrated to the logs: clutch slips in 1st to 50-60 km/h, tyre tail, inside
  wheel spins first, upshift kick), metrics with USER/PROPOSAL thresholds, optimizer, bridge export, subagents.
  Findings: at a 1st-gear launch 1 % throttle takes the slip from 1.0 to 2.3 (clutch slipping, low inertia), so the
  regulator must slow down BEFORE the peak; in corners the combined ndSlip is high without throttle (LAT_SPLIT).
- v0.10.0: TRACTION_MODE 2 (tuned regulator) default. Sim: tuning 100/210 runs pass (v0.9.3: 71), hidden 61/135
  (v0.9.3: 33); runs over 1.5x peak slip 35 vs 131 (tuning), 20 vs 95 (hidden). TRACTION_MODE 1 = old foot.
- v0.10.0 user: much better than before, steering good, throttle clearly improved, but sometimes needlessly cautious,
  after a kerb it refused to accelerate on straight asphalt; other cars: "the dump is much longer"; one spin. Logs
  (Mustang + Supra, analysed by agents, cross-checked): the cap was PINNED to RETURN x memory (A < T clamp while T
  creeps with the memory recovery; K_UP never ran): 17-31 s of needless cut per session; limits learned in corners
  applied on straights; corner cuts to the 0.09 floor; hold band froze the cap at 0.47 of the peak where real
  full-throttle slip sits (sx 0.45-0.5). The spin: throttle rising too fast under 0.7-2 g, then brake + 2->1 downshift
  locked the rears (brake limiter: longitudinal only). kb-test.csv: test never switched on.
- v0.10.1 (interim, same tuned parameters): pin fix, forgetting (SPARE/FORGET_*), LEARN_LAT, FLOOR_LAT, recovery
  scaled by the key ramp, settings TRACTION_RECOVERY / TRACTION_MEMORY, recorder meta line. Sim: Mustang profile,
  Supra refit, per-axle lateral grip, real slip noise (5 Hz band, 3-4x before), new scenarios kerb_straight,
  corner_then_straight; sim/replay.lua = open-loop replay of the real logs (sim/data/real) as a CAUTION measure
  (needless cut share) added to the optimizer cost. Replay of the Supra log: needless cut 55 s (0.10.0) -> 35 s.
- v0.10.1 user: "improvement, but still work ahead". Mustang logs (d1-d3): needless cuts 11-14 %, the rest in fast corners
  (LAT_SPLIT left 0.34 for the throttle at 0.75 lateral) -> ELLIPSE, GUARD_LEVEL; replay LOW 0.75.
- v0.11.0: optimizer round 5 (all new parameters + 11 real datasets in the cost), core/tuned.lua = seed 63: needless
  cuts in the real logs 29 % -> 4.2 %, sim passes up (tuning 92 -> 114/320, hidden 45 -> 61/200), but more short slip
  spikes over 1.5x on the user's cars (tuning 20 -> 37/160, hidden 6 -> 21/100; peak max about the same, rear slides
  unchanged, more power-on understeer at low grip: front axle slide in hidden h_kerb_corner_2nd at grip 0.8). MEM 0 in the tuned set; TRACTION_MEMORY now defaults to 0 and 1 really turns the memory on.
  TRACTION_KEY (default X) switches the traction off/on while driving (user: burnouts, spinning on purpose).
  If the user reports spins: TARGET_SLIP below 100 or TRACTION_MEMORY 1 first, then retune with a spike penalty.
- v0.11.0 user: "braver, but the jerking of the throttle power came back". Logs (Mustang, 2 zips; analysis workflow +
  cross-check): relay limit cycle in 1st/2nd gear, 4-6 throttle direction changes/s, ~0.35 s period: after a cut the
  cap climbs at K_BACK 1.2 /s (MEM 0: T = 1) up to HOLD_BAND x target = 0.72 (s12: 0.47), the slip overshoots
  ~90 ms later to 1.14x target, cut, repeat. The sim missed it: binary steadyDirChanges + runCost cap at 5 (6/s costs
  the same as 13/s), and its slip noise is 1.5-2.4x too large and Gaussian (real: heavy-tailed, kurtosis ~30), so
  its pulsing is a shallow noise ripple and s12 chatters at 3-5/s there vs 0.6-1.6 real.
- v0.11.1: RET_HOLD 0.5 s (traction.lua MODE 2): a cut where the measured slip is over the target (RET_ARM) holds the
  cap for RET_HOLD while the slip stays above RET_LOW 0.5 x target; arming on prediction/noise cuts or a window that
  ignores re-arming made kerb recovery 1-2.5 s in the sim. Replay of the 0.11 logs: 1st/2nd direction changes
  3.9 -> 2.4 and 4.1 -> 3.3 /s, needless cuts 4.2 -> 4.7 % (old 11 datasets). A lift or shift ends the window. 0.11 logs added as sim/data/real e1-e4,
  f1-f4 (+ gas_out, tc_state). NEXT (planned): heavy-tailed sensor noise in runner.lua, a whole-held low-gear pulse
  metric with a continuous cost, low-gear lateral exit scenarios, a calibration test that the sim ranks s12/r63 pulsing
  like the real logs (low gear 2.5 / 1.6 / 4.4 /s for 0.10.0 / 0.10.1 / 0.11.0), replay pulse rate in the cost, then
  retune with RET_HOLD/RET_ARM in the space (already added).
- v0.11.1 user: "jerking clearly smaller, want to perfect it"; logs (Sachsenring, Spa): low-gear 2.96 / 2.24 /s.
  Nordschleife, part of Spa and a whole Red Bull Ring zip ("almost phenomenal there") were REPLAYS: KeyDrive's live
  values frozen while the car moved (Gamepad FX does not run in replays) -> v0.11.2 = recorder skips stale samples
  (same throttle as 0.11.1). Check logs for frozen tc_cap/drive_slip_nd before analysing.
- Sim upgrade (after 0.11.1): heavy-tailed slip noise fitted to 17 real sessions (runner.lua VOL_SIGMA 0.6, VOL_TAU
  0.6 s, NOISE_REL 0.115), sim/calibrate.py (sim must rank low-gear pulse s12 < v0.11.1 < r63 like the logs), USER
  check 'pulse' (whole key-held direction changes/s, gears 1-2 too; graded vs max(1, oracle), cap 10/run, wet/cold/grip
  x0.25), scenarios exit_1st_lateral / exit_2nd_lateral / hairpin_kerb_1st, real-log replay terms (caution x80,
  low-gear pulse x8, RISK x300 = replayed output above the logged one while the real tyres were past their peak),
  +10 per failed safety check (a never-cutting core used to win), LOSS_WEIGHT 20, recoveryTime x3. Cost ranks
  v0.11.1 < s12 < r63 < traction off < very cautious. Core: PRED_KD (prediction-only cuts gentler), RESTORE (tried,
  OFF: it re-enabled the pulsing), lift below the cap ends a RET_HOLD window (review: partial lift + re-press froze it).
- v0.12.0: optimizer round 6 seed 74 + HOLD_BAND 0.70 by hand (0.6 brought back 1-3 s kerb recovery). Sim low-gear
  pulse 3.7 -> 1.5 /s, replay: low-gear pulse 2.79 -> 1.91, needless 12.3 -> 9.8 %, risk 0.14 -> 0.64 %; tuning passes
  98 -> 127/380, but runs over 1.5x peak slip 146 -> 163 (hidden 79 -> 90). Watch for spins in the next logs.
- v0.12.1 (user: hide the KeyDrive window, a slider for the intervention): KeyDriveConfig window "KeyDrive" (see layout).
  Sim, strength 0 / 25 / 50 / 75 / 100: runs over 1.5x peak 205 / 189 / 163 / 137 / 116 of 380, real-log needless
  cuts 6 / 7 / 10 / 25 / 37 %, recovery fails 0 / 0 / 1 / 6 / 19.
- v0.12.1 logs (Road America, Mustang; sim/data/real h1-h4): strength 100 for 3 sessions, 50 for one. Strength 50:
  low-gear pulse 1.38 /s (0.11.1: 2.2-3.0), needless 14 %, drive slip > 1.5x 0.7 % of held time (0.11.1: 3 %). Strength
  100: needless 34 % (cuts to 0.2-0.45 in 3rd-gear corners at 1.3-1.9 g). Open issues: (a) launch after revving in
  NEUTRAL (traction off in N by design): engaging 1st with 0.8+ request -> rear ndSlip up to 38, the cap reaches the
  floor too late (clutch dump) -> a launch cap on N->1 at standstill; (b) second slide under trail braking (rear
  combined slip 1.5-2.2 while the brake limiter only watches longitudinal slip) -> brake phase.
- v0.12.1 user: strength 100 "much better than 50, very few jerks, throttle onset getting good"; "hide the window" meant
  the big diagnostic panel (the checkbox does it). Real logs: what separates 100 from 50 is the AMPLITUDE (reversals
  >= 5 % 0.38 vs 0.65 /s, travel 0.18 vs 0.25 /s), not the 1 %-deadband count; the needless-cut share (34 % vs 14 %) was
  not felt. The sim agrees on amplitude (pulseBig 0.61 vs 0.92) but no cost weighting ranks 100 < 50 without letting a
  more cautious set win: where the user's optimum lies along caution is unknown -> the user explores it with the slider.
- v0.13.0: default = v0.12.1 strength 100 (tuned.lua TARGET_SLIP 0.7453, K_BACK/K_UP/FORGET_RATE x0.6); slider
  re-centred (0 = v0.12 default, 100 = x0.85 / x0.75), stored under new keys (starts at 50). Note: K_BACK 0.73 /s < the
  key ramp 1.2 /s also slows the onset without wheelspin (0 -> full ~1.2 s); tests 1/3/7/7b use TRACTION 0 for the pure
  key ramp, tests 28/30 the frozen v0.12.0 set (fixtures/tuned_v0120.lua). NEXT: optimizer anchored at this set
  (penalise more loss / caution than the anchor, reward smaller amplitude).
- v0.13.1: optimizer round 7 in anchor mode (anchor = v0.13.0), seed 83: HOLD_BAND 0.55, K_BACK 1.03, K_DOWN 5.2, PRED_KD
  0.21, FLOOR 0.21. Sim tuning passes 43 -> 126/380, pulse fails 113 -> 47, loss fails 279 -> 181, safety unchanged;
  hidden passes 14 -> 58/200; replay big reversals 0.52 -> 0.38 /s, needless 38 -> 35 %. Onset 0 -> full 1.35 -> 0.95 s
  (K_BACK also sets the onset; keeping 0.73 cost loss 0.21 / caution 44 %). Tell the user THROTTLE_RISE_RATE ~85 if
  the slower onset is missed.
