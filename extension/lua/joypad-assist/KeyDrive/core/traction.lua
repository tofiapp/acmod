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
--   - When the slip crosses the target, 95 % of the throttle sent at that moment is remembered (an absolute level;
--     the spin only shows once the throttle is already past the limit). When the wheels grip again, the middle
--     between the throttle at the start and at the end of the spin replaces it if lower (the limit lies between). A is pulled down only to 85 % of it, not to the floor. If the slip
--     stays high for 0.4 s anyway, A may go further, down to FLOOR.
--   - Between 80 % and 100 % of the target slip A holds still (no hunting).
--   - Below 80 % of the target, A comes back quickly up to 92 % of the remembered level, and above that only creeps
--     (CREEP per second), so the grip limit is approached gently instead of hit again and again.
--   - The memory is kept per gear AND per 500 rpm band (user logs: the wheels spun every time between 5000 and
--     5600 rpm, where the engine makes its torque, and took clearly more throttle below). The limit used is the lower
--     of the current band and the next one up, so the cap eases down smoothly (K_PRE per second) just before the
--     revs reach a band where the wheels spun last time, instead of reacting after the spin.
--   - With plenty of grip at the cap, the current band's memory creeps up (CREEP per second); every band also drifts
--     back towards 1 slowly. A new throttle application or a gear change starts with A at the remembered level.
--   - The memory survives teleports and session restarts (same car), it is reset only when the script reloads.
-- `k` (= out / requested) is kept for the overlay and the log.

-- Pure Lua (Lua 5.1 / LuaJIT): no CSP API. `carState` is anything with the fields of CSP's car state that are read
-- here (gear, rpm, localVelocity.z, tractionType, wheels[0..3].ndSlip/load/angularSpeed/tyreRadius), so the simulator
-- can drive the same code. Every instance has its own memory; parameters live in `self.p` (see DEFAULTS) so the
-- optimizer can tune them.

local M = {}
M.__index = M

M.DEFAULTS = {
  SLIP_TAU = 0.03,      -- s, slip low-pass
  K_DOWN = 2.5,         -- per second at full error
  K_DOWN_SEVERE = 5,    -- per second when the slip is more than twice the target (a real spin: catch it quickly;
                        -- user log: a first-gear spin took 0.6 s to catch at 1.5 /s and the launch crawled)
  K_BACK = 1.5,         -- per second, quick return up to the remembered level
  K_PRE = 1.2,          -- per second, easing down before a band where the wheels spun last time
  CREEP = 0.08,         -- per second, memory growth of the current band while there is plenty of grip
  HOLD_BAND = 0.8,      -- below this fraction of the target slip the cap may rise
  PULL = 0.85,          -- after a crossing, the cap goes down to this fraction of the remembered level
  RETURN = 0.92,        -- quick return stops at this fraction of the remembered level
  PERSIST = 0.4,        -- s over the target before the cap may go below PULL * memory
  FLOOR = 0.3,
  MEMORY_RECOVERY = 0.015, -- per second back towards 1
  LEARN_MARGIN = 0.95,  -- each crossing remembers this fraction of the level it happened at
  LEARN_MIN = 0.3,      -- crossings below this throttle teach nothing
}

local RPM_BAND = 500
local BANDS = 32             -- up to 16000 rpm
local GEARS = 10
local V0 = 5              -- m/s, low-speed floor for the fallback slip ratio
local FALLBACK_SCALE = 0.12 -- slip ratio treated as "1.0" (peak) in the fallback
local MIN_LOAD = 50       -- N, a wheel with less load is in the air and ignored

local function finite(x)
  return x == x and x > -1e9 and x < 1e9
end

-- `params`: optional table overriding DEFAULTS (copied, so the caller may reuse it).
function M.new(params)
  local p = {}
  for k, v in pairs(M.DEFAULTS) do p[k] = v end
  if params then for k, v in pairs(params) do if M.DEFAULTS[k] ~= nil then p[k] = v end end end
  local o = setmetatable({
    p = p,
    available = true,   -- false when the car gives no usable wheel data
    usesNdSlip = true,  -- false: fallback to the wheel speed slip ratio
    slip = 0,           -- filtered measured slip (ndSlip units, or slip ratio in fallback)
    ratio = 0,          -- longitudinal slip ratio of the driven wheels, for diagnostics
    k = 1,              -- current throttle multiplier
    limit = 1,          -- absolute cap (overlay)
    memoryNow = 1,      -- remembered level for the current gear and revs (overlay)
    active = false,     -- the cap is reducing the throttle
    riseScale = 1,      -- kept for the caller; always 1 now
    severe = false,     -- the slip is more than twice the target: the caller may cut the throttle faster
    airborne = false,
    wheels = {}, driven = {}, drivenCount = 0,
    memory = {}, stamp = {}, known = {}, -- [gear][band] remembered level, clock when set, a limit has been found
    clock = 0, overTime = 0, lastGear = 0,
    A = 1,              -- absolute throttle cap
    crossBand = -1,     -- rpm band where the current spin started
    crossGear = 0,
    crossOut = 1,       -- throttle when the current spin started
  }, M)
  for g = 1, GEARS do
    o.memory[g], o.stamp[g], o.known[g] = {}, {}, {}
    for b = 0, BANDS do o.memory[g][b], o.stamp[g][b], o.known[g][b] = 1, 0, false end
  end
  return o
end

function M:configure(carState)
  local wheels, driven = self.wheels, self.driven
  for i = 0, 3 do wheels[i] = carState.wheels[i] end
  local t = carState.tractionType
  if t == 1 then
    driven[1], driven[2], self.drivenCount = 0, 1, 2       -- front-wheel drive
  elseif t == 0 then
    driven[1], driven[2], self.drivenCount = 2, 3, 2       -- rear-wheel drive
  else
    driven[1], driven[2], driven[3], driven[4], self.drivenCount = 0, 1, 2, 3, 4 -- AWD or unknown
  end
  local w = wheels[driven[1]]
  local okR, r = pcall(function () return w.tyreRadius + w.angularSpeed + w.load end)
  self.available = okR and finite(r) and w.tyreRadius > 0.05
  local okN, nd = pcall(function () return w.ndSlip end)
  self.usesNdSlip = okN and type(nd) == 'number' and finite(nd)
  self:reset()
end

function M:reset()
  self.slip, self.ratio, self.k, self.limit, self.riseScale, self.memoryNow = 0, 0, 1, 1, 1, 1
  self.active, self.airborne = false, false
  self.overTime = 0
  self.A = 1
end

-- Measured slip (ndSlip or scaled ratio) and the raw slip ratio, or nil when the driven wheels are in the air.
local function measure(self, carState)
  local v = carState.localVelocity.z
  local wheels, driven, nd = self.wheels, self.driven, self.usesNdSlip
  local ndSum, loadSum, speedSum, n = 0, 0, 0, 0
  for k = 1, self.drivenCount do
    local w = wheels[driven[k]]
    local load = w.load
    if load > MIN_LOAD then
      if nd then ndSum = ndSum + w.ndSlip * load end
      loadSum = loadSum + load
      speedSum = speedSum + w.angularSpeed * w.tyreRadius
      n = n + 1
    end
  end
  if n == 0 then return nil end
  local ratio = (speedSum / n - v) / math.max(math.abs(v), V0)
  local slip = nd and ndSum / loadSum or ratio / FALLBACK_SCALE
  if not finite(slip) or not finite(ratio) then return nil end
  return slip, ratio
end

-- Remembered level of a band with the slow recovery applied.
local function level(self, g, b)
  if not self.known[g][b] then return 1 end
  local m = self.memory[g][b] + self.p.MEMORY_RECOVERY * (self.clock - self.stamp[g][b])
  if m >= 1 then
    self.known[g][b] = false
    return 1
  end
  return m
end

local function setLevel(self, g, b, m)
  self.memory[g][b], self.stamp[g][b], self.known[g][b] = m, self.clock, m < 1
end

-- Returns the throttle to send. `requested` is the ramped key throttle, `target` the slip target in ndSlip units
-- (1 = tyre peak, keep it <= 1: past the peak the slip runs away), `response` scales the rates (1 = default).
function M:update(dt, carState, requested, target, response)
  local P = self.p
  self.clock = self.clock + dt
  if not self.available or target <= 0 then
    self.active = false
    return requested
  end

  local gear = carState.gear
  if gear < 1 then gear = 1 elseif gear > GEARS then gear = GEARS end
  local band = math.floor(carState.rpm / RPM_BAND)
  if band < 0 then band = 0 elseif band > BANDS - 1 then band = BANDS - 1 end
  local mem = level(self, gear, band)
  local ahead = level(self, gear, band + 1)
  local lim = mem < ahead and mem or ahead
  local T = lim < 1 and lim * P.RETURN or 1   -- where the cap wants to be

  if requested < 0.02 or gear ~= self.lastGear then
    -- New application or new gear: start at what this gear and these revs took last time.
    self.A = T
    self.lastGear = gear
    self.overTime = 0
  end

  local slip, ratio = measure(self, carState)
  if slip == nil then
    self.airborne = true -- driven wheels in the air: keep the cap as it is
  else
    self.airborne = false
    local a = math.min(1, dt / P.SLIP_TAU)
    self.slip = self.slip + (slip - self.slip) * a
    self.ratio = self.ratio + (ratio - self.ratio) * a

    local A = self.A
    local out = requested < A and requested or A
    if self.slip > target and requested > 0.05 then
      if self.overTime == 0 then
        -- Crossing: remember the throttle this gear and these revs could take. The wheels only show the spin once
        -- the throttle is already past the limit (wheel and drivetrain inertia), so the memory is set a little below.
        -- Only a crossing caused by real throttle teaches a limit (a rear sliding sideways in a corner while the
        -- driver just starts to press would otherwise teach a nonsense limit of a few percent).
        if out > P.LEARN_MIN then
          local m = (out < mem and out or mem) * P.LEARN_MARGIN
          setLevel(self, gear, band, m)
          mem = m
          self.crossBand, self.crossGear, self.crossOut = band, gear, out
        end
        if A > out then A = out < P.FLOOR and P.FLOOR or out end
      end
      self.overTime = self.overTime + dt
      local e = (self.slip - target) / target
      local kd = P.K_DOWN
      if e > 1 then e, kd = 1, P.K_DOWN_SEVERE end
      local bottom = self.overTime > P.PERSIST and P.FLOOR
        or (mem < 1 and math.max(P.FLOOR, mem * P.PULL) or P.FLOOR)
      if A > bottom then
        A = A - kd * response * e * dt
        if A < bottom then A = bottom end
      end
    else
      if self.overTime > 0 and self.crossBand >= 0 and self.crossGear == gear and out > P.LEARN_MIN * 0.5 then
        -- The wheels just gripped again. The spin showed only after the throttle was past the limit, and the grip
        -- comes back only after it went below: the limit lies between, so remember the middle.
        local m = (self.crossOut + out) * 0.5
        if m < level(self, gear, self.crossBand) then setLevel(self, gear, self.crossBand, m) end
        if m < level(self, gear, band) then setLevel(self, gear, band, m) end
        mem = level(self, gear, band)
        ahead = level(self, gear, band + 1)
        lim = mem < ahead and mem or ahead
        T = lim < 1 and lim * P.RETURN or 1
      end
      self.crossBand = -1
      self.overTime = 0
      if A > T + 0.005 then
        -- The revs approach a band where the wheels spun last time: ease off before it happens.
        A = A - P.K_PRE * response * dt
        if A < T then A = T end
      elseif self.slip < target * P.HOLD_BAND then
        if A < T - 0.005 then
          A = A + P.K_BACK * response * dt
          if A > T then A = T end
        elseif mem < 1 then
          -- At the cap with grip to spare: this band takes a bit more than remembered.
          setLevel(self, gear, band, math.min(1, mem + P.CREEP * response * dt))
        end
      end
    end
    self.A = A
  end

  local A = self.A
  local out = requested < A and requested or A
  self.k = requested > 0.02 and out / requested or 1
  self.limit = A
  self.severe = self.slip > 2 * target
  self.memoryNow = mem
  self.active = out < requested - 0.005 and requested > 0.02
  return out
end

return M
