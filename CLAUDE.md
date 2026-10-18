# CLAUDE.md

## Project

MirrorDelta is a Lua app for Assetto Corsa with Custom Shaders Patch (CSP). It has several windows,
each with its own taskbar icon:

- **delta** (`MirrorDelta`): mini sector line, delta line, delta in seconds. Sits above the mirror.
- **timing** (`MirrorDelta Timing`): position, lap, current time, best lap.
- **tyres** (`MirrorDelta Tyres`): tyre core temperature (big number) and tread zones (inner/middle/outer).
- **notify** (`MirrorDelta Notifications`): short messages at the top (flags, fastest lap, positions, pits,
  invalid lap, disconnects), three styles (pill, slanted strip, thin line).
- **setup** (`MirrorDelta Setup`): one line at the top centre when a car setting changes (TC, TC2, ABS, brake bias,
  engine brake, fuel map, turbo, MGU-K/H, limiters, auto shift/clutch; fields as in the official Unbound app, each
  probed once under pcall) plus AC's non-penalty system messages (`src/setup_line.lua`).
- **mirror** (`MirrorDelta Mirror`): AC's rear view via `ui.drawVirtualMirror` (ac_apps.lua, used by CSP's OBS view);
  GT3-style radar markers on the `S.mirrorTargets` nearest cars behind (style, palette, line width, fill, gap label settings; nearest first, a marker overlapping a nearer one is skipped with `S.mirrorHideOverlap`) from a perspective projection (look/side/up, `S.mirrorFov`, 4:1 square pixels; camera at car.ini `[GRAPHICS] MIRROR_POSITION`
  via `ac.INIConfig.carData`, else `car.driverEyesPosition`, through `car.transform:transformPointTo`, else origin + 0.6 m; the box is
  the 8 projected corners of `aabbCenter`/`aabbSize` through the other car's transform, each probed under pcall; manual
  `S.mirrorOffsetX/Y`), threat colours, time gap label on the nearest, edge arrows for cars
  outside the crop, side bars for cars alongside; cars must also be behind by spline gap (`sim.trackLengthM`). Left/right from `wheels[0/1].position` vs `car.side`. The mirror texture is HDR (pre post-processing). `S.mirrorMode`
  (click in the window cycles, hover shows version + mode): 1 gamma = `ui.drawVirtualMirror` into a float `ui.ExtraCanvas`, then
  `ui.renderShader` with `pow(saturate(c * exposure), 0.4545)` (SDK example in ac_wfx_impl.lua); 2 YEBIS canvas with exposure 30
  as CSP's OBS "Virtual mirror" view (obs_integration.lua; user reported no change with it); 3 `ui.beginTonemapping` like
  `display.mirror()`; 4 raw; 5 own camera = `ac.GeometryShot(ac.findNodes('sceneRoot:yes'))` updated in `render.onSceneReady` as
  CSP's OBS camera views (obs_integration.lua: setBestSceneShotQuality + SimplifiedWithLights, float), from the
  markers' camera with vertical FOV from `S.mirrorFov` (4:1), `S.mirrorCamHeight` / `S.mirrorCamPitch` (camera basis camF/camU
  shared with the projection), near plane past our own car, drawn mirrored (u reversed), so markers are exact (`M.exact`,
  offsets off); 11 MIPs + `mipsUpdate`, the shader takes exposure from the last MIP (average) then mode 1's gamma (a fixed
  exposure was dark: the scene's HDR scale differs from the mirror texture's); 6 the same shot with SimplifiedYEBIS. Markers are not smoothed. Always cropped to the window's aspect via UVs or a clip rect, never stretched (`S.mirrorZoom`). Hiding AC's own
  virtual mirror / flags: no verified API; app windows titled like a mirror or flag are hidden via `ac.accessAppWindow`.
- **standings** (`MirrorDelta Standings`, `src/standings_window.lua`): bottom centre row replacing AC's F9 overlay leaderboard:
  player and neighbours by `racePosition`, names (3 letters / surname / none), gap to me or to the car ahead. Race gap
  modes: live (lapCount + splinePosition, `sim.trackLengthM`, player's speed) or a timing loop (`M.update(dt)` from
  script.update records every car's crossing time of `S.standingsSectors` checkpoints, interpolated in the frame; gap =
  difference at the last checkpoint both passed, every sector or only the line). Otherwise best lap difference.
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
  src/damage_window.lua   damage window: one view ("cross"): body bars top/bottom/sides, tyre + suspension square per corner,
                          engine % in the middle, rectangles only
                          (car.damage[0..3], wheels[i].tyreWear/isBlown, wheels[i].suspensionDamage under pcall)
  src/gear_window.lua     gear window (car.gear: -1 R, 0 N; car.rpm, car.rpmLimiter, car.speedKmh)
  src/notify.lua          event detection (flags, other cars polled at 10 Hz) + fixed ring buffer of events
  src/notify_window.lua   notification window (styles: pill, slanted strip via ui.pathLineTo/pathFillConvex, line)
  src/settings_window.lua tabs: Delta, Časy, Pneumatiky, Převody, Poškození, Notifikace, Barvy, Diagnostika
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
- Delta = `lapTimeMs - grid(u)`, smoothed (0.15 s) with ±20 ms colour hysteresis. The delta line is split in the
  middle (default): `T.nowDelta` = delta change over the last 3 s (20 Hz ring buffer in `updateTrend`); default
  reference is the previous lap (`S.referenceKind = 3`, kind 5), strictly: no saved best, estimate, provisional or AC
  delta in that mode. The out lap's partial grid becomes the previous lap with an anchor (`prevLapAnchor`, first
  recorded u); `ownDelta` compares an out-lap reference directly (its grid holds AC's raw out-lap timer, pit lane included, so the delta at the line equals the lap time difference), no delta before the anchor, sectors before it neutral. Keep `updateInner` under LuaJIT's
  60-upvalue limit (move new logic into helper functions).
- Pit lane (`car.isInPitlane`): `src/pit_lights.lua` gives a brightness 0..1 per place on the delta line and per mini
  sector (`S.pitStyle`: 1 scanner, 2 waves from the centre, 3 breathing, 4 halves in turn with `S.pitSectorPattern`),
  colour `S.pitColor` (blue default, orange, white, yellow); the timing window shows BOX in that colour (`S.pitBox`).
- Mini sectors are boundaries at `j / N` in `u`; times are interpolated; purple needs a clean lap and an
  existing best; best sector lists are kept per sector count.
- Deleted laps (cut on track, or AC's callback says invalid) flash red (`flashKind 5`), never become the flash best,
  are listed in `deletedLaps` so `T.bestMs` ignores AC's best when it equals one; `T.lastLapMs/lastLapState` feed the
  timing window's POSL column; `T.bestMs` then falls back to AC's previous best. `ac.onLapCompleted` gives
  `(carIndex, lapTime, valid, cuts, ...)`; invalid with 0 cuts on a lap seen clean is not deleted. A cut is only a
  change of `isLapValid` from true to false within the lap (`checkValidity`; AC keeps the out lap's false after the line).
  Any deleted lap is undeleted when AC takes it as its best (`undeleteIfACBest`, also checked before deleting): AC does
  not keep invalid laps as its best, so its best time is the final word. Diagnostika shows AC's raw best (`T.acBestMs`).
  Each deletion is also announced as a notification with `diag.deletedReason` (the user cannot open Diagnostika). Diagnostika shows
  `diag.lastDeleted` / `diag.lastCallback`. AC system messages are translated to Czech in `originals.lua` (`PHRASES`).
- Out laps, laps that start or pass through the pit lane, and invalid laps are never references. A full lap that
  cannot be a reference (started in the pit lane, cut) is a **provisional** reference until a valid one exists
  (never saved). `activeRef()` order: chosen reference, the other one, provisional.
- **Out lap (partial):** once the car is on track the lap is measured from there; line position = reference's,
  else the measured one (saved as `line` in the data file), else spline 0. With a reference:
  delta = (t - t0) - (ref(u) - ref(u0)) and sectors against it; without: sectors from AC's delta or neutral.
  The sector containing u0 stays grey. The delta window shows no status text (only Diagnostika does).
- A lap counts only if lapCount changed within 0.5 s of the timer restart (a later lapCount confirms it); a timer
  restart in the pit lane or away from the known line is not a crossing. Without an own reference, mini sectors
  are coloured by the change of AC's `performanceMeter` over the sector.
  Teleport (`ac.onCarJumped`), replay and session start reset the lap until the next line crossing.
- The lap event is the **timer restart** (`lapTimeMs` drops). AC can change `lapCount` a frame before or
  after the timer; a lapCount change only counts on its own when the timer is already small, and a second
  event within 1.5 s is ignored (an earlier version dropped the lap here, which froze the delta on the out lap).
- AC may report `previousLapTimeMs` one frame late: the lap time must fall inside the crossing frame,
  else the callback time or the timer estimate is used.

## Diagnostics

The delta did not start in the user's practice sessions although the simulated tests pass, so the
tracker keeps `T.diag` (line crossings, timed laps, references, last reset reason, last rejected lap
reason, jumps, session starts, first script error, whether AC's delta exists). `T.status` explains in the
delta window why there is no delta yet. `T.update` runs the logic under `pcall`; an error is
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
  are checked with `pcall` at runtime. `car.performanceMeter` (AC's own delta in seconds, see
  `acc-lua-examples/cars/dash_display_8100`) is the fallback delta (`S.deltaSource`), also read under `pcall`.
  AC's damage displayer is hidden like the official Unbound app does it: `sim.damageDisplayerShown` +
  `ac.trySimKeyPressCommand('Hide Damage')`. AC's overlay leaderboard (F9) is turned off with `ac.accessOverlayLeaderboardParams().displayMode = 0` (Unbound).
  System messages: CSP `[HIDE] HIDE_SYSTEM_MESSAGES` written to `ac.getFolder(ac.FolderID.ExtCfgUser)/gui.ini` with
  `ac.INIConfig.load` + `:setAndSave` (as ControllerTweaks writes CSP user configs; `applyLiveConfigEdit` is internal
  only, but in versions up to 1.12.0 it also hid the track limits / penalty messages, so it is applied as well:
  at start and again 3, 10 and 30 s later and after every session change, `originals.applyMessages`). Caught with `ac.onMessage(title, description, type)` (RGBControl): car setting messages
  (`originals.isSettingMessage`) go to the setup line only if no own reading within 2 s, the rest to the notifications.
  Notifications use `sim.raceFlagType` + `ac.FlagType` (Radar, RGBControl), `ac.getDriverName(i)`, `car.isConnected`,
  `car.bestLapTimeMs` of any car and `ac.getSession(i).type == ac.SessionType.Race` (RGBControl). If someone provides `extension/internal/lua-sdk` from a CSP install,
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
