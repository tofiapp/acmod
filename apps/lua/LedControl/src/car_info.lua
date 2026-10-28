-- Facts about the player's car read once per car: LED sections of digital_instruments.ini (all keys dumped raw, the
-- format besides OBJECT_NAME is not documented publicly), CSP car config emissive sections driven by RPM, generator
-- lines, ai.ini shift point. ac.INIConfig.carData also reads data.acd.

local csp = require('src/csp')
local ac = csp.ac
local M = {}

local function first(list)
  if type(list) == 'table' then return list[1] end
  return list
end

local function upper(s)
  return type(s) == 'string' and s:upper() or ''
end

local function read()
  local info = { carId = ac.getCarID(0) or '', leds = {}, cspRpm = {}, generators = {}, cspSections = 0,
    shiftUp = 0, fuelWarn = 0, errors = {} }

  local ok, ini = pcall(ac.INIConfig.carData, 0, 'digital_instruments.ini')
  if ok and ini and ini.sections then
    for name, keys in pairs(ini.sections) do
      local n = tostring(name):match('^LED_(%d+)$')
      if n then
        info.leds[#info.leds + 1] = { index = tonumber(n), section = name, keys = keys,
          rpm = tonumber(first(keys.RPM_SWITCH)) }
      end
    end
    table.sort(info.leds, function (a, b) return a.index < b.index end)
  elseif not ok then
    info.errors[#info.errors + 1] = 'digital_instruments.ini: ' .. tostring(ini)
  end

  local ok2, cfg = pcall(ac.INIConfig.carConfig, 0)
  info.cspConfig = ok2 and cfg or false
  if ok2 and cfg and cfg.sections then
    for name, keys in pairs(cfg.sections) do
      info.cspSections = info.cspSections + 1
      name = tostring(name)
      if name:find('^EMISSIVE') and upper(first(keys.INPUT)) == 'RPM' then
        info.cspRpm[#info.cspRpm + 1] = { section = name, names = type(keys.NAME) == 'table' and keys.NAME or {},
          threshold = tonumber(first(keys.INPUT_THRESHOLD)), color = keys.COLOR }
      end
      local gen = keys['@']
      if gen and #info.generators < 40 then
        info.generators[#info.generators + 1] = name .. ': @ = ' .. table.concat(gen, ', ')
      end
    end
    table.sort(info.cspRpm, function (a, b) return a.section < b.section end)
    table.sort(info.generators)
  elseif not ok2 then
    info.errors[#info.errors + 1] = 'CSP config: ' .. tostring(cfg)
  end

  local ok3, ai = pcall(ac.INIConfig.carData, 0, 'ai.ini')
  if ok3 and ai then
    local ok4, up = pcall(ai.get, ai, 'GEARS', 'UP', 0)
    if ok4 then info.shiftUp = tonumber(up) or 0 end
  end

  -- fuel warning light as CSP's led_colors / RGBControl read it
  local ok5, carIni = pcall(ac.INIConfig.carData, 0, 'car.ini')
  if ok5 and carIni then
    local ok6, w = pcall(carIni.get, carIni, 'GRAPHICS', 'FUEL_LIGHT_MIN_LITERS', 0)
    if ok6 then info.fuelWarn = tonumber(w) or 0 end
  end
  return info
end

-- Cached per car id: the car's files do not change during a session, and CSP's car config can be slow to parse.
local cache = { id = nil, info = nil }

function M.read()
  local id = ac.getCarID(0)
  if cache.info and cache.id == id then return cache.info end
  local ok, info = pcall(read)
  if ok then
    cache.id, cache.info = id, info
    return info
  end
  return { carId = '', leds = {}, cspRpm = {}, generators = {}, cspSections = 0, shiftUp = 0, fuelWarn = 0,
    errors = { tostring(info) } }
end

return M
