-- Visual light meshes of the player's car: the rain light copy ('mesh' mode), blinking brake lights and recoloured dash
-- meshes. Only this PC sees them. Same shadow copy approach as src/takeover.lua, in its own small writer:
-- per instance a copy of the mesh in the same node (:getVertices / :getIndices -> parent:createMesh), with its own
-- material (:assignMaterialFrom(original) + :ensureUniqueMaterials()); a taken writer hides the original and shows the
-- copy with its own ksEmissive, written only when the colour changes. Copies follow the node (steering wheel, LODs).
-- Self-heal marker: "carId|name|name..." of hidden originals, kept in the lights storage and written before anything
-- is hidden; heal() shows them again after a crash or reload, release() clears it.
-- No allocation in set() / guard().

local color = require('src/color')
local detect = require('src/detect')

local M = { PREFIX = '__lclight_' }
local OWN = '^' .. M.PREFIX           -- copies made here
local LED_COPY = '^__ledcontrol_'      -- copies made by src/takeover.lua

local UNSET = -2
local ORIGINAL = color.ORIGINAL
local MAX_INSTANCES = 8      -- per mesh name (LOD A/B, hi-res and low-res cockpit)
local MAX_NAMES = 32

-- ---------------------------------------------------------------- self-heal marker

local markerStore = nil      -- table with a string field 'meshGuard' (the lights ac.storage) or nil
local markerCar = ''
local markerSet, markerList = {}, {}

function M.useStorage(stored, carId)
  markerStore = stored
  markerCar = carId or ''
end

local function writeMarker()
  if not markerStore then return end
  markerStore.meshGuard = #markerList > 0 and (markerCar .. '|' .. table.concat(markerList, '|')) or ''
end

local function markHidden(name)
  if markerSet[name] then return end
  markerSet[name] = true
  markerList[#markerList + 1] = name
  writeMarker()
end

function M.clearMarker()
  if #markerList == 0 and (not markerStore or markerStore.meshGuard == '') then return end
  markerSet, markerList = {}, {}
  if markerStore then markerStore.meshGuard = '' end
end

-- Shows the originals an earlier run left hidden and hides its stray copies. Returns the number of meshes healed.
function M.heal(carId)
  if not markerStore then return 0 end
  local marker = markerStore.meshGuard
  if type(marker) ~= 'string' or marker == '' then return 0 end
  local parts = {}
  for p in string.gmatch(marker, '[^|]+') do parts[#parts + 1] = p end
  local healed = 0
  local root = ac.findNodes('carRoot:0')
  if root and #root > 0 and parts[1] == carId then
    for i = 2, #parts do
      local ok, ref = pcall(root.findMeshes, root, parts[i])
      if ok and ref and #ref > 0 then
        ref:setVisible(true)
        healed = healed + #ref
      end
    end
    local ok, stray = pcall(root.findMeshes, root, M.PREFIX .. '?')
    if ok and stray and #stray > 0 then stray:setVisible(false) end
  end
  if parts[1] == carId or parts[1] == nil then
    markerSet, markerList = {}, {}
    markerStore.meshGuard = ''
  end
  return healed
end

-- ---------------------------------------------------------------- writer

-- role: short id used in the copy names ('rain', 'brake', 'dash').
function M.writer(role)
  return { role = role, names = {}, inst = {}, n = 0, ready = false, error = nil, cur = UNSET, curK = -1,
    col = rgb(0, 0, 0), taken = false, reShows = 0, writes = 0, timer = 0, copies = 0 }
end

local function releaseInstances(w)
  for i = 1, w.n do
    local it = w.inst[i]
    if it.hidden then pcall(it.ref.setVisible, it.ref, true); it.hidden = false end
    if it.copy then
      pcall(it.copy.setVisible, it.copy, false)
      pcall(it.copy.dispose, it.copy)
      it.copy = nil
    end
  end
  w.inst, w.n, w.copies = {}, 0, 0
  w.taken, w.cur, w.curK, w.ready = false, UNSET, -1, false
end

local function makeCopy(w, ref, k)
  local v = ref:getVertices()
  local ix = ref:getIndices()
  if not v or not ix then return nil, 'getVertices/getIndices nevrátily data' end
  local parent = ref:getParent()
  if not parent or #parent == 0 then return nil, 'mesh nemá nadřazený uzel' end
  local copy = parent:createMesh(string.format('%s%s_%d', M.PREFIX, w.role, k), nil, v, ix, false, true)
  if not copy or #copy == 0 then return nil, 'createMesh nevytvořil kopii' end
  copy:assignMaterialFrom(ref)
  copy:ensureUniqueMaterials()
  copy:setVisible(false)
  local okS, shadows = pcall(ref.isCastingShadows, ref, 1)
  if okS then pcall(copy.setShadows, copy, shadows == true) end
  local okT, transparent = pcall(ref.isTransparent, ref, 1)
  if okT and transparent then pcall(copy.setTransparent, copy, true) end
  return copy
end

-- Finds every instance of the given mesh names and makes their hidden copies. Returns true when at least one copy
-- exists; otherwise w.error holds a Czech reason.
function M.prepare(w, names)
  releaseInstances(w)
  w.error = nil
  w.names = {}
  for i = 1, math.min(#(names or {}), MAX_NAMES) do w.names[i] = names[i] end
  if #w.names == 0 then w.error = 'nejsou vybrané žádné meshe'; return false end
  local root = ac.findNodes('carRoot:0')
  if not root or #root == 0 then w.error = 'model auta ještě není načtený'; return false end
  local k, why = 0, nil
  for i = 1, #w.names do
    local ok, found = pcall(root.findMeshes, root, w.names[i])
    if ok and found then
      for j = 1, math.min(#found, MAX_INSTANCES) do
        local ref = found:at(j)
        k = k + 1
        local okC, copy, reason = pcall(makeCopy, w, ref, k)
        if okC and copy then
          w.n = w.n + 1
          w.inst[w.n] = { ref = ref, copy = copy, name = w.names[i], hidden = false, wasVisible = true }
          w.copies = w.copies + 1
        else
          why = okC and reason or tostring(copy)
        end
      end
    end
  end
  if w.n == 0 then
    w.error = why or 'meshe s těmito jmény na autě nejsou'
    return false
  end
  w.ready = true
  return true
end

-- First instance's original emissive (r, g, b), or nil when it cannot be read.
function M.originalEmissive(w)
  local it = w.inst[1]
  if not it then return nil end
  local ok, v = pcall(it.ref.getMaterialPropertyValue, it.ref, 1, 'ksEmissive')
  if not ok or v == nil or type(v) == 'number' then return nil end
  return v.x or v.r or 0, v.y or v.g or 0, v.z or v.b or 0
end

local function showOriginal(w)
  for i = 1, w.n do
    local it = w.inst[i]
    if it.hidden then it.ref:setVisible(it.wasVisible); it.hidden = false end
    if it.copy then it.copy:setVisible(false) end
  end
  w.taken = false
end

-- p: packed colour (0 = dark) or color.ORIGINAL (the car's own mesh); k: emissive of a full colour. Change-only.
function M.set(w, p, k)
  if not w.ready or (w.cur == p and w.curK == k) then return end
  w.cur, w.curK = p, k
  if p < 0 then showOriginal(w) return end
  local r, g, b = color.unpack(p)
  w.col:set(r * k, g * k, b * k)
  for i = 1, w.n do
    local it = w.inst[i]
    it.copy:setMaterialProperty('ksEmissive', w.col)
    if not w.taken then
      if not it.hidden then
        it.wasVisible = it.ref:isVisible()
        if it.wasVisible then
          markHidden(it.name)
          it.ref:setVisible(false)
          it.hidden = true
        end
      end
      it.copy:setVisible(it.wasVisible)
    end
  end
  w.taken = true
  w.writes = w.writes + 1
end

-- Every 0.5 s: originals hidden by this writer stay hidden (counts re-shows).
function M.guard(w, dt)
  if not w.taken then return end
  w.timer = w.timer + dt
  if w.timer < 0.5 then return end
  w.timer = 0
  for i = 1, w.n do
    local it = w.inst[i]
    if it.hidden and it.ref:isVisible() then
      it.ref:setVisible(false)
      w.reShows = w.reShows + 1
    end
  end
end

-- Originals back, copies removed.
function M.release(w)
  releaseInstances(w)
end

-- ---------------------------------------------------------------- mesh list for the pickers (on demand only)

-- LOD A meshes of the player's car: { { name, lower, radius, dist (m from the eyes), material } ... }, nearest first,
-- one entry per name, at most limit. Copies made by LedControl and the names in skip (set) are left out.
function M.listMeshes(car, limit, skip)
  local out = {}
  local root = ac.findNodes('carRoot:0')
  if not root or #root == 0 or not car then return out end
  local okA, all = pcall(root.findMeshes, root, '{ lod:A }')
  if not okA or not all or #all == 0 then
    okA, all = pcall(root.findMeshes, root, '?')
    if not okA or not all then return out end
  end
  local eyes, world = vec3(), vec3()
  car.transform:transformPointTo(eyes, car.driverEyesPosition)
  local seen = {}
  for i = 1, math.min(#all, 6000) do
    local name = all:name(i)
    if name ~= '' and not seen[name] and not name:find(LED_COPY) and not name:find(OWN)
        and not (skip and skip[name]) then
      seen[name] = true
      local ref = all:at(i)
      local inst = { centre = vec3(), chain = nil }
      local c, r = ref:boundingSphere(1, inst.centre)
      local d = 99
      if c then
        inst.chain = detect.chainOf(ref)
        detect.worldOf(inst, world)
        local dx, dy, dz = world.x - eyes.x, world.y - eyes.y, world.z - eyes.z
        d = math.sqrt(dx * dx + dy * dy + dz * dz)
      end
      local okM, mat = pcall(ref.materialName, ref, 1)
      out[#out + 1] = { name = name, lower = name:lower(), radius = r or 0, dist = d, material = okM and mat or '?' }
    end
  end
  table.sort(out, function (a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    return a.name < b.name
  end)
  while #out > (limit or 400) do out[#out] = nil end
  return out
end

-- Unique mesh names matching a filter (for detection, e.g. '{ actsAsBrakeLights:yes & lod:A }'), at most limit.
function M.namesOf(filter, limit, skip)
  local out = {}
  local root = ac.findNodes('carRoot:0')
  if not root or #root == 0 then return out end
  local ok, ref = pcall(root.findMeshes, root, filter)
  if not ok or not ref then return out end
  local seen = {}
  for i = 1, #ref do
    local name = ref:name(i)
    if name ~= '' and not seen[name] and not name:find(OWN) and not name:find(LED_COPY)
        and not (skip and skip[name]) then
      seen[name] = true
      out[#out + 1] = name
      if #out >= (limit or MAX_NAMES) then break end
    end
  end
  return out
end

M.ORIGINAL = ORIGINAL

return M
