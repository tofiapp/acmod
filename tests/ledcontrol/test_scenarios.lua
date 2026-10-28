-- LedControl phase 4: scenarios with per-group priority, built-in presets, custom conditions, copy-on-write user
-- presets, persistence, export / import, frame looks with rescaling, test button, hold timers, manual LED map,
-- no allocation in normal operation.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame = H.frame

local app
local function loadApp() app = H.loadApp(); return app end

-- colour seen on a formula LED (by slot left to right in the main row, or by name)
local function slotColour(slot) return env.seen(env.formula.hr[env.formula.slot[slot]]) end
local function nameColour(name) return env.seen(env.formula.hr[name]) end
local function lit(r, g, b) return r + g + b > 0.5 end
local function isGreen(r, g, b) return g > 20 and r < 1 end
local function isRed(r, g, b) return r > 20 and g < 1 end
local function isBlue(r, g, b) return b > 20 and r < 1 and g < 12 end

-- ---------------------------------------------------------------- F1 preset on the formula

H.formulaCar(1)
env.storage = {}
local car = env.car
car.speedKmh = 120
car.rpm = 8000
loadApp()
frame(5)
local rt = app.runtime
check(rt.state == 'run' and rt.presetId == 'builtin:f1', 'formula: auto preset F1 (' .. tostring(rt.presetId) .. ')')
check(app.config.S.testMode == 0, 'normal operation after load')

local anyLit = false
for slot = 1, 15 do if lit(slotColour(slot)) then anyLit = true end end
check(not anyLit, 'below the shift lights start: main row dark (base off) although AC lights it')

-- 55 % of the fill: 9 of 15 from the left (first LED at the start, full row one step before the shift point)
car.rpm = 8625 + 0.55 * 2875
frame(2)
local fillOk = true
for slot = 1, 15 do
  local r, g, b = slotColour(slot)
  if slot <= 5 and not isGreen(r, g, b) then fillOk = false end
  if slot >= 6 and slot <= 9 and not isRed(r, g, b) then fillOk = false end
  if slot >= 10 and lit(r, g, b) then fillOk = false end
end
check(fillOk, 'shift lights: 9 LEDs from the left, green then red')
check(rt.compiled.groups[1].activeName == 'Řadicí světla podle otáček', 'Diody tab shows the active scenario per group')
check(not lit(nameColour('FLAG_L1')), 'side LEDs dark when no side scenario is active')

car.rpm = 11600
frame(2)
local allBlue = true
for slot = 1, 15 do if not isBlue(slotColour(slot)) then allBlue = false end end
check(allBlue, 'shift point: whole row blue (F1)')

car.rpm = 13000
local on, off = false, false
for _ = 1, 30 do
  frame(1)
  if isBlue(slotColour(1)) then on = true elseif not lit(slotColour(1)) then off = true end
end
check(on and off, 'limiter: row blinks blue')

-- pit limiter beats the shift lights on every group
car.rpm = 10350
car.manualPitsSpeedLimiterEnabled = true
frame(2)
local swapped, orange = false, false
local first1, first2 = slotColour(1), slotColour(2)
for _ = 1, 30 do
  frame(1)
  local r1 = slotColour(1)
  local r2 = slotColour(2)
  if r1 > 20 and r2 < 1 then orange = true end
  if r1 ~= first1 then swapped = true end
end
check(orange and swapped, 'pit limiter: odd/even alternate orange')
local sideOrange = false
for _ = 1, 30 do frame(1); if nameColour('FLAG_L1') > 20 then sideOrange = true end end
check(sideOrange, 'pit limiter: side LEDs too (target all)')
car.manualPitsSpeedLimiterEnabled = false

-- blue flag on the side columns, RPM row keeps the shift lights
env.sim.raceFlagType = 12
local sideBlue = false
for _ = 1, 30 do frame(1); if isBlue(nameColour('FLAG_L1')) then sideBlue = true end end
check(sideBlue, 'blue flag: side LEDs blink blue')
check(isGreen(slotColour(1)) and isRed(slotColour(6)), 'blue flag: main row still shows the shift lights')
env.sim.raceFlagType = 0

-- hover blinks the LED on the car but leaves the frame buffer (and the preview / colour picker) alone
car.rpm = 8000
frame(2)
local fbBefore = rt.fb[1]
env.windowOpen = true
env.ui.hover = '##led1'
local blinked, fbSame = false, true
for _ = 1, 20 do
  frame(1)
  if rt.fb[1] ~= fbBefore then fbSame = false end
  if nameColour(rt.layout.leds[1].name) > 20 then blinked = true end
end
env.ui.hover = nil
env.windowOpen = false
check(blinked and fbSame, 'hover: LED blinks on the car, preview colour unchanged (picker fix)')

-- Test button forces a scenario for 5 s
rt.testScenario('flagYellow')
local yellow = false
for _ = 1, 30 do
  frame(1)
  local r, g = nameColour('FLAG_L1')
  if r > 20 and g > 15 then yellow = true end
end
check(yellow, 'Test: yellow flag shows without a flag')
frame(300)
check(not lit(nameColour('FLAG_L1')), 'Test: stops after 5 s')
rt.editScenario('flagWhite', 'on', false)
rt = app.runtime
frame(2)
rt.testScenario('flagWhite')
frame(3)
check(nameColour('FLAG_L1') > 20, 'Test: works for a switched-off scenario too')
env.sim.raceFlagType = 14
frame(400)
check(not lit(nameColour('FLAG_L1')), 'switched-off scenario stays dark when its condition holds')
env.sim.raceFlagType = 0
rt.setPreset('builtin:f1')
frame(2)

-- ABS hold timer
car.absInAction = true
frame(1)
car.absInAction = false
frame(5)
check(app.engine.find(rt.compiled, 'abs').active, 'ABS: still active right after the intervention (hold)')
frame(30)
check(not app.engine.find(rt.compiled, 'abs').active, 'ABS: off 0.3 s later')

-- start countdown fills from the edges, then green
env.sim.timeToSessionStart = 3500
frame(2)
local count = 0
for slot = 1, 15 do if isRed(slotColour(slot)) then count = count + 1 end end
check(count == 8 and isRed(slotColour(1)) and isRed(slotColour(15)) and not lit(slotColour(8)),
  'start countdown: half the time left = 4 LEDs from each edge (' .. count .. ')')
env.sim.timeToSessionStart = -500
local green = false
for _ = 1, 20 do frame(1); if isGreen(slotColour(8)) then green = true end end
check(green, 'start: green blink after the countdown')
env.sim.timeToSessionStart = -1e6

-- idle animation when standing
car.speedKmh = 0
car.rpm = 5000
frame(200)
check(app.engine.find(rt.compiled, 'idle').active, 'idle: active after 3 s standing')
car.speedKmh = 120

-- ---------------------------------------------------------------- built-in edited in place, custom condition, persistence

local scId = rt.addCustom()
check(rt.presetId == 'builtin:f1' and #app.presets.user == 0, 'editing a built-in preset keeps the car on it, no copy')
check(app.presets.isModified('builtin:f1'), 'the built-in is marked as changed')
rt.editScenario(scId, 'when', { { q = 'speed', op = '<', v = 60 }, { q = 'fuel', op = '<', v = 5 } })
rt.editScenario(scId, 'look', { p = 'solid', c = { '#FFFFFF' } })
rt.editScenario(scId, 'prio', 1)
car.speedKmh = 30
car.fuel = 50
frame(2)
check(not app.engine.find(rt.compiled, scId).active, 'custom: one row false = inactive')
car.fuel = 3
frame(2)
local white = true
for slot = 1, 15 do local r, g, b = slotColour(slot); if not (r > 20 and g > 20 and b > 20) then white = false end end
check(app.engine.find(rt.compiled, scId).active and white, 'custom: both rows true = row white (priority 1)')
car.fuel = 50
car.speedKmh = 120
rt.editScenario('shiftLights', 'param', 50)
local userId = rt.presetId

loadApp()
frame(3)
rt = app.runtime
check(rt.presetId == userId, 'preset choice saved per car')
local p = app.presets.get(userId)
local own = p and app.presets.ownOf(p) or {}
check(own[scId] and #own[scId].when == 2, 'custom scenario saved in the built-in')
check(own.shiftLights and own.shiftLights.param == 50, 'changed parameter saved')

-- ---------------------------------------------------------------- animations: one look, several presets
do
  local P = app.presets
  local function lookIn(presetId, id)
    local list = P.effective(P.get(presetId))
    for i = 1, #list do if list[i].id == id then return list[i].look, list[i] end end
  end
  rt.editScenario('shiftPoint', 'look', { p = 'blink', c = { '#00FF00', '#000000' }, hz = 3 })
  local a = P.animFor('builtin:f1', 'shiftPoint')
  check(a and a.look.p == 'blink' and P.animCount(a) == 1, 'a look edit makes an animation for this preset')
  check(lookIn('builtin:f1', 'shiftPoint').c[1] == '#00FF00', 'the preset shows the animation')
  check(lookIn('builtin:gt3', 'shiftPoint').c[1] == '#FF0000', 'other presets keep their own look')
  P.assign(a.id, 'builtin:gt3', true)
  check(lookIn('builtin:gt3', 'shiftPoint').c[1] == '#00FF00', 'ticked in GT3: GT3 shows the animation too')
  rt.editScenario('shiftPoint', 'look', { p = 'blink', c = { '#0000FF', '#000000' }, hz = 3 })
  check(lookIn('builtin:gt3', 'shiftPoint').c[1] == '#0000FF' and #P.animsOf('shiftPoint') == 1,
    'editing the animation changes every ticked preset, no second animation')
  local uid = P.create('builtin:gt3', 'Moje')
  check(P.animFor(uid, 'shiftPoint') == a, 'a copy of a preset uses the same animations')
  local b = P.splitAnim(a.id, uid)
  check(b and P.animFor(uid, 'shiftPoint') == b and not a.presets[uid] and a.presets['builtin:gt3'],
    'Jen pro tento preset: own copy, the others keep the original')
  P.assign(b.id, 'builtin:minimal', true)
  local _, e = lookIn('builtin:minimal', 'shiftPoint')
  check(e.on == true, 'ticking an animation switches the scenario on in that preset (Minimální has it off)')
  check(P.renameAnim(b.id, 'Zelené řazení') and b.name == 'Zelené řazení', 'rename')
  local text = P.export('builtin:gt3')
  check(text and text:find('#0000FF', 1, true), 'export carries the animation look')
  P.delete(uid)
  check(not b.presets[uid], 'a deleted preset is taken out of its animations')
  loadApp()
  frame(3)
  P = app.presets
  rt = app.runtime
  a = P.animFor('builtin:gt3', 'shiftPoint')
  check(a and a.look.c[1] == '#0000FF' and P.animFor('builtin:f1', 'shiftPoint') == a, 'animations saved and loaded')
  check(P.animFor('builtin:minimal', 'shiftPoint') and P.animFor('builtin:minimal', 'shiftPoint').name == 'Zelené řazení',
    'second animation saved with its name')
  P.resetBuiltin('builtin:gt3')
  check(not P.isModified('builtin:gt3') and lookIn('builtin:gt3', 'shiftPoint').c[1] == '#FF0000'
    and P.animFor('builtin:f1', 'shiftPoint') == a, 'Obnovit výchozí: GT3 back to its own look, F1 keeps the animation')
  P.deleteAnim(P.animFor('builtin:minimal', 'shiftPoint').id)
  check(P.animFor('builtin:minimal', 'shiftPoint') == nil, 'deleted animation: back to the preset look')
  P.resetBuiltin('builtin:minimal')
end

-- move a scenario up and down
local function indexOf(id)
  local list = app.presets.effective(rt.preset())
  for i = 1, #list do if list[i].id == id then return i end end
end
local before = indexOf('tc')
rt.moveScenario('tc', -1)
check(indexOf('tc') == before - 1, 'move up: one place higher')
rt.moveScenario('tc', 1)
check(indexOf('tc') == before, 'move down: back')

-- export / import
local text = app.presets.export(userId)
check(text and text:sub(1, 20) == 'LEDCONTROL-PRESET 1 ', 'export: one line with the prefix')
local newId = app.presets.import('něco před tím ' .. text)
check(newId and newId ~= userId, 'import: new preset id')
local a, b = app.presets.effective(app.presets.get(userId)), app.presets.effective(app.presets.get(newId))
local same = #a == #b
for i = 1, math.min(#a, #b) do
  if a[i].id ~= b[i].id or a[i].on ~= b[i].on or a[i].prio ~= b[i].prio or a[i].param ~= b[i].param then same = false end
end
check(same, 'import: same scenarios as the export')
check(app.presets.get(newId).name ~= app.presets.get(userId).name, 'import: name made unique')
local bad, why = app.presets.import('hello')
check(bad == nil and why and why:find('LEDCONTROL', 1, true), 'import: text without the prefix rejected with a reason')
bad, why = app.presets.import('LEDCONTROL-PRESET 1 {"name": ')
check(bad == nil and why ~= nil, 'import: broken JSON rejected')
local evil = app.presets.import('LEDCONTROL-PRESET 1 {"name":"x","scenarios":{"os.exit":{"on":true},"limiter":{"prio":"abc","look":{"p":"boom","c":["#zz"]}}}}')
local ep = app.presets.get(evil)
check(ep and ep.scenarios['os.exit'] == nil and ep.scenarios.limiter.look.p == 'solid', 'import: unknown keys and bad values dropped')

-- ---------------------------------------------------------------- frame looks

rt.editScenario('idle', 'look', { p = 'frames', fps = 2, palette = { '#FF0000' }, g = { { n = 3, f = { '1.1', '.1.' } } } })
rt.editScenario('idle', 'prio', 1)
car.speedKmh = 0
frame(200)
local framesOk = true
for slot = 1, 15 do
  local r = slotColour(slot)
  local want = (slot <= 5 or slot >= 11)
  if (r > 20) ~= want then framesOk = false end
end
local sawSecond = false
for _ = 1, 40 do
  frame(1)
  if slotColour(8) > 20 and slotColour(1) < 1 then sawSecond = true end
end
check(framesOk and sawSecond, 'frames: 3 cells rescaled to 15, both frames shown')
rt.editScenario('idle', 'look', { p = 'frames', fps = 2, rescale = false, palette = { '#FF0000' },
  g = { { n = 3, f = { '1.1' } } } })
frame(2)
check(#rt.compiled.warnings > 0, 'frames: without rescaling a layout mismatch is reported')
car.speedKmh = 120

-- ---------------------------------------------------------------- minimal preset: base = car's own logic

rt.setPreset('builtin:minimal')
car.rpm = 12000
frame(3)
local r, g = slotColour(1)
check(near(g, 30) and r < 1, 'minimal preset: the car lights its own RPM LEDs')
car.manualPitsSpeedLimiterEnabled = true
local orangeSeen = false
for _ = 1, 30 do frame(1); if slotColour(1) > 20 then orangeSeen = true end end
check(orangeSeen, 'minimal preset: pit limiter still shown')
car.manualPitsSpeedLimiterEnabled = false

-- hotkey cycles presets
local beforePreset = rt.presetId
env.hotkeys = { ['__APP_LEDCONTROL_NEXT_PRESET'] = true }
frame(1)
check(rt.presetId ~= beforePreset, 'hotkey: next preset')

-- ---------------------------------------------------------------- GT3: no side LEDs, flags on the main row

H.gt3Car(-1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 3000
loadApp()
frame(3)
rt = app.runtime
check(rt.presetId == 'builtin:gt3', 'gt3: auto preset GT3')
local function gtColour(k) return env.seen(rt.layout.leds[k].inst[1].ref[1]) end
-- 80 % start of shift point (97 % of limiter 13000 = 12610): half way -> 3 LEDs from each edge? 10 LEDs: half 5
env.car.rpm = 12610 * 0.8 + 0.5 * (12610 * 0.2)
frame(2)
local litCount = 0
for k = 1, 10 do if lit(gtColour(k)) then litCount = litCount + 1 end end
check(litCount == 6 and lit(gtColour(1)) and lit(gtColour(10)) and not lit(gtColour(5)),
  'gt3: fill from the edges (' .. litCount .. ' lit)')
-- just below the shift point the row is already full in the fill colours, the shift point blink comes after it
env.car.rpm = 12610 * 0.99
frame(2)
litCount = 0
for k = 1, 10 do if lit(gtColour(k)) then litCount = litCount + 1 end end
check(litCount == 10 and rt.compiled.groups[1].activeName == 'Řadicí světla podle otáček',
  'gt3: full row before the shift point (' .. litCount .. ' lit, ' .. tostring(rt.compiled.groups[1].activeName) .. ')')
env.sim.raceFlagType = 2
local yellowMain = false
for _ = 1, 30 do frame(1); local rr, gg = gtColour(5); if rr > 20 and gg > 15 then yellowMain = true end end
check(yellowMain, 'gt3: yellow flag falls back to the main row')
env.sim.raceFlagType = 0
local drs = app.engine.find(rt.compiled, 'drsActive')
check(drs and not drs.avail, 'gt3: DRS marked unavailable')
local red = app.engine.find(rt.compiled, 'flagRed')
check(red and not red.avail and red.note:find('nehlásí', 1, true), 'red flag marked as not reported by AC')

-- ---------------------------------------------------------------- manual LED map

H.formulaCar(1)
env.storage = {}
loadApp()
frame(3)
rt = app.runtime
rt.setMap({ leds = { { 'RPM_LED_5', 1 }, { 'RPM_LED_1', 1 }, { 'FLAG_L1', 2 } }, groups = { { 'Moje řada', 'main' }, { 'Bok', 'side' } } })
frame(3)
check(rt.layout.manual and rt.layout.signature == '2+1' and rt.layout.leds[1].name == 'RPM_LED_5', 'manual map: order and groups as picked')
check(rt.layout.groups[1].name == 'Moje řada' and rt.layout.groups[2].role == 'side', 'manual map: group names and roles')
rt.setMap(nil)
frame(3)
check(not rt.layout.manual and #rt.layout.leds == 21, 'manual map cleared: automatic detection again')
local list = app.detect.listMeshes(env.car, 50)
local hasLed = false
for _, m in ipairs(list) do if m.name == 'RPM_LED_1' then hasLed = true end end
check(#list > 0 and hasLed, 'mesh list for manual mapping')

-- ---------------------------------------------------------------- no allocation in normal operation

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
loadApp()
env.windowOpen = true
frame(60)
local k = 0
local function sweep()
  k = k + 1
  env.car.rpm = 8000 + (k % 120) * 45
  frame(1)
end
for _ = 1, 120 do sweep() end
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for _ = 1, 300 do sweep() end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
env.windowOpen = false
check(grown < 4, string.format('no per-frame allocation with scenarios and the window open (%.2f KB / 300 frames)', grown))

return H.finish('test_scenarios')
