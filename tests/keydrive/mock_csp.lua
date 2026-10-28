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
  M.callbacks = { jumped = {}, controls = {}, release = {} }
  M.storage = {}
  M.override = nil          -- table returned by ac.overrideCarControls (created on the first call)
  M.overrideCalls = 0
  M.noCombineAxis = false   -- true: the override struct has no combineAxis field (CSP older than preview125)
  M.click = {}              -- button label -> true: ui.button returns true once
  M.texts = {}              -- texts drawn by the last window call
  M.joypad = { gas = 0, brake = 0, steer = 0, clutch = 1, handbrake = 0, steerStickX = 0, gForces = vec(),
    steerLock = 270, steerRatio = 18 }
  local wheels = {}
  for i = 0, 3 do
    wheels[i] = {
      angularSpeed = 0, tyreRadius = 0.32, load = 3000, ndSlip = 0, slipRatio = 0, slipAngle = 0,
      look = vec(0, 0, 1), velocity = vec(),
      position = vec(i % 2 == 0 and 0.78 or -0.78, 0.3, i < 2 and 1.3 or -1.3),
    }
  end
  M.car = {
    index = 0, isAIControlled = false, physicsAvailable = true, speedKmh = 0, gas = 0, brake = 0,
    localVelocity = vec(), localAngularVelocity = vec(), gear = 1, rpm = 900, tractionType = 0, wheels = wheels,
    acceleration = vec(), collisionDepth = 0, wheelsOutside = 0, steer = 0, absMode = 0,
    isUserControlled = true, steerLock = 270,
    look = vec(0, 0, 1), side = vec(1, 0, 0),
  }
  M.saved = {}
  M.renderModules = {}
  M.calls = {}
  M.messages = {}
end

local function count(name) M.calls[name] = (M.calls[name] or 0) + 1 end

function M.install(core)
  package.path = core .. '/?.lua;' .. package.path
  for k in pairs(package.loaded) do
    if k:sub(1, 4) == 'src/' or k:sub(1, 5) == 'core/' then package.loaded[k] = nil end
  end

  math.clamp = function (x, a, b) if x < a then return a elseif x > b then return b end return x end

  vec2 = function (x, y) return setmetatable({ x = x or 0, y = y or 0 }, vec2mt) end
  rgbm = function (r, g, b, m) return { r = r, g = g, b = b, mult = m } end

  car = M.car
  sim = { isPaused = false, isReplayActive = false, frame = 0 }
  __carIndex = 0
  __dirname = 'KD'
  io.save = function (path, data) M.saved[path] = data; return true end
  io.createDir = function () return true end
  script = {}

  ac = {
    FolderID = { Cfg = 'cfg', Logs = 'logs' },
    getSim = function () return sim end,
    storage = function (defaults, prefix)
      local t = {}
      for k, v in pairs(defaults) do
        local saved = M.storage[(prefix or '') .. k]
        if saved == nil then t[k] = v else t[k] = saved end
      end
      return setmetatable({}, {
        __index = t,
        __newindex = function (_, k, v) t[k] = v; M.storage[(prefix or '') .. k] = v end,
      })
    end,
    overrideCarControls = function ()
      M.overrideCalls = M.overrideCalls + 1
      if not M.override then
        local fields = { gas = 0, brake = 0, steer = 0, clutch = 0, handbrake = 0, kers = 0, mguhMode = 0,
          requestedGearIndex = 0, combineAxis = true }
        local o = { fields = fields }
        function o.active() return true end
        M.override = setmetatable(o, {
          __index = fields,
          __newindex = function (_, k, v)
            if fields[k] == nil or (k == 'combineAxis' and M.noCombineAxis) then error('no member ' .. k) end
            fields[k] = v
          end,
        })
      end
      return M.override
    end,
    CarControlsInput = { Flag = { Skip = -1, Disable = 0, Enable = 1 } },
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
    getCarID = function () return 'test_car' end,
    setDrawUIActive = function (v) M.drawUIActive = v end,
    setMessage = function (title, text) M.messages[#M.messages + 1] = text end,
    onRelease = function (cb) table.insert(M.callbacks.release, cb) end,
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
    windowWidth = function () return 1920 end,
    drawRectFilled = function () count('drawRectFilled') end,
    setCursor = function () end,
    text = function (t) count('text'); M.texts[#M.texts + 1] = t end,
    textColored = function (t) count('text'); M.texts[#M.texts + 1] = t end,
    button = function (label) local c = M.click[label]; M.click[label] = nil; return c == true end,
    sameLine = function () end,
    separator = function () end,
    slider = function (_, value) return value end,
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

function M.release()
  for _, cb in ipairs(M.callbacks.release) do cb() end
end

function M.jump()
  for _, cb in ipairs(M.callbacks.jumped) do cb() end
end

return M
