local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check = H.env, H.check
local frame = H.frame
local function P(...) print('PROBE ' .. string.format(...)) end
-- thresholds of smp_lada2108_t1600 (acc-extension-config, [EMISSIVE_1..4] INPUT = RPM)
H.baseCar(1)
env.carId = 'test_lada'
local wheel = env.node('STEER_HR', env.node('COCKPIT_HR', env.root, 0, 0.5, 0.3), 0, 0.2, 0.1)
local thr = { 4450, 5800, 7400, 8900 }
env.cspConfig = {}
for k = 0, 3 do
  env.mesh('LED1_' .. k, wheel, { centre = { (1.5 - k) * 0.012, 0.04, 0 } })
  env.cspConfig['EMISSIVE_' .. (k + 1)] = { NAME = { 'LED1_' .. k }, INPUT = { 'RPM' }, INPUT_THRESHOLD = { tostring(thr[k + 1]) } }
  H.acLed('LED1_' .. k, thr[k + 1], 0, 10, 0)
end
env.car.rpmLimiter = 9200
env.car.rpmMinimum = 900
env.ini['ai.ini'] = { GEARS = { UP = { '8900' } } }
env.storage = {}
env.car.speedKmh = 100
env.car.rpm = 3000
local app = H.loadApp()
frame(3)
local rt = app.runtime
rt.editScenario('shiftLights', 'look', { p = 'fill', dir = 'left', src = 'car', c = { '#FFFFFF', '#000000' },
  zones = { 0, '#00FF00', 0.5, '#FF0000' } })
frame(2)
for _, rpm in ipairs({ 5000, 6000, 6800, 7500 }) do
  env.car.rpm = rpm
  frame(3)
  local lit = 0
  for k = 1, 4 do local r, g, b = env.seen(rt.layout.leds[k].inst[1].ref[1]); if r + g + b > 0.5 then lit = lit + 1 end end
  local carLit = 0
  for k = 1, 4 do if rpm >= thr[k] then carLit = carLit + 1 end end
  P('rpm %d: app lights %d, car thresholds say %d (relative start %.0f, preset %s)', rpm, lit, carLit, 8900 * 0.8, rt.presetId)
  check(lit == carLit, 'src=car at ' .. rpm)
end
return H.finish('test_regress_carthr')
