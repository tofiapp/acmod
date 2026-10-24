-- Minimal stand-in for the CSP API used by the KeyDrive Gamepad FX script and its render module.
-- M.load(core, file) installs fresh globals and runs a script, returning its `script` table.

local M = {}

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local vec2mt = {}
vec2mt.__index = vec2mt
function vec2mt:set(x, y) self.x, self.y = x, y; return self end

local function newIni(data)
  local o = { data = data or {} }
  function o:get(section, key, default)
    local s = self.data[section]
    local v = s and s[key]
    if v == nil then return default end
    if type(default) == 'boolean' then return v == true or v == 1 or v == '1' end
    if type(default) == 'number' then return tonumber(v) or default end
    return v
  end
  function o:mapSection(section, defaults)
    local r = {}
    for k, v in pairs(defaults) do r[k] = self:get(section, k, v) end
    return r
  end
  return o
end

function M.reset()
  M.keys = {}               -- VK code -> true while held
  M.controls = { KEYBOARD = { GAS = 38, BRAKE = 40, LEFT = 37, RIGHT = 39 } }
  M.settings = {}
  M.connected = {}
  M.callbacks = { jumped = {}, controls = {} }
  M.joypad = { gas = 0, brake = 0, steer = 0, clutch = 1, handbrake = 0, steerStickX = 0, gForces = vec() }
  local wheels = {}
  for i = 0, 3 do
    wheels[i] = {
      angularSpeed = 0, tyreRadius = 0.32, load = 3000,
      position = vec(i % 2 == 0 and 0.78 or -0.78, 0.3, i < 2 and 1.3 or -1.3),
    }
  end
  M.car = {
    index = 0, isAIControlled = false, physicsAvailable = true, speedKmh = 0, gas = 0, brake = 0,
    localVelocity = vec(), localAngularVelocity = vec(), gear = 1, rpm = 900, tractionType = 0, wheels = wheels,
  }
  M.renderModules = {}
  M.calls = {}
end

local function count(name) M.calls[name] = (M.calls[name] or 0) + 1 end

function M.install(core)
  package.path = core .. '/?.lua;' .. package.path
  for k in pairs(package.loaded) do
    if k:sub(1, 4) == 'src/' then package.loaded[k] = nil end
  end

  math.clamp = function (x, a, b) if x < a then return a elseif x > b then return b end return x end

  vec2 = function (x, y) return setmetatable({ x = x or 0, y = y or 0 }, vec2mt) end
  rgbm = function (r, g, b, m) return { r = r, g = g, b = b, mult = m } end

  car = M.car
  sim = { isPaused = false }
  __carIndex = 0
  script = {}

  ac = {
    FolderID = { Cfg = 'cfg' },
    getFolder = function () return 'cfg' end,
    INIConfig = {
      load = function (path)
        if path:find('controls.ini', 1, true) then return newIni(M.controls) end
        return newIni({})
      end,
      scriptSettings = function () return newIni(M.settings) end,
    },
    isKeyDown = function (k) return M.keys[k] == true end,
    getJoypadState = function () return M.joypad end,
    onCarJumped = function (_, cb) table.insert(M.callbacks.jumped, cb) end,
    onControlSettingsChanged = function (cb) table.insert(M.callbacks.controls, cb) end,
    loadRenderThreadModule = function (name) table.insert(M.renderModules, name) end,
    getCar = function () return M.car end,
    setDrawUIActive = function (v) M.drawUIActive = v end,
    StructItem = {
      key = function (k) return { __key = k } end,
      int32 = function () return 0 end,
      double = function () return 0 end,
      boolean = function () return false end,
    },
  }
  ac.connect = function (layout)
    local key = layout[1] and layout[1].__key or '?'
    local s = M.connected[key]
    if not s then
      s = {}
      for k, v in pairs(layout) do if type(k) == 'string' then s[k] = v end end
      M.connected[key] = s
    end
    return s
  end

  ui = {
    Font = { Small = 1 },
    windowHeight = function () return 1080 end,
    drawRectFilled = function () count('drawRectFilled') end,
    setCursor = function () end,
    text = function () count('text') end,
    textColored = function () count('text') end,
    pushFont = function () end,
    popFont = function () end,
  }
end

-- Runs `file` from the core folder in a fresh environment and returns its `script` table.
function M.load(core, file)
  M.install(core)
  local chunk = assert(loadfile(core .. '/' .. file))
  chunk()
  return script
end

function M.jump()
  for _, cb in ipairs(M.callbacks.jumped) do cb() end
end

return M
