-- LedControl: tab Nastavení (brightness, default method / preset, hotkeys, export / import, delete data, defaults)
-- and the Diody tab's manual LED order / mesh picker.

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

-- brightness from the settings tab
env.windowOpen, env.ui.tab = true, 'Nastavení'
env.ui.slide = { ['##intensitySettings'] = 40 }
frame(1)
env.ui.slide = nil
frame(2)
local r, g = env.seen(env.formula.hr[env.formula.slot[1]])
check(S.intensity == 40 and near(g, 40), 'settings: brightness rewrites the LEDs')

-- hotkey binding buttons drawn
env.hotkeyControlDrawn = false
frame(1)
check(env.hotkeyControlDrawn, 'settings: hotkey binding buttons drawn')

-- default method for cars without a profile
clickIn('Nastavení', 'B – překreslení##defaultMethod')
frame(3)
check(S.method == 2 and app.takeover.method == 2, 'settings: default method applied to a car without its own')
clickIn('Nastavení', 'A – stínová kopie##defaultMethod')
frame(3)

-- default preset
env.ui.openCombo = '##defaultPreset'
clickIn('Nastavení', 'Minimální')
env.ui.openCombo = nil
check(S.defaultPreset == 'builtin:minimal', 'settings: default preset chosen')

-- export / import through the clipboard
clickIn('Nastavení', 'Kopírovat aktuální preset do schránky')
check(env.clipboard and env.clipboard:find('LEDCONTROL-PRESET 1 ', 1, true) == 1, 'settings: preset exported to the clipboard')
local before = #app.presets.user
clickIn('Nastavení', 'Vložit preset ze schránky')
check(#app.presets.user == before + 1 and rt.presetId == app.presets.user[#app.presets.user].id,
  'settings: imported preset used by this car')
env.clipboard = 'nesmysl'
clickIn('Nastavení', 'Vložit preset ze schránky')
check(texts('Nastavení'):find('LEDCONTROL-PRESET', 1, true) ~= nil, 'settings: import failure explained')
clickIn('Nastavení', 'Kopírovat diagnostiku do schránky')
check(env.clipboard:find('diagnostika', 1, true) ~= nil, 'settings: diagnostics copied')

-- delete saved data needs a second click
rt.editScenario('limiter', 'on', false)
check(#app.presets.user >= 1, 'setup: user presets exist')
local userCount = #app.presets.user
clickIn('Nastavení', 'Smazat uložená data##delete')
check(#app.presets.user == userCount, 'delete: first click only asks')
clickIn('Nastavení', 'Opravdu smazat vše? Klikněte znovu##delete')
frame(3)
check(#app.presets.user == 0 and rt.presetId:match('^builtin:'), 'delete: user presets gone, car back on a built-in')

-- restore defaults needs a second click
app.config.set('intensity', 70)
clickIn('Nastavení', 'Obnovit výchozí nastavení##defaults')
check(S.intensity == 70, 'defaults: first click only asks')
clickIn('Nastavení', 'Opravdu obnovit? Klikněte znovu##defaults')
frame(3)
check(S.intensity == 25 and S.defaultPreset == 'auto' and S.method == 1, 'defaults: settings restored')

-- ---------------------------------------------------------------- manual LED order from the Diody tab

clickIn('Diody', 'Upravit pořadí a skupiny diod')
local t = texts('Diody')
check(t:find('1. RPM_LED_3', 1, true) and t:find('Pořadí a výběr diod', 1, true), 'map: editor lists the LEDs in order')
clickIn('Diody', 'Dolů##mapDown1')
clickIn('Diody', 'Odebrat##mapDel21')
clickIn('Diody', 'Uložit pořadí')
frame(3)
local lay = rt.layout
check(lay.manual and #lay.leds == 20 and lay.leds[1].name == 'RPM_LED_1' and lay.leds[2].name == 'RPM_LED_3',
  'map: moved and removed LED saved as the car map')
check(lay.signature == '15+3+2', 'map: groups kept (' .. lay.signature .. ')')
local profile = require('src/store').loadCar('test_formula')
check(profile.map and #profile.map.leds == 20, 'map: saved in the car profile')

-- mesh picker adds a mesh
clickIn('Diody', 'Upravit pořadí a skupiny diod')
clickIn('Diody', 'Načíst meshe z kokpitu')
env.ui.type = { ['Hledat##meshFilter'] = 'flag_r3' }
frame(1)
t = texts('Diody')
check(t:find('FLAG_R3', 1, true) ~= nil and t:find('1 meshů', 1, true) ~= nil, 'map: mesh list filtered')
local label
for _, s in ipairs(env.ui.texts) do if s:find('^FLAG_R3') then label = s end end
clickIn('Diody', label)
clickIn('Diody', 'Uložit pořadí')
frame(3)
local picked
for _, led in ipairs(rt.layout.leds) do if led.name == 'FLAG_R3' then picked = led end end
check(#rt.layout.leds == 21 and picked and picked.group == 1 and picked.id == 16,
  'map: picked mesh added at the end of group 1 (main row)')
clickIn('Diody', 'Zpět na automatické hledání')
frame(3)
check(not rt.layout.manual and #rt.layout.leds == 21 and rt.layout.signature == '15+3+3', 'map: automatic detection again')

-- a car without LEDs offers manual picking
H.emptyCar()
env.storage = {}
loadApp()
frame(3)
t = texts('Diody')
check(t:find('Vybrat diody ručně', 1, true) ~= nil, 'no LEDs: manual picking offered')

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
check(grown < 4, string.format('no per-frame allocation with Nastavení open (%.2f KB / 300 frames)', grown))

return H.finish('test_settings')
