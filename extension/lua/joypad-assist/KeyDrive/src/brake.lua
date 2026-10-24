-- Brake lock limiter: keeps every wheel just below locking, also for cars without ABS.
--
-- Measurement: the highest ndSlip of the four wheels that touch the ground (AC's combined slip, 1 = tyre peak), so the
-- first wheel to lock (usually a front one, or the inside one in a corner) decides. Under braking ndSlip rises steeply
-- before a lock, so it is predicted a little ahead from its rate.
--
-- Control: a multiplier k on the driver's ramped brake, out = requested * k.
--   e = (target - predicted slip) / target, clamped to [-1, 1]
--   dk/dt = K_UP * e (e > 0) or K_DOWN * e (e < 0)
-- Learning: the multiplier at which the slip last reached the target is remembered (`memory`), and a new brake
-- application starts from it instead of from 100 %, so the first lock of each stop is avoided. The memory slowly
-- returns to 1 (grip may be higher at a different speed or with more downforce).
-- Below 10 km/h the limiter lets go (wheels near standstill read nonsense slip, and a stop needs full brake).

local M = {
  available = true,
  slip = 0,         -- filtered highest wheel ndSlip
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

local wheels = {}

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

function M.configure(carState)
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local ok, nd = pcall(function () return wheels[0].ndSlip + wheels[0].load end)
  M.available = ok and type(nd) == 'number' and finite(nd)
  M.memory = 1
  M.reset()
end

function M.reset()
  M.slip, M.slipRate, M.k = 0, 0, M.memory
  M.active = false
end

local function measure()
  local best, idx = -1, -1
  for i = 0, 3 do
    local w = wheels[i]
    if w.load > MIN_LOAD then
      local nd = w.ndSlip
      if nd > best then best, idx = nd, i end
    end
  end
  if idx < 0 or not finite(best) then return nil end
  return best, idx
end

-- `requested` is the ramped key brake, `target` the slip target (1 = tyre peak).
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
  if math.abs(carState.localVelocity.z) < MIN_SPEED then
    M.active = false
    return requested
  end

  local slip, idx = measure()
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
