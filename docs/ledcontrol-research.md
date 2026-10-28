# LedControl: research (phase 1)

What a CSP Lua app can do for driving the player's car LEDs and lights, verified against the public SDK
(`ac-custom-shaders-patch/acc-lua-sdk`, local clone of 2026-08-17) and usage in official code (`app-csp-defaults`,
`acc-lua-internal`, `acc-extension-config`). The full generated API definitions ship only with CSP
(`extension/internal/lua-sdk`), so functions missing from the public SDK are accepted only when an official app or
internal script calls them; each such call is marked with where it was seen.

## 1. Finding the LEDs

| Source | How | Verified |
| --- | --- | --- |
| `digital_instruments.ini` `[LED_n] OBJECT_NAME` | `ac.INIConfig.carData(0, 'digital_instruments.ini')`, supports `data.acd` (SDK doc of `carData`) | SDK |
| CSP car config `[EMISSIVE_...] NAME=… INPUT=RPM INPUT_THRESHOLD=…` | `ac.INIConfig.carConfig(0).sections` (plain table) | SDK; example `smp_lada2108_t1600.ini` |
| CSP config generator `@ = DashIndicator, Input = RPM, InputThreshold = …` | same file; whether `carConfig()` returns generators expanded is unknown → PoC dumps it | `ks_ford_escort_mk1.ini` |
| Meshes CSP marks as LEDs | `root:findMeshes('{ actsAsLED:yes }')` | `show_important_wheels.lua` |
| Manual mapping | list cockpit meshes (`root:findMeshes('{ lod:A }')`, `:name(i)`), user picks | SDK |

- Root: `ac.findNodes('carRoot:0')` (Radar, RallyCopilot). Cockpit LOD: filter `& lod:A` (Radar). Hi-res and low-res
  cockpit / steering wheel (`COCKPIT_HR`/`COCKPIT_LR`, `STEER_HR`/`STEER_LR`) can both hold a copy of an LED: all copies
  found by name are kept as one LED.
- Note: CSP configs reuse `LED_x` meshes for other roles (e.g. `ks_porsche_911_rsr_2017`: `LED_3` = headlight
  indicator). A `[SCRIPTABLE_DISPLAY_...]` section does not mean the LEDs are scripted (`ks_ferrari_488_gt3` uses one
  for the digital mirror).
- Exact keys inside `[LED_n]` besides `OBJECT_NAME` (RPM threshold, colours, blinking) are not documented anywhere
  public; the PoC dumps every key of every `[LED_n]` of the real car instead of guessing.
- Position for left-to-right order: mesh `:boundingSphere()` (parent space) through the live local matrices up the
  node chain (`:getTransformationRaw()`, as CSP's `vr_rig_base.getActualTransform`), projected on the car's side axis.

## 2. Taking over the LEDs

AC (and CSP `[EMISSIVE_...]` configs) write the LED material's `ksEmissive` by RPM every frame. MirrorDelta tried
writing `ksEmissive` from `script.update` too and the two fought (visible flicker). There is no API to switch AC's
digital instrument LEDs off. Candidates, all from verified calls:

1. **Shadow copy (proposed main way).** For each LED mesh: `ref:getVertices()` + `ref:getIndices()` →
   `parentNode:createMesh(name, nil, vertices, indices)` (copy in the same node, so it follows the steering wheel and LOD
   switching), `copy:assignMaterialFrom(ref):ensureUniqueMaterials()` (own material per LED, so colouring one never
   colours another), original `ref:setVisible(false)`. AC keeps writing the hidden original; the copy's emissive is
   set only on a state change. Back to the original: `setVisible(true)` on the original, copy hidden/disposed; also
   on `ac.onRelease`. `createMesh` is in the SDK but no official script uses it → must be proven in the PoC.
2. **Redraw over the LED** (`render.mesh{ mesh = ref, transform = … }` in `render.on('main.root.transparent')`, as
   Radar draws brake light meshes): no fight, but it draws every frame and has depth / glass issues.
3. **Direct material write** with `ensureUniqueMaterials()` per LED: cheapest, but likely fights AC again.

Original colours can be read back with `ref:getMaterialPropertyValue(index, 'ksEmissive')` (SDK).

## 3. Car and session state (scenarios)

| Scenario | Field | Seen in |
| --- | --- | --- |
| Pit limiter | `car.manualPitsSpeedLimiterEnabled`, `car.isInPitlane` | Unbound, RGBControl |
| Rev limiter | `car.isEngineLimiterOn`, `car.rpm`, `car.rpmLimiter` | RGBControl |
| Shift point | `ai.ini [GEARS] UP` | RGBControl `data.lua` |
| Flags | `sim.raceFlagType` vs `ac.FlagType` | SDK enum + RGBControl |
| DRS | `car.drsPresent`, `car.drsAvailable`, `car.drsActive` | RGBControl |
| ABS / TC working | `car.absInAction`, `car.tractionControlInAction` | RGBControl |
| Fuel | `car.fuel`, warning `car.ini [GRAPHICS] FUEL_LIGHT_MIN_LITERS` | RGBControl |
| Damage | `car.engineLifeLeft`, `car.damage[0..3]` | RGBControl, MirrorDelta |
| Start countdown | `sim.timeToSessionStart`, `sim.isSessionStarted` | RGBControl |
| Engine off / standing | `car.rpm < car.rpmMinimum`, `car.speedKmh` | `stalling.lua` |
| Rain / darkness | `sim.rainIntensity`, `sim.rainWetness`, `sim.timeHours` | RGBControl |

Flags per the SDK enum comments: working `None, Start, Caution (yellow), Stop (black), ReturnToPits (penalty),
FasterCar (blue), Finished (chequered), OneLapLeft (white)`; not working `Slippery, PitLaneClosed, SlowVehicle,
Ambulance, MechanicalFailure, Unsportsmanlike, StopCancel, SessionSuspended (red), Code60`. Online behaviour of each
flag is not documented → the app shows the live raw value.

## 4. Other lights

Real controls (the car's actual state, other drivers see it online):
- headlights `ac.setHeadlights(bool)`, high beams `ac.setHighBeams(bool)`, hazards `ac.setTurningLights(ac.TurningLights.Hazards)`,
  flash `ac.overrideCarControls().headlightsFlash = true` (all Unbound);
- extra switches (rain light on many F1 mods): `ac.isExtraSwitchAvailable(i)`, `ac.getExtraSwitchName(i)`,
  `ac.accessExtraSwitchParams(i)`, toggled with `ac.simulateCustomHotkeyPress('__EXT_LIGHT_A')` (Unbound); state
  `car.extraA..F`.
- brake light threshold `ac.setBrakingLightsThreshold(n)` is used only by internal modes / showroom; availability to
  apps unknown → probe under pcall.

Visual only (same shadow copy as the LEDs): meshes of CSP config `[EMISSIVE_*]` sections (brake, reverse, extra A–T,
rain light), brake light meshes `'{ actsAsBrakeLights:yes & lod:A }'` (Radar). Cabin / dash tint: an
`ac.LightSource(ac.LightType.Regular)` (Flashlight app) or user-picked meshes.

## 5. App frame

- Logic with the window closed: `manifest.ini [CORE] LAZY = NONE`; `script.update` runs every frame "after world
  matrix traversal", even with no window open (SDK wiki "Lua apps").
- Tabs: `ui.tabBar` / `ui.tabItem` (CarMirrorsConfigurator). Colours: `ui.colorPicker` / `ui.colorButton`.
- Hotkeys: `ac.ControlButton('__APP_LEDCONTROL_...')`, `:pressed()`, `:control(size)` draws the binding button
  (TimeShift, DynamicReturn).
- Storage: `ac.storage`; export/import as text with `stringify` / `JSON`; clipboard `ui.setClipboardText` /
  `ui.getClipboardText`.
- Online: no documented server switch for client visuals; `sim.isOnlineRace` + `ac.INIConfig.onlineExtras()` are
  readable, every risky call runs under pcall and its failure is shown with the reason.
