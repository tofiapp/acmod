-- LedControl tests: LED detection from every source, order and groups, the three takeover methods against an AC
-- that rewrites the LEDs every frame, restore on every exit path, self-heal, error boundary, no per-frame allocation.
-- Run with tests/ledcontrol/run_tests.py (LuaJIT via the "lupa" Python package).

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near, DT = H.env, H.check, H.near, H.DT
local frame, click, seenOf, mode = H.frame, H.click, H.seenOf, H.mode
local formulaCar, gt3Car, markedCar, namedCar, emptyCar, baseCar =
  H.formulaCar, H.gt3Car, H.markedCar, H.namedCar, H.emptyCar, H.baseCar
local app
local function loadApp() app = H.loadApp(); return app end

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
env.startMode = 1                       -- next run starts in original mode, so nothing is hidden again
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
env.storage = {}; env.startMode = 5
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
env.storage = { lc_method = 3 }; env.startMode = 5
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
env.storage = { lc_method = 3 }; env.startMode = 5
loadApp()
frame(90)
check(app.takeover.stats.fights == 0 and near(seenOf('RPM_LED_1'), 25), 'direct: no fight when AC keeps its old material')
env.acWrites = 'mesh'

-- ---------------------------------------------------------------- 6. fallback when copies cannot be made

formulaCar(1)
env.createMeshFails = true
env.storage = {}; env.startMode = 5
loadApp()
frame(3)
env.createMeshFails = false
check(app.takeover.method == 2 and app.takeover.fallback and app.takeover.fallback:find('createMesh', 1, true),
  'fallback: no copies -> redraw with the reason')

-- ---------------------------------------------------------------- 7. other cars and sources

gt3Car(-1)
env.storage = {}; env.startMode = 5
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
env.storage = {}; env.startMode = 5
loadApp()
frame(3)
env.callbacks.session()
frame(3)
check(app.runtime.lastRestart == 'session' and app.runtime.state == 'run', 'session start: detected again')

-- ---------------------------------------------------------------- 8. no allocation per frame

formulaCar(1)
env.storage = {}; env.startMode = 2
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

return H.finish('test_ledcontrol')
