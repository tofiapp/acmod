-- Traction limiter for the throttle.
--
-- Measurement: AC's own normalised slip of the driven wheels (`wheels[i].ndSlip`, combined longitudinal + lateral,
-- about 1 at the tyre's peak grip), load-weighted like Advanced Gamepad Assist reads it. Being combined, it also
-- sees a rear axle that is already sliding sideways in a fast corner. If a car has no ndSlip, a longitudinal slip
-- ratio from wheel speed is used instead (driven wheel speed vs the car's forward speed).
--
-- Control: a multiplier k on the driver's ramped throttle, out = requested * k.
--   e = (target - (slip + PREDICT * slip rate)) / target, clamped to [-1, 1]
--   dk/dt = K_UP * e (e > 0) or K_DOWN * e (e < 0), times `response`
--   k never drops below a floor (20 % at low speed, 50 % from 160 km/h), so the car can always accelerate and a
--   fast corner never gets a sudden lift. k returns to 1 whenever the driver is off the throttle.

local M = {
  available = true,   -- false when the car gives no usable wheel data
  usesNdSlip = true,  -- false: fallback to the wheel speed slip ratio
  slip = 0,           -- filtered measured slip (ndSlip units, or slip ratio in fallback)
  slipRate = 0,       -- filtered d(slip)/dt
  ratio = 0,          -- longitudinal slip ratio of the driven wheels, for diagnostics
  k = 1,              -- current throttle multiplier
  limit = 1,          -- same as k (kept for the overlay)
  active = false,     -- the multiplier is reducing the throttle
  airborne = false,
}

local SLIP_TAU = 0.02   -- s, slip low-pass
local PREDICT = 0.15    -- s, the controller acts on slip + PREDICT * slip rate (reacts to a spin before it builds up)
local RATE_TAU = 0.03   -- s, low-pass of the slip rate
local K_UP = 2
local K_DOWN = 6
local FLOOR_LOW, FLOOR_HIGH = 0.2, 0.5
local FLOOR_V_LOW, FLOOR_V_HIGH = 40 / 3.6, 160 / 3.6
local V0 = 5            -- m/s, low-speed floor for the fallback slip ratio
local FALLBACK_SCALE = 0.12 -- slip ratio treated as "1.0" (peak) in the fallback
local MIN_LOAD = 50     -- N, a wheel with less load is in the air and ignored

local wheels = {}
local driven = {}
local drivenCount = 0

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

function M.configure(carState)
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local t = carState.tractionType
  if t == 1 then
    driven[1], driven[2], drivenCount = 0, 1, 2       -- front-wheel drive
  elseif t == 0 then
    driven[1], driven[2], drivenCount = 2, 3, 2       -- rear-wheel drive
  else
    driven[1], driven[2], driven[3], driven[4], drivenCount = 0, 1, 2, 3, 4 -- AWD or unknown
  end
  local w = wheels[driven[1]]
  local okR, r = pcall(function () return w.tyreRadius + w.angularSpeed + w.load end)
  M.available = okR and finite(r) and w.tyreRadius > 0.05
  local okN, nd = pcall(function () return w.ndSlip end)
  M.usesNdSlip = okN and type(nd) == 'number' and finite(nd)
  M.reset()
end

function M.reset()
  M.slip, M.slipRate, M.ratio, M.k, M.limit = 0, 0, 0, 1, 1
  M.active, M.airborne = false, false
end

-- Returns measured slip (ndSlip or scaled ratio) and the raw slip ratio, or nil when the driven wheels are in the air.
local function measure(carState)
  local v = carState.localVelocity.z
  local ref = math.max(math.abs(v), V0)
  local ndSum, loadSum, speedSum, n = 0, 0, 0, 0
  for k = 1, drivenCount do
    local w = wheels[driven[k]]
    local load = w.load
    if load > MIN_LOAD then
      if M.usesNdSlip then ndSum = ndSum + w.ndSlip * load end
      loadSum = loadSum + load
      speedSum = speedSum + w.angularSpeed * w.tyreRadius
      n = n + 1
    end
  end
  if n == 0 then return nil end
  local ratio = (speedSum / n - v) / ref
  local slip = M.usesNdSlip and ndSum / loadSum or ratio / FALLBACK_SCALE
  if not finite(slip) or not finite(ratio) then return nil end
  return slip, ratio
end

-- Returns the throttle to send. `requested` is the ramped key throttle, `target` the slip target in ndSlip units
-- (1 = tyre peak), `response` scales the controller gains (1 = default).
function M.update(dt, carState, requested, target, response)
  if not M.available or target <= 0 then
    M.active = false
    return requested
  end
  if requested < 0.02 then
    M.k = 1 -- off the throttle: start fresh next time
  end

  local slip, ratio = measure(carState)
  if slip == nil then
    M.airborne = true -- driven wheels in the air: keep k as it is
  else
    M.airborne = false
    local a = math.min(1, dt / SLIP_TAU)
    local prev = M.slip
    M.slip = M.slip + (slip - M.slip) * a
    M.ratio = M.ratio + (ratio - M.ratio) * a
    local rate = (M.slip - prev) / dt
    M.slipRate = M.slipRate + (rate - M.slipRate) * math.min(1, dt / RATE_TAU)

    local predicted = M.slip + PREDICT * M.slipRate
    local e = (target - predicted) / target
    if e > 1 then e = 1 elseif e < -1 then e = -1 end
    local k = M.k + (e > 0 and K_UP or K_DOWN) * response * e * dt
    local v = math.abs(carState.localVelocity.z)
    local t = (v - FLOOR_V_LOW) / (FLOOR_V_HIGH - FLOOR_V_LOW)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local floor = FLOOR_LOW + (FLOOR_HIGH - FLOOR_LOW) * t
    if k < floor then k = floor elseif k > 1 then k = 1 end
    M.k = k
  end

  M.limit = M.k
  M.active = M.k < 0.995 and requested > 0.02
  return requested * M.k
end

return M
