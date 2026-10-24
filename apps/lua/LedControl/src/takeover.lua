-- The only module that changes the scene. Puts a packed colour (color.lua) on each LED of a layout, or gives the LED
-- back to the car (color.ORIGINAL). Writes happen only when an LED's value changes.
--
-- Methods (AC writes the LED material's ksEmissive by RPM every frame, so writing it directly fights AC):
--  1 shadow copy: per instance a copy of the mesh in the same node (:getVertices/:getIndices -> parent:createMesh),
--    with its own material (:assignMaterialFrom(original) + :ensureUniqueMaterials()). A taken LED hides the
--    original and shows the copy; AC keeps writing the hidden original. Copies follow the steering wheel and LODs.
--  2 redraw: the LED mesh is drawn again over itself in render.on('main.root.transparent') with render.mesh
--    (grown 8 % about its centre x live node chain x 3 mm towards the camera, as Radar draws scene meshes).
--  3 direct: :ensureUniqueMaterials() per instance (only when LEDs share a material), then ksEmissive is written;
--    when AC is seen writing it back, the colours are put back every frame in script.frameBegin.
-- A failure while attaching falls back to the next method (1 -> 2 -> 3) with the reason kept in M.fallback.

local config = require('src/config')
local color = require('src/color')
local detect = require('src/detect')

local S = config.S

local M = {
  method = 0,          -- active method, 0 = not attached
  wanted = 0,          -- method asked for
  items = {},
  n = 0,
  fallback = nil,      -- Czech reason when another method than the wanted one runs
  fightMode = false,   -- direct: AC writes back, colours are re-asserted every frame
  version = 0,         -- bumped when anything shown in the diagnostics changes
  stats = { copies = 0, instances = 0, reShows = 0, fights = 0, copyWrites = 0, writes = 0,
    materialsBefore = 0, materialsAfter = 0, split = false, drawErrors = 0 },
}

M.SHADOW, M.REDRAW, M.DIRECT = 1, 2, 3
M.NAMES = { 'A – stínová kopie', 'B – překreslení', 'C – přímý zápis' }

local UNSET = -2
local layoutRef = nil
local carId = ''
local guardTimer = 0
local sampleIndex = 0
local pendingFallback = 0

local function bump() M.version = M.version + 1 end

-- ---------------------------------------------------------------- self-heal marker

local function writeGuard()
  local names, seen = { carId }, {}
  for i = 1, M.n do
    local inst = M.items[i].inst
    for k = 1, #inst do
      local nm = inst[k].name
      if not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
    end
  end
  config.set('hiddenGuard', table.concat(names, '|'))
end

local guardWritten = false

local function clearGuard()
  if S.hiddenGuard ~= '' then config.set('hiddenGuard', '') end
end

-- Un-hides the originals a previous run left hidden (crash, reload) and removes stray copies. Returns the count.
function M.heal(currentCarId)
  local marker = S.hiddenGuard
  if marker == '' then return 0 end
  local healed = 0
  local root = ac.findNodes('carRoot:0')
  local parts = {}
  for p in string.gmatch(marker, '[^|]+') do parts[#parts + 1] = p end
  if root and #root > 0 and parts[1] == currentCarId then
    for i = 2, #parts do
      local ok, ref = pcall(root.findMeshes, root, parts[i])
      if ok and ref and #ref > 0 then
        ref:setVisible(true)
        healed = healed + #ref
      end
    end
    local ok, stray = pcall(root.findMeshes, root, '__ledcontrol_?')
    if ok and stray and #stray > 0 then stray:setVisible(false) end
  end
  if parts[1] == currentCarId or parts[1] == nil then clearGuard() end
  return healed
end

-- ---------------------------------------------------------------- per method setup

local function newItem(led)
  local it = { led = led, cur = UNSET, taken = false, col = rgb(0, 0, 0), draw = rgbm(0, 0, 0, 1), inst = {} }
  for k = 1, #led.inst do
    local src = led.inst[k]
    it.inst[k] = { ref = src.ref, parent = src.parent, name = led.name, centre = src.centre, radius = src.radius,
      chain = src.chain, hidden = false, wasVisible = true, copy = nil, orig = nil, grow = nil }
  end
  return it
end

local function attachShadow()
  local made = 0
  for i = 1, M.n do
    local it = M.items[i]
    for k = 1, #it.inst do
      local inst = it.inst[k]
      local v = inst.ref:getVertices()
      local ix = inst.ref:getIndices()
      if not v or not ix then return false, 'getVertices/getIndices nevrátily data (' .. inst.name .. ')' end
      local copy = inst.parent:createMesh(string.format('__ledcontrol_%d_%d', i, k), nil, v, ix, false, true)
      if not copy or #copy == 0 then return false, 'createMesh nevytvořil kopii (' .. inst.name .. ')' end
      copy:assignMaterialFrom(inst.ref)
      copy:ensureUniqueMaterials()
      copy:setVisible(false)
      local okS, shadows = pcall(inst.ref.isCastingShadows, inst.ref, 1)
      if okS then copy:setShadows(shadows == true) end
      local okT, transparent = pcall(inst.ref.isTransparent, inst.ref, 1)
      if okT and transparent then copy:setTransparent(true) end
      inst.copy = copy
      made = made + 1
    end
  end
  M.stats.copies = made
  return true
end

local GROW = 1.08
local function attachRedraw()
  if type(render) ~= 'table' or type(render.mesh) ~= 'function' then return false, 'render.mesh není k dispozici' end
  for i = 1, M.n do
    local it = M.items[i]
    for k = 1, #it.inst do
      local inst = it.inst[k]
      local c = inst.centre
      inst.grow = mat4x4.translation(vec3(-c.x, -c.y, -c.z)):mul(mat4x4.scaling(vec3(GROW, GROW, GROW)))
        :mul(mat4x4.translation(c))
    end
  end
  return true
end

local function materialCount()
  local all = ac.emptySceneReference()
  for i = 1, M.n do
    local inst = M.items[i].inst
    for k = 1, #inst do all:append(inst[k].ref) end
  end
  return all:getMaterialsCount(), all
end

local function attachDirect()
  local before = materialCount()
  M.stats.materialsBefore = before
  local instances = M.stats.instances
  if before < instances then
    -- LEDs share materials: give every single instance its own (unique relative to the rest of the scene)
    for i = 1, M.n do
      local inst = M.items[i].inst
      for k = 1, #inst do inst[k].ref:ensureUniqueMaterials() end
    end
    M.stats.split = true
  end
  M.stats.materialsAfter = materialCount()
  for i = 1, M.n do
    local inst = M.items[i].inst
    for k = 1, #inst do
      local ok, v = pcall(inst[k].ref.getMaterialPropertyValue, inst[k].ref, 1, 'ksEmissive')
      if ok and v ~= nil and type(v) ~= 'number' then
        inst[k].orig = rgb(v.x or v.r or 0, v.y or v.g or 0, v.z or v.b or 0)
      end
    end
  end
  return true
end

local ATTACH = { attachShadow, attachRedraw, attachDirect }

-- ---------------------------------------------------------------- writes

local function setEmissive(ref, col)
  ref:setMaterialProperty('ksEmissive', col)
end

local function showOriginal(it)
  local m = M.method
  if m == M.SHADOW then
    for k = 1, #it.inst do
      local inst = it.inst[k]
      if inst.hidden then inst.ref:setVisible(inst.wasVisible); inst.hidden = false end
      if inst.copy then inst.copy:setVisible(false) end
    end
  elseif m == M.DIRECT then
    for k = 1, #it.inst do
      local inst = it.inst[k]
      if inst.orig then setEmissive(inst.ref, inst.orig) end
    end
  end
  it.taken = false
end

local function showColour(it, p)
  local r, g, b = color.unpack(p)
  local k = S.intensity
  it.col:set(r * k, g * k, b * k)
  local m = M.method
  if m == M.SHADOW then
    if not it.taken and not guardWritten then writeGuard(); guardWritten = true end
    for j = 1, #it.inst do
      local inst = it.inst[j]
      setEmissive(inst.copy, it.col)
      if not it.taken then
        inst.copy:setVisible(true)
        if not inst.hidden then
          inst.wasVisible = inst.ref:isVisible()
          inst.ref:setVisible(false)
          inst.hidden = true
        end
      end
    end
  elseif m == M.DIRECT then
    for j = 1, #it.inst do setEmissive(it.inst[j].ref, it.col) end
  else
    -- redraw: shader colour in display units (1 = white reference); an unlit LED is drawn dark to cover AC's light
    local br = k / 25
    if p == 0 then it.draw.r, it.draw.g, it.draw.b = 0.025, 0.025, 0.03
    else it.draw.r, it.draw.g, it.draw.b = r * br, g * br, b * br end
  end
  it.taken = true
  M.stats.writes = M.stats.writes + 1
end

-- Puts packed colour p on LED i (color.ORIGINAL = the car's own logic). No-op when unchanged.
function M.set(i, p)
  local it = M.items[i]
  if not it or it.cur == p or M.method == 0 then return end
  it.cur = p
  if p < 0 then showOriginal(it) else showColour(it, p) end
end

-- Forces every LED to be written again on the next set() (brightness change).
function M.invalidate()
  for i = 1, M.n do M.items[i].cur = UNSET end
end

-- ---------------------------------------------------------------- attach / release

local function releaseItems()
  for i = 1, M.n do
    local it = M.items[i]
    if it.taken or it.cur ~= UNSET then showOriginal(it) end
    it.cur = UNSET
  end
end

-- Gives the car its own LEDs back and removes the copies.
function M.dispose()
  if M.method ~= 0 then releaseItems() end
  for i = 1, M.n do
    local inst = M.items[i].inst
    for k = 1, #inst do
      local c = inst[k].copy
      if c then pcall(c.setVisible, c, false); pcall(c.dispose, c); inst[k].copy = nil end
    end
  end
  -- only a marker this run wrote is cleared here; one left by an earlier run waits for heal()
  if guardWritten then clearGuard() end
  guardWritten = false
  M.items, M.n, M.method, M.fightMode = {}, 0, 0, false
  layoutRef = nil
  bump()
end

-- Prepares layout's LEDs with the wanted method (falls back on a failure). Returns the method used (0 = none).
function M.attach(layout, wanted, id)
  M.dispose()
  layoutRef, carId = layout, id or ''
  M.wanted = wanted
  M.fallback = nil
  local s = M.stats
  s.copies, s.reShows, s.fights, s.copyWrites, s.writes, s.drawErrors = 0, 0, 0, 0, 0, 0
  s.materialsBefore, s.materialsAfter, s.split = 0, 0, false
  local reasons = {}
  for step = 0, 2 do
    local m = (wanted - 1 + step) % 3 + 1
    M.items, M.n, s.instances = {}, #layout.leds, 0
    for i = 1, M.n do
      M.items[i] = newItem(layout.leds[i])
      s.instances = s.instances + #M.items[i].inst
    end
    local ok, res, why = pcall(ATTACH[m])
    if ok and res then
      M.method = m
      if m ~= wanted then
        M.fallback = string.format('Metoda %s nefunguje (%s), běží %s.', M.NAMES[wanted], table.concat(reasons, '; '),
          M.NAMES[m])
      end
      bump()
      return m
    end
    reasons[#reasons + 1] = ok and tostring(why) or tostring(res)
    M.method = m
    M.dispose()
    layoutRef = layout
  end
  M.fallback = 'Žádná metoda nefunguje: ' .. table.concat(reasons, '; ')
  bump()
  return 0
end

-- ---------------------------------------------------------------- per frame

local function sameColour(v, col)
  if v == nil or type(v) == 'number' then return true end
  local x, y, z = v.x or v.r or 0, v.y or v.g or 0, v.z or v.b or 0
  return math.abs(x - col.r) < 0.01 and math.abs(y - col.g) < 0.01 and math.abs(z - col.b) < 0.01
end

-- Every 0.5 s: hidden originals stay hidden (shadow), AC writing our colour back is detected (direct), copies keep
-- their colour (shadow). One LED is sampled per check, so reading values back costs little.
function M.guard(dt)
  if M.method == 0 or M.n == 0 then return end
  guardTimer = guardTimer + dt
  if pendingFallback ~= 0 then
    local m = pendingFallback
    pendingFallback = 0
    local layout = layoutRef
    M.attach(layout, m, carId)
    M.fallback = 'Překreslení selhalo při kreslení, běží ' .. M.NAMES[M.method] .. '.'
    return
  end
  if guardTimer < 0.5 then return end
  guardTimer = 0
  sampleIndex = sampleIndex % M.n + 1
  local it = M.items[sampleIndex]
  if M.method == M.SHADOW then
    for i = 1, M.n do
      local x = M.items[i]
      if x.taken then
        for k = 1, #x.inst do
          local inst = x.inst[k]
          if inst.hidden and inst.ref:isVisible() then
            M.stats.reShows = M.stats.reShows + 1
            inst.ref:setVisible(false)
            bump()
          end
        end
      end
    end
    if it.taken and it.inst[1] and it.inst[1].copy then
      local c = it.inst[1].copy
      local ok, v = pcall(c.getMaterialPropertyValue, c, 1, 'ksEmissive')
      if ok and not sameColour(v, it.col) then
        M.stats.copyWrites = M.stats.copyWrites + 1
        setEmissive(c, it.col)
        bump()
      end
    end
  elseif M.method == M.DIRECT and it.taken then
    local ref = it.inst[1].ref
    local ok, v = pcall(ref.getMaterialPropertyValue, ref, 1, 'ksEmissive')
    if ok and not sameColour(v, it.col) then
      M.stats.fights = M.stats.fights + 1
      M.fightMode = true
      bump()
    end
  end
end

-- script.frameBegin: right before rendering, after AC's own update of the LEDs.
function M.frameBegin()
  if M.method ~= M.DIRECT or not M.fightMode then return end
  for i = 1, M.n do
    local it = M.items[i]
    if it.taken then
      for k = 1, #it.inst do setEmissive(it.inst[k].ref, it.col) end
    end
  end
end

-- ---------------------------------------------------------------- redraw

local MESH = {
  mesh = false,
  transform = 'original',
  textures = {},
  values = { gColor = rgbm(0, 0, 0, 1) },
  cacheKey = 7411,
  shader = [[
    float4 main(PS_IN pin) {
      return float4(gColor.rgb * gWhiteRefPoint, 1);
    }
  ]],
}
local LIFT = 0.003
local lift = mat4x4.identity()
local dacc = mat4x4.identity()
local wpos = vec3()
local useOwnMatrix = true

local function drawInstance(inst, col)
  MESH.mesh = inst.ref
  MESH.values.gColor = col
  if useOwnMatrix then
    local cam = ac.getSim().cameraPosition
    dacc:set(inst.grow)
    local chain = inst.chain
    for i = 1, #chain do dacc:mulSelf(chain[i]) end
    dacc:transformPointTo(wpos, inst.centre)
    local dx, dy, dz = cam.x - wpos.x, cam.y - wpos.y, cam.z - wpos.z
    local len = math.max(1e-4, math.sqrt(dx * dx + dy * dy + dz * dz))
    lift.position:set(dx / len * LIFT, dy / len * LIFT, dz / len * LIFT)
    dacc:mulSelf(lift)
    MESH.transform = dacc
  else
    MESH.transform = 'original'
  end
  render.mesh(MESH)
end

local function drawAll()
  render.setBlendMode(render.BlendMode.OpaqueForced)
  render.setDepthMode(render.DepthMode.LessEqual)
  render.setCullMode(render.CullMode.None)
  for i = 1, M.n do
    local it = M.items[i]
    if it.taken then
      for k = 1, #it.inst do
        local inst = it.inst[k]
        if inst.ref:isVisible() and inst.parent:isActive() then drawInstance(inst, it.draw) end
      end
    end
  end
end

-- render.on('main.root.transparent'): draws the taken LEDs for the redraw method.
function M.draw3D()
  if M.method ~= M.REDRAW or M.n == 0 then return end
  local ok = pcall(drawAll)
  if not ok and useOwnMatrix then
    useOwnMatrix = false
    ok = pcall(drawAll)
  end
  if not ok then
    M.stats.drawErrors = M.stats.drawErrors + 1
    pendingFallback = M.DIRECT
    bump()
  end
end

function M.layout() return layoutRef end

return M
