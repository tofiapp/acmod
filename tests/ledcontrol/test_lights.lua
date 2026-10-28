-- LedControl lights (tab Světla): detection of what the car has, real controls with confirmation, minimum interval
-- and driver override, restore on scenario end / master off / error boundary / session restart, rain light in both
-- modes, brake light copies, backlight (cabin light source + dash meshes), flash on the hotkey, priorities, Test,
-- self-heal of hidden meshes, online banner and block, persistence, no allocation with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame = H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions (this file only)

-- CSP flag filter for brake lights ('{ actsAsBrakeLights:yes & lod:A }', Radar.lua)
local refmt = getmetatable(env.ref({})).__index
local baseFind = refmt.findMeshes
local function walk(obj, fn)
  if obj.kind == 'mesh' then fn(obj) return end
  for i = 1, #obj.children do walk(obj.children[i], fn) end
end
function refmt:findMeshes(filter)
  if type(filter) == 'string' and filter:find('actsAsBrakeLights:yes', 1, true) then
    local lodA = filter:find('lod:A', 1, true) ~= nil
    local out, seenM = {}, {}
    for i = 1, #self do
      walk(self[i], function (m)
        if not seenM[m] and not m.disposed and m.actsAsBrakeLights and (not lodA or m.lod == 'A') then
          seenM[m] = true
          out[#out + 1] = m
        end
      end)
    end
    return env.ref(out)
  end
  return baseFind(self, filter)
end

-- AC's light controls: commands are logged and take effect in the next frame (as AC applies them in its update)
-- lag: frames until AC shows a command (0 = the next frame)
local A = { queue = {}, due = {}, qn = 0, lag = 0, log = {}, flashes = {}, flashFrames = 0, ignore = {}, made = 0,
  alive = 0, last = nil }
local function queue(f) A.qn = A.qn + 1; A.queue[A.qn] = f; A.due[A.qn] = env.frameNo + 1 + A.lag end
local function logCmd(name, value) A.log[#A.log + 1] = { name = name, value = value, t = env.clock } end
ac.setHeadlights = function (on)
  logCmd('headlights', on)
  queue(function () env.car.headlightsActive = on end)
end
ac.setHighBeams = function (on)
  logCmd('highBeams', on)
  queue(function () env.car.lowBeams = not on end)
end
ac.TurningLights = { None = 0, Left = 1, Right = 2, Hazards = 3 }
ac.setTurningLights = function (v)
  logCmd('turn', v)
  queue(function ()
    local c = env.car
    c.hazardLights, c.turningLeftOnly, c.turningRightOnly = v == 3, v == 1, v == 2
  end)
end
ac.isExtraSwitchAvailable = function (i) return env.extras ~= nil and env.extras[i] ~= nil end
ac.getExtraSwitchName = function (i) return env.extras and env.extras[i] and env.extras[i].name or nil end
ac.accessExtraSwitchParams = function (i) return env.extras and env.extras[i] and env.extras[i].params or nil end
ac.simulateCustomHotkeyPress = function (id)
  logCmd(id, true)
  queue(function ()
    local L = id:match('^__EXT_LIGHT_(%u)$')
    if L and not A.ignore[L] then env.car['extra' .. L] = not env.car['extra' .. L] end
  end)
end
local controlsT = { headlightsFlash = false }
ac.overrideCarControls = function () return controlsT end
ac.LightType = { Regular = 1 }
ac.LightSource = function (t)
  A.made, A.alive = A.made + 1, A.alive + 1
  local l = { lightType = t, position = vec3(), color = rgb(), range = 0, disposed = false }
  l.dispose = function (self)
    if not self.disposed then self.disposed = true; A.alive = A.alive - 1 end
  end
  A.last = l
  return l
end
ac.INIConfig.onlineExtras = function () return env.onlineExtras end

local baseStep = env.acStep
env.acStep = function ()
  local q, due, keep = A.queue, A.due, 0
  for i = 1, A.qn do
    if due[i] <= env.frameNo then q[i]()
    else keep = keep + 1; q[keep], due[keep] = q[i], due[i] end
  end
  for i = keep + 1, A.qn do q[i], due[i] = nil, nil end
  A.qn = keep
  if controlsT.headlightsFlash then
    controlsT.headlightsFlash = false
    A.flashes[#A.flashes + 1] = env.clock
    A.flashFrames = 8
  end
  if A.flashFrames > 0 then A.flashFrames = A.flashFrames - 1 end
  env.car.flashingLightsActive = A.flashFrames > 0
  -- AC lights the brake light meshes while braking
  local lit = env.car.brake > 0.05
  for i = 1, #(env.brakeMats or {}) do
    local e = env.brakeMats[i].ksEmissive
    e.r, e.g, e.b = lit and 30 or 0, 0, 0
  end
  baseStep()
end

-- remembers the colour object each colour button edits (to see that the tab keeps it between frames)
local baseColorButton = ui.colorButton
U.colourSeen = {}
ui.colorButton = function (label, c, flags, size)
  U.colourSeen[label] = c
  return baseColorButton(label, c, flags, size)
end

-- icon buttons (Výš / Níž) are recorded by their id, so a test can see which arrows are drawn
local baseIconButton = ui.iconButton
ui.iconButton = function (...)
  local id = U.idStack and U.idStack[#U.idStack]
  if U.record and id then U.texts[#U.texts + 1] = 'icon:' .. tostring(id) end
  return baseIconButton(...)
end

-- sliders are recorded by their label too (to see which parameters a row shows)
local baseSlider = ui.slider
ui.slider = function (label, ...)
  if U.record then U.texts[#U.texts + 1] = label end
  return baseSlider(label, ...)
end

ui.inputText = function (label, str)
  U.last = label
  local v = U.input and U.input[label]
  if v ~= nil then U.input[label] = nil; return v, true end
  return str, false
end

-- ---------------------------------------------------------------- test car

local function lightCar(opts)
  opts = opts or {}
  local c = env.car
  c.headlightsActive, c.lowBeams, c.hazardLights = false, true, false
  c.hasLowBeams = opts.lowBeams ~= false
  c.hasFlashingLights = opts.flash ~= false
  c.hasTurningLights = opts.turning ~= false
  c.headlightsAreHeadlights = opts.headlights ~= false
  c.flashingLightsActive, c.brakeLightsActive, c.turningLeftOnly, c.turningRightOnly = false, false, false, false
  for _, L in ipairs({ 'A', 'B', 'C', 'D', 'E', 'F' }) do c['extra' .. L] = false end
  env.extras = opts.extras or { [2] = { name = 'Rain light', params = { holdMode = false } },
    [4] = { name = 'Horn light', params = { holdMode = true } } }
  local body = env.node('BODY', env.root, 0, 0.6, -2)
  env.brakeMats = {}
  if opts.brake ~= false then
    for k, x in ipairs({ 0.6, -0.6 }) do
      local mat = env.material('brake_' .. k)
      local m = env.mesh(k == 1 and 'BRAKE_L' or 'BRAKE_R', body, { centre = { x, 0, -0.1 }, radius = 0.15, material = mat })
      m.actsAsBrakeLights = true
      env.brakeMats[k] = mat
      env['brake' .. k] = m
    end
  end
  env.rainMesh = env.mesh('RAIN_LIGHT', body, { centre = { 0, 0.2, -0.2 }, radius = 0.05 })
  env.dashMesh = env.mesh('DASH_GLOW', env.node('DASH', env.root, 0, 0.6, 0.5), { centre = { 0, 0, 0 }, radius = 0.12 })
  env.sim.timeHours = 14
end

local app, L, rt
-- crash = true: the script starts again without ac.onRelease (CSP calls it on a normal reload)
local function loadApp(crash)
  if app and not crash and env.callbacks.release then env.callbacks.release() end
  app = H.loadApp()
  L = require('src/lights')
  rt = app.runtime
  return app
end

local function count(name, from)
  local n = 0
  for i = from or 1, #A.log do if A.log[i].name == name then n = n + 1 end end
  return n
end
local function lastOf(name)
  for i = #A.log, 1, -1 do if A.log[i].name == name then return A.log[i] end end
  return nil
end
local function minGap(name, from)
  local prev, gap = nil, math.huge
  for i = from or 1, #A.log do
    local e = A.log[i]
    if e.name == name then
      if prev then gap = math.min(gap, e.t - prev) end
      prev = e.t
    end
  end
  return gap
end
local function itemOf(id)
  for i = 1, #L.items do if L.items[i].id == id then return L.items[i] end end
  return nil
end
local function seconds(s) frame(math.floor(s * 60 + 0.5)) end
local function texts(fn)
  U.record, U.texts = true, {}
  fn()
  U.record = false
  return U.texts
end
local function hasText(list, needle)
  for i = 1, #list do if type(list[i]) == 'string' and list[i]:find(needle, 1, true) then return true end end
  return false
end
local function drawTab()
  env.windowOpen = true
  U.tab = 'Světla'
  frame(1)
end
local function clickTab(label)
  U.tab = 'Světla'
  H.click(label)
  env.windowOpen = false
end

-- ---------------------------------------------------------------- detection

H.formulaCar(1)
env.storage = {}
lightCar()
env.car.speedKmh = 120
env.car.rpm = 8000
loadApp()
frame(5)

check(L.available and L.carId == 'test_formula', 'lights: initialised for the car')
local ids = {}
for i = 1, #L.items do ids[L.items[i].id] = true end
check(ids.headlights and ids.highBeams and ids.flash and ids.hazards and ids.extra3 and ids.extra5 and ids.brake
  and ids.backlight, 'items: headlights, high beams, flash, hazards, extra switches, brake lights, backlight')
check(not ids.extra1 and not ids.extra2, 'items: only the extra switches the car has')
check(#L.brakeNames == 2, 'brake light meshes found by actsAsBrakeLights (' .. #L.brakeNames .. ')')
check(L.rainMode == 'switch' and L.rainSource and L.rainSource.key == 'C', 'rain light: automatic = switch C (Rain light)')
local hold = nil
for _, e in ipairs(L.rainSources) do if e.key == 'E' then hold = e end end
check(hold and not hold.usable and hold.note:find('držení', 1, true), 'hold-mode switch not usable for the rain light')
check(itemOf('extra5').note ~= nil, 'switch notes shown (hold mode)')
check(L.brakeThreshold:find('setBrakingLightsThreshold', 1, true) ~= nil, 'brake light threshold API probed')

-- ---------------------------------------------------------------- rain light, switch mode, with the pit limiter

local car = env.car
local mark = #A.log + 1
car.manualPitsSpeedLimiterEnabled = true
local sawOn, sawOff = false, false
for _ = 1, 120 do
  frame(1)
  if car.extraC then sawOn = true else sawOff = true end
end
local toggles = count('__EXT_LIGHT_C', mark)
check(sawOn and sawOff and toggles >= 6 and toggles <= 10, 'rain switch blinks with the limiter (' .. toggles .. ' toggles in 2 s)')
check(minGap('__EXT_LIGHT_C', mark) >= L.MIN_INTERVAL - 1e-6, string.format('rain switch: commands at least 0.25 s apart (%.3f)',
  minGap('__EXT_LIGHT_C', mark)))
check(itemOf('extra3').holder == L.byId.rainPit.holderText, 'tab item shows which scenario holds the switch')
car.manualPitsSpeedLimiterEnabled = false
seconds(1)
check(car.extraC == false and not L.CH.extra[3].held, 'limiter off: rain switch back off (as before)')
local after = #A.log
seconds(1)
check(#A.log == after, 'no commands while nothing changes')

-- the driver had the rain light on before: it stays on afterwards
car.extraC = true
frame(2)
car.manualPitsSpeedLimiterEnabled = true
seconds(1.5)
car.manualPitsSpeedLimiterEnabled = false
seconds(1)
check(car.extraC == true, 'rain switch restored to on (the driver had it on)')
car.extraC = false
frame(2)

-- AC ignores the switch: a few tries, then the scenario lets go with a reason
A.ignore.C = true
mark = #A.log + 1
car.manualPitsSpeedLimiterEnabled = true
seconds(3)
local tries = count('__EXT_LIGHT_C', mark)
check(tries == 3 and L.CH.extra[3].failed ~= nil, 'switch without effect: 3 tries, then marked (' .. tries .. ')')
check(itemOf('extra3').holder == L.TEXT.noEffect, 'tab shows that AC did not react')
car.manualPitsSpeedLimiterEnabled = false
A.ignore.C = nil
seconds(1)

-- ---------------------------------------------------------------- headlights at dusk, driver override

mark = #A.log + 1
env.sim.timeHours = 20
frame(5)
check(car.headlightsActive and count('headlights', mark) == 1, 'dusk: headlights on with one command')
car.headlightsActive = false                -- the driver switches them off by hand
seconds(1)
check(not car.headlightsActive and count('headlights', mark) == 1, 'driver override: the scenario does not turn them back on')
check(L.CH.headlights.yielded and itemOf('headlights').holder == L.TEXT.yielded, 'driver override shown in the tab')
env.sim.timeHours = 14
seconds(21)
check(not L.CH.headlights.held and count('headlights', mark) == 1, 'scenario ended: the driver\'s choice stays, no command')
env.sim.timeHours = 21
frame(5)
check(car.headlightsActive and count('headlights', mark) == 2, 'scenario again: takes the lights again')
env.sim.timeHours = 14
seconds(10)
check(car.headlightsActive, 'dusk: lights stay during the 20 s hold')
seconds(11)
check(not car.headlightsActive and lastOf('headlights').value == false, 'dusk over: lights back off')
env.sim.rainIntensity = 0.5
frame(5)
check(car.headlightsActive, 'rain: headlights on')
env.sim.rainIntensity = 0
seconds(21)
check(not car.headlightsActive, 'rain over: back off')

-- ---------------------------------------------------------------- hazards when stopped on track

car.turningLeftOnly = true                  -- the driver has the left indicator on
mark = #A.log + 1
car.speedKmh = 0
seconds(2)
check(not car.hazardLights, 'hazards: not before the stop time')
seconds(1.5)
check(car.hazardLights and count('turn', mark) == 1, 'hazards: on after 3 s standing on track')
car.speedKmh = 40
seconds(2)
check(not car.hazardLights and car.turningLeftOnly and lastOf('turn').value == 1, 'hazards: off again, left indicator restored')
car.speedKmh = 0
car.isInPitlane = true
mark = #A.log + 1
seconds(4)
check(not car.hazardLights and count('turn', mark) == 0, 'hazards: not in the pit lane')
car.isInPitlane = false
car.speedKmh = 120
car.turningLeftOnly = false
frame(2)

-- ---------------------------------------------------------------- brake lights blink under hard braking

car.brake = 1
local lit, dark, hidden = false, false, true
for _ = 1, 40 do
  frame(1)
  local r, _, _, st = env.seen(env.brake1)
  if r > 20 then lit = true elseif r < 1 then dark = true end
  if env.brake1.visible then hidden = false end
end
check(lit and dark and hidden, 'brake blink: copy blinks with the original\'s lit colour, original hidden')
check(env.storage['lcl_meshGuard']:find('BRAKE_L', 1, true) ~= nil, 'self-heal marker written before hiding')
car.brake = 0
seconds(1)
local r1, _, _, st1 = env.seen(env.brake1)
check(env.brake1.visible and st1 == 'ok' and r1 < 1, 'brake blink over: the car\'s own brake light again')
car.speedKmh = 30
car.brake = 1
seconds(0.5)
check(env.brake1.visible, 'brake blink: not below the speed threshold')
car.brake = 0
car.speedKmh = 120
frame(2)

-- ---------------------------------------------------------------- backlight: cabin light + dash meshes

check(A.alive == 0, 'backlight: no light source while the headlights are off (only with lights)')
car.headlightsActive = true
frame(3)
check(A.alive == 1 and A.last.color.b > A.last.color.r, 'backlight: cabin light created in the scenario colour')
local p = A.last.position
check(near(p.x, 0, 1e-6) and near(p.y, 0.5, 1e-6) and near(p.z, 0.7, 1e-6), 'cabin light placed relative to the eyes')
-- pick a dash mesh in the tab
U.tab = 'Světla'
H.click('Vybrat…##pick_dash')
local list = texts(function () env.windowOpen = true; frame(1) end)
local dashLabel = nil
for _, t in ipairs(list) do if type(t) == 'string' and t:find('^DASH_GLOW  %(') then dashLabel = t end end
check(dashLabel ~= nil, 'mesh picker lists the car\'s meshes')
U.input = { ['Filtr##flt_dash'] = 'dash' }
local filtered = texts(function () frame(1) end)
local onlyDash = true
for _, t in ipairs(filtered) do if type(t) == 'string' and t:find('##lm', 1, true) and not t:find('DASH', 1, true) then onlyDash = false end end
check(onlyDash, 'mesh picker filter')
if dashLabel then H.click(dashLabel) end
frame(3)
local dr, dg, db = env.seen(env.dashMesh)
check(#L.carSettings().dash.meshes == 1 and not env.dashMesh.visible and db > dr and db > 0.5,
  'dash mesh recoloured by the backlight (copy shown, original hidden)')
H.click('Hotovo##pick_dash')
env.windowOpen = false
car.headlightsActive = false
seconds(3)
check(A.alive == 0 and env.dashMesh.visible, 'backlight over: light source disposed, dash mesh back')
-- the pit limiter scenario has to be switched on; above the normal backlight it wins
L.setOn('backlightPit', true)
car.headlightsActive = true
frame(2)
local blue = A.last.color.b
car.manualPitsSpeedLimiterEnabled = true
frame(2)
check(A.last.color.r > A.last.color.b and blue > 0, 'backlight priority: orange with the pit limiter')
car.manualPitsSpeedLimiterEnabled = false
car.headlightsActive = false
L.setOn('backlightPit', false)
seconds(3)

-- ---------------------------------------------------------------- flash on the hotkey

mark = #A.flashes + 1
env.hotkeys = { ['__APP_LEDCONTROL_FLASH'] = true }
seconds(2)
local n = #A.flashes - mark + 1
local gapOk = true
for i = mark + 1, #A.flashes do if A.flashes[i] - A.flashes[i - 1] < 0.25 then gapOk = false end end
check(n == 2 and gapOk, 'flash hotkey: two flashes at least 0.25 s apart (' .. n .. ')')
L.setOn('flash', false)
env.hotkeys = { ['__APP_LEDCONTROL_FLASH'] = true }
seconds(1)
check(#A.flashes - mark + 1 == 2, 'flash hotkey ignored while the scenario is off')
L.setOn('flash', true)

-- ---------------------------------------------------------------- priorities on one output, Test button

L.setOn('rainWet', true)
env.sim.rainIntensity = 0.5
car.manualPitsSpeedLimiterEnabled = true
frame(3)
check(L.OUT.rain.winner == L.byId.rainPit, 'rain output: the limiter blink wins (higher priority)')
L.move('rainWet', -1)
frame(3)
check(L.OUT.rain.winner == L.byId.rainWet and L.order[1].id == 'rainWet', 'moved up: rain light solid wins')
mark = #A.log + 1
seconds(1)
check(car.extraC and count('__EXT_LIGHT_C', mark) == 0, 'solid rain light: no toggling')
L.move('rainWet', 1)
frame(2)
check(L.OUT.rain.winner == L.byId.rainPit, 'moved back: the limiter blink wins again')
L.test('rainWet')
frame(2)
check(L.OUT.rain.winner == L.byId.rainWet, 'Test: the tested scenario wins on its light even below another active one')
seconds(5.5)
check(L.OUT.rain.winner == L.byId.rainPit, 'Test over: priority order again')
car.manualPitsSpeedLimiterEnabled = false
env.sim.rainIntensity = 0
L.setOn('rainWet', false)
seconds(12)
check(not car.extraC, 'rain over: switch off again')

-- Test in the tab: hazards for 5 s while driving
mark = #A.log + 1
clickTab('Test##lt_hazardStop')
frame(3)
check(car.hazardLights and L.testing('hazardStop'), 'Test: hazards on while driving')
seconds(5)
check(not car.hazardLights and count('turn', mark) == 2, 'Test: hazards back off after 5 s')

-- tab controls: on/off checkbox, priority arrows (inside one light), name that expands, slider
clickTab('##lon_hazardStop')
check(not L.byId.hazardStop.on, 'tab: scenario switched off')
clickTab('##lon_hazardStop')
check(L.byId.hazardStop.on, 'tab: scenario switched on again')
local arrows = texts(drawTab)
env.windowOpen = false
check(not hasText(arrows, 'icon:lup_hazardStop') and not hasText(arrows, 'icon:ldn_hazardStop')
  and hasText(arrows, 'icon:ldn_rainPit') and not hasText(arrows, 'icon:lup_rainPit') and hasText(arrows, 'icon:lup_rainWet'),
  'tab: Výš / Níž only between the scenarios of one light')
check(L.byId.rainWet.prio > L.byId.rainPit.prio, 'setup: rain blink above the solid rain light')
clickTab('lup_rainWet')
check(L.byId.rainWet.prio < L.byId.rainPit.prio, 'tab: priority up')
clickTab('ldn_rainWet')
check(L.byId.rainWet.prio > L.byId.rainPit.prio, 'tab: priority down')
local closed = texts(drawTab)
env.windowOpen = false
check(not hasText(closed, '##lp_hazardStop_stop'), 'tab: parameters hidden until the name is clicked')
clickTab('Při zastavení na trati##lx_hazardStop')
U.slide = { ['##lp_hazardStop_stop'] = 5 }
clickTab('nic')
U.slide = nil
check(L.byId.hazardStop.P.stop == 5, 'tab: parameter slider')
clickTab('Na klávesu##lx_flash')
local opened = texts(drawTab)
env.windowOpen = false
check(not hasText(opened, '##lp_hazardStop_stop') and hasText(opened, '##lp_flash_count'), 'tab: one scenario expanded at a time')
U.slide = { ['##lp_flash_count'] = 2.4 }
clickTab('nic')
U.slide = nil
check(L.byId.flash.P.count == 2, 'tab: whole-number parameter rounded (' .. L.byId.flash.P.count .. ')')

-- colour button of a scenario: the picked colour stays as picked (no snapping to black or white between frames,
-- no re-quantising of the picker's own value) and reaches the cabin light
local color = require('src/color')
car.headlightsActive = true
frame(3)
clickTab('Palubní deska a kabina##lx_backlight')
U.pick = { ['##lc_backlight'] = { 0.33, 0.9, 0.25 } }
clickTab('nic')
U.pick = nil
local picked = L.byId.backlight.colour
env.windowOpen = true
U.tab = 'Světla'
frame(10)
env.windowOpen = false
local cb = U.colourSeen['##lc_backlight']
check(picked == color.pack(0.33, 0.9, 0.25) and L.byId.backlight.colour == picked, 'colour button: picked colour stored')
check(cb and near(cb.r, 0.33) and near(cb.g, 0.9) and near(cb.b, 0.25), 'colour button keeps the picked value between frames')
check(A.alive == 1 and A.last.color.g > A.last.color.r and A.last.color.g > A.last.color.b, 'cabin light in the picked colour')
L.setColour('backlight', '#2A5CFF')
car.headlightsActive = false
seconds(3)

-- ---------------------------------------------------------------- rain light, mesh mode

clickTab('Meshe##rm_mesh')
frame(2)
check(L.rainMode == 'mesh' and L.carSettings().rain.meshes[1] == 'RAIN_LIGHT', 'mesh mode: prefilled with the detected rain mesh')
mark = #A.log + 1
car.manualPitsSpeedLimiterEnabled = true
local on, off2 = false, false
for _ = 1, 60 do
  frame(1)
  local r = env.seen(env.rainMesh)
  if r > 20 then on = true elseif r < 1 then off2 = true end
end
check(on and off2 and not env.rainMesh.visible, 'mesh mode: copy of the rain light blinks red')
check(count('__EXT_LIGHT_C', mark) == 0, 'mesh mode: the real switch is not touched')
car.manualPitsSpeedLimiterEnabled = false
seconds(0.5)
check(env.rainMesh.visible, 'mesh mode: limiter off, original back')

-- persistence: car settings in the profile, scenario settings in the lights storage
loadApp()
frame(3)
check(L.carSettings().rain.mode == 'mesh' and L.carSettings().dash.meshes[1] == 'DASH_GLOW', 'per car: rain mode and dash meshes saved')
check(L.byId.hazardStop.P.stop == 5 and L.byId.flash.on, 'global: scenario parameters saved')
clickTab('Automaticky##rm_auto')
frame(2)
check(L.rainMode == 'switch' and L.carSettings().rain.mode == nil, 'rain light back to automatic')

-- ---------------------------------------------------------------- AC shows commands late, configuration changes, replay

A.lag = 3
env.sim.timeHours = 21
seconds(0.5)
check(car.headlightsActive and L.CH.headlights.held and not L.CH.headlights.yielded,
  'lag: a late AC confirmation is no driver override')
app.config.set('master', false)
frame(1)
app.config.set('master', true)
seconds(0.5)
check(car.headlightsActive and L.CH.headlights.before == false and not L.CH.headlights.yielded,
  'lag: taken again while the give-back was on its way, the driver\'s state (off) is kept')
mark = #A.log + 1
L.toggleMesh('dash', 'DASH_GLOW')
L.toggleMesh('dash', 'DASH_GLOW')
seconds(0.5)
check(count('headlights', mark) == 0 and L.CH.headlights.held, 'configuration change: held lights are not given back')
env.sim.timeHours = 14
seconds(21)
check(not car.headlightsActive and not L.CH.headlights.held, 'lag: lights back off at the end')

-- release while a toggle of the rain switch is still on its way: no second toggle, the switch ends as the driver had it
check(L.rainMode == 'switch' and L.rainSource.key == 'C', 'lag test runs on the rain switch')
car.manualPitsSpeedLimiterEnabled = true
local rch = L.CH.extra[3]
local inFlight = false
for _ = 1, 120 do
  frame(1)
  if rch.pending and rch.expected == false and car.extraC then inFlight = true; break end
end
mark = #A.log + 1
app.config.set('master', false)
frame(10)
check(inFlight and car.extraC == false and count('__EXT_LIGHT_C', mark) == 0,
  'release with a toggle in flight: no extra toggle, rain switch off as before (' .. count('__EXT_LIGHT_C', mark) .. ')')
car.manualPitsSpeedLimiterEnabled = false
app.config.set('master', true)
frame(5)
A.lag = 0

car.brake = 1
car.headlightsActive = true
frame(10)
check(not env.brake1.visible and A.alive == 1, 'before the replay: brake copy and cabin light active')
mark = #A.log + 1
env.sim.isReplayActive = true
frame(3)
check(env.brake1.visible and env.dashMesh.visible and A.alive == 0 and count('turn', mark) + count('headlights', mark) == 0,
  'replay: the car\'s own look, nothing commanded')
env.sim.isReplayActive = false
frame(3)
check(not env.brake1.visible and A.alive == 1, 'after the replay: scenarios run again')
car.brake = 0
car.headlightsActive = false
seconds(3)

-- ---------------------------------------------------------------- master off, error boundary, session restart

local function activateAll()
  car.manualPitsSpeedLimiterEnabled = true
  env.sim.timeHours = 21
  car.brake = 1
  frame(20)
end
local function allBack(what)
  check(not car.headlightsActive, what .. ': headlights back off')
  check(not car.extraC, what .. ': rain switch back off')
  check(A.alive == 0, what .. ': cabin light disposed')
  check(env.brake1.visible and env.dashMesh.visible, what .. ': originals visible')
  check((env.storage['lcl_meshGuard'] or '') == '', what .. ': self-heal marker cleared')
end
local function calm()
  car.manualPitsSpeedLimiterEnabled = false
  env.sim.timeHours = 14
  car.brake = 0
end

activateAll()
check(car.headlightsActive and A.alive == 1 and not env.brake1.visible, 'everything active before master off')
app.config.set('master', false)
frame(3)
allBack('master off')
calm()
app.config.set('master', true)
frame(3)

activateAll()
local step = app.engine.step
app.engine.step = function () error('boom (test)') end
frame(3)
check(app.safety.halted, 'error boundary: halted')
allBack('error')
app.engine.step = step
calm()
app.safety.retry()
rt.restart('retry')
frame(5)

activateAll()
env.callbacks.session()
calm()                                      -- conditions over: only the release can give everything back this fast
frame(2)
allBack('session restart')
frame(5)

-- unload (CSP calls ac.onRelease, then the script does not run any more: only AC applies the commands)
activateAll()
env.callbacks.release()
for _ = 1, 3 do env.frameNo = env.frameNo + 1; env.clock = env.clock + H.DT; env.acStep() end
allBack('unload')
calm()
loadApp(true)
frame(5)

-- lights module off in the tab
activateAll()
clickTab('Ovládat světla auta##lenabled')
frame(2)
allBack('lights off in the tab')
clickTab('Ovládat světla auta##lenabled')
calm()
frame(5)

-- ---------------------------------------------------------------- self-heal after a crash

car.brake = 1
frame(10)
check(not env.brake1.visible, 'before the crash: brake light original hidden')
env.reloadScene()                           -- CSP removes the copies, the script starts again without release
car.brake = 0
loadApp(true)
frame(3)
check(env.brake1.visible and env.brake2.visible and L.healed >= 2, 'self-heal: originals visible after a crash (' .. L.healed .. ')')

-- ---------------------------------------------------------------- online

env.sim.isOnlineRace = true
frame(2)
local t = texts(drawTab)
check(hasText(t, 'vidí i ostatní'), 'online: banner shown')
check(not hasText(t, 'řídí jen řidič („I online“'), 'online with real lights allowed: no block note')
env.windowOpen = false
env.sim.timeHours = 21
frame(5)
check(car.headlightsActive, 'online: real lights allowed by default')
clickTab('I online##lrealonline')
seconds(0.5)                                -- the give-back waits for the 0.25 s minimum after the last command
check(not car.headlightsActive and itemOf('headlights').holder == L.TEXT.blocked, 'online block: lights given back, reason shown')
t = texts(drawTab)
env.windowOpen = false
check(hasText(t, 'řídí jen řidič („I online“'), 'online block: the tab says so')
clickTab('I online##lrealonline')
env.sim.timeHours = 14
seconds(21)
env.sim.isOnlineRace = false
env.onlineExtras = { sections = { EXTRA_RULES = {}, ABOUT = {} } }
check(L.online.readExtras():find('EXTRA_RULES', 1, true) ~= nil, 'online extras read on demand')
t = texts(drawTab)
env.windowOpen = false
check(not hasText(t, 'vidí i ostatní') and not hasText(t, '„I online“ je vypnuto'), 'offline: no banner')

-- diagnostics: lines for "Kopírovat diagnostiku" and the tab block
local dl = table.concat(L.diagLines(), '\n')
check(dl:find('Světla: zapnuto', 1, true) and dl:find('EXTRA_RULES', 1, true) and dl:find('dešťové světlo', 1, true)
  and dl:find('výstup Výstražná světla', 1, true), 'diagnostics lines')
t = texts(drawTab)
env.windowOpen = false
check(hasText(t, 'Diagnostika##ldiag') and hasText(t, 'příkazů') and hasText(t, 'meshe brake'),
  'tab: diagnostics block shown (collapsed section)')
env.clipboard = nil
clickTab('Kopírovat diagnostiku##ldiag_copy')
check(env.clipboard and env.clipboard:find('diagnostika', 1, true) ~= nil and env.clipboard:find('výstup', 1, true) ~= nil,
  'tab: diagnostics (with the lights) copied')

-- ---------------------------------------------------------------- formula without headlights, a car with less

H.formulaCar(1)
env.storage = {}
lightCar({ headlights = false, extras = {}, brake = false, turning = false, flash = false, lowBeams = false })
env.car.speedKmh = 120
loadApp()
frame(5)
car = env.car
check(L.rainMode == 'switch' and L.rainSource and L.rainSource.key == 'lights', 'no headlights: the lights switch is the rain light')
ids = {}
for i = 1, #L.items do ids[L.items[i].id] = true end
check(not ids.hazards and not ids.flash and not ids.highBeams and not ids.brake and ids.headlights,
  'only what exists: no hazards, flash, high beams or brake lights')
t = texts(drawTab)
env.windowOpen = false
check(not hasText(t, '##lon_hazardStop') and not hasText(t, '##lon_lightsDusk') and not hasText(t, '##lon_brakeBlink')
  and not hasText(t, '##lon_flash') and hasText(t, '##lon_rainPit'), 'tab: scenarios only for lights the car has')
car.manualPitsSpeedLimiterEnabled = true
mark = #A.log + 1
local litF, offF = false, false
for _ = 1, 90 do frame(1); if car.headlightsActive then litF = true else offF = true end end
check(litF and offF and count('headlights', mark) >= 4 and minGap('headlights', mark) >= 0.25 - 1e-6, 'rain light through the lights switch blinks')
car.manualPitsSpeedLimiterEnabled = false
seconds(1)
check(not car.headlightsActive, 'lights switch back off')

-- solid rain light through the lights switch: the (missing) headlights output must not give the switch back
check(L.OUT.headlights.ch == nil and not L.OUT.headlights.has, 'no headlights: the headlights output drives no channel')
L.setOn('rainWet', true)
env.sim.rainIntensity = 0.5
mark = #A.log + 1
seconds(2)
check(car.headlightsActive and count('headlights', mark) == 1,
  'solid rain light through the lights switch: one command, no fight (' .. count('headlights', mark) .. ')')
env.sim.rainIntensity = 0
seconds(12)
check(not car.headlightsActive and count('headlights', mark) == 2, 'solid rain light over: switch back off')
L.setOn('rainWet', false)

-- backlight on a car without headlights: only in the dark (lightsDusk hours), not all day
check(A.alive == 0, 'no headlights: no cabin light during the day')
env.sim.timeHours = 21
frame(3)
check(A.alive == 1, 'no headlights: cabin light in the dark')
env.sim.timeHours = 14
seconds(3)
check(A.alive == 0, 'no headlights: cabin light off again in daylight')

-- priority arrows skip the scenarios the tab does not show (their light is missing on this car)
local function visibleOrder()
  local out = {}
  for _, s in ipairs(L.order) do if s.out.has then out[#out + 1] = s.id end end
  return table.concat(out, ',')
end
check(visibleOrder() == 'rainPit,rainWet,backlightPit,backlight', 'visible scenarios: ' .. visibleOrder())
L.move('backlightPit', -1)
check(visibleOrder() == 'rainPit,backlightPit,rainWet,backlight', 'moved up past hidden scenarios: ' .. visibleOrder())
L.move('backlightPit', 1)
check(visibleOrder() == 'rainPit,rainWet,backlightPit,backlight', 'moved back down: ' .. visibleOrder())
L.move('rainPit', -1)
check(visibleOrder() == 'rainPit,rainWet,backlightPit,backlight', 'top scenario cannot move up')
clickTab('lup_backlight')
check(visibleOrder() == 'rainPit,rainWet,backlight,backlightPit', 'tab: Výš inside one light: ' .. visibleOrder())
clickTab('ldn_backlight')
check(visibleOrder() == 'rainPit,rainWet,backlightPit,backlight', 'tab: Níž inside one light: ' .. visibleOrder())
-- another light in between (an older saved order): Výš still passes the neighbour of the same light
L.move('rainWet', 1)
check(visibleOrder() == 'rainPit,backlightPit,rainWet,backlight', 'setup: another light between the rain scenarios')
clickTab('lup_rainWet')
check(visibleOrder() == 'rainWet,rainPit,backlightPit,backlight', 'tab: Výš passes the other light: ' .. visibleOrder())
local top = texts(drawTab)
env.windowOpen = false
check(not hasText(top, 'icon:lup_rainWet') and hasText(top, 'icon:ldn_rainWet'), 'tab: the top scenario of a light has no Výš')
clickTab('ldn_rainWet')
check(L.byId.rainWet.prio > L.byId.rainPit.prio, 'tab: Níž back below the blink')

-- high beam flash fallback (no own flash)
H.formulaCar(1)
env.storage = {}
lightCar({ flash = false })
env.car.speedKmh = 120
loadApp()
frame(5)
car = env.car
check(L.OUT.flash.has and L.OUT.flash.ch == L.CH.highBeams, 'no own flash: high beams are used')
mark = #A.log + 1
env.hotkeys = { ['__APP_LEDCONTROL_FLASH'] = true }
seconds(1)
check(count('highBeams', mark) == 0, 'high beam flash needs the headlights on')
car.headlightsActive = true
frame(2)
env.hotkeys = { ['__APP_LEDCONTROL_FLASH'] = true }
local sawHigh = false
for _ = 1, 120 do frame(1); if not car.lowBeams then sawHigh = true end end
check(sawHigh and car.lowBeams and count('highBeams', mark) == 4 and minGap('highBeams', mark) >= 0.25 - 1e-6,
  'high beam flash: two pulses, back to low beams (' .. count('highBeams', mark) .. ' commands)')
car.headlightsActive = false

-- ---------------------------------------------------------------- no allocation with the tab open

H.formulaCar(1)
env.storage = {}
lightCar()
env.car.speedKmh = 120
loadApp()
frame(5)
car = env.car
L.setRainMode('mesh')
car.manualPitsSpeedLimiterEnabled = true     -- rain mesh copy blinks
car.headlightsActive = true                  -- backlight: cabin light placed every frame, dash copy
car.brake = 1                                -- brake copies blink
L.toggleMesh('dash', 'DASH_GLOW')
env.windowOpen = true
U.tab = 'Světla'
frame(10)
H.click('Vybrat…##pick_rain')
H.click('Palubní deska a kabina##lx_backlight')   -- an expanded row (parameter, colour field) is part of the check
env.windowOpen = true
frame(120)
local function sweep() frame(1) end
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for _ = 1, 300 do sweep() end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
env.windowOpen = false
check(A.alive == 1 and not env.rainMesh.visible and not env.brake1.visible, 'allocation test runs with lights active')
print(string.format('allocation with tab Světla open: %.2f KB / 300 frames', grown))
check(grown < 4, string.format('no per-frame allocation with lights active and tab Světla open (%.2f KB / 300 frames)', grown))

return H.finish('test_lights')
