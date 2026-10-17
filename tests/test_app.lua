-- Drives a simulated car around a track and checks MirrorDelta's lap logic and drawing.
-- Run with tests/run_tests.py (needs LuaJIT through the "lupa" Python package).

local appDir, tmpDir = ...
package.path = appDir .. '/?.lua;' .. package.path

local env = dofile(appDir .. '/../../../tests/mock_csp.lua')
env.folder = tmpDir

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol) return math.abs(a - b) <= tol end

local function loadApp()
  for k in pairs(package.loaded) do
    if k:match('^src/') then package.loaded[k] = nil end
  end
  script = {}
  dofile(appDir .. '/MirrorDelta.lua')
  return require('src/tracker')
end

-- Track model: spline 0..1, timing line at LINE (not at spline zero on purpose).
local LINE = 0.3
local DT = 1 / 60
local BASE_LAP = 90           -- seconds at pace 1
local car = env.car

local function speed(p) -- spline units per second, varies around the lap
  return (1 / BASE_LAP) * (1 + 0.35 * math.sin(p * math.pi * 6))
end

local tracker = loadApp()

local lateLapTime = false   -- AC updating previousLapTimeMs one frame late
local lateCallback = false  -- ac.onLapCompleted arriving one frame late
local pendingPrev, pendingCb = nil, nil
local splitEvent = false    -- lapCount changes one frame before the timer restarts
local pendingTimer = nil

local function frame(pace)
  env.clock = env.clock + DT
  if pendingPrev then car.previousLapTimeMs, pendingPrev = pendingPrev, nil end
  if pendingCb then env.callbacks.lap(0, pendingCb[1], pendingCb[2]); pendingCb = nil end
  if pendingTimer then car.lapTimeMs = pendingTimer - DT * 1000; pendingTimer = nil end
  local p0 = car.splinePosition
  local p1 = p0 + DT * speed(p0) * pace
  local before = (p0 - LINE) % 1
  local after = (p1 - LINE) % 1
  car.lapTimeMs = car.lapTimeMs + DT * 1000
  if after < before and not car.isInPit then
    -- crossed the timing line during this frame
    local f = (1 - before) / ((1 - before) + after)
    local lapMs = car.lapTimeMs - DT * 1000 + f * DT * 1000
    if lateLapTime then pendingPrev = lapMs else car.previousLapTimeMs = lapMs end
    if splitEvent then pendingTimer = (1 - f) * DT * 1000 + DT * 1000 else car.lapTimeMs = (1 - f) * DT * 1000 end
    car.lapCount = car.lapCount + 1
    if car.isLapValid and not car.wasPit and (car.bestLapTimeMs == 0 or lapMs < car.bestLapTimeMs) then
      car.bestLapTimeMs = lapMs
    end
    if lateCallback then pendingCb = { lapMs, car.isLapValid } else env.callbacks.lap(0, lapMs, car.isLapValid) end
    car.isLapValid = true
    car.wasPit = car.isInPitlane
  end
  car.splinePosition = p1 % 1
  script.update(DT)
end

-- Runs until the car crosses the line n times; returns the delta samples seen on the way.
local function driveLaps(n, pace, onFrame)
  local target = car.lapCount + n
  while car.lapCount < target do
    frame(pace)
    if onFrame then onFrame() end
  end
end

-- 1. Out lap from the pit lane, then a reference lap
car.splinePosition, car.isInPitlane, car.wasPit = 0.55, true, true
for _ = 1, 120 do frame(0.5) end
check(not tracker.flying, 'out lap from the pits is not a timed lap')
car.isInPitlane = false
driveLaps(1, 1)                     -- reach the line: out lap ends
check(tracker.flying, 'lap after the out lap is timed')
check(tracker.flashKind == 4, 'out lap shows a grey flash')
driveLaps(1, 1)                     -- reference lap
for _ = 1, 120 do frame(1) end      -- let the confirmation wait run out
check(tracker.sessionRefMs > 0, 'session reference set after a clean lap')
check(near(tracker.sessionRefMs, car.previousLapTimeMs, 1), 'reference uses the lap time from AC')
check(tracker.allTimeRefMs == tracker.sessionRefMs, 'all-time reference set too')
check(io.fileExists(tracker.dataFile()), 'data file written')
local refLap = tracker.sessionRefMs

-- 2. A faster lap: delta negative, mini sectors purple
local minDelta, sawSign = 0, 0
local u0 = car.lapCount
driveLaps(1, 1.01, function ()
  if tracker.hasDelta then
    minDelta = math.min(minDelta, tracker.delta)
    sawSign = tracker.deltaSign
  end
end)
local expected = refLap / 1000 * (1 - 1 / 1.01)
check(near(minDelta, -expected, 0.06), string.format('faster lap delta %.3f, expected about %.3f', minDelta, -expected))
check(sawSign == -1, 'delta colour is green when faster')
check(tracker.flashKind == 1, 'faster lap flashes purple (new best)')
for _ = 1, 120 do frame(1.01) end
check(tracker.sessionRefMs < refLap, 'faster lap becomes the new reference')

-- mini sectors during the next lap at pace 1.02: everything purple
local purpleSeen = 0
driveLaps(1, 1.02, function ()
  for i = 1, tracker.sectorCount do if tracker.secState[i] == 1 then purpleSeen = math.max(purpleSeen, i) end end
end)
check(purpleSeen >= tracker.sectorCount - 1, 'faster lap marks mini sectors purple, last purple index ' .. purpleSeen)
for _ = 1, 120 do frame(1) end

-- 3. A slower lap: delta positive, sectors yellow, red flash
local maxDelta, yellow = 0, 0
driveLaps(1, 0.98, function ()
  if tracker.hasDelta then maxDelta = math.max(maxDelta, tracker.delta) end
  for i = 1, tracker.sectorCount do if tracker.secState[i] == 3 then yellow = yellow + 1 end end
end)
check(maxDelta > 1, 'slower lap gives a positive delta: ' .. maxDelta)
check(yellow > 0, 'slower lap marks mini sectors yellow')
check(tracker.flashKind == 3, 'slower lap than the previous one flashes red')
local bestBefore = tracker.sessionRefMs
for _ = 1, 120 do frame(1) end

-- 4. A cut lap is never a reference
for _ = 1, 600 do frame(1.05) end
car.isLapValid = false
driveLaps(1, 1.05)
check(tracker.flashKind == 4, 'cut lap flashes grey')
for _ = 1, 120 do frame(1) end
check(tracker.sessionRefMs == bestBefore, 'cut lap does not become the reference')

-- 5. Teleport to the pits resets until the next line crossing
for _ = 1, 300 do frame(1) end
env.callbacks.jump()
car.splinePosition = 0.9
frame(1)
check(not tracker.flying and not tracker.hasDelta, 'teleport stops the delta')
driveLaps(1, 1)
check(tracker.flying, 'timed again after the next line crossing')

-- 5b. Late lap time and late callback from AC: the finished lap is still read correctly
for _ = 1, 120 do frame(1) end
driveLaps(1, 1)
lateLapTime, lateCallback = true, true
driveLaps(1, 1.03)
check(tracker.flashKind == 1, 'faster lap flashes purple even when AC reports the time a frame late')
local beforeLate = tracker.sessionRefMs
for _ = 1, 120 do frame(1) end
check(tracker.sessionRefMs < beforeLate, 'late-reported faster lap still becomes the reference')
check(near(tracker.sessionRefMs, car.previousLapTimeMs, 1), 'reference time matches AC lap time')
lateLapTime, lateCallback = false, false

-- 5c. lapCount changing a frame before the timer restarts must not stop the delta
splitEvent = true
driveLaps(2, 1)
local splitDelta = false
for _ = 1, 600 do frame(1); if tracker.hasDelta then splitDelta = true end end
check(tracker.flying and splitDelta, 'delta keeps working when lapCount and timer change in different frames')
splitEvent = false
driveLaps(1, 1)

-- 6. Drawing with both layouts, both tyre styles and both timing layouts
local delta = require('src/delta_window')
local timing = require('src/timing_window')
local tyres = require('src/tyres_window')
local settings = require('src/settings_window')
local config = require('src/config')
for _ = 1, 400 do frame(1) end
local ok, err = pcall(function ()
  for layout = 1, 2 do
    config.set('deltaLayout', layout)
    delta.draw()
    config.set('timingLayout', layout)
    env.windowW, env.windowH = 390, 60
    timing.draw()
    config.set('tyreStyle', layout)
    config.set('tyreArrange', layout)
    env.windowW, env.windowH = 180, 140
    tyres.draw()
    env.windowW, env.windowH = 260, 102
    config.set('gearShowSpeed', layout == 1)
    car.rpm = layout == 1 and 7790 or 6000
    script.windowGear(DT)
    env.windowW, env.windowH = 150, 168
    car.damage[0], car.damage[2] = layout == 1 and 0 or 30, layout == 1 and 80 or 0
    car.engineLifeLeft = layout == 1 and 1000 or 420
    config.set('damageAutoHide', layout == 2)
    script.windowDamage(DT)
    env.windowW, env.windowH = 600, 80
  end
  settings.draw()
end)
check(ok, 'drawing runs without errors: ' .. tostring(err))
check(env.calls.pushFont == env.calls.popFont, 'every pushed font is popped')
check(tracker.diag.error == nil, 'tracker ran without script errors: ' .. tostring(tracker.diag.error))
check(tracker.diag.lapEvents > 5 and tracker.diag.references > 0, 'diagnostics count line crossings and references')
check((env.calls.rect or 0) > 100, 'rectangles were drawn')
check(tyres.available() == true and tyres.optimumFromCar() == true, 'tyre temperatures detected')

-- 6b. No per-frame allocation once caches are warm (JIT off: trace compilation would count too)
do
  local shared = vec2(10, 10)
  local savedMeasure, savedText = ui.measureDWriteText, ui.dwriteTextAligned
  ui.measureDWriteText = function () return shared end
  ui.dwriteTextAligned = function () end
  config.set('deltaLayout', 2)
  config.set('timingLayout', 2)
  config.set('tyreStyle', 1)
  local function frameAndDraw()
    frame(1)
    env.windowW, env.windowH = 600, 80
    script.windowDelta(DT)
    env.windowW, env.windowH = 390, 60
    script.windowTiming(DT)
    env.windowW, env.windowH = 180, 140
    script.windowTyres(DT)
    env.windowW, env.windowH = 260, 102
    script.windowGear(DT)
    env.windowW, env.windowH = 150, 168
    script.windowDamage(DT)
  end
  for _ = 1, 300 do frameAndDraw() end
  jit.off()
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count')
  for _ = 1, 300 do frameAndDraw() end
  local perFrame = (collectgarbage('count') - before) * 1024 / 300
  collectgarbage('restart')
  jit.on()
  ui.measureDWriteText, ui.dwriteTextAligned = savedMeasure, savedText
  -- the running lap time string changes ten times a second; everything else is cached
  check(perFrame < 16, string.format('per-frame allocation %.1f bytes', perFrame))
end

-- 7. Saved reference loads in a new session
local saved = tracker.allTimeRefMs
env.callbacks.release()
tracker = loadApp()
config = require('src/config')
config.set('referenceMode', 2)
env.callbacks.session(0, false)
frame(1)
check(tracker.allTimeRefMs == saved, 'all-time reference loaded from disk')
driveLaps(1, 1)
local got = false
for _ = 1, 600 do frame(1); if tracker.hasDelta then got = true end end
check(got, 'delta available on the first timed lap thanks to the saved reference')

-- 8. Missing tyre fields do not break the window
for i = 0, 3 do env.car.wheels[i] = {} end
package.loaded['src/tyres_window'] = nil
local tyres2 = require('src/tyres_window')
ok, err = pcall(tyres2.draw)
check(ok and tyres2.available() == false, 'tyre window survives missing fields: ' .. tostring(err))

-- 9. Clearing saved data
tracker.clearSaved()
check(not io.fileExists(tracker.dataFile()) and tracker.allTimeRefMs == 0, 'saved data cleared')

print(string.format('%d passed, %d failed', passed, failed))
return failed
