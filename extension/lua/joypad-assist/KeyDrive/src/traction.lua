-- Traction limiter for the throttle, built to feel like a foot that remembers how much the car takes.
--
-- Measurement: AC's own normalised slip of the driven wheels (`wheels[i].ndSlip`, about 1 at the tyre's peak),
-- load-weighted like Advanced Gamepad Assist reads it. If a car has no ndSlip, a longitudinal slip ratio from wheel
-- speed is used instead.
--
-- Control: an absolute throttle cap A, out = min(requested, A) (the caller also slew-limits the result, so nothing
-- ever jumps). History: a plain slow PI loop pulsed in first gear: the car took about 70 % throttle, the loop climbed
-- to 72 %, the wheels spun, it fell to the 40 % floor, climbed back within half a second and spun again, about once a
-- second (user log). So:
--   - When the slip crosses the target, 95 % of the throttle sent at that moment is remembered for the current gear
--     (`memory[gear]`, an absolute level; the spin only shows once the throttle is already past the limit), and A is pulled down only to 85 % of it, not to the floor. If the slip
--     stays high for 0.4 s anyway, A may go further, down to FLOOR.
--   - Between 80 % and 100 % of the target slip A holds still (no hunting).
--   - Below 80 % of the target, A comes back quickly up to 92 % of the remembered level, and above that only creeps
--     (CREEP per second), so the grip limit is approached gently instead of hit again and again.
--   - The memory drifts back up slowly (grip in a gear grows with speed as wheel torque drops), and a new throttle
--     application or a gear change starts with A at the remembered level.
-- `k` (= out / requested) is kept for the overlay and the log.

local M = {
  available = true,   -- false when the car gives no usable wheel data
  usesNdSlip = true,  -- false: fallback to the wheel speed slip ratio
  slip = 0,           -- filtered measured slip (ndSlip units, or slip ratio in fallback)
  ratio = 0,          -- longitudinal slip ratio of the driven wheels, for diagnostics
  k = 1,              -- current throttle multiplier
  limit = 1,          -- same as k (kept for the overlay)
  memoryNow = 1,      -- remembered level for the current gear (overlay)
  active = false,     -- the multiplier is reducing the throttle
  riseScale = 1,      -- kept for the caller; always 1 now
  airborne = false,
}

local SLIP_TAU = 0.03     -- s, slip low-pass
local K_DOWN = 2.5        -- per second at full error
local K_BACK = 1.5        -- per second, quick return up to the remembered level
local CREEP = 0.08        -- per second above the remembered level
local HOLD_BAND = 0.8     -- below this fraction of the target slip k may rise
local PULL = 0.85         -- after a crossing, k goes down to this fraction of the remembered level
local RETURN = 0.92       -- quick return stops at this fraction of the remembered level
local PERSIST = 0.4       -- s over the target before k may go below PULL * memory
local FLOOR = 0.3
local MEMORY_RECOVERY = 0.02 -- per second back towards 1
local LEARN_MARGIN = 0.95    -- each crossing remembers this fraction of the level it happened at
local LEARN_MIN = 0.3        -- crossings below this throttle teach nothing
local V0 = 5              -- m/s, low-speed floor for the fallback slip ratio
local FALLBACK_SCALE = 0.12 -- slip ratio treated as "1.0" (peak) in the fallback
local MIN_LOAD = 50       -- N, a wheel with less load is in the air and ignored

local wheels = {}
local driven = {}
local drivenCount = 0
local memory = {}         -- per gear (1-based gear numbers), remembered throttle level
local known = {}          -- per gear: a limit has been found
local overTime = 0
local lastGear = 0
local A = 1               -- absolute throttle cap

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
  for g = 1, 12 do memory[g], known[g] = 1, false end
  M.reset()
end

function M.reset()
  M.slip, M.ratio, M.k, M.limit, M.riseScale, M.memoryNow = 0, 0, 1, 1, 1, 1
  M.active, M.airborne = false, false
  overTime = 0
  A = 1
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
-- (1 = tyre peak, keep it <= 1: past the peak the slip runs away), `response` scales the rates (1 = default).
function M.update(dt, carState, requested, target, response)
  if not M.available or target <= 0 then
    M.active = false
    return requested
  end

  local gear = carState.gear
  if gear < 1 then gear = 1 elseif gear > 12 then gear = 12 end
  for g = 1, 12 do
    local m = memory[g] + MEMORY_RECOVERY * dt
    memory[g] = m > 1 and 1 or m
  end
  local mem = memory[gear]
  M.memoryNow = mem

  local quickTop = known[gear] and mem * RETURN or 1
  if requested < 0.02 or gear ~= lastGear then
    -- New application or new gear: start at what this gear took last time.
    A = quickTop
    lastGear = gear
    overTime = 0
  end

  local slip, ratio = measure(carState)
  if slip == nil then
    M.airborne = true -- driven wheels in the air: keep the cap as it is
  else
    M.airborne = false
    local a = math.min(1, dt / SLIP_TAU)
    M.slip = M.slip + (slip - M.slip) * a
    M.ratio = M.ratio + (ratio - M.ratio) * a

    local out = requested < A and requested or A
    if M.slip > target and requested > 0.05 then
      if overTime == 0 then
        -- Crossing: remember the throttle this gear could take. The wheels only show the spin once the throttle is
        -- already past the limit (wheel and drivetrain inertia), so each crossing sets the memory a little below.
        -- Only a crossing caused by real throttle teaches a limit (a rear sliding sideways in a corner while the
        -- driver just starts to press would otherwise teach a nonsense limit of a few percent).
        if out > LEARN_MIN then
          local m = (out < memory[gear] and out or memory[gear]) * LEARN_MARGIN
          memory[gear], known[gear] = m, true
          mem = memory[gear]
        end
        if A > out then A = out end
      end
      overTime = overTime + dt
      local e = (M.slip - target) / target
      if e > 1 then e = 1 end
      local bottom = overTime > PERSIST and FLOOR or (known[gear] and math.max(FLOOR, mem * PULL) or FLOOR)
      if A > bottom then
        A = A - K_DOWN * response * e * dt
        if A < bottom then A = bottom end
      end
    else
      overTime = 0
      if M.slip < target * HOLD_BAND then
        quickTop = known[gear] and mem * RETURN or 1
        if A < quickTop then
          A = math.min(quickTop, A + K_BACK * response * dt)
        else
          A = A + CREEP * response * dt
        end
        if A > 1 then A = 1 end
      end
    end
  end

  local out = requested < A and requested or A
  M.k = requested > 0.02 and out / requested or 1
  M.limit = A
  M.memoryNow = memory[gear]
  M.active = out < requested - 0.005 and requested > 0.02
  return out
end

return M
