-- Minimal stand-in for the CSP Lua API, enough to run LedControl outside the game.
-- Scene: nodes with live translation matrices, meshes with materials (shared on purpose), visibility, LOD and
-- CSP flags; an AC LED driver that rewrites the LEDs' ksEmissive by RPM every frame (to prove the takeover wins).
-- It is served to the app through the fake adapter (fake_csp.lua). Names and argument shapes follow the SDK
-- (tests/ledcontrol/sdk_signatures.txt lists where each one is defined or used by official CSP code).
--
-- UNSURE (behaviour of the game this mock has to guess; a test that passes here may still fail in the game):
--  * frame order: the mock runs AC's LED writer, then script.update, then script.frameBegin, then the render
--    callback. When AC really writes ksEmissive relative to the app's callbacks is not documented.
--  * whether AC / CSP write the emissive of the LED's material (shared by every mesh using it) or per mesh, and
--    whether ensureUniqueMaterials on a created copy really detaches it from CSP's emissive logic.
--  * whether a mesh hidden with setVisible(false) stays hidden after a LOD switch or a session reset (the mock
--    keeps it hidden; the jammer in test_jammer.lua tries both).
--  * render.mesh / render.circle: the mock only records the calls, it cannot tell whether the redrawn LED covers
--    the original on screen (bloom, depth, transparency order).
--  * createMesh / getVertices / getIndices: the mock copies tables; the game may refuse a mesh (skinned, too
--    big, packed in a KN5 LOD that is not loaded).
--  * ac.storage, io.save / io.load: written at once and never fail in the mock.

local M = { frameNo = 0, clock = 0, storage = {}, callbacks = {}, renderCallbacks = {}, draws = {}, ini = {}, cspConfig = {},
  carId = 'test_car', ui = { texts = {} }, acLeds = {}, acWrites = 'mesh' }

-- ---------------------------------------------------------------- maths

local vec2mt = {}
vec2mt.__index = vec2mt
function vec2mt:set(x, y) self.x, self.y = x, y; return self end
vec2 = setmetatable({}, { __call = function (_, x, y) return setmetatable({ x = x or 0, y = y or 0 }, vec2mt) end })

local vec3mt = {}
vec3mt.__index = vec3mt
function vec3mt:set(x, y, z)
  if type(x) == 'table' then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end
  return self
end
vec3 = setmetatable({}, { __call = function (_, x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vec3mt) end })

local rgbmt = {}
rgbmt.__index = rgbmt
function rgbmt:set(r, g, b)
  if type(r) == 'table' then self.r, self.g, self.b = r.r, r.g, r.b else self.r, self.g, self.b = r, g, b end
  return self
end
rgb = setmetatable({}, { __call = function (_, r, g, b) return setmetatable({ r = r or 0, g = g or 0, b = b or 0 }, rgbmt) end })

local rgbmmt = {}
rgbmmt.__index = rgbmmt
function rgbmmt:set(c) self.r, self.g, self.b, self.mult = c.r, c.g, c.b, c.mult; return self end
rgbm = setmetatable({}, { __call = function (_, r, g, b, m)
  return setmetatable({ r = r or 0, g = g or 0, b = b or 0, mult = m or 0 }, rgbmmt) end })

-- mat4x4: translations only (scale ignored), enough for the node chain
local matmt = {}
matmt.__index = matmt
local function newMat(x, y, z)
  local m = setmetatable({ tx = x or 0, ty = y or 0, tz = z or 0 }, matmt)
  m.position = { set = function (_, px, py, pz) m.tx, m.ty, m.tz = px, py, pz end }
  return m
end
function matmt:mul(o) return newMat(self.tx + o.tx, self.ty + o.ty, self.tz + o.tz) end
function matmt:mulSelf(o) self.tx, self.ty, self.tz = self.tx + o.tx, self.ty + o.ty, self.tz + o.tz; return self end
function matmt:set(o) self.tx, self.ty, self.tz = o.tx, o.ty, o.tz; return self end
function matmt:transformPointTo(dst, v) dst.x, dst.y, dst.z = v.x + self.tx, v.y + self.ty, v.z + self.tz; return dst end
mat4x4 = {
  identity = function () return newMat(0, 0, 0) end,
  translation = function (v) return newMat(v.x, v.y, v.z) end,
  scaling = function () return newMat(0, 0, 0) end,
}
M.newMat = newMat

-- ---------------------------------------------------------------- write log
-- Every material and visibility write is logged on the object (a ring of LOG_MAX entries: frame, kind, writer,
-- value), with counts per writer. The app is the writer of every scene reference call; AC's LED writer ('ac') and the
-- jammer ('jammer') write through M.writeEmissive / M.writeVisible with their own name. An app write that repeats
-- the app's own last write on that object (no other writer in between, same value) is counted as redundant.

M.LOG_MAX = 32
M.redundant = { emissive = 0, visible = 0, lastObj = nil, lastKind = nil, lastFrame = 0 }
M.writeCount = { app = 0, ac = 0, jammer = 0 }

-- the ring is made in full when the object is created, so logging never allocates inside a measured frame
local function newLog()
  local log = { n = 0 }
  for i = 1, M.LOG_MAX do log[i] = { frame = 0, kind = '', writer = '', r = 0, g = 0, b = 0 } end
  return log
end
M.newLog = newLog

local function logWrite(obj, kind, writer, r, g, b)
  local log = obj.log
  if not log then log = newLog(); obj.log = log end
  local slot = log.n % M.LOG_MAX + 1
  local prev = log.n > 0 and log[(log.n - 1) % M.LOG_MAX + 1] or nil
  if writer == 'app' and prev and prev.writer == 'app' and prev.kind == kind and prev.r == r and prev.g == g
    and prev.b == b then
    local key = kind == 'visible' and 'visible' or 'emissive'
    M.redundant[key] = M.redundant[key] + 1
    M.redundant.lastObj, M.redundant.lastKind, M.redundant.lastFrame = obj, kind, M.frameNo
  end
  log.n = log.n + 1
  local e = log[slot]
  if not e then e = {}; log[slot] = e end
  e.frame, e.kind, e.writer, e.r, e.g, e.b = M.frameNo, kind, writer, r, g, b
  M.writeCount[writer] = (M.writeCount[writer] or 0) + 1
end
M.logWrite = logWrite

-- The last logged write on a material or mesh (nil when none).
function M.lastWrite(obj)
  local log = obj and obj.log
  if not log or log.n == 0 then return nil end
  return log[(log.n - 1) % M.LOG_MAX + 1]
end

function M.writeEmissive(mat, r, g, b, writer)
  local e = mat.ksEmissive
  e.r, e.g, e.b = r, g, b
  logWrite(mat, 'ksEmissive', writer or 'ac', r, g, b)
end

function M.writeVisible(mesh, v, writer)
  mesh.visible = v == true
  logWrite(mesh, 'visible', writer or 'ac', v and 1 or 0, 0, 0)
end

-- ---------------------------------------------------------------- scene

local refmt = {}
refmt.__index = refmt
local function ref(list)
  local r = setmetatable({}, refmt)
  for i = 1, #(list or {}) do r[i] = list[i] end
  return r
end
M.ref = ref

local materialCounter = 0
function M.material(name, r, g, b)
  materialCounter = materialCounter + 1
  return { name = name or ('mat' .. materialCounter), id = materialCounter, ksEmissive = { r = r or 0, g = g or 0, b = b or 0 },
    log = newLog() }
end

function M.node(name, parent, x, y, z)
  local n = { kind = 'node', name = name, parent = parent, children = {}, matrix = newMat(x, y, z), active = true }
  if parent then parent.children[#parent.children + 1] = n end
  return n
end

function M.mesh(name, parent, opts)
  opts = opts or {}
  local c = opts.centre or { 0, 0, 0 }
  local m = { kind = 'mesh', name = name, parent = parent, material = opts.material or M.material(), visible = opts.visible ~= false,
    centre = { x = c[1], y = c[2], z = c[3] }, radius = opts.radius or 0.004, lod = opts.lod or 'A',
    actsAsLED = opts.actsAsLED or false, shadows = false, transparent = false, created = false, log = newLog() }
  parent.children[#parent.children + 1] = m
  return m
end

local function escape(p)
  return (p:gsub('[%^%$%(%)%%%.%[%]%*%+%-]', '%%%0'))
end
local function namePattern(p)
  return '^' .. (escape(p):gsub('%?', '.*')) .. '$'
end

local function compile(filter)
  filter = filter:gsub('^%s+', ''):gsub('%s+$', '')
  if filter:sub(1, 1) ~= '{' then
    local pat = namePattern(filter)
    return function (m) return m.name:match(pat) ~= nil end
  end
  local body = filter:sub(2, -2)
  local tests = {}
  for term in body:gmatch('[^&]+') do
    term = term:gsub('^%s+', ''):gsub('%s+$', '')
    if term == 'actsAsLED:yes' then tests[#tests + 1] = function (m) return m.actsAsLED end
    elseif term:match('^lod:') then
      local l = term:sub(5)
      tests[#tests + 1] = function (m) return m.lod == l end
    elseif term:sub(1, 1) == '(' then
      local pats = {}
      for p in term:sub(2, -2):gmatch('[^,]+') do pats[#pats + 1] = namePattern((p:gsub('^%s+', ''):gsub('%s+$', ''))) end
      tests[#tests + 1] = function (m)
        for i = 1, #pats do if m.name:match(pats[i]) then return true end end
        return false
      end
    else
      local pat = namePattern(term)
      tests[#tests + 1] = function (m) return m.name:match(pat) ~= nil end
    end
  end
  return function (m)
    for i = 1, #tests do if not tests[i](m) then return false end end
    return true
  end
end

local function walk(obj, fn)
  if obj.kind == 'mesh' then fn(obj) return end
  for i = 1, #obj.children do walk(obj.children[i], fn) end
end

function refmt:findMeshes(filter)
  local test = compile(filter)
  local out, seen = {}, {}
  for i = 1, #self do
    walk(self[i], function (m)
      if not seen[m] and not m.disposed and test(m) then seen[m] = true; out[#out + 1] = m end
    end)
  end
  return ref(out)
end
function refmt:at(i, out)
  out = out or ref()
  for k = #out, 1, -1 do out[k] = nil end
  out[1] = self[i]
  return out
end
function refmt:name(i) local o = self[i or 1]; return o and o.name or '' end
function refmt:materialName(i) local o = self[i or 1]; return o and o.material and o.material.name or '' end
function refmt:getParent()
  local out, seen = {}, {}
  for i = 1, #self do
    local p = self[i].parent
    if p and not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return ref(out)
end
function refmt:getTransformationRaw()
  local o = self[1]
  if not o then return nil end
  if o.kind ~= 'node' then error('not a node') end
  return o.matrix
end
function refmt:boundingSphere(i, out)
  local o = self[i or 1]
  if not o or o.kind ~= 'mesh' then return nil, nil end
  out = out or vec3()
  out.x, out.y, out.z = o.centre.x, o.centre.y, o.centre.z
  return out, o.radius
end
function refmt:setVisible(v)
  for i = 1, #self do
    local o = self[i]
    if o.kind == 'mesh' then o.visible = v == true; logWrite(o, 'visible', 'app', v and 1 or 0, 0, 0) end
  end
  return self
end
function refmt:isVisible(i) local o = self[i or 1]; return o ~= nil and o.kind == 'mesh' and o.visible and not o.disposed end
function refmt:isActive(i) local o = self[i or 1]; return o ~= nil and o.active ~= false end
function refmt:isCastingShadows(i) local o = self[i or 1]; return o ~= nil and o.shadows end
function refmt:isTransparent(i) local o = self[i or 1]; return o ~= nil and o.transparent end
function refmt:setShadows(v) for i = 1, #self do self[i].shadows = v end return self end
function refmt:setTransparent(v) for i = 1, #self do self[i].transparent = v end return self end
-- (M.noVertices[name] = true: the game gives no vertex data for that mesh, as getVertices may return nil)
-- The vertex list knows only UVs (mesh opts uvs = { { u, v }, ... }, default none: size 0) as ac.VertexBuffer
-- :size() / :get(i) -> ac.MeshVertex { uv } (acc-lua-sdk lib_scene.lua).
M.noVertices = {}
local vbmt = {}
vbmt.__index = vbmt
function vbmt:size() return self.source.uvs and #self.source.uvs or 0 end
function vbmt:get(i)
  local uv = self.source.uvs and self.source.uvs[i]
  if not uv then return nil end
  return { pos = vec3(), normal = vec3(), uv = vec2(uv[1], uv[2]) }
end
function refmt:getVertices()
  if self[1] and self[1].kind == 'mesh' and not M.noVertices[self[1].name] then
    return setmetatable({ source = self[1] }, vbmt)
  end
  return nil
end
-- material description (mesh opts shader / texSlots, default ksPerPixel with txDiffuse only)
function refmt:shaderName(i) local o = self[i or 1]; return o and (o.shader or 'ksPerPixel') or nil end
function refmt:getTextureSlotsCount(i) local o = self[i or 1]; return o and #(o.texSlots or { 'txDiffuse' }) or 0 end
function refmt:getTextureSlotName(i, k) local o = self[i or 1]; return o and (o.texSlots or { 'txDiffuse' })[k] or nil end
function refmt:getTextureSlotFilename(index, slot)
  if type(index) == 'string' then index, slot = 1, index end
  local o = self[index or 1]
  if not o then return nil end
  local t = o.textures and o.textures[slot]
  if type(t) == 'string' then return t end
  if o.texFile == false then return nil end           -- (a test: the game gives no filename)
  return o.texFile or ('tex_' .. o.name .. '_' .. tostring(slot) .. '.dds')
end
function refmt:getIndices() if self[1] and self[1].kind == 'mesh' then return { source = self[1] } end return nil end
function refmt:createMesh(name, materialName, v, ix, keepAlive, moveData)
  if M.createMeshFails then return nil end
  local parent = self[1]
  local s = v.source
  local m = M.mesh(name, parent, { centre = { s.centre.x, s.centre.y, s.centre.z }, radius = s.radius, lod = s.lod })
  m.created, m.keepAlive, m.copyOf = true, keepAlive == true, s
  return ref({ m })
end
function refmt:assignMaterialFrom(other, index)
  local src = other[index or 1]
  for i = 1, #self do self[i].material = src.material end
  return self
end
local function allMeshes()
  local list = {}
  walk(M.root, function (m) if not m.disposed then list[#list + 1] = m end end)
  return list
end
function refmt:ensureUniqueMaterials()
  local inSet = {}
  for i = 1, #self do inSet[self[i]] = true end
  local usedOutside = {}
  for _, m in ipairs(allMeshes()) do if not inSet[m] then usedOutside[m.material] = true end end
  local clones = {}
  for i = 1, #self do
    local m = self[i]
    if usedOutside[m.material] then
      local c = clones[m.material]
      if not c then
        local e = m.material.ksEmissive
        c = M.material(m.material.name, e.r, e.g, e.b)
        clones[m.material] = c
      end
      m.material = c
    end
  end
  return self
end
function refmt:setMaterialProperty(prop, value)
  if M.failSetMaterial then error('setMaterialProperty failed (test)') end
  for i = 1, #self do
    local mat = self[i].material
    local t = mat[prop]
    if not t then t = {}; mat[prop] = t end
    t.r, t.g, t.b = value.r or value.x, value.g or value.y, value.b or value.z
    logWrite(mat, prop, 'app', t.r, t.g, t.b)
  end
  M.materialWrites = (M.materialWrites or 0) + 1
  return self
end
-- Dynamic texture (setMaterialTexture with a table, acc-lua-sdk lib_scene.lua): the callback runs at once with the
-- draw calls recorded into a canvas on each mesh of the reference (fake canvas: commands, size, region).
M.paints = 0
-- width of a text in the mock font metric (0.52 x size per UTF-8 character), counted without allocating
function M.textWidth(t, size)
  local n = 0
  for i = 1, #t do
    local b = t:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n * size * 0.52
end
function refmt:setMaterialTexture(slot, value)
  if type(value) == 'table' then
    if not value.callback then error('Callback is missing', 2) end
    -- one canvas per mesh and slot, reused by every paint (its command tables too)
    local owner = self[1]
    owner.canvases = owner.canvases or {}
    local cv = owner.canvases[slot]
    if not cv then cv = { n = 0, cmds = {} }; owner.canvases[slot] = cv end
    cv.n, cv.slot, cv.size, cv.region, cv.frame, cv.background = 0, slot, value.textureSize, value.region, M.frameNo,
      value.background
    M.recording = cv
    local ok, err = pcall(value.callback, 1 / 60)
    M.recording = nil
    if not ok then error(err, 2) end
    -- content hash: a repaint with exactly the same picture counts as a redundant write
    local h = 0
    for k = 1, cv.n do
      local c = cv.cmds[k]
      for j = 2, #c do
        local v = c[j]
        if type(v) == 'number' then h = (h * 31 + math.floor(v * 1000)) % 2147483647
        elseif type(v) == 'string' then for q = 1, #v do h = (h * 31 + v:byte(q)) % 2147483647 end end
      end
    end
    cv.hash = h
    for i = 1, #self do
      local m = self[i]
      if not m.textures then m.textures = {} end
      m.textures[slot] = cv
      logWrite(m, 'texture', 'app', h, 0, 0)
    end
    M.paints = M.paints + 1
    M.lastCanvas = cv
  else
    for i = 1, #self do self[i].textures = self[i].textures or {}; self[i].textures[slot] = value end
  end
  return self
end
function refmt:getMaterialPropertyValue(index, prop)
  if type(index) == 'string' then index, prop = 1, index end
  local o = self[index or 1]
  local t = o and o.material[prop]
  if not t then return nil end
  return vec3(t.r, t.g, t.b)
end
function refmt:getMaterialsCount()
  local seen, n = {}, 0
  for i = 1, #self do
    local m = self[i].material
    if m and not seen[m] then seen[m] = true; n = n + 1 end
  end
  return n
end
function refmt:countMatches(other)
  local inSelf = {}
  for i = 1, #self do inSelf[self[i]] = true end
  local n = 0
  for i = 1, #other do if inSelf[other[i]] then n = n + 1 end end
  return n
end
function refmt:append(other) for i = 1, #other do self[#self + 1] = other[i] end return self end
function refmt:dispose()
  for i = 1, #self do
    local o = self[i]
    o.disposed = true
    local p = o.parent
    if p then for k = #p.children, 1, -1 do if p.children[k] == o then table.remove(p.children, k) end end end
  end
  for i = #self, 1, -1 do self[i] = nil end
end

-- What the driver sees for an original LED mesh: its own emissive when visible, a visible copy's emissive, or a
-- redrawn colour on top. Returns r, g, b, plus 'double' when the original and a copy are both visible.
function M.seen(mesh)
  local d = M.draws[mesh]
  if d and d.frame == M.frameNo then return d.r, d.g, d.b, 'drawn' end
  local shown, r, g, b = 0, 0, 0, 0
  if mesh.visible and not mesh.disposed then
    shown = 1
    r, g, b = mesh.material.ksEmissive.r, mesh.material.ksEmissive.g, mesh.material.ksEmissive.b
  end
  for _, c in ipairs(mesh.parent.children) do
    if c.copyOf == mesh and c.visible and not c.disposed then
      shown = shown + 1
      r, g, b = c.material.ksEmissive.r, c.material.ksEmissive.g, c.material.ksEmissive.b
    end
  end
  return r, g, b, shown == 2 and 'double' or (shown == 0 and 'none' or 'ok')
end

-- AC's digital instruments: every frame, LED k gets its colour when rpm >= its threshold, else black.
-- acWrites = 'mesh': into the mesh's current material; 'material': into the material it had at load.
function M.acStep()
  if not M.car then return end
  local rpm = M.car.rpm
  for i = 1, #M.acLeds do
    local a = M.acLeds[i]
    local lit = rpm >= a.rpm
    for k = 1, #a.meshes do
      local mesh = a.meshes[k]
      M.writeEmissive(M.acWrites == 'mesh' and mesh.material or a.materials[k], lit and a.r or 0, lit and a.g or 0,
        lit and a.b or 0, 'ac')
    end
  end
end

-- CSP reloading the script: meshes created without keepAlive are removed, everything else stays as it is.
function M.reloadScene()
  walk(M.root, function (m) if m.created and not m.keepAlive then m.disposed = true end end)
end

-- ---------------------------------------------------------------- render

render = {
  BlendMode = { OpaqueForced = 27 }, DepthMode = { LessEqual = 3 }, CullMode = { None = 0 },
  setBlendMode = function () end, setDepthMode = function () end, setCullMode = function () end,
  on = function (name, cb) M.renderCallbacks[name] = cb end,
  mesh = function (p)
    if M.meshFails then error('render.mesh failed (test)') end
    local o = p.mesh[1]
    local d = M.draws[o]
    if not d then d = {}; M.draws[o] = d end
    d.r, d.g, d.b, d.frame = p.values.gColor.r, p.values.gColor.g, p.values.gColor.b, M.frameNo
    M.drawCount = (M.drawCount or 0) + 1
  end,
}

-- ---------------------------------------------------------------- ac

local function iniObject(sections)
  local o = { sections = sections }
  function o:get(section, key, default)
    local s = self.sections[section]
    local v = s and s[key]
    if v == nil then return default end
    if type(default) == 'number' then return tonumber(v[1]) or default end
    if default == nil then return v end
    return v[1]
  end
  return o
end

ac = {
  FolderID = { ScriptConfig = 1 },
  getCar = function (i) if i == 0 then return M.car end return nil end,
  getSim = function () return M.sim end,
  getCarID = function () return M.carId end,
  findNodes = function (f)
    if f == 'carRoot:0' and M.root then return ref({ M.root }) end
    return ref({})
  end,
  emptySceneReference = function () return ref({}) end,
  INIConfig = {
    carData = function (_, file)
      if M.iniFails then error('ini failed (test)') end
      return iniObject(M.ini[file] or {})
    end,
    carConfig = function () return iniObject(M.cspConfig) end,
  },
  storage = function (defaults, prefix)
    return setmetatable({}, {
      __index = function (_, k)
        local v = M.storage[prefix .. k]
        if v == nil then return defaults[k] end
        return v
      end,
      __newindex = function (_, k, v) M.storage[prefix .. k] = v end,
    })
  end,
  getFolder = function () return M.folder end,
  onRelease = function (cb) M.callbacks.release = cb end,
  onSessionStart = function (cb) M.callbacks.session = cb end,
  setClipboardText = function (t) M.clipboard = t end,
  getPatchVersion = function () return '0.2.11-mock' end,
  getPatchVersionCode = function () return 3400 end,
  ControlButton = function (id)
    return { id = id, pressed = function ()
        local p = M.hotkeys and M.hotkeys[id]
        if p then M.hotkeys[id] = nil return true end
        if id == '__APP_LEDCONTROL_MASTER' and M.hotkeyPressed then M.hotkeyPressed = false return true end
        return false
      end,
      control = function () M.hotkeyControlDrawn = true end }
  end,
}

-- ---------------------------------------------------------------- files

function io.fileExists(p) local f = io.open(p, 'r'); if f then f:close(); return true end return false end
function io.load(p) local f = io.open(p, 'r'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
function io.save(p, s) local f = io.open(p, 'w'); if not f then return false end f:write(s); f:close(); return true end
function io.createDir() return true end
function io.deleteFile(p) os.remove(p) end

local function ser(v, out)
  local t = type(v)
  if t == 'number' then out[#out + 1] = string.format('%.17g', v)
  elseif t == 'string' then out[#out + 1] = string.format('%q', v)
  elseif t == 'boolean' then out[#out + 1] = tostring(v)
  elseif t == 'table' then
    out[#out + 1] = '{'
    for k, x in pairs(v) do
      out[#out + 1] = '['; ser(k, out); out[#out + 1] = ']='; ser(x, out); out[#out + 1] = ','
    end
    out[#out + 1] = '}'
  else out[#out + 1] = 'nil' end
end
stringify = setmetatable({
  parse = function (s)
    local f = assert(loadstring('return ' .. s))
    setfenv(f, setmetatable({}, { __index = function (_, k) error('Not available: ' .. tostring(k)) end }))
    return f()
  end,
}, { __call = function (_, v) local out = {}; ser(v, out); return table.concat(out) end })

function io.scanDir(dir, mask)
  local out = {}
  local pat = '^' .. mask:gsub('[%.%-]', '%%%0'):gsub('%*', '.*') .. '$'
  local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
  if p then
    for name in p:lines() do if name:match(pat) then out[#out + 1] = name end end
    p:close()
  end
  return out
end

-- JSON (CSP's is native; this is a small pure Lua stand-in)
local function jenc(v, out)
  local t = type(v)
  if t == 'nil' then out[#out + 1] = 'null'
  elseif t == 'boolean' then out[#out + 1] = tostring(v)
  elseif t == 'number' then out[#out + 1] = string.format('%.14g', v)
  elseif t == 'string' then out[#out + 1] = '"' .. v:gsub('[%c"\\]', function (c) return string.format('\\u%04x', c:byte()) end) .. '"'
  elseif t == 'table' then
    local n = #v
    local isArray = n > 0 or next(v) == nil
    if isArray then for k in pairs(v) do if type(k) ~= 'number' or k > n or k < 1 then isArray = false end end end
    if isArray then
      out[#out + 1] = '['
      for i = 1, n do if i > 1 then out[#out + 1] = ',' end jenc(v[i], out) end
      out[#out + 1] = ']'
    else
      out[#out + 1] = '{'
      local first = true
      for k, x in pairs(v) do
        if not first then out[#out + 1] = ',' end
        first = false
        jenc(tostring(k), out); out[#out + 1] = ':'; jenc(x, out)
      end
      out[#out + 1] = '}'
    end
  end
end
local function jdec(s)
  local i = 1
  local function ws() i = s:find('[^%s]', i) or #s + 1 end
  local val
  local function str()
    local j = i + 1
    local buf = {}
    while true do
      local c = s:sub(j, j)
      if c == '' then error('bad json string') end
      if c == '"' then break end
      if c == '\\' then
        local e = s:sub(j + 1, j + 1)
        if e == 'u' then buf[#buf + 1] = string.char(tonumber(s:sub(j + 2, j + 5), 16) % 256); j = j + 6
        else buf[#buf + 1] = ({ n = '\n', t = '\t', r = '\r' })[e] or e; j = j + 2 end
      else buf[#buf + 1] = c; j = j + 1 end
    end
    i = j + 1
    return table.concat(buf)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == '{' then
      i = i + 1
      local o = {}
      ws()
      if s:sub(i, i) == '}' then i = i + 1 return o end
      while true do
        ws()
        local k = str()
        ws()
        if s:sub(i, i) ~= ':' then error('bad json object') end
        i = i + 1
        o[k] = val()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == '}' then return o end
        if d ~= ',' then error('bad json object') end
      end
    elseif c == '[' then
      i = i + 1
      local a = {}
      ws()
      if s:sub(i, i) == ']' then i = i + 1 return a end
      while true do
        a[#a + 1] = val()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == ']' then return a end
        if d ~= ',' then error('bad json array') end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == 'true' then i = i + 4 return true
    elseif s:sub(i, i + 4) == 'false' then i = i + 5 return false
    elseif s:sub(i, i + 3) == 'null' then i = i + 4 return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
      if not num or num == '' then error('bad json value at ' .. i) end
      i = i + #num
      return tonumber(num)
    end
  end
  local v = val()
  ws()
  if i <= #s then error('trailing json') end
  return v
end
JSON = {
  stringify = function (v) local out = {}; jenc(v, out); return table.concat(out) end,
  parse = jdec,
}

-- ---------------------------------------------------------------- ui

local U = M.ui
local function turnPoint(cw, pivot, x, y)
  local dx, dy = x - pivot.x, y - pivot.y
  if cw == 90 then return pivot.x - dy, pivot.y + dx
  elseif cw == 180 then return pivot.x - dx, pivot.y - dy
  elseif cw == 270 then return pivot.x + dy, pivot.y - dx end
  return x, y
end
local function rec(s) if U.record then U.texts[#U.texts + 1] = s end end
ui = {
  ColorPickerFlags = { PickerHueBar = 1, NoPicker = 4, NoTooltip = 64, NoAlpha = 2, NoInputs = 32 },
  TreeNodeFlags = { None = 0, Framed = 2, DefaultOpen = 32 },
  StyleColor = { Text = 0, Button = 21 },
  Font = { Main = 0, Small = 1, Title = 2, Huge = 3, Tiny = 4 },
  ButtonFlags = { None = 0, Disabled = 0x100 },
  Icons = setmetatable({}, { __index = function (_, k) return 'icon:' .. k end }),
  -- collapsible sections are always drawn open in the tests (their label is recorded)
  treeNode = function (label, flags, content)
    if content == nil then flags, content = nil, flags end
    U.last = label
    rec(label)
    if content then content() end
  end,
  textDisabled = function (t) rec(t) end,   -- keeps U.last: hovering the item before a (?) shows its help
  alignTextToFramePadding = function () end,
  offsetCursorY = function () end,
  offsetCursorX = function () end,
  setCursorX = function () end,
  setCursorY = function () end,
  indent = function () end,
  unindent = function () end,
  setNextItemIcon = function () end,
  measureText = function (t) return vec2(#tostring(t) * 7, 14) end,
  HoveredFlags = { None = 0, AllowWhenBlockedByActiveItem = 32 },
  invisibleButton = function (label) U.last = label; return U.click == label end,
  itemActive = function () return U.active ~= nil and U.active == U.last end,
  mouseDown = function () return U.mouseDown == true end,
  pushFont = function () end,
  popFont = function () end,
  pushStyleColor = function () end,
  popStyleColor = function () end,
  pushID = function (id) U.idStack = U.idStack or {}; U.idStack[#U.idStack + 1] = id end,
  popID = function () U.idStack[#U.idStack] = nil end,
  -- an icon button is clicked by the id pushed before it (kit.iconButton): env.ui.click = 'id'
  iconButton = function (icon, size, padding, frame, flags)
    local id = U.idStack and U.idStack[#U.idStack]
    U.last = id
    if flags and flags ~= 0 then return false end      -- disabled
    return U.click ~= nil and U.click == id
  end,
  dummy = function () end,
  getCursor = function () return vec2(0, 0) end,
  -- rotation (acc-lua-sdk ui: beginRotation / endPivotRotation(deg, pivot), 90 = no turn): the canvas commands drawn
  -- in between are turned by 90 - deg clockwise around the pivot (multiples of 90 only; e[15] = the text's turn)
  beginRotation = function () if M.recording then M.recording.rotFrom = M.recording.n + 1 end end,
  endPivotRotation = function (deg, pivot)
    local cv = M.recording
    if not cv or not cv.rotFrom then return end
    local cw = ((90 - deg) % 360 + 360) % 360
    for k = cv.rotFrom, cv.n do
      local e = cv.cmds[k]
      local x1, y1 = turnPoint(cw, pivot, e[2], e[3])
      local x2, y2 = turnPoint(cw, pivot, e[4], e[5])
      e[2], e[3], e[4], e[5] = math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
      if e[1] == 'text' then e[15] = cw end
    end
    cv.rotFrom = nil
  end,
  getCursorX = function () return 0 end,
  getCursorY = function () return 0 end,
  drawCircleFilled = function () end,
  drawRectFilled = function (p1, p2, c, rounding)
    local cv = M.recording
    if cv then
      cv.n = cv.n + 1
      local e = cv.cmds[cv.n]
      if not e then e = {}; cv.cmds[cv.n] = e end          -- reused between paints: the mock must not allocate
      e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9] = 'rect', p1.x, p1.y, p2.x, p2.y, c.r, c.g, c.b, c.mult or 1
      e[10] = rounding or 0
      for k = 11, 15 do e[k] = nil end
    end
  end,
  -- DirectWrite text (signatures as official CSP code calls them; widths: UNSURE, 0.52 x size per character for
  -- Bahnschrift SemiCondensed, the real font is narrower or wider per glyph)
  Alignment = { Start = -1, Center = 0, End = 1 },          -- values as in acc-lua-sdk common/ac_ui_enums.lua
  pushDWriteFont = function (f) M.fontStack = M.fontStack or {}; M.fontStack[#M.fontStack + 1] = f end,
  popDWriteFont = function () if M.fontStack then M.fontStack[#M.fontStack] = nil end end,
  measureDWriteText = function (t, size)
    return vec2(M.textWidth(t, size), size * 1.2)
  end,
  dwriteDrawTextClipped = function (t, size, p1, p2, ha, va, wrap, c)
    local cv = M.recording
    if cv then
      cv.n = cv.n + 1
      local e = cv.cmds[cv.n]
      if not e then e = {}; cv.cmds[cv.n] = e end
      e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9] = 'text', p1.x, p1.y, p2.x, p2.y, c.r, c.g, c.b, c.mult or 1
      e[10], e[11], e[12], e[13], e[14], e[15] = t, size, ha, va, M.textWidth(t, size), 0
    end
  end,
  drawRect = function () end,
  progressBar = function () end,
  itemClicked = function () return false end,
  ComboFlags = { None = 0 },
  setNextItemWidth = function () end,
  header = function (t) rec(t) end,
  inputText = function (label, text)
    U.last = label
    local v = U.type and U.type[label]
    if v ~= nil then U.type[label] = nil return v, true, false end
    return text, false, false
  end,
  childWindow = function (id, size, border, flags, content)
    if content == nil then flags, content = content, flags end
    if content == nil then border, content = content, border end
    if content then content() end
  end,
  getClipboardText = function () return M.clipboard or '' end,
  selectable = function (label) U.last = label; rec(label); return U.click == label end,
  combo = function (label, preview, flags, content)
    U.last = label
    rec(preview)
    if U.openCombo == label and content then content() end
  end,
  checkbox = function (label) U.last = label; rec(label); return U.click == label end,
  button = function (label) U.last = label; rec(label); return U.click == label end,
  radioButton = function (label) U.last = label; rec(label); return U.click == label end,
  slider = function (label, v)
    U.last = label
    if U.slide and U.slide[label] then return U.slide[label], true end
    return v, false
  end,
  colorButton = function (label, c)
    U.last = label
    U.cells = (U.cells or 0) + 1
    local p = U.pick and U.pick[label]
    if p then c.r, c.g, c.b = p[1], p[2], p[3]; return true end
    return false
  end,
  itemHovered = function () return U.hover ~= nil and U.last == U.hover end,
  setTooltip = function (t) rec(t) end,
  text = function (t) rec(t) end,
  textWrapped = function (t) rec(t) end,
  textColored = function (t) rec(t) end,
  sameLine = function () end,
  separator = function () end,
  availableSpaceX = function () return 500 end,
  tabBar = function (_, fn) fn() end,
  tabItem = function (label, fn) if label == (U.tab or 'Diody') then fn() end end,
}

return M
