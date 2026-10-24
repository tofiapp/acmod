-- LedControl tests: LED detection from every source, order and groups, the three takeover methods against an AC
-- that rewrites the LEDs every frame, restore on every exit path, self-heal, error boundary, no per-frame allocation.
-- Run with tests/ledcontrol/run_tests.py (LuaJIT via the "lupa" Python package).

local appDir, tmpDir, mockPath = ...
package.path = appDir .. '/?.lua;' .. package.path

local env = dofile(mockPath)
env.folder = tmpDir

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

local DT = 1 / 60

-- ---------------------------------------------------------------- cars

local function baseCar(sideX)
  env.car = {
    position = vec3(0, 0, 0), side = vec3(sideX, 0, 0), up = vec3(0, 1, 0), look = vec3(0, 0, 1),
    driverEyesPosition = vec3(0, 0.75, 0.25), rpm = 12000, steer = 0,
    wheels = { [0] = { position = vec3(0.8 * sideX, 0.3, 1.5) }, [1] = { position = vec3(-0.8 * sideX, 0.3, 1.5) } },
  }
  env.car.transform = env.newMat(0, 0, 0)
  env.sim = { cameraPosition = vec3(0, 0.75, 0.2) }
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
  dofile(appDir .. '/LedControl.lua')
  app = { runtime = require('src/runtime'), takeover = require('src/takeover'), config = require('src/config'),
    safety = require('src/safety'), detect = require('src/detect') }
  return app
end

local function frame(n)
  for _ = 1, n or 1 do
    env.frameNo = env.frameNo + 1
    env.clock = env.clock + DT
    env.acStep()
    script.update(DT)
    script.frameBegin(DT)
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

-- ---------------------------------------------------------------- 1. formula, shadow copies

formulaCar(1)
env.storage = {}
loadApp()
frame(3)
local rt, tk = app.runtime, app.takeover
check(rt.state == 'run', 'formula: running (state ' .. tostring(rt.state) .. ')')
check(tk.method == 1, 'formula: shadow method by default')
local lay = rt.layout
check(#lay.leds == 21, 'formula: 21 LEDs (got ' .. #lay.leds .. ')')
check(lay.signature == '15+3+3', 'formula: groups 15+3+3 (got ' .. lay.signature .. ')')
check(lay.source == 'digital_instruments', 'formula: source digital_instruments')
check(lay.groups[1].role == 'main' and lay.groups[2].name == 'Levé' and lay.groups[3].name == 'Pravé',
  'formula: main row, left and right columns')
local orderOk = true
for slot = 1, 15 do if lay.leds[lay.groups[1].leds[slot]].name ~= env.formula.slot[slot] then orderOk = false end end
check(orderOk, 'formula: main row ordered left to right by position, not by name')
check(lay.groups[2].vertical and lay.leds[lay.groups[2].leds[1]].name == 'FLAG_L1', 'formula: side column top to bottom')
local rej = {}
for _, r in ipairs(lay.rejected) do rej[r.name] = r.reason end
check(rej.RPM_BAR and rej.RPM_BAR:find('velký'), 'formula: big mesh rejected')
check(rej.REAR_LED and rej.REAR_LED:find('daleko'), 'formula: far mesh rejected')
check(rej.GHOST and rej.GHOST:find('nalezen'), 'formula: missing mesh rejected')
check(#lay.leds[1].inst == 3 and lay.leds[1].inst[1].lodA and lay.leds[1].inst[1].visible,
  'formula: 3 instances per RPM LED, LOD A visible first')
check(lay.leds[1].rpm ~= nil, 'formula: RPM_SWITCH read from digital_instruments')
check(rt.info.shiftUp == 11500, 'formula: ai.ini shift point read')

-- original mode: nothing taken, AC's colours shown
mode(1)
local r, g, b, st = seenOf('RPM_LED_1')
check(near(g, 30) and st == 'ok', 'original mode: AC lights the LED')
check(tk.stats.copies == 15 * 3 + 6, 'shadow: one copy per instance (' .. tk.stats.copies .. ')')

-- all white wins over AC every frame, nothing shown twice
mode(5)
frame(30)
local allWhite, double = true, false
for name in pairs(env.formula.hr) do
  local rr, gg, bb, s = seenOf(name)
  if not (near(rr, 25) and near(gg, 25) and near(bb, 25)) then allWhite = false end
  if s ~= 'ok' then double = true end
end
check(allWhite, 'shadow: all LEDs white although AC writes them every frame')
check(not double, 'shadow: original hidden while the copy shows')
check(app.config.S.hiddenGuard:find('RPM_LED_1', 1, true) ~= nil, 'shadow: self-heal marker written before hiding')
local writes = tk.stats.writes
frame(20)
check(tk.stats.writes == writes, 'shadow: no writes while nothing changes')

-- chase: exactly one LED lit
mode(3)
local oneLit = true
for _ = 1, 20 do
  frame(1)
  local lit = 0
  for name in pairs(env.formula.hr) do
    local rr, gg, bb = seenOf(name)
    if rr + gg + bb > 0 then lit = lit + 1 end
  end
  if lit ~= 1 then oneLit = false end
end
check(oneLit, 'chase: exactly one LED lit at a time')

-- manual colour of one LED; neighbours sharing its material keep AC's colour
mode(1)
local idx3 = nil
for i, led in ipairs(lay.leds) do if led.name == 'RPM_LED_3' then idx3 = i end end
env.ui.pick = { ['##led' .. idx3] = { 1, 0, 0 } }
click('nothing')
env.ui.pick = nil
frame(2)
r, g, b = seenOf('RPM_LED_3')
check(near(r, 25) and near(g, 0), 'manual: picked LED red')
r, g, b, st = seenOf('RPM_LED_1')
check(near(g, 30) and near(r, 0) and st == 'ok', 'manual: LED sharing the material keeps AC colour')
check(app.config.S.testMode == rt.MANUAL, 'manual: picking a colour switches to manual mode')

-- hover blinks the LED on the car
env.ui.hover = '##led1'
local saw = { on = false, off = false }
for _ = 1, 30 do
  frame(1)
  local rr = seenOf(lay.leds[1].name)
  if rr > 1 then saw.on = true else saw.off = true end
end
env.ui.hover = nil
env.windowOpen = false
check(saw.on and saw.off, 'hover: LED blinks on the car')

-- master off: everything back
app.config.set('master', false)
frame(2)
local restored = true
for name, m in pairs(env.formula.hr) do
  if not m.visible then restored = false end
  local _, _, _, s = env.seen(m)
  if s ~= 'ok' then restored = false end
end
r, g = seenOf('RPM_LED_1')
check(restored and near(g, 30), 'master off: originals visible, AC colours back')
check(app.config.S.hiddenGuard == '', 'master off: self-heal marker cleared')
check(rt.state == 'off', 'master off: state off')
app.config.set('master', true)
mode(5)
check(rt.state == 'run' and near(seenOf('RPM_LED_1'), 25), 'master on again: running')

-- hotkey toggles the master switch
env.hotkeyPressed = true
frame(2)
check(app.config.S.master == false and rt.state == 'off', 'hotkey: master off')
env.hotkeyPressed = true
frame(2)
check(app.config.S.master == true, 'hotkey: master on')

-- brightness
env.windowOpen = true
env.ui.slide = { ['##intensity'] = 50 }
frame(1)
env.ui.slide = nil
frame(2)
check(near(seenOf('RPM_LED_1'), 50), 'brightness slider rewrites the LEDs')
app.runtime.setIntensity(25)

-- diagnostics
click('Kopírovat diagnostiku')
check(env.clipboard and env.clipboard:find('[LED_0]', 1, true) and env.clipboard:find('RPM_SWITCH', 1, true),
  'diagnostics: raw [LED_n] keys copied')
check(env.clipboard:find('RPM_BAR', 1, true) ~= nil, 'diagnostics: rejected candidates listed')
env.windowOpen = false

-- ---------------------------------------------------------------- 2. self-heal after a crash

mode(5)
check(not env.formula.hr.RPM_LED_1.visible, 'crash setup: original hidden')
env.reloadScene()                       -- CSP drops our copies, the hidden originals stay hidden
env.storage.lc_testMode = 1             -- next run starts in original mode, so nothing is hidden again
loadApp()
frame(3)
check(env.formula.hr.RPM_LED_1.visible and app.runtime.healed > 0, 'self-heal: originals visible after reload')
check(near(select(2, seenOf('RPM_LED_1')), 30), 'self-heal: AC colours back')

-- ---------------------------------------------------------------- 3. error boundary

mode(3)
env.failSetMaterial = true
frame(10)
env.failSetMaterial = false
check(app.safety.halted and app.safety.error ~= nil, 'error: halted with the message kept')
local allBack = true
for _, m in pairs(env.formula.hr) do if not m.visible then allBack = false end end
check(allBack, 'error: originals visible again')
env.windowOpen = true
click('Zkusit znovu')
frame(3)
check(not app.safety.halted and app.runtime.state == 'run', 'error: retry runs again')
env.windowOpen = false

-- ac.onRelease
mode(5)
env.callbacks.release()
check(env.formula.hr.RPM_LED_1.visible and app.config.S.hiddenGuard == '', 'release: originals visible, marker cleared')

-- ---------------------------------------------------------------- 4. redraw

formulaCar(1)
env.storage = { lc_testMode = 5 }
loadApp()
frame(2)
env.windowOpen = true
click('B – překreslení')
env.windowOpen = false
frame(3)
rt, tk = app.runtime, app.takeover
check(tk.method == 2, 'redraw: method B active')
r, g, b, st = seenOf('RPM_LED_1')
check(st == 'drawn' and near(r, 1) and near(g, 1), 'redraw: LED drawn white over AC')
check(env.formula.hr.RPM_LED_1.visible, 'redraw: scene untouched')
local profile = require('src/store').loadCar('test_formula')
check(profile.method == 2, 'redraw: method saved per car')
mode(1)
r, g, b, st = seenOf('RPM_LED_1')
check(st == 'ok' and near(g, 30), 'redraw: original mode draws nothing')
mode(5)
env.meshFails = true
frame(3)
env.meshFails = false
frame(3)
check(tk.method == 3 and tk.fallback ~= nil, 'redraw: draw failure falls back to direct')

-- ---------------------------------------------------------------- 5. direct

formulaCar(1)
env.storage = { lc_testMode = 5, lc_method = 3 }
require('src/store').deleteCar('test_formula')
loadApp()
frame(3)
rt, tk = app.runtime, app.takeover
check(tk.method == 3, 'direct: method C active')
check(tk.stats.split and tk.stats.materialsAfter > tk.stats.materialsBefore, 'direct: shared materials split')
frame(90)
check(tk.stats.fights > 0 and tk.fightMode, 'direct: AC writing back detected')
check(near(seenOf('RPM_LED_1'), 25), 'direct: colour re-asserted before rendering')
mode(1)
check(near(select(2, seenOf('RPM_LED_1')), 30), 'direct: original mode gives the LED back to AC')

formulaCar(1)
env.acWrites = 'material'
env.storage = { lc_testMode = 5, lc_method = 3 }
loadApp()
frame(90)
check(app.takeover.stats.fights == 0 and near(seenOf('RPM_LED_1'), 25), 'direct: no fight when AC keeps its old material')
env.acWrites = 'mesh'

-- ---------------------------------------------------------------- 6. fallback when copies cannot be made

formulaCar(1)
env.createMeshFails = true
env.storage = { lc_testMode = 5 }
loadApp()
frame(3)
env.createMeshFails = false
check(app.takeover.method == 2 and app.takeover.fallback and app.takeover.fallback:find('createMesh', 1, true),
  'fallback: no copies -> redraw with the reason')

-- ---------------------------------------------------------------- 7. other cars and sources

gt3Car(-1)
env.storage = { lc_testMode = 5 }
loadApp()
frame(3)
lay = app.runtime.layout
check(lay.source == 'csp_rpm' and #lay.leds == 10 and lay.signature == '10', 'gt3: 10 LEDs from CSP config')
local gtOrder = true
for i = 1, 10 do if lay.leds[i].name ~= 'GT_LED_' .. (i - 1) then gtOrder = false end end
check(gtOrder, 'gt3: order left to right with the side axis pointing right')
check(#app.runtime.info.generators == 1, 'gt3: generator lines dumped')
local gtWhite = true
for i = 1, 10 do
  local m = lay.leds[i].inst[1].ref[1]
  if not near(env.seen(m), 25) then gtWhite = false end
end
check(gtWhite, 'gt3: one shared material, every LED its own colour')
mode(3)
local gtOne = true
for _ = 1, 10 do
  frame(1)
  local lit = 0
  for i = 1, 10 do
    local rr, gg, bb = env.seen(lay.leds[i].inst[1].ref[1])
    if rr + gg + bb > 0 then lit = lit + 1 end
  end
  if lit ~= 1 then gtOne = false end
end
check(gtOne, 'gt3: chase lights one LED although all share a material')

markedCar()
env.storage = {}
loadApp()
frame(3)
check(app.runtime.layout.source == 'acts_as_led' and #app.runtime.layout.leds == 6, 'marked: 6 LEDs from actsAsLED')

namedCar()
env.storage = {}
loadApp()
frame(3)
check(app.runtime.layout.source == 'names' and #app.runtime.layout.leds == 5, 'named: 5 LEDs from mesh names')

emptyCar()
env.storage = {}
loadApp()
frame(3)
check(app.runtime.state == 'noleds', 'empty: no LEDs state')
env.windowOpen = true
env.ui.record = true
env.ui.texts = {}
frame(1)
env.ui.record = false
env.windowOpen = false
local said = false
for _, t in ipairs(env.ui.texts) do if t:find('nenašel', 1, true) then said = true end end
check(said, 'empty: the window says no LEDs were found')

-- model not loaded yet: waits and retries
baseCar(1)
env.carId = 'test_late'
local lateRoot = env.root
env.root = nil
env.storage = {}
loadApp()
frame(5)
check(app.runtime.state == 'wait', 'late model: still waiting')
env.root = lateRoot
env.mesh('SHIFT_LED_1', env.node('STEER_HR', lateRoot, 0, 0.7, 0.4), { centre = { 0, 0.05, 0 } })
frame(70)
check(app.runtime.state == 'run', 'late model: detected once loaded')

-- session start re-detects
formulaCar(1)
env.storage = { lc_testMode = 5 }
loadApp()
frame(3)
env.callbacks.session()
frame(3)
check(app.runtime.lastRestart == 'session' and app.runtime.state == 'run', 'session start: detected again')

-- ---------------------------------------------------------------- 8. no allocation per frame

formulaCar(1)
env.storage = { lc_testMode = 2 }
loadApp()
env.windowOpen = true
frame(120)
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local before = collectgarbage('count')
frame(300)
local grown = collectgarbage('count') - before
collectgarbage('restart')
jit.on()
env.windowOpen = false
check(grown < 4, string.format('no per-frame allocation in update + render + window (%.2f KB over 300 frames)', grown))

-- ---------------------------------------------------------------- 9. all files load

print(string.format('%d passed, %d failed', passed, failed))
return failed
