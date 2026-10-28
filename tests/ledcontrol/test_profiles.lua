-- The five test car profiles: formula with LEDs on the steering wheel, GT3 with LED groups, a car whose shift lights
-- are drawn into the dash display texture, a car without LEDs and a car with two displays. Checked: what the LED
-- takeover finds, that it never writes to a display mesh or its material, and that master off leaves the car as
-- it was. (The display takeover itself: test_display.lua.)

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame

local function appWrites(obj)
  local log, n = obj.log, 0
  for i = 1, math.min(log.n, env.LOG_MAX) do if log[i].writer == 'app' then n = n + 1 end end
  return n
end

local PROFILES = {
  { name = 'formula', build = H.formulaCar, state = 'run', leds = 21, groups = 3 },
  { name = 'GT3', build = H.gt3Car, state = 'run', leds = 10, groups = 1 },
  { name = 'display texture', build = H.displayCar, state = 'noleds', leds = 0, groups = 0 },
  { name = 'no LEDs', build = H.emptyCar, state = 'noleds', leds = 0, groups = 0 },
  { name = 'two displays', build = H.dualDisplayCar, state = 'run', leds = 10, groups = 1 },
}

for _, P in ipairs(PROFILES) do
  P.build(1)
  env.storage = {}
  env.car.speedKmh, env.car.gear, env.car.rpm = 120, 4, 11000
  local app = H.loadApp()
  frame(30)
  local rt = app.runtime
  local n = rt.layout and #rt.layout.leds or 0
  check(rt.state == P.state, string.format('%s: state %s (%s)', P.name, P.state, tostring(rt.state)))
  check(n == P.leds, string.format('%s: %d LEDs found (%d)', P.name, P.leds, n))
  check((rt.layout and #rt.layout.groups or 0) == P.groups, string.format('%s: %d groups', P.name, P.groups))
  for _, key in ipairs({ 'displayMesh', 'displayMesh2' }) do
    local m = env[key]
    if m then
      local isLed = false
      for i = 1, n do
        local led = rt.layout.leds[i]
        for k = 1, #led.inst do if led.inst[k].ref[1] == m then isLed = true end end
      end
      check(not isLed, P.name .. ': ' .. m.name .. ' is not taken for an LED')
      check(appWrites(m) == 0 and appWrites(m.material) == 0, P.name .. ': no LED write to ' .. m.name)
    end
  end
  app.config.set('master', false)
  frame(3)
  local shownCopy = false
  local function walk(o)
    if o.kind == 'mesh' then if o.created and not o.disposed and o.visible then shownCopy = true end return end
    for i = 1, #o.children do walk(o.children[i]) end
  end
  walk(env.root)
  check(not shownCopy, P.name .. ': master off, no copy left visible')
  env.storage = {}
end

return H.finish('test_profiles')
