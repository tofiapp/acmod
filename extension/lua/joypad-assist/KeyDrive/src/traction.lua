-- Traction limiter for the throttle.
--
-- Measurement: AC's own normalised slip of the driven wheels (`wheels[i].ndSlip`, combined longitudinal + lateral,
-- about 1 at the tyre's peak grip), load-weighted like Advanced Gamepad Assist reads it. Being combined, it also
-- sees a rear axle that is already sliding sideways in a fast corner. If a car has no ndSlip, a longitudinal slip
-- ratio from wheel speed is used instead (driven wheel speed vs the car's forward speed).
--
-- Control: a multiplier k on the driver's ramped throttle, out = requested * k. Smoothness comes first (user: the
-- previous version swung the throttle 97 -> 22 -> 75 -> 22 % in first gear):
--   slip is filtered over 80 ms, so single spikes (a clutch bite, a kerb) do not move the throttle
--   e = (target - slip) / target, clamped to [-1, 1]
--   dk/dt = K_UP * e (e > 0) or K_DOWN * e (e < 0), times `response`: slow both ways, a leaning foot, no chopping
--   k never drops below 40 %; more than that is the driver's job
--   k is frozen for 0.5 s after a gear change (the clutch bite makes a short slip spike)
--   k returns to 1 whenever the driver is off the throttle.
--   riseScale (0.1..1) slows the throttle's rise as the slip approaches the target, so the throttle creeps up to the
--   grip limit instead of overshooting it (the slow k alone could not catch a spin that the ramp had already started).

local M = {
  available = true,   -- false when the car gives no usable wheel data
  usesNdSlip = true,  -- false: fallback to the wheel speed slip ratio
  slip = 0,           -- filtered measured slip (ndSlip units, or slip ratio in fallback)
  ratio = 0,          -- longitudinal slip ratio of the driven wheels, for diagnostics
  k = 1,              -- current throttle multiplier
  limit = 1,          -- same as k (kept for the overlay)
  active = false,     -- the multiplier is reducing the throttle
  riseScale = 1,      -- multiplier on the throttle rise rate
  airborne = false,
}

local SLIP_TAU = 0.08   -- s, slip low-pass
local K_UP = 1.0
local K_DOWN = 1.5
local FLOOR = 0.4
local SHIFT_HOLD = 0.5  -- s
local RISE_SLOWDOWN = 2 -- rise rate is full below half the target slip and drops to 10 % near the target
local V0 = 5            -- m/s, low-speed floor for the fallback slip ratio
local FALLBACK_SCALE = 0.12 -- slip ratio treated as "1.0" (peak) in the fallback
local MIN_LOAD = 50     -- N, a wheel with less load is in the air and ignored

local wheels = {}
local lastGear, shiftTimer = 0, 0
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
  M.slip, M.ratio, M.k, M.limit, M.riseScale = 0, 0, 1, 1, 1
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
    M.slip = M.slip + (slip - M.slip) * a
    M.ratio = M.ratio + (ratio - M.ratio) * a

    local gear = carState.gear
    if gear ~= lastGear then lastGear, shiftTimer = gear, SHIFT_HOLD end
    if shiftTimer > 0 then shiftTimer = shiftTimer - dt end

    local e = (target - M.slip) / target
    if e > 1 then e = 1 elseif e < -1 then e = -1 end
    local rs = e * RISE_SLOWDOWN
    if rs < 0.1 then rs = 0.1 elseif rs > 1 then rs = 1 end
    M.riseScale = rs
    if not (e < 0 and shiftTimer > 0) then
      local k = M.k + (e > 0 and K_UP or K_DOWN) * response * e * dt
      if k < FLOOR then k = FLOOR elseif k > 1 then k = 1 end
      M.k = k
    end
  end

  M.limit = M.k
  M.active = M.k < 0.995 and requested > 0.02
  return requested * M.k
end

return M
