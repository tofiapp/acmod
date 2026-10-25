# KeyDrive – phase 1 research notes

Sources checked (October 2026):

- `ac-custom-shaders-patch/acc-lua-sdk` (`ac_joypad_assist.lua`, `common/ac_extras_binaryinput.lua`,
  `common/ac_extras_connect.lua`, `common/ac_extras_ini.lua`)
- `ac-custom-shaders-patch/acc-lua-internal/included-gamepad` (official Gamepad FX scripts shipped with CSP:
  Gamepad Force, Gyrosteer, Mobile)
- `adam10603/AC-Advanced-Gamepad-Assist` v1.5.5 (AGA) – studied only, no code copied
- `ac-custom-shaders-patch/acc-extension-config` wiki (`Misc – Server extra options`)

## Script type and location

- Gamepad FX scripts live in `extension/lua/joypad-assist/<Name>/` with `manifest.ini` (`[ABOUT] NAME, AUTHOR,
  VERSION, DESCRIPTION`) and `assist.lua` as the entry point. Optional `settings.ini` is the user settings file
  shown by Content Manager; it is read with `ac.INIConfig.scriptSettings():mapSection(section, defaults)`
  (official Gyrosteer / Gamepad Force).
- The script runs in the **physics thread** (`--[[? ctx.flags.physicsThread = true; ?]]` in the SDK), so
  `script.update(dt)` is called every physics step (`dt` ≈ 0.003 s). Globals: `car` (`ac.getCar(__carIndex)`),
  `sim`, `__carIndex`, `__gamepadIndex`.
- `require('src/x')` resolves relative to the script folder (official scripts use `require('modes/race')`).
- `ac.loadRenderThreadModule(name)` loads a second module running in the render thread; it can implement
  `script.drawUI()` and must call `ac.setDrawUIActive(true)` (official Mobile script). It cannot share Lua state
  with the physics module – data goes through `ac.connect`.

## Reading and writing inputs

`ac.getJoypadState()` returns a mutable struct; writing its fields changes what goes to physics. The struct is
generated from C++ and not in the public SDK. Fields confirmed from the official scripts and AGA:

| Field | Use |
| --- | --- |
| `gas`, `brake`, `clutch`, `handbrake` (0..1) | written by Mobile and AGA |
| `steer` (-1..1, normalised to full lock) | written by Gamepad Force, Mobile, AGA |
| `steerStickX` | raw stick |
| `gearUp`, `gearDown`, `requestedGearIndex`, `absUp/Down`, `tcUp/Down`, … | buttons (Mobile) |
| `steerLock`, `steerRatio` | AGA: lock in degrees = `steerLock / steerRatio` |
| `speedKmh`, `localVelocity`, `localAngularVelocity`, `gForces`, `ffb`, `ndSlipL`, `ndSlipR` | car data copies |
| `steeringSpeed`, `steeringFilter`, `speedSensitivity`, `rumbleEffects` | AC gamepad settings |
| `vibrationLeft/Right`, `gamepadType`, `gamepadIndex` | feedback |

Keyboard: AGA reads AC's own driving binds from `cfg/controls.ini` `[KEYBOARD] GAS, BRAKE, LEFT, RIGHT`
(`ac.INIConfig.load(ac.getFolder(ac.FolderID.Cfg) .. '\\controls.ini')`), polls them with `ac.isKeyDown(key)` in the
physics thread and re-reads on `ac.onControlSettingsChanged`. The user sets *Input method = Gamepad* and
*Combine with keyboard* so that the other keyboard controls (gears, lights, …) keep working.

Custom bindable keys: `ac.ControlButton(id, {keyboard = {key = ..., ctrl = ...}})` exists in the physics thread
(`:down()`, `:pressed()`, `:released()` map to `lj_binaryinput_*physics`). An app creating a `ControlButton` with
the same id can draw the binding editor with `:control()`.

## Car data for the controllers

All used by AGA in the physics thread or by official CSP code:

- Slip: `car.wheels[i].ndSlip` (normalised slip, ≈ 1 at the tyre's peak), `slipRatio`, `slipAngle`, `load`, `loadK`,
  `angularSpeed`, `tyreRadius`. Driven wheels from `car.tractionType` (AGA: `1` = FWD → wheels 0, 1, otherwise rear).
- Lateral load: `ac.getJoypadState().gForces` (Gamepad Force) or `car.acceleration` (in g, official OBS code).
- Speed and direction: `car.speedKmh`, `car.localVelocity` (z < 0 when reversing), `car.gear` (-1 = R).
- ABS / TC: `car.absMode` (0 = off), `car.absInAction`, `car.tractionControlMode`, `car.tractionControlInAction`.
- Tyre temperature: `car.wheels[i].tyreCoreTemperature`, `tyreOptimumTemperature` (AGA, physics thread). The
  optimum window can also come from `tyres.ini` `[THERMAL_FRONT]` `PERFORMANCE_CURVE` via `ac.INIConfig.carData`
  (same approach as MirrorDelta's `car_data.lua`).
- Pits and resets: `car.isInPitlane`, `ac.onCarJumped(car.index, cb)`, `car.isAIControlled`, `car.physicsAvailable`.

## Shared memory with the UI app

`ac.connect({ac.StructItem.key('...'), field = ac.StructItem.double(), ...})` with an identical layout on both sides.
AGA connects its joypad script and its UI app this way. Persistent settings: `ac.storage` works in the joypad
script (AGA). Plan: the core owns persistence (per car, per mode), the app edits through the shared struct and
`ac.broadcastSharedEvent` commands.

## Online

- The server extra options (`csp_extra_options.ini`) have no option for Gamepad FX, input scripts or client
  Lua apps. The only related levers are a minimum CSP version and `REQUIRED_MODULES`.
- AGA states it works on any online server. Gamepad FX runs locally on the client and only changes the inputs.
- The server's `ABS_ALLOWED` / `TC_ALLOWED` rules apply to the car's ABS/TC, not to a script that limits the
  pedals. A league that forbids ABS/TC may consider slip-limited inputs an aid: KeyDrive therefore keeps the
  "leave it to the car's ABS" option and the raw bypass key, and the README asks users to respect league rules.

## Open points to confirm in the game (PoC)

1. The script runs with *Input method = Gamepad* and **no physical gamepad** connected.
2. With *Combine with keyboard* on, AC does not mix the raw keyboard gas into the joypad state before or after
   the script (AGA's keyboard brake assist relies on this). The PoC overlay shows the incoming joypad values
   and the final `car.gas` so this can be read directly.
   Fallback if keys leak in: bind AC's GAS/BRAKE/LEFT/RIGHT to unused keys and give KeyDrive its own
   `ac.ControlButton` driving keys.

## AC's own keyboard filter (measured, v0.9)

Recorded with the KeyDriveConfig "KeyDrive Reference" window in the normal keyboard input mode (120 s, Supercars Gen3
Supra, controls.ini [KEYBOARD] STEERING_SPEED 1.75, STEERING_OPPOSITE_DIRECTION_SPEED 2.5, STEER_RESET_SPEED 1.8).
Steering in units of full lock (270 deg of steering wheel for that car):

- Outwards (key held, wheel on the key's side or centred): STEERING_SPEED x factor(speed), independent of the wheel
  position and of lateral g. Factor: 0.60 at 55 km/h, 0.50 at 95, 0.37 at 105, 0.30 at 125, 0.24 at 145, 0.18 at
  165, 0.14 at 185, 0.11 at 205, 0.10 from 215 km/h (extrapolated 0.74 at standstill).
- Back to the centre with no key: STEER_RESET_SPEED x STEERING_SPEED = 3.15 /s, not speed dependent.
- Towards the other side while the wheel still points the other way: STEERING_OPPOSITE_DIRECTION_SPEED x
  STEERING_SPEED = 4.4 /s (few samples).
- In gamepad mode with Combine with keyboard, AC sends no keyboard steering to the joypad state (v0.8.1 detection).

Pedals in keyboard mode (for later):
- Throttle rises ~4.5 /s (0 -> 0.9 in 0.22 s); with rear ndSlip around 1 it dips quickly (0.90 -> 0.71 in 0.07 s) and
  returns, never below ~0.35-0.45 while the key is held, and still lets the rear reach ndSlip ~2 at full throttle.
- Brake never goes to 1: it settles at 0.55-0.70 with small modulation, fronts at ndSlip ~0.65-0.75, no locking.
