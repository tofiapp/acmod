-- Shared helpers for the LedControl tests: check/near, test cars (scene + INI data + AC's LED driver), app loading,
-- frame loop and window clicks. Each test file does: local H = dofile(helpersPath)(appDir, tmpDir, mockPath)

return function (appDir, tmpDir, mockPath)
package.path = appDir .. '/?.lua;' .. package.path

local env = dofile(mockPath)
env.folder = tmpDir

-- ---------------------------------------------------------------- adapter sandbox
-- App modules see no CSP globals: only src/csp.lua (here replaced by the fake adapter) may hold them. Reading one
-- from any other module is recorded in H.direct and raises an error naming it.
local fakeAdapter = dofile(appDir .. '/../../../tests/ledcontrol/fake_csp.lua')
local HIDDEN = {}
for _, n in ipairs({ 'ac', 'ui', 'render', 'io', 'os', 'JSON', 'stringify', 'vec2', 'vec3', 'rgb', 'rgbm', 'mat4x4',
  'script', 'bit' }) do HIDDEN[n] = true end
local direct = {}
local appEnv = setmetatable({}, {
  __index = function (_, k)
    if HIDDEN[k] then
      direct[#direct + 1] = k
      error('LedControl module read the CSP global "' .. tostring(k) .. '" directly (use src/csp.lua)', 2)
    end
    return _G[k]
  end,
  __newindex = function (_, k, v) rawset(_G, k, v) end,
})
local function appSearcher(name)
  if type(name) ~= 'string' or not name:match('^src/') or name == 'src/csp' then return nil end
  local path = appDir .. '/' .. name .. '.lua'
  local f = io.open(path, 'r')
  if not f then return nil end
  f:close()
  local chunk, err = loadfile(path)
  if not chunk then error(err, 0) end
  setfenv(chunk, appEnv)
  return chunk
end
table.insert(package.loaders, 2, appSearcher)
local function loadEntry(path)
  local chunk = assert(loadfile(path))
  setfenv(chunk, appEnv)
  return chunk()
end

local H = { env = env, passed = 0, failed = 0 }
local function check(cond, msg)
  if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
H.check, H.near = check, near

local DT = 1 / 60
H.DT = DT

-- ---------------------------------------------------------------- cars

local function baseCar(sideX)
  env.car = {
    position = vec3(0, 0, 0), side = vec3(sideX, 0, 0), up = vec3(0, 1, 0), look = vec3(0, 0, 1),
    driverEyesPosition = vec3(0, 0.75, 0.25), rpm = 12000, steer = 0,
    speedKmh = 0, gear = 1, gas = 0, brake = 0, fuel = 50, rpmLimiter = 13000, rpmMinimum = 4000,
    manualPitsSpeedLimiterEnabled = false, isInPitlane = false, isInPit = false, isEngineLimiterOn = false,
    drsPresent = false, drsAvailable = false, drsActive = false, absInAction = false, tractionControlInAction = false,
    engineLifeLeft = 1000, lapCount = 0, racePosition = 1, headlightsActive = false, lowBeams = false,
    hazardLights = false, absModes = 3, tractionControlModes = 3, damage = { [0] = 0, 0, 0, 0 },
    wheels = { [0] = { position = vec3(0.8 * sideX, 0.3, 1.5) }, [1] = { position = vec3(-0.8 * sideX, 0.3, 1.5) } },
  }
  env.car.transform = env.newMat(0, 0, 0)
  env.sim = { cameraPosition = vec3(0, 0.75, 0.2), raceFlagType = 0, timeToSessionStart = -1e6, isSessionStarted = true,
    rainIntensity = 0, rainWetness = 0, timeHours = 14, isOnlineRace = false, isReplayActive = false, isPaused = false }
  env.root = env.node('carRoot:0', nil, 0, 0, 0)
  env.ini, env.cspConfig, env.acLeds = {}, {}, {}
end

local function acLed(name, rpm, r, g, b)
  local meshes = env.ref({ env.root }):findMeshes(name)
  local a = { rpm = rpm, r = r, g = g, b = b, meshes = {}, materials = {} }
  for i = 1, #meshes do a.meshes[i] = meshes[i]; a.materials[i] = meshes[i].material end
  env.acLeds[#env.acLeds + 1] = a
end

-- Formula: 15 RPM LEDs in a row (names not in position order), 3 + 3 flag LEDs in columns at the sides, hi-res and
-- low-res steering wheel plus LOD B (inactive), 3 materials shared by the RPM LEDs, plus bad candidates.
local FORMULA_ORDER = { 3, 1, 2, 5, 4, 6, 8, 7, 9, 10, 12, 11, 13, 15, 14 }   -- slot (left to right) -> LED number
local function formulaCar(sideX)
  baseCar(sideX)
  env.carId = 'test_formula'
  local cockpit = env.node('COCKPIT_HR', env.root, 0, 0.5, 0.3)
  local lodB = env.node('LOD_B', env.root, 0, 0.5, 0.3)
  lodB.active = false
  local wheels = { env.node('STEER_HR', cockpit, 0, 0.2, 0.1), env.node('STEER_LR', cockpit, 0, 0.2, 0.1),
    env.node('STEER_B', lodB, 0, 0.2, 0.1) }
  local mats = { env.material('led_green'), env.material('led_red'), env.material('led_blue') }
  local di = {}
  env.formula = { hr = {}, slot = {} }
  for slot = 1, 15 do
    local n = FORMULA_ORDER[slot]
    local name = 'RPM_LED_' .. n
    local x = (8 - slot) * 0.01 * sideX           -- slot 1 is the leftmost
    for w = 1, 3 do
      local m = env.mesh(name, wheels[w], { centre = { x, 0.05, 0 }, material = mats[math.floor((slot - 1) / 5) + 1],
        lod = w == 3 and 'B' or 'A' })
      if w == 1 then env.formula.hr[name] = m end
    end
    env.formula.slot[slot] = name
    di['LED_' .. (n - 1)] = { OBJECT_NAME = { name }, RPM_SWITCH = { tostring(9000 + 200 * n) }, EMISSIVE = { '0', '30', '0' } }
  end
  for k = 1, 3 do
    local l = env.mesh('FLAG_L' .. k, wheels[1], { centre = { 0.13 * sideX, 0.05 - 0.012 * k, 0 } })
    local r = env.mesh('FLAG_R' .. k, wheels[1], { centre = { -0.13 * sideX, 0.05 - 0.012 * k, 0 } })
    env.formula.hr[l.name], env.formula.hr[r.name] = l, r
    di['LED_' .. (14 + k)] = { OBJECT_NAME = { 'FLAG_L' .. k }, RPM_SWITCH = { '99999' } }
    di['LED_' .. (17 + k)] = { OBJECT_NAME = { 'FLAG_R' .. k }, RPM_SWITCH = { '99999' } }
  end
  env.mesh('RPM_BAR', wheels[1], { centre = { 0, 0.08, 0 }, radius = 0.2 })
  env.mesh('REAR_LED', env.root, { centre = { 0, 0.6, -3.2 } })
  di.LED_21 = { OBJECT_NAME = { 'RPM_BAR' } }
  di.LED_22 = { OBJECT_NAME = { 'REAR_LED' } }
  di.LED_23 = { OBJECT_NAME = { 'GHOST' } }
  env.ini['digital_instruments.ini'] = di
  env.ini['ai.ini'] = { GEARS = { UP = { '11500' } } }
  for n = 1, 15 do acLed('RPM_LED_' .. n, 9000 + 200 * n, 0, 30, 0) end
end

-- GT3: no digital instruments, CSP config RPM emissives, all LEDs share one material.
local function gt3Car(sideX)
  baseCar(sideX)
  env.carId = 'test_gt3'
  local wheel = env.node('STEER_HR', env.node('COCKPIT_HR', env.root, 0, 0.5, 0.3), 0, 0.2, 0.1)
  local mat = env.material('rpm_leds')
  for k = 0, 9 do env.mesh('GT_LED_' .. k, wheel, { centre = { (4.5 - k) * 0.012 * sideX, 0.04, 0 }, material = mat }) end
  env.cspConfig = {
    EMISSIVE_RPM_0 = { NAME = { 'GT_LED_0', 'GT_LED_1', 'GT_LED_2', 'GT_LED_3', 'GT_LED_4' }, INPUT = { 'RPM' }, INPUT_THRESHOLD = { '6000' } },
    EMISSIVE_RPM_1 = { NAME = { 'GT_LED_5', 'GT_LED_6', 'GT_LED_7', 'GT_LED_8', 'GT_LED_9' }, INPUT = { 'RPM' }, INPUT_THRESHOLD = { '7000' } },
    EMISSIVE_BRAKE = { NAME = { 'BRAKE' }, INPUT = { 'BRAKE' } },
    INSTRUMENTS = { ['@'] = { 'DashIndicator', 'Input = RPM' } },
  }
  for k = 0, 9 do acLed('GT_LED_' .. k, 6000, 30, 0, 0) end
end

-- Display car: the shift lights are drawn by a CSP scriptable display into the dash texture, no LED meshes.
-- Sections as in acc-lua-examples/cars/dash_display_8100 (MESHES, RESOLUTION, DISPLAY_POS, DISPLAY_SIZE, SCRIPT).
local function displayCar(sideX)
  baseCar(sideX or 1)
  env.carId = 'test_display'
  local dash = env.node('DASH', env.node('COCKPIT_HR', env.root, 0, 0.5, 0.3), 0, 0.1, 0.4)
  env.displayMesh = env.mesh('DISPLAY_SCREEN', dash, { centre = { 0, 0, 0 }, radius = 0.12,
    material = env.material('dash_screen') })
  env.cspConfig = {
    SCRIPTABLE_DISPLAY_0 = { MESHES = { 'DISPLAY_SCREEN' }, RESOLUTION = { '1024', '1024' }, DISPLAY_POS = { '112', '272' },
      DISPLAY_SIZE = { '800', '480' }, SCRIPT = { 'display.lua' } },
  }
end

-- Two displays (dash 800 x 480 and a small steering wheel screen 480 x 272) plus the GT3 LED row.
local function dualDisplayCar(sideX)
  gt3Car(sideX or 1)
  env.carId = 'test_dual_display'
  local cockpit = env.root.children[1]
  local dash = env.node('DASH', cockpit, 0, 0.1, 0.4)
  env.displayMesh = env.mesh('DASH_SCREEN', dash, { centre = { 0, 0, 0 }, radius = 0.12, material = env.material('dash_screen') })
  env.displayMesh2 = env.mesh('WHEEL_SCREEN', cockpit.children[1], { centre = { 0, -0.02, 0 }, radius = 0.05,
    material = env.material('wheel_screen') })
  env.cspConfig.SCRIPTABLE_DISPLAY_0 = { MESHES = { 'DASH_SCREEN' }, RESOLUTION = { '1024', '512' },
    DISPLAY_POS = { '0', '0' }, DISPLAY_SIZE = { '800', '480' }, SCRIPT = { 'dash.lua' } }
  env.cspConfig.SCRIPTABLE_DISPLAY_1 = { MESHES = { 'WHEEL_SCREEN' }, RESOLUTION = { '512', '512' },
    DISPLAY_POS = { '16', '120' }, DISPLAY_SIZE = { '480', '272' }, SCRIPT = { 'wheel.lua' } }
end

local function markedCar()
  baseCar(1)
  env.carId = 'test_marked'
  local wheel = env.node('STEER_HR', env.root, 0, 0.7, 0.4)
  for k = 1, 6 do env.mesh('IND_' .. k, wheel, { centre = { (3.5 - k) * 0.01, 0.05, 0 }, actsAsLED = true }) end
end

local function namedCar()
  baseCar(1)
  env.carId = 'test_named'
  local wheel = env.node('STEER_HR', env.root, 0, 0.7, 0.4)
  for k = 1, 5 do env.mesh('SHIFT_LIGHT_' .. k, wheel, { centre = { (3 - k) * 0.01, 0.05, 0 } }) end
  env.mesh('DOOR_HANDLE', wheel, { centre = { 0.5, 0, 0 } })
end

local function emptyCar()
  baseCar(1)
  env.carId = 'test_empty'
  env.mesh('BODY', env.node('BODY_NODE', env.root, 0, 0, 0), { centre = { 0, 0.5, 0 }, radius = 2 })
end

-- ---------------------------------------------------------------- app

local app
local function loadApp()
  for k in pairs(package.loaded) do
    if k:match('^src/') then package.loaded[k] = nil end
  end
  script = {}
  env.renderCallbacks = {}
  package.loaded['src/csp'] = fakeAdapter()     -- built now: a test may swap a global (stringify, ...) before loading
  loadEntry(appDir .. '/LedControl.lua')
  app = { runtime = require('src/runtime'), takeover = require('src/takeover'), config = require('src/config'),
    safety = require('src/safety'), detect = require('src/detect'), presets = require('src/presets'),
    engine = require('src/engine'), carState = require('src/car_state') }
  if env.startMode then app.runtime.setMode(env.startMode); env.startMode = nil end
  return app
end

local function frame(n)
  for _ = 1, n or 1 do
    env.frameNo = env.frameNo + 1
    env.clock = env.clock + DT
    env.acStep()
    if env.jammer then env.jammer.step('before') end
    script.update(DT)
    script.frameBegin(DT)
    if env.jammer then env.jammer.step('after') end
    local cb = env.renderCallbacks['main.root.transparent']
    if cb then cb() end
    if env.windowOpen then script.windowMain(DT) end
  end
end

local function click(label)
  env.windowOpen = true
  env.ui.click = label
  frame(1)
  env.ui.click = nil
end

local function seenOf(name)
  return env.seen(env.formula.hr[name])
end

local function mode(m)
  app.runtime.setMode(m)
  frame(2)
end


H.baseCar, H.acLed, H.formulaCar, H.gt3Car, H.markedCar, H.namedCar, H.emptyCar =
  baseCar, acLed, formulaCar, gt3Car, markedCar, namedCar, emptyCar
H.displayCar, H.dualDisplayCar = displayCar, dualDisplayCar
H.FORMULA_ORDER = FORMULA_ORDER
H.loadApp = function () loadApp(); H.app = app; return app end
H.direct = direct            -- CSP globals an app module read directly (must stay empty)

-- ---------------------------------------------------------------- what the driver sees

local function chainActive(o)
  local p = o.parent
  while p do
    if p.active == false then return false end
    p = p.parent
  end
  return true
end
H.chainActive = chainActive

-- Colour the driver sees on layout LED i (r, g, b, how): the instance on an active node chain (current LOD) decides.
function H.seenLed(i)
  local led = app.runtime.layout.leds[i]
  for k = 1, #led.inst do
    local mesh = led.inst[k].ref[1]
    if chainActive(mesh) then return env.seen(mesh) end
  end
  return 0, 0, 0, 'inactive'      -- no instance on an active node chain: the LED is not drawn at all
end

-- true when LED i shows the colour the app wants (fb): off when it wants off, else the same hue (channels compared
-- after scaling to the brightest one; tolerance 0.2). A doubled LED (original and copy both visible) never matches.
function H.ledMatches(i)
  local p = app.runtime.fb[i]
  local r, g, b, how = H.seenLed(i)
  if how == 'double' then return false, 'original and copy both visible' end
  if how == 'inactive' then return true end
  if p == nil or p < 0 then return true end           -- the car's own logic: nothing to compare
  local er, eg, eb = math.floor(p / 65536) % 256, math.floor(p / 256) % 256, p % 256
  local em, sm = math.max(er, eg, eb), math.max(r, g, b)
  if em == 0 then return sm < 0.05, string.format('wants off, shows %.1f %.1f %.1f', r, g, b) end
  if sm <= 0 then return false, 'wants a colour, shows off' end
  local ok = math.abs(er / em - r / sm) < 0.2 and math.abs(eg / em - g / sm) < 0.2 and math.abs(eb / em - b / sm) < 0.2
  return ok, string.format('wants #%06X, shows %.1f %.1f %.1f (%s)', p, r, g, b, tostring(how))
end
H.frame, H.click, H.seenOf, H.mode = frame, click, seenOf, mode

function H.finish(name)
  check(#direct == 0, 'no app module called the CSP API directly (' .. table.concat(direct, ', ') .. ')')
  print(string.format('%s: %d passed, %d failed', name, H.passed, H.failed))
  LC_PASSED = H.passed            -- read by run_tests.py for the summary
  return H.failed
end

return H
end
