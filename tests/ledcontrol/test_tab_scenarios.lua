-- LedControl: tab Scénáře through the mock UI (layout of docs/ledcontrol-ui.md). Base look on one line with its "(?)"
-- (preset, copy-on-write), list in priority order under category captions, one row per scenario: on/off, the name
-- (a click expands it), live dot (green = lit, blue = Test, orange = layout problem), Test, Výš / Níž (no Výš on the
-- first row, no Níž on the last); availability (GT3: no DRS, red flag not reported) as a grey name with the reason in
-- "(?)"; the expanded scenario (target with the fallback note, pattern, only the settings the pattern uses, colours
-- with quick picks, Hz, direction, width, fill zones, fill source, parameter, the Otáčky hint of the shift lights),
-- slider / colour / name edits saved on release or at most every 0.3 s and when the tab is hidden, the custom
-- condition builder, click feedback (copy made, Test that cannot run, back to normal operation) and no allocation
-- with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions (this file only)

-- A control is "active" while the test drags it (U.slide) or types into it (U.active); U.release = the label that is
-- released after an edit this frame.
ui.itemActive = function ()
  return (U.slide ~= nil and U.slide[U.last] ~= nil) or (U.active ~= nil and U.active == U.last)
end
ui.itemDeactivatedAfterEdit = function () return U.release ~= nil and U.release == U.last end
local itemActive, itemDeactivated = ui.itemActive, ui.itemDeactivatedAfterEdit
ui.indent = ui.indent or function () end
ui.unindent = ui.unindent or function () end
if not ui.header then ui.header = function (t) if U.record then U.texts[#U.texts + 1] = t end end end
if not ui.inputText then
  ui.inputText = function (label, text)
    U.last = label
    local v = U.type and U.type[label]
    if v ~= nil then U.type[label] = nil return v, true, false end
    return text, false, false
  end
end
-- the "(?)" of K.help is an item that can be hovered: U.hover = '(?)' shows every help tooltip of the frame
do
  local f = ui.textDisabled
  ui.textDisabled = function (t, ...) U.last = t; return f(t, ...) end
end

-- the text the name field was last drawn with
local inputShown = {}
do
  local f = ui.inputText
  ui.inputText = function (label, text, ...)
    inputShown[label] = text
    return f(label, text, ...)
  end
end

-- every label a control was drawn with during the recorded frame (icon buttons: their K.iconButton id)
local drawn, recordDrawn = {}, false
for _, name in ipairs({ 'slider', 'colorButton', 'combo', 'button', 'checkbox', 'selectable', 'radioButton',
  'inputText' }) do
  local f = ui[name]
  ui[name] = function (label, ...)
    if recordDrawn then drawn[label] = true end
    return f(label, ...)
  end
end
do
  local f = ui.iconButton
  ui.iconButton = function (...)
    if recordDrawn and U.idStack then drawn[U.idStack[#U.idStack]] = true end
    return f(...)
  end
end

-- live dots (K.dot -> ui.drawCircleFilled) per scenario row, and the text colour each scenario name was drawn with
local dots, nameColour = {}, {}
local textColour, rowLabel = nil, nil
do
  local push, pop, sel, circle = ui.pushStyleColor, ui.popStyleColor, ui.selectable, ui.drawCircleFilled
  ui.pushStyleColor = function (k, c, ...) if k == ui.StyleColor.Text then textColour = c end return push(k, c, ...) end
  ui.popStyleColor = function (...) textColour = nil; return pop(...) end
  ui.selectable = function (label, ...)
    if tostring(label):find('##ex_', 1, true) then
      rowLabel = label
      if recordDrawn then nameColour[label] = textColour end
    end
    return sel(label, ...)
  end
  ui.drawCircleFilled = function (p, r, c, ...)
    if recordDrawn and rowLabel then dots[rowLabel:match('##ex_(.*)$')] = c end
    return circle(p, r, c, ...)
  end
end

local TAB = 'Scénáře'
local app, rt, presets, engine, K
local function loadApp()
  app = H.loadApp()
  rt, presets, engine = app.runtime, app.presets, app.engine
  K = require('src/ui/kit')
  return app
end

local function same(a, b)
  return a ~= nil and b ~= nil and math.abs(a.r - b.r) < 1e-6 and math.abs(a.g - b.g) < 1e-6
    and math.abs(a.b - b.b) < 1e-6
end

local function show(n)
  env.windowOpen = true
  U.tab = TAB
  frame(n or 1)
end

-- texts and control labels of one frame of the tab; help = true also records every "(?)" tooltip
local function capture(help)
  env.windowOpen = true
  U.tab = TAB
  U.record = true
  U.texts = {}
  drawn, dots, nameColour = {}, {}, {}
  rowLabel = nil
  if help then U.hover = '(?)' end
  recordDrawn = true
  frame(1)
  recordDrawn = false
  U.hover = nil
  U.record = false
  return table.concat(U.texts, '\n')
end
local function has(text, part) return text:find(part, 1, true) ~= nil end

local function click(label)
  U.tab = TAB
  H.click(label)
  frame(1)
end
local function pick(combo, item)
  U.openCombo = combo
  click(item)
  U.openCombo = nil
end
local function entry(id)
  local list = presets.effective(rt.preset())
  for i = 1, #list do if list[i].id == id then return list[i], i end end
end
local function lookOf(id) return entry(id).look end
local function nameLabel(id) return entry(id).name .. '##ex_' .. id end
local function expand(id) click(nameLabel(id)) end

-- ---------------------------------------------------------------- list on the formula with F1 styl

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 8000
loadApp()
frame(3)
check(rt.presetId == 'builtin:f1', 'formula: F1 styl')
local text = capture()
check(app.safety.uiError == nil, 'tab drawn without an error (' .. tostring(app.safety.uiError) .. ')')
check(has(text, 'Základ (když nic nesvítí)') and drawn['Zhasnuto##base_off'] and drawn['Podle auta##base_orig'],
  'base look: one line with two choices')
local help = capture(true)
check(has(help, '„F1 styl“ je vestavěný preset') and has(help, presets.BUILTIN[1].note),
  'base (?): preset name and note')
check(has(help, 'první úprava vytvoří vaši vlastní kopii'), 'base (?): editing a built-in preset makes a copy')
check(not has(text, 'Preset: F1 styl') and not has(text, 'Nahoře je vyšší priorita'),
  'no extra lines above the list (preset name, intro)')
check(has(text, 'BOX') and has(text, 'VLAJKY') and has(text, 'ŘAZENÍ') and has(text, 'START'),
  'category captions (Czech capitals)')

-- rows in priority order
local list = presets.effective(rt.preset())
local lastAt, ordered = 0, true
for i = 1, #list do
  local at = text:find(list[i].name .. '##ex_', 1, true)
  if not at or at < lastAt then ordered = false end
  lastAt = at or lastAt
end
check(ordered, 'rows in priority order')
local allRows = true
for i = 1, #list do
  local id = list[i].id
  for _, l in ipairs({ '##on_' .. id, 'Test##test_' .. id, list[i].name .. '##ex_' .. id }) do
    if not drawn[l] then allRows = false end
  end
  if (i > 1) ~= (drawn['up_' .. id] == true) or (i < #list) ~= (drawn['dn_' .. id] == true) then allRows = false end
end
check(allRows, 'every row: on/off, name, Test, Výš (not on the first row), Níž (not on the last row)')
check(not drawn['Upravit##ex_limiter'], 'no separate Upravit button (the name expands)')
check(has(help, 'Při 11500 ot/min (karta Otáčky)'), 'availability note in (?) (shift point from ai.ini)')
check(has(help, 'Nedostupné: AC tuto vlajku zatím nehlásí'), 'formula: red flag unavailable, reason in (?)')
check(same(nameColour[nameLabel('flagRed')], K.DIM) and nameColour[nameLabel('flagYellow')] == nil,
  'unavailable scenario: grey name, an available one keeps the normal colour')

-- live indicator
capture()
check(next(dots) == nil, 'nothing lit: no dot')
env.car.manualPitsSpeedLimiterEnabled = true
frame(2)
capture()
check(same(dots.pitLimiter, K.GREEN), 'pit limiter on: green dot on its row')
env.car.manualPitsSpeedLimiterEnabled = false
frame(2)
capture()
check(dots.pitLimiter == nil, 'pit limiter off again: no dot')

-- Test button: the scenario is forced on and marked
click('Test##test_flagYellow')
local sc = engine.find(rt.compiled, 'flagYellow')
check(sc and sc.forceUntil > rt.ST.t, 'Test: scenario forced for a few seconds')
local yellow = false
for _ = 1, 30 do
  frame(1)
  local r, g = env.seen(env.formula.hr.FLAG_L1)
  if r > 20 and g > 15 then yellow = true end
end
check(yellow, 'Test: the side LEDs show the yellow flag')
capture()
check(same(dots.flagYellow, K.BLUE), 'Test: blue dot on the tested row')
frame(300)
-- Test clicked in a frame where the compiled preset is a frame old (another edit this frame): runs one frame later
presets.version = presets.version + 1
env.windowOpen, U.tab, U.click = true, TAB, 'Test##test_flagBlack'
script.windowMain(H.DT)
U.click = nil
sc = engine.find(rt.compiled, 'flagBlack')
check(not (sc.forceUntil > rt.ST.t), 'Test with a stale compiled preset: queued, not lost on the old one')
frame(1)
sc = engine.find(rt.compiled, 'flagBlack')
check(sc.forceUntil > rt.ST.t, 'Test with a stale compiled preset: runs once runtime compiled the preset again')
frame(300)
-- Test of a switched-off scenario: shown on the car when the engine keeps it a candidate, else the tab says why
rt.editScenario('flagWhite', 'on', false)
frame(2)
local white = engine.find(rt.compiled, 'flagWhite')
local candidate = false
for gi = 1, #rt.compiled.groups do
  for _, c in ipairs(rt.compiled.groups[gi].cands) do if c == white then candidate = true end end
end
capture()
check(same(nameColour[nameLabel('flagWhite')], K.GREY), 'switched-off scenario: grey name')
click('Test##test_flagWhite')
text = capture()
if candidate then
  local r, g, b = env.seen(env.formula.hr.FLAG_L1)
  check(r > 20 and g > 20 and b > 20 and not has(text, 'Test se neukáže'), 'Test of a switched-off scenario: shown')
else
  check(has(text, 'Test se neukáže'), 'Test of a switched-off scenario: explained')
end
rt.setPreset('builtin:f1')
frame(300)

-- ---------------------------------------------------------------- copy-on-write

local versionBefore = presets.version
click('##on_flagBlue')
check(rt.presetId:match('^user:') ~= nil, 'copy-on-write: switching a scenario off moves the car to a user copy')
local userId = rt.presetId
check(presets.get(userId).from == 'builtin:f1', 'copy-on-write: the copy remembers F1 styl')
check(presets.BUILTIN[1].scenarios.flagBlue == nil, 'copy-on-write: the built-in preset is unchanged')
check(entry('flagBlue').on == false and presets.version > versionBefore, 'on/off: blue flag off and saved')
text = capture()
check(has(text, 'Uloženo do vaší kopie „' .. presets.get(userId).name .. '“'), 'copy made: said under the row')
help = capture(true)
check(has(help, 'Změny se ukládají do tohoto presetu') and has(help, 'Vychází z presetu „F1 styl“'),
  'base (?): user preset edits are saved directly, and its base')
click('##on_flagBlue')
check(entry('flagBlue').on == true and rt.presetId == userId, 'on/off: back on, same user preset')
frame(300)
check(not has(capture(), 'Uloženo do vaší kopie'), 'copy message disappears after a few seconds')

-- base look
click('Podle auta##base_orig')
check(presets.get(userId).base == 'original', 'base look: car\'s own logic')
click('Zhasnuto##base_off')
check(presets.get(userId).base == 'off', 'base look: off')

-- priority arrows (K.iconButton ids)
local _, at = entry('pitLane')
click('dn_pitLane')
local _, at2 = entry('pitLane')
check(at2 == at + 1, 'Níž: one place lower')
click('up_pitLane')
_, at2 = entry('pitLane')
check(at2 == at, 'Výš: back')
local firstId = presets.effective(rt.preset())[1].id
capture()
check(not drawn['up_' .. firstId], 'no Výš on the first row')
click('up_' .. firstId)
check(presets.effective(rt.preset())[1].id == firstId, 'Výš on the first row does nothing')

-- ---------------------------------------------------------------- expanded scenario: target, pattern, settings

expand('limiter')
text = capture()
check(has(text, 'Kde') and has(text, 'Vzor') and drawn['##sc_target'] and drawn['##sc_pattern'],
  'expand by clicking the name: target and pattern rows')
check(drawn['##c1'] and drawn['##c2'] and drawn['##sc_hz'] and not drawn['##sc_dir'] and not drawn['##sc_width'],
  'blink: colours and Hz only')
check(drawn['##sw_##c1_1'] and drawn['##sw_##c2_8'], 'colours: quick picks next to each colour button')

pick('##sc_target', 'všechny diody')
check(entry('limiter').to == 'all', 'target combo: all LEDs')
pick('##sc_pattern', 'Pulzuje')
check(lookOf('limiter').p == 'pulse', 'pattern combo: pulse')
pick('##sc_pattern', 'Běžící světlo')
capture()
check(lookOf('limiter').p == 'run' and drawn['##sc_dir'] and drawn['##sc_width'], 'run: direction and width shown')
U.openCombo = '##sc_dir'
capture()
U.openCombo = nil
check(drawn['tam a zpět'] and drawn['od středu ke krajům'], 'run: "tam a zpět" offered')
pick('##sc_dir', 'od krajů ke středu')
check(lookOf('limiter').dir == 'edges', 'direction combo')

-- slider: kept locally while dragged, saved on release
local v0 = presets.version
U.slide = { ['##sc_width'] = 3.2 }
show(5)
check(presets.version == v0 and (lookOf('limiter').width or 1) == 1, 'width slider: nothing saved while dragging')
U.slide = nil
U.release = '##sc_width'
show(1)
U.release = nil
frame(1)
check(lookOf('limiter').width == 3 and presets.version == v0 + 1, 'width slider: saved once on release (3 LEDs)')

U.slide = { ['##sc_hz'] = 6.04 }
show(4)
check(presets.version == v0 + 1, 'Hz slider: nothing saved while dragging')
U.slide = nil
U.release = '##sc_hz'
show(1)
U.release = nil
frame(1)
check(math.abs(lookOf('limiter').hz - 6) < 1e-9, 'Hz slider: saved on release, rounded to 0.1')

-- no release event in this CSP: saved at most every 0.3 s and once more after the drag
ui.itemActive, ui.itemDeactivatedAfterEdit = nil, nil
v0 = presets.version
for i = 1, 30 do                      -- 0.5 s of dragging
  U.slide = { ['##sc_hz'] = 2 + i * 0.1 }
  show(1)
end
U.slide = nil
local during = presets.version - v0
show(30)
check(during >= 1 and during <= 3, 'no release event: at most every 0.3 s while dragging (' .. during .. ' saves)')
check(math.abs(lookOf('limiter').hz - 5) < 1e-9, 'no release event: last value saved after the drag')
ui.itemActive, ui.itemDeactivatedAfterEdit = itemActive, itemDeactivated

-- colours: the picker keeps its value, saved at most every 0.3 s
pick('##sc_pattern', 'Bliká')
v0 = presets.version
for i = 1, 36 do                      -- 0.6 s in the picker
  U.pick = { ['##c1'] = { 0, i / 36, 0 } }
  show(1)
end
U.pick = nil
local colourSaves = presets.version - v0
show(30)
check(colourSaves >= 1 and colourSaves <= 3, 'colour: at most every 0.3 s while picking (' .. colourSaves .. ' saves)')
check(lookOf('limiter').c[1] == '#00FF00', 'colour: final colour saved as #RRGGBB')
U.pick = { ['##c2'] = { 1, 0, 0 } }
show(1)
U.pick = nil
show(30)
local c = lookOf('limiter').c
check(c[1] == '#00FF00' and c[2] == '#FF0000', 'colour 2 saved, colour 1 kept')
check(has(capture(), 'Mezi bliknutími'), 'colour 2 labelled for the blink pattern')
-- quick pick (a colour that stays true at any brightness): 5th = #00C8FF
U.pick = { ['##sw_##c1_5'] = { 0, 200 / 255, 1 } }
show(1)
U.pick = nil
show(30)
check(lookOf('limiter').c[1] == '#00C8FF' and lookOf('limiter').c[2] == '#FF0000', 'quick pick: colour 1 set, colour 2 kept')
-- the picker's rgbm is not overwritten while it is being edited (only when the stored colour changed elsewhere)
local handed = {}
do
  local f = ui.colorButton
  ui.colorButton = function (label, col, ...) if label == '##c1' then handed[#handed + 1] = col.r end return f(label, col, ...) end
  U.pick = { ['##c1'] = { 0.33, 0.9, 0.25 } }
  show(1)
  U.pick = nil
  show(1)
  ui.colorButton = f
end
check(math.abs(handed[#handed] - 0.33) < 1e-6, 'colour: the picker gets its own value back on the next frame')
show(30)
rt.editScenario('limiter', 'look', { p = 'blink', c = { '#0000FF', '#FF0000' }, hz = 5 })
handed = {}
do
  local f = ui.colorButton
  ui.colorButton = function (label, col, ...) if label == '##c1' then handed[#handed + 1] = col.b end return f(label, col, ...) end
  show(2)
  ui.colorButton = f
end
check(handed[#handed] == 1, 'colour: a colour changed elsewhere is shown in the picker')

-- a pending colour is saved before an immediate edit (pattern combo) of the same scenario: both kept
U.pick = { ['##c1'] = { 0, 1, 0 } }
show(1)
U.pick = nil
show(30)
click('##on_limiter')                         -- two edits just now: the next colour stays pending (< 0.3 s)
click('##on_limiter')
U.pick = { ['##c1'] = { 1, 0, 1 } }
show(1)
U.pick = nil
check(lookOf('limiter').c[1] == '#00FF00', 'colour pending right after another edit')
pick('##sc_pattern', 'Pulzuje')
c = lookOf('limiter')
check(c.p == 'pulse' and c.c[1] == '#FF00FF' and c.c[2] == '#FF0000', 'pending colour saved before the pattern change')
pick('##sc_pattern', 'Bliká')

-- the car switches to another preset (hotkey, preset combo) while a colour is pending: it goes to the preset it was
-- made in, never into the new one
local nUser = #presets.user
click('##on_limiter')
click('##on_limiter')
U.pick = { ['##c1'] = { 0, 1, 1 } }
show(1)
U.pick = nil
rt.setPreset('builtin:gt3')
show(30)
check(rt.presetId == 'builtin:gt3' and #presets.user == nUser, 'preset switch: no copy of the new built-in preset made')
check(entry('limiter').look.c[1] == '#FF0000', 'preset switch: the new preset keeps its own colour')
check(presets.get(userId).scenarios.limiter.look.c[1] == '#00FFFF', 'preset switch: the colour saved in the old preset')
rt.setPreset('builtin:f1')
show(2)
U.pick = { ['##c1'] = { 1, 1, 1 } }
show(1)                                         -- pending in the built-in preset (committed next frame)
U.pick = nil
rt.setPreset('builtin:gt3')
show(30)
check(rt.presetId == 'builtin:gt3' and #presets.user == nUser
  and presets.BUILTIN[1].scenarios.limiter.look.c[1] == '#0000FF',
  'preset switch from a built-in preset: the pending colour is dropped, no copy made')
rt.setPreset(userId)
show(2)
check(lookOf('limiter').c[1] == '#00FFFF', 'back in the user preset')

-- a pending colour in a built-in preset, then a combo edit (which makes the user copy): the colour is saved first,
-- both land in the copy
click('##on_limiter')
click('##on_limiter')
rt.setPreset('builtin:f1')
show(1)
U.pick = { ['##c1'] = { 1, 0.5, 0 } }
show(1)
U.pick = nil
pick('##sc_pattern', 'Pulzuje')
local copyId = rt.presetId
check(copyId:match('^user:') ~= nil and copyId ~= userId and lookOf('limiter').p == 'pulse'
  and lookOf('limiter').c[1] == '#FF8000', 'pending colour + pattern combo on a built-in preset: both in the new copy')
presets.delete(copyId)
rt.setPreset(userId)
show(2)

-- collapsing (a second click on the name) saves a pending slider value
U.slide = { ['##sc_hz'] = 9 }
show(2)
U.slide = nil
expand('limiter')
capture()
check(math.abs(lookOf('limiter').hz - 9) < 1e-9 and not drawn['##sc_target'], 'collapse: pending slider value saved')

-- hiding the tab (main.lua calls M.flush) saves a pending slider value
expand('limiter')
U.slide = { ['##sc_hz'] = 7 }
show(2)
U.slide = nil
U.tab = 'Diody'
frame(2)
check(math.abs(lookOf('limiter').hz - 7) < 1e-9, 'tab hidden: pending slider value saved')
show(1)
expand('limiter')

-- ---------------------------------------------------------------- fill: zones, source, parameter

expand('shiftLights')
text = capture()
check(drawn['##zc1'] and drawn['##zc2'] and drawn['##zc3'] and drawn['##zu2'] and not drawn['##zu1'],
  'fill: three zones from F1 styl, the first starts at 0')
check(drawn['##c2'] and not drawn['##c1'] and drawn['##sc_dir'] and drawn['##sc_src'] and drawn['##sc_param'],
  'fill: colour of unlit LEDs, direction, source, parameter')
check(has(text, 'Barvy') and has(text, 'od začátku') and has(text, 'Pozadí'), 'fill: zones and the unlit colour labelled')
check(has(text, 'Otáčky') and has(text, 'nastavíte v kartě Otáčky'), 'shift lights: RPM values are in the tab Otáčky')
U.openCombo = '##sc_dir'
capture()
U.openCombo = nil
check(drawn['od krajů ke středu'] and not drawn['tam a zpět'], 'fill: "tam a zpět" not offered as a fill direction')

U.slide = { ['##zu2'] = 50 }
show(2)
U.slide = nil
U.release = '##zu2'
show(1)
U.release = nil
frame(1)
local z = lookOf('shiftLights').zones
check(#z == 6 and math.abs(z[3] - 0.5) < 1e-9, 'zone 2 start moved to 50 %')
U.pick = { ['##zc1'] = { 1, 1, 0 } }
show(1)
U.pick = nil
show(30)
check(lookOf('shiftLights').zones[2] == '#FFFF00', 'zone 1 colour')
click('Přidat barvu##addzone')
z = lookOf('shiftLights').zones
check(#z == 8 and z[7] > z[5] and z[8] == '#FFFFFF', 'add zone: appended after the last one')
click('rmzone2')
z = lookOf('shiftLights').zones
check(#z == 6 and z[1] == 0 and z[2] == '#FFFF00', 'remove zone 2')
click('rmzone1')
click('rmzone1')
z = lookOf('shiftLights').zones
check(#z == 2 and z[1] == 0, 'remove zones down to one, the first starts at 0')
capture()
check(not drawn['rmzone1'], 'the last zone cannot be removed')

-- fill source: the formula's main row has RPM thresholds for every LED
U.openCombo = '##sc_src'
capture()
U.openCombo = nil
check(drawn['podle prahů otáček auta'], 'source "car" offered when every LED of the group has a threshold')
pick('##sc_src', 'podle prahů otáček auta')
check(lookOf('shiftLights').src == 'car', 'source combo: car thresholds')

-- parameter
U.slide = { ['##sc_param'] = 61.4 }
show(2)
U.slide = nil
U.release = '##sc_param'
show(1)
U.release = nil
frame(1)
check(entry('shiftLights').param == 61, 'parameter slider: saved on release, whole number')
check(has(capture(), 'Začátek'), 'parameter labelled with its name')
-- a start RPM set by hand in the tab Otáčky: the (?) at Začátek says that it wins for this car
check(not has(capture(true), 'začátek nastavený v kartě Otáčky'), 'automatic start: no (?) at Začátek')
rt.ST.shiftStartManual = 7200
check(has(capture(true), 'U tohoto auta platí začátek nastavený v kartě Otáčky'), 'manual start: (?) at Začátek')
rt.ST.shiftStartManual = 0

-- target "all" includes the side LEDs without thresholds: "car" no longer offered
pick('##sc_target', 'všechny diody')
U.openCombo = '##sc_src'
text = capture()
U.openCombo = nil
check(not drawn['podle prahů otáček auta'] and has(text, 'Skupiny bez prahů otáček se plní od začátku'),
  'source "car" not offered for all LEDs (explained: groups without thresholds fill from the start)')
pick('##sc_target', 'hlavní řada')

-- persisted
local saved = presets.get(rt.presetId).scenarios
loadApp()
frame(3)
check(rt.presetId == userId and math.abs(entry('limiter').look.hz - 7) < 1e-9 and entry('shiftLights').param == 61,
  'edits saved in the preset file')
check(saved.limiter.to == 'all', 'target saved')

-- ---------------------------------------------------------------- custom condition builder

show(1)
click('Přidat vlastní scénář##addcustom')
local customId
for _, e in ipairs(presets.effective(rt.preset())) do if e.custom then customId = e.id end end
text = capture()
check(customId ~= nil and drawn['##sc_name'] and has(text, 'Název') and has(text, 'VLASTNÍ'),
  'add custom: new scenario expanded under its caption')
check(drawn['##q1'] and drawn['##op1'] and drawn['##v1'] and has(text, 'Když'), 'custom: one condition row')
check(has(capture(true), 'Svítí, když rychlost < 60 km/h.'), 'custom: the condition described in (?) of the row')

-- name: typed, saved when the field is left
U.type = { ['##sc_name'] = 'Pomalu v boxech' }
U.active = '##sc_name'
show(1)
show(1)
check(entry(customId).name ~= 'Pomalu v boxech', 'name: not saved while typing')
U.active = nil
show(2)
check(entry(customId).name == 'Pomalu v boxech', 'name: saved when the field is left')
check(has(capture(), 'Pomalu v boxech##ex_' .. customId), 'name: the row shows the new name')
U.type = { ['##sc_name'] = '   ' }
U.active = '##sc_name'
show(1)
U.active = nil
show(2)
check(entry(customId).name == 'Pomalu v boxech' and inputShown['##sc_name'] == 'Pomalu v boxech',
  'empty name: not saved, the field shows the stored name again')
U.type = { ['##sc_name'] = 'a' .. string.rep('č', 25) }
U.release = '##sc_name'
show(1)
U.release = nil
show(1)
local nm = entry(customId).name
check(nm == 'a' .. string.rep('č', 19), 'long name: cut to 40 bytes without splitting a character (' .. #nm .. ' B)')
U.type = { ['##sc_name'] = 'Pomalu v boxech' }
U.release = '##sc_name'
show(1)
U.release = nil
show(1)
check(entry(customId).name == 'Pomalu v boxech', 'name: saved on release')

-- quantity, bool value, second row, operator, value
pick('##q1', 'V pit lane')
local w = entry(customId).when
check(w[1].q == 'pitlane' and w[1].op == '=' and w[1].v == 1, 'quantity combo: bool quantity = yes')
capture()
check(drawn['ano##vb1'] and not drawn['##v1'], 'bool quantity: checkbox instead of a slider')
click('ano##vb1')
check(entry(customId).when[1].v == 0, 'bool checkbox: "no"')
-- a row stored with another operator (import): the checkbox shows what conditions.eval does, a click makes it '='
local wi = presets.deepCopy(entry(customId).when)
wi[1] = { q = 'pitlane', op = '<', v = 1 }
rt.editScenario(customId, 'when', wi)
show(1)
local boxShown = nil
do
  local f = ui.checkbox
  ui.checkbox = function (label, v, ...) if label == 'ano##vb1' then boxShown = v end return f(label, v, ...) end
  show(1)
  ui.checkbox = f
end
check(boxShown == false, 'bool row "< 1": shown as "ne" (holds only while not in the pit lane)')
click('ano##vb1')
w = entry(customId).when
check(w[1].op == '=' and w[1].v == 1, 'bool checkbox: normalised to "= 1"')
click('ano##vb1')
check(entry(customId).when[1].op == '=' and entry(customId).when[1].v == 0, 'bool checkbox: back to "no"')
click('Přidat podmínku##addrow')
check(#entry(customId).when == 2, 'add row')
check(has(capture(), '\na\n'), 'second row labelled "a"')
pick('##op2', '≥')
check(entry(customId).when[2].op == '>=', 'operator combo')
U.slide = { ['##v2'] = 99.6 }
show(2)
U.slide = nil
U.release = '##v2'
show(1)
U.release = nil
frame(1)
w = entry(customId).when
check(w[2].v == 100, 'value slider: saved on release')
check(has(capture(true), 'mimo pit lane a rychlost ≥ 100 km/h'), 'description in (?): both rows')
pick('##q2', 'Denní doba')
w = entry(customId).when
check(w[2].q == 'time' and w[2].op == '>=' and w[2].v >= 0 and w[2].v <= 24, 'quantity change keeps the value in range')
click('rmrow1')
w = entry(customId).when
check(#w == 1 and w[1].q == 'time', 'remove row')
click('rmrow1')
text = capture(true)
check(#entry(customId).when == 0 and has(text, 'Bez podmínky nikdy nesvítí'), 'no rows: said in the form and in (?)')
click('Přidat podmínku##addrow')

-- the custom scenario works on the car
env.car.speedKmh = 30
pick('##q1', 'Rychlost')
pick('##op1', '<')
U.slide = { ['##v1'] = 60 }
show(2)
U.slide = nil
U.release = '##v1'
show(1)
U.release = nil
frame(3)
capture()
check(engine.find(rt.compiled, customId).active and same(dots[customId], K.GREEN), 'custom: active on the car (green dot)')
env.car.speedKmh = 120

-- delete with confirmation
click('Smazat scénář##sc_delete')
check(entry(customId) ~= nil, 'delete: first click only asks')
check(drawn['Opravdu smazat?##sc_delete'] or has(capture(), 'Opravdu smazat?'), 'delete: asks "Opravdu smazat?"')
click('Opravdu smazat?##sc_delete')
check(entry(customId) == nil, 'delete: second click removes the scenario')

-- ---------------------------------------------------------------- not running: Test says why

env.car.manualPitsSpeedLimiterEnabled = true
frame(2)
capture()
check(same(dots.pitLimiter, K.GREEN), 'pit limiter: green dot')
app.config.set('master', false)
frame(3)
capture()
check(dots.pitLimiter == nil, 'master off: no stale dot from the stopped engine')
env.car.manualPitsSpeedLimiterEnabled = false
click('Test##test_pitLimiter')
text = capture()
check(has(text, 'Test teď nejde: vypnuto hlavním vypínačem.'), 'Test while not running: the reason (master off)')
frame(300)
check(not has(capture(), 'Test teď nejde'), 'the Test message disappears after a few seconds')
app.config.set('master', true)
frame(3)
rt.setMode(2)
frame(2)
click('Test##test_pitLimiter')
text = capture()
check(has(text, 'Test teď nejde: diody ukazují testovací vzor.') and drawn['Zpět na provoz##sc_normal'],
  'Test during the test pattern of the Diody tab: explained, with a way back')
click('Zpět na provoz##sc_normal')
check(app.config.S.testMode == 0, 'back to normal operation from the tab')
capture()
check(not drawn['Zpět na provoz##sc_normal'], 'back to normal: the button is gone')

-- layout warnings of the compiled preset: orange dot on the row, the text in its settings
rt.editScenario('idle', 'look', { p = 'frames', fps = 2, rescale = false, palette = { '#FF0000' },
  g = { { n = 3, f = { '1.1' } } } })
frame(3)
capture()
check(same(dots.idle, K.ORANGE), 'layout warning: orange dot on the row')
expand('idle')
text = capture()
check(has(text, 'snímky jsou pro 3 diod'), 'layout warning: shown in the expanded scenario')
check(has(text, 'Snímky') and has(text, 'kreslí se v kartě Editor'), 'frames pattern: points to the Editor tab')
expand('idle')
check(app.safety.uiError == nil, 'no UI error on the formula (' .. tostring(app.safety.uiError) .. ')')

-- ---------------------------------------------------------------- GT3: availability

H.gt3Car(-1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 3000
loadApp()
frame(3)
check(rt.presetId == 'builtin:gt3', 'gt3: GT3 styl')
help = capture(true)
check(has(help, '„GT3 styl“ je vestavěný preset') and has(help, presets.BUILTIN[2].note), 'gt3: base (?)')
check(has(help, 'Nedostupné: auto nemá DRS'), 'gt3: DRS unavailable')
check(has(help, 'Nedostupné: AC tuto vlajku zatím nehlásí'), 'gt3: red flag unavailable')
check(has(help, 'Při 12610 ot/min (karta Otáčky)'), 'gt3: shift point note without ai.ini (97 % of the limiter)')
check(not has(help, 'boční diody'), 'gt3: the side fallback is not repeated on every row')
expand('flagBlue')
check(has(capture(true), 'Auto nemá boční diody, svítí hlavní řada.'), 'gt3: side target falls back to the main row (?)')
pick('##sc_target', 'hlavní řada')
check(not has(capture(true), 'Auto nemá boční diody'), 'gt3: no fallback note once the target is the main row')

-- ---------------------------------------------------------------- a car without RPM thresholds

H.namedCar()
env.storage = {}
env.car.speedKmh = 120
loadApp()
frame(3)
show(1)
expand('shiftLights')
U.openCombo = '##sc_src'
text = capture(true)
U.openCombo = nil
check(drawn['od začátku po bod řazení'] and not drawn['podle prahů otáček auta'],
  'no thresholds: only the relative source offered')
check(has(text, 'jde jen u aut, která mají práh otáček'), 'no thresholds: explained in (?)')

-- ---------------------------------------------------------------- a car without LEDs

H.emptyCar()
env.storage = {}
loadApp()
frame(3)
capture()
check(rt.state == 'noleds', 'no LEDs: state')
click('Test##test_pitLimiter')
check(has(capture(), 'Test teď nejde: auto nemá rozpoznané diody.'), 'no LEDs: Test explained')
check(app.safety.uiError == nil, 'no LEDs: no UI error (' .. tostring(app.safety.uiError) .. ')')

-- ---------------------------------------------------------------- no allocation with the tab open

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
loadApp()
show(10)
expand('shiftLights')
show(60)
local k = 0
local function sweep()
  k = k + 1
  env.car.rpm = 8000 + (k % 120) * 45
  env.car.manualPitsSpeedLimiterEnabled = k % 200 < 100
  frame(1)
end
local function measure()
  for _ = 1, 240 do sweep() end
  jit.off()
  collectgarbage('collect')
  collectgarbage('stop')
  local mem = collectgarbage('count')
  for _ = 1, 300 do sweep() end
  local grown = collectgarbage('count') - mem
  collectgarbage('restart')
  jit.on()
  return grown
end
local grown = measure()
check(grown < 4, string.format('no per-frame allocation with the Scénáře tab open, fill expanded (%.2f KB / 300 frames)',
  grown))
if os.getenv('LC_SHOW_ALLOC') then print(string.format('alloc fill expanded: %.3f KB', grown)) end

-- a custom scenario with two condition rows expanded
click('Přidat vlastní scénář##addcustom')
click('Přidat podmínku##addrow')
pick('##q2', 'V pit lane')
show(300)                                       -- the copy message is gone
grown = measure()
check(grown < 4, string.format('no per-frame allocation with a custom scenario expanded (%.2f KB / 300 frames)', grown))
if os.getenv('LC_SHOW_ALLOC') then print(string.format('alloc custom expanded: %.3f KB', grown)) end

-- a Test message and a dot on screen
click('Test##test_flagYellow')
show(2)
grown = measure()
check(grown < 4, string.format('no per-frame allocation while a Test runs (%.2f KB / 300 frames)', grown))
env.windowOpen = false
check(app.safety.uiError == nil, 'no UI error (' .. tostring(app.safety.uiError) .. ')')

return H.finish('test_tab_scenarios')
