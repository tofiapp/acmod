-- Pit lane lights in the cockpit: while our car is in the pit lane, a light runs from side to side (or every other
-- LED blinks in turn) in the pit colour, either on the car's own shift LEDs or on a virtual LED bar in front of the
-- driver (the same on every car), see S.carLedsVirtual.
--
-- The car's LEDs. Their materials are not changed: AC keeps driving them by RPM (writing their ksEmissive as well made
-- them flicker, the two fought every frame). Instead they are drawn again on top in the main 3D pass
-- (render.on('main.root.transparent')). Meshes: 1. digital_instruments.ini [LED_n] OBJECT_NAME (ac.INIConfig.carData),
-- found under ac.findNodes('carRoot:0') with :findMeshes(name); 2. the meshes CSP marks as LEDs ('{ actsAsLED:yes }',
-- CSP's show_important_wheels filter); 3. cockpit meshes named like LEDs ('?LED?', '?RPM?', '?SHIFT?'). Position: the
-- mesh's :boundingSphere() in its parent's space, taken to world space every frame by multiplying the live local
-- matrices up the node chain (:getTransformationRaw() references; CSP's vr_rig_base getActualTransform does the same;
-- the cached world matrix was stale and car.worldToLocal / car.transform put the lights above the LEDs, the model is
-- offset from the physics body). Drawing (drawMeshes): every LED mesh again with render.mesh and an own matrix = the
-- node chain, the mesh scaled up a little around its centre and moved a few mm towards the camera, so it covers AC's
-- own LED without depth fighting; 'original' transform as the first fallback, glowing discs as the last.
-- Whether they fit is checked at every pit entry (in the cockpit, with the cockpit LOD active; at the session start
-- another camera / LOD may be active and the check went wrong): a dash drawn by a CSP script, hidden, oversized or far
-- away meshes, fewer than two left = the car's LEDs are not used and the virtual bar takes over.
--
-- The virtual bar: S.carLedsVirtualCount discs in a row in front of the driver's eyes (car.driverEyesPosition through
-- car.transform; distance and height settings), drawn with render.circle facing the camera, on top of everything, as
-- CSP's Traffic tool draws its virtual traffic lights. Everything under pcall; no per-frame allocation.

local config = require('src/config')
local pitLights = require('src/pit_lights')
local S = config.S

local M = { count = 0, found = 0, source = '', active = false, useMeshes = false, useVirtual = false, fits = false,
  reason = '', dropped = '', testing = false, drawMode = 1 }

local allLeds, checked, leds = {}, {}, {}   -- every LED mesh found / those that passed the check / the ones drawn
local session = -1
local worldPos, toCam, localPos = vec3(), vec3(), vec3()
local fill, edge = rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 0)
local callbackSet = false

-- ---------------------------------------------------------------- the car's LED meshes

local GROW = 1.08              -- the redrawn LED is this much bigger than the mesh, so it covers it fully
local function addMesh(ref)
  local centre, radius = ref:boundingSphere(1, vec3())
  if not centre or not radius or radius <= 0 then return end
  -- scale about the mesh centre (in its own space): v * T(-c) * S * T(c)
  local grow = mat4x4.translation(vec3(-centre.x, -centre.y, -centre.z))
    :mul(mat4x4.scaling(vec3(GROW, GROW, GROW))):mul(mat4x4.translation(centre))
  allLeds[#allLeds + 1] = { ref = ref, centre = centre, radius = radius, pos = vec3(), grow = grow, chain = {} }
end

-- The live local matrices from the LED mesh (when it has one) and its nodes up to the scene root (references).
local function matrixOf(n) return n:getTransformationRaw() end
local function chainOf(ref)
  local list = {}
  local n = ref
  while n and #n > 0 and #list < 32 do
    local ok, m = pcall(matrixOf, n)
    if ok and m then list[#list + 1] = m end
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

local function fromInstruments(root)
  local ini = ac.INIConfig.carData(0, 'digital_instruments.ini')
  if not ini then return end
  for i = 0, 63 do
    local section = 'LED_' .. i
    local name = ini:get(section, 'OBJECT_NAME', '')
    if type(name) == 'table' then name = name[1] end
    if type(name) == 'string' and name ~= '' then
      -- the cockpit LOD's mesh of that name (as CSP's Radar filters '& lod:A'), else any mesh of that name
      local ok, refA = pcall(root.findMeshes, root, '{ (' .. name .. ') & lod:A }')
      local ref = (ok and refA and #refA > 0) and refA or root:findMeshes(name)
      if ref and #ref > 0 then addMesh(ref) end
    end
  end
  if #allLeds > 0 then M.source = 'digital_instruments.ini' end
end

local function fromCspMarks(root)
  local all = root:findMeshes('{ actsAsLED:yes }')
  if not all then return end
  for k = 1, #all do addMesh(all:at(k)) end
  if #allLeds > 0 then M.source = 'CSP (actsAsLED)' end
end

-- Last resort: cockpit meshes named like shift LEDs (the size / distance check drops what is not one).
local function fromNames(root)
  local all = root:findMeshes('{ (?LED?, ?RPM?, ?SHIFT?) & lod:A }')
  if not all then return end
  for k = 1, #all do addMesh(all:at(k)) end
  if #allLeds > 0 then M.source = 'podle názvu' end
end

-- Finds the LED meshes once per session (the check whether they fit runs at every pit entry).
local function load()
  allLeds, checked, leds, M.source = {}, {}, {}, ''
  local root = ac.findNodes('carRoot:0')
  if not root then return end
  pcall(fromInstruments, root)
  if #allLeds == 0 then pcall(fromCspMarks, root) end
  if #allLeds == 0 then pcall(fromNames, root) end
  M.found = #allLeds
end

-- ---------------------------------------------------------------- does it fit this car? (at every pit entry)
local MAX_RADIUS, MAX_EYES = 0.06, 1.8

local function scriptedDash()
  local cfg = ac.INIConfig.carConfig(0)
  if not cfg or type(cfg.sections) ~= 'table' then return false end
  for name in pairs(cfg.sections) do
    if type(name) == 'string' and name:find('^SCRIPTABLE_DISPLAY') then return true end
  end
  return false
end

local function isShown(ref) return ref:isVisible() end

local eyesWorld = vec3()
local function checkLeds(car)
  car.transform:transformPointTo(eyesWorld, car.driverEyesPosition)
  local w2l = car.worldToLocal
  local kept, hiddenN, big, far = {}, 0, 0, 0
  local n = #allLeds
  for k = 1, n do
    local led = allLeds[k]
    led.chain = chainOf(led.ref)
    ledWorld(led)
    w2l:transformPointTo(led.pos, worldPos)
    local dx, dy, dz = worldPos.x - eyesWorld.x, worldPos.y - eyesWorld.y, worldPos.z - eyesWorld.z
    local okV, shown = pcall(isShown, led.ref)
    led.hidden = okV and shown == false
    if led.hidden then hiddenN = hiddenN + 1 end
    led.big = led.radius > MAX_RADIUS
    led.far = dx * dx + dy * dy + dz * dz > MAX_EYES * MAX_EYES
    if led.big then big = big + 1 elseif led.far then far = far + 1 end
  end
  -- all hidden: the cockpit LOD is not the active one right now (another camera), not a reason to drop them
  local dropHidden = hiddenN > 0 and hiddenN < n
  for k = 1, n do
    local led = allLeds[k]
    if not led.big and not led.far and not (dropHidden and led.hidden) then kept[#kept + 1] = led end
  end
  checked = kept
  local parts = {}
  if dropHidden then parts[#parts + 1] = string.format('%d skrytých', hiddenN) end
  if big > 0 then parts[#parts + 1] = string.format('%d moc velkých', big) end
  if far > 0 then parts[#parts + 1] = string.format('%d mimo kokpit', far) end
  M.dropped = table.concat(parts, ', ')
end

-- Per car choice: 0 automatic, 1 always the car's LEDs, 2 never the car's LEDs.
local choiceCache, choiceId, choiceList = 0, nil, nil
function M.carChoice()
  local id, list = ac.getCarID(0) or '', S.carLedsCars or ''
  if id == choiceId and list == choiceList then return choiceCache end   -- no strings built per frame
  choiceId, choiceList, choiceCache = id, list, 0
  for entry in list:gmatch('[^;]+') do
    local name, v = entry:match('^(.-)=(%d)$')
    if name == id then choiceCache = tonumber(v) or 0 end
  end
  return choiceCache
end

function M.setCarChoice(choice)
  local id = ac.getCarID(0) or ''
  local list = {}
  for entry in (S.carLedsCars or ''):gmatch('[^;]+') do
    if entry:match('^(.-)=') ~= id then list[#list + 1] = entry end
  end
  if choice ~= 0 then list[#list + 1] = id .. '=' .. choice end
  config.set('carLedsCars', table.concat(list, ';'))
end

-- Left to right across the car (for the running light): car space x.
local function order()
  table.sort(leds, function (a, b) return a.pos.x < b.pos.x end)
end

-- Pit entry: checks the car's LEDs as they are now and decides what to draw.
local function evaluate(car)
  M.fits, M.reason, M.dropped, checked = false, '', '', {}
  if #allLeds == 0 then
    M.reason = 'auto nemá diody otáček jako díly modelu'
  else
    local okS, scripted = pcall(scriptedDash)
    if okS and scripted then
      M.reason = 'palubní deska je kreslená skriptem CSP'
    else
      local okC, err = pcall(checkLeds, car)
      if not okC then
        M.reason = 'kontrola selhala: ' .. tostring(err)
      elseif #checked < 2 then
        M.reason = 'diody nesedí (' .. (M.dropped ~= '' and M.dropped or 'žádné vhodné') .. ')'
      else
        M.fits = true
      end
    end
  end
  local choice = M.carChoice()
  local useMeshes = choice ~= 2 and S.carLedsVirtual ~= 2 and ((choice == 1 and #allLeds > 0) or (choice == 0 and M.fits))
  leds = {}
  if useMeshes then
    local src = choice == 1 and allLeds or checked
    if choice == 1 and #checked == 0 then pcall(checkLeds, car) end   -- chains for the forced LEDs
    for k = 1, #src do leds[k] = src[k] end
    pcall(order)
  end
  M.useMeshes = #leds > 0
  M.count = #leds
  M.useVirtual = S.carLedsVirtual == 2 or (S.carLedsVirtual == 1 and not M.useMeshes)
end

-- ---------------------------------------------------------------- brightness pattern
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

-- ---------------------------------------------------------------- drawing the car's LEDs
local MESH = {
  mesh = false,
  transform = 'original',
  textures = {},
  values = { gColor = rgbm(0, 0, 0, 1) },
  cacheKey = 7301,
  shader = [[
    float4 main(PS_IN pin) {
      return float4(gColor.rgb * gWhiteRefPoint, 1);
    }
  ]],
}
local OFF_R, OFF_G, OFF_B = 0.025, 0.025, 0.03   -- an unlit LED
local LIFT = 0.003             -- m towards the camera
local lift = mat4x4.identity()

local function drawMeshes(c, n, t)
  render.setBlendMode(render.BlendMode.OpaqueForced)
  render.setDepthMode(render.DepthMode.LessEqual)
  render.setCullMode(render.CullMode.None)
  local col = MESH.values.gColor
  local br = S.carLedsBrightness
  local cam = ac.getSim().cameraPosition
  for k = 1, n do
    local led = leds[k]
    local b = level(k, n, t)
    col.r = OFF_R + (c.r * br - OFF_R) * b
    col.g = OFF_G + (c.g * br - OFF_G) * b
    col.b = OFF_B + (c.b * br - OFF_B) * b
    MESH.mesh = led.ref
    if M.drawMode == 1 then
      -- own matrix: grown about its centre, the car's node chain, then a few mm towards the camera (world space)
      acc:set(led.grow)
      local chain = led.chain
      for i = 1, #chain do acc:mulSelf(chain[i]) end
      acc:transformPointTo(worldPos, led.centre)
      toCam:set(cam.x - worldPos.x, cam.y - worldPos.y, cam.z - worldPos.z)
      local len = math.max(1e-4, math.sqrt(toCam.x * toCam.x + toCam.y * toCam.y + toCam.z * toCam.z))
      lift.position:set(toCam.x / len * LIFT, toCam.y / len * LIFT, toCam.z / len * LIFT)
      acc:mulSelf(lift)
      MESH.transform = acc
    else
      MESH.transform = 'original'
    end
    render.mesh(MESH)
  end
end

-- Last fallback (render.mesh cannot draw scene meshes in this CSP): glowing discs over the LEDs.
local function drawDiscs(c, n, t)
  local cam = ac.getSim().cameraPosition
  render.setDepthMode(render.DepthMode.Normal)
  for k = 1, n do
    local led = leds[k]
    local b = level(k, n, t)
    if b > 0.02 then
      ledWorld(led)
      toCam:set(cam.x - worldPos.x, cam.y - worldPos.y, cam.z - worldPos.z)
      local len = math.max(1e-4, math.sqrt(toCam.x * toCam.x + toCam.y * toCam.y + toCam.z * toCam.z))
      local up = led.radius * 1.1 / len                     -- just in front of the LED towards the eye
      worldPos:set(worldPos.x + toCam.x * up, worldPos.y + toCam.y * up, worldPos.z + toCam.z * up)
      local power = S.carLedsBrightness * b
      fill.r, fill.g, fill.b, fill.mult = c.r * power, c.g * power, c.b * power, 1
      render.circle(worldPos, toCam, led.radius, fill, edge)
    end
  end
end

-- ---------------------------------------------------------------- the virtual LED bar
local VIRTUAL_RADIUS = 0.011   -- m
local function drawVirtual(c, t)
  local car, sim = ac.getCar(0), ac.getSim()
  local cam, eyes, tr = sim.cameraPosition, car.driverEyesPosition, car.transform
  local n = math.max(2, math.min(16, math.floor(S.carLedsVirtualCount)))
  local width = S.carLedsVirtualWidth / 100
  local dist, drop = S.carLedsVirtualDist / 100, S.carLedsVirtualDrop / 100
  local br = S.carLedsBrightness
  render.setDepthMode(render.DepthMode.Off)      -- always in view, like a HUD element
  for k = 1, n do
    local x = -width / 2 + width * (k - 1) / (n - 1)   -- car space x grows to the left: k = 1 on the left
    localPos:set(eyes.x - x, eyes.y - drop, eyes.z + dist)
    tr:transformPointTo(worldPos, localPos)
    toCam:set(cam.x - worldPos.x, cam.y - worldPos.y, cam.z - worldPos.z)
    local b = level(k, n, t)
    fill.r = OFF_R + (c.r * br - OFF_R) * b
    fill.g = OFF_G + (c.g * br - OFF_G) * b
    fill.b = OFF_B + (c.b * br - OFF_B) * b
    fill.mult = 1
    render.circle(worldPos, toCam, VIRTUAL_RADIUS, fill, edge)
  end
end

local function draw()
  if not M.active then return end
  local c = pitLights.colorAt(S.carLedsColor)
  local t = os.preciseClock()
  if M.useMeshes then
    local n = #leds
    local drawn = false
    while M.drawMode <= 2 and not drawn do
      local ok, err = pcall(drawMeshes, c, n, t)
      if ok then drawn = true else
        M.meshError = tostring(err)
        M.drawMode = M.drawMode + 1                -- next way; 3 = discs
      end
    end
    if not drawn then drawDiscs(c, n, t) end
  end
  if M.useVirtual then drawVirtual(c, t) end
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

-- Try it now (settings button): the lights run for a few seconds wherever the car is.
local testUntil = -1
function M.test(seconds) testUntil = os.preciseClock() + (seconds or 8) end

local function step()
  local car, sim = ac.getCar(0), ac.getSim()
  if not car or not sim then return end
  if sim.currentSessionIndex ~= session then
    session = sim.currentSessionIndex
    M.drawMode = 1
    load()
  end
  local testing = os.preciseClock() < testUntil
  M.testing = testing
  local want = S.carLedsPit and (car.isInPitlane or testing)
  if want and not M.active then                   -- pit entry: the check, in the cockpit as it is now
    local ok, err = pcall(evaluate, car)
    if not ok then M.reason, M.useMeshes, M.useVirtual = 'chyba: ' .. tostring(err), false, false end
  end
  M.active = want and (M.useMeshes or M.useVirtual)
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
