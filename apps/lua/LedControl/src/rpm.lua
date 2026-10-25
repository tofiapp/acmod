-- RPM range of the player's car for the shift lights: where they start, where they are full (shift point) and where
-- the limiter blinks, plus optional RPM values per LED of the main row. Per car, saved in the car profile (profile.rpm).
--
-- Automatic values (each can be overridden by hand, nil = automatic):
--   limiter: the RPM at which AC's own limiter flag (car.isEngineLimiterOn) switched on, learned while driving and
--            saved; else car.rpmLimiter; else ai.ini [GEARS] UP / 0.97; else 8000 (then only AC's flag blinks it).
--   shift:   ai.ini [GEARS] UP only when it lies below 97 % of the limiter (race cars often have an AI shift point at
--            or above the limiter, which left the lights half full while the limiter already blinked); else 97 % of
--            the limiter (MirrorDelta's car_data.lua uses the same rule).
--   start:   the preset's "Začátek" percentage of the shift point.
-- Writes ST.shiftUp (effective), ST.shiftStartManual (0 = from the preset), ST.limiterRpm, ST.limiterKnown.
-- No allocation in update().

local M = { version = 0, learned = 0, maxSeen = 0, flagUnreliable = false, auto = {}, ledRpm = nil }

local profile = nil
local saveFn = nil
local carLimiter, aiUp = 0, 0
local edgeWas = false
local lowFlagTime = 0
local saveDue = -1
local clock = 0

local MIN_RPM, MAX_RPM = 500, 30000

local function bump() M.version = M.version + 1 end

local function num(v)
  v = tonumber(v)
  if not v or v ~= v or v < MIN_RPM or v > MAX_RPM then return nil end
  return math.floor(v + 0.5)
end

-- Clean copy of a stored profile.rpm (store.lua calls it).
function M.sanitise(t)
  if type(t) ~= 'table' then return nil end
  local out = { start = num(t.start), shift = num(t.shift), limiter = num(t.limiter), learned = num(t.learned) }
  if type(t.leds) == 'table' then
    out.leds = {}
    for i = 1, math.min(#t.leds, 64) do out.leds[i] = num(t.leds[i]) or MIN_RPM end
    if #out.leds == 0 then out.leds = nil end
  end
  if not (out.start or out.shift or out.limiter or out.learned or out.leds) then return nil end
  return out
end

local function cfg()
  if not profile then return {} end
  if type(profile.rpm) ~= 'table' then profile.rpm = {} end
  return profile.rpm
end

local function compute(ST)
  local c = cfg()
  local a = M.auto
  -- limiter
  if (c.learned or 0) > 0 then a.limiter, a.limiterFrom = c.learned, 'naměřeno ve hře'
  elseif carLimiter > 0 then a.limiter, a.limiterFrom = carLimiter, 'z auta'
  elseif aiUp > 0 then a.limiter, a.limiterFrom = math.floor(aiUp / 0.97 + 0.5), 'odhad z ai.ini'
  else a.limiter, a.limiterFrom = 8000, 'neznámý' end
  local limiter = c.limiter or a.limiter
  -- shift point
  if aiUp > 0 and aiUp < limiter * 0.97 and aiUp > limiter * 0.5 then a.shift, a.shiftFrom = aiUp, 'ai.ini'
  else a.shift, a.shiftFrom = math.floor(limiter * 0.97 + 0.5), aiUp > 0 and '97 % omezovače (ai.ini je výš)' or '97 % omezovače' end
  local shift = c.shift or a.shift
  M.limiter, M.shift, M.start = limiter, shift, c.start or 0
  M.limiterKnown = c.limiter ~= nil or (c.learned or 0) > 0 or carLimiter > 0
  M.ledRpm = c.leds
  ST.shiftUp, ST.shiftKnown = shift, true
  ST.shiftStartManual = c.start or 0
  ST.limiterRpm, ST.limiterKnown = limiter, M.limiterKnown
  bump()
end

-- On every car detection: info = car_info (ai.ini UP), save = function () that writes the car profile.
function M.init(prof, info, ST, save)
  profile, saveFn = prof, save
  aiUp = info and tonumber(info.shiftUp) or 0
  if aiUp ~= aiUp then aiUp = 0 end
  local car = ac.getCar(0)
  local ok, lim = pcall(function () return car and car.rpmLimiter end)
  carLimiter = (ok and tonumber(lim) and lim > 0) and lim or 0
  M.maxSeen, M.flagUnreliable, edgeWas, lowFlagTime = 0, false, false, 0
  local c = cfg()
  M.learned = c.learned or 0
  compute(ST)
end

local function save()
  if saveFn then saveFn() end
end

-- Every frame after car_state.fill: learns the limiter from AC's flag (rising edge at high RPM).
function M.update(ST, dt)
  clock = clock + dt
  if saveDue > 0 and clock >= saveDue then saveDue = -1; save() end
  local rpm = ST.rpm
  if rpm > M.maxSeen then M.maxSeen = rpm end
  local flag = ST.engineLimiter == true
  -- a flag that is on at low RPM is not the limiter cutting: ignore it from then on
  if flag and rpm < M.limiter * 0.5 then
    lowFlagTime = lowFlagTime + dt
    if lowFlagTime > 2 and not M.flagUnreliable then M.flagUnreliable = true; bump() end
  else
    lowFlagTime = 0
  end
  if flag and not edgeWas and not M.flagUnreliable and rpm > 2500 and rpm > M.shift * 0.7 then
    local learned = math.floor(rpm + 0.5)
    if math.abs(learned - M.learned) > 50 and (M.learned == 0 or learned > M.learned) then
      M.learned = learned
      cfg().learned = learned
      compute(ST)
      saveDue = clock + 2
    end
  end
  edgeWas = flag
  if M.flagUnreliable then ST.engineLimiter = false end
end

-- key 'start' | 'shift' | 'limiter': a number (RPM) or nil = automatic.
function M.set(key, value, ST)
  local c = cfg()
  c[key] = num(value)
  compute(ST)
  saveDue = clock + 0.5
end

function M.forgetLearned(ST)
  local c = cfg()
  c.learned, M.learned = nil, 0
  compute(ST)
  save()
end

-- RPM per LED of the main row (n LEDs, left to right); nil switches it off.
function M.setLeds(list, ST)
  local c = cfg()
  if type(list) == 'table' then
    c.leds = {}
    for i = 1, math.min(#list, 64) do c.leds[i] = num(list[i]) or MIN_RPM end
  else
    c.leds = nil
  end
  compute(ST)
  saveDue = clock + 0.5
end

function M.setLed(k, value, ST)
  local c = cfg()
  if type(c.leds) ~= 'table' or not c.leds[k] then return end
  c.leds[k] = num(value) or c.leds[k]
  compute(ST)
  saveDue = clock + 0.5
end

-- n values spread evenly from the start of the shift lights to the shift point.
function M.spread(n, startRpm, ST)
  local list = {}
  local a, b = startRpm, M.shift
  for k = 1, n do list[k] = n > 1 and math.floor(a + (b - a) * (k - 1) / (n - 1) + 0.5) or b end
  M.setLeds(list, ST)
end

function M.flush()
  if saveDue > 0 then saveDue = -1; save() end
end

return M
