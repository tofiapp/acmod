-- KeyDrive: Gamepad FX script turning on/off keyboard inputs into smooth, grip-aware pedal and steering inputs.
-- Runs in the physics thread (script.update every physics step, dt ~ 0.003 s).
-- Thin game wrapper: reads settings, keys and the joypad state through CSP and runs the pure Lua cores
-- (core/throttle.lua, core/steering.lua; the simulator in sim/ runs the same files). The brake is still here (phase 9).
-- Throttle: ramp, manual cap, corner cap, traction limiter. Brake: ramp, manual cap, trail-brake release, lock
-- limiter on longitudinal slip. Steering: speed-dependent rate, grip window for the front tyres, countersteer.

if car.isAIControlled then return end

local ramp = require('core/ramp')
local curve = require('core/curve')
local Throttle = require('core/throttle')
local Steering = require('core/steering')
local keys = require('src/keys')
local shared = require('src/shared')
local brakeLimiter = require('src/brake')
local tuned = require('core/tuned')

local function loadSettings()
  local defaults = {
    THROTTLE_RISE_RATE = 120,
    THROTTLE_FALL_RATE = 400,
    MAX_THROTTLE = 100,
    TRACTION = true,
    TRACTION_MODE = 2,
    TARGET_SLIP = 100,
    TRACTION_RESPONSE = 100,
    CORNER_THROTTLE_REDUCTION = 0,
    BRAKE_RISE_RATE = 400,
    BRAKE_FALL_RATE = 800,
    MAX_BRAKE = 100,
    BRAKE_LIMITER = true,
    BRAKE_TARGET_SLIP = 100,
    BRAKE_USE_GAME_ABS = true,
    TRAIL_BRAKE_RELEASE = 40,
    STEER_STYLE = 0,
    STEER_RATE = 100,
    STEER_SPEED_SLOWDOWN = 100,
    STEER_SPEED_CURVE = '0:250 60:160 120:100 200:70',
    STEER_RETURN_SPEED = 150,
    STEER_BOTH_KEYS = 0,
    STEER_LIMIT_STRENGTH = 0,
    STEER_TARGET = 120,
    COUNTERSTEER_ASSIST = 0,
    SHOW_DIAGNOSTICS = true,
    RECORD_LOG = true,
  }
  local ok, s = pcall(function ()
    return ac.INIConfig.scriptSettings():mapSection('KEYDRIVE', defaults)
  end)
  return ok and s or defaults
end

local function flag(v) return v ~= false and v ~= 0 end

local S = loadSettings()
local P = {
  throttleRise = math.max(S.THROTTLE_RISE_RATE, 1) / 100,
  throttleFall = math.max(S.THROTTLE_FALL_RATE, 1) / 100,
  maxThrottle = math.clamp(S.MAX_THROTTLE / 100, 0, 1),
  traction = flag(S.TRACTION),
  tractionMode = tonumber(S.TRACTION_MODE) == 1 and 1 or 2, -- 1 = remembering foot (v0.7-0.9), 2 = tuned regulator
  targetSlip = math.clamp(S.TARGET_SLIP / 100, 0.3, 3), -- in ndSlip units, 1 = tyre peak
  tractionResponse = math.clamp(S.TRACTION_RESPONSE / 100, 0.1, 5),
  cornerThrottleReduction = math.clamp(S.CORNER_THROTTLE_REDUCTION / 100, 0, 1),
  brakeRise = math.max(S.BRAKE_RISE_RATE, 1) / 100,
  brakeFall = math.max(S.BRAKE_FALL_RATE, 1) / 100,
  maxBrake = math.clamp(S.MAX_BRAKE / 100, 0, 1),
  brakeLimiter = flag(S.BRAKE_LIMITER),
  brakeTargetSlip = math.clamp(S.BRAKE_TARGET_SLIP / 100, 0.3, 3),
  brakeUseGameAbs = flag(S.BRAKE_USE_GAME_ABS), -- car's ABS switched on: leave the regulation to it
  trailBrakeRelease = math.clamp(S.TRAIL_BRAKE_RELEASE / 100, 0, 1),
  steerStyle = tonumber(S.STEER_STYLE) or 0, -- 0 auto: AC's own steering if AC sends it, 2 emulation of AC rates
  steerStyleAC = S.STEER_STYLE ~= 1,         -- emulation uses AC's keyboard rates (0 and 2), 1: KeyDrive's curve
  steerRate = math.clamp(S.STEER_RATE / 100, 0.3, 3),                  -- scales AC's three keyboard rates
  steerSlowdown = math.clamp(S.STEER_SPEED_SLOWDOWN / 100, 0, 1),     -- share of AC's slowdown with speed
  steerCurve = curve.parse(S.STEER_SPEED_CURVE, '0:250 60:160 120:100 200:70'), -- km/h -> % of full lock per s
  steerReturn = math.clamp(S.STEER_RETURN_SPEED / 100, 0.2, 5),
  steerBothReturn = S.STEER_BOTH_KEYS == 1 or S.STEER_BOTH_KEYS == true, -- false: hold the angle
  steerLimitStrength = math.clamp(S.STEER_LIMIT_STRENGTH / 100, 0, 1),
  steerTarget = math.clamp(S.STEER_TARGET / 100, 0.5, 2),
  countersteerAssist = math.clamp(S.COUNTERSTEER_ASSIST / 100, 0, 1),
}

local TRAIL_TAU = 0.2        -- s, smoothing of the steering amount used for the trail-brake release

local live = shared.connect()
live.showDiagnostics = flag(S.SHOW_DIAGNOSTICS)
live.recordLog = flag(S.RECORD_LOG)
live.targetSlip = P.targetSlip
live.brakeTargetSlip = P.brakeTargetSlip

-- TRACTION_MODE 2 uses the optimizer's parameters (core/tuned.lua); TARGET_SLIP then scales the tuned target
-- (100 % = as tuned), so the setting keeps its meaning "more or less slip than the default".
local throttleParams = {
  RISE = P.throttleRise, FALL = P.throttleFall, MAX = P.maxThrottle, TRACTION = P.traction,
  TARGET_SLIP = P.targetSlip, RESPONSE = P.tractionResponse, CORNER_REDUCTION = P.cornerThrottleReduction,
}
local tractionParams = nil
if P.tractionMode == 2 then
  for k, v in pairs(tuned.throttle) do throttleParams[k] = v end
  throttleParams.TARGET_SLIP = math.min(1, tuned.throttle.TARGET_SLIP * P.targetSlip) -- past the peak it runs away
  tractionParams = tuned.traction
end
local throttleCore = Throttle.new(throttleParams, tractionParams)
live.targetSlip = throttleParams.TARGET_SLIP -- the target really used (overlay, recorder's wheelspin flag)
local traction = throttleCore.traction
local steerCore = Steering.new({
  STYLE_AC = P.steerStyleAC, RATE = P.steerRate, SLOWDOWN = P.steerSlowdown, CURVE = P.steerCurve,
  RETURN = P.steerReturn, BOTH_RETURN = P.steerBothReturn, LIMIT_STRENGTH = P.steerLimitStrength,
  TARGET = P.steerTarget, COUNTERSTEER = P.countersteerAssist,
})
local steering = steerCore.assist
local keyRates = {}

local gas, brake, steer = 0, 0, 0
local brakeRequest = 0 -- ramped key brake before limits
local trail = 0       -- smoothed |steer| for the trail-brake release
local lastWritten, leakTime = 0, 0
local hz = 0

local function applyKeys()
  live.bindGas, live.bindBrake, live.bindLeft, live.bindRight = keys.gas, keys.brake, keys.left, keys.right
  live.bindGearUp, live.bindGearDown = keys.gearUp, keys.gearDown
  keyRates.KB_SPEED, keyRates.KB_OPPOSITE, keyRates.KB_RESET = keys.steerSpeed, keys.steerOppositeSpeed,
    keys.steerResetSpeed
  steerCore:setParams(keyRates)
end

keys.read()
applyKeys()
throttleCore:configure(car)
brakeLimiter.configure(car)
do
  local okL, lock, ratio = pcall(function ()
    local st = ac.getJoypadState()
    return st.steerLock + 0, st.steerRatio + 0
  end)
  steerCore:configure(car, okL and lock or nil, okL and ratio or nil)
end

local function reset()
  gas, brakeRequest, brake, steer, trail = 0, 0, 0, 0, 0
  lastWritten, leakTime = 0, 0
  throttleCore:reset(car)
  brakeLimiter.configure(car)
  steerCore:reset()
end

ac.onCarJumped(car.index, reset)
ac.onControlSettingsChanged(function ()
  keys.read()
  applyKeys()
end)

pcall(ac.loadRenderThreadModule, 'module_render')

local brakeState = 3

local function brakeInput(dt, kBrake)
  -- Trail braking: the more the wheels are turned, the lower the brake cap.
  local st = math.abs(steer)
  trail = trail + (st - trail) * math.min(1, dt / TRAIL_TAU)
  local cap = P.maxBrake * (1 - P.trailBrakeRelease * trail)
  brakeRequest = ramp.step(brakeRequest, kBrake and cap or 0, P.brakeRise, P.brakeFall, dt)
  live.brakeCap = cap

  if not brakeLimiter.available then brakeState = 0; return brakeRequest end
  if not P.brakeLimiter then brakeState = 1; return brakeRequest end
  if P.brakeUseGameAbs and car.absMode > 0 then
    brakeState = 2
    brakeLimiter.reset()
    return brakeRequest
  end
  local out = brakeLimiter.update(dt, car, brakeRequest, P.brakeTargetSlip)
  brakeState = brakeLimiter.active and 4 or 3
  return out
end

-- STEER_STYLE 0: if AC itself computes the keyboard steering in gamepad mode (Combine with keyboard), it arrives in
-- the joypad state before KeyDrive writes it. Votes decide: a steering key held while the incoming value points the
-- same way (and differs from what KeyDrive wrote last step, so it is not our own value echoed back) means AC steers.
local acSteerVotes, lastWrittenSteer, steerFromAC = 0, 0, false

function script.update(dt)
  if car.isAIControlled then return end
  if dt <= 0 then return end
  if dt > 0.05 then dt = 0.05 end -- after a hitch, never jump more than 50 ms worth of ramp

  local state = ac.getJoypadState()
  local inGas, inBrake, inSteer = state.gas, state.brake, state.steer

  -- Leak check: the car should run exactly the throttle written in the previous step.
  if car.gas > lastWritten + 0.1 then leakTime = leakTime + dt else leakTime = 0 end

  local kGas, kBrake, kLeft, kRight = keys.gasDown(), keys.brakeDown(), keys.leftDown(), keys.rightDown()

  live.gx = state.gForces.x
  gas = throttleCore:update(dt, kGas, car, state.gForces.x, steer)
  live.cap = throttleCore.cap
  brake = brakeInput(dt, kBrake)

  if P.steerStyle == 0 and (kLeft ~= kRight) and math.abs(car.speedKmh) > 5 then
    local dir = kRight and 1 or -1
    if math.abs(inSteer - lastWrittenSteer) > 1e-4 and inSteer * dir > 0.03 then
      acSteerVotes = math.min(acSteerVotes + 1, 300)
    elseif math.abs(inSteer) < 0.005 or math.abs(inSteer - lastWrittenSteer) <= 1e-4 then
      acSteerVotes = math.max(acSteerVotes - 1, -300)
    end
  end
  steerFromAC = P.steerStyle == 0 and acSteerVotes > 100
  if steerFromAC then
    steer = inSteer          -- AC's own keyboard steering, untouched
    steerCore:follow(inSteer) -- so a later switch to KeyDrive's steering does not jump
  else
    steer = steerCore:update(dt, kLeft, kRight, car)
  end

  state.gas = gas
  state.brake = brake
  if not steerFromAC then state.steer = steer end
  lastWrittenSteer = steerFromAC and 1e9 or steer
  lastWritten = gas

  -- Buttons AC does not forward from the keyboard in gamepad mode. Held state, AC detects the press itself.
  local kUp, kDown = keys.gearUpDown(), keys.gearDownDown()
  if kUp then state.gearUp = true end
  if kDown then state.gearDown = true end
  if keys.handbrakeDown() then state.handbrake = 1 end

  -- Diagnostics
  hz = hz + (1 / dt - hz) * math.min(1, dt * 2)
  local a = live.alive + 1
  live.alive = a > 1000000 and 0 or a
  live.keyMask = (kGas and 1 or 0) + (kBrake and 2 or 0) + (kLeft and 4 or 0) + (kRight and 8 or 0)
    + (kUp and 16 or 0) + (kDown and 32 or 0)
  live.inGas, live.inBrake, live.inSteer = inGas, inBrake, inSteer
  live.steerFromAC = steerFromAC
  live.acSteerVotes = acSteerVotes
  live.outGas, live.outBrake, live.outSteer = gas, brake, steer
  live.gasRequest = throttleCore.request
  live.slip = traction.slip
  live.slipRatio = traction.ratio
  live.usesNdSlip = traction.usesNdSlip
  live.tcLimit = traction.limit
  live.tcMemory = traction.memoryNow
  live.tractionMode = P.tractionMode
  live.tcSx, live.tcLateral, live.tcTargetX = traction.sx, traction.lateral, traction.targetX
  live.tcSlipRate, live.tcKappaPeak = traction.slipRate, traction.kappaPeak
  live.tcState = not traction.available and 0 or not P.traction and 1 or traction.airborne and 2
    or traction.active and 4 or 3
  live.brakeRequest = brakeRequest
  live.brakeK = brakeLimiter.k
  live.brakeSlip = brakeLimiter.slip
  live.brakeMemory = brakeLimiter.memory
  live.brakeState = brakeState
  live.steerRequest = steerCore.request
  live.steerLo, live.steerHi = steering.lo, steering.hi
  live.frontAlpha = steering.alpha
  live.alphaPeak = steering.alphaPeak
  live.betaF = steering.betaF
  live.degPerUnit = steering.degPerUnit
  live.steerState = not steering.available and 0 or steering.fade == 0 and 1 or steering.countering and 4
    or steering.limiting and 3 or 2
  live.brakePeakRatio = brakeLimiter.peakRatio
  live.leak = leakTime > 0.3
  live.physicsHz = hz
end
