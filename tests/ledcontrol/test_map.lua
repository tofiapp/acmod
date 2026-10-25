-- LedControl: the Diody tab's manual LED order, groups and mesh picker (src/ui/led_map.lua).

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
loadApp()
frame(3)
local rt, S = app.runtime, app.config.S

-- ---------------------------------------------------------------- manual LED order from the Diody tab

clickIn('Diody', 'Upravit pořadí a skupiny diod')
local t = texts('Diody')
check(t:find('1. RPM_LED_3', 1, true) and t:find('Pořadí a výběr diod', 1, true), 'map: editor lists the LEDs in order')
clickIn('Diody', '↓##mapDown1')
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
check(t:find('FLAG_R3', 1, true) ~= nil and t:find('1 mesh', 1, true) ~= nil, 'map: mesh list filtered')
local label
for _, s in ipairs(env.ui.texts) do if s:find('^FLAG_R3') then label = s end end
clickIn('Diody', label)
clickIn('Diody', 'Uložit pořadí')
frame(3)
local picked
for _, led in ipairs(rt.layout.leds) do if led.name == 'FLAG_R3' then picked = led end end
check(#rt.layout.leds == 21 and picked and picked.group == 1 and picked.id == 16,
  'map: picked mesh added at the end of group 1 (main row)')
-- reverse a whole group in one click
clickIn('Diody', 'Upravit pořadí a skupiny diod')
clickIn('Diody', 'Obrátit pořadí##mapRev2')
clickIn('Diody', 'Uložit pořadí')
frame(3)
local g2 = rt.layout.groups[2]
check(rt.layout.leds[g2.leds[1]].name == 'FLAG_L3' and rt.layout.leds[g2.leds[3]].name == 'FLAG_L1',
  'map: Obrátit pořadí reverses the group')
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


return H.finish('test_map')
