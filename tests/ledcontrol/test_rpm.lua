-- RPM range per car (src/rpm.lua): the shift lights are full before the limiter blinks also when ai.ini's shift point
-- lies above the limiter, the limiter learned from AC's flag, an unreliable flag ignored, manual start / shift /
-- limiter, RPM per LED, persistence, sanitising, no allocation.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame

local function litCount()
  local n = 0
  for slot = 1, 15 do
    local r, g, b = env.seen(env.formula.hr[env.formula.slot[slot]])
    if r + g + b > 0.5 then n = n + 1 end
  end
  return n
end
local function limiterActive(app) return app.engine.find(app.runtime.compiled, 'limiter').active end

-- ai.ini UP 11500 above the limiter 11000: the bug was a half full row while the limiter already blinked
H.formulaCar(1)
env.car.rpmLimiter = 11000
env.car.speedKmh = 120
env.storage = {}
local app = H.loadApp()
frame(3)
local rt, rpm = app.runtime, app.runtime.rpm
check(rpm.shift == 10670 and rpm.limiter == 11000, 'shift point capped below the limiter (' .. rpm.shift .. ')')
env.car.rpm = 10700
frame(20)                -- past the limiter's 0.15 s hold from the start at 12000 rpm
check(litCount() == 15 and not limiterActive(app), 'whole row lit at the shift point, limiter not yet blinking')
env.car.rpm = 10960
frame(2)
check(limiterActive(app), 'limiter blinks at 99.5 % of the limiter')

-- learning the real limiter from AC's flag
env.car.rpm = 10400
env.car.isEngineLimiterOn = true
frame(2)
env.car.isEngineLimiterOn = false
frame(2)
check(rpm.learned == 10400 and rpm.limiter == 10400 and rpm.auto.limiterFrom == 'naměřeno ve hře',
  'limiter learned from AC\'s flag (' .. rpm.learned .. ')')
check(rpm.shift == math.floor(10400 * 0.97 + 0.5), 'shift point follows the learned limiter')
frame(200)
local profile = require('src/store').loadCar('test_formula')
check(profile.rpm and profile.rpm.learned == 10400, 'learned limiter saved in the car profile')
app = H.loadApp()
frame(3)
rt, rpm = app.runtime, app.runtime.rpm
check(rpm.limiter == 10400, 'learned limiter kept after a restart')
rpm.forgetLearned(rt.ST)
check(rpm.limiter == 11000 and rpm.learned == 0, 'forget: back to the car value')

-- a flag that is on at low RPM is not the limiter
env.car.rpm = 3000
env.car.isEngineLimiterOn = true
frame(200)
check(rpm.flagUnreliable and not limiterActive(app) and rpm.learned == 0, 'flag on at low RPM: ignored')
env.car.isEngineLimiterOn = false

-- manual start / shift / limiter
H.formulaCar(1)
env.car.speedKmh = 120
env.storage = {}
app = H.loadApp()
frame(3)
rt, rpm = app.runtime, app.runtime.rpm
rpm.set('start', 7000, rt.ST)
rpm.set('shift', 9000, rt.ST)
rpm.set('limiter', 9500, rt.ST)
env.car.rpm = 6900
frame(2)
check(litCount() == 0, 'manual start: dark below 7000')
env.car.rpm = 8000
frame(2)
check(litCount() == 7, 'manual range: half way = 7 of 15 (' .. litCount() .. ')')
env.car.rpm = 9100
frame(2)
check(not limiterActive(app), 'manual limiter: not at 9100')
env.car.rpm = 9460
frame(2)
check(limiterActive(app), 'manual limiter: blinks at 9460')
rpm.set('limiter', nil, rt.ST)
check(rpm.limiter == 13000, 'limiter back to automatic')

-- RPM per LED
rpm.spread(15, 7000, rt.ST)
check(#rpm.ledRpm == 15 and rpm.ledRpm[1] == 7000 and rpm.ledRpm[15] == 9000, 'spread evenly from start to shift point')
rpm.setLed(15, 9800, rt.ST)
rpm.set('shift', 9900, rt.ST)       -- shift point above the LEDs, so the whole-row shift point does not cover them
env.car.rpm = 9500
frame(2)
check(litCount() == 14, 'last LED waits for its own 9800 rpm (' .. litCount() .. ')')
env.car.rpm = 9850
frame(2)
check(litCount() == 15, 'last LED lit at 9850')
env.car.rpm = 6950
frame(2)
check(litCount() == 0, 'below the first LED value: dark')
rpm.setLeds(nil, rt.ST)
check(rpm.ledRpm == nil, 'per LED values switched off')

-- sanitising
local clean = rpm.sanitise({ start = 'x', shift = 1e999, limiter = -5, learned = 0 / 0, leds = { 7000, 'bad', 1e9 } })
check(clean and clean.start == nil and clean.shift == nil and clean.limiter == nil and clean.learned == nil
  and #clean.leds == 3 and clean.leds[1] == 7000 and clean.leds[2] == 500, 'hostile values dropped')
check(rpm.sanitise({}) == nil, 'empty rpm settings are not stored')

-- no allocation with learning running
H.formulaCar(1)
env.car.speedKmh = 120
env.storage = {}
app = H.loadApp()
frame(60)
local k = 0
local function sweep() k = k + 1; env.car.rpm = 8000 + (k % 120) * 40; frame(1) end
for _ = 1, 120 do sweep() end
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for _ = 1, 300 do sweep() end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
check(grown < 4, string.format('no per-frame allocation with the RPM module (%.2f KB / 300 frames)', grown))

return H.finish('test_rpm')
