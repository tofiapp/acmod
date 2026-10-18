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
local lateCount = false     -- lapCount changes one frame after the timer restarts
local pendingCount = false

local function frame(pace)
  env.clock = env.clock + DT
  if pendingPrev then car.previousLapTimeMs, pendingPrev = pendingPrev, nil end
  if pendingCb then env.callbacks.lap(0, pendingCb[1], pendingCb[2]); pendingCb = nil end
  if pendingTimer then car.lapTimeMs = pendingTimer - DT * 1000; pendingTimer = nil end
  if pendingCount then car.lapCount = car.lapCount + 1; pendingCount = false end
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
    if lateCount then pendingCount = true else car.lapCount = car.lapCount + 1 end
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
    if lateCount and pendingCount then frame(pace) end
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
local liveGreen, liveFrames = 0, 0
local u0 = car.lapCount
driveLaps(1, 1.01, function ()
  if tracker.hasDelta then
    minDelta = math.min(minDelta, tracker.delta)
    sawSign = tracker.deltaSign
    liveFrames = liveFrames + 1
    if tracker.liveSign < 0 then liveGreen = liveGreen + 1 end
  end
end)
local expected = refLap / 1000 * (1 - 1 / 1.01)
check(near(minDelta, -expected, 0.06), string.format('faster lap delta %.3f, expected about %.3f', minDelta, -expected))
check(sawSign == -1, 'delta colour is green when faster')
check(liveGreen > liveFrames * 0.8, string.format('line is green (gaining now) through a faster lap: %d of %d', liveGreen, liveFrames))
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
    env.windowW, env.windowH = 520, 110
    script.windowNotify(DT)
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
check(env.sim.damageDisplayerShown == false and env.calls['Hide Damage'] == 1, 'damage window hides AC damage displayer once')

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
    env.windowW, env.windowH = 520, 110
    script.windowNotify(DT)
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

-- 10. Without own reference the delta falls back to AC's performanceMeter (deltaSource 1 only)
car.performanceMeter = -0.42
env.callbacks.release()
tracker = loadApp()
config = require('src/config')
config.set('deltaSource', 2)
env.callbacks.session(0, false)
for _ = 1, 120 do frame(1) end
check(not tracker.hasDelta and tracker.status ~= nil, 'own-only source shows a status instead of a delta')
config.set('deltaSource', 1)
for _ = 1, 120 do frame(1) end
check(tracker.hasDelta and tracker.deltaFromAC and near(tracker.delta, -0.42, 0.02),
  'AC delta used while there is no own reference: ' .. tostring(tracker.delta))
check(tracker.diag.acDelta == true and tracker.status == nil, 'AC delta detected, no status text')
ok, err = pcall(script.windowDelta, DT)
check(ok and tracker.diag.error == nil, 'delta window draws with the AC delta: ' .. tostring(err or tracker.diag.error))
config.set('deltaSource', 1)

-- 11. A lap that starts in the pit lane is a provisional reference until the first valid lap
tracker.clearSaved()
env.callbacks.release()
tracker = loadApp()
config = require('src/config')
config.set('deltaSource', 2)
env.callbacks.session(0, false)
frame(1)
car.isInPitlane = true
driveLaps(1, 0.8)                   -- line crossed inside the pit lane
car.isInPitlane = false
check(tracker.flying and not tracker.clean, 'lap starting in the pit lane is recorded but not clean')
driveLaps(1, 1)                     -- that lap ends: nothing valid yet, so it becomes provisional
for _ = 1, 30 do frame(1) end
check(tracker.provisionalMs > 0 and tracker.refKind == 3, 'pit lane lap becomes the provisional reference')
check(tracker.hasDelta, 'delta available on the first flying lap')
driveLaps(1, 1)
for _ = 1, 120 do frame(1) end
check(tracker.allTimeRefMs > 0 and tracker.refKind == 2, 'first valid lap replaces the provisional reference')
config.set('deltaSource', 1)

-- 12. Mini sectors and the delta line blink blue at the rev limiter
do
  local blue = 0
  local saved = ui.drawRectFilled
  ui.drawRectFilled = function (p1, p2, color)
    if color.b > 0.99 and color.r < 0.3 and color.g > 0.5 and color.g < 0.6 then blue = blue + 1 end
  end
  car.rpm = car.rpmLimiter
  env.clock = math.floor(env.clock) + 0.01   -- the "on" half of the 8 Hz blink
  env.windowW, env.windowH = 600, 80
  script.windowDelta(DT)
  ui.drawRectFilled = saved
  car.rpm = 6000
  check(blue >= tracker.sectorCount + 1, 'sectors and line blink blue at the limiter: ' .. blue)
end

-- 13. Notifications
local notify = require('src/notify')
env.cars[1] = { index = 1, bestLapTimeMs = 0, isInPitlane = false, isConnected = true, racePosition = 1, lapCount = 0, isLapValid = true }
env.cars[2] = { index = 2, bestLapTimeMs = 0, isInPitlane = false, isConnected = true, racePosition = 2, lapCount = 0, isLapValid = true }
env.sim.carsCount = 3
car.racePosition = 3
env.sim.currentSessionIndex = 1     -- new session: notify takes a fresh snapshot
for _ = 1, 200 do frame(1) end      -- past the quiet start
local function newest() return notify.get(1) end
env.cars[1].bestLapTimeMs = 30000   -- faster than anything the player drove
for _ = 1, 10 do frame(1) end
check(newest() and newest().kind == notify.FASTEST and newest().sub:find('Jezdec 1', 1, true), 'fastest lap notification')
env.cars[2].isInPitlane = true
for _ = 1, 10 do frame(1) end
check(newest().kind == notify.PIT_IN, 'pit entry notification')
car.racePosition, env.cars[2].racePosition = 2, 3
for _ = 1, 80 do frame(1) end
check(newest().kind == notify.GAIN and newest().title == 'POSUN NA P2' and newest().sub:find('Jezdec 2', 1, true), 'position gained notification')
env.sim.raceFlagType = ac.FlagType.Caution
frame(1)
check(newest().kind == notify.YELLOW, 'yellow flag notification')
env.sim.raceFlagType = 0
car.isLapValid = false
frame(1)
check(newest().kind == notify.INVALID, 'invalid lap notification')
env.cars[2].isConnected = false     -- offline: AI cars are not "connected", no message
for _ = 1, 10 do frame(1) end
check(newest().kind ~= notify.DISCONNECT, 'no disconnect notification offline')
env.sim.isOnlineRace = true
env.cars[1].isConnected = false
for _ = 1, 10 do frame(1) end
check(newest().kind == notify.DISCONNECT, 'disconnect notification online')
env.sim.isOnlineRace = false
do
  local notifyWindow = require('src/notify_window')
  local shared = vec2(10, 10)
  local savedText = ui.dwriteTextAligned
  ui.dwriteTextAligned = function () end
  env.windowW, env.windowH = 520, 110
  local ok2, err2 = pcall(function ()
    for style = 1, 3 do config.set('notifyStyle', style); notifyWindow.draw() end
  end)
  check(ok2, 'notification window draws all styles: ' .. tostring(err2))
  check((env.calls.quad or 0) >= 2, 'slanted strip uses quads')
  for _ = 1, 50 do notifyWindow.draw() end
  jit.off()
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count')
  for _ = 1, 200 do notifyWindow.draw() end
  local perFrame = (collectgarbage('count') - before) * 1024 / 200
  collectgarbage('restart')
  jit.on()
  ui.dwriteTextAligned = savedText
  check(perFrame < 1, string.format('notification window allocation %.1f bytes per frame', perFrame))
  config.set('notifyStyle', 1)
end
check(tracker.diag.error == nil, 'no script errors after notifications: ' .. tostring(tracker.diag.error))

-- 14. Out lap: delta and mini sectors from the pit exit; timer restarts off the line are not crossings
car.isLapValid = true
env.callbacks.session(0, false)
car.isInPitlane = true
frame(0.4)
car.splinePosition = 0.5            -- line at 0.3: the pit exit is 20 % into the lap
for _ = 1, 60 do frame(0.4) end
check(not tracker.flying and not tracker.partial, 'no delta while still in the pit lane')
car.lapTimeMs = 0                   -- AC restarts the timer in the pit lane without counting a lap
frame(0.4)
check(not tracker.flying, 'timer restart in the pit lane is not a line crossing')
car.isInPitlane = false
local outColored, outDelta = 0, nil
for _ = 1, 1200 do frame(1) end
for i = 1, tracker.sectorCount do
  if tracker.secState[i] == 2 or tracker.secState[i] == 3 then outColored = outColored + 1 end
end
check(tracker.partial and tracker.hasDelta and math.abs(tracker.delta) < 0.15,
  'out lap delta from the pit exit: ' .. tostring(tracker.hasDelta) .. ' ' .. tostring(tracker.delta))
check(outColored >= 2, 'out lap mini sectors are coloured: ' .. outColored)
driveLaps(1, 1)
check(tracker.flying and tracker.clean, 'flying lap after the out lap')
for _ = 1, 600 do frame(1) end
car.lapTimeMs = 0                   -- timer restart mid-lap on track, lapCount unchanged
frame(1)
check(not tracker.flying and tracker.diag.lastReset:find('mimo', 1, true) ~= nil, 'timer restart away from the line is not a crossing')
for _ = 1, 40 do frame(1) end         -- after the 0.5 s wait for a late lapCount
check(tracker.partial, 'measuring continues as a partial lap until the line')
check(tracker.diag.error == nil, 'no script errors in the out lap: ' .. tostring(tracker.diag.error))

-- 15. Without any reference, a timer restart on track (no lapCount change) never makes a reference;
--     lapCount arriving a frame after the timer still confirms a lap
tracker.clearSaved()
env.callbacks.session(0, false)
frame(1)
car.splinePosition = 0.6
for _ = 1, 30 do frame(1) end
car.lapTimeMs = 0                   -- e.g. AC restarting the timer at the pit exit
for _ = 1, 30 do frame(1) end
driveLaps(1, 1)                     -- the real line
for _ = 1, 120 do frame(1) end
check(tracker.sessionRefMs == 0 and tracker.provisionalMs == 0, 'timer restart off the line gives no reference of any kind')
lateCount = true
driveLaps(1, 1)
check(tracker.flying and tracker.clean, 'lapCount one frame after the timer confirms the new lap')
for _ = 1, 120 do frame(1) end
lateCount = false
check(tracker.sessionRefMs > 0, 'lap confirmed by a lapCount one frame late becomes the reference')
check(tracker.diag.error == nil, 'no script errors: ' .. tostring(tracker.diag.error))

-- 16. Without an own reference the mini sectors follow AC's delta
tracker.clearSaved()
env.callbacks.session(0, false)
frame(1)
car.performanceMeter = 0
driveLaps(1, 1)                     -- start a flying lap, nothing to compare with yet
for _ = 1, 1500 do
  car.performanceMeter = car.performanceMeter - 0.0005   -- getting faster than AC's best
  frame(1)
end
local acGreen = 0
for i = 1, tracker.sectorCount do if tracker.secState[i] == 2 then acGreen = acGreen + 1 end end
check(tracker.refKind ~= 1 and tracker.refKind ~= 2 and tracker.deltaFromAC and acGreen >= 3, 'mini sectors coloured from AC delta: ' .. acGreen)

-- 17. Line crossed in the pit lane with lapCount one frame late: the lap time is still read correctly
tracker.clearSaved()
env.callbacks.session(0, false)
frame(1)
driveLaps(1, 1)                     -- first crossing on track
car.isInPitlane = true
lateCount = true
driveLaps(1, 1)                     -- this lap ends in the pit lane (timer first, lapCount a frame later)
lateCount = false
local pitLapMs = car.previousLapTimeMs
check(tracker.flying and tracker.flashLapMs > 0 and math.abs(tracker.flashLapMs - pitLapMs) < 30,
  string.format('lap time read across a late lapCount in the pit lane: %.0f vs %.0f', tracker.flashLapMs, pitLapMs))
car.isInPitlane = false
check(tracker.diag.error == nil, 'no script errors: ' .. tostring(tracker.diag.error))

-- 18. Out lap without any reference: mini sectors from the pit exit (AC delta or neutral),
--     the measured line survives a restart, no status text in the delta window, no invalid-lap message
tracker.clearSaved()
env.callbacks.session(0, false)
frame(1)
driveLaps(1, 1)                     -- a confirmed crossing: the line position is learned and saved
env.callbacks.release()
tracker = loadApp()
config = require('src/config')
notify = require('src/notify')
env.callbacks.session(0, false)
car.isInPitlane = true
frame(0.4)
car.splinePosition = 0.5
for _ = 1, 30 do frame(0.4) end
car.isInPitlane = false
local countBefore = notify.count
car.isLapValid = false              -- AC marks the out lap invalid at the pit exit
for _ = 1, 1500 do
  car.performanceMeter = car.performanceMeter + 0.0005
  frame(1)
end
car.isLapValid = true
local start = tracker.lapFraction()
local yellow = 0
for i = 1, tracker.sectorCount do if tracker.secState[i] == 3 then yellow = yellow + 1 end end
check(tracker.partial and tracker.refKind ~= 1 and tracker.refKind ~= 2, 'out lap without a reference is measured from the pit exit')
check(math.abs(start - LINE) < 0.01, string.format('line position loaded from the saved file: %.4f', start))
check(yellow >= 3, 'out lap mini sectors coloured from AC delta: ' .. yellow)
check(notify.count == countBefore, 'no invalid-lap notification on the out lap')
env.lastTexts = {}
env.windowW, env.windowH = 600, 80
script.windowDelta(DT)
local statusShown = false
for _, str in ipairs(env.lastTexts) do if str:find('čekám', 1, true) or str:find('průjezd', 1, true) then statusShown = true end end
check(not statusShown, 'no status text in the delta window')
config.set('deltaSource', 2)        -- no AC delta either: sectors still advance, neutral grey
for _ = 1, 600 do frame(1) end
local neutral = 0
for i = 1, tracker.sectorCount do if tracker.secState[i] == 4 then neutral = neutral + 1 end end
check(tracker.partial and neutral >= 3, 'out lap sectors shown as passed without any comparison: ' .. neutral)
config.set('deltaSource', 1)
check(tracker.diag.error == nil, 'no script errors: ' .. tostring(tracker.diag.error))

-- 19. A lap our checks rejected but AC took as its best lap becomes the reference
tracker.clearSaved()
env.callbacks.session(0, false)
frame(1)
driveLaps(1, 1)                     -- flying lap starts
car.bestLapTimeMs = 0               -- AC has no best lap yet in this session
for _ = 1, 600 do frame(1) end
car.isLapValid = false              -- a moment our tracker sees as a cut, AC does not keep
frame(1)
car.isLapValid = true
driveLaps(1, 1)
for _ = 1, 30 do frame(1) end
check((tracker.refKind == 1 or tracker.refKind == 2) and math.abs(tracker.sessionRefMs - car.bestLapTimeMs) < 2,
  string.format('lap confirmed by AC best time becomes the reference: kind %d, %.0f vs %.0f', tracker.refKind, tracker.sessionRefMs, car.bestLapTimeMs))

-- 20. AC knows a best lap but has no delta of its own: delta against AC's best time (estimate)
tracker.clearSaved()
car.performanceMeter = nil          -- this CSP has no performanceMeter
env.callbacks.release()
tracker = loadApp()
config = require('src/config')
env.callbacks.session(0, false)
frame(1)
driveLaps(1, 1)
for _ = 1, 300 do frame(1) end
check(tracker.refKind == 4 and tracker.hasDelta and not tracker.deltaFromAC,
  'delta against the AC best time without own reference: kind ' .. tracker.refKind)
check(tracker.diag.error == nil, 'no script errors: ' .. tostring(tracker.diag.error))
car.performanceMeter = 0

-- 21. All twelve damage styles draw without errors, balanced clip rects and no per-frame allocation
do
  local damage = require('src/damage_window')
  local savedText = ui.dwriteTextAligned
  ui.dwriteTextAligned = function () end
  env.windowW, env.windowH = 160, 200
  car.damage[0], car.damage[1], car.damage[2], car.damage[3] = 20, 0, 45, 5
  car.engineLifeLeft = 640
  car.wheels[1].isBlown = true
  config.set('damageAutoHide', false)
  local ok3, err3 = pcall(function ()
    for style = 1, 12 do config.set('damageStyle', style); damage.draw() end
    car.damage[1] = 40                -- a fresh hit: the rear flashes
    for style = 1, 12 do config.set('damageStyle', style); damage.draw() end
  end)
  check(ok3, 'all damage styles draw: ' .. tostring(err3))
  check((env.clipDepth or 0) == 0, 'damage styles pop every clip rect')
  check(#damage.STYLE_NAMES == 12, 'twelve damage style names')
  local worst, worstStyle = 0, 0
  for style = 1, 12 do
    config.set('damageStyle', style)
    for _ = 1, 20 do damage.draw() end
    jit.off()
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 50 do damage.draw() end
    local perFrame = (collectgarbage('count') - before) * 1024 / 50
    collectgarbage('restart')
    jit.on()
    if perFrame > worst then worst, worstStyle = perFrame, style end
  end
  ui.dwriteTextAligned = savedText
  check(worst < 1, string.format('damage styles allocate nothing per frame (worst %.1f bytes, style %d)', worst, worstStyle))
  car.wheels[1].isBlown = false
  car.damage[0], car.damage[1], car.damage[2], car.damage[3] = 0, 0, 0, 0
  car.engineLifeLeft = 1000
  config.set('damageStyle', 1)
end

print(string.format('%d passed, %d failed', passed, failed))
return failed
