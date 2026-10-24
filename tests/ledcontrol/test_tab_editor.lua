-- LedControl: tab Editor (manual presets and frame animations): presets new / copy / rename / delete / export,
-- new custom animation, painting cells (click and drag), palette, frames add / duplicate / delete / move, fps,
-- save into the preset (the LEDs on the car show the painted frames), discard, layout mismatch warning and the
-- rescale button, Test na autě, no allocation with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions used by the editor grid
-- (the shared mock stays untouched: these are the calls the grid needs, with the signatures of the official apps)

local R1, R2 = vec2(0, 0), vec2(22, 22)
ui.ButtonFlags = { None = 0, Disabled = 0x100 }
ui.HoveredFlags = { None = 0, AllowWhenBlockedByActiveItem = 32 }
ui.invisibleButton = function (label) U.last = label; return U.click == label end
ui.itemRect = function () return R1, R2 end
ui.itemActive = function () return U.active ~= nil and U.active == U.last end
ui.itemClicked = function () return U.click ~= nil and U.click == U.last end
ui.mouseDown = function () return U.mouseDown == true end
ui.dummy = function () U.last = '##dummy' end
ui.drawRect = function () end
ui.StyleColor = { Text = 0 }
local styleDepth = 0
ui.pushStyleColor = function () styleDepth = styleDepth + 1 end
ui.popStyleColor = function () styleDepth = styleDepth - 1 end
ui.drawRectFilled = function (_, _, c)
  local f = U.fills
  if f then f[#f + 1] = { U.last, c.r, c.g, c.b } end
end
-- the colour object a watched colour button gets each frame (what the picker would show), without allocating
local seenColour = { r = -1, g = -1, b = -1 }
local baseColorButton = ui.colorButton
ui.colorButton = function (label, c, flags, size)
  if label == U.watchColour then seenColour.r, seenColour.g, seenColour.b = c.r, c.g, c.b end
  return baseColorButton(label, c, flags, size)
end
local baseButton = ui.button
U.flags = {}
ui.button = function (label, size, flags)
  U.flags[label] = flags or 0
  return baseButton(label)
end

-- ---------------------------------------------------------------- helpers

local app, rt, presets
local function loadApp()
  if app then check(app.safety.uiError == nil, 'no UI error in the editor (' .. tostring(app.safety.uiError) .. ')') end
  app = H.loadApp()
  rt, presets = app.runtime, app.presets
  return app
end
local function tabFrame(n)
  env.windowOpen = true
  U.tab = 'Editor'
  frame(n or 1)
end
local function click(label)
  U.click = label
  tabFrame(1)
  U.click = nil
end
local function pickCombo(combo, label)
  U.openCombo = combo
  click(label)
  U.openCombo = nil
end
local function texts()
  U.record = true
  U.texts = {}
  tabFrame(1)
  U.record = false
  return table.concat(U.texts, '\n')
end
local function has(t, s) return t:find(s, 1, true) ~= nil end
local function validUtf8(s)
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local n = b < 0x80 and 0 or (b >= 0xF0 and 3 or (b >= 0xE0 and 2 or (b >= 0xC0 and 1 or -1)))
    if n < 0 then return false end
    for k = 1, n do
      local c = s:byte(i + k)
      if not c or c < 0x80 or c >= 0xC0 then return false end
    end
    i = i + n + 1
  end
  return true
end
local function editor() return require('src/ui/tab_editor') end
local function peek() return editor().peek() end
local function storedLook(scId)
  local p = presets.get(rt.presetId)
  local e = p and p.scenarios[scId]
  return e and e.look
end

local function slotColour(slot) return env.seen(env.formula.hr[env.formula.slot[slot]]) end
local function nameColour(name) return env.seen(env.formula.hr[name]) end
local function lit(r, g, b) return r + g + b > 0.5 end
local function isRed(r, g, b) return r > 20 and g < 1 and b < 1 end
local function isBlue(r, g, b) return b > 20 and r < 1 and g < 1 end
local function isWhite(r, g, b) return r > 20 and g > 20 and b > 20 end

-- frame 1 of the animation below: slot 1 blue, 2..5 red, rest off; frame 2: 11..15 red, rest off
local function showsFrame1()
  if not isBlue(slotColour(1)) then return false end
  for s = 2, 5 do if not isRed(slotColour(s)) then return false end end
  for s = 6, 15 do if lit(slotColour(s)) then return false end end
  return true
end
local function showsFrame2()
  for s = 1, 10 do if lit(slotColour(s)) then return false end end
  for s = 11, 15 do if not isRed(slotColour(s)) then return false end end
  return true
end
local function sidesDark()
  for k = 1, 3 do
    if lit(nameColour('FLAG_L' .. k)) or lit(nameColour('FLAG_R' .. k)) then return false end
  end
  return true
end

-- ---------------------------------------------------------------- preset row

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 8000
loadApp()
frame(3)
tabFrame(2)
local t = texts()
check(rt.presetId == 'builtin:f1', 'start: formula on the F1 preset')
check(has(t, 'Nový##edNew') and has(t, 'Kopírovat##edCopy') and has(t, 'Kopírovat do schránky##edExport'),
  'editor: preset row drawn')
check(has(t, 'relativní'), 'editor: built-in presets explained as relative')
check(U.flags['Přejmenovat##edRename'] == 0x100 and U.flags['Smazat##edDelete'] == 0x100,
  'built-in preset: rename and delete disabled')
click('Smazat##edDelete')
check(not has(texts(), 'Opravdu smazat'), 'built-in preset: delete does nothing')

pickCombo('##edPreset', 'GT3 styl##edPreset:builtin:gt3')
check(rt.presetId == 'builtin:gt3', 'preset combo: car switches to the chosen preset')
pickCombo('##edPreset', 'F1 styl##edPreset:builtin:f1')
check(rt.presetId == 'builtin:f1', 'preset combo: back to F1')

-- Nový: copy of the current preset with a new name, the name box opens
click('Nový##edNew')
local myId = rt.presetId
local mine = presets.get(myId)
check(#presets.user == 1 and myId:match('^user:') and mine.name == 'Nový preset' and mine.from == 'builtin:f1',
  'Nový: user preset made from the current one, the car uses it')
t = texts()
check(has(t, 'Uložit název##edRenameOk'), 'Nový: name box open')
check(U.flags['Přejmenovat##edRename'] == 0 and U.flags['Smazat##edDelete'] == 0, 'user preset: rename and delete enabled')
U.type = { ['##edRenameText'] = '   ' }
click('Uložit název##edRenameOk')
check(presets.get(myId).name == 'Nový preset' and has(texts(), 'nesmí být prázdný'), 'rename: empty name refused')
U.type = { ['##edRenameText'] = 'Moje animace' }
click('Uložit název##edRenameOk')
check(presets.get(myId).name == 'Moje animace' and not has(texts(), 'Uložit název##edRenameOk'),
  'rename: name saved, box closed')
click('Přejmenovat##edRename')
check(has(texts(), 'Uložit název##edRenameOk'), 'Přejmenovat: opens the name box')
click('Zrušit##edRenameCancel')
check(presets.get(myId).name == 'Moje animace', 'rename cancelled: name kept')

-- Kopírovat
click('Kopírovat##edCopy')
local copyId = rt.presetId
check(copyId ~= myId and presets.get(copyId).name == 'Moje animace (kopie)' and #presets.user == 2,
  'Kopírovat: copy with "(kopie)", the car uses it')

-- rename: a name another preset already has is refused (the combos could not tell them apart)
click('Přejmenovat##edRename')
U.type = { ['##edRenameText'] = 'Moje animace' }
click('Uložit název##edRenameOk')
check(presets.get(copyId).name == 'Moje animace (kopie)' and has(texts(), 'už existuje'),
  'rename: name of another user preset refused')
U.type = { ['##edRenameText'] = 'F1 styl' }
click('Uložit název##edRenameOk')
check(presets.get(copyId).name == 'Moje animace (kopie)', 'rename: name of a built-in preset refused')
-- a long Czech name is cut to 40 bytes without splitting a character (byte 40 starts "ó")
local longName = 'Žluťoučký kůň úpěl ďábelské ódy – příliš dlouhý název'
U.type = { ['##edRenameText'] = longName }
click('Uložit název##edRenameOk')
local cutName = presets.get(copyId).name
check(cutName == 'Žluťoučký kůň úpěl ďábelské' and validUtf8(cutName),
  'rename: long name cut on a character boundary (' .. cutName .. ')')
check(editor().cutUtf8('abc', 2) == 'ab' and editor().cutUtf8('ab', 5) == 'ab' and editor().cutUtf8('aé', 2) == 'a',
  'cutUtf8: plain, short and multi-byte cases')

-- Smazat: two clicks, the first one expires
click('Smazat##edDelete')
check(presets.get(copyId) ~= nil and has(texts(), 'Opravdu smazat? Klikněte znovu##edDelete'),
  'delete: first click only asks')
tabFrame(300)
check(not has(texts(), 'Opravdu smazat'), 'delete: confirmation expires')
click('Smazat##edDelete')
click('Opravdu smazat? Klikněte znovu##edDelete')
check(presets.get(copyId) == nil and #presets.user == 1, 'delete: preset gone after the second click')
check(rt.presetId == presets.choose(nil, app.config.S.defaultPreset, rt.layout, false) and rt.presetId == 'builtin:f1',
  'delete: the car falls back to presets.choose (F1 for a 15 LED row)')

pickCombo('##edPreset', 'Moje animace##edPreset:' .. myId)
check(rt.presetId == myId, 'own preset chosen again')

-- export to the clipboard
env.clipboard = nil
click('Kopírovat do schránky##edExport')
check(env.clipboard and env.clipboard:find('LEDCONTROL-PRESET 1 ', 1, true) == 1, 'export: preset text in the clipboard')
click('Vložit ze schránky##edImport')
local importedId = rt.presetId
check(importedId ~= myId and #presets.user == 2 and presets.get(importedId).name == 'Moje animace (2)',
  'import from the clipboard: new preset, the car uses it')
env.clipboard = 'nesmysl'
click('Vložit ze schránky##edImport')
check(rt.presetId == importedId and has(texts(), 'LEDCONTROL-PRESET'), 'import of bad text: refused with a reason')
click('Smazat##edDelete')
click('Opravdu smazat? Klikněte znovu##edDelete')
pickCombo('##edPreset', 'Moje animace##edPreset:' .. myId)
check(rt.presetId == myId and #presets.user == 1, 'imported preset deleted, own preset again')
check(styleDepth == 0, 'text colour pushes and pops balanced')

-- ---------------------------------------------------------------- new custom animation

t = texts()
check(has(t, 'Vyberte scénář'), 'no animation yet: the picker asks to choose one')
pickCombo('##edScenario', 'Nová vlastní animace##edScNew')
tabFrame(1)
local work, cur, dirty, sel, nFrames = peek()
check(sel and sel:match('^custom:') and rt.presetId == myId, 'new animation: custom scenario in the own preset')
local look = storedLook(sel)
check(look and look.p == 'frames' and look.g[1].n == 15 and look.g[2].n == 3 and look.g[3].n == 3
  and look.g[1].f[1] == string.rep('0', 15) and #look.g[1].f == 1, 'new animation: one frame per group, all cells off, stored')
check(presets.get(myId).scenarios[sel].name == 'Vlastní animace 1', 'new animation: named "Vlastní animace 1"')
check(work and nFrames == 1 and cur == 1 and not dirty, 'new animation: clean working copy')
t = texts()
check(has(t, 'Řada otáček – 15 diod') and has(t, 'Levé – 3 diody') and has(t, 'Pravé – 3 diody'),
  'grid: one row per LED group with its name, in real order')
check(has(t, 'Ukáže se, když: Rychlost < 60 km/h'), 'custom animation: its condition is described')
check(not has(t, 'neuloženo'), 'clean copy: no "neuloženo"')
check(U.flags['Zahodit změny##edDiscard'] == 0x100, 'clean copy: Zahodit změny disabled')
check(has(t, 'Smazat animaci##edScDel'), 'custom animation: delete button shown')

-- ---------------------------------------------------------------- painting

click('##edBrush1')
check(select(6, peek()) == 3, 'brush 1 selected')
-- drag from cell 2 to cell 5
U.mouseDown, U.active = true, '##edCell1_2'
for k = 2, 5 do
  U.hover = '##edCell1_' .. k
  tabFrame(1)
end
U.mouseDown, U.active = false, nil
tabFrame(1)
-- mouse pressed outside the grid and moved over a cell: no painting
U.mouseDown, U.hover = true, '##edCell1_7'
tabFrame(2)
U.mouseDown, U.hover = false, nil
work = peek()
check(work.g[1].f[1] == '011110000000000', 'drag paints cells 2..5, a press outside the grid paints nothing ('
  .. work.g[1].f[1] .. ')')
check(has(texts(), 'neuloženo'), 'painted: "neuloženo" shown')
check(U.flags['Zahodit změny##edDiscard'] == 0, 'painted: Zahodit změny enabled')
env.clipboard = nil
click('Kopírovat do schránky##edExport')
check(env.clipboard and has(texts(), 'Neuložené změny animace v něm nejsou'), 'export with unsaved edits: says they are not in it')

-- palette colour 3 changed with the colour button; clicking it also selects brush 3
click('##edPal3')
check(select(6, peek()) == 5, 'clicking a palette colour selects its brush')
U.pick = { ['##edPal3'] = { 0, 0, 1 } }
tabFrame(1)
U.pick = nil
work = peek()
check(work.palette[3] == '#0000FF', 'palette colour 3 edited (' .. tostring(work.palette[3]) .. ')')
tabFrame(5)
check(peek().palette[3] == '#0000FF', 'palette colour stays as picked over frames')
click('##edCell1_1')
check(peek().g[1].f[1] == '311110000000000', 'click paints one cell')
click('##edBrush.')
click('##edCell2_1')
check(peek().g[2].f[1] == '.00', 'transparent brush paints "."')
click('##edBrush0')
click('##edCell2_1')
check(peek().g[2].f[1] == '000', 'off brush paints "0"')

-- ---------------------------------------------------------------- frames

click('Duplikovat##edDup')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 2 and cur == 2 and work.g[1].f[2] == work.g[1].f[1] and #work.g[2].f == 2,
  'Duplikovat: copy of the frame after it, in every group')
for k = 1, 5 do click('##edCell1_' .. k) end
click('##edBrush1')
for k = 11, 15 do click('##edCell1_' .. k) end
check(peek().g[1].f[2] == '000000000011111', 'frame 2 painted')
click('Přidat snímek##edAdd')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 3 and cur == 3 and work.g[1].f[3] == string.rep('0', 15) and work.g[3].f[3] == '000',
  'Přidat snímek: empty frame after the current one')
click('< Posunout##edLeft')
work, cur = peek()
check(cur == 2 and work.g[1].f[2] == string.rep('0', 15) and work.g[1].f[3] == '000000000011111',
  'move left: frames swapped, selection follows')
click('Posunout >##edRight')
work, cur = peek()
check(cur == 3 and work.g[1].f[3] == string.rep('0', 15), 'move right: back')
click('Smazat snímek##edDelFrame')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 2 and cur == 2 and #work.g[1].f == 2 and #work.g[2].f == 2, 'Smazat snímek: frame removed everywhere')
click('1##edFrame1')
check(select(2, peek()) == 1, 'frame strip: click selects a frame')
check(has(texts(), '[1]##edFrame1'), 'frame strip: selected frame marked')
click('Vyplnit štětcem##edFill')
check(peek().g[1].f[1] == string.rep('1', 15), 'Vyplnit štětcem fills the frame')
click('Zahodit změny##edDiscard')
work, cur, dirty, sel, nFrames = peek()
check(not dirty and nFrames == 1 and work.g[1].f[1] == string.rep('0', 15), 'Zahodit změny: back to the stored look')

-- paint the two frames again (as above), then fps and save
local function paintAnimation()
  click('##edBrush1')
  for k = 2, 5 do click('##edCell1_' .. k) end
  click('##edBrush3')
  click('##edCell1_1')
  click('Přidat snímek##edAdd')
  click('##edBrush1')
  for k = 11, 15 do click('##edCell1_' .. k) end
end
U.pick = { ['##edPal3'] = { 0, 0, 1 } }
tabFrame(1)
U.pick = nil
paintAnimation()
work = peek()
check(work.g[1].f[1] == '311110000000000' and work.g[1].f[2] == '000000000011111', 'animation painted again')
U.slide = { ['##edFps'] = 6 }
tabFrame(1)
U.slide = nil
check(peek().fps == 6, 'fps slider')
check(has(texts(), '2 snímky, 6.0 snímků/s'), 'preview label shows frames and fps')

-- live preview draws the frame of the animation (one cell per LED of every group)
U.fills = {}
tabFrame(1)
local cells, red = 0, false
for _, f in ipairs(U.fills) do
  if f[1] == '##dummy' then
    cells = cells + 1
    if f[2] > 0.9 and f[3] < 0.1 then red = true end
  end
end
U.fills = nil
check(cells == 21 and red, 'live preview: 21 cells drawn, painted colour among them (' .. cells .. ')')

click('Uložit##edSave')
look = storedLook(sel)
check(look and look.g[1].f[1] == '311110000000000' and look.g[1].f[2] == '000000000011111' and look.fps == 6
  and look.palette[3] == '#0000FF' and #look.g[2].f == 2, 'Uložit: the look is stored in the preset')
check(not select(3, peek()) and not has(texts(), 'neuloženo'), 'saved: "neuloženo" gone')

-- the car shows the painted frames while the custom condition holds (speed < 60 km/h)
env.car.speedKmh = 30
frame(3)
local saw1, saw2, dark = false, false, true
for _ = 1, 60 do
  frame(1)
  if showsFrame1() then saw1 = true end
  if showsFrame2() then saw2 = true end
  if not sidesDark() then dark = false end
end
check(saw1 and saw2 and dark, 'car: LEDs show both painted frames, side groups off')
check(rt.compiled.groups[1].activeName == 'Vlastní animace 1', 'car: the animation is the active scenario')

-- hovering a cell blinks its LED on the car
U.hover = '##edCell1_8'
local blinked = false
for _ = 1, 20 do
  tabFrame(1)
  if isWhite(slotColour(8)) then blinked = true end
end
U.hover = nil
check(blinked, 'hover over a cell: its LED blinks on the car')

-- ---------------------------------------------------------------- Test na autě

env.car.speedKmh = 120
frame(5)
check(not lit(slotColour(1)), 'condition false: the animation is off')
click('Test na autě##edTest')
local tested = false
for _ = 1, 30 do
  tabFrame(1)
  if showsFrame1() or showsFrame2() then tested = true end
end
check(tested and has(texts(), 'Test na autě: animace se ukazuje 5 s'), 'Test na autě: saved and shown on the car')
tabFrame(330)
check(not lit(slotColour(1)) and not lit(slotColour(15)), 'Test na autě: stops after 5 s')
rt.setMode(2)
click('Test na autě##edTest')
check(has(texts(), 'Normální provoz'), 'Test na autě with a Diody test pattern: explained')
rt.setMode(0)
tabFrame(2)

-- ---------------------------------------------------------------- scenario picker and switches

local customLabel = 'Vlastní animace 1 – vlastní snímky##edSc:' .. sel
pickCombo('##edScenario', 'Omezovač otáček##edSc:limiter')
t = texts()
check(select(4, peek()) == 'limiter' and has(t, 'vzor „Bliká“') and has(t, 'neuloženo'),
  'built-in scenario: its look is replaced only on save')
check(storedLook('limiter') == nil, 'built-in scenario: nothing stored before Uložit')
check(not has(t, 'Smazat animaci##edScDel'), 'built-in scenario: no delete button')
-- the car's preset changed outside the editor (header combo) with unsaved edits: they are dropped with a message
U.openCombo = '##preset'
click('GT3 styl##hdrPreset:builtin:gt3')
U.openCombo = nil
t = texts()
check(rt.presetId == 'builtin:gt3' and has(t, 'neuložené změny animace jsou zahozené'), 'header preset switch: edits dropped, said so')
U.openCombo = '##preset'
click('Moje animace##hdrPreset:' .. myId)
U.openCombo = nil
check(rt.presetId == myId and select(4, peek()) == 'limiter', 'header preset switch back: own preset')
pickCombo('##edScenario', 'Modrá vlajka (pouští rychlejší auto)##edSc:flagBlue')
check(has(texts(), '(sem tento scénář nesvítí)'), 'side scenario: main row marked as not targeted')
pickCombo('##edScenario', customLabel)
work = peek()
check(select(4, peek()) == sel and work.g[1].f[2] == '000000000011111', 'custom animation picked again from the stored look')
click('Scénář zapnutý##edOn')
check(presets.get(myId).scenarios[sel].on == false and has(texts(), 'Scénář je vypnutý'), 'switch: scenario off')
click('Scénář zapnutý##edOn')
check(presets.get(myId).scenarios[sel].on == true, 'switch: scenario on again')

-- ---------------------------------------------------------------- layout mismatch and rescaling

rt.editScenario(sel, 'look', { p = 'frames', fps = 2, palette = { '#FF0000', '#00FF00', '#0000FF', '#FFFFFF', '#FFFF00' },
  g = { { n = 5, f = { '12345' } } } })
tabFrame(2)
work, cur, dirty = peek()
check(work.g[1].n == 5 and work.g[2].f[1] == '...' and not dirty,
  'stored look for 5 LEDs loaded, missing groups transparent, not "neuloženo"')
click('Přidat snímek##edAdd')
work = peek()
check(work.g[1].f[2] == '00000' and work.g[2].f[2] == '...' and work.g[3].f[2] == '...',
  'Přidat snímek: groups the animation leaves transparent stay transparent')
click('Smazat snímek##edDelFrame')
work, cur, dirty = peek()
check(#work.g[1].f == 1 and cur == 1 and not dirty, 'frame added and removed again: back to the stored look')
t = texts()
check(has(t, 'Skupina Řada otáček: snímky jsou pro 5 diod, auto má 15 diod.') and has(t, 'Přizpůsobit počtu diod##edFit'),
  'mismatch: warning and the rescale button')
env.car.speedKmh = 30
frame(3)
check(isRed(slotColour(1)) and isRed(slotColour(3)) and isBlue(slotColour(8)) and isWhite(slotColour(11)),
  'car: 5 cells rescaled to 15 by the engine (rescale on)')
click('Přizpůsobit počtu diod##edFit')
work, cur, dirty = peek()
check(work.g[1].n == 15 and work.g[1].f[1] == '111222333444555' and dirty, 'Přizpůsobit: nearest-centre resampling to 15')
check(not has(texts(), 'Přizpůsobit počtu diod##edFit'), 'after fitting: no warning')
click('Na autě s jiným počtem diod snímky přepočítat##edRescale')
check(peek().rescale == false and has(texts(), 'se scénář na autě s jiným počtem diod vypne'), 'rescale switched off')
click('Uložit##edSave')
look = storedLook(sel)
check(look.rescale == false and look.g[1].n == 15 and look.g[1].f[1] == '111222333444555', 'saved: rescale off, 15 cells')
env.car.speedKmh = 120

-- persistence and import of the exported text
local exported = presets.export(myId)
loadApp()
frame(3)
check(rt.presetId == myId, 'reload: car keeps the own preset')
look = storedLook(sel)
check(look and look.g[1].f[1] == '111222333444555' and look.rescale == false, 'reload: animation saved on disk')
local imported = presets.import(exported)
local il = imported and presets.get(imported).scenarios[sel].look
check(il and il.g[1].f[1] == '111222333444555' and il.fps == 2, 'import of the exported text keeps the frames')

-- a car with another LED count: the stored 15-cell frames are flagged in the editor
H.gt3Car(1)
env.car.speedKmh = 30
loadApp()
frame(3)
rt.setPreset(myId)
tabFrame(2)
pickCombo('##edScenario', customLabel)
t = texts()
check(has(t, 'snímky jsou pro 15 diod, auto má 10 diod') and has(t, 'scénář na autě vypne'),
  'other car: mismatch warning, scenario off without rescaling')
check(#rt.compiled.warnings > 0, 'other car: the engine reports the mismatch too')
click('Přizpůsobit počtu diod##edFit')
check(peek().g[1].n == 10, 'other car: fitted to 10 LEDs')

-- the colour picker keeps the exact value the user picked (it is not snapped back to the 8-bit stored hex every
-- frame, which made the Diody picker jump), also after Uložit reloads the working copy from the stored look
U.watchColour = '##edPal2'
U.pick = { ['##edPal2'] = { 0.3333, 0.5, 0.7071 } }
tabFrame(1)
U.pick = nil
tabFrame(5)
check(seenColour.r == 0.3333 and seenColour.g == 0.5 and seenColour.b == 0.7071 and peek().palette[2] == '#5580B4',
  'palette picker: exact picked value kept over frames (' .. seenColour.r .. ')')
click('Uložit##edSave')
tabFrame(5)
check(seenColour.r == 0.3333 and seenColour.b == 0.7071 and storedLook(sel).palette[2] == '#5580B4',
  'palette picker: value kept after saving')
U.watchColour = nil

-- deleting the custom animation: the first click only asks, the second removes it from the preset
click('Smazat animaci##edScDel')
check(presets.get(myId).scenarios[sel] ~= nil and has(texts(), 'Opravdu smazat animaci? Klikněte znovu##edScDel'),
  'delete animation: first click only asks')
tabFrame(300)
check(not has(texts(), 'Opravdu smazat animaci'), 'delete animation: question expires')
click('Smazat animaci##edScDel')
click('Opravdu smazat animaci? Klikněte znovu##edScDel')
check(presets.get(myId).scenarios[sel] == nil and select(4, peek()) ~= sel and has(texts(), 'je smazaná'),
  'delete animation: custom scenario removed from the preset')
local customLeft = false
for _, e in ipairs(presets.effective(presets.get(myId))) do if e.id == sel then customLeft = true end end
check(not customLeft, 'delete animation: gone from the effective list too')

-- ---------------------------------------------------------------- no allocation with the tab open

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 30
env.car.rpm = 8000
loadApp()
frame(3)
tabFrame(1)
pickCombo('##edScenario', 'Nová vlastní animace##edScNew')
U.pick = { ['##edPal3'] = { 0, 0, 1 } }
tabFrame(1)
U.pick = nil
paintAnimation()
click('Uložit##edSave')
U.hover = '##edCell1_4'
local function measure(n)
  tabFrame(120)
  jit.off()
  collectgarbage('collect')
  collectgarbage('stop')
  local mem = collectgarbage('count')
  tabFrame(n)
  local grown = collectgarbage('count') - mem
  collectgarbage('restart')
  jit.on()
  return grown
end
local grown = measure(300)
check(grown < 4, string.format('no per-frame allocation with Editor open (%.2f KB / 300 frames)', grown))
-- the same with the animation and preset combos open (their item functions run every frame) and painting held down
U.openCombo = '##edScenario'
grown = measure(300)
check(grown < 4, string.format('no per-frame allocation with the animation combo open (%.2f KB / 300 frames)', grown))
U.openCombo = '##edPreset'
U.mouseDown, U.active = true, '##edCell1_4'
grown = measure(300)
check(grown < 4, string.format('no per-frame allocation with the preset combo open, mouse held (%.2f KB / 300 frames)', grown))
U.openCombo, U.mouseDown, U.active = nil, false, nil
U.hover = nil
env.windowOpen = false
check(app.safety.uiError == nil, 'no UI error in the editor (' .. tostring(app.safety.uiError) .. ')')

return H.finish('test_tab_editor')
