-- Minimal stand-in for the CSP Lua API, enough to run MirrorDelta outside the game.
-- Only what the app uses is mocked; drawing calls are counted, not rendered.

local M = { clock = 0, calls = {}, callbacks = {}, storage = {}, windowW = 600, windowH = 80 }

local function count(name)
  M.calls[name] = (M.calls[name] or 0) + 1
end

-- vec2
local vec2mt = {}
vec2mt.__index = vec2mt
function vec2mt:set(x, y) self.x, self.y = x, y; return self end
vec2 = setmetatable({}, { __call = function (_, x, y) return setmetatable({ x = x or 0, y = y or 0 }, vec2mt) end })

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
  wheels = {},
}
for i = 0, 3 do
  M.car.wheels[i] = {
    tyreCoreTemperature = 80 + i, tyreInsideTemperature = 90, tyreMiddleTemperature = 85,
    tyreOutsideTemperature = 78, tyreOptimumTemperature = 88, tyreWear = 0.1, isBlown = false,
  }
end
M.sim = { isReplayActive = false, isPaused = false, carsCount = 12, currentSessionIndex = 0, damageDisplayerShown = true, raceFlagType = 0 }
M.cars = {}                   -- other cars by index (1..); missing ones are nil like unused slots
M.session = { laps = 15, isTimedRace = false, type = 3 }

ac = {
  FolderID = { ScriptConfig = 1 },
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
  pathLineTo = function (p) assert(p.x == p.x and p.y == p.y, 'NaN in path'); count('pathLineTo') end,
  pathFillConvex = function (color) assert(color and color.mult, 'path without colour'); count('quad') end,
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
