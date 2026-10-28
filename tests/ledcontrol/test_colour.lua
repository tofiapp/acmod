-- Colour fidelity: pure default colours, the hue guard at high brightness, automatic brightness by time of day.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near, frame = H.env, H.check, H.near, H.frame

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
local app = H.loadApp()
frame(3)
local tk, color, S = app.takeover, require('src/color'), app.config.S
local col = rgb()

tk.emissiveOf(color.parse('#00FF40'), 50, col)
check(col.g == 50 and col.b / col.g < 0.06, string.format('guard: green with a little blue stays green at 50 (b %.2f)', col.b))
tk.emissiveOf(color.parse('#00FF40'), 10, col)
check(near(col.g, 10) and near(col.b, 10 * 0x40 / 255, 1e-6), 'guard: no change at low brightness')
tk.emissiveOf(color.parse('#00FF00'), 80, col)
check(col.r == 0 and col.g == 80 and col.b == 0, 'guard: a pure colour stays pure')
app.runtime.setBrightness('colourGuard', 0)
tk.emissiveOf(color.parse('#00FF40'), 50, col)
check(near(col.b, 50 * 0x40 / 255, 1e-6), 'guard off: linear')
app.runtime.setBrightness('colourGuard', 0.7)

-- default colours are pure: F1 zones, catalogue looks
local p = require('src/presets')
local f1 = p.BUILTIN[1].scenarios.shiftLights.look.zones
check(f1[2] == '#00FF00' and f1[6] == '#0000FF', 'F1 zones use pure green and blue')

-- automatic brightness by the time of day
app.runtime.setMode(5)
app.runtime.setBrightness('autoBrightness', true)
env.sim.timeHours = 22
frame(3)
check(near(env.seen(env.formula.hr.RPM_LED_1), S.intensityNight), 'auto brightness: night value at 22 h')
env.sim.timeHours = 12
frame(3)
check(near(env.seen(env.formula.hr.RPM_LED_1), S.intensityDay), 'auto brightness: day value at noon')
env.sim.timeHours = 7
frame(3)
check(near(env.seen(env.formula.hr.RPM_LED_1), (S.intensityDay + S.intensityNight) / 2, 0.3), 'auto brightness: between at 7 h')
app.runtime.setBrightness('autoBrightness', false)
frame(2)
check(near(env.seen(env.formula.hr.RPM_LED_1), S.intensity), 'manual brightness again')

return H.finish('test_colour')
