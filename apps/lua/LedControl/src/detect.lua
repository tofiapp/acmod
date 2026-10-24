-- Finds the LEDs of the player's car and orders them as the driver sees them.
-- Sources, tried in this order until one gives a usable LED: digital_instruments.ini [LED_n] OBJECT_NAME together
-- with CSP config [EMISSIVE_*] INPUT = RPM meshes; meshes CSP marks { actsAsLED:yes } (show_important_wheels.lua);
-- cockpit meshes named ?LED? / ?RPM? / ?SHIFT? in LOD A (Radar uses lod:A filters).
-- Every mesh found by an LED's name is kept as an instance (LOD A/B, hi-res and low-res cockpit or steering wheel).
-- Position: the bounding sphere centre (parent space) through the live local matrices up the node chain
-- (:getTransformationRaw(), as CSP's vr_rig_base getActualTransform), then projected on the car's side and up axes.

local M = {}

local MAX_RADIUS = 0.06      -- m; a bigger mesh is not a single LED
local MAX_EYES = 1.8         -- m from the driver's eyes
local MAX_LEDS = 64
local MAX_INSTANCES = 8

M.MAX_RADIUS, M.MAX_EYES, M.MAX_LEDS = MAX_RADIUS, MAX_EYES, MAX_LEDS

-- ---------------------------------------------------------------- geometry helpers

local function matrixOf(n) return n:getTransformationRaw() end

-- The live local matrices from the mesh (when it has one) and its nodes up to the scene root (references).
function M.chainOf(ref)
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

-- World position of an instance's bounding sphere centre into out.
function M.worldOf(inst, out)
  acc:set(IDENT)
  local chain = inst.chain
  for i = 1, #chain do acc:mulSelf(chain[i]) end
  acc:transformPointTo(out, inst.centre)
  return out
end

local function dot(ax, ay, az, b) return ax * b.x + ay * b.y + az * b.z end

-- ---------------------------------------------------------------- candidates

local function addName(list, seen, name, source, rpm)
  if type(name) ~= 'string' or name == '' or seen[name] then return end
  seen[name] = true
  list[#list + 1] = { name = name, source = source, rpm = rpm }
end

local function namesOf(ref, list, seen, source)
  for i = 1, #ref do addName(list, seen, ref:name(i), source) end
end

local function safeFind(root, filter)
  local ok, ref = pcall(root.findMeshes, root, filter)
  if ok and ref then return ref end
  return nil
end

-- Lists of candidate names per source group, plus the raw counts for the diagnostics.
local function candidateGroups(root, info, counts)
  local primary, seen = {}, {}
  for i = 1, #info.leds do
    local led = info.leds[i]
    local o = led.keys and led.keys.OBJECT_NAME
    addName(primary, seen, type(o) == 'table' and o[1] or o, 'digital_instruments', led.rpm)
  end
  counts.digital_instruments = #primary
  for i = 1, #info.cspRpm do
    local e = info.cspRpm[i]
    for j = 1, #e.names do addName(primary, seen, e.names[j], 'csp_rpm', e.threshold) end
  end
  counts.csp_rpm = #primary - counts.digital_instruments

  local marked, mseen = {}, {}
  local ref = safeFind(root, '{ actsAsLED:yes }')
  if ref then namesOf(ref, marked, mseen, 'acts_as_led') end
  counts.acts_as_led = #marked

  local named, nseen = {}, {}
  ref = safeFind(root, '{ (?LED?, ?RPM?, ?SHIFT?) & lod:A }')
  if ref then namesOf(ref, named, nseen, 'names') end
  counts.names = #named

  return { primary, marked, named }
end

-- ---------------------------------------------------------------- instances

local function score(inst)
  return (inst.lodA and 2 or 0) + (inst.visible and 1 or 0)
end

local function instancesOf(root, lodA, name)
  local found = safeFind(root, name)
  local list = {}
  if not found then return list end
  for i = 1, math.min(#found, MAX_INSTANCES) do
    local ref = found:at(i)
    local inst = { ref = ref, parent = ref:getParent(), centre = vec3(), radius = 0, k = i }
    local c, r = ref:boundingSphere(1, inst.centre)
    inst.hasSphere = c ~= nil
    inst.radius = r or 0
    inst.chain = M.chainOf(ref)
    inst.visible = ref:isVisible()
    local okL, n = pcall(lodA.countMatches, lodA, ref)
    inst.lodA = okL and (n or 0) > 0
    local okM, mat = pcall(ref.materialName, ref, 1)
    inst.material = okM and mat or '?'
    local okP, pn = pcall(inst.parent.name, inst.parent, 1)
    inst.parentName = okP and pn or '?'
    list[#list + 1] = inst
  end
  table.sort(list, function (a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa > sb end
    return a.k < b.k
  end)
  return list
end

-- ---------------------------------------------------------------- groups

local function dist2(a, b)
  local dx, dy = a.lateral - b.lateral, a.height - b.height
  return dx * dx + dy * dy
end

local function findRoot(p, i)
  while p[i] ~= i do p[i] = p[p[i]]; i = p[i] end
  return i
end

-- Single-linkage clusters in the plane of the wheel (lateral, height). Threshold from the typical LED spacing, so a
-- row split into colour blocks stays one row while side columns a few cm away become their own groups.
local function cluster(leds)
  local n = #leds
  if n == 0 then return {} end
  local nn = {}
  for i = 1, n do
    local best = math.huge
    for j = 1, n do
      if i ~= j then best = math.min(best, dist2(leds[i], leds[j])) end
    end
    nn[i] = math.sqrt(best)
  end
  table.sort(nn)
  local median = nn[math.floor((n + 1) / 2)] or 0
  if median == math.huge then median = 0 end
  local th = math.max(0.015, 2.5 * median)
  local th2 = th * th
  local p = {}
  for i = 1, n do p[i] = i end
  for i = 1, n do
    for j = i + 1, n do
      if dist2(leds[i], leds[j]) <= th2 then
        local a, b = findRoot(p, i), findRoot(p, j)
        if a ~= b then p[b] = a end
      end
    end
  end
  local byRoot, list = {}, {}
  for i = 1, n do
    local r = findRoot(p, i)
    local c = byRoot[r]
    if not c then
      c = { leds = {}, minL = math.huge, maxL = -math.huge, minH = math.huge, maxH = -math.huge, sumH = 0 }
      byRoot[r] = c
      list[#list + 1] = c
    end
    local led = leds[i]
    c.leds[#c.leds + 1] = led
    c.minL, c.maxL = math.min(c.minL, led.lateral), math.max(c.maxL, led.lateral)
    c.minH, c.maxH = math.min(c.minH, led.height), math.max(c.maxH, led.height)
    c.sumH = c.sumH + led.height
  end
  return list, th
end

local function orderCluster(c)
  if c.maxL - c.minL >= c.maxH - c.minH then
    table.sort(c.leds, function (a, b) return a.lateral > b.lateral end)   -- left to right (larger = more left)
    c.vertical = false
  else
    table.sort(c.leds, function (a, b) return a.height > b.height end)     -- top to bottom
    c.vertical = true
  end
end

local function makeGroups(leds)
  local list, th = cluster(leds)
  local main = nil
  for i = 1, #list do
    local c = list[i]
    orderCluster(c)
    if not main or #c.leds > #main.leds or (#c.leds == #main.leds and c.sumH / #c.leds > main.sumH / #main.leds) then
      main = c
    end
  end
  local left, right, other = {}, {}, {}
  for i = 1, #list do
    local c = list[i]
    if c ~= main then
      if c.minL > main.maxL then left[#left + 1] = c
      elseif c.maxL < main.minL then right[#right + 1] = c
      else other[#other + 1] = c end
    end
  end
  table.sort(left, function (a, b) return a.maxL > b.maxL end)
  table.sort(right, function (a, b) return a.maxL > b.maxL end)
  table.sort(other, function (a, b) return a.sumH / #a.leds > b.sumH / #b.leds end)
  local groups = {}
  local function add(c, name, role)
    if c then groups[#groups + 1] = { name = name, role = role, cluster = c } end
  end
  add(main, 'Řada otáček', 'main')
  for i = 1, #left do add(left[i], #left > 1 and ('Levé ' .. i) or 'Levé', 'side') end
  for i = 1, #right do add(right[i], #right > 1 and ('Pravé ' .. i) or 'Pravé', 'side') end
  for i = 1, #other do add(other[i], #other > 1 and ('Další řada ' .. i) or 'Další řada', 'other') end
  return groups, th or 0
end

-- ---------------------------------------------------------------- detection

local REASON_NONE = 'mesh se jménem nebyl v modelu auta nalezen'

function M.run(car, info)
  local layout = { carId = info.carId, leds = {}, groups = {}, rejected = {}, warnings = {}, counts = {},
    source = 'none', signature = '0', threshold = 0, steer = 0 }
  local root = ac.findNodes('carRoot:0')
  if not root or #root == 0 then
    layout.warnings[#layout.warnings + 1] = 'Model auta zatím není načtený.'
    layout.notReady = true
    return layout
  end
  local lodA = safeFind(root, '{ lod:A }') or root
  local groupsOfNames = candidateGroups(root, info, layout.counts)

  local eyes = vec3()
  car.transform:transformPointTo(eyes, car.driverEyesPosition)
  local cp, side, up = car.position, car.side, car.up
  local w0, w1 = car.wheels[0].position, car.wheels[1].position
  local leftSign = dot(w0.x - w1.x, w0.y - w1.y, w0.z - w1.z, side) >= 0 and 1 or -1
  local world = vec3()

  local valid = {}
  for g = 1, #groupsOfNames do
    local names = groupsOfNames[g]
    local tried = {}
    for i = 1, #names do
      local c = names[i]
      local inst = instancesOf(root, lodA, c.name)
      local p = inst[1]
      local reason = nil
      if not p then reason = REASON_NONE
      elseif not p.hasSphere then reason = 'mesh nemá geometrii (bounding sphere)'
      elseif p.radius > MAX_RADIUS then reason = string.format('příliš velký mesh (%.0f cm), asi více diod v jednom', p.radius * 100)
      else
        M.worldOf(p, world)
        local dx, dy, dz = world.x - eyes.x, world.y - eyes.y, world.z - eyes.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > MAX_EYES then reason = string.format('daleko od řidiče (%.1f m)', d) end
      end
      if reason then
        layout.rejected[#layout.rejected + 1] = { name = c.name, source = c.source, reason = reason }
      else
        local rx, ry, rz = world.x - cp.x, world.y - cp.y, world.z - cp.z
        tried[#tried + 1] = { name = c.name, source = c.source, rpm = c.rpm, inst = inst, primary = p,
          world = vec3(world.x, world.y, world.z),
          lateral = dot(rx, ry, rz, side) * leftSign, height = dot(rx, ry, rz, up), visible = p.visible }
      end
    end
    -- hidden LEDs are dropped when others of the same source are visible (all hidden = inactive LOD or camera)
    local anyVisible = false
    for i = 1, #tried do if tried[i].visible then anyVisible = true end end
    for i = 1, #tried do
      local led = tried[i]
      if anyVisible and not led.visible then
        layout.rejected[#layout.rejected + 1] = { name = led.name, source = led.source, reason = 'skrytý mesh' }
      elseif #valid < MAX_LEDS then
        valid[#valid + 1] = led
      end
    end
    if #valid > 0 then
      layout.source = valid[1].source
      if not anyVisible then
        layout.warnings[#layout.warnings + 1] = 'Diody jsou teď skryté (jiný pohled nebo LOD), pořadí může být nepřesné.'
      end
      break
    end
  end

  local groups, th = makeGroups(valid)
  layout.threshold = th
  local sig = {}
  for gi = 1, #groups do
    local g = groups[gi]
    g.leds = {}
    for k = 1, #g.cluster.leds do
      local led = g.cluster.leds[k]
      led.id = #layout.leds + 1
      led.group = gi
      layout.leds[led.id] = led
      g.leds[k] = led.id
    end
    g.vertical = g.cluster.vertical
    g.cluster = nil
    sig[gi] = tostring(#g.leds)
  end
  layout.groups = groups
  layout.signature = #sig > 0 and table.concat(sig, '+') or '0'
  layout.steer = tonumber(car.steer) or 0
  if math.abs(layout.steer) > 3 then
    layout.warnings[#layout.warnings + 1] = string.format(
      'Volant byl při hledání natočený (%.0f°), pořadí může být nepřesné. S rovným volantem dejte Znovu najít.', layout.steer)
  end
  return layout
end

return M
