-- One plain table ST with the scalars the scenarios need, filled once per frame from ac.getCar(0) / ac.getSim().
-- Optional fields are probed once per car under pcall (the car state struct is generated from C++ and not public);
-- a field that is missing stays at its neutral value. Fields used here were all seen in official apps (RGBControl,
-- Unbound, CSP's led_colors / stalling modules).

local csp = require('src/csp')
local ac = csp.ac
local M = {}

local ST = {
  t = 0, dt = 0, ready = false,
  speed = 0, rpm = 0, rpmLimiter = 8000, rpmMin = 800, shiftUp = 0, shiftKnown = false, gear = 0, gas = 0, brake = 0,
  fuel = 100, fuelWarn = 0, pitLimiter = false, inPitlane = false, inPit = false, engineLimiter = false,
  drsPresent = false, drsAvailable = false, drsActive = false, absInAction = false, tcInAction = false,
  hasAbs = false, hasTc = false, engineLife = 1000, damage = 0, flag = 0, timeToStart = -1e9, sessionStarted = true,
  limiterKnown = false, limiterRpm = 8000, shiftStartManual = 0, rain = 0, wetness = 0, timeHours = 12, lap = 0, position = 0, steer = 0, lapTimeMs = 0, lastLapMs = 0, bestLapMs = 0, delta = 0,
  headlights = false, lowBeams = false, hazards = false, isOnline = false, replay = false, paused = false,
  standingFor = 0,       -- s below 2 km/h
  engineOff = false,
}
M.ST = ST

-- car field name -> ST key (copied as is when the field exists)
local CAR_FIELDS = {
  { 'speedKmh', 'speed' }, { 'rpm', 'rpm' }, { 'gear', 'gear' }, { 'gas', 'gas' }, { 'brake', 'brake' },
  { 'fuel', 'fuel' }, { 'manualPitsSpeedLimiterEnabled', 'pitLimiter' }, { 'isInPitlane', 'inPitlane' },
  { 'isInPit', 'inPit' }, { 'isEngineLimiterOn', 'engineLimiter' }, { 'drsPresent', 'drsPresent' },
  { 'drsAvailable', 'drsAvailable' }, { 'drsActive', 'drsActive' }, { 'absInAction', 'absInAction' },
  { 'tractionControlInAction', 'tcInAction' }, { 'engineLifeLeft', 'engineLife' }, { 'lapCount', 'lap' },
  { 'racePosition', 'position' }, { 'steer', 'steer' }, { 'headlightsActive', 'headlights' },
  { 'lowBeams', 'lowBeams' }, { 'hazardLights', 'hazards' }, { 'lapTimeMs', 'lapTimeMs' },
  { 'previousLapTimeMs', 'lastLapMs' }, { 'bestLapTimeMs', 'bestLapMs' }, { 'performanceMeter', 'delta' },
}
local SIM_FIELDS = {
  { 'raceFlagType', 'flag' }, { 'timeToSessionStart', 'timeToStart' }, { 'isSessionStarted', 'sessionStarted' },
  { 'rainIntensity', 'rain' }, { 'rainWetness', 'wetness' }, { 'timeHours', 'timeHours' },
  { 'isOnlineRace', 'isOnline' }, { 'isReplayActive', 'replay' }, { 'isPaused', 'paused' },
}

local carHas, simHas = {}, {}
local hasDamage = false
local probedFor = nil

local function readField(obj, name) return obj[name] end

local function probe(car, sim)
  for i = 1, #CAR_FIELDS do
    local ok, v = pcall(readField, car, CAR_FIELDS[i][1])
    carHas[i] = ok and v ~= nil
  end
  for i = 1, #SIM_FIELDS do
    local ok, v = pcall(readField, sim, SIM_FIELDS[i][1])
    simHas[i] = ok and v ~= nil
  end
  hasDamage = pcall(function () return car.damage[0] + car.damage[3] end)
  -- the car's own value (percentages in conditions); the effective range (limiterRpm, shiftUp) comes from rpm.lua
  local okL, lim = pcall(readField, car, 'rpmLimiter')
  ST.rpmLimiter = (okL and tonumber(lim) and lim > 0) and lim or 8000
  local okM, mn = pcall(readField, car, 'rpmMinimum')
  ST.rpmMin = okM and tonumber(mn) and mn > 0 and mn or 800
  local okA, abs = pcall(readField, car, 'absModes')
  ST.hasAbs = okA and (tonumber(abs) or 0) > 0
  local okT, tc = pcall(readField, car, 'tractionControlModes')
  ST.hasTc = okT and (tonumber(tc) or 0) > 0
end

-- Car facts from car_info (once per car): shift point from ai.ini, fuel warning from car.ini.
function M.setCarInfo(info)
  probedFor = nil
  local up = info and tonumber(info.shiftUp) or 0
  ST.shiftKnown = up > 0
  ST.shiftUp = up
  ST.fuelWarn = info and tonumber(info.fuelWarn) or 0
end

function M.availability()
  return { carHas = carHas, simHas = simHas, damage = hasDamage }
end

function M.fill(dt)
  local car, sim = ac.getCar(0), ac.getSim()
  ST.dt = dt
  ST.t = ST.t + dt
  if not car or not sim then ST.ready = false return ST end
  if probedFor ~= car then probe(car, sim); probedFor = car end
  ST.ready = true
  for i = 1, #CAR_FIELDS do
    if carHas[i] then ST[CAR_FIELDS[i][2]] = car[CAR_FIELDS[i][1]] end
  end
  for i = 1, #SIM_FIELDS do
    if simHas[i] then ST[SIM_FIELDS[i][2]] = sim[SIM_FIELDS[i][1]] end
  end
  if hasDamage then
    local d = car.damage
    local m = d[0]
    if d[1] > m then m = d[1] end
    if d[2] > m then m = d[2] end
    if d[3] > m then m = d[3] end
    ST.damage = m
  end
  ST.flag = tonumber(ST.flag) or 0
  if ST.speed < 2 then ST.standingFor = ST.standingFor + dt else ST.standingFor = 0 end
  ST.engineOff = ST.rpm < ST.rpmMin * 0.5
  return ST
end

return M
