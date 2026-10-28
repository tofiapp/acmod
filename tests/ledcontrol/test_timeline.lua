-- A drive played back on a time line, on the formula (main row + left / right flag columns, preset F1 styl) and on
-- the GT3 car (one row, preset GT3 styl), with AC writing its own LEDs every frame and the jammer active. At every
-- step, after a settle time, for several frames:
--   * the scenario that wins in each LED group is the expected one,
--   * every LED shows a colour the winning scenario's look can show (or the base, off),
--   * every LED shows what the app wants (the takeover holds against the game).
-- Then: master off gives everything back. A second part loads the app in other orders of initialisation (car not
-- there yet, model loaded late, session callback before the first frame, LOD B active at load).
-- Not covered (needs the game): real AC flag timing, real pit lane geometry, what the game's own LED logic does.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local jammerPath = appDir .. '/../../../tests/ledcontrol/jammer.lua'
local color = nil

local function seconds(s) frame(math.floor(s * 60 + 0.5)) end

-- colours a compiled scenario's look can show (packed): its two colours, its fill zones and palette, off; a pulse
-- also shows its colour dimmed (same channel ratios)
local function allowed(sc)
  local set, list = { [0] = true }, {}
  local function add(p) if p and p >= 0 and not set[p] then set[p] = true; list[#list + 1] = p end end
  local cl = sc.cl
  add(cl.c1); add(cl.c2)
  for i = 1, #cl.zc do add(cl.zc[i]) end
  if cl.p == 'frames' then for i = 1, 9 do add(cl.palette[i]) end end
  set.list, set.pulse = list, cl.p == 'pulse'
  return set
end
local function rgbOf(p) return math.floor(p / 65536) % 256, math.floor(p / 256) % 256, p % 256 end
local function okColour(set, p)
  if set[p] then return true end
  if not set.pulse then return false end
  local r, g, b = rgbOf(p)
  local m = math.max(r, g, b)
  for _, q in ipairs(set.list) do
    local qr, qg, qb = rgbOf(q)
    local qm = math.max(qr, qg, qb)
    if qm > 0 and m > 0 and math.abs(r / m - qr / qm) < 0.08 and math.abs(g / m - qg / qm) < 0.08
      and math.abs(b / m - qb / qm) < 0.08 then return true end
  end
  return false
end

local function setCar(p)
  local car, sim = env.car, env.sim
  for k, v in pairs(p) do
    if k == 'flag' then sim.raceFlagType = v
    elseif k == 'speed' then car.speedKmh = v
    elseif k == 'pitLimiter' then car.manualPitsSpeedLimiterEnabled = v
    elseif k == 'pitlane' then car.isInPitlane = v
    elseif k == 'box' then car.isInPit = v
    elseif k == 'abs' then car.absInAction = v
    elseif k == 'tc' then car.tractionControlInAction = v
    else car[k] = v end
  end
end

local function groupByRole(rt, role, nth)
  local k = 0
  for gi = 1, #rt.layout.groups do
    if rt.layout.groups[gi].role == role then
      k = k + 1
      if k == (nth or 1) then return gi end
    end
  end
  return nil
end

-- expect: { main = id | false, side = id | false } (false = nothing wins: the base). Checked over `hold` frames.
local function verify(app, step, expect, hold)
  local rt = app.runtime
  local C = rt.compiled
  local problems = {}
  for f = 1, hold or 20 do
    frame(1)
    for gi = 1, #C.groups do
      local g = C.groups[gi]
      local role = rt.layout.groups[gi].role
      local want = expect[role]
      if want == nil and role ~= 'main' then want = expect.side end
      if want ~= nil then
        local got = g.activeId or false
        if got ~= want and not problems[gi] then
          problems[gi] = string.format('group %s: %s wins instead of %s (frame %d)', g.name, tostring(got), tostring(want), f)
        end
        local sc = got and app.engine.find(C, got)
        local set = sc and allowed(sc) or { [0] = true }
        for k = 1, g.n do
          local i = g.ids[k]
          local p = rt.fb[i]
          if p and p >= 0 and not okColour(set, p) and not problems['c' .. gi] then
            problems['c' .. gi] = string.format('group %s LED %d: #%06X is not a colour of %s', g.name, k, p, tostring(got))
          end
          local ok, why = H.ledMatches(i)
          if not ok and not problems['t' .. gi] then
            problems['t' .. gi] = string.format('group %s LED %d: takeover lost (%s)', g.name, k, tostring(why))
          end
        end
      end
    end
  end
  local list = {}
  for _, v in pairs(problems) do list[#list + 1] = v end
  table.sort(list)
  check(#list == 0, step .. ': ' .. (#list == 0 and 'ok' or table.concat(list, '; ')))
  return #list == 0
end

local function restoredAll(all)
  local bad = nil
  for i = 1, #all do
    local m = all[i]
    local w = env.lastWrite(m)
    if not m.visible and w and w.kind == 'visible' and w.writer == 'app' then bad = m.name .. ' hidden by the app' end
  end
  local function walk(o)
    if o.kind == 'mesh' then
      if o.created and not o.disposed and o.visible then bad = o.name .. ' copy shown' end
      return
    end
    for i = 1, #o.children do walk(o.children[i]) end
  end
  walk(env.root)
  for _, d in pairs(env.draws) do if d.frame == env.frameNo then bad = 'still drawn' end end
  return bad == nil, bad
end

local function drive(carName, build, method)
  build(1)
  env.storage = {}
  setCar({ speed = 150, rpm = 9000, gear = 4, fuel = 50, flag = 0, pitLimiter = false, pitlane = false, box = false,
    abs = false, tc = false })
  local app = H.loadApp()
  frame(3)
  local rt = app.runtime
  if method ~= 1 then rt.setMethod(method); frame(3) end
  local tag = carName .. ' / ' .. app.takeover.NAMES[method]
  -- the game: AC writes its LEDs every frame (mock AC step) and the jammer blinks them on the limiter
  local J = dofile(jammerPath)(env)
  local all = {}
  for i = 1, #rt.layout.leds do
    local led = rt.layout.leds[i]
    for k = 1, #led.inst do all[#all + 1] = led.inst[k].ref[1] end
  end
  J.watch(all)
  env.jammer = J
  J.set({ when = 'limiter', target = 'original', phase = 'before', reshow = true, blinkHz = 8 })
  local side = groupByRole(rt, 'side') ~= nil
  local S = side and 'flag' or nil       -- on the GT3 the side scenarios fall back to the main row

  local function step(name, set, expect, settle)
    setCar(set)
    seconds(settle or 0.5)
    verify(app, tag .. ' – ' .. name, expect)
  end
  local cruise = math.floor(rt.ST.shiftUp * 0.9)       -- inside the shift lights on both cars
  step('track, shift lights', { speed = 150, rpm = cruise }, { main = 'shiftLights', side = false })
  step('pit lane with the limiter', { pitlane = true, pitLimiter = true, speed = 60, rpm = 7000 },
    { main = 'pitLimiter', side = 'pitLimiter' })
  step('pit lane without the limiter', { pitLimiter = false, speed = 60 }, { main = 'pitLane', side = 'pitLane' })
  step('standing in the box', { box = true, speed = 0, rpm = 4500 }, { main = 'idle', side = 'idle' }, 3.5)
  step('back on track', { box = false, pitlane = false, speed = 160, rpm = cruise }, { main = 'shiftLights', side = false })
  step('blue flag', { flag = 12 }, side and { main = 'shiftLights', side = 'flagBlue' } or { main = 'flagBlue' })
  step('yellow flag', { flag = 2 }, side and { main = 'shiftLights', side = 'flagYellow' } or { main = 'flagYellow' })
  step('flag gone', { flag = 0 }, { main = 'shiftLights', side = false })
  -- the jammer blinks the LEDs by visibility on the limiter: the direct method first has to switch to the redraw
  step('rev limiter', { rpm = env.car.rpmLimiter * 0.995 }, { main = 'limiter', side = false }, method == 3 and 1.8 or 0.5)
  step('low fuel', { rpm = cruise, fuel = 2 }, side and { main = 'shiftLights', side = 'lowFuel' } or { main = 'shiftLights' })
  step('ABS working', { abs = true }, side and { main = 'shiftLights', side = 'abs' } or { main = 'shiftLights' })
  step('TC working', { abs = false, tc = true }, side and { main = 'shiftLights', side = 'tc' } or { main = 'shiftLights' })
  setCar({ tc = false, fuel = 50 })
  -- reset to the pits (AC's "back to pits": in the box, standing, engine at idle)
  step('reset to the pits', { box = true, pitlane = true, speed = 0, rpm = 4500 }, { main = 'idle', side = 'idle' }, 3.5)
  -- session restart: AC puts its LEDs back and CSP fires the session callback; the app takes the LEDs again
  J.sessionReset()
  step('after the session restart', { box = false, pitlane = false, speed = 150, rpm = cruise },
    { main = 'shiftLights', side = false }, 2)
  check(rt.state == 'run' and rt.lastRestart == 'session', tag .. ': running again after the session restart ('
    .. tostring(rt.state) .. ', ' .. tostring(rt.lastRestart) .. ')')
  -- LOD switch while on the limiter
  -- (the direct method cannot keep LEDs the game blinks by visibility: it switches to the redraw first, ~1.7 s)
  setCar({ rpm = env.car.rpmLimiter * 0.995 })
  J.lodSwitch(150)
  seconds(method == 3 and 1.8 or 0.2)
  verify(app, tag .. ' – limiter during the LOD switch', { main = 'limiter', side = false })
  seconds(1.5)
  verify(app, tag .. ' – limiter after the LOD switch', { main = 'limiter', side = false })
  -- off: everything back, also while the game keeps writing
  app.config.set('master', false)
  seconds(0.2)
  local ok, why = restoredAll(all)
  check(ok, tag .. ': master off restores the car (' .. tostring(why) .. ')')
  check(env.redundant.emissive + env.redundant.visible == 0, tag .. ': no app write without a change ('
    .. (env.redundant.emissive + env.redundant.visible) .. ')')
  J.on = false
  env.jammer = nil
  env.sim.raceFlagType = 0
end

for _, m in ipairs({ 1, 2, 3 }) do drive('formula', H.formulaCar, m) end
drive('GT3', H.gt3Car, 1)
drive('GT3', H.gt3Car, 3)

-- ---------------------------------------------------------------- other orders of initialisation

local function settled(name, app, leds)
  local rt = app.runtime
  local ok = rt.state == 'run' and rt.layout and #rt.layout.leds == leds
  local all = true
  if ok then
    for i = 1, #rt.layout.leds do if not H.ledMatches(i) then all = false end end
  end
  check(ok and all, string.format('init order "%s": runs with %d LEDs (state %s, %s LEDs, takeover %s)', name, leds,
    tostring(rt.state), tostring(rt.layout and #rt.layout.leds), tostring(all)))
end

-- the car is not there for the first second (ac.getCar returns nil, no car id)
H.formulaCar(1)
env.storage = {}
local car, id = env.car, env.carId
env.car, env.carId = nil, ''
local app = H.loadApp()
seconds(1)
env.car, env.carId = car, id
setCar({ speed = 150, rpm = 9000 })
seconds(2.5)
settled('car appears after 1 s', app, 21)

-- the model is loaded late: carRoot:0 exists but has no meshes for 2 s
H.formulaCar(1)
env.storage = {}
local kids = env.root.children
env.root.children = {}
app = H.loadApp()
seconds(2)
env.root.children = kids
setCar({ speed = 150, rpm = 9000 })
seconds(3)
settled('model loaded 2 s late', app, 21)

-- the session callback fires before the first frame
H.formulaCar(1)
env.storage = {}
app = H.loadApp()
if env.callbacks.session then env.callbacks.session(0, true) end
setCar({ speed = 150, rpm = 9000 })
seconds(2)
settled('session callback before the first frame', app, 21)

-- LOD B active at load (camera far away), the cockpit LOD comes later
H.formulaCar(1)
env.storage = {}
local cockpit, lodB = env.root.children[1], env.root.children[2]
cockpit.active, lodB.active = false, true
app = H.loadApp()
seconds(1)
cockpit.active, lodB.active = true, false
setCar({ speed = 150, rpm = 9000 })
seconds(2)
settled('LOD B active at load', app, 21)

return H.finish('test_timeline')
