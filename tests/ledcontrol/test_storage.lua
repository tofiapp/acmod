-- Saving and loading: a user preset with a custom scenario and a frame animation shared with a built-in, the LED map
-- of a car, export / import as text (same effective looks after the round trip), and the same preset on a car with
-- another number of LEDs (frames rescaled, or the scenario switched off with a warning when rescaling is off).

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function looks(P, preset)
  local out = {}
  for _, e in ipairs(P.effective(preset)) do
    if not e.custom then out[e.id] = { on = e.on, prio = e.prio, look = e.look, param = e.param } end
  end
  return out
end

-- ---------------------------------------------------------------- a preset with everything, saved and loaded

H.formulaCar(1)
env.storage = {}
env.car.speedKmh, env.car.rpm = 150, 9000
local app = H.loadApp()
frame(3)
local rt, P = app.runtime, app.presets
local uid = P.create('builtin:f1', 'Moje')
rt.setPreset(uid)
frame(2)
local scId = rt.addCustom()
rt.editScenario(scId, 'when', { { q = 'speed', op = '<', v = 80 } })
rt.editScenario('shiftLights', 'param', 60)
-- a frame animation for the shift point, drawn for this car's 15 LEDs
local frames = { p = 'frames', fps = 8, palette = { '#FF0000', '#0000FF' },
  g = { [1] = { n = 15, f = { '111111100000000', '000000011111111' } } } }
rt.editScenario('shiftPoint', 'look', frames)
local anim = P.animFor(uid, 'shiftPoint')
check(anim ~= nil, 'the frame animation is an animation of the preset')
P.assign(anim.id, 'builtin:gt3', true)
-- a manual LED map: the first two RPM LEDs swapped, the last flag LED dropped
local lay = rt.layout
local map = { leds = {} }
for i = 1, #lay.leds - 1 do map.leds[i] = { lay.leds[i].name, lay.leds[i].group } end
map.leds[1], map.leds[2] = map.leds[2], map.leds[1]
rt.setMap(map)
frame(5)
local before = looks(P, P.get(uid))
local firstName = rt.layout.leds[1].name
frame(60)        -- deferred saves written

app = H.loadApp()
frame(5)
rt, P = app.runtime, app.presets
check(rt.presetId == uid and P.get(uid) and P.get(uid).name == 'Moje', 'user preset and the car\'s choice loaded')
check(same(looks(P, P.get(uid)), before), 'every scenario of the preset loaded unchanged')
local e
for _, x in ipairs(P.effective(P.get(uid))) do if x.id == scId then e = x end end
check(e and e.when and e.when[1].v == 80, 'custom scenario loaded with its condition')
check(P.animFor('builtin:gt3', 'shiftPoint') and P.animFor('builtin:gt3', 'shiftPoint').look.p == 'frames',
  'the animation still applies to GT3 styl')
check(rt.layout.manual and #rt.layout.leds == 20 and rt.layout.leds[1].name == firstName, 'LED map loaded (manual, 20 LEDs)')

-- ---------------------------------------------------------------- export / import as text

local text = P.export(uid)
check(type(text) == 'string' and text:sub(1, #P.EXPORT_PREFIX) == P.EXPORT_PREFIX and not text:find('\n'),
  'export: one line of text with the prefix')
local id2, why = P.import(text)
check(id2 and id2 ~= uid, 'import: a new preset (' .. tostring(why) .. ')')
check(same(looks(P, P.get(id2)), looks(P, P.get(uid))), 'import: the same effective looks as the exported preset')
local bad, why2 = P.import(text:sub(1, #text - 7))
check(bad == nil and type(why2) == 'string', 'import of a cut text refused with a reason')
local text2 = P.export('builtin:gt3')
local id3 = P.import(text2)
local fromGt3 = P.get(id3)
local look3
for _, x in ipairs(P.effective(fromGt3)) do if x.id == 'shiftPoint' then look3 = x.look end end
check(look3 and look3.p == 'frames', 'a built-in exported with its animation carries the animation look')

-- ---------------------------------------------------------------- the same preset on a car with 10 LEDs

H.gt3Car(1)
env.storage = env.storage        -- (same storage: presets.lon is in the temp folder, shared)
env.car.speedKmh, env.car.rpm = 150, 9000
app = H.loadApp()
frame(5)
rt, P = app.runtime, app.presets
rt.setPreset(uid)
frame(3)
local C = rt.compiled
local sc = app.engine.find(C, 'shiftPoint')
local f = sc and sc.frames[1]
check(f and f.ok and f.srcN == 15 and #f.rows[1] == 10, 'frames for 15 LEDs rescaled to the 10 of the GT3')
local row = ''
for k = 1, 10 do row = row .. tostring(f.rows[1][k]) end
check(row == '1111100000', 'the rescaled first frame keeps the left half lit (' .. row .. ')')
-- relative fill on 10 LEDs: 60 % of the shift lights from the edges (preset F1: from the left)
local sl = app.engine.find(C, 'shiftLights')
check(sl and sl.cl.p == 'fill', 'shift lights are a relative fill')
-- rescaling off: the scenario is switched off on this car with a warning
local noRescale = P.deepCopy(frames)
noRescale.rescale = false
rt.editScenario('shiftPoint', 'look', noRescale)
frame(3)
C = rt.compiled
sc = app.engine.find(C, 'shiftPoint')
local warned = false
for i = 1, #C.warnings do if C.warnings[i]:find('15', 1, true) and C.warnings[i]:find('10', 1, true) then warned = true end end
check(sc and sc.layoutOk == false and warned, 'rescaling off: shift point disabled on 10 LEDs with a warning')

return H.finish('test_storage')
