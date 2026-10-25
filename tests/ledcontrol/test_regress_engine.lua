-- Regression tests for the final review findings in the engine and data layer: non-finite numbers in imports,
-- truncated imports, parameters clamped to their scenario's range, symmetric frame rescaling, new custom scenarios
-- at the end of the priority list, cars without a limiter, two LED rows and arcs in detection.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame

H.formulaCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
local presets, patterns = app.presets, app.patterns or require('src/patterns')

-- inf / nan in an imported condition never reach presets.lon (which must stay readable)
local good = presets.create('builtin:gt3', 'Moje GT3')
local id = presets.import('LEDCONTROL-PRESET 1 {"name":"Sdileny","from":"builtin:f1","scenarios":{"custom:1":{"on":true,'
  .. '"when":[{"q":"speed","op":"<","v":1e999},{"q":"fuel","op":"<","v":5}]}}}')
local p = id and presets.get(id)
check(p and #p.scenarios['custom:1'].when == 1 and p.scenarios['custom:1'].when[1].q == 'fuel',
  'import: a row with an infinite value is dropped, the others kept')
local raw = io.load(tmpDir .. '/presets.lon')
check(raw and not raw:find('inf', 1, true) and not raw:find('nan', 1, true), 'presets.lon holds no inf / nan')
check(pcall(stringify.parse, raw), 'presets.lon parses with a strict parser')
app = H.loadApp()
frame(2)
presets = app.presets
check(presets.get(good) ~= nil and presets.get(id) ~= nil, 'user presets survive a restart')

-- an unreadable presets.lon is kept aside instead of being overwritten silently
io.save(tmpDir .. '/presets.lon', '{ list = { broken')
app = H.loadApp()
frame(2)
check(io.fileExists(tmpDir .. '/presets.lon.bad'), 'damaged presets.lon kept as presets.lon.bad')
presets = app.presets

-- truncated or garbage text is refused with a reason
local full = presets.export(presets.create('builtin:f1', 'Na export'))
local cut = full:sub(1, math.floor(#full * 0.6))
local bad, why = presets.import(cut)
check(bad == nil and why and why:find('neúplný', 1, true), 'import: text cut at 60 % refused')
bad = presets.import('LEDCONTROL-PRESET 1 [x')
check(bad == nil, 'import: garbage refused')
bad = presets.import(full .. '}')
check(bad == nil, 'import: extra closing bracket refused')
check(presets.import(full) ~= nil, 'import: the full text still works')
check(presets.balanced('{"a":"}{"}') and not presets.balanced('{"a":1}{"b":2}'), 'brackets inside strings are ignored')

-- imported parameters are clamped to the scenario's own range
local cid = presets.import('LEDCONTROL-PRESET 1 {"name":"Zly","scenarios":{"idle":{"param":-1000000},"damage":{"param":-5}}}')
local cp = presets.get(cid)
check(cp.scenarios.idle.param == 0 and cp.scenarios.damage.param == 1, 'import: parameters clamped to the scenario range')

-- frames rescaled symmetrically
local function rescale(s, n)
  local cl = patterns.compile({ p = 'frames', g = { { n = #s, f = { s } } } })
  local f = patterns.framesFor(cl, 1, n, true)
  local out = {}
  for k = 1, n do out[k] = tostring(f.rows[1][k]) end
  return table.concat(out)
end
check(rescale('1000000001', 15) == '110000000000011', 'rescale 10 -> 15 stays symmetric (' .. rescale('1000000001', 15) .. ')')
check(rescale('1100000000', 5) == '10000', 'rescale 10 -> 5 keeps a left-only pattern on the left')
check(rescale('10000000000000000001', 10) == '1000000001', 'rescale 20 -> 10 keeps both edges')
check(rescale('1001', 2) == '11', 'rescale 4 -> 2 keeps both edges')

-- a new custom scenario goes to the end, also after a move
local rt = app.runtime
rt.setPreset('builtin:f1')
rt.moveScenario('tc', -1)
local scId = rt.addCustom()
local list = presets.effective(rt.preset())
check(list[#list].id == scId, 'new custom scenario is last after a move')

-- a car without a limiter (rpmLimiter 0): the limiter scenario never fires on rpm alone
H.formulaCar(1)
env.car.rpmLimiter = 0
env.car.rpm = 11000
env.car.speedKmh = 120
env.storage = {}
app = H.loadApp()
frame(5)
check(not app.runtime.ST.limiterKnown and not app.engine.find(app.runtime.compiled, 'limiter').active,
  'no limiter: limiter scenario stays off at high rpm')
check(math.abs(app.runtime.ST.rpmLimiter - 11500 / 0.97) < 1, 'no limiter: reference from the shift point')

-- detection: two close rows become two groups, an arc stays one row
local function build(fn)
  H.baseCar(1)
  env.carId = 'test_layout'
  fn(env.node('STEER_HR', env.root, 0, 0.7, 0.4))
  env.storage = {}
  local a = H.loadApp()
  frame(3)
  return a.runtime.layout
end
local lay = build(function (w)
  for k = 1, 10 do env.mesh('SHIFT_LIGHT_' .. k, w, { centre = { (5.5 - k) * 0.01, 0.07, 0 } }) end
  for k = 11, 20 do env.mesh('SHIFT_LIGHT_' .. k, w, { centre = { (15.5 - k) * 0.01, 0.05, 0 } }) end
end)
check(lay.signature == '10+10' and lay.leds[1].name == 'SHIFT_LIGHT_1' and lay.leds[11].name == 'SHIFT_LIGHT_11',
  'two rows 2 cm apart: two groups, each left to right (' .. lay.signature .. ')')
lay = build(function (w)
  for k = 1, 15 do
    local a = math.rad(-60 + (k - 1) * 120 / 14)
    env.mesh('SHIFT_LIGHT_' .. k, w, { centre = { -0.1 * math.sin(a), 0.1 * math.cos(a), 0 } })
  end
end)
local arcOk = lay.signature == '15'
for k = 1, 15 do if lay.leds[k].name ~= 'SHIFT_LIGHT_' .. k then arcOk = false end end
check(arcOk, 'arc of 15 LEDs: one row in order (' .. lay.signature .. ')')

return H.finish('test_regress_engine')
