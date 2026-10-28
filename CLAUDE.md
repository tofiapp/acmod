# CLAUDE.md

## Project

This repository holds two separate Lua apps for Assetto Corsa with Custom Shaders Patch (CSP) that share no code:
**MirrorDelta** (everything below up to the LedControl section) and **LedControl** (section at the end). Each has its
own tests and its own ZIP (`build.sh [MirrorDelta|LedControl]`). Do not change one app for the other.

MirrorDelta is a Lua app for Assetto Corsa with Custom Shaders Patch (CSP). It has several windows,
each with its own taskbar icon:

- **delta** (`MirrorDelta`): mini sector line, delta line, delta in seconds. Sits above the mirror.
- **timing** (`MirrorDelta Timing`): position, lap, current time, best lap.
- **tyres** (`MirrorDelta Tyres`): tyre core temperature (big number) and tread zones (inner/middle/outer). Colours from
  an optimal window per axle: `src/car_data.lua` reads tyres.ini `THERMAL_FRONT/REAR[_compoundIndex]` `PERFORMANCE_CURVE`
  via `ac.INIConfig.carData` + `:tryGetLut` (sections as CSP's shared/sim/cars.lua), grip >= 99.5 % of the best; else
  CSP's `tyreOptimumTemperature`, else `S.tyreOptimum`.
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
  CSP's OBS camera views (obs_integration.lua quality levels, `S.mirrorCamQuality`: 1 SimplifiedWithLights + SimplifiedYEBIS,
  looked dark and unlit in game; 2 default Main shaders + 'area' shadows + full YEBIS; 3 'dedicated' shadows + grass), from the
  markers' camera (`S.mirrorCamPos` 1 rear bumper = back of our aabb, end picked by transforming both ends, 0.5 m above its
  bottom, 5 cm behind; 2 the mirror position) with vertical FOV from `S.mirrorFov` (4:1), `S.mirrorCamHeight` / `S.mirrorCamPitch` (camera basis camF/camU
  shared with the projection), near plane past our own car, drawn mirrored (u reversed), so markers are exact (`M.exact`,
  offsets off); 6 the same camera without YEBIS: 11 MIPs + `mipsUpdate`, the shader takes exposure from the last MIP
  (average) then mode 1's gamma. Markers are not smoothed. Always cropped to the window's aspect via UVs or a clip rect, never stretched (`S.mirrorZoom`). Hiding AC's own
  virtual mirror / flags: no verified API; app windows titled like a mirror or flag are hidden via `ac.accessAppWindow`.
- **standings** (`MirrorDelta Standings`, `src/standings_window.lua`): bottom centre row replacing AC's F9 overlay leaderboard:
  player and neighbours by `racePosition`, names (3 letters / surname / none), gap to me or to the car ahead. Race gap
  modes: live (lapCount + splinePosition, `sim.trackLengthM`, player's speed) or a timing loop (`M.update(dt)` from
  script.update records every car's crossing time of `S.standingsSectors` checkpoints, interpolated in the frame; gap =
  difference at the last checkpoint both passed, every sector or only the line). Otherwise best lap difference.
- **gear** (`MirrorDelta Gear`): 12-segment RPM bar lighting from both edges to the centre (range up to the shift point
  from `src/car_data.lua`: ai.ini `[GEARS] UP` as CSP's RGBControl/led_colors use it, else `car.rpmLimiter`; also the delta
  window's blue blink), gear on a rounded tile coloured by revs (white/yellow/red, blinking blue at the limiter),
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
build.sh / build.ps1      one ZIP per app: dist/<App>-<version>.zip with apps/lua/<App>/... (no argument = both)
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
  delta in that mode (the delta only; mini sectors without a usable reference, i.e. the out lap, the first lap and the
  stretch before the previous out lap's anchor, are coloured by AC's delta change, else by `anyRef()`: session best,
  all-time best, estimate, provisional). The out lap's partial grid becomes the previous lap with an anchor (`prevLapAnchor`, first
  recorded u); `ownDelta` compares an out-lap reference directly (its grid holds AC's raw out-lap timer, pit lane included, so the delta at the line equals the lap time difference), no delta before the anchor, sectors before it neutral. Keep `updateInner` under LuaJIT's
  60-upvalue limit (move new logic into helper functions).
- Pit lane (`car.isInPitlane`): `src/pit_lights.lua` gives a brightness 0..1 per place on the delta line and per mini
  sector (`S.pitStyle`: 1 scanner, 2 waves from the centre, 3 breathing, 4 halves in turn with `S.pitSectorPattern`),
  colour `S.pitColor` (blue default, orange, white, yellow); the timing window shows BOX in that colour (`S.pitBox`).
  MirrorDelta does not touch the car's LEDs or lights (the pit LED / headlight blinking was removed in 1.28.0,
  LedControl does that).
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
pip install lupa && ./run_tests                 # both suites (LuaJIT 2.1 via lupa); ./run_tests LedControl for one
python tests/run_tests.py                       # MirrorDelta: syntax check of all Lua files + simulated laps
python tests/ledcontrol/run_tests.py [name]     # LedControl: own mock (scene, shared materials, AC LED writer)
./build.sh [MirrorDelta|LedControl]             # or build.ps1 on Windows; runs the app's tests first, no ZIP if red
```

## Defaults the user chose

Delta layout B (sectors top, line middle, number bottom), 24 sectors in 3 groups, line 9.5 px, gap 12 px,
number 30 px, opacity 100 %, intensity off. Timing side by side, best lap purple frame, lap flash on.
Tyres style 1 (big core numbers + zone bar); style 2 = core number + tyre + three zone numbers.
Gear: rounded style, speed on a dark bar as wide as the gear tile, speed step 3 km/h, font Unbounded.

## LedControl (second, separate app)

`apps/lua/LedControl/` takes over the LEDs of the player's steering wheel / dash (and, tab Světla, the car's lights).
Research: `docs/ledcontrol-research.md`, plan and data model: `docs/ledcontrol-plan.md`. One window (`LedControl`,
`FUNCTION_MAIN = windowMain`), `LAZY = NONE`, `[SIM_CALLBACKS] FRAME_BEGIN = frameBegin`. User-facing docs: Czech
`apps/lua/LedControl/README.md`.

```
apps/lua/LedControl/
  src/csp.lua             the adapter: the only file that reads the CSP globals (see below)
  LedControl.lua          entry: script.update / frameBegin / windowMain under the error boundary, ac.onRelease,
                          ac.onSessionStart, render.on('main.root.transparent'), hotkey handlers
  src/config.lua          ac.storage 'lc_' -> plain S (master, method, intensity, testMode, defaultPreset, hiddenGuard)
  src/store.lua           ScriptConfig files car_<carId>.lon (method, preset, map, lights) and presets.lon, sanitised
  src/safety.lua          error boundary: first error -> restorers (runtime.halt) + message; UI errors kept apart
  src/car_info.lua        once per car: digital_instruments [LED_n] dump (RPM_SWITCH), CSP [EMISSIVE_*] INPUT=RPM,
                          generator '@' lines, ai.ini [GEARS] UP, car.ini FUEL_LIGHT_MIN_LITERS
  src/car_state.lua       ST, scalars per frame; optional car/sim fields probed once under pcall
  src/detect.lua          layout: sources digital_instruments + csp_rpm, else actsAsLED, else ?LED?/?RPM?/?SHIFT?
                          (LOD A); every mesh of a name = instance; checks radius <= 6 cm, <= 1.8 m from the eyes,
                          visible; order = bounding sphere centre through the live node chain on car.side (left sign
                          from wheels[0]-wheels[1]); groups = single-linkage clusters (threshold 2.5 x median spacing,
                          >= 1.5 cm), main = biggest, Levé / Pravé / Další řada; manual map overrides; listMeshes()
  src/takeover.lua        brightness M.intensity set by runtime (manual or auto by time of day); emissiveOf() pushes
                          weaker channels down above 12 (config colourGuard) so hues stay true; the only module that
                          changes LED meshes: 1 shadow copy (createMesh of getVertices /
                          getIndices in the original's parent, assignMaterialFrom + ensureUniqueMaterials, original
                          hidden), 2 redraw (render.mesh, grow 8 % x live chain x 3 mm lift), 3 direct ksEmissive
                          (materials split only when shared, re-assert in frameBegin when AC writes back); fallback
                          1 -> 2 -> 3; change-only set(i, packed); guard every 0.5 s (re-shows, AC writes); self-heal
                          marker hiddenGuard written before hiding, cleared only by the run that wrote it; frameBegin
                          re-hides an original the game showed again (A), re-asserts LEDs AC lights by RPM (C, per
                          LED it.fight, not in the frame it was written), remembers shown instances (B draws while
                          shown within 1 s); render check in draw3D (every 15 frames, read-back once a second, every
                          15 frames after a lost one): 2 lost in a row switch to B (max 3 switches). Proven against
                          tests/ledcontrol/jammer.lua in test_jammer.lua (part A: red on the limiter with A, B, C)
  src/color.lua           packed 0xRRGGBB, ORIGINAL = -1 (car's own logic), OFF = 0, hsv, mix, parse '#RRGGBB'
  src/patterns.lua        compiled looks: solid, blink, alternate, pulse, run, fill (left/right/edges/centre, zones,
                          car thresholds), frames ('.' transparent, '0' off, '1'..'9' palette; nearest-centre rescale),
                          rainbow, off, original; UNSET = transparent (falls through)
  src/conditions.lua      custom condition quantities / operators, compile, eval (no allocation), Czech describe
  src/scenarios.lua       catalogue (order = default priority) with test / value / avail / param / hold; pure
                          default colours (a small second channel turns green turquoise once the main one saturates)
  src/rpm.lua             per car RPM range (profile.rpm): limiter learned from AC's isEngineLimiterOn (rising edge at
                          high RPM; a flag on at low RPM = unreliable, ignored), else car.rpmLimiter; shift point =
                          ai.ini UP only below 97 % of the limiter, else 97 %; manual start / shift / limiter and RPM
                          per main-row LED; writes ST.shiftUp, ST.shiftStartManual, ST.limiterRpm, ST.limiterKnown
  src/presets.lua         built-ins F1 styl, GT3 styl, Minimální (relative), edited in place (overlay p.edits saved as
                          builtinEdits, resetBuiltin; no hidden copies since 0.4.0); user presets sparse ('from'
                          built-in); animations = library of named looks per catalogue scenario (anims, presets ticked
                          in anim.presets, one per scenario and preset, a look edit goes into it or makes one;
                          look order catalogue <- built-in <- own entry <- animation); move, custom scenarios (per
                          preset), export "LEDCONTROL-PRESET 1 " + JSON (animation looks baked in), import via
                          JSON.parse + sanitise
  src/engine.lua          compile(preset, layout, ST) -> per group candidate lists; step(): scenario tests once with
                          hold / Test timers, per group highest priority active scenario paints, UNSET falls through,
                          rest = preset base ('off' / 'original')
  src/runtime.lua         states wait -> run | off | noleds | failed; restart on session, car change, method, map;
                          noleds searches again (every 2 s for 30 s, then 10 s; a slow track loads the model late);
                          per frame car_state.fill -> engine.step or a test pattern -> takeover.set (hover blink only
                          on the car, never in fb); preset per car; lights.update while the master switch is on
  src/lights.lua          lights (tab Světla): outputs rain / headlights / hazards / flash (real controls via
                          ac.setHeadlights, setHighBeams, setTurningLights, overrideCarControls().headlightsFlash,
                          simulateCustomHotkeyPress('__EXT_LIGHT_x') as Unbound) and brake / backlight (visual);
                          per output the highest active scenario wins; commands only on change, >= 0.25 s apart,
                          read back, 2 retries; driver change = scenario lets go; the driver's state is given back;
                          held states in lcl_realGuard (healed at init), LED-only restarts keep held lights, nothing
                          commanded while paused, replay parks; scenario settings global (ac.storage 'lcl_', saves
                          deferred 0.5 s), rain mode / meshes / cabin light per car in profile.lights
  src/light_meshes.lua    shadow copies of light meshes (same approach as takeover), marker lcl_meshGuard
  src/display.lua         display takeover (tab Displej): [SCRIPTABLE_DISPLAY_*] from the CSP car config (MESHES,
                          RESOLUTION, DISPLAY_POS, DISPLAY_SIZE), shadow copy of the display meshes, original hidden
                          (marker displayGuard, cleared only by the run that wrote it), copy:setMaterialTexture(slot,
                          { textureSize, background, region, callback }) (SDK lib_scene; CSP traffic tool); virtual
                          LED row = engine on a 12 cell layout with the car's preset; overlays from catalogue scenario
                          tests; at most S.displayHz paints, only when the fingerprint of the shown values changed;
                          profile.display { on, which, page, slot (nil auto = txDiffuse + txEmissive when the material
                          has it, 'txDiffuse', 'txEmissive'), regionMode (nil = mesh UVs via getVertices():get(k).uv
                          bounding box, 'config'), rotation (0/90/180/270 clockwise: ui.beginRotation +
                          endPivotRotation(90 - r, pivot) as dash_display_8100), aspect (width / height as seen; nil =
                          from getLocalAABB: x / sqrt(dy^2 + dz^2)) -> pageBox(i): laid out in W x W / aspect and
                          stretched by ui.beginScale + endPivotScale(vec2(1, sy), 0) onto the region (a square
                          texture on a wide screen), adjust = { [i] = { x, y, w, h } } };
                          M.calibrate (not saved) paints a grid over the whole texture with the region outlined
                          (display_pages.calibration); describe(i) = shader / slots / painted / glow / region; a mesh whose
                          getVertices is nil is painted directly (ensureUniqueMaterials, getTextureSlotFilename kept
                          and set back on release); design settings S.display* (theme / own colours, font, rounding,
                          brightness, LED row, zones of Vlastní, units) -> display_pages.setStyle via applyStyle;
                          the tab saves sliders / pickers once they rest (config.setLive / flushLive); glow = the
                          material's own ksEmissive (read at take; 0 -> 1 so the page glows, UNSURE) x S.displayGlow x
                          night factor, written on change;
                          a region change retakes (nothing stale outside the region); direct release restores the
                          slot filename, else one empty paint with background nil
  src/display_pages.lua   pages Závod / Otáčky / Kola / Vlastní + OVERLAYS, THEMES, FONTS, FIELDS; arrangement by
                          shapeOf(W, H): 'wide' (W >= 2.4 H, a strip), 'tall' (H > 1.1 W), 'normal'; text scale and
                          margin from the style; labels at most half of their value; text fitted with measureDWriteText
                          (width + height per string cached), placed by hand and drawn with ui.dwriteDrawText (no clip
                          rect: endPivotScale / endPivotRotation move vertices but not clip rects, so clipped text was
                          cut away on the stretched display) / drawRectFilled; also the tab preview
  src/online.lua          online state, banner and the optional block of real controls online
  src/hotkeys.lua         ac.ControlButton master / next preset / flash, polled in script.update
  src/diag.lua            "Kopírovat diagnostiku" text
  src/selftest.lua        Self-test (Diody → Diagnostika): every scenario of the preset forced alone (engine C.solo +
                          Test) for 2 s, LEDs of the groups it wins read back in the render pass (takeover.readback:
                          copy / material, original hidden; B unreadable = SKIP), then every display page and overlay
                          (paints counted); protocol OK / FAIL / SKIP with LedControl / LuaJIT / CSP versions, copied
                          with ac.setClipboardText; called from LedControl.lua update + render callback
  src/ui/kit.lua          UI building blocks (label column, (?) help, sections, choice, dot, colour + safe quick picks);
                          the design rules are docs/ledcontrol-ui.md; tests/ledcontrol/dump_ui.py prints a tab as text
  src/ui/main.lua         header (master, status, preset combo, errors, online / test pattern notes) + tabs loaded
                          lazily under pcall; src/ui/common.lua note() = coloured text that wraps (textColored does not)
  src/ui/tab_leds.lua     Diody: preview, brightness (Noc / Den / Slunce, Auto), test patterns; collapsed sections
                          Pořadí a skupiny (led_map.lua), Způsob převzetí, Diagnostika; tab_rpm.lua (Otáčky: live bar,
                          Auto / manual start, shift, limiter, learned limiter, RPM per LED), tab_scenarios.lua,
                          tab_editor.lua, tab_lights.lua, tab_display.lua (Displej), tab_settings.lua
tests/ledcontrol/         mock_csp.lua (scene graph, shared materials, AC LED writer, write log per material / mesh
                          with writer + frame, redundant app writes counted, JSON, ui), jammer.lua (the game fighting the
                          app: every frame, after N, limiter blink by visibility, by material name before the picture,
                          LOD switch, session reset), fake_csp.lua (fake adapter), sdk_signatures.txt, helpers.lua (test
                          cars: formula 15+3+3 with HR/LR/LOD B instances, GT3 10 LEDs one material, actsAsLED, names,
                          empty, display texture, two displays; seenLed / ledMatches), test_*.lua each in its own
                          LuaJIT runtime; test_timeline (a drive: pits with / without limiter, flags, limiter, fuel,
                          ABS / TC, reset to pits, session restart, LOD switch, init orders; winner per group, colours,
                          takeover vs jammer, restore), test_perf (writes / allocation per frame), test_storage,
                          test_display (fake canvas: every page / overlay at 800x480, 480x272, 512x512 inside the
                          screen, dumped to tests/output/display, PNGs by tools/render_display.py from run_tests.py)
```

Adapter: `src/csp.lua` is the only LedControl file that reads the CSP globals (ac, ui, render, io, os, JSON, stringify,
vec2/vec3/rgb/rgbm/mat4x4, script, bit); every other module binds them at its top
(`local csp = require('src/csp')` + `local ac, ui = csp.ac, csp.ui`). The tests serve the fake adapter
(tests/ledcontrol/fake_csp.lua over mock_csp.lua) and load every other module in an environment without these globals
(helpers.lua), test_adapter.lua scans the sources statically. Every API name the app uses must be listed in
tests/ledcontrol/sdk_signatures.txt (definition in acc-lua-sdk, or a call in official CSP code for C++-bound names),
regenerated with `python3 -I tests/ledcontrol/tools/sdk_signatures.py <acc-lua-sdk> <official code dirs>`; run_tests.py
fails on an unlisted name. CSP runs OpenResty's LuaJIT 2.1 fork with 5.2 compatibility (acc-lua-sdk README); the tests
run stock LuaJIT 2.1 from lupa (no 5.2 compat), so avoid code whose meaning differs between the two (__len / __pairs on
tables, table.pack / unpack, goto).

Rules as for MirrorDelta: no per-frame allocation (every test file ends with an allocation check: window open, its
tab drawn, < 4 KB over 300 frames), no invented CSP API (evidence in docs/ledcontrol-plan.md section 12; calls only seen
in internal code are probed under pcall), UI Czech, code English. Lua pitfalls already hit here: `ipairs` stops at the
first nil (presets.effective), `a and nil or b` is always b.
