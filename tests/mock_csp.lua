-- Minimal stand-in for the CSP Lua API, enough to run MirrorDelta outside the game.
-- Only what the app uses is mocked; drawing calls are counted, not rendered.

local M = { clock = 0, calls = {}, callbacks = {}, storage = {}, windowW = 600, windowH = 80 }

local function count(name)
  M.calls[name] = (M.calls[name] or 0) + 1
end

render = { AntialiasingMode = { None = 0, YEBIS = 104, SimplifiedYEBIS = 105 }, ShadersType = { Main = 0, SimplifiedWithLights = 14 },
  onSceneReady = function (cb) M.sceneReady = cb end,
  on = function (name, cb) M.renderCallbacks = M.renderCallbacks or {}; M.renderCallbacks[name] = cb end,
  circle = function (pos, dir, radius, color, outline)
    M.circles = M.circles or {}
    M.circles[#M.circles + 1] = { x = pos.x, y = pos.y, z = pos.z, r = color.r, g = color.g, b = color.b, radius = radius }
  end,
  setDepthMode = function () end,
  DepthMode = { Normal = 0 },
  TextureFormat = { R16G16B16A16 = { Float = 10 }, R8G8B8A8 = { UNorm = 28 } } }

-- vec2
local vec2mt = {}
vec2mt.__index = vec2mt
function vec2mt:set(x, y) self.x, self.y = x, y; return self end
vec2 = setmetatable({}, { __call = function (_, x, y) return setmetatable({ x = x or 0, y = y or 0 }, vec2mt) end })

-- rgb
local rgbmt3 = {}
rgbmt3.__index = rgbmt3
function rgbmt3:set(r, g, b)
  if type(r) == 'table' then self.r, self.g, self.b = r.r, r.g, r.b else self.r, self.g, self.b = r, g, b end
  return self
end
rgb = setmetatable({}, { __call = function (_, r, g, b) return setmetatable({ r = r or 0, g = g or 0, b = b or 0 }, rgbmt3) end })

-- vec3
local vec3mt = {}
vec3mt.__index = vec3mt
function vec3mt:set(x, y, z) self.x, self.y, self.z = x, y, z; return self end
vec3 = setmetatable({}, { __call = function (_, x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vec3mt) end })

-- mat4x4 (translations only, enough for the node chain in the tests)
function M.translation(x, y, z)
  local m = { tx = x, ty = y, tz = z }
  function m:mulSelf(o) if o.live then o:live() end; self.tx, self.ty, self.tz = self.tx + o.tx, self.ty + o.ty, self.tz + o.tz; return self end
  function m:set(o) self.tx, self.ty, self.tz = o.tx, o.ty, o.tz; return self end
  function m:transformPointTo(dst, v) dst.x, dst.y, dst.z = v.x + self.tx, v.y + self.ty, v.z + self.tz; return dst end
  return m
end
mat4x4 = { identity = function () return M.translation(0, 0, 0) end }

-- car.worldToLocal: the inverse of car.transform below
function M.worldToLocalOf(car)
  return { transformPointTo = function (_, dst, v)
    local p, s, u, l = car.position, car.side or { x = 1, y = 0, z = 0 }, car.up or { x = 0, y = 1, z = 0 },
      car.look or { x = 0, y = 0, z = 1 }
    local rx, ry, rz = v.x - p.x, v.y - p.y, v.z - p.z
    dst.x, dst.y, dst.z = rx * s.x + ry * s.y + rz * s.z, rx * u.x + ry * u.y + rz * u.z, rx * l.x + ry * l.y + rz * l.z
    return dst
  end }
end

-- car.transform: local x along car.side, y along car.up, z along car.look, from car.position
function M.transformOf(car)
  return { transformPointTo = function (_, dst, v)
    local p, s, u, l = car.position, car.side or { x = 1, y = 0, z = 0 }, car.up or { x = 0, y = 1, z = 0 },
      car.look or { x = 0, y = 0, z = 1 }
    dst.x = p.x + s.x * v.x + u.x * v.y + l.x * v.z
    dst.y = p.y + s.y * v.x + u.y * v.y + l.y * v.z
    dst.z = p.z + s.z * v.x + u.z * v.y + l.z * v.z
    return dst
  end }
end

-- rgbm
local rgbmt = {}
rgbmt.__index = rgbmt
local function newRgbm(r, g, b, m) return setmetatable({ r = r or 0, g = g or 0, b = b or 0, mult = m or 0 }, rgbmt) end
function rgbmt:set(c) self.r, self.g, self.b, self.mult = c.r, c.g, c.b, c.mult; return self end
function rgbmt:setLerp(a, b, k)
  self.r = a.r + (b.r - a.r) * k
  self.g = a.g + (b.g - a.g) * k
  self.b = a.b + (b.b - a.b) * k
  self.mult = a.mult + (b.mult - a.mult) * k
  return self
end
function rgbmt:clone() return newRgbm(self.r, self.g, self.b, self.mult) end
rgbm = setmetatable({ isrgbm = function (v) return getmetatable(v) == rgbmt end }, {
  __call = function (_, r, g, b, m) return newRgbm(r, g, b, m) end,
})

-- stringify: plain Lua table constructor
local function ser(v, out)
  local t = type(v)
  if t == 'number' then out[#out + 1] = string.format('%.17g', v)
  elseif t == 'string' then out[#out + 1] = string.format('%q', v)
  elseif t == 'boolean' then out[#out + 1] = tostring(v)
  elseif t == 'table' then
    out[#out + 1] = '{'
    for k, x in pairs(v) do
      out[#out + 1] = '['
      ser(k, out)
      out[#out + 1] = ']='
      ser(x, out)
      out[#out + 1] = ','
    end
    out[#out + 1] = '}'
  else out[#out + 1] = 'nil' end
end
stringify = setmetatable({
  parse = function (s) return assert(loadstring('return ' .. s))() end,
}, { __call = function (_, v) local out = {}; ser(v, out); return table.concat(out) end })

-- io extensions
function io.fileExists(path) local f = io.open(path, 'rb'); if f then f:close(); return true end; return false end
function io.load(path) local f = io.open(path, 'rb'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
function io.save(path, data) local f = io.open(path, 'wb'); if not f then return false end; f:write(data); f:close(); return true end
function io.createDir(path) os.execute('mkdir -p "' .. path .. '"') end
function io.deleteFile(path) os.remove(path) end

os.preciseClock = function () return M.clock end

-- car, sim, session
M.car = {
  index = 0, splinePosition = 0, lapTimeMs = 0, lapCount = 0, previousLapTimeMs = 0, bestLapTimeMs = 0,
  racePosition = 3, engineLifeLeft = 1000, damage = { [0] = 0, 0, 0, 0 }, gear = 3, rpm = 7400, rpmLimiter = 7800, speedKmh = 184.4, isLapValid = true, isInPitlane = false, isInPit = false,
  tractionControlMode = 2, tractionControlModes = 8, absMode = 1, absModes = 1, brakeBias = 0.585,
  autoShift = false, autoClutch = true, manualPitsSpeedLimiterEnabled = false,
  wheels = {},
}
for i = 0, 3 do
  M.car.wheels[i] = {
    tyreCoreTemperature = 80 + i, tyreInsideTemperature = 90, tyreMiddleTemperature = 85,
    tyreOutsideTemperature = 78, tyreOptimumTemperature = 88, tyreWear = 0.1, isBlown = false, suspensionDamage = 0,
    position = { x = (i % 2 == 0) and 0.8 or -0.8, y = 0.3, z = i < 2 and 1.3 or -1.3 },   -- FL is on +x (left)
  }
end
-- own car at the origin facing +z; side points left (+x)
M.car.position, M.car.look, M.car.up = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, { x = 0, y = 1, z = 0 }
M.car.side, M.car.velocity = { x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 50 }
M.car.transform = M.transformOf(M.car)
M.car.worldToLocal = M.worldToLocalOf(M.car)
M.car.driverEyesPosition = { x = 0, y = 0.6, z = 0 }   -- like the old fixed camera height
M.car.aabbCenter, M.car.aabbSize = { x = 0, y = 0.5, z = -0.1 }, { x = 1.9, y = 1.2, z = 4.5 }   -- bottom at y -0.1
M.sim = { cameraPosition = { x = 0, y = 1, z = 0.2 }, isReplayActive = false, isPaused = false, carsCount = 12, currentSessionIndex = 0, damageDisplayerShown = true, raceFlagType = 0 }
M.cars = {}
M.overlayBoard = { displayMode = 2, verticalLayout = false }                   -- other cars by index (1..); missing ones are nil like unused slots
M.session = { laps = 15, isTimedRace = false, type = 3 }

ac = {
  findNodes = function (filter)
    -- scene reference: array part = meshes (names) of our car under 'carRoot:0', from M.carMeshes { name = isLED }
    local function ref(list)
      local r = { filter = filter }
      for k = 1, #list do r[k] = list[k] end
      function r:findMeshes(f)
        local out = {}
        for name, led in pairs(M.carMeshes or {}) do
          if name == f or (f == '{ actsAsLED:yes }' and led) then out[#out + 1] = name end
        end
        table.sort(out)
        return ref(out)
      end
      function r:at(k) return ref({ self[k] }) end
      -- mesh position: M.meshPos[name] (in its parent's space; the parent's world matrix is the identity)
      function r:boundingSphere(index, out)
        local p = (M.meshPos or {})[self[index or 1]]
        if not p then return nil, nil end
        out:set(p[1], p[2], p[3])
        return out, 0.01
      end
      -- parent node: its local transform moves by M.ledParentOffset (default none), and it hangs under the scene root
      function r:getParent()
        local node = { 'parent' }
        -- a live matrix: the car model's root follows car.position (+ M.ledParentOffset), read when multiplied
        function node:getTransformationRaw()
          local m = M.translation(0, 0, 0)
          function m:live()
            local o, p = M.ledParentOffset or { x = 0, y = 0, z = 0 }, M.car.position
            self.tx, self.ty, self.tz = p.x + o.x, p.y + o.y, p.z + o.z
            return self
          end
          return m
        end
        function node:getParent() return {} end
        return node
      end
      function r:setMaterialProperty(prop, value)
        M.emissive = M.emissive or {}
        for k = 1, #self do M.emissive[self[k]] = { value.r, value.g, value.b } end
        return self
      end
      return r
    end
    return ref({})
  end,
  GeometryShot = function (scene, size, mips, depth, aa, format)
    local shot = { scene = scene, size = size, aa = aa, mipCount = mips, updates = 0 }
    function shot:setBestSceneShotQuality() return self end
    function shot:setShadersType(t) self.shaders = t; return self end
    function shot:setClippingPlanes(near, far) self.near, self.far = near, far; return self end
    function shot:mipsUpdate() self.mips = (self.mips or 0) + 1; return self end
    function shot:setAlternativeShadowsSet(t) self.shadows = t; return self end
    function shot:setGrass(t) self.grass = t; return self end
    function shot:dispose() self.disposed = true end
    function shot:update(pos, look, up, fov)
      self.updates = self.updates + 1
      self.pos, self.look, self.up, self.fov = pos, look, up, fov
      return self
    end
    M.shots = M.shots or {}
    M.shots[#M.shots + 1] = shot
    return shot
  end,
  FolderID = { ScriptConfig = 1, ExtCfgUser = 18 },
  INIConfig = {
    carData = function (i, name)
      local data = M.carIni and M.carIni[name]
      if not data then return nil end
      return {
        get = function (_, section, key, default) local v = data[section .. '/' .. key]; if v == nil then return default end; return v end,
        -- LUT given as { {input, output}, ... }: linear interpolation like ac.DataLUT11
        tryGetLut = function (_, section, key)
          local pts = data[section .. '/' .. key]
          if type(pts) ~= 'table' then return nil end
          local lut = {}
          for k = 1, #pts do lut[k] = pts[k] end
          lut.get = function (_, x)
            if x <= pts[1][1] then return pts[1][2] end
            for k = 2, #pts do
              if x <= pts[k][1] then
                local a, b = pts[k - 1], pts[k]
                return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1])
              end
            end
            return pts[#pts][2]
          end
          return lut
        end,
      }
    end,
    load = function (path)
      M.iniFiles = M.iniFiles or {}
      local file = M.iniFiles[path] or {}
      M.iniFiles[path] = file
      return {
        get = function (_, section, key, default) local v = file[section .. '/' .. key]; if v == nil then return default end; return v end,
        setAndSave = function (_, section, key, value) file[section .. '/' .. key] = value; M.iniWrites = (M.iniWrites or 0) + 1 end,
      }
    end,
  },
  getFolder = function () return M.folder end,
  getCarID = function () return 'test_car' end,
  getTrackFullID = function (sep) return 'test_track' .. sep .. 'gp' end,
  getSim = function () return M.sim end,
  getCar = function (i) if (i or 0) == 0 then return M.car end; return M.cars[i] end,
  getDriverName = function (i) return i == 0 and 'Hráč' or ('Jezdec ' .. i) end,
  FlagType = { None = 0, Start = 1, Caution = 2, Stop = 5, ReturnToPits = 8, FasterCar = 12, Finished = 13, OneLapLeft = 14 },
  SessionType = { Practice = 1, Qualify = 2, Race = 3 },
  getSession = function () return M.session end,
  storage = function (layout)
    local t = {}
    for k, v in pairs(layout) do t[k] = M.storage[k] ~= nil and M.storage[k] or v end
    return setmetatable({}, {
      __index = function (_, k) return t[k] end,
      __newindex = function (_, k, v) t[k] = v; M.storage[k] = v end,
    })
  end,
  trySimKeyPressCommand = function (cmd)
    M.calls[cmd] = (M.calls[cmd] or 0) + 1
    if cmd == 'Hide Damage' then M.sim.damageDisplayerShown = not M.sim.damageDisplayerShown end
  end,
  getUI = function () return { windowSize = vec2(1920, 1080) } end,
  accessOverlayLeaderboardParams = function () return M.overlayBoard end,
  applyLiveConfigEdit = function (file, text) M.configEdits = M.configEdits or {}; M.configEdits[#M.configEdits + 1] = file .. ':' .. text end,
  onMessage = function (cb) M.callbacks.message = cb end,
  getAppWindows = function ()
    local list = {}
    for i, title in ipairs({ 'MirrorDelta', 'MirrorDelta Timing', 'MirrorDelta Tyres', 'MirrorDelta Gear',
      'MirrorDelta Damage', 'MirrorDelta Notifications', 'MirrorDelta Flags', 'Some Other App', 'MirrorDelta Setup',
      'MirrorDelta Mirror', 'Virtual Mirror', 'Race Flags', 'Car Mirrors Configurator', 'MirrorDelta Standings' }) do
      list[i] = { name = 'w' .. i, title = title, visible = false, layer = 0 }
    end
    return list
  end,
  accessAppWindow = function (name)
    return {
      move = function (self, pos) M.moved = M.moved or {}; M.moved[name] = pos; return self end,
      setVisible = function (self, v) M.shown = M.shown or {}; M.shown[name] = v ~= false; return self end,
      resize = function (self, size) M.resized = M.resized or {}; M.resized[name] = size; return self end,
    }
  end,
  onLapCompleted = function (_, cb) M.callbacks.lap = cb end,
  onSessionStart = function (cb) M.callbacks.session = cb end,
  onCarJumped = function (_, cb) M.callbacks.jump = cb end,
  onRelease = function (cb) M.callbacks.release = cb end,
  log = function () end,
  error = function (msg) print('ac.error: ' .. tostring(msg)) end,
  warn = function () end,
}

-- ui
ui = {
  Alignment = { Start = -1, Center = 0, End = 1 },
  ComboFlags = { None = 0 },
  ColorPickerFlags = { PickerHueBar = 0 },
  windowWidth = function () return M.windowW end,
  windowHeight = function () return M.windowH end,
  availableSpaceX = function () return 300 end,
  drawRectFilled = function (p1, p2, color)
    assert(p1.x == p1.x and p2.y == p2.y, 'NaN in rect')
    assert(color and color.mult, 'rect without colour')
    count('rect')
  end,
  setCursor = function () end,
  windowHovered = function () return M.hovered == true end,
  mouseClicked = function () return M.clicked == true end,
  pathLineTo = function (p)
    assert(p.x == p.x and p.y == p.y, 'NaN in path'); count('pathLineTo')
    if M.recordFills then M.path = M.path or {}; M.path[#M.path + 1] = p.x; M.path[#M.path + 1] = p.y end
  end,
  pathFillConvex = function (color)
    assert(color and color.mult, 'path without colour'); count('quad')
    if M.recordFills then
      M.fills = M.fills or {}
      M.fills[#M.fills + 1] = { pts = M.path or {}, r = color.r, g = color.g, b = color.b }
      M.path = nil
    end
  end,
  ExtraCanvas = function (size, mips, aa, format)
    assert(size and size.x > 0 and aa and format, 'canvas without size, antialiasing mode or format')
    local c = { exposure = 0 }
    function c:setExposure(v) self.exposure = v; M.canvasExposure = v; return self end
    function c:clear() return self end
    function c:update(cb) cb(0); return self end
    M.canvas = c
    return c
  end,
  drawImage = function (img, p1, p2, color, uv1, uv2)
    assert(img and p1 and p2 and color and color.mult, 'image without rect or colour')
    count('image')
    local m = M.lastImage or {}
    m[1], m[2], m[3], m[4] = p1.x, p1.y, p2.x, p2.y
    m[5], m[6], m[7], m[8] = uv1 and uv1.x or 0, uv1 and uv1.y or 0, uv2 and uv2.x or 1, uv2 and uv2.y or 1
    m.img = img
    M.lastImage = m
  end,
  beginTonemapping = function () M.tonemapDepth = (M.tonemapDepth or 0) + 1; count('tonemap') end,
  endTonemapping = function () M.tonemapDepth = (M.tonemapDepth or 0) - 1 end,
  setShadingOffset = function () end,
  resetShadingOffset = function () end,
  renderShader = function (params)
    assert(params.p1 and params.p2 and params.textures and params.shader, 'shader without rect, textures or code')
    count('shader')
    local m = M.lastShader or {}
    m[1], m[2], m[3], m[4] = params.p1.x, params.p1.y, params.p2.x, params.p2.y
    m[5], m[6], m[7], m[8] = params.uv1.x, params.uv1.y, params.uv2.x, params.uv2.y
    M.lastShader = m
    return true
  end,
  drawVirtualMirror = function (p1, p2, color)
    assert(p1 and p2 and color and color.mult, 'mirror without rect or colour')
    count('mirror')
    local m = M.lastMirror or {}
    m[1], m[2], m[3], m[4] = p1.x, p1.y, p2.x, p2.y
    M.lastMirror = m
    return M.mirrorAvailable ~= false
  end,
  pathStroke = function (color, closed, thickness)
    assert(color and color.mult, 'stroke without colour'); assert(thickness and thickness > 0, 'stroke thickness'); count('stroke')
  end,
  pathArcTo = function (c, r) assert(c.x == c.x and r > 0, 'bad arc'); count('arc') end,
  drawLine = function (p1, p2, color, thickness)
    assert(p1.x == p1.x and p2.y == p2.y, 'NaN in line'); assert(color and color.mult, 'line without colour'); count('line')
  end,
  drawRect = function (p1, p2, color) assert(color and color.mult, 'rect outline without colour'); count('rectOutline') end,
  drawCircleFilled = function (c, r, color) assert(c.x == c.x and r > 0 and color and color.mult, 'bad circle'); count('circle') end,
  pushClipRect = function (p1, p2) assert(p1.x <= p2.x and p1.y <= p2.y, 'clip rect inverted'); M.clipDepth = (M.clipDepth or 0) + 1 end,
  popClipRect = function () M.clipDepth = M.clipDepth - 1; assert(M.clipDepth >= 0, 'clip pop without push') end,
  dwriteTextAligned = function (str, size)
    assert(type(str) == 'string', 'text must be a string')
    assert(size > 0, 'font size must be positive')
    count('text')
    M.lastTexts = M.lastTexts or {}
    M.lastTexts[#M.lastTexts + 1] = str
  end,
  measureDWriteText = function (str, size) return vec2(#str * size * 0.5, size) end,
  pushDWriteFont = function () count('pushFont') end,
  popDWriteFont = function () count('popFont') end,
  checkbox = function () return false end,
  slider = function (_, v) return v end,
  combo = function (_, _, _, cb) cb() end,
  selectable = function () return false end,
  colorButton = function () end,
  itemEdited = function () return false end,
  button = function () return false end,
  text = function () end,
  textWrapped = function () end,
  header = function () end,
  offsetCursorY = function () end,
  sameLine = function () end,
  setNextItemWidth = function () end,
  tabBar = function (_, cb) cb() end,
  tabItem = function (_, cb) cb() end,
}

script = {}

return M
