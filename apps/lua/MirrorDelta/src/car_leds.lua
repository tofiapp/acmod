-- Pit lane lights on the car's own shift LEDs: while our car is in the pit lane, a light runs across the cockpit RPM
-- LEDs from side to side (or every other LED blinks in turn), in the pit colour.
-- The LEDs are not changed: AC keeps driving them by RPM (writing their ksEmissive as well made them flicker, the two
-- fought every frame). Instead glowing discs are drawn over them in the main 3D pass (render.on('main.root.transparent'),
-- render.circle) the way CSP's Traffic tool draws its virtual traffic lights.
-- LEDs: digital_instruments.ini [LED_n] OBJECT_NAME (ac.INIConfig.carData), meshes found under
-- ac.findNodes('carRoot:0') with :findMeshes(name); without that file the meshes CSP marks as LEDs ('{ actsAsLED:yes }',
-- CSP's show_important_wheels filter). Position: the mesh's :boundingSphere() in its parent's space, taken to world space
-- every frame by multiplying the live local matrices up the node chain (:getTransformationRaw() references, kept from
-- the pit entry; CSP's vr_rig_base getActualTransform does the same). Earlier tries: the cached world matrix was stale
-- (the lights stayed behind), and going through car.worldToLocal / car.transform put them above the LEDs (the model
-- is offset from the physics body). Following the model's own nodes also follows a turning steering wheel.
-- Cars whose dash is a CSP script or a screen texture have no such meshes. Everything under pcall; no per-frame allocation.

local config = require('src/config')
local pitLights = require('src/pit_lights')
local S = config.S

local M = { count = 0, source = '', active = false }

local leds = {}                -- { ref = mesh, centre = vec3 (parent space), radius, pos = vec3 (car space) }
local session = -1
local worldPos, toCam = vec3(), vec3()
local fill, edge = rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 0)
local callbackSet = false

local function addMesh(ref)
  local centre, radius = ref:boundingSphere(1, vec3())
  if not centre or not radius or radius <= 0 then return end
  leds[#leds + 1] = { ref = ref, centre = centre, radius = radius, pos = vec3(), side = 0 }
end

-- The live local matrices from the LED's parent node up to the scene root (references to the nodes' own matrices).
local function chainOf(ref)
  local list = {}
  local n = ref:getParent()
  while n and #n > 0 and #list < 32 do
    list[#list + 1] = n:getTransformationRaw()
    n = n:getParent()
  end
  return list
end

local IDENT = mat4x4.identity()
local acc = mat4x4.identity()
-- World position of LED led into worldPos (local x parent x ... x root, as CSP's getActualTransform).
local function ledWorld(led)
  acc:set(IDENT)
  local chain = led.chain
  for i = 1, #chain do acc:mulSelf(chain[i]) end
  acc:transformPointTo(worldPos, led.centre)
end

-- Node chains of all LEDs, and their car-space positions for the left-to-right order.
local function locate(car)
  local w2l = car.worldToLocal
  for k = 1, #leds do
    local led = leds[k]
    led.chain = chainOf(led.ref)
    ledWorld(led)
    w2l:transformPointTo(led.pos, worldPos)
  end
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
      if ref and #ref > 0 then addMesh(ref) end
    end
  end
  if #leds > 0 then M.source = 'digital_instruments.ini' end
end

local function fromCspMarks(root)
  local all = root:findMeshes('{ actsAsLED:yes }')
  if not all then return end
  for k = 1, #all do addMesh(all:at(k)) end
  if #leds > 0 then M.source = 'CSP (actsAsLED)' end
end

-- Left to right across the car (for the running light): car space x.
local function order()
  table.sort(leds, function (a, b) return a.pos.x < b.pos.x end)
end

local function load(car)
  leds, M.source = {}, ''
  local root = ac.findNodes('carRoot:0')
  if not root then return end
  pcall(fromInstruments, root)
  if #leds == 0 then pcall(fromCspMarks, root) end
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
  local up = ac.getCar(0).up
  local c = pitLights.colorAt(S.carLedsColor)
  local n, t = #leds, os.preciseClock()
  render.setDepthMode(render.DepthMode.Normal)
  for k = 1, n do
    local led = leds[k]
    local b = level(k, n, t)
    if b > 0.02 then
      ledWorld(led)
      if S.carLedsOffset ~= 0 then                 -- manual nudge along the car's up axis, cm
        local h = S.carLedsOffset / 100
        worldPos:set(worldPos.x + up.x * h, worldPos.y + up.y * h, worldPos.z + up.z * h)
      end
      toCam:set(cam.x - worldPos.x, cam.y - worldPos.y, cam.z - worldPos.z)
      local len = math.max(1e-4, math.sqrt(toCam.x * toCam.x + toCam.y * toCam.y + toCam.z * toCam.z))
      -- just in front of the LED towards the eye, so the LED's own geometry does not cover the disc
      local lift = led.radius * 1.1 / len
      worldPos:set(worldPos.x + toCam.x * lift, worldPos.y + toCam.y * lift, worldPos.z + toCam.z * lift)
      local power = S.carLedsBrightness * b      -- a few times the white point: glows, but stays orange
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
  local active = S.carLedsPit and car.isInPitlane and #leds > 0
  if active and not M.active then                 -- pit entry: where the LEDs are now, left to right
    local ok = pcall(locate, car)
    if ok then pcall(order) else active = false end
  end
  M.active = active
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
