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
-- (the section "Pořadí a skupiny" is collapsed in the game; the mock draws every section open)

local t = texts('Diody')
check(t:find('1  RPM_LED_3', 1, true) and t:find('Pořadí a skupiny', 1, true), 'map: section lists the LEDs in order')
check(not t:find('neuloženo', 1, true) and not t:find('Automaticky##mapAuto', 1, true),
  'map: nothing unsaved, no way back to automatic before a manual map exists')
-- Uložit / Zahodit do nothing before an edit
clickIn('Diody', 'Uložit##mapSave')
frame(3)
check(not rt.layout.manual, 'map: Uložit without an edit keeps the automatic order')
clickIn('Diody', '↓##mapDown1')
check(texts('Diody'):find('neuloženo', 1, true) ~= nil, 'map: an edit shows "neuloženo"')
clickIn('Diody', '×##mapDel21')
clickIn('Diody', 'Uložit##mapSave')
frame(3)
local lay = rt.layout
check(lay.manual and #lay.leds == 20 and lay.leds[1].name == 'RPM_LED_1' and lay.leds[2].name == 'RPM_LED_3',
  'map: moved and removed LED saved as the car map')
check(lay.signature == '15+3+2', 'map: groups kept (' .. lay.signature .. ')')
local profile = require('src/store').loadCar('test_formula')
check(profile.map and #profile.map.leds == 20, 'map: saved in the car profile')
t = texts('Diody')
check(t:find('Pořadí a skupiny (ruční)', 1, true) and t:find('Automaticky##mapAuto', 1, true) and
  not t:find('neuloženo', 1, true), 'map: section says the order is manual, offers Automaticky')
check(t:find('1  RPM_LED_1', 1, true) ~= nil, 'map: the section follows the saved layout')

-- Zahodit drops an edit
clickIn('Diody', '↓##mapDown1')
clickIn('Diody', 'Zahodit##mapCancel')
frame(3)
t = texts('Diody')
check(t:find('1  RPM_LED_1', 1, true) and not t:find('neuloženo', 1, true) and rt.layout.leds[1].name == 'RPM_LED_1',
  'map: Zahodit drops the edit')

-- mesh picker adds a mesh
clickIn('Diody', 'Přidat diody ručně##mapPick')
env.ui.type = { ['Hledat##meshFilter'] = 'flag_r3' }
frame(1)
t = texts('Diody')
check(t:find('FLAG_R3', 1, true) ~= nil and t:find('1 díl', 1, true) ~= nil, 'map: mesh list filtered')
local label
for _, s in ipairs(env.ui.texts) do if s:find('^FLAG_R3') then label = s end end
clickIn('Diody', label)
clickIn('Diody', 'Uložit##mapSave')
frame(3)
local picked
for _, led in ipairs(rt.layout.leds) do if led.name == 'FLAG_R3' then picked = led end end
check(#rt.layout.leds == 21 and picked and picked.group == 1 and picked.id == 16,
  'map: picked mesh added at the end of group 1 (main row)')
clickIn('Diody', 'Skrýt##mapPickHide')
check(texts('Diody'):find('Přidat diody ručně', 1, true) ~= nil, 'map: Skrýt hides the mesh list')
-- reverse a whole group in one click
clickIn('Diody', 'Obrátit##mapRev2')
clickIn('Diody', 'Uložit##mapSave')
frame(3)
local g2 = rt.layout.groups[2]
check(rt.layout.leds[g2.leds[1]].name == 'FLAG_L3' and rt.layout.leds[g2.leds[3]].name == 'FLAG_L1',
  'map: Obrátit reverses the group')
-- rename a group and change its role
env.ui.type = { ['##mapGroupName2'] = 'Vlajky' }
frame(1)
env.ui.openCombo = '##mapGroupRole2'
clickIn('Diody', 'další řada##role_other')
env.ui.openCombo = nil
clickIn('Diody', 'Uložit##mapSave')
frame(3)
check(rt.layout.groups[2].name == 'Vlajky' and rt.layout.groups[2].role == 'other', 'map: group name and role saved')
-- move an LED to another group
local first = rt.layout.leds[1].name
env.ui.openCombo = '##mapGroup1'
clickIn('Diody', 'Pravé##pickGroup3')
env.ui.openCombo = nil
clickIn('Diody', 'Uložit##mapSave')
frame(3)
local moved
for _, led in ipairs(rt.layout.leds) do if led.name == first then moved = led end end
check(moved and moved.group == 3 and rt.layout.signature == '15+3+3' and rt.layout.manual,
  'map: an LED moved to another group (' .. rt.layout.signature .. ')')
clickIn('Diody', 'Automaticky##mapAuto')
frame(3)
check(not rt.layout.manual and #rt.layout.leds == 21 and rt.layout.signature == '15+3+3', 'map: automatic detection again')

-- a car without LEDs offers manual picking: the list opens inline, a picked mesh becomes the car's LED
H.emptyCar()
env.mesh('DASH_LAMP', env.node('DASH', env.root, 0, 0.7, 0.4), { centre = { 0, 0.05, 0 } })
env.storage = {}
loadApp()
frame(3)
rt = app.runtime
t = texts('Diody')
check(rt.state == 'noleds' and t:find('Vybrat diody ručně', 1, true) ~= nil, 'no LEDs: manual picking offered')
check(not t:find('##mapPickHide', 1, true) and not t:find('Uložit##mapSave', 1, true),
  'no LEDs: one line, the list opens only on request')
clickIn('Diody', 'Vybrat diody ručně##mapStart')
t = texts('Diody')
check(t:find('##mapPickHide', 1, true) and t:find('DASH_LAMP', 1, true) and not t:find('Vybrat diody ručně', 1, true),
  'no LEDs: Vybrat diody ručně shows the mesh list at once')
label = nil
for _, s in ipairs(env.ui.texts) do if s:find('^DASH_LAMP') then label = s end end
clickIn('Diody', label)
clickIn('Diody', 'Uložit##mapSave')
frame(3)
check(rt.state == 'run' and #rt.layout.leds == 1 and rt.layout.manual, 'no LEDs: the picked mesh is the car\'s LED now')

return H.finish('test_map')
