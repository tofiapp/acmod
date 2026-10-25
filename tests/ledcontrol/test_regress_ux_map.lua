local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check = H.env, H.check
local frame, click = H.frame, H.click
-- a wheel with 5 LED clusters: RPM row 8, left column 2, right column 2, two lower rows of 3
H.baseCar(1)
env.carId = 'test_five'
local wheel = env.node('STEER_HR', env.root, 0, 0.7, 0.4)
local k = 0
local function led(x, y) k = k + 1; env.mesh('IND_' .. k, wheel, { centre = { x, y, 0 }, actsAsLED = true }) end
for i = 1, 8 do led((4.5 - i) * 0.01, 0.05) end
led(0.13, 0.03); led(0.13, 0.02)
led(-0.13, 0.03); led(-0.13, 0.02)
for i = 1, 3 do led((2 - i) * 0.01, -0.03) end
for i = 1, 3 do led((2 - i) * 0.01, -0.09) end
env.storage = {}
local app = H.loadApp()
frame(3)
local rt = app.runtime
print('auto layout:', #rt.layout.leds, 'LEDs, signature', rt.layout.signature, 'groups', #rt.layout.groups)
for gi, g in ipairs(rt.layout.groups) do print('  group', gi, g.name, g.role, #g.leds) end
-- user opens "Upravit pořadí a skupiny diod" and saves without changing anything
env.ui.tab = 'Diody'
click('Upravit pořadí a skupiny diod')
click('Uložit pořadí')
frame(3)
print('after Uložit pořadí:', #rt.layout.leds, 'LEDs, signature', rt.layout.signature)
check(#rt.layout.leds == 18, 'saving the unchanged order keeps all 18 LEDs (got ' .. #rt.layout.leds .. ')')
return H.finish('test_regress_ux_map')
