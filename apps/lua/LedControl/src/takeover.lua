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

local csp = require('src/csp')
local ac, render, vec3, rgb, rgbm, mat4x4 = csp.ac, csp.render, csp.vec3, csp.rgb, csp.rgbm, csp.mat4x4
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
  acDriven = false,    -- the LEDs come from AC's / CSP's own RPM lights, which write them every frame
  frameNo = 0,         -- counted in frameBegin
  lost = 0,            -- render checks in a row that saw the game's value instead of ours
  version = 0,         -- bumped when anything shown in the diagnostics changes
  stats = { copies = 0, instances = 0, reShows = 0, fights = 0, copyWrites = 0, writes = 0,
    materialsBefore = 0, materialsAfter = 0, split = false, drawErrors = 0, renderChecks = 0, renderLost = 0,
    switched = 0 },
}

M.SHADOW, M.REDRAW, M.DIRECT = 1, 2, 3
M.NAMES = { 'A – stínová kopie', 'B – překreslení', 'C – přímý zápis' }

local UNSET = -2
M.intensity = S.intensity     -- effective brightness (runtime sets it: manual, or by the time of day)

local pow = math.pow or function (a, b) return a ^ b end

-- Emissive of packed colour p at brightness k into col. Above k = 12 the weaker channels are pushed down
-- (c = max * (c / max) ^ gamma), so a colour keeps its hue when its main channel saturates in the HDR image.
local function emissiveOf(p, k, col)
  local r, g, b = color.unpack(p)
  local guard = S.colourGuard or 0
  if guard > 0 and k > 12 then
    local m = r > g and (r > b and r or b) or (g > b and g or b)
    if m > 0 then
      local gamma = 1 + guard * math.log(k / 12) / math.log(2)
      r, g, b = m * pow(r / m, gamma), m * pow(g / m, gamma), m * pow(b / m, gamma)
    end
  end
  col:set(r * k, g * k, b * k)
end
M.emissiveOf = emissiveOf

-- Brightness change: every LED is written again on the next set().
function M.setIntensity(k)
  if math.abs(k - M.intensity) < 0.25 then return end
  M.intensity = k
  for i = 1, M.n do M.items[i].cur = UNSET end
end
local layoutRef = nil
local carId = ''
local guardTimer = 0
local sampleIndex = 0
local pendingFallback = 0
local pendingReason = nil
local renderIndex = 0
local RENDER_CHECK_EVERY = 15   -- frames between two render checks (one LED each; visibility only, no allocation)
local READBACK_EVERY = 60       -- frames between two material read-backs (getMaterialPropertyValue returns a new value)
local READBACK_SUSPECT = 15     -- ... while the last check lost
local hiddenByGame = 0          -- direct: frames in which the game hid a taken LED it had shown (blink by visibility)
local LOST_LIMIT = 2            -- render checks in a row lost to the game before switching to the redraw

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
  -- fight: direct method, this LED's material is written by the game too, so it is put back every frame
  local it = { led = led, cur = UNSET, taken = false, col = rgb(0, 0, 0), draw = rgbm(0, 0, 0, 1), inst = {},
    fight = false }
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
      inst.copy = copy                -- recorded first: dispose() removes it even when a call below fails
      copy:setVisible(false)
      copy:assignMaterialFrom(inst.ref)
      copy:ensureUniqueMaterials()
      local okS, shadows = pcall(inst.ref.isCastingShadows, inst.ref, 1)
      if okS then copy:setShadows(shadows == true) end
      local okT, transparent = pcall(inst.ref.isTransparent, inst.ref, 1)
      if okT and transparent then copy:setTransparent(true) end
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
      inst.nodes = {}
      local node = inst.parent
      while node and #node > 0 and #inst.nodes < 32 do
        inst.nodes[#inst.nodes + 1] = node
        node = node:getParent()
      end
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

-- A hidden mesh holding the instance's current material (shared with it).
local function holderOf(inst, tag)
  local v, ix = inst.ref:getVertices(), inst.ref:getIndices()
  if not v or not ix then return nil end
  local h = inst.parent:createMesh('__ledcontrol_' .. tag, nil, v, ix, false, true)
  if not h or #h == 0 then return nil end
  h:setVisible(false)
  h:assignMaterialFrom(inst.ref)
  return h
end

local function attachDirect()
  local before = materialCount()
  M.stats.materialsBefore = before
  local instances = M.stats.instances
  if before < instances then
    -- LEDs share materials. Each instance gets two hidden holders: one keeps AC's material, one gets a private copy.
    -- A taken LED shares the private one, an LED given back to the car shares AC's one again (AC may keep writing
    -- the material the LED had at load, so a permanent split would freeze the car's own LEDs).
    local allHeld = true
    for i = 1, M.n do
      local inst = M.items[i].inst
      for k = 1, #inst do
        local x = inst[k]
        local okA, a = pcall(holderOf, x, string.format('a%d_%d', i, k))
        local okO, o = pcall(holderOf, x, string.format('o%d_%d', i, k))
        x.acHold = okA and a or nil
        x.ownHold = okO and o or nil
        if x.ownHold then x.ownHold:ensureUniqueMaterials() end
        if not (x.acHold and x.ownHold) then allHeld = false end
      end
    end
    if not allHeld then
      -- no holders (createMesh missing): split for good and say that the car's LEDs return after a session restart
      for i = 1, M.n do
        local inst = M.items[i].inst
        for k = 1, #inst do
          local x = inst[k]
          if x.acHold then pcall(x.acHold.dispose, x.acHold) end
          if x.ownHold then pcall(x.ownHold.dispose, x.ownHold) end
          x.acHold, x.ownHold = nil, nil
          x.ref:ensureUniqueMaterials()
        end
      end
      M.stats.noHolders = true
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
      if inst.copy and inst.copyShown then inst.copy:setVisible(false); inst.copyShown = false end
    end
  elseif m == M.DIRECT then
    for k = 1, #it.inst do
      local inst = it.inst[k]
      if inst.acHold then inst.ref:assignMaterialFrom(inst.acHold)
      elseif inst.orig then setEmissive(inst.ref, inst.orig) end
    end
  end
  it.taken = false
end

local function showColour(it, p)
  local k = M.intensity
  emissiveOf(p, k, it.col)
  local m = M.method
  if m == M.SHADOW then
    if not it.taken and not guardWritten then writeGuard(); guardWritten = true end
    for j = 1, #it.inst do
      local inst = it.inst[j]
      setEmissive(inst.copy, it.col)
      if not it.taken then
        inst.copy:setVisible(true)
        inst.copyShown = true
        if not inst.hidden then
          inst.wasVisible = inst.ref:isVisible()
          inst.ref:setVisible(false)
          inst.hidden = true
        end
      end
    end
  elseif m == M.DIRECT then
    for j = 1, #it.inst do
      local inst = it.inst[j]
      if not it.taken and inst.ownHold then inst.ref:assignMaterialFrom(inst.ownHold) end
      setEmissive(inst.ref, it.col)
    end
    it.setFrame = M.frameNo        -- frameBegin of this frame does not write the same value again
  else
    -- redraw: shader colour in display units (1 = white reference); an unlit LED is drawn dark to cover AC's light
    if p == 0 then it.draw.r, it.draw.g, it.draw.b = 0.025, 0.025, 0.03
    else
      local c = it.col
      it.draw.r, it.draw.g, it.draw.b = c.r / 25, c.g / 25, c.b / 25
    end
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
    if it.taken or it.cur ~= UNSET then pcall(showOriginal, it) end
    it.cur = UNSET
  end
end

-- Gives the car its own LEDs back and removes the copies.
function M.dispose()
  if M.method ~= 0 then releaseItems() end
  for i = 1, M.n do
    local inst = M.items[i].inst
    for k = 1, #inst do
      local x = inst[k]
      local c = x.copy
      if c then
        if x.copyShown then pcall(c.setVisible, c, false) end
        pcall(c.dispose, c)
        x.copy, x.copyShown = nil, false
      end
      if x.acHold then pcall(x.ref.assignMaterialFrom, x.ref, x.acHold); pcall(x.acHold.dispose, x.acHold) end
      if x.ownHold then pcall(x.ownHold.dispose, x.ownHold) end
      x.acHold, x.ownHold = nil, nil
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
  M.lost = 0
  local s = M.stats
  s.copies, s.reShows, s.fights, s.copyWrites, s.writes, s.drawErrors = 0, 0, 0, 0, 0, 0
  s.renderChecks, s.renderLost = 0, 0
  -- AC's digital instruments and CSP's RPM emissives write these LEDs every frame (the direct method fights them
  -- from the first frame instead of waiting to notice it)
  M.acDriven = false
  for i = 1, #layout.leds do
    local src = layout.leds[i].source
    if src == 'digital_instruments' or src == 'csp_rpm' then M.acDriven = true end
  end
  s.materialsBefore, s.materialsAfter, s.split, s.noHolders = 0, 0, false, false
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
      if m == M.DIRECT and s.noHolders then
        M.fallback = (M.fallback and (M.fallback .. ' ') or '') .. 'Přímý zápis musel rozdělit sdílené materiály diod:'
          .. ' po vypnutí je auto znovu ovládá až po restartu jízdy.'
      end
      if m == M.DIRECT then
        -- LEDs AC / CSP light by RPM are fought from the first frame; the others only once a check sees the game
        -- write them (UNSURE: AC may also write the LEDs of its digital instruments that never light)
        for i = 1, M.n do
          local led = M.items[i].led
          local r = tonumber(led.rpm)
          if (led.source == 'digital_instruments' or led.source == 'csp_rpm') and (r == nil or r < 50000) then
            M.items[i].fight = true
            M.fightMode = true
          end
        end
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
    local m, why = pendingFallback, pendingReason
    pendingFallback, pendingReason = 0, nil
    local layout = layoutRef
    local switched = M.stats.switched + 1
    M.attach(layout, m, carId)
    M.stats.switched = switched
    M.fallback = (why or 'Překreslení selhalo při kreslení') .. ', běží ' .. (M.NAMES[M.method] or 'nic') .. '.'
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
      M.fightMode, it.fight = true, true
      bump()
    end
  end
end

-- script.frameBegin: right before rendering, after AC's own update of the LEDs (UNSURE: the order is not documented;
-- the render check in draw3D notices when the game still wins and switches to the redraw).
--  shadow: an original the game showed again (LOD system, AC blinking its LEDs by visibility, session reset) is hidden
--          in the same frame (one isVisible per instance, setVisible only when it is shown);
--  direct: the colours are put back every frame while AC writes them (fightMode).
function M.frameBegin()
  M.frameNo = M.frameNo + 1
  local m = M.method
  if m == M.SHADOW then
    for i = 1, M.n do
      local it = M.items[i]
      if it.taken then
        for k = 1, #it.inst do
          local inst = it.inst[k]
          if inst.hidden and inst.ref:isVisible() then
            inst.ref:setVisible(false)
            M.stats.reShows = M.stats.reShows + 1
          end
        end
      end
    end
  elseif m == M.DIRECT then
    local fight = M.fightMode
    for i = 1, M.n do
      local it = M.items[i]
      if it.taken then
        for k = 1, #it.inst do
          local inst = it.inst[k]
          if fight and it.fight and it.setFrame ~= M.frameNo - 1 then setEmissive(inst.ref, it.col) end
          -- the direct method cannot keep an LED the game hides: counted for the render check
          if inst.ref:isVisible() then inst.seenFrame = M.frameNo
          elseif (inst.seenFrame or -1000) + 60 >= M.frameNo then hiddenByGame = hiddenByGame + 1 end
        end
      end
    end
  elseif m == M.REDRAW then
    -- remember which instances the game shows, so a blink that hides the original does not stop the redraw
    for i = 1, M.n do
      local it = M.items[i]
      if it.taken then
        for k = 1, #it.inst do
          local inst = it.inst[k]
          if inst.ref:isVisible() then inst.seenFrame = M.frameNo end
        end
      end
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

-- isActive is a node's own flag: an instance is drawn only when every node up to the root is active (LOD switch)
local function chainActive(inst)
  local nodes = inst.nodes
  for j = 1, #nodes do
    if not nodes[j]:isActive() then return false end
  end
  return true
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
        -- drawn while its node chain is active and the game showed it within the last second
        if (inst.seenFrame or 0) + 60 >= M.frameNo and chainActive(inst) then drawInstance(inst, it.draw) end
      end
    end
  end
end

-- Render check (shadow and direct, every RENDER_CHECK_EVERY frames, one LED in turn): what the opaque pass used is
-- read back here, after everything else of the frame ran. A wrong colour or an original shown again means the game
-- writes after the app; after LOST_LIMIT checks in a row the takeover switches to the redraw (it does not depend on
-- the LED's material or visibility).
local function renderCheck()
  if M.frameNo % RENDER_CHECK_EVERY ~= 0 then return end
  renderIndex = renderIndex % M.n + 1
  local it = M.items[renderIndex]
  if not it.taken then return end
  M.stats.renderChecks = M.stats.renderChecks + 1
  local lost = false
  local inst = it.inst[1]
  local readback = M.frameNo % (M.lost > 0 and READBACK_SUSPECT or READBACK_EVERY) == 0
  if M.method == M.SHADOW then
    for k = 1, #it.inst do
      local x = it.inst[k]
      if x.hidden and x.ref:isVisible() then lost = true end
    end
    if readback and inst.copy then
      local ok, v = pcall(inst.copy.getMaterialPropertyValue, inst.copy, 1, 'ksEmissive')
      if ok and not sameColour(v, it.col) then lost = true; M.stats.copyWrites = M.stats.copyWrites + 1 end
    end
  else
    if hiddenByGame >= 3 then lost = true end
    hiddenByGame = 0
    if readback then
      local ok, v = pcall(inst.ref.getMaterialPropertyValue, inst.ref, 1, 'ksEmissive')
      if ok and not sameColour(v, it.col) then
        if it.fight then lost = true
        else it.fight, M.fightMode = true, true; M.stats.fights = M.stats.fights + 1 end
      end
    end
  end
  if lost then
    M.lost = M.lost + 1
    M.stats.renderLost = M.stats.renderLost + 1
    -- (at most 3 switches per attach chain: a redraw that fails falls back again and must not loop)
    if M.lost >= LOST_LIMIT and pendingFallback == 0 and M.stats.switched < 3 then
      pendingFallback = M.REDRAW
      pendingReason = 'Hra přepisuje diody i přes ' .. M.NAMES[M.method]
      bump()
    end
  elseif readback then
    M.lost = 0     -- only a full check (with the read-back) clears the count; a visibility-only one cannot
  end
end

-- render.on('main.root.transparent'): draws the taken LEDs for the redraw method, checks the others.
function M.draw3D()
  if M.n == 0 or M.method == 0 then return end
  if M.method ~= M.REDRAW then
    renderCheck()
    return
  end
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
