-- LedControl: tab Nastavení (default preset / method for a new car, hotkeys, colour guard, export / import, delete
-- data, defaults with a second click, version line), brightness through runtime (its slider is in the Diody tab) and
-- the diagnostics copy (tab Světla).

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near, frame = H.env, H.check, H.near, H.frame

local app
local function loadApp() app = H.loadApp(); return app end
local function clickIn(tab, label)
  env.windowOpen = true
  env.ui.tab = tab
  env.ui.click = label
  frame(1)
  env.ui.click = nil
end
local function texts(tab)
  env.windowOpen = true
  env.ui.tab = tab
  env.ui.record = true
  env.ui.texts = {}
  frame(1)
  env.ui.record = false
  return table.concat(env.ui.texts, '\n')
end

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 10350
loadApp()
frame(3)
local rt, S = app.runtime, app.config.S

local color = require('src/color')

-- the first screen: sections and the version line, no brightness slider any more (it is in the Diody tab)
local first = texts('Nastavení')
check(first:find('Nové auto', 1, true) and first:find('Klávesy', 1, true) and first:find('Barvy', 1, true)
  and first:find('Sdílení', 1, true) and first:find('Data', 1, true) and first:find('LedControl ' .. require('src/diag').VERSION, 1, true),
  'settings: sections Nové auto, Klávesy, Barvy, Sdílení, Data and the version line')
check(not first:find('Jas diod', 1, true), 'settings: brightness is not in Nastavení')

-- brightness (set by the Diody tab through runtime) rewrites the LEDs
rt.setIntensity(40)
frame(2)
local r, g = env.seen(env.formula.hr[env.formula.slot[1]])
check(S.intensity == 40 and near(g, 40), 'settings: brightness rewrites the LEDs')

-- colour guard slider: 0..100 % -> config colourGuard 0..1, the LEDs are written again with the new hues
for i = 1, rt.n do rt.setManual(i, color.pack(0.5, 1, 0)) end   -- a mixed colour (the weaker channel is guarded)
frame(2)
env.windowOpen, env.ui.tab = true, 'Nastavení'
env.ui.slide = { ['##colourGuard'] = 0 }
frame(1)
env.ui.slide = nil
frame(2)
local r0 = env.seen(env.formula.hr[env.formula.slot[1]])
check(S.colourGuard == 0 and near(r0, 20, 0.2), string.format('colour guard 0 %%: red stays half of green (%.2f)', r0))
env.ui.slide = { ['##colourGuard'] = 99.6 }
frame(1)
env.ui.slide = nil
frame(2)
local r1, g1 = env.seen(env.formula.hr[env.formula.slot[1]])
check(S.colourGuard == 1 and r1 < 10 and near(g1, 40), string.format('colour guard 100 %%: the weaker red is pushed down (%.2f)', r1))
env.ui.slide = { ['##colourGuard'] = 70 }
frame(1)
env.ui.slide = nil
check(S.colourGuard == 0.7, 'colour guard back to 70 %')
rt.setMode(0)
frame(2)

-- hotkey binding buttons drawn
env.hotkeyControlDrawn = false
frame(1)
check(env.hotkeyControlDrawn, 'settings: hotkey binding buttons drawn')

-- default method for cars without a profile
clickIn('Nastavení', 'B překreslení##defaultMethod')
frame(3)
check(S.method == 2 and app.takeover.method == 2, 'settings: default method applied to a car without its own')
clickIn('Nastavení', 'A kopie##defaultMethod')
frame(3)
check(S.method == 1 and app.takeover.method == 1, 'settings: default method back to A')

-- default preset
env.ui.openCombo = '##defaultPreset'
clickIn('Nastavení', 'Minimální##defp:builtin:minimal')
env.ui.openCombo = nil
check(S.defaultPreset == 'builtin:minimal', 'settings: default preset chosen')
check(texts('Nastavení'):find('Minimální', 1, true) ~= nil, 'settings: the combo shows the chosen default preset')
env.ui.openCombo = '##defaultPreset'
clickIn('Nastavení', 'Automaticky##defp_auto')
env.ui.openCombo = nil
check(S.defaultPreset == 'auto', 'settings: default preset back to automatic')
env.ui.openCombo = '##defaultPreset'
clickIn('Nastavení', 'Minimální##defp:builtin:minimal')
env.ui.openCombo = nil

-- export / import through the clipboard
clickIn('Nastavení', 'Kopírovat preset##export')
check(env.clipboard and env.clipboard:find('LEDCONTROL-PRESET 1 ', 1, true) == 1, 'settings: preset exported to the clipboard')
local before = #app.presets.user
check(texts('Nastavení'):find('je ve schránce', 1, true) ~= nil, 'settings: export confirmed under the buttons')
clickIn('Nastavení', 'Vložit preset##import')
check(#app.presets.user == before + 1 and rt.presetId == app.presets.user[#app.presets.user].id,
  'settings: imported preset used by this car')
env.clipboard = 'nesmysl'
clickIn('Nastavení', 'Vložit preset##import')
check(texts('Nastavení'):find('LEDCONTROL-PRESET', 1, true) ~= nil, 'settings: import failure explained')
-- "Kopírovat diagnostiku" lives in the Diagnostika sections (Diody, Světla)
clickIn('Světla', 'Kopírovat diagnostiku##ldiag_copy')
check(env.clipboard:find('diagnostika', 1, true) ~= nil, 'settings: diagnostics copied')

-- delete saved data needs a second click
rt.editScenario('limiter', 'on', false)
check(#app.presets.user >= 1, 'setup: user presets exist')
local userCount = #app.presets.user
clickIn('Nastavení', 'Smazat uložená data##delete')
check(#app.presets.user == userCount, 'delete: first click only asks')
check(texts('Nastavení'):find('Opravdu smazat? Klikněte znovu##delete', 1, true) ~= nil, 'delete: the button asks again')
for _ = 1, 300 do frame(1) end
check(texts('Nastavení'):find('Smazat uložená data##delete', 1, true) ~= nil, 'delete: the question goes away after a few seconds')
clickIn('Nastavení', 'Smazat uložená data##delete')
clickIn('Nastavení', 'Opravdu smazat? Klikněte znovu##delete')
frame(3)
check(#app.presets.user == 0 and rt.presetId:match('^builtin:'), 'delete: user presets gone, car back on a built-in')
check(texts('Nastavení'):find('Uložená data jsou smazaná.', 1, true) ~= nil, 'delete: confirmed by a message')

-- restore defaults needs a second click
local L = require('src/lights')
app.config.set('intensity', 70)
app.config.set('colourGuard', 0.2)
app.config.set('method', 2)
app.config.set('defaultPreset', 'builtin:minimal')
app.config.set('master', true)
L.setOn('hazardStop', false)
clickIn('Nastavení', 'Výchozí nastavení##defaults')
check(S.intensity == 70, 'defaults: first click only asks')
clickIn('Nastavení', 'Opravdu obnovit? Klikněte znovu##defaults')
frame(3)
check(S.intensity == 25 and S.defaultPreset == 'auto' and S.method == 1, 'defaults: settings restored')
check(S.colourGuard == 0.7 and S.master == true, 'defaults: colour guard restored, master switch kept')
check(L.byId.hazardStop.on, 'defaults: light scenarios restored')
check(rt.presetId == 'builtin:f1', 'defaults: a car without its own choice follows the default preset again (' .. rt.presetId .. ')')
check(texts('Nastavení'):find('Nastavení je výchozí.', 1, true) ~= nil, 'defaults: confirmed by a message')

-- allocation with the settings tab open
H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
loadApp()
env.windowOpen, env.ui.tab = true, 'Nastavení'
frame(120)
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
frame(300)
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
env.windowOpen = false
print(string.format('allocation with tab Nastavení open: %.2f KB / 300 frames', grown))
check(grown < 4, string.format('no per-frame allocation with Nastavení open (%.2f KB / 300 frames)', grown))

return H.finish('test_settings')
