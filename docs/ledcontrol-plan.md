# LedControl: implementation plan (phase 2)

Synthesis of three independent proposals (data-model-first, runtime-robustness-first, user-workflow-first) and the
research in `docs/ledcontrol-research.md`. Every CSP call listed in section 12 was found in the local SDK clone or in
official code; calls seen only outside apps run behind a probe with a fallback.

## 1. Goals and rules

- Take over the player's car LEDs (wheel, dash) and, separately, its other lights; configure everything in one window
  with five tabs (Diody, Scénáře, Editor, Světla, Nastavení). Czech UI, English code.
- Only the player's car. LED and visual light changes are local; real light controls (headlights, flash, hazards,
  extra switches) are the car's real state and the UI says other drivers see them online.
- Every exit path (master switch, scenario off, session/car change, error, app reload or unload) gives the car its
  original look back.
- Materials change only on a state change; no allocation in the frame loop (strings, tables, vectors are reused).
- MirrorDelta is not touched; LedControl has its own tests and its own ZIP.

## 2. Files

```
apps/lua/LedControl/
  manifest.ini          [ABOUT] NAME=LedControl, VERSION; [CORE] LAZY = NONE; [SIM_CALLBACKS] FRAME_BEGIN = frameBegin;
                        one window WINDOW_... ID=main, FUNCTION_MAIN=windowMain, FLAGS=SETTINGS-less, own icon
  LedControl.lua        entry: requires modules, script.update / script.frameBegin / script.windowMain under the error
                        boundary, ac.onRelease, ac.onSessionStart (sets a flag only)
  icon.png
  src/config.lua        global settings (ac.storage) copied into a plain table S; config.set() only
  src/store.lua         ScriptConfig files: cars/<carId>.lon (car profile), presets.lon (user presets), lights.lon;
                        stringify / stringify.tryParse, validation + sanitising, version field v = 1, migrations;
                        export / import text (JSON envelope)
  src/safety.lua        error boundary: on the first error release every scene change, keep the error + traceback,
                        stop the app's scene work until the user presses "Zkusit znovu"; self-heal on start
  src/car_state.lua     one plain table ST filled per frame from ac.getCar(0) / ac.getSim() (scalars only)
  src/car_info.lua      per car, once: car id, ai.ini [GEARS] UP/DOWN, car.rpmLimiter, car.ini FUEL_LIGHT_MIN_LITERS,
                        raw dump of every [LED_n] section and of CSP [EMISSIVE_*] INPUT=RPM sections
  src/detect.lua        LED layout of the car (sources, instances, positions, order, groups, signature, warnings)
  src/takeover.lua      the only module that changes the scene: writers over items (LEDs or light meshes) with the
                        three methods shadow / redraw / direct, change-only writes, restore
  src/color.lua         hex <-> packed int, cached per string; packed compare for change detection
  src/patterns.lua      pure maths: compile a look for a group of n LEDs, evaluate a packed colour per LED
  src/conditions.lua    quantity registry for the condition builder, compile to numeric arrays, evaluate without
                        allocation, Czech description
  src/scenarios.lua     catalogue of built-in LED and light scenarios (id, Czech name, availability, default look,
                        state test with hysteresis/timers)
  src/presets.lua       built-in relative presets (F1 styl, GT3 styl, Minimální), user presets, copy-on-write when a
                        built-in one is edited, preset per car, cycling, layout check / rescale of frame looks
  src/runtime.lua       lifecycle state machine and the LED frame loop (per-group priority, packed colours)
  src/lights.lua        light channels the car has, real controls and visual light items, light scenarios
  src/online.lua        online state, onlineExtras dump, per-feature blocks with a Czech reason
  src/hotkeys.lua       ac.ControlButton master / next preset / flash, polled in script.update
  src/ui/main.lua       header (master switch, preset, car + status line, error bar, online badge) + ui.tabBar
  src/ui/common.lua     reused vec2/rgbm, cached strings, LED strip preview, colour cell, scenario row
  src/ui/tab_leds.lua, tab_scenarios.lua, tab_editor.lua, tab_lights.lua, tab_settings.lua
  README.md             Czech (phase 7)
tests/ledcontrol/run_tests.py, mock_csp.lua, test_ledcontrol.lua    own mock and suite (lupa + LuaJIT)
build.sh / build.ps1    one ZIP per app: dist/<App>-<version>.zip with only apps/lua/<App>/...; no argument = both
```

## 3. Data model

All stored tables carry `v = 1`; stored text is parsed with `stringify.tryParse` (own files) or `JSON.parse`
(imports), never executed, then sanitised (types, ranges, max sizes).

**Layout** (runtime, built by detect each load):
```lua
Layout = {
  carId = 'ks_ferrari_sf15t', source = 'digital_instruments' | 'csp_emissive' | 'acts_as_led' | 'names' | 'manual',
  leds = {   -- left to right inside each group
    { id = 1, name = 'LED_0', group = 1, rpm = 10500 or nil, pos = vec3(...),         -- car space, wheel straight
      ini = { OBJECT_NAME = {...}, ... },                                              -- raw [LED_n] keys (PoC dump)
      instances = { { ref = <mesh>, parent = <node>, node = 'STEER_HR', lod = 'A' }, { ... 'STEER_LR' ... } } },
  },
  groups = { { name = 'Horní řada', role = 'main', leds = {1..15} }, { name = 'Levé', role = 'side', leds = {16,17,18} } },
  signature = '15+3',  warnings = { 'Pořadí změřeno s natočeným volantem' },
}
```
Roles: `main` (RPM row), `side` (flags, warnings), `other` (only scenarios that target it). A scenario aimed at `side`
on a car without side groups falls back to `main`.

**Car profile** `cars/<carId>.lon`:
```lua
{ v = 1, carId = '...', method = 'shadow' | 'redraw' | 'direct', intensity = 25, preset = 'builtin:f1',
  map = nil | { leds = { { 'LED_4', 1 }, { 'SIDE_L1', 2 } }, groups = { { 'Horní řada', 'main' }, { 'Levé', 'side' } } },
  lights = { rain = { mode = 'switch', switch = 1 } | { mode = 'mesh', meshes = { 'RAINLIGHT' } },
             dash = { meshes = { 'DASH_BL' }, cabinLight = true, offset = { 0, -0.25, 0.45 } } } }
```
`map` is nil for automatic detection; once the user reorders, regroups or maps by hand it holds mesh names in order.

**Preset** (built-ins are code; user presets in `presets.lon`): a complete LED setup. Missing scenario keys mean the
catalogue default (sparse overrides, so new built-in scenarios reach old presets).
```lua
{ v = 1, id = 'user:3', name = 'Moje F1', base = 'builtin:f1', layout = nil | '15+3',
  scenarios = {
    pitLimiter = { on = true, prio = 1, to = 'all',  look = { p = 'alternate', c = { '#FF8C00', '#0040FF' }, hz = 3 } },
    flagBlue   = { on = true, prio = 3, to = 'side', look = { p = 'blink', c = { '#0050FF' }, hz = 2 } },
    shift      = { on = true, prio = 11, to = 'main', look = { p = 'fill', dir = 'left' | 'edges', src = 'relative' | 'car',
                   from = 0.80, to = 0.995, zones = { 0, '#00FF00', 0.34, '#FF0000', 0.67, '#0050FF' } } },
    ['custom:1'] = { on = true, prio = 20, to = 'main', name = 'Pod 60 km/h a málo paliva',
                   when = { { q = 'speed', op = '<', v = 60 }, { q = 'fuel', op = '<', v = 5 } },   -- all rows must hold
                   look = { p = 'frames', fps = 4, rescale = true, palette = { '#000000', '#FF0000', '#FFFFFF' },
                            g = { [1] = { n = 15, f = { '111110000011111', '000001111100000' } } } } },
  } }
```
Looks: `p` = `solid | blink | alternate | pulse | run | fill | frames | off | original`; `c` colours; `hz` cycles per
second; `dir` left-to-right or edges-to-centre; `zones` colour a fill by relative rank `u = 0..1`; `src = 'car'` uses the
car's own per-LED RPM thresholds (when the dump confirms them), else the relative range of the shift point.
Relative looks work on any LED count. Frame looks store one string per group (one character per cell = palette index);
on another layout they are rescaled by nearest-centre sampling (symmetric frames stay symmetric) when `rescale = true`,
otherwise the scenario is switched off on that car with a Czech warning in Editor and Scénáře.

**Settings** (ac.storage): master switch, global brightness, default preset, hotkey ids, UI state. **Export**: one line
`LEDCONTROL-PRESET 1 ` + JSON of the preset; import validates, renames on id clash and reports what was dropped.

**Compile step**: whenever the preset, layout or settings change, `presets.compile()` flattens everything into
preallocated arrays per group: candidate scenarios sorted by priority, compiled conditions, compiled looks (colours as
packed ints, zone tables, rescaled frames). The frame loop only reads these arrays.

## 4. Runtime

State machine (runtime.lua): `BOOT -> HEAL -> WAIT_CAR -> DETECT -> RUN | NO_LEDS | FAILED`, restarted on session start,
car change (car id), replay start/stop, master switch, method change. `HEAL` un-hides every mesh listed in the
self-heal marker (`hiddenGuard` in ac.storage, written before hiding anything, cleared on a clean release), so a crash
or a reload never leaves the car without LEDs.

Per frame in `script.update`:
1. `car_state.fill()`: scalars only (speed, rpm, gear, limiter flags, pit, flags, drs, abs/tc in action, fuel, damage,
   session start time, rain, time of day, lights state).
2. Scenario tests: each catalogue scenario has a test function with hysteresis and timers in preallocated fields;
   custom scenarios run compiled condition rows. `Test` sets a timer that forces the scenario on for 5 s.
3. Per group: the highest-priority active scenario whose target includes the group wins; a look may leave cells
   `original` so they fall through to lower scenarios and finally to the car's own logic.
4. Patterns write one packed colour per LED (`-1` = original) into a preallocated framebuffer; a step key (blink phase,
   frame index, fill level) skips groups whose output cannot have changed.
5. takeover receives only the LEDs whose packed value changed.

`script.frameBegin` (manifest `[SIM_CALLBACKS] FRAME_BEGIN`, "right before scene has started rendering") is used only
by the direct method to re-assert colours after AC's own update. Hotkeys are polled in `script.update`, so they work with
the window closed.

## 5. LED takeover

Instances: every mesh found by an LED's name, in LOD A first and then any other copy (hi-res and low-res cockpit and
steering wheel). All instances of one LED get the same colour.

**A. Shadow copy (default).** Per instance: `v = ref:getVertices()`, `ix = ref:getIndices()`,
`copy = parent:createMesh('__ledcontrol_<led>_<i>', nil, v, ix, false, true)`, `copy:assignMaterialFrom(ref)
:ensureUniqueMaterials()`. A taken LED shows the copy (`ref:setVisible(false)`, `copy:setVisible(true)`); an LED in
state `original` swaps back, so the car's own logic shows through untouched. Colour = `ksEmissive` on the copy, set
only on change (off = black emissive, i.e. the unlit LED texture). Copies live in the original's parent node, so they
follow the steering wheel and the cockpit LOD switch. A guard checks every 0.5 s that hidden originals stay hidden and
counts re-shows (shown in Diagnostika). Release: originals visible, copies hidden (kept for reuse, removed by CSP on
script reload since keepAlive = false).

**B. Redraw.** Lit LEDs are drawn again in `render.on('main.root.transparent')` with
`render.mesh{ mesh = ref, transform = m }`, where `m` = grow 8 % about the mesh centre × live node chain × 3 mm towards
the camera (MirrorDelta's proven setup), `'original'` transform as a second try; OpaqueForced, LessEqual depth, colour ×
`gWhiteRefPoint`. Nothing in the scene is changed; it draws every frame (no change-only saving) and glass over the LED
can tint it.

**C. Direct.** `ensureUniqueMaterials()` on every single instance reference, so LEDs that shared one material no longer
share it; then `setMaterialProperty('ksEmissive', rgb)`. A fight sampler reads the value back with
`getMaterialPropertyValue` a few frames after a write; if AC changed it, the writer re-asserts it every frame in
`frameBegin` (and says so in Diagnostika). Release: stop writing; AC takes the LED over again.

The method is chosen per car (profile), with a fallback order A -> B -> C when a call fails; the reason is shown.

## 6. Detection

Sources, merged in this order: saved manual map; `digital_instruments.ini [LED_0..63] OBJECT_NAME` via
`ac.INIConfig.carData` (also from data.acd); CSP config `[EMISSIVE_*]` with `INPUT = RPM` (`NAME` meshes,
`INPUT_THRESHOLD` = car threshold) via `ac.INIConfig.carConfig(0).sections`; `{ actsAsLED:yes }`; cockpit meshes named
`?LED?`, `?RPM?`, `?SHIFT?`. Candidates are checked (bounding radius ≤ 6 cm, ≤ 1.8 m from the eyes, visible unless all are
hidden = inactive LOD) and the rejected ones listed with the reason. Order: the bounding-sphere centre through the live
node chain, in car space (`car.worldToLocal`), sorted along the car's side axis; a measurement with the wheel turned is
flagged. Groups: automatic split into rows by height and into left/right columns at the sides, then editable. Manual
mapping lists the car's LOD A meshes (name, material, radius) with a filter box; the user ticks meshes and orders them.

## 7. Lights (tab Světla)

Only what the car has, from `car.headlightsAreHeadlights`, `hasLowBeams`, `hasFlashingLights`, `hasTurningLights`,
`ac.isExtraSwitchAvailable(i)` + `ac.getExtraSwitchName(i)` (role names such as a rain light), brake light meshes
`{ actsAsBrakeLights:yes & lod:A }`, CSP `[EMISSIVE_*]` light sections.
- Real controls (Unbound calls): `ac.setHeadlights`, `ac.setHighBeams`, flash `ac.overrideCarControls().headlightsFlash`,
  hazards `ac.setTurningLights(ac.TurningLights.Hazards)`, extra switches `ac.simulateCustomHotkeyPress('__EXT_LIGHT_A')`.
  Commands only on change, at least 0.25 s apart, verified by reading the state back; the state before the scenario is
  remembered and put back.
- Visual items: the same takeover writers on light meshes (rain light meshes, brake light meshes, user-picked dash
  meshes): colour, intensity, blinking.
- Rain light: per car `switch` (toggle the extra switch, real state) or `mesh` (visual copy).
- Backlight: `ac.LightSource(ac.LightType.Regular)` placed in the cabin (offset from the eyes, colour by scenario,
  disposed on release) and/or user-picked dash meshes recoloured.
- Brake lights blinking under hard braking: visual copy of the brake light meshes; `ac.setBrakingLightsThreshold` is
  seen only in CSP internal modes, so it is probed and used only if available.
Default light scenarios: rain light blinks with pit limiter, hazards when stopped on track, lights on at dusk or in
rain, brake lights blink under hard braking, backlight colour by scenario, flash on a hotkey. Same priority and Test.

## 8. UI

- Header: master switch, preset combo, car + LED count + method, current scenario per group, error bar, online badge.
- Diody: LED strip preview from the framebuffer in real order (per group), source and rejected candidates, method
  radio (A/B/C) with Diagnostika (instances, materials, re-shows, fights), intensity slider, order/group editor (move,
  assign group, reverse, split rows), manual mapping, test tools (single LED, rainbow, chase, all off).
- Scénáře: list by priority with on/off, priority arrows, target group role, pattern, colours, Hz, Test, availability
  badge (for example "nedostupné: AC tuto vlajku nehlásí"), custom scenario builder (quantity, comparison, value,
  add row; all rows must hold).
- Editor: preset row (new, copy, rename, delete), scenario picker, frame grid per group (click paints the palette
  colour), palette, frame strip (add, copy, delete, move), fps, layout warning with rescale option, Test na autě, Uložit.
- Světla: online banner, channels with live state and capabilities, rain light mode, mesh pickers, light scenarios.
- Nastavení: global brightness, hotkey bindings (`:control()`), default preset, export/import (clipboard), delete saved
  data (with an in-window confirmation), restore defaults.

## 9. Scenarios and state fields

| Scenario | Fields | Availability |
| --- | --- | --- |
| Pit limiter on | `car.manualPitsSpeedLimiterEnabled` | all |
| Pit lane without limiter | `car.isInPitlane` and not the above | all |
| Flags | `sim.raceFlagType` | blue, yellow, black (Stop), penalty (ReturnToPits), white, chequered: per SDK "works"; red (SessionSuspended), Code60 etc.: "does not work yet" → shown unavailable; online: live value shown |
| Rev limiter | `car.isEngineLimiterOn`, `car.rpm >= car.rpmLimiter` | all |
| Shift point | `ai.ini [GEARS] UP`, `car.rpm` | when ai.ini has it |
| Shift lights | `car.rpm`, car thresholds or relative range | all |
| DRS available / active | `car.drsPresent`, `drsAvailable`, `drsActive` | cars with DRS |
| ABS / TC intervention | `car.absInAction`, `car.tractionControlInAction` | cars with ABS / TC |
| Low fuel | `car.fuel` vs `FUEL_LIGHT_MIN_LITERS` or a set value | all |
| Damage | `car.engineLifeLeft`, `car.damage[0..3]` | all |
| Start countdown | `sim.timeToSessionStart`, `sim.isSessionStarted` | race start |
| Standing / engine off | `car.speedKmh`, `car.rpm < car.rpmMinimum` | all |
| Custom | quantities: speed, rpm, gear, fuel, gas, brake, rain, time of day, lap, position, in pit lane, limiter, DRS, ABS/TC in action | all |

## 10. Testing

`tests/ledcontrol/` with its own mock: a scene graph (nodes with local matrices, meshes with vertices, shared
materials, visibility), an AC LED driver that rewrites ksEmissive every frame (to prove the takeover wins), INI data
(digital_instruments, CSP config, ai.ini, car.ini), car/sim state, render callbacks, storage. Tests: detection from each
source and merging, LOD/HR/LR instances, shared materials split, order and groups, each takeover method + restore on
every exit path + self-heal, priority per group, every pattern on several LED counts, frame rescaling, condition
builder, presets (sparse overrides, copy-on-write, export/import round trip, bad input), lights state machines,
online blocks, zero allocation in the frame loop. `tests/run_tests.py` (MirrorDelta) stays as it is.

## 11. Build

`build.sh [MirrorDelta|LedControl]` and `build.ps1` the same: one ZIP per app, `dist/<App>-<version>.zip`, version from
the app's manifest, containing only `apps/lua/<App>/...`. Without arguments both are built; MirrorDelta's ZIP stays
byte-for-byte the same layout as now.

## 12. CSP API used (evidence)

| Call | Evidence | Status |
| --- | --- | --- |
| `[CORE] LAZY = NONE`, `script.update` runs with windows closed | sdk wiki Lua-apps.md | verified |
| `[SIM_CALLBACKS] FRAME_BEGIN` | sdk wiki Lua-apps.md | verified (docs) |
| `ac.findNodes('carRoot:0')`, `:findMeshes(filter)`, `lod:A`, `actsAsLED`, `actsAsBrakeLights` | lib_scene.lua:264; Radar.lua:121; show_important_wheels.lua:2 | verified |
| `:getVertices()`, `:getIndices()` | lib_scene.lua:357,366; android_auto/apps/web/app.lua:23 | verified (internal car script) |
| `:createMesh(name, mat, v, ix, keepAlive, moveData)` | lib_scene.lua:318 | SDK only, no official caller → PoC |
| `:assignMaterialFrom`, `:ensureUniqueMaterials`, `:setVisible`, `:isVisible` | lib_scene.lua:954,230,466,701 | verified |
| `:setMaterialProperty('ksEmissive', rgb)`, `:getMaterialPropertyValue` | lib_scene.lua:154,872; TrafficLightEmissive.lua | verified |
| `:boundingSphere`, `:getParent`, `:getTransformationRaw`, `:at`, `:name` | lib_scene.lua:904,630,574,982,687 | verified |
| `render.on('main.root.transparent')`, `render.mesh`, `render.setBlendMode/DepthMode/CullMode` | CspDebug.lua:860-868; Radar.lua:102-108 | verified |
| `ac.INIConfig.carData` (data.acd), `carConfig(0).sections`, `onlineExtras()` | ac_extras_ini.lua:47-61,89,105 | verified |
| car fields in section 9, `car.worldToLocal`, `car.driverEyesPosition` | RGBControl conditions.lua, Unbound.lua, driver_shift.lua | verified |
| `ac.setHeadlights`, `ac.setHighBeams`, `ac.setTurningLights`, `ac.overrideCarControls().headlightsFlash` | Unbound.lua:147,175,193,207 | verified |
| `ac.isExtraSwitchAvailable`, `ac.getExtraSwitchName`, `ac.accessExtraSwitchParams`, `ac.simulateCustomHotkeyPress` | Unbound.lua:14,258-266 | verified |
| `ac.setBrakingLightsThreshold` | showroom_previews.lua, driver-interview mode | internal only → probe |
| `ac.LightSource(ac.LightType.Regular)` | ac_light.lua:56; Flashlight.lua:16 | verified |
| `ac.ControlButton(id)`, `:pressed()`, `:control()` | ac_extras_binaryinput.lua:14,107,164; TimeShift.lua | verified |
| `ac.storage`, `stringify`, `JSON`, `io.*` + `ac.getFolder(ac.FolderID.ScriptConfig)` | ac_storage.d.lua; RGBControl saving.lua | verified |
| `ui.tabBar/tabItem`, `ui.colorPicker/colorButton`, `ui.setClipboardText/getClipboardText` | CarMirrorsConfigurator; Flashlight; Voice.lua | verified |
| `ac.onRelease`, `ac.onSessionStart` | Unbound.lua:156,281 | verified |

## 13. Phase 3 proof of concept

Contents: manifest + entry, config/store minimal, safety + self-heal, car_info dump, detect (all sources, instances,
order, auto groups), takeover with all three methods and a switch, tab Diody only: LED list in order with group and
source, rejected candidates, method radio, per-LED test (click an LED, pick a colour), rainbow, chase, all off,
"původní stav", Diagnostika (raw `[LED_n]` keys, CSP RPM sections, instances per LED, materials before/after split,
re-show and fight counters), "Kopírovat diagnostiku" to the clipboard. Master switch restores everything. Tests for
the PoC parts.

In-game checklist (formula + GT3):
1. Diody shows the right LED count and order; note anything wrong.
2. Method A: rainbow and single-LED colours, each LED alone, no other LED changes, no flicker at revs; turn the wheel
   (lights follow); switch cockpit LOD/camera; master off → car looks exactly as before.
3. Same with B and C; note which one looks right on each car.
4. Copy the diagnostics of both cars and send them.

## 14. Risks and open points

- `createMesh` has no official caller; if copies do not render or crash, method B/C remain.
- Keys inside `[LED_n]` besides OBJECT_NAME are unknown until the PoC dump; car thresholds are used only once seen.
- Whether `carConfig()` returns CSP generator lines (`@ = DashIndicator, Input = RPM`) expanded is unknown (PoC dump).
- LEDs drawn by CSP scriptable displays or textures are not meshes; manual mapping cannot fix those.
- Online flag behaviour is undocumented; the UI shows the live value.
- `ac.setBrakingLightsThreshold` may be unavailable to apps; then brake light blinking is visual only.
