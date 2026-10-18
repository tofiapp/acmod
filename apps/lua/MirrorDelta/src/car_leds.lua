-- Pit lane lights on the car's own shift LEDs: while our car is in the pit lane, the RPM LEDs in the cockpit blink
-- in turn (every other LED, then the others) in the pit colour, like a pit limiter display. Works for any car whose
-- shift lights are AC's digital instrument LEDs:
-- - digital_instruments.ini [LED_n] OBJECT_NAME (+ RPM_SWITCH for their order, EMISSIVE for their brightness), read
--   with ac.INIConfig.carData; the meshes are found under ac.findNodes('carRoot:0') with :findMeshes(name);
-- - without that file: the meshes CSP marks as LEDs ('{ actsAsLED:yes }', the filter CSP's show_important_wheels uses).
-- The light is set with :setMaterialProperty('ksEmissive', rgb) as CSP's own Traffic and Railworks tools light their
-- lamps. AC drives the same LEDs by RPM, so the pit pattern is written every frame while in the pit lane and all LEDs
-- are switched off once when leaving (AC lights them again with the revs). Cars whose dash is a CSP script or a
-- screen texture are not affected. Everything runs under pcall; no allocation per frame.

local config = require('src/config')
local pitLights = require('src/pit_lights')
local S = config.S

local M = { count = 0, source = '', active = false }

local leds = {}                -- { ref = SceneReference, group = 0/1, power = emissive multiplier }
local session = -1
local ON, OFF = rgb(), rgb()
local wasActive = false

local function maxComponent(v)
  if type(v) == 'table' then
    local m = 0
    for i = 1, #v do m = math.max(m, tonumber(v[i]) or 0) end
    return m
  end
  return tonumber(v) or 0
end

local function fromInstruments(root)
  local ini = ac.INIConfig.carData(0, 'digital_instruments.ini')
  if not ini then return end
  local found = {}
  for i = 0, 63 do
    local section = 'LED_' .. i
    local name = ini:get(section, 'OBJECT_NAME', '')
    if type(name) == 'table' then name = name[1] end
    if type(name) == 'string' and name ~= '' then
      local ref = root:findMeshes(name)
      if ref and #ref > 0 then
        found[#found + 1] = { ref = ref, rpm = tonumber(ini:get(section, 'RPM_SWITCH', 0)) or 0,
          power = maxComponent(ini:get(section, 'EMISSIVE', nil)), index = i }
      end
    end
  end
  table.sort(found, function (a, b) if a.rpm ~= b.rpm then return a.rpm < b.rpm end return a.index < b.index end)
  for k = 1, #found do
    local f = found[k]
    leds[#leds + 1] = { ref = f.ref, group = k % 2, power = f.power > 0 and f.power or 20 }
  end
  if #leds > 0 then M.source = 'digital_instruments.ini' end
end

local function fromCspMarks(root)
  local all = root:findMeshes('{ actsAsLED:yes }')
  if not all then return end
  for k = 1, #all do
    leds[#leds + 1] = { ref = all:at(k), group = k % 2, power = 20 }
  end
  if #leds > 0 then M.source = 'CSP (actsAsLED)' end
end

local function load()
  leds, M.source = {}, ''
  local root = ac.findNodes('carRoot:0')
  if not root then return end
  pcall(fromInstruments, root)
  if #leds == 0 then pcall(fromCspMarks, root) end
  M.count = #leds
end

local function setAll(phase)
  local c = pitLights.colorAt(S.carLedsColor)
  for k = 1, #leds do
    local led = leds[k]
    if phase >= 0 and led.group == phase then
      ON:set(c.r * led.power, c.g * led.power, c.b * led.power)
      led.ref:setMaterialProperty('ksEmissive', ON)
    else
      led.ref:setMaterialProperty('ksEmissive', OFF)
    end
  end
end

local function step()
  local car, sim = ac.getCar(0), ac.getSim()
  if not car or not sim then return end
  if sim.currentSessionIndex ~= session then
    session = sim.currentSessionIndex
    load()
  end
  local active = S.carLedsPit and car.isInPitlane and #leds > 0
  M.active = active
  if active then
    setAll(math.floor(os.preciseClock() / 0.3) % 2)   -- every other LED, then the others, ~1.7 times a second each
  elseif wasActive then
    setAll(-1)                                          -- all off; AC lights them again by RPM
  end
  wasActive = active
end

local failed = false
function M.update()
  if failed then return end
  local ok, err = pcall(step)
  if not ok then
    failed = true
    M.source = 'chyba: ' .. tostring(err)
  end
end

return M
