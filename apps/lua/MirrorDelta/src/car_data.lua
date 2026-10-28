-- Values from the car's own data files, read once per session (and again when the tyre compound changes):
-- - shift point: ai.ini [GEARS] UP, the optimal up-shift RPM (CSP's own RGBControl / LED colours use it for shift
--   colours). Race cars often want the shift before the rev limiter, so the gear bar and the blue blinking follow it.
-- - optimal tyre temperature window per axle: tyres.ini [THERMAL_FRONT(_n)] / [THERMAL_REAR(_n)] PERFORMANCE_CURVE
--   (temperature -> grip LUT; section suffix = car.compoundIndex, as in CSP's shared/sim/cars.lua), the range where the
--   grip is within 0.5 % of its best. Some race tyres have a wide or shifted window that a single number misses.
-- Each read runs under pcall; whatever is missing falls back (limiter, CSP's optimum field, the manual setting).

local config = require('src/config')
local S = config.S

local M = {
  aiShiftRpm = 0,              -- ai.ini value, 0 when missing
  tyreLo = { 0, 0 },           -- optimal window, front / rear; 0 = unknown
  tyreHi = { 0, 0 },
  tyreFromCurve = false,
}

local session, compound = -1, -1

local function readShift()
  local ini = ac.INIConfig.carData(0, 'ai.ini')
  local up = ini and tonumber(ini:get('GEARS', 'UP', 0)) or 0
  M.aiShiftRpm = up > 0 and up or 0
end

local GRIP_SHARE = 0.995
local function readWindow(ini, section, axle)
  M.tyreLo[axle], M.tyreHi[axle] = 0, 0
  local lut = ini:tryGetLut(section, 'PERFORMANCE_CURVE')
  if not lut or #lut < 2 then return end
  local best = -1e9
  for t = 0, 200 do
    local g = lut:get(t)
    if g > best then best = g end
  end
  if best <= 0 then return end
  local lo, hi = nil, nil
  for t = 0, 200 do
    if lut:get(t) >= best * GRIP_SHARE then
      lo = lo or t
      hi = t
    end
  end
  -- a curve that is flat over almost everything says nothing about the optimum
  if lo and hi - lo <= 70 then M.tyreLo[axle], M.tyreHi[axle] = lo, hi end
end

local function readTyres(car)
  local ini = ac.INIConfig.carData(0, 'tyres.ini')
  if not ini then return end
  local suffix = (car.compoundIndex or 0) == 0 and '' or '_' .. car.compoundIndex
  readWindow(ini, 'THERMAL_FRONT' .. suffix, 1)
  readWindow(ini, 'THERMAL_REAR' .. suffix, 2)
end

local function compoundOf(car)
  return car.compoundIndex
end

-- Call every frame (cheap); reads the files only when the session or the compound changes.
function M.update()
  local car, sim = ac.getCar(0), ac.getSim()
  if not car or not sim then return end
  local okC, c = pcall(compoundOf, car)
  c = okC and c or 0
  if sim.currentSessionIndex == session and c == compound then return end
  local newSession = sim.currentSessionIndex ~= session
  session, compound = sim.currentSessionIndex, c
  if newSession then
    M.aiShiftRpm = 0
    pcall(readShift)
  end
  M.tyreLo[1], M.tyreHi[1], M.tyreLo[2], M.tyreHi[2] = 0, 0, 0, 0
  pcall(readTyres, car)
  M.tyreFromCurve = M.tyreLo[1] > 0 or M.tyreLo[2] > 0
end

-- RPM at which to shift (where the bar is full and the blue blinking starts).
function M.shiftRpm(car)
  local limiter = car.rpmLimiter > 0 and car.rpmLimiter or 8000
  local point = limiter * 0.98
  local ai = M.aiShiftRpm
  if S.gearRpmSource == 1 and ai > limiter * 0.5 and ai < point then point = ai end
  return point * (1 + S.gearShiftAdjust / 100)
end

-- Source of the shift point, for the settings.
function M.shiftSourceText(car)
  local limiter = car.rpmLimiter > 0 and car.rpmLimiter or 8000
  local ai = M.aiShiftRpm
  if S.gearRpmSource == 1 and ai > limiter * 0.5 and ai < limiter * 0.98 then
    return string.format('optimální řazení auta %d ot/min (omezovač %d)', ai, limiter)
  end
  return string.format('omezovač %d ot/min%s', limiter, ai > 0 and string.format(' (řazení auta %d)', ai) or '')
end

return M
