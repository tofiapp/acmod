-- Brake lock limiter: keeps every wheel just below locking, also for cars without ABS.
--
-- Measurement: longitudinal slip only, so steering into a corner (lateral slip) never takes the brake away:
--   lock = max over grounded wheels of -slipRatio / peakRatio
-- peakRatio is the slip ratio of the tyre's peak, learned online from wheels running straight
-- (|slipAngle| < 1.5 deg): ndSlip is normalised to the peak, so peakRatio = |slipRatio| / ndSlip there.
-- Default 0.13 (measured in the user's first logs). The value is predicted a little ahead from its rate.
--
-- Control: a multiplier k on the driver's ramped brake, out = requested * k.
--   e = (target - predicted lock) / target, clamped to [-1, 1]
--   dk/dt = K_UP * e (e > 0) or K_DOWN * e (e < 0)
-- Learning: the brake level at which the lock value last crossed the target is remembered (`memory`), and a new
-- application starts just below it, so the first lock of each stop is avoided. The memory slowly returns to 1.
-- Below 10 km/h the limiter lets go (wheels near standstill read nonsense slip, and a stop needs full brake).

local M = {
  available = true,
  slip = 0,         -- filtered highest wheel lock value (1 = peak slip ratio)
  peakRatio = 0.13, -- learned slip ratio at the tyre's peak
  slipRate = 0,
  k = 1,
  memory = 1,
  active = false,
  lastWheel = -1,   -- index of the wheel with the highest slip
}

local overTarget = false

local SLIP_TAU = 0.01
local RATE_TAU = 0.02
local PREDICT = 0.04
local K_UP = 4
local K_DOWN = 15
local FLOOR = 0.15
local MEMORY_MARGIN = 0.03   -- start a little below the remembered lock point
local MEMORY_RECOVERY = 0.15 -- per second back towards 1
local MIN_SPEED = 10 / 3.6
local MIN_LOAD = 50
local LEARN_TAU = 3

local wheels = {}

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

function M.configure(carState)
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local ok, nd = pcall(function () return wheels[0].slipRatio + wheels[0].ndSlip + wheels[0].slipAngle + wheels[0].load end)
  M.available = ok and type(nd) == 'number' and finite(nd)
  M.memory = 1
  M.reset()
end

function M.reset()
  M.slip, M.slipRate, M.k = 0, 0, M.memory
  M.active = false
end

local function measure(dt, speed)
  local best, idx = -1e9, -1
  local learn = speed > 15 and math.min(1, dt / LEARN_TAU) or 0
  for i = 0, 3 do
    local w = wheels[i]
    if w.load > MIN_LOAD then
      local sr = w.slipRatio
      local lock = -sr / M.peakRatio
      if lock > best then best, idx = lock, i end
      if learn > 0 then
        local nd = w.ndSlip
        if math.abs(w.slipAngle) < 1.5 and nd > 0.4 and nd < 1.5 and math.abs(sr) > 0.03 then
          local p = math.abs(sr) / nd
          if p > 0.04 and p < 0.4 then M.peakRatio = M.peakRatio + (p - M.peakRatio) * learn end
        end
      end
    end
  end
  if idx < 0 or not finite(best) then return nil end
  return best, idx
end

-- `requested` is the ramped key brake, `target` the lock target (1 = the tyre's peak slip ratio).
function M.update(dt, carState, requested, target)
  M.memory = math.min(1, M.memory + MEMORY_RECOVERY * dt)
  if not M.available or target <= 0 then
    M.active = false
    return requested
  end
  if requested < 0.02 then
    M.k = math.max(FLOOR, M.memory - MEMORY_MARGIN) -- next application starts below the last lock point
    M.slip, M.slipRate, M.active, overTarget = 0, 0, false, false
    return requested
  end
  local speed = math.abs(carState.localVelocity.z)
  if speed < MIN_SPEED then
    M.active = false
    return requested
  end

  local slip, idx = measure(dt, speed)
  if slip ~= nil then
    local prev = M.slip
    M.slip = M.slip + (slip - M.slip) * math.min(1, dt / SLIP_TAU)
    local rate = (M.slip - prev) / dt
    M.slipRate = M.slipRate + (rate - M.slipRate) * math.min(1, dt / RATE_TAU)
    M.lastWheel = idx

    local predicted = M.slip + PREDICT * M.slipRate
    local e = (target - predicted) / target
    if e > 1 then e = 1 elseif e < -1 then e = -1 end
    if e < 0 and not overTarget and requested * M.k > 0.05 then
      -- Remember where the grip ran out (brake level at the moment the slip crossed the target).
      local level = requested * M.k
      if level < M.memory then M.memory = level end
    end
    overTarget = e < 0
    local k = M.k + (e > 0 and K_UP or K_DOWN) * e * dt
    if k < FLOOR then k = FLOOR elseif k > 1 then k = 1 end
    M.k = k
  end

  M.active = M.k < 0.995
  return requested * M.k
end

return M
