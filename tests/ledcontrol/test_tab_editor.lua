-- LedControl: tab Editor (own presets and frame animations): preset icons new / copy / rename / delete (built-in
-- presets: rename and delete disabled), rename in place, new custom animation, painting cells (click and drag),
-- brush palette with the colour row (colour button + quick picks), frames add / duplicate / delete / move (icons,
-- disabled when not possible, fixed while frames wrap), fps and the live preview, save into the preset (the LEDs on
-- the car show the painted frames), discard, layout mismatch warning and Přizpůsobit, rescale, Test na autě, export /
-- import of the edited preset, no allocation with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions used by the editor
-- (the shared mock stays untouched: these are the calls the grid needs, with the signatures of the official apps,
-- plus recording: icon ids into the texts, flags of buttons and icons, the highlighted (accent) buttons, and hover on
-- texts and on the kit's "(?)" so tooltips can be read)

local R1, R2 = vec2(0, 0), vec2(22, 22)
ui.HoveredFlags = { None = 0, AllowWhenBlockedByActiveItem = 32 }
ui.invisibleButton = function (label)
  U.last = label
  if U.record then U.texts[#U.texts + 1] = label end
  return U.click == label
end
ui.itemRect = function () return R1, R2 end
ui.itemActive = function () return U.active ~= nil and U.active == U.last end
ui.itemClicked = function () return U.click ~= nil and U.click == U.last end
ui.mouseDown = function () return U.mouseDown == true end
ui.dummy = function () U.last = '##dummy' end
ui.drawRect = function () end
local styleDepth = 0
ui.pushStyleColor = function (idx)
  styleDepth = styleDepth + 1
  if idx == ui.StyleColor.Button then U.accent = true end
end
ui.popStyleColor = function () styleDepth = styleDepth - 1; U.accent = false end
ui.drawRectFilled = function (_, _, c)
  local f = U.fills
  if f then f[#f + 1] = { U.last, c.r, c.g, c.b } end
end
-- the colour object a watched colour button gets each frame (what the picker would show), without allocating
local seenColour = { r = -1, g = -1, b = -1 }
local baseColorButton = ui.colorButton
ui.colorButton = function (label, c, flags, size)
  if label == U.watchColour then seenColour.r, seenColour.g, seenColour.b = c.r, c.g, c.b end
  if U.record then U.texts[#U.texts + 1] = 'colour:' .. label end
  return baseColorButton(label, c, flags, size)
end
local baseButton = ui.button
U.flags, U.accented = {}, {}
ui.button = function (label, size, flags)
  U.flags[label] = flags or 0
  if U.accent then U.accented[label] = true end
  return baseButton(label)
end
local baseIconButton = ui.iconButton
ui.iconButton = function (icon, size, padding, framed, flags)
  local id = U.idStack and U.idStack[#U.idStack]
  if id then U.flags[id] = flags or 0 end
  if U.record then U.texts[#U.texts + 1] = 'icon:' .. tostring(id) end
  return baseIconButton(icon)
end
local baseCombo = ui.combo
ui.combo = function (label, preview, flags, content)
  if U.record then U.texts[#U.texts + 1] = 'combo:' .. label end
  return baseCombo(label, preview, flags, content)
end
local baseTextDisabled, baseText, baseTextColored = ui.textDisabled, ui.text, ui.textColored
ui.textDisabled = function (t) baseTextDisabled(t); U.last = '(?)' end
ui.text = function (t) baseText(t); U.last = t end
ui.textColored = function (t, c) baseTextColored(t, c); U.last = t end

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
  U.accented = {}
  tabFrame(1)
  U.record = false
  return table.concat(U.texts, '\n')
end
-- texts of a frame with the mouse over an item (a text, '(?)' = every help mark, or a label)
local function hoverTexts(what)
  U.hover = what
  local t = texts()
  U.hover = nil
  return t
end
local function has(t, s) return t:find(s, 1, true) ~= nil end
local function count(t, s)
  local n, i = 0, 1
  while true do
    local a, b = t:find(s, i, true)
    if not a then return n end
    n, i = n + 1, b + 1
  end
end
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
local DISABLED = 0x100

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
check(has(t, 'icon:edNew') and has(t, 'icon:edCopy') and has(t, 'icon:edRename') and has(t, 'icon:edDelete')
  and has(t, 'combo:##edPreset'), 'editor: preset row = combo + four icons')
check(not has(t, 'Kopírovat do schránky') and not has(t, 'Vložit ze schránky'),
  'editor: export / import are not repeated here (tab Nastavení)')
check(not has(t, 'relativní'), 'editor: no long explanation in the main view')
check(has(hoverTexts('(?)'), 'relativní'), 'editor: built-in presets explained as relative in the (?) tooltip')
check(has(hoverTexts('edDelete'), 'Smazat') and has(hoverTexts('edNew'), 'Nový preset'), 'preset icons have tooltips')
check(U.flags.edRename == DISABLED and U.flags.edDelete == DISABLED and U.flags.edNew == 0 and U.flags.edCopy == 0,
  'built-in preset: rename and delete disabled, new and copy enabled')
click('edDelete')
check(not has(texts(), 'Smazat?##edDeleteOk'), 'built-in preset: delete does nothing')
click('edRename')
check(not has(texts(), '##edRenameText'), 'built-in preset: rename does nothing')

pickCombo('##edPreset', 'GT3 styl##edPreset:builtin:gt3')
check(rt.presetId == 'builtin:gt3', 'preset combo: car switches to the chosen preset')
pickCombo('##edPreset', 'F1 styl##edPreset:builtin:f1')
check(rt.presetId == 'builtin:f1', 'preset combo: back to F1')

-- Nový: copy of the current preset with a new name, the name box opens in place of the combo
click('edNew')
local myId = rt.presetId
local mine = presets.get(myId)
check(#presets.user == 1 and myId:match('^user:') and mine.name == 'Nový preset' and mine.from == 'builtin:f1',
  'Nový: user preset made from the current one, the car uses it')
t = texts()
check(has(t, 'Uložit název##edRenameOk') and has(t, 'zadejte název'), 'Nový: name box open, asks for the name')
check(not has(t, 'icon:edNew') and not has(t, 'combo:##edPreset'), 'rename in place: the name box replaces combo and icons')
U.type = { ['##edRenameText'] = '   ' }
click('Uložit název##edRenameOk')
check(presets.get(myId).name == 'Nový preset' and has(texts(), 'nesmí být prázdný'), 'rename: empty name refused')
U.type = { ['##edRenameText'] = 'Moje animace' }
click('Uložit název##edRenameOk')
t = texts()
check(presets.get(myId).name == 'Moje animace' and not has(t, 'Uložit název##edRenameOk') and has(t, 'icon:edNew'),
  'rename: name saved, box closed, preset row back')
check(U.flags.edRename == 0 and U.flags.edDelete == 0, 'user preset: rename and delete enabled')
click('edRename')
check(has(texts(), 'Uložit název##edRenameOk'), 'Přejmenovat: opens the name box')
click('Zrušit##edRenameCancel')
check(presets.get(myId).name == 'Moje animace' and not has(texts(), '##edRenameText'), 'rename cancelled: name kept')

-- Kopie
click('edCopy')
local copyId = rt.presetId
check(copyId ~= myId and presets.get(copyId).name == 'Moje animace (kopie)' and #presets.user == 2,
  'Kopie: copy with "(kopie)", the car uses it')
check(has(texts(), 'vytvořená'), 'Kopie: said so')

-- rename: a name another preset already has is refused (the combos could not tell them apart)
click('edRename')
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
click('edDelete')
t = texts()
check(presets.get(copyId) ~= nil and has(t, 'Smazat?##edDeleteOk') and not has(t, 'icon:edDelete'),
  'delete: first click only asks (the icon turns into "Smazat?")')
check(has(hoverTexts('Smazat?##edDeleteOk'), 'Klikněte znovu'), 'delete: the question explains the second click')
tabFrame(300)
check(not has(texts(), 'Smazat?'), 'delete: confirmation expires')
click('edDelete')
click('Smazat?##edDeleteOk')
check(presets.get(copyId) == nil and #presets.user == 1, 'delete: preset gone after the second click')
check(rt.presetId == presets.choose(nil, app.config.S.defaultPreset, rt.layout, false) and rt.presetId == 'builtin:f1',
  'delete: the car falls back to presets.choose (F1 for a 15 LED row)')
check(has(texts(), 'je smazaný'), 'delete: said so')

pickCombo('##edPreset', 'Moje animace##edPreset:' .. myId)
check(rt.presetId == myId, 'own preset chosen again')

-- export / import (buttons in Nastavení): the exported text of the own preset imports as a new preset, which the
-- editor then shows and can delete; bad text is refused with a reason
local text = presets.export(myId)
check(text and text:find('LEDCONTROL-PRESET 1 ', 1, true) == 1, 'export: preset as one line of text')
local importedId = presets.import(text)
rt.setPreset(importedId)
tabFrame(1)
check(importedId ~= myId and #presets.user == 2 and presets.get(importedId).name == 'Moje animace (2)'
  and has(texts(), 'Moje animace (2)'), 'import: new preset, the car and the editor use it')
local bad, why = presets.import('nesmysl')
check(bad == nil and why and has(why, 'LEDCONTROL-PRESET'), 'import of bad text: refused with a reason')
click('edDelete')
click('Smazat?##edDeleteOk')
pickCombo('##edPreset', 'Moje animace##edPreset:' .. myId)
check(rt.presetId == myId and #presets.user == 1, 'imported preset deleted, own preset again')
check(styleDepth == 0, 'style colour pushes and pops balanced')

-- ---------------------------------------------------------------- new custom animation

t = texts()
check(has(t, 'Vyberte…') and has(t, 'Nová animace##edScNew'), 'no animation yet: the picker asks to choose one')
check(not has(t, '##edCell') and not has(t, 'Uložit##edSave'), 'no animation yet: nothing else below the picker')
check(has(hoverTexts('(?)'), 'kreslený po snímcích'), 'Animace: explained in the (?) tooltip')
click('Nová animace##edScNew')
tabFrame(1)
local work, cur, dirty, sel, nFrames = peek()
check(sel and sel:match('^custom:') and rt.presetId == myId, 'new animation: custom scenario in the own preset')
local look = storedLook(sel)
check(look and look.p == 'frames' and look.g[1].n == 15 and look.g[2].n == 3 and look.g[3].n == 3
  and look.g[1].f[1] == string.rep('0', 15) and #look.g[1].f == 1, 'new animation: one frame per group, all cells off, stored')
check(presets.get(myId).scenarios[sel].name == 'Vlastní animace 1', 'new animation: named "Vlastní animace 1"')
check(work and nFrames == 1 and cur == 1 and not dirty, 'new animation: clean working copy')
t = texts()
check(has(t, 'Nová animace „Vlastní animace 1“'), 'new animation: said so')
local pMain, pLeft, pRight = t:find('Řada otáček', 1, true), t:find('Levé', 1, true), t:find('Pravé', 1, true)
check(pMain and pLeft and pRight and pMain < pLeft and pLeft < pRight and has(t, '##edCell3_3'),
  'grid: one row per LED group with its name, in real order')
check(has(hoverTexts('Řada otáček'), '15 diod') and has(hoverTexts('Levé'), '3 diody'), 'grid: LED count in the tooltip')
check(has(t, 'Kdy: rychlost < 60 km/h'), 'custom animation: its condition is shown')
check(has(hoverTexts('(?)'), 'kartě Scénáře'), 'custom animation: where to change the condition (tooltip)')
check(not has(t, 'neuloženo'), 'clean copy: no "neuloženo"')
check(U.flags['Zahodit##edDiscard'] == DISABLED, 'clean copy: Zahodit disabled')
check(has(t, 'icon:edScDel'), 'custom animation: delete icon shown')
check(U.flags.edDelFrame == DISABLED and U.flags.edLeft == DISABLED and U.flags.edRight == DISABLED
  and U.flags.edAdd == 0 and U.flags.edDup == 0, 'one frame: delete / move disabled, add / duplicate enabled')

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
check(U.flags['Zahodit##edDiscard'] == 0, 'painted: Zahodit enabled')
check(editor().unsaved(), 'painted: the editor reports unsaved edits (not in an export yet)')

-- the colour row edits the chosen palette brush: colour button + quick picks
t = texts()
check(has(t, 'colour:##edPal1') and not has(t, 'colour:##edPal3'), 'colour row: only the chosen brush colour')
U.pick = { ['##edPal3'] = { 0, 1, 0 } }
tabFrame(1)
U.pick = nil
check(peek().palette[3] == '#0000FF', 'colour row: another palette colour is not edited')
click('##edBrush3')
check(select(6, peek()) == 5, 'clicking a palette brush selects it')
check(has(texts(), 'colour:##edPal3'), 'colour row follows the brush')
U.pick = { ['##edPal3'] = { 0, 0, 1 } }
tabFrame(1)
U.pick = nil
work = peek()
check(work.palette[3] == '#0000FF', 'palette colour 3 edited (' .. tostring(work.palette[3]) .. ')')
tabFrame(5)
check(peek().palette[3] == '#0000FF', 'palette colour stays as picked over frames')
click('##sw_##edPal3_1')
check(peek().palette[3] == '#FF0000', 'quick pick sets a colour that stays true (' .. peek().palette[3] .. ')')
U.pick = { ['##edPal3'] = { 0, 0, 1 } }
tabFrame(1)
U.pick = nil
click('##edCell1_1')
check(peek().g[1].f[1] == '311110000000000', 'click paints one cell')
click('##edBrush.')
check(has(texts(), 'průhledná'), 'transparent brush: the colour row says what it does')
click('##edCell2_1')
check(peek().g[2].f[1] == '.00', 'transparent brush paints "."')
click('##edBrush0')
click('##edCell2_1')
check(peek().g[2].f[1] == '000', 'off brush paints "0"')
check(has(hoverTexts('##edBrush0'), 'Zhasnuto'), 'brush cells have tooltips')

-- ---------------------------------------------------------------- frames

click('edDup')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 2 and cur == 2 and work.g[1].f[2] == work.g[1].f[1] and #work.g[2].f == 2,
  'Duplikovat: copy of the frame after it, in every group')
tabFrame(1)
check(U.flags.edDelFrame == 0 and U.flags.edLeft == 0 and U.flags.edRight == DISABLED,
  'two frames, second chosen: delete and left enabled, right disabled')
for k = 1, 5 do click('##edCell1_' .. k) end
click('##edBrush1')
for k = 11, 15 do click('##edCell1_' .. k) end
check(peek().g[1].f[2] == '000000000011111', 'frame 2 painted')
click('edAdd')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 3 and cur == 3 and work.g[1].f[3] == string.rep('0', 15) and work.g[3].f[3] == '000',
  'Přidat snímek: empty frame after the current one')
click('edLeft')
work, cur = peek()
check(cur == 2 and work.g[1].f[2] == string.rep('0', 15) and work.g[1].f[3] == '000000000011111',
  'move left: frames swapped, selection follows')
click('edRight')
work, cur = peek()
check(cur == 3 and work.g[1].f[3] == string.rep('0', 15), 'move right: back')
click('edDelFrame')
work, cur, dirty, sel, nFrames = peek()
check(nFrames == 2 and cur == 2 and #work.g[1].f == 2 and #work.g[2].f == 2, 'Smazat snímek: frame removed everywhere')
click('1##edFrame1')
check(select(2, peek()) == 1, 'frame strip: click selects a frame')
t = texts()
check(U.accented['1##edFrame1'] and not U.accented['2##edFrame2'], 'frame strip: the chosen frame is highlighted')
check(has(hoverTexts('edAdd'), 'Přidat snímek'), 'frame icons have tooltips')
click('Vyplnit##edFill')
check(peek().g[1].f[1] == string.rep('1', 15), 'Vyplnit fills the frame with the brush')
-- many frames: the strip wraps, the icons are drawn once and stay
for _ = 1, 8 do click('edAdd') end
t = texts()
check(select(5, peek()) == 10 and has(t, '10##edFrame10') and count(t, 'icon:edAdd') == 1,
  'ten frames: all shown, the icons once')
click('Zahodit##edDiscard')
work, cur, dirty, sel, nFrames = peek()
check(not dirty and nFrames == 1 and work.g[1].f[1] == string.rep('0', 15), 'Zahodit: back to the stored look')
check(has(texts(), 'zahozené'), 'Zahodit: said so')

-- paint the two frames again (as above), then fps and save
local function paintAnimation()
  click('##edBrush3')
  U.pick = { ['##edPal3'] = { 0, 0, 1 } }
  tabFrame(1)
  U.pick = nil
  click('##edBrush1')
  for k = 2, 5 do click('##edCell1_' .. k) end
  click('##edBrush3')
  click('##edCell1_1')
  click('edAdd')
  click('##edBrush1')
  for k = 11, 15 do click('##edCell1_' .. k) end
end
paintAnimation()
work = peek()
check(work.g[1].f[1] == '311110000000000' and work.g[1].f[2] == '000000000011111', 'animation painted again')
U.slide = { ['##edFps'] = 6 }
tabFrame(1)
U.slide = nil
check(peek().fps == 6 and select(5, peek()) == 2, 'fps slider: 2 frames at 6 frames/s')
check(has(hoverTexts('##dummy'), 'Náhled animace'), 'live preview next to the speed, with a tooltip')

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
t = texts()
check(not select(3, peek()) and not has(t, 'neuloženo') and not editor().unsaved(), 'saved: "neuloženo" gone')
check(has(t, 'Uloženo do „Moje animace“'), 'saved: said where')

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
check(tested and has(texts(), 'Test na autě: 5 s'), 'Test na autě: saved and shown on the car')
tabFrame(330)
check(not lit(slotColour(1)) and not lit(slotColour(15)), 'Test na autě: stops after 5 s')
rt.setMode(2)
click('Test na autě##edTest')
check(has(texts(), 'testovací vzor'), 'Test na autě with a Diody test pattern: explained')
rt.setMode(0)
tabFrame(2)

-- ---------------------------------------------------------------- scenario picker and switches

local customLabel = 'Vlastní animace 1 – snímky##edSc:' .. sel
pickCombo('##edScenario', 'Omezovač otáček##edSc:limiter')
t = texts()
check(select(4, peek()) == 'limiter' and has(t, 'vzor „Bliká“') and not has(t, 'neuloženo'),
  'built-in scenario: only shown, nothing counts as unsaved before painting')
check(has(hoverTexts('(?)'), 'nahradíte'), 'built-in scenario: saving replaces its pattern (tooltip)')
check(storedLook('limiter') == nil, 'built-in scenario: nothing stored before Uložit')
check(not has(t, 'icon:edScDel'), 'built-in scenario: no delete icon')
click('##edBrush1')
click('##edCell1_3')
check(has(texts(), 'neuloženo'), 'built-in scenario: painting makes it unsaved')
-- the car's preset changed outside the editor (header combo) with unsaved edits: they are dropped with a message
U.openCombo = '##preset'
click('GT3 styl##hdrPreset:builtin:gt3')
U.openCombo = nil
t = texts()
check(rt.presetId == 'builtin:gt3' and has(t, 'Preset se změnil – neuložené změny zahozené'),
  'header preset switch: edits dropped, said so')
U.openCombo = '##preset'
click('Moje animace##hdrPreset:' .. myId)
U.openCombo = nil
check(rt.presetId == myId and select(4, peek()) == 'limiter', 'header preset switch back: own preset')
pickCombo('##edScenario', 'Modrá vlajka (pouští rychlejší auto)##edSc:flagBlue')
check(has(hoverTexts('Řada otáček'), 'sem nesvítí') and not has(hoverTexts('Levé'), 'sem nesvítí'),
  'side scenario: main row marked as not targeted (grey name, tooltip)')
pickCombo('##edScenario', customLabel)
work = peek()
check(select(4, peek()) == sel and work.g[1].f[2] == '000000000011111', 'custom animation picked again from the stored look')
click('Zapnutý##edOn')
check(presets.get(myId).scenarios[sel].on == false and has(hoverTexts('(?)'), 'jen při Testu na autě'),
  'switch: scenario off, the tooltip says when it still shows')
click('Zapnutý##edOn')
check(presets.get(myId).scenarios[sel].on == true, 'switch: scenario on again')

-- ---------------------------------------------------------------- layout mismatch and rescaling

rt.editScenario(sel, 'look', { p = 'frames', fps = 2, palette = { '#FF0000', '#00FF00', '#0000FF', '#FFFFFF', '#FFFF00' },
  g = { { n = 5, f = { '12345' } } } })
tabFrame(2)
work, cur, dirty = peek()
check(work.g[1].n == 5 and work.g[2].f[1] == '...' and not dirty,
  'stored look for 5 LEDs loaded, missing groups transparent, not "neuloženo"')
click('edAdd')
work = peek()
check(work.g[1].f[2] == '00000' and work.g[2].f[2] == '...' and work.g[3].f[2] == '...',
  'Přidat snímek: groups the animation leaves transparent stay transparent')
click('edDelFrame')
work, cur, dirty = peek()
check(#work.g[1].f == 1 and cur == 1 and not dirty, 'frame added and removed again: back to the stored look')
t = texts()
check(has(t, 'Řada otáček: snímky pro 5 diod, auto má 15.') and has(t, 'Přizpůsobit##edFit'),
  'mismatch: one short warning line and the Přizpůsobit button')
check(has(hoverTexts('(?)'), 'přepočítají samy'), 'mismatch: the tooltip says the car rescales meanwhile')
env.car.speedKmh = 30
frame(3)
check(isRed(slotColour(1)) and isRed(slotColour(3)) and isBlue(slotColour(8)) and isWhite(slotColour(11)),
  'car: 5 cells rescaled to 15 by the engine (rescale on)')
click('Přizpůsobit##edFit')
work, cur, dirty = peek()
check(work.g[1].n == 15 and work.g[1].f[1] == '111222333444555' and dirty, 'Přizpůsobit: nearest-centre resampling to 15')
check(not has(texts(), 'Přizpůsobit##edFit'), 'after fitting: no warning')
click('Přepočítat##edRescale')
check(peek().rescale == false and has(hoverTexts('(?)'), 'Bez přepočtu tam tento scénář nesvítí'),
  'rescale switched off, explained in the tooltip')
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
check(has(t, 'snímky pro 15 diod, auto má 10 – nesvítí.'), 'other car: mismatch warning, the scenario does not show')
check(has(hoverTexts('(?)'), 'Bez přepočtu (Jiný počet diod)'), 'other car: what to do, in the tooltip')
check(#rt.compiled.warnings > 0, 'other car: the engine reports the mismatch too')
click('Přizpůsobit##edFit')
check(peek().g[1].n == 10, 'other car: fitted to 10 LEDs')

-- the colour picker keeps the exact value the user picked (it is not snapped back to the 8-bit stored hex every
-- frame, which made the Diody picker jump), also after Uložit reloads the working copy from the stored look
click('##edBrush2')
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
click('edScDel')
t = texts()
check(presets.get(myId).scenarios[sel] ~= nil and has(t, 'Smazat?##edScDelOk') and not has(t, 'icon:edScDel'),
  'delete animation: first click only asks')
tabFrame(300)
check(not has(texts(), 'Smazat?##edScDelOk'), 'delete animation: question expires')
click('edScDel')
click('Smazat?##edScDelOk')
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
click('Nová animace##edScNew')
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
-- tooltips shown (help marks, an icon) and a long frame strip with the colour row of a palette brush
for _ = 1, 9 do click('edAdd') end
click('##edBrush3')
U.hover = '(?)'
grown = measure(300)
check(grown < 4, string.format('no per-frame allocation with tooltips and 11 frames (%.2f KB / 300 frames)', grown))
U.hover = 'edAdd'
grown = measure(300)
check(grown < 4, string.format('no per-frame allocation with an icon tooltip (%.2f KB / 300 frames)', grown))
U.hover = nil
env.windowOpen = false
check(app.safety.uiError == nil, 'no UI error in the editor (' .. tostring(app.safety.uiError) .. ')')

return H.finish('test_tab_editor')
