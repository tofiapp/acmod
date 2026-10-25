-- Lifecycle and the LED frame loop. States: wait (no car yet) -> run | off (master switch) | noleds | failed.
-- A restart (session start, car change, method change, LED map change, "Znovu najít") gives every LED back, heals
-- what an earlier run left hidden, reads the car again and attaches the takeover.
-- Per frame in run: car_state.fill -> engine.step (scenarios of the car's preset) or a test pattern from the Diody tab
-- -> takeover.set for every LED (change-only). The lights module runs in every state but wait.

local config = require('src/config')
local store = require('src/store')
local carInfo = require('src/car_info')
local carState = require('src/car_state')
local detect = require('src/detect')
local takeover = require('src/takeover')
local color = require('src/color')
local presets = require('src/presets')
local engine = require('src/engine')
local lights = require('src/lights')
local rpm = require('src/rpm')

local S = config.S
local ST = carState.ST

local M = {
  rpm = rpm,
  state = 'wait', carId = '', info = nil, layout = nil, profile = { v = 1 },
  fb = {}, manual = {}, n = 0, hover = 0, hoverUntil = 0, healed = 0,
  clock = 0, version = 0, restartReason = 'start', lastRestart = '',
  presetId = 'builtin:f1', compiled = nil, compiledVersion = -1, ST = ST, lights = lights,
}

-- Test patterns of the Diody tab (0 = normal operation: the scenarios drive the LEDs).
M.MODES = { 'Původní stav', 'Duha', 'Běžící světlo', 'Vše zhasnout', 'Vše bílé', 'Ruční barvy' }
M.NORMAL, M.MANUAL = 0, 6
M.STATES = {
  wait = 'čekám na auto',
  run = 'běží',
  off = 'vypnuto hlavním vypínačem',
  noleds = 'auto nemá rozpoznané diody',
  failed = 'žádná metoda převzetí nefunguje',
}

local CHASE = 0x00C8FF

local function bump() M.version = M.version + 1 end

function M.restart(reason)
  M.restartReason = reason or 'restart'
end

local function saveProfile()
  if M.carId ~= '' then store.saveCar(M.carId, M.profile) end
end

-- ---------------------------------------------------------------- settings used by the window

function M.method()
  return M.profile.method or S.method
end

function M.setMethod(m)
  M.profile.method = m
  saveProfile()
  M.restart('method')
end

function M.setMode(mode)
  config.set('testMode', mode)
end

function M.setManual(i, p)
  if i < 1 or i > M.n then return end
  if S.testMode ~= M.MANUAL then
    -- start from what the LEDs show now, so editing one LED keeps the others
    for k = 1, M.n do M.manual[k] = M.fb[k] or color.ORIGINAL end
    config.set('testMode', M.MANUAL)
  end
  M.manual[i] = p
end

-- Brightness the LEDs use now: the manual value, or with automatic brightness between the night and the day value
-- by the time of day (day 8-17 h, night until 6 h and from 20 h, linear in between).
function M.effectiveIntensity()
  if not S.autoBrightness then return S.intensity end
  local h = ST.timeHours or 12
  local f
  if h >= 8 and h <= 17 then f = 1
  elseif h <= 6 or h >= 20 then f = 0
  elseif h < 8 then f = (h - 6) / 2
  else f = (20 - h) / 3 end
  return S.intensityNight + (S.intensityDay - S.intensityNight) * f
end

function M.setIntensity(v)
  config.set('intensity', v)
  takeover.setIntensity(M.effectiveIntensity())
end

-- key: 'autoBrightness' | 'intensityDay' | 'intensityNight' | 'colourGuard'
function M.setBrightness(key, v)
  config.set(key, v)
  if key == 'colourGuard' then takeover.invalidate() end
  takeover.setIntensity(M.effectiveIntensity())
end

-- The window marks an LED under the mouse; it blinks on the car while marked (the preview keeps its colour).
function M.markHover(i)
  M.hover, M.hoverUntil = i, M.clock + 0.15
end

function M.preset()
  return presets.get(M.presetId) or presets.BUILTIN[1]
end

function M.setPreset(id)
  if not presets.get(id) then return end
  M.presetId = id
  M.profile.preset = id
  saveProfile()
  M.compiledVersion = -1
  bump()
end

-- Nastavení changed the default preset: a car without its own choice follows it now.
function M.defaultPresetChanged()
  if M.profile.preset or not M.layout then return end
  M.presetId = presets.choose(nil, S.defaultPreset, M.layout, ST.drsPresent)
  M.compiledVersion = -1
  bump()
end

function M.cyclePreset()
  local all = presets.all()
  local at = 1
  for i = 1, #all do if all[i].id == M.presetId then at = i end end
  M.setPreset(all[at % #all + 1].id)
end

-- Preset edits from the Scénáře / Editor tabs: a built-in preset is copied first, the car switches to the copy.
local function follow(id)
  if id and id ~= M.presetId then M.setPreset(id) end
  M.compiledVersion = -1
  return id
end
function M.editScenario(scId, field, value) return follow(presets.setScenario(M.presetId, scId, field, value)) end
function M.moveScenario(scId, delta) return follow(presets.move(M.presetId, scId, delta)) end
function M.addCustom()
  local id, scId = presets.addCustom(M.presetId)
  follow(id)
  return scId
end
function M.removeScenario(scId) return follow(presets.removeScenario(M.presetId, scId)) end
function M.setBase(base) return follow(presets.setBase(M.presetId, base)) end

local compileIfNeeded

-- Button Test: the scenario shows for 5 s even when its condition does not hold (also right after an edit).
function M.testScenario(id, seconds)
  if M.layout and M.state == 'run' and S.testMode == M.NORMAL then compileIfNeeded() end
  if M.compiled then engine.test(M.compiled, id, seconds or 5, ST.t) end
end

-- Manual LED map (order and groups picked by the user); nil = automatic detection.
function M.setMap(map)
  M.profile.map = map
  saveProfile()
  M.restart('map')
end

-- ---------------------------------------------------------------- lifecycle

local function attach()
  takeover.attach(M.layout, M.method(), M.carId)
  M.state = takeover.method ~= 0 and 'run' or 'failed'
end

local function detectCar(car, id)
  M.carId = id
  M.healed = M.healed + takeover.heal(id)
  M.info = carInfo.read()
  M.profile = store.loadCar(id)
  carState.setCarInfo(M.info)
  M.layout = detect.run(car, M.info, M.profile.map)
  if M.layout.notReady then return false end
  local n = #M.layout.leds
  M.n = n
  for i = 1, detect.MAX_LEDS do
    M.fb[i] = color.ORIGINAL
    if i > n or M.manual[i] == nil then M.manual[i] = color.ORIGINAL end
  end
  carState.fill(0)
  rpm.init(M.profile, M.info, ST, saveProfile)
  M.presetId = presets.choose(M.profile.preset, S.defaultPreset, M.layout, ST.drsPresent)
  M.compiledVersion = -1
  lights.init(id, M.profile, M.layout, M.info)
  if n == 0 then M.state = 'noleds'
  elseif not S.master then M.state = 'off'
  else attach() end
  bump()
  return true
end

local floor = math.floor

local function fillTest(t, mode)
  local n, fb = M.n, M.fb
  if mode == 2 then
    local step = floor(t * 8) / 48
    for i = 1, n do fb[i] = color.hsv((i - 1) / n + step, 1, 1) end
  elseif mode == 3 then
    local pos = floor(t * 8) % n + 1
    for i = 1, n do fb[i] = i == pos and CHASE or color.OFF end
  elseif mode == 4 then
    for i = 1, n do fb[i] = color.OFF end
  elseif mode == 5 then
    for i = 1, n do fb[i] = color.WHITE end
  elseif mode == M.MANUAL then
    local manual = M.manual
    for i = 1, n do fb[i] = manual[i] end
  else
    for i = 1, n do fb[i] = color.ORIGINAL end
  end
end

function compileIfNeeded()
  local v = presets.version
  if M.compiled and M.compiledVersion == v and M.compiledRpm == rpm.version then return end
  M.compiledRpm = rpm.version
  local old = M.compiled
  M.compiled = engine.compile(M.preset(), M.layout, ST)
  M.compiledVersion = v
  -- a running Test survives an edit made meanwhile
  if old then
    for i = 1, #M.compiled.scen do
      local sc = M.compiled.scen[i]
      local o = engine.find(old, sc.id)
      if o and o.forceUntil > ST.t then sc.forceUntil, sc.since = o.forceUntil, o.since end
    end
  end
  bump()
end

local carCheck = 0
local waitTimer = 0
local lightsOn = false

local function stopLights()
  if lightsOn then lights.release(); lightsOn = false end
end
-- restarts that concern only the LEDs (same car): the lights module is re-initialised by lights.init, which keeps the
-- real controls it holds (no give-back + re-take of real lights other drivers see)
local KEEP_LIGHTS = { method = true, map = true, redetect = true }

function M.update(dt)
  M.clock = M.clock + dt
  if M.restartReason then
    takeover.dispose()
    if not KEEP_LIGHTS[M.restartReason] then stopLights() end
    M.lastRestart = M.restartReason
    M.restartReason = nil
    M.state = 'wait'
    waitTimer = 0
    bump()
  end
  if M.state == 'wait' then
    waitTimer = waitTimer - dt
    if waitTimer > 0 then return end
    waitTimer = 1          -- model not loaded yet: try again in a second
    local car = ac.getCar(0)
    local id = ac.getCarID(0)
    if car and id and id ~= '' and detectCar(car, id) then waitTimer = 0 end
    return
  end
  carCheck = carCheck + dt
  if carCheck >= 1 then
    carCheck = 0
    if ac.getCarID(0) ~= M.carId then M.restart('car'); return end
  end
  carState.fill(dt)
  rpm.update(ST, dt)
  if S.master then
    lights.update(dt, ST)
    lightsOn = true
  else
    stopLights()
  end
  if M.state == 'off' then
    if S.master then attach(); bump() end
    return
  end
  if M.state ~= 'run' then return end
  if not S.master then
    takeover.dispose()
    M.state = 'off'
    bump()
    return
  end
  local mode = S.testMode
  if mode == M.NORMAL then
    compileIfNeeded()
    engine.step(M.compiled, ST, M.fb)
  else
    fillTest(M.clock, mode)
  end
  takeover.setIntensity(M.effectiveIntensity())
  local fb, h = M.fb, M.hover
  if not (h > 0 and h <= M.n and M.clock < M.hoverUntil) then h = 0 end
  local blink = floor(M.clock * 6) % 2 == 0 and color.WHITE or color.OFF
  for i = 1, M.n do takeover.set(i, i == h and blink or fb[i]) end
  takeover.guard(dt)
end

-- Error boundary restorer and app unload: everything back to the car.
function M.halt()
  pcall(rpm.flush)
  pcall(takeover.dispose)
  pcall(lights.release)
  lightsOn = false
  M.state = 'wait'
end

-- Called once at load: user presets from disk; test patterns never survive a restart.
function M.init()
  presets.load()
  if S.testMode ~= M.NORMAL then config.set('testMode', M.NORMAL) end
end

return M
