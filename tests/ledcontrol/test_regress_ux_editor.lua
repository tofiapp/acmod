-- LedControl: tab Editor regressions (review-ux): browsing scenarios in the editor without editing anything says
-- nothing about dropped edits (and does when something was edited), Test na autě with the master switch off saves
-- nothing, Test na autě while running on a built-in preset, the rev limiter look afterwards.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions used by the editor grid
-- (the shared mock stays untouched: these are the calls the grid needs, with the signatures of the official apps)

local R1, R2 = vec2(0, 0), vec2(22, 22)
ui.HoveredFlags = { None = 0, AllowWhenBlockedByActiveItem = 32 }
ui.invisibleButton = function (label) U.last = label; return U.click == label end
ui.itemRect = function () return R1, R2 end
ui.itemActive = function () return U.active ~= nil and U.active == U.last end
ui.itemClicked = function () return U.click ~= nil and U.click == U.last end
ui.mouseDown = function () return U.mouseDown == true end
ui.dummy = function () U.last = '##dummy' end
ui.drawRect = function () end
local styleDepth = 0
ui.pushStyleColor = function () styleDepth = styleDepth + 1 end
ui.popStyleColor = function () styleDepth = styleDepth - 1 end
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
local function lit(r, g, b) return r + g + b > 0.5 end
-- ================= review-ux: browsing scenarios in the editor without editing anything
H.formulaCar(1)
env.storage = {}
loadApp()
frame(3)
tabFrame(2)
local scIdOf = function (name) for _, e in ipairs(presets.effective(rt.preset())) do if e.name == name then return e.id end end end
local a, b = scIdOf('Pit limiter zapnutý'), scIdOf('Omezovač otáček')
pickCombo('##edScenario', 'Pit limiter zapnutý##edSc:' .. a)
local _, _, dirty = peek()
print('after only selecting "Pit limiter zapnutý": dirty =', dirty)
pickCombo('##edScenario', 'Omezovač otáček##edSc:' .. b)
local t = texts()
print('message shown:', has(t, 'Neuložené změny zahozené.'))
check(not has(t, 'Neuložené změny zahozené.'), 'no "unsaved changes dropped" message when nothing was edited')
-- the same switch after painting a cell: now the message is due (so the check above looks for the right text)
click('##edBrush1')
click('##edCell1_3')
pickCombo('##edScenario', 'Pit limiter zapnutý##edSc:' .. a)
t = texts()
check(has(t, 'Neuložené změny zahozené.') and not select(3, peek()), 'edited, then another scenario: edits dropped, said so')
pickCombo('##edScenario', 'Omezovač otáček##edSc:' .. b)
-- the Test na autě button with the master switch off on a built-in preset
app.config.set('master', false)
frame(3)
local before = rt.presetId
click('Test na autě##edTest')
t = texts()
print('preset before:', before, ' after Test (master off):', rt.presetId)
print('copy message visible:', has(t, 'kopii'), ' blocked message visible:', has(t, 'Diody nejsou převzaté'))
local look = storedLook(b)
print('stored look of "Omezovač otáček" in', rt.presetId, ':', look and look.p, look and look.g and look.g[1] and look.g[1].f[1])
check(rt.presetId == before and has(t, 'Diody nejsou převzaté') and not (look and look.p == 'frames'),
  'Test na autě with the master switch off: explained, nothing saved, no copy of the built-in preset')
-- master on: same click while running
H.formulaCar(1)
env.storage = {}
loadApp()
frame(3)
tabFrame(2)
pickCombo('##edScenario', 'Omezovač otáček##edSc:' .. b)
click('Test na autě##edTest')
frame(2)
t = texts()
look = storedLook(b)
print('master on: preset now', rt.presetId, ' look', look and look.p, look and look.g and look.g[1] and look.g[1].f[1])
print('messages: copy', has(t, 'kopii'), ' test', has(t, 'Test na autě: 5 s.'))
check(rt.presetId == 'builtin:f1' and has(t, 'Test na autě: 5 s.') and not (look and look.p == 'frames'),
  'Test na autě on an unpainted built-in scenario: its own look is tested, nothing saved')
env.car.rpm = 13000
frame(30)
local anyLit = false
for s = 1, 15 do if lit(slotColour(s)) then anyLit = true end end
print('at the rev limiter after the Test ended: any main LED lit =', anyLit)
local afterTest = anyLit
rt.setPreset('builtin:f1'); frame(3)
anyLit = false
for s = 1, 15 do if lit(slotColour(s)) then anyLit = true end end
print('same rpm with the built-in F1 styl: any main LED lit =', anyLit)
check(afterTest and anyLit, 'rev limiter after the Test: the LEDs light as with the built-in preset')
check(styleDepth == 0, 'style colour pushes and pops balanced')
return H.finish('test_regress_ux_editor')
