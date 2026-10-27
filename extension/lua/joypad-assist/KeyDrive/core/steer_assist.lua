-- Steering assist: grip window for the front wheels and a countersteer (both off by default; the user wants no
-- steering intervention). Pure Lua, no CSP API: reads only the car state fields named below. One instance per car.
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

local M = {}
M.__index = M

local BETA_TAU = 0.08
local LEARN_TAU = 3
local FADE_V0, FADE_V1 = 20 / 3.6, 40 / 3.6

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

function M.new()
  return setmetatable({
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
    wheels = {},
    sideSign = 1, sideVotes = 0,
  }, M)
end

-- `steerLock`, `steerRatio`: optional, from CSP's joypad state (road wheel lock = steerLock / steerRatio).
function M:configure(carState, steerLock, steerRatio)
  local wheels = self.wheels
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local ok = pcall(function ()
    self.carLook, self.carSide = carState.look, carState.side
    self.look0, self.look1 = wheels[0].look, wheels[1].look
    self.vel0, self.vel1, self.vel2, self.vel3 = wheels[0].velocity, wheels[1].velocity, wheels[2].velocity,
      wheels[3].velocity
    return self.carLook.x + self.carSide.x + self.look0.x + self.look1.x + self.vel0.x + self.vel1.x + self.vel2.x
      + self.vel3.x + wheels[0].slipAngle + wheels[0].ndSlip + wheels[0].slipRatio
  end)
  self.available = ok
  if steerLock and steerRatio then
    local lock = steerLock / steerRatio
    if finite(lock) and math.abs(lock) > 3 and math.abs(lock) < 60 then self.degPerUnit = math.abs(lock) end
  end
  self:reset()
end

function M:reset()
  self.betaF, self.betaR, self.delta, self.alpha = 0, 0, 0, 0
  self.limiting, self.countering = false, false
  self.lo, self.hi = -1, 1
end

-- Angle of a world vector in the car's horizontal plane, deg (sign fixed by sideSign).
local function angleOf(self, l)
  local side, look = self.carSide, self.carLook
  local x = l.x * side.x + l.y * side.y + l.z * side.z
  local z = l.x * look.x + l.y * look.y + l.z * look.z
  return math.deg(math.atan2(x, z))
end

-- Measures the front axle and learns the car's constants. `output` is the steering written last step.
local function measure(self, dt, carState, output)
  local d = (angleOf(self, self.look0) + angleOf(self, self.look1)) * 0.5
  local b = (angleOf(self, self.vel0) + angleOf(self, self.vel1)) * 0.5
  local br = (angleOf(self, self.vel2) + angleOf(self, self.vel3)) * 0.5
  -- The wheels turn the way the output says: fixes the sign of car.side.
  local sideSign = self.sideSign
  if math.abs(output) > 0.1 and math.abs(d) > 1 then
    local votes = self.sideVotes + ((((d * sideSign) > 0) == (output > 0)) and 1 or -1)
    if votes < -200 then votes = -200 elseif votes > 200 then votes = 200 end
    if votes < -100 then sideSign, votes = -sideSign, 0 end
    self.sideSign, self.sideVotes = sideSign, votes
  end
  d, b, br = d * sideSign, b * sideSign, br * sideSign
  if not finite(d) or not finite(b) or not finite(br) then return false end
  self.delta = d
  local v = carState.localVelocity.z

  local k = math.min(1, dt / LEARN_TAU)
  if math.abs(output) > 0.15 and math.abs(d) > 2 then
    local dpu = math.abs(d / output)
    if dpu > 3 and dpu < 60 then self.degPerUnit = self.degPerUnit + (dpu - self.degPerUnit) * k end
  end
  if v > 15 then
    local wheels = self.wheels
    for i = 0, 1 do
      local w = wheels[i]
      local nd, sa, sr = w.ndSlip, math.abs(w.slipAngle), math.abs(w.slipRatio)
      if sr < 0.015 and nd > 0.4 and nd < 1.6 and sa > 1 then
        local peak = sa / nd
        if peak > 2 and peak < 20 then self.alphaPeak = self.alphaPeak + (peak - self.alphaPeak) * k end
      end
    end
  end

  local kb = math.min(1, dt / BETA_TAU)
  self.betaF = self.betaF + (b - self.betaF) * kb
  self.betaR = self.betaR + (br - self.betaR) * kb
  self.alpha = d - self.betaF
  return true
end

-- `request` is the ramped key steering (-1..1), `output` the value written in the previous step.
-- `target` scales the peak slip angle (1 = peak), `limitStrength` and `counterStrength` are 0..1.
function M:update(dt, carState, request, output, target, limitStrength, counterStrength)
  local v = carState.localVelocity.z
  self.limiting, self.countering = false, false
  if not self.available or v < 1 or (limitStrength <= 0 and counterStrength <= 0) then
    self.fade = 0
    return request
  end
  if not measure(self, dt, carState, output) then return request end

  local fade = (v - FADE_V0) / (FADE_V1 - FADE_V0)
  if fade < 0 then fade = 0 elseif fade > 1 then fade = 1 end
  self.fade = fade
  if fade == 0 then return request end

  local dpu = self.degPerUnit
  local half = self.alphaPeak * target
  local lo, hi = (self.betaF - half) / dpu, (self.betaF + half) / dpu
  self.lo, self.hi = lo, hi

  -- Limiting: only ever reduces the request towards zero.
  local limited = request
  local lo0, hi0 = lo < 0 and lo or 0, hi > 0 and hi or 0
  if limited < lo0 then limited = lo0 elseif limited > hi0 then limited = hi0 end
  local out = request + (limited - request) * limitStrength * fade
  if math.abs(out) < math.abs(request) - 1e-4 then self.limiting = true end

  -- Countersteer: rear beyond its peak and the front axle sliding the same way -> wheels along the front's path.
  local slide = math.abs(self.betaR) / self.alphaPeak
  if counterStrength > 0 and slide > 1 and self.betaF * self.betaR > 0 then
    local w = (slide - 1) / 0.6
    if w > 1 then w = 1 end
    w = w * counterStrength * fade
    local counter = self.betaF / dpu
    -- Keep a stronger manual countersteer the driver already gives.
    local manual = (counter > 0 and out > counter) or (counter < 0 and out < counter)
    if not manual then
      out = out + (counter - out) * w
      self.countering = w > 0.05
    end
  end
  if out > 1 then out = 1 elseif out < -1 then out = -1 end
  return out
end

return M
