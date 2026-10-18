-- Pit lane lights on the car's own shift LEDs: while our car is in the pit lane, a light runs across the cockpit RPM
-- LEDs from side to side (or every other LED blinks in turn), in the pit colour.
-- The LEDs are not changed: AC keeps driving them by RPM (writing their ksEmissive as well made them flicker, the two
-- fought every frame). Instead glowing discs are drawn over them in the main 3D pass (render.on('main.root.transparent'),
-- render.circle) the way CSP's Traffic tool draws its virtual traffic lights.
-- LEDs: digital_instruments.ini [LED_n] OBJECT_NAME (ac.INIConfig.carData), meshes found under
-- ac.findNodes('carRoot:0') with :findMeshes(name); without that file the meshes CSP marks as LEDs ('{ actsAsLED:yes }',
-- CSP's show_important_wheels filter). Position: the mesh's :boundingSphere() in its parent's coordinates, through the
-- parent's live world matrix (:getWorldTransformationRaw() returns a reference, kept). Ordered left to right once.
-- Cars whose dash is a CSP script or a screen texture have no such meshes. Everything under pcall; no per-frame allocation.

local config = require('src/config')
local pitLights = require('src/pit_lights')
local S = config.S

local M = { count = 0, source = '', active = false }

local leds = {}                -- { centre = vec3 (parent space), radius, matrix = parent world matrix, power }
local session = -1
local worldPos, toCam = vec3(), vec3()
local fill, edge = rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 0)
local callbackSet = false

local function maxComponent(v)
  if type(v) == 'table' then
    local m = 0
    for i = 1, #v do m = math.max(m, tonumber(v[i]) or 0) end
    return m
  end
  return tonumber(v) or 0
end

local function addMesh(ref, power)
  local centre, radius = ref:boundingSphere(1, vec3())
  if not centre or not radius or radius <= 0 then return end
  local matrix = ref:getParent():getWorldTransformationRaw()
  if not matrix then return end
  leds[#leds + 1] = { centre = centre, radius = radius, matrix = matrix, power = power > 0 and power or 20, side = 0 }
end

local function fromInstruments(root)
  local ini = ac.INIConfig.carData(0, 'digital_instruments.ini')
  if not ini then return end
  for i = 0, 63 do
    local section = 'LED_' .. i
    local name = ini:get(section, 'OBJECT_NAME', '')
    if type(name) == 'table' then name = name[1] end
    if type(name) == 'string' and name ~= '' then
      local ref = root:findMeshes(name)
      if ref and #ref > 0 then addMesh(ref, maxComponent(ini:get(section, 'EMISSIVE', nil))) end
    end
  end
  if #leds > 0 then M.source = 'digital_instruments.ini' end
end

local function fromCspMarks(root)
  local all = root:findMeshes('{ actsAsLED:yes }')
  if not all then return end
  for k = 1, #all do addMesh(all:at(k), 20) end
  if #leds > 0 then M.source = 'CSP (actsAsLED)' end
end

-- Left to right across the car (for the running light).
local function order(car)
  local p, sd = car.position, car.side
  for k = 1, #leds do
    local led = leds[k]
    led.matrix:transformPointTo(worldPos, led.centre)
    led.side = (worldPos.x - p.x) * sd.x + (worldPos.y - p.y) * sd.y + (worldPos.z - p.z) * sd.z
  end
  table.sort(leds, function (a, b) return a.side < b.side end)
end

local function load(car)
  leds, M.source = {}, ''
  local root = ac.findNodes('carRoot:0')
  if not root then return end
  pcall(fromInstruments, root)
  if #leds == 0 then pcall(fromCspMarks, root) end
  if #leds > 0 then pcall(order, car) end
  M.count = #leds
end

-- Brightness 0..1 of LED k of n at time t.
local SCAN_PERIOD = 1.4
local function level(k, n, t)
  if S.carLedsStyle == 2 then
    return (k % 2 == math.floor(t / 0.3) % 2) and 1 or 0           -- every other LED, then the others
  end
  if n == 1 then return 0.5 + 0.5 * math.cos(t / SCAN_PERIOD * 2 * math.pi) end
  local u = (k - 1) / (n - 1)
  local p = 0.5 - 0.5 * math.cos(t / SCAN_PERIOD * 2 * math.pi)  -- eased: slows down at the ends
  local width = math.max(0.12, 1.3 / n)
  local x = math.max(0, 1 - math.abs(u - p) / width)
  return x * x * (3 - 2 * x)
end

local function draw()
  if not M.active then return end
  local cam = ac.getSim().cameraPosition
  local c = pitLights.colorAt(S.carLedsColor)
  local n, t = #leds, os.preciseClock()
  render.setDepthMode(render.DepthMode.Normal)
  for k = 1, n do
    local led = leds[k]
    local b = level(k, n, t)
    if b > 0.02 then
      led.matrix:transformPointTo(worldPos, led.centre)
      toCam:set(cam.x - worldPos.x, cam.y - worldPos.y, cam.z - worldPos.z)
      local len = math.max(1e-4, math.sqrt(toCam.x * toCam.x + toCam.y * toCam.y + toCam.z * toCam.z))
      -- just in front of the LED towards the eye, so the LED's own geometry does not cover the disc
      local lift = led.radius * 1.1 / len
      worldPos:set(worldPos.x + toCam.x * lift, worldPos.y + toCam.y * lift, worldPos.z + toCam.z * lift)
      local power = led.power * b
      fill.r, fill.g, fill.b, fill.mult = c.r * power, c.g * power, c.b * power, 1
      render.circle(worldPos, toCam, led.radius, fill, edge)
    end
  end
end

local drawFailed = false
local function safeDraw()
  if drawFailed then return end
  local ok, err = pcall(draw)
  if not ok then
    drawFailed = true
    M.source = 'chyba: ' .. tostring(err)
  end
end

local function step()
  local car, sim = ac.getCar(0), ac.getSim()
  if not car or not sim then return end
  if sim.currentSessionIndex ~= session then
    session = sim.currentSessionIndex
    load(car)
  end
  M.active = S.carLedsPit and car.isInPitlane and #leds > 0
  if M.active and not callbackSet then
    callbackSet = true
    render.on('main.root.transparent', safeDraw)
  end
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

-- For tests: the brightness pattern.
M.level = level

return M
