-- KeyDrive: Gamepad FX script turning on/off keyboard inputs into smooth, grip-aware pedal and steering inputs.
-- Runs in the physics thread (script.update every physics step, dt ~ 0.003 s). Phase 2: proof of concept,
-- only the throttle is shaped properly; brake and steering are simple placeholders so the car is drivable.

if car.isAIControlled then return end

local ramp = require('src/ramp')
local keys = require('src/keys')
local shared = require('src/shared')

local function loadSettings()
  local defaults = {
    THROTTLE_RISE_RATE = 150,
    THROTTLE_FALL_RATE = 400,
    MAX_THROTTLE = 100,
    SHOW_DIAGNOSTICS = true,
  }
  local ok, s = pcall(function ()
    return ac.INIConfig.scriptSettings():mapSection('KEYDRIVE', defaults)
  end)
  return ok and s or defaults
end

local S = loadSettings()
local throttleRise = math.max(S.THROTTLE_RISE_RATE, 1) / 100
local throttleFall = math.max(S.THROTTLE_FALL_RATE, 1) / 100
local maxThrottle = math.clamp(S.MAX_THROTTLE / 100, 0, 1)

-- Placeholders until phases 4 and 5.
local BRAKE_RISE, BRAKE_FALL = 6, 10           -- per second
local STEER_OUT, STEER_BACK = 2.5, 5           -- per second at standstill, scaled down with speed

local live = shared.connect()
live.showDiagnostics = S.SHOW_DIAGNOSTICS ~= false and S.SHOW_DIAGNOSTICS ~= 0

local gas, brake, steer = 0, 0, 0
local hz = 0

local function publishBinds()
  live.bindGas, live.bindBrake, live.bindLeft, live.bindRight = keys.gas, keys.brake, keys.left, keys.right
end

keys.read()
publishBinds()

local function reset()
  gas, brake, steer = 0, 0, 0
end

ac.onCarJumped(car.index, reset)
ac.onControlSettingsChanged(function ()
  keys.read()
  publishBinds()
end)

pcall(ac.loadRenderThreadModule, 'module_render')

function script.update(dt)
  if car.isAIControlled then return end
  if dt <= 0 then return end
  if dt > 0.05 then dt = 0.05 end -- after a hitch, never jump more than 50 ms worth of ramp

  local state = ac.getJoypadState()
  local inGas, inBrake, inSteer = state.gas, state.brake, state.steer

  local kGas, kBrake, kLeft, kRight = keys.gasDown(), keys.brakeDown(), keys.leftDown(), keys.rightDown()

  gas = ramp.step(gas, kGas and maxThrottle or 0, throttleRise, throttleFall, dt)
  brake = ramp.step(brake, kBrake and 1 or 0, BRAKE_RISE, BRAKE_FALL, dt)

  local steerTarget
  if kLeft and kRight then
    steerTarget = steer -- both keys: hold the current angle
  else
    steerTarget = (kRight and 1 or 0) - (kLeft and 1 or 0)
  end
  local speedK = 1 / (1 + math.abs(car.speedKmh) / 80)
  steer = ramp.stepSigned(steer, steerTarget, STEER_OUT * speedK, STEER_BACK * speedK, dt)

  state.gas = gas
  state.brake = brake
  state.steer = steer

  -- Diagnostics
  hz = hz + (1 / dt - hz) * math.min(1, dt * 2)
  local a = live.alive + 1
  live.alive = a > 1000000 and 0 or a
  live.keyMask = (kGas and 1 or 0) + (kBrake and 2 or 0) + (kLeft and 4 or 0) + (kRight and 8 or 0)
  live.inGas, live.inBrake, live.inSteer = inGas, inBrake, inSteer
  live.outGas, live.outBrake, live.outSteer = gas, brake, steer
  live.physicsHz = hz
end
