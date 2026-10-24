-- KeyDrive: Gamepad FX script turning on/off keyboard inputs into smooth, grip-aware pedal and steering inputs.
-- Runs in the physics thread (script.update every physics step, dt ~ 0.003 s).
-- Throttle: ramp, manual cap, corner cap, traction limiter. Brake: ramp, manual cap, trail-brake release, lock
-- limiter on longitudinal slip. Steering: speed-dependent rate, grip window for the front tyres, countersteer.

if car.isAIControlled then return end

local ramp = require('src/ramp')
local keys = require('src/keys')
local shared = require('src/shared')
local traction = require('src/traction')
local brakeLimiter = require('src/brake')
local steering = require('src/steering')
local curve = require('src/curve')

local function loadSettings()
  local defaults = {
    THROTTLE_RISE_RATE = 120,
    THROTTLE_FALL_RATE = 400,
    MAX_THROTTLE = 100,
    TRACTION = true,
    TARGET_SLIP = 100,
    TRACTION_RESPONSE = 100,
    CORNER_THROTTLE_REDUCTION = 25,
    BRAKE_RISE_RATE = 400,
    BRAKE_FALL_RATE = 800,
    MAX_BRAKE = 100,
    BRAKE_LIMITER = true,
    BRAKE_TARGET_SLIP = 100,
    BRAKE_USE_GAME_ABS = true,
    TRAIL_BRAKE_RELEASE = 40,
    STEER_SPEED_CURVE = '0:250 60:160 120:100 200:70',
    STEER_RETURN_SPEED = 150,
    STEER_BOTH_KEYS = 0,
    STEER_LIMIT_STRENGTH = 100,
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
  steerCurve = curve.parse(S.STEER_SPEED_CURVE, '0:250 60:160 120:100 200:70'), -- km/h -> % of full lock per s
  steerReturn = math.clamp(S.STEER_RETURN_SPEED / 100, 0.2, 5),
  steerBothReturn = S.STEER_BOTH_KEYS == 1 or S.STEER_BOTH_KEYS == true, -- false: hold the angle
  steerLimitStrength = math.clamp(S.STEER_LIMIT_STRENGTH / 100, 0, 1),
  steerTarget = math.clamp(S.STEER_TARGET / 100, 0.5, 2),
  countersteerAssist = math.clamp(S.COUNTERSTEER_ASSIST / 100, 0, 1),
}

local THROTTLE_ASSIST_FALL = 1.5 -- per second: fastest throttle reduction an assist may make
local CORNER_G_FULL = 1.5    -- lateral g at which the corner cap reduction is complete
local CORNER_TAU = 0.15      -- s, smoothing of the corner factor
local TRAIL_TAU = 0.2        -- s, smoothing of the steering amount used for the trail-brake release

local live = shared.connect()
live.showDiagnostics = flag(S.SHOW_DIAGNOSTICS)
live.recordLog = flag(S.RECORD_LOG)
live.targetSlip = P.targetSlip
live.brakeTargetSlip = P.brakeTargetSlip

local gasRequest = 0  -- ramped key throttle (the "foot" before limits)
local gas, brake, steer = 0, 0, 0
local brakeRequest = 0 -- ramped key brake before limits
local steerRequest = 0 -- ramped key steering before the grip window
local corner = 0      -- smoothed 0..1 corner load factor
local trail = 0       -- smoothed |steer| for the trail-brake release
local lastWritten, leakTime = 0, 0
local hz = 0

local function publishBinds()
  live.bindGas, live.bindBrake, live.bindLeft, live.bindRight = keys.gas, keys.brake, keys.left, keys.right
  live.bindGearUp, live.bindGearDown = keys.gearUp, keys.gearDown
end

keys.read()
publishBinds()
traction.configure(car)
brakeLimiter.configure(car)
steering.configure(car, ac.getJoypadState())

local function reset()
  gasRequest, gas, brakeRequest, brake, steerRequest, steer, corner, trail = 0, 0, 0, 0, 0, 0, 0, 0
  lastWritten, leakTime = 0, 0
  traction.configure(car)
  brakeLimiter.configure(car)
  steering.reset()
end

ac.onCarJumped(car.index, reset)
ac.onControlSettingsChanged(function ()
  keys.read()
  publishBinds()
end)

pcall(ac.loadRenderThreadModule, 'module_render')

local function throttle(dt, kGas, state)
  -- Corner cap: lateral g or steering, whichever is larger.
  local gx = state.gForces.x
  live.gx = gx
  local g = math.abs(gx) / CORNER_G_FULL
  local st = math.abs(steer)
  local c = g > st and g or st
  if c > 1 then c = 1 end
  corner = corner + (c - corner) * math.min(1, dt / CORNER_TAU)
  local cap = P.maxThrottle * (1 - P.cornerThrottleReduction * corner)

  gasRequest = ramp.step(gasRequest, kGas and cap or 0, P.throttleRise, P.throttleFall, dt)

  -- Traction only when driving forwards in a forward gear; reverse, neutral and standing in reverse never use it.
  local forward = car.gear > 0 and car.localVelocity.z > -1
  live.cap = cap
  local out
  if P.traction and forward then
    out = traction.update(dt, car, gasRequest, P.targetSlip, P.tractionResponse)
  else
    traction.reset()
    out = gasRequest
  end
  -- Smoothness: the sent throttle never jumps. It drops at the key fall rate only when the driver lifts,
  -- otherwise (traction, corner cap) at most THROTTLE_ASSIST_FALL per second.
  local fall = gasRequest < gas and P.throttleFall or THROTTLE_ASSIST_FALL
  local rise = P.throttleRise * ((P.traction and forward) and traction.riseScale or 1)
  return ramp.step(gas, out, rise, fall, dt)
end

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

local counterHold = 0

local function steerInput(dt, kLeft, kRight)
  local target
  if kLeft and kRight then
    target = P.steerBothReturn and 0 or steerRequest -- both keys: hold the angle, or return smoothly
  else
    target = (kRight and 1 or 0) - (kLeft and 1 or 0)
  end
  local rate = curve.eval(P.steerCurve, math.abs(car.speedKmh)) / 100
  steerRequest = ramp.stepSigned(steerRequest, target, rate, rate * P.steerReturn, dt)
  if car.gear < 0 or car.localVelocity.z < 0 then
    steering.reset()
    return steerRequest -- reversing: plain keys
  end
  local wanted = steering.update(dt, car, steerRequest, steer, P.steerTarget, P.steerLimitStrength, P.countersteerAssist)
  -- The assist may never move the wheels faster than the keys do (user report: it grabbed the steering).
  -- A countersteer (opt-in) has to be quick, and so does taking it back, else the car swings the other way.
  if steering.countering then counterHold = 0.6 elseif counterHold > 0 then counterHold = counterHold - dt end
  if counterHold > 0 then return wanted end
  local maxRate = rate * math.max(1, P.steerReturn)
  return ramp.stepSigned(steer, wanted, maxRate, maxRate, dt)
end

function script.update(dt)
  if car.isAIControlled then return end
  if dt <= 0 then return end
  if dt > 0.05 then dt = 0.05 end -- after a hitch, never jump more than 50 ms worth of ramp

  local state = ac.getJoypadState()
  local inGas, inBrake, inSteer = state.gas, state.brake, state.steer

  -- Leak check: the car should run exactly the throttle written in the previous step.
  if car.gas > lastWritten + 0.1 then leakTime = leakTime + dt else leakTime = 0 end

  local kGas, kBrake, kLeft, kRight = keys.gasDown(), keys.brakeDown(), keys.leftDown(), keys.rightDown()

  gas = throttle(dt, kGas, state)
  brake = brakeInput(dt, kBrake)

  steer = steerInput(dt, kLeft, kRight)

  state.gas = gas
  state.brake = brake
  state.steer = steer
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
  live.outGas, live.outBrake, live.outSteer = gas, brake, steer
  live.gasRequest = gasRequest
  live.slip = traction.slip
  live.slipRatio = traction.ratio
  live.usesNdSlip = traction.usesNdSlip
  live.tcLimit = traction.limit
  live.tcState = not traction.available and 0 or not P.traction and 1 or traction.airborne and 2
    or traction.active and 4 or 3
  live.brakeRequest = brakeRequest
  live.brakeK = brakeLimiter.k
  live.brakeSlip = brakeLimiter.slip
  live.brakeMemory = brakeLimiter.memory
  live.brakeState = brakeState
  live.steerRequest = steerRequest
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
