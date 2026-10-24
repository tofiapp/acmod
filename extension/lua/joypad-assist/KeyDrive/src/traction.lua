-- Traction limiter for the throttle: a PI-style limit L on the driven wheels' slip ratio.
--
-- Slip is measured from wheel speed (angularSpeed * tyreRadius) against the car's forward speed, without
-- relying on AC's own slip fields:
--   axle slip  = (mean driven wheel speed - v) / max(|v|, V0)       (yaw cancels out between left and right)
--   wheel slip = (fastest driven wheel - v - |yaw rate| * halfTrack) / max(|v|, V0)
-- The yaw term removes the part of the outer wheel's speed that comes from turning, without needing signs.
-- V0 keeps the ratio meaningful at launch (allowed slip speed at standstill = target * V0).
--
-- Limit dynamics (rates in units of throttle per second, so independent of the physics rate):
--   e = (target - slip) / target, clamped to [-2, 1]
--   e >= 0: while limiting, L rises at K_UP * e (slows down as slip approaches the target: a gentle foot);
--           otherwise L simply follows the driver's ramp
--   e <  0: L falls at K_DOWN * e, output additionally reduced by K_P * e right away
-- While L is not the limiting factor it stays just above the requested throttle (anti-windup), so a slip spike
-- is caught from the current throttle level, not from 100 %.

local M = {
  available = true,   -- false when the car gives no usable wheel data
  slip = 0,           -- filtered slip ratio (0.1 = 10 %)
  limit = 1,          -- current traction limit
  active = false,     -- limit is below the requested throttle
  airborne = false,
}

local V0 = 5            -- m/s, low-speed floor for the slip ratio
local SLIP_TAU = 0.015  -- s, slip low-pass
local K_UP = 2.5
local K_DOWN = 6
local K_P = 0.175
local HEADROOM = 0.05
local MIN_LOAD = 50     -- N, a wheel with less load is in the air and ignored

local wheels = {}       -- cached wheel state references (0-based like car.wheels)
local driven = {}       -- 1-based list of driven wheel indexes
local drivenCount = 0
local halfTrack = 0.8

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

-- Reads drivetrain layout and geometry. Call at start and after a car reset.
function M.configure(carState)
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local t = carState.tractionType
  drivenCount = 0
  if t == 1 then
    driven[1], driven[2], drivenCount = 0, 1, 2       -- front-wheel drive
  elseif t == 0 then
    driven[1], driven[2], drivenCount = 2, 3, 2       -- rear-wheel drive
  else
    driven[1], driven[2], driven[3], driven[4], drivenCount = 0, 1, 2, 3, 4 -- AWD or unknown
  end

  local ok, ht = pcall(function ()
    local a, b = wheels[2].position, wheels[3].position
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) * 0.5
  end)
  halfTrack = (ok and finite(ht) and ht > 0.3 and ht < 1.5) and ht or 0.8

  local okR, r = pcall(function () return wheels[driven[1]].tyreRadius + wheels[driven[1]].angularSpeed end)
  M.available = okR and finite(r) and wheels[driven[1]].tyreRadius > 0.05
  M.reset()
end

function M.reset()
  M.slip = 0
  M.limit = 1
  M.active = false
  M.airborne = false
end

-- Raw slip ratio of the driven wheels, or nil when every driven wheel is in the air.
local function measure(carState)
  local v = carState.localVelocity.z
  local yaw = math.abs(carState.localAngularVelocity.y)
  local ref = math.max(math.abs(v), V0)
  local sum, n, fastest = 0, 0, -1e9
  for k = 1, drivenCount do
    local w = wheels[driven[k]]
    if w.load > MIN_LOAD then
      local s = w.angularSpeed * w.tyreRadius
      sum = sum + s
      n = n + 1
      if s > fastest then fastest = s end
    end
  end
  if n == 0 then return nil end
  local axle = (sum / n - v) / ref
  local wheel = (fastest - v - yaw * halfTrack) / ref
  local slip = axle > wheel and axle or wheel
  if not finite(slip) then return nil end
  return slip
end

-- Returns the throttle to send. `requested` is the ramped key throttle, `target` the slip ratio target
-- (0.1 = 10 %), `response` scales the controller gains (1 = default).
function M.update(dt, carState, requested, target, response)
  if not M.available or target <= 0 then
    M.active = false
    return requested
  end

  local raw = measure(carState)
  if raw == nil then
    M.airborne = true
    M.active = M.limit < requested
    return math.min(requested, M.limit) -- keep the limit frozen while the driven wheels are in the air
  end
  M.airborne = false
  M.slip = M.slip + (raw - M.slip) * math.min(1, dt / SLIP_TAU)

  local e = (target - M.slip) / target
  if e > 1 then e = 1 elseif e < -2 then e = -2 end

  -- Anti-windup: when not limiting, the limit tracks just above what the driver asks for.
  local ceiling = requested + HEADROOM
  if ceiling > 1 then ceiling = 1 end
  local L = M.limit
  if L > ceiling then L = ceiling end
  if e >= 0 then
    if M.active then
      L = L + K_UP * response * e * dt   -- give throttle back gently while limiting
    else
      L = ceiling                         -- free: follow the driver's ramp
    end
  else
    L = L + K_DOWN * response * e * dt
  end
  if L < 0 then L = 0 end
  if L > ceiling then L = ceiling end
  M.limit = L

  local out = L
  if e < 0 then out = out + K_P * response * e end
  if out < 0 then out = 0 end
  M.active = out < requested
  return out < requested and out or requested
end

return M
