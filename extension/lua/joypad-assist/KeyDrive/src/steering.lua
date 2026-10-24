-- Steering: rate-limited key steering with a grip window for the front wheels and a countersteer assist.
--
-- Everything is worked out in road wheel degrees with the sign of the steering output (+ = right), from vectors of
-- the car state (the same fields CSP's own gamepad scripts use):
--   delta   front wheel angle: wheels[0..1].look against the car's look/side, averaged
--   betaF   direction the front axle travels: wheels[0..1].velocity against the car's look/side
--   alpha   front slip angle = delta - betaF
-- The sign of car.side is checked online against the steering output (flips itself if needed).
--   betaR   direction the rear axle travels (wheels[2..3].velocity); the rear slip angle is -betaR
-- Holding a key asks for full grip, not full lock: the output is kept inside the window
--   [betaF - alphaPeak * target, betaF + alphaPeak * target]
-- which is the range where the front tyres stay at or below their peak slip angle (limiting only ever reduces the
-- request towards zero).
-- Countersteer: when the rear axle slides beyond the peak slip angle and the front axle moves sideways the same way
-- (the car is oversteering, not just cornering), the front wheels are turned towards betaF, i.e. along the direction
-- the front axle travels. That leaves the front tyres without side force, so the rear tyres' force turns the car
-- back. It fades in between 1x and 1.6x the peak rear slip and is applied with its own strength, even without a key.
-- (Pointing the wheels to the window's edge instead would push the nose further into the spin; the model in the
-- tests showed exactly that.)
--
-- Learned online per car (no calibration lap needed):
--   degPerUnit  road wheel degrees per steering unit (delta / output while steering)
--   alphaPeak   peak front slip angle = |slipAngle| / ndSlip while the wheel is not braking or driving (ndSlip is
--               normalised to the tyre's peak); default 7 deg (7.2 measured in the user's logs)

local M = {
  available = true,
  delta = 0,          -- measured front wheel angle, deg
  alpha = 0,          -- front slip angle, deg (steering sign)
  betaF = 0,          -- front axle travel direction, deg
  betaR = 0,          -- rear axle travel direction, deg
  alphaPeak = 7,
  degPerUnit = 15,
  lo = -1, hi = 1,    -- current window in output units (for diagnostics)
  limiting = false,
  countering = false,
  fade = 0,           -- 0 at low speed (no window) .. 1
}

local BETA_TAU = 0.04
local LEARN_TAU = 3
local FADE_V0, FADE_V1 = 20 / 3.6, 40 / 3.6

local wheels, carLook, carSide, look0, look1, vel0, vel1, vel2, vel3 = {}, nil, nil, nil, nil, nil, nil, nil, nil
local sideSign, sideVotes = 1, 0

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

function M.configure(carState, joypadState)
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local ok = pcall(function ()
    carLook, carSide = carState.look, carState.side
    look0, look1 = wheels[0].look, wheels[1].look
    vel0, vel1, vel2, vel3 = wheels[0].velocity, wheels[1].velocity, wheels[2].velocity, wheels[3].velocity
    return carLook.x + carSide.x + look0.x + look1.x + vel0.x + vel1.x + vel2.x + vel3.x
      + wheels[0].slipAngle + wheels[0].ndSlip
      + wheels[0].slipRatio
  end)
  M.available = ok
  if joypadState then
    local okL, lock = pcall(function () return joypadState.steerLock / joypadState.steerRatio end)
    if okL and finite(lock) and math.abs(lock) > 3 and math.abs(lock) < 60 then M.degPerUnit = math.abs(lock) end
  end
  M.reset()
end

function M.reset()
  M.betaF, M.betaR, M.delta, M.alpha = 0, 0, 0, 0
  M.limiting, M.countering = false, false
  M.lo, M.hi = -1, 1
end

-- Angle of a world vector in the car's horizontal plane, deg (sign fixed by sideSign).
local function angleOf(l)
  local x = l.x * carSide.x + l.y * carSide.y + l.z * carSide.z
  local z = l.x * carLook.x + l.y * carLook.y + l.z * carLook.z
  return math.deg(math.atan2(x, z))
end

-- Measures the front axle and learns the car's constants. `output` is the steering written last step.
local function measure(dt, carState, output)
  local d = (angleOf(look0) + angleOf(look1)) * 0.5
  local b = (angleOf(vel0) + angleOf(vel1)) * 0.5
  local br = (angleOf(vel2) + angleOf(vel3)) * 0.5
  -- The wheels turn the way the output says: fixes the sign of car.side.
  if math.abs(output) > 0.1 and math.abs(d) > 1 then
    sideVotes = math.clamp(sideVotes + (((d * sideSign) > 0) == (output > 0) and 1 or -1), -200, 200)
    if sideVotes < -100 then sideSign, sideVotes = -sideSign, 0 end
  end
  d, b, br = d * sideSign, b * sideSign, br * sideSign
  if not finite(d) or not finite(b) or not finite(br) then return false end
  M.delta = d
  local v = carState.localVelocity.z

  local k = math.min(1, dt / LEARN_TAU)
  if math.abs(output) > 0.15 and math.abs(d) > 2 then
    local dpu = math.abs(d / output)
    if dpu > 3 and dpu < 60 then M.degPerUnit = M.degPerUnit + (dpu - M.degPerUnit) * k end
  end
  if v > 15 then
    for i = 0, 1 do
      local w = wheels[i]
      local nd, sa, sr = w.ndSlip, math.abs(w.slipAngle), math.abs(w.slipRatio)
      if sr < 0.015 and nd > 0.4 and nd < 1.6 and sa > 1 then
        local peak = sa / nd
        if peak > 2 and peak < 20 then M.alphaPeak = M.alphaPeak + (peak - M.alphaPeak) * k end
      end
    end
  end

  local kb = math.min(1, dt / BETA_TAU)
  M.betaF = M.betaF + (b - M.betaF) * kb
  M.betaR = M.betaR + (br - M.betaR) * kb
  M.alpha = d - M.betaF
  return true
end

-- `request` is the ramped key steering (-1..1), `output` the value written in the previous step.
-- `target` scales the peak slip angle (1 = peak), `limitStrength` and `counterStrength` are 0..1.
function M.update(dt, carState, request, output, target, limitStrength, counterStrength)
  local v = carState.localVelocity.z
  M.limiting, M.countering = false, false
  if not M.available or v < 1 or (limitStrength <= 0 and counterStrength <= 0) then
    M.fade = 0
    return request
  end
  if not measure(dt, carState, output) then return request end

  local fade = (v - FADE_V0) / (FADE_V1 - FADE_V0)
  if fade < 0 then fade = 0 elseif fade > 1 then fade = 1 end
  M.fade = fade
  if fade == 0 then return request end

  local dpu = M.degPerUnit
  local half = M.alphaPeak * target
  local lo, hi = (M.betaF - half) / dpu, (M.betaF + half) / dpu
  M.lo, M.hi = lo, hi

  -- Limiting: only ever reduces the request towards zero.
  local limited = request
  local lo0, hi0 = lo < 0 and lo or 0, hi > 0 and hi or 0
  if limited < lo0 then limited = lo0 elseif limited > hi0 then limited = hi0 end
  local out = request + (limited - request) * limitStrength * fade
  if math.abs(out) < math.abs(request) - 1e-4 then M.limiting = true end

  -- Countersteer: rear beyond its peak and the front axle sliding the same way -> wheels along the front's path.
  local slide = math.abs(M.betaR) / M.alphaPeak
  if counterStrength > 0 and slide > 1 and M.betaF * M.betaR > 0 then
    local w = (slide - 1) / 0.6
    if w > 1 then w = 1 end
    w = w * counterStrength * fade
    local counter = M.betaF / dpu
    -- Keep a stronger manual countersteer the driver already gives.
    local manual = (counter > 0 and out > counter) or (counter < 0 and out < counter)
    if not manual then
      out = out + (counter - out) * w
      M.countering = w > 0.05
    end
  end
  if out > 1 then out = 1 elseif out < -1 then out = -1 end
  return out
end

return M
