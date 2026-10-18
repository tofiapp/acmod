-- Lap tracking: reference lap, live delta, mini sectors and lap events.
--
-- Positions inside a lap are measured from the timing line, not from spline zero:
-- the AI spline does not always start exactly at the line where AC counts laps.
-- At every line crossing the line's spline position is estimated (interpolated
-- between frames) and the lap fraction is u = (spline - lineSpline) mod 1.
--
-- The current lap is recorded on a fixed grid: point k holds the lap time (ms) at
-- u = k / GRID, interpolated between frames. A finished valid lap's grid becomes
-- the reference, so the delta lookup is one interpolation.
-- All tables are allocated up front; the per-frame path creates no tables.

local config = require('src/config')
local store = require('src/store')
local S = config.S

local GRID = 1000              -- one point per 0.1 % of the lap
local MAX_SECTORS = 60
local HYSTERESIS = 0.02        -- s; delta colour only flips past ±20 ms
local SMOOTH_TIME = 0.15       -- s; delta smoothing time constant
local JUMP_LIMIT = 0.05        -- spline change in one frame treated as a teleport
local LINE_WAIT = 0.02         -- lap fraction we wait past the measured line for AC to count the lap
local CALLBACK_WAIT = 1.5      -- s to wait for ac.onLapCompleted after crossing the line
local EVENT_DEBOUNCE = 1.5     -- s; a second lap event this soon belongs to the same crossing

local T = {
  GRID = GRID,
  MAX_SECTORS = MAX_SECTORS,
  flying = false,              -- current lap started at the line on track and is timed
  partial = false,             -- out lap measured from the pit exit against the reference (never a reference)
  clean = false,               -- no cut and no pit lane so far in this lap
  hasDelta = false,
  delta = 0,                   -- smoothed delta in seconds, negative = faster
  deltaSign = 1,               -- -1 faster, +1 slower (with hysteresis)
  sectorCount = 24,
  curSector = 1,
  secState = {},               -- 0 not passed, 1 best ever, 2 faster than ref, 3 slower, 4 passed, no ref
  refMs = 0,                   -- lap time of the active reference
  refKind = 0,                 -- active reference: 0 none, 1 session, 2 all-time, 3 provisional
  provisionalMs = 0,           -- best full lap that cannot be a reference (out lap, cut), used until a valid one exists
  sessionRefMs = 0,
  allTimeRefMs = 0,
  -- lap end flash: 1 new best, 2 faster than previous lap, 3 slower, 4 not a timed lap
  flashKind = 0,
  flashUntil = 0,
  flashLapMs = 0,
  -- timing info for the timing window
  position = 0,
  carsCount = 0,
  lap = 0,
  totalLaps = 0,
  currentMs = 0,
  bestMs = 0,
  deltaFromAC = false,         -- the shown delta comes from AC's own performance meter
  status = 'Delta: čekám na první data',  -- why there is no delta (nil when there is one)
  -- diagnostics for the settings tab (strings are constants, so no allocation)
  diag = {
    error = nil,          -- first script error, if any
    lapEvents = 0,        -- line crossings seen
    timedLaps = 0,        -- laps that were complete and clean
    references = 0,       -- laps that became a reference
    lastReset = '-',      -- why the running lap was last dropped
    lastReject = '-',     -- why the last finished lap was not timed or not used
    jumps = 0,
    sessionStarts = 0,
    acDelta = nil,        -- whether AC's own delta (performanceMeter) is available
  },
}
for i = 1, MAX_SECTORS do T.secState[i] = 0 end

local function newList(n)
  local list = {}
  for i = 1, n do list[i] = 0 end
  return list
end

local cur, cand = newList(GRID + 1), newList(GRID + 1)   -- lap being recorded, finished lap awaiting confirmation
local sessionRef, allTimeRef = newList(GRID + 1), newList(GRID + 1)
local sessionRefStart, allTimeRefStart = 0, 0            -- line spline position of each reference
local provisionalRef, provisionalStart = newList(GRID + 1), 0
local sessionBest, allTimeBest = newList(MAX_SECTORS), newList(MAX_SECTORS)  -- best mini sector times, ms (0 = none)
local allTimeBestByCount = {}                           -- [sector count] = list, saved to disk
local loaded, dirty = false, false

local prevSpline, prevRawT, prevLapCount = 0, 0, -1     -- raw values of the previous frame
local prevU, prevT = 0, 0                               -- last recorded lap fraction and lap time
local curStart = 0                                       -- line spline position for the current lap
local nextK, nextSec, lastSecT = 1, 1, 0
local sectorsLive = false
local partialU0, partialT0, skipFirstSector = 0, 0, false
-- A lap only counts when AC also bumped lapCount around the timer restart; a timer restart alone
-- (pit exit, return to pits) must never produce a reference.
local lastCountChange, lapConfirmed, cleanIfConfirmed = -100, false, false
local acNow, acSecStart = nil, nil -- AC's delta this frame and at the last sector boundary (nil = none)
local COUNT_WINDOW = 0.5       -- s between lapCount change and timer restart that still belong together
local heldRawT, heldClock = nil, 0 -- timer value before a rejected restart, kept briefly for a late lapCount
local needReset, needSessionReset, wasReplay = false, false, false
local pendingActive, pendingMs, pendingStart, pendingClock = false, 0, 0, 0
local cbClock, cbValid, cbMs = -100, true, 0
local prevLapMs, bestFlashMs = 0, 0
local lastEventClock = -100
local sessionCheckClock = -100

-- Signed difference a - b on the unit circle, in [-0.5, 0.5).
local function circDiff(a, b)
  local d = (a - b) % 1
  if d >= 0.5 then d = d - 1 end
  return d
end

local function lapU(s)
  return (s - curStart) % 1
end

-- Lap time (ms) of grid g at lap fraction u.
local function gridAt(g, u)
  local x = u * GRID
  if x <= 0 then return g[1] end
  if x >= GRID then return g[GRID + 1] end
  local i = math.floor(x)
  local a = g[i + 1]
  return a + (g[i + 2] - a) * (x - i)
end
T.gridAt = gridAt

local function copyList(dst, src, n)
  for i = 1, n do dst[i] = src[i] end
end

-- The chosen reference first, then the other one, then the provisional lap, so there is a delta
-- as soon as any full lap was driven.
local function activeRef()
  if S.referenceMode == 1 then
    if T.sessionRefMs > 0 then return sessionRef, T.sessionRefMs, sessionRefStart, 1 end
    if T.allTimeRefMs > 0 then return allTimeRef, T.allTimeRefMs, allTimeRefStart, 2 end
  else
    if T.allTimeRefMs > 0 then return allTimeRef, T.allTimeRefMs, allTimeRefStart, 2 end
    if T.sessionRefMs > 0 then return sessionRef, T.sessionRefMs, sessionRefStart, 1 end
  end
  if T.provisionalMs > 0 then return provisionalRef, T.provisionalMs, provisionalStart, 3 end
  return nil, 0, 0, 0
end

-- True when a known line position (from a reference) is clearly elsewhere: the timer restarted off the line.
local function awayFromLine(s)
  local ref, _, refStart = activeRef()
  return ref ~= nil and math.abs(circDiff(s, refStart)) > 0.03
end

-- A full lap that is not a valid reference still serves until there is one.
local function offerProvisional(grid, ms, start)
  if T.sessionRefMs > 0 or T.allTimeRefMs > 0 then return end
  if T.provisionalMs > 0 and ms >= T.provisionalMs then return end
  copyList(provisionalRef, grid, GRID + 1)
  provisionalRef[GRID + 1] = ms
  T.provisionalMs, provisionalStart = ms, start
end

-- Persistence

local function saveData()
  dirty = false
  local sectors = {}
  for count, list in pairs(allTimeBestByCount) do
    local out = {}
    for i = 1, count do out[i] = math.floor((list[i] or 0) + 0.5) end
    sectors[tostring(count)] = out
  end
  local grid = nil
  if T.allTimeRefMs > 0 then
    grid = {}
    for i = 1, GRID + 1 do grid[i] = math.floor(allTimeRef[i] + 0.5) end
  end
  store.save({ version = 1, lapMs = T.allTimeRefMs, start = allTimeRefStart, grid = grid, sectors = sectors })
end

local function loadData()
  loaded = true
  local data = store.load()
  if not data then return end
  local lapMs = tonumber(data.lapMs) or 0
  if lapMs > 0 and type(data.grid) == 'table' and #data.grid == GRID + 1 then
    for i = 1, GRID + 1 do allTimeRef[i] = tonumber(data.grid[i]) or 0 end
    T.allTimeRefMs = lapMs
    allTimeRefStart = tonumber(data.start) or 0
  end
  if type(data.sectors) == 'table' then
    for key, list in pairs(data.sectors) do
      local count = tonumber(key)
      if count and count >= 1 and count <= MAX_SECTORS and type(list) == 'table' then
        local t = newList(MAX_SECTORS)
        for i = 1, count do t[i] = tonumber(list[i]) or 0 end
        allTimeBestByCount[count] = t
      end
    end
  end
end

local function setSectorCount(count)
  count = math.max(4, math.min(MAX_SECTORS, math.floor(count + 0.5)))
  local changed = count ~= T.sectorCount
  T.sectorCount = count
  local list = allTimeBestByCount[count]
  if not list then
    list = newList(MAX_SECTORS)
    allTimeBestByCount[count] = list
  end
  allTimeBest = list
  if changed then
    for i = 1, MAX_SECTORS do sessionBest[i] = 0; T.secState[i] = 0 end
    -- the running lap's sector progress no longer matches: colour again from the next lap
    sectorsLive = false
  end
end

-- Lap recording

local function finishSector(j, ms)
  local state = 0
  if (T.flying or T.partial) and sectorsLive then
    local ref = activeRef()
    if ref then
      local n = T.sectorCount
      local refSec = gridAt(ref, j / n) - gridAt(ref, (j - 1) / n)
      local best = S.referenceMode == 1 and sessionBest[j] or allTimeBest[j]
      if T.clean and best > 0 and ms < best then
        state = 1
      elseif ms < refSec then
        state = 2
      else
        state = 3
      end
    elseif T.flying and acNow and acSecStart then
      -- no own reference yet: colour by how AC's delta changed over the sector
      state = acNow <= acSecStart and 2 or 3
    else
      state = 4
    end
    acSecStart = acNow
    if T.clean and ms > 0 then
      if sessionBest[j] == 0 or ms < sessionBest[j] then sessionBest[j] = ms end
      if allTimeBest[j] == 0 or ms < allTimeBest[j] then
        allTimeBest[j] = ms
        dirty = true
      end
    end
  end
  T.secState[j] = state
end

-- Records grid points and mini sector boundaries between the last recorded frame and (u1, t1).
local function advance(u1, t1)
  local u0, t0 = prevU, prevT
  local du = u1 - u0
  if du <= 0 then return end
  if T.flying or T.partial then
    local dt = t1 - t0
    if T.flying then
      while nextK <= GRID and nextK <= u1 * GRID do
        cur[nextK + 1] = t0 + dt * (nextK / GRID - u0) / du
        nextK = nextK + 1
      end
    end
    local n = T.sectorCount
    while nextSec <= n and nextSec <= u1 * n do
      local tb = t0 + dt * (nextSec / n - u0) / du
      if skipFirstSector then
        -- the out lap started inside this sector: its time is incomplete
        skipFirstSector = false
        T.secState[nextSec] = 4
      else
        finishSector(nextSec, tb - lastSecT)
      end
      lastSecT = tb
      nextSec = nextSec + 1
    end
  end
  prevU, prevT = u1, t1
end

local function startLap(flying, lineSpline, clean)
  T.flying = flying
  T.partial = false
  skipFirstSector = false
  T.clean = flying and clean ~= false
  T.hasDelta = false
  sectorsLive = true
  curStart = lineSpline or 0
  cur[1] = 0
  nextK, nextSec, lastSecT = 1, 1, 0
  prevU, prevT = 0, 0
  for i = 1, MAX_SECTORS do T.secState[i] = 0 end
  acSecStart = acNow
end

-- Out lap: once the car is on track, measure from here to the line against the reference,
-- using the reference's line position (no crossing seen yet in this stint).
local function startPartial(s, t, refStart)
  startLap(false, refStart)
  T.partial = true
  local u0 = lapU(s)
  partialU0, partialT0 = u0, t
  nextSec = math.floor(u0 * T.sectorCount) + 1
  skipFirstSector = true
  lastSecT = t
  prevU, prevT = u0, t
end

local function resetLap(reason)
  startLap(false, nil)
  if reason then T.diag.lastReset = reason end
end

local function lapFinished(lapMs, now)
  if T.flying or T.partial then advance(1, lapMs) end
  local complete = T.flying and T.clean and nextK > GRID
  if complete then
    if bestFlashMs == 0 or lapMs < bestFlashMs then
      T.flashKind = 1
      bestFlashMs = lapMs
    elseif prevLapMs > 0 and lapMs < prevLapMs then
      T.flashKind = 2
    else
      T.flashKind = 3
    end
    prevLapMs = lapMs
    -- keep the finished grid until AC confirms the lap (or the wait runs out)
    cur, cand = cand, cur
    pendingActive, pendingMs, pendingStart, pendingClock = true, lapMs, curStart, now
    T.diag.timedLaps = T.diag.timedLaps + 1
  else
    if T.flying and lapConfirmed and nextK > GRID then offerProvisional(cur, lapMs, curStart) end
    if not T.flying then
      T.diag.lastReject = 'kolo nezačalo průjezdem cílem (out lap z boxu, reset)'
    elseif not T.clean then
      T.diag.lastReject = 'neplatné kolo (řezání podle AC nebo boxová ulička)'
    else
      T.diag.lastReject = 'chybí část kola (záznam nedošel do konce)'
    end
    T.flashKind = 4
    if dirty then saveData() end
  end
  T.flashLapMs = lapMs
  T.flashUntil = now + S.lapFlashTime
end

local function finalizePending(now)
  if not pendingActive then return end
  local fresh = cbClock >= pendingClock - CALLBACK_WAIT
  if not fresh and now - pendingClock < CALLBACK_WAIT then return end
  pendingActive = false
  local ms = pendingMs
  local valid = true
  if fresh then
    valid = cbValid
    if cbMs > 0 and math.abs(cbMs - ms) < 1000 then ms = cbMs end
  end
  if not valid then
    T.diag.lastReject = 'AC kolo po dojetí označilo jako neplatné'
    offerProvisional(cand, ms, pendingStart)   -- only confirmed laps get this far
  end
  if valid then
    T.diag.references = T.diag.references + 1
    cand[GRID + 1] = ms
    if T.sessionRefMs == 0 or ms < T.sessionRefMs then
      copyList(sessionRef, cand, GRID + 1)
      T.sessionRefMs, sessionRefStart = ms, pendingStart
    end
    if T.allTimeRefMs == 0 or ms < T.allTimeRefMs then
      copyList(allTimeRef, cand, GRID + 1)
      T.allTimeRefMs, allTimeRefStart = ms, pendingStart
      dirty = true
    end
  end
  if dirty then saveData() end
end

-- AC computes its own delta to its best lap in seconds ("performance meter", read the same way by the
-- official dash_display_8100 example). Checked once under pcall; used when our own measurement has nothing.
local acDeltaOk = nil
local function acDelta(car)
  if acDeltaOk == nil then
    acDeltaOk = pcall(function () return car.performanceMeter + 0 end)
    T.diag.acDelta = acDeltaOk
  end
  if not acDeltaOk or car.bestLapTimeMs <= 0 then return nil end
  return car.performanceMeter
end

local function smoothInto(raw, dt)
  if T.hasDelta then
    T.delta = T.delta + (raw - T.delta) * (1 - math.exp(-dt / SMOOTH_TIME))
  else
    T.delta = raw
    T.hasDelta = true
  end
  if T.delta < -HYSTERESIS then
    T.deltaSign = -1
  elseif T.delta > HYSTERESIS then
    T.deltaSign = 1
  end
end

local function updateDelta(dt, s, t, car)
  local ref, refMs, refStart, kind = activeRef()
  T.refMs, T.refKind = refMs, kind
  local own = S.deltaSource ~= 3 and (T.flying or T.partial) and ref
  if not own or kind == 3 then
    -- AC's delta (to a valid lap) beats our provisional one; with deltaSource = 3 it is the only source
    local v = S.deltaSource ~= 2 and car and acDelta(car)
    if v then
      T.deltaFromAC = true
      T.status = nil
      smoothInto(v, dt)
      return
    end
  end
  T.deltaFromAC = false
  if own and T.partial then
    -- out lap: time since the pit exit against the reference over the same stretch
    local u = math.max(partialU0, lapU(s))
    local refPart = gridAt(ref, u) - gridAt(ref, partialU0)
    T.status = nil
    smoothInto(((t - partialT0) - refPart) / 1000, dt)
  elseif own then
    local u = lapU(s)
    if prevU > 0.9 and u < 0.5 then u = 1 end   -- just past the line, AC has not counted the lap yet
    local uRef = u + circDiff(curStart, refStart)
    if uRef < 0 then uRef = 0 elseif uRef > 1 then uRef = 1 end
    T.status = kind == 3 and 'Delta proti dočasnému kolu (out lap nebo neplatné), platné kolo ho nahradí' or nil
    smoothInto((t - gridAt(ref, uRef)) / 1000, dt)
  else
    T.hasDelta = false
    if S.deltaSource == 3 then
      T.status = 'Delta z AC: AC zatím nemá nejlepší kolo'
    elseif not T.flying then
      T.status = 'Delta: čekám na průjezd cílovou čárou'
    else
      T.status = 'Delta: první kolo, zatím není s čím porovnat (od dalšího průjezdu cílem už ano)'
    end
  end
end

local function updateTiming(sim, car, now)
  T.position = car.racePosition
  T.carsCount = sim.carsCount
  T.lap = car.lapCount + 1
  T.currentMs = car.lapTimeMs
  T.bestMs = car.bestLapTimeMs
  if now - sessionCheckClock > 1 then
    sessionCheckClock = now
    local session = ac.getSession(sim.currentSessionIndex)
    T.totalLaps = (session and not session.isTimedRace and session.laps) or 0
  end
end

local function updateInner(dt)
  if not loaded then
    loadData()
    setSectorCount(S.sectors)
  elseif S.sectors ~= T.sectorCount then
    setSectorCount(S.sectors)
  end

  local sim = ac.getSim()
  local car = ac.getCar(0)
  if not car then return end
  local now = os.preciseClock()

  if sim.isReplayActive then
    wasReplay = true
    return
  end
  if sim.isPaused then return end

  local s, t, lapCount = car.splinePosition, car.lapTimeMs, car.lapCount
  updateTiming(sim, car, now)
  acNow = S.deltaSource ~= 2 and acDelta(car) or nil

  if needSessionReset then
    needSessionReset = false
    T.sessionRefMs, T.provisionalMs = 0, 0
    for i = 1, MAX_SECTORS do sessionBest[i] = 0 end
    bestFlashMs, prevLapMs = 0, 0
    pendingActive = false
    T.flashUntil = 0
    prevLapCount = -1
  end

  if prevLapCount < 0 or wasReplay or needReset then
    -- first frame, back from a replay, teleport or new session: wait for the next line crossing
    wasReplay, needReset = false, false
    prevLapCount, prevSpline, prevRawT = lapCount, s, t
    resetLap(nil)
    updateDelta(dt, s, t, car)
    return
  end

  -- The lap timer restarting is the crossing. AC may bump lapCount a frame earlier or later than
  -- the timer, so a lapCount change only counts on its own while the timer is already small.
  local countChanged = lapCount ~= prevLapCount
  if countChanged then lastCountChange = now end
  local lapEvent = t + 500 < prevRawT or (countChanged and t < 2000)
  local ds = circDiff(s, prevSpline)
  prevLapCount = lapCount

  if lapEvent and now - lastEventClock < EVENT_DEBOUNCE then
    -- second half of the same crossing (lapCount and timer in different frames); a lapCount
    -- arriving after the timer confirms the lap that just started
    if countChanged and T.flying and not lapConfirmed then
      lapConfirmed = true
      T.clean = cleanIfConfirmed
    end
    lapEvent = false
  end
  if lapEvent and not (ds >= 0 and ds < JUMP_LIMIT) then
    -- lap counter or timer changed without driving over the line (teleport, session reset)
    resetLap('časovač kola se vynuloval bez jízdy přes cíl')
  elseif lapEvent and not countChanged and (car.isInPitlane or car.isInPit or awayFromLine(s)) then
    -- the timer restarted but AC did not count a lap (pit exit, return to pits): not a crossing.
    -- A real crossing still counts when lapCount follows a frame later.
    resetLap('časovač se vynuloval mimo cílovou čáru (boxy)')
    -- keep the old timer value: if lapCount follows, the lap time is read against it
    if not heldRawT then heldRawT, heldClock = prevRawT, now end
  elseif lapEvent then
    heldRawT = nil
    lastEventClock = now
    T.diag.lapEvents = T.diag.lapEvents + 1
    -- the line lies between the previous and this frame: t ms have passed since crossing it
    local frameMs = dt * 1000
    local lineSpline = s
    if ds > 0 and frameMs > 0 then
      lineSpline = (s - ds * math.min(1, math.max(0, t / frameMs))) % 1
    end
    -- The finished lap must end within this frame. AC may update previousLapTimeMs a frame
    -- late (it would still hold the lap before), so prefer the callback, then the field,
    -- then the estimate from the timer.
    local lo, hi = prevRawT - 1, prevRawT + frameMs * 1.5 + 2
    local lapMs = car.previousLapTimeMs
    if now - cbClock < 0.5 and cbMs >= lo and cbMs <= hi then
      lapMs = cbMs
    elseif lapMs < lo or lapMs > hi then
      lapMs = prevRawT + math.max(0, frameMs - t)
    end
    lapFinished(lapMs, now)
    -- a lap starting in the pit lane is recorded too (provisional reference), it just is not clean
    local base = not car.isInPitlane and not car.isInPit
    startLap(true, lineSpline, base)
    lapConfirmed = now - lastCountChange < COUNT_WINDOW
    cleanIfConfirmed = base
    if not lapConfirmed then T.clean = false end
    advance(lapU(s), t)
  elseif ds > JUMP_LIMIT or ds < -JUMP_LIMIT then
    resetLap('skok pozice na trati (teleport)')
  elseif T.partial then
    local u = lapU(s)
    if car.isInPitlane then
      resetLap('out lap: zpět do boxové uličky')
    elseif prevU > 0.9 and u < 0.5 then
      -- past the line, AC has not counted the lap yet: wait a little, then give up
      if u > LINE_WAIT then resetLap('out lap: projel cílem, ale AC kolo nezapočítalo') end
    elseif u > prevU then
      advance(u, t)
    end
  elseif not T.flying and not car.isInPitlane and not car.isInPit and car.speedKmh > 5 then
    local ref, _, refStart = activeRef()
    if ref then startPartial(s, t, refStart) end
  elseif T.flying then
    local u = lapU(s)
    if prevU > 0.9 and u < 0.5 then
      -- past the measured line, but AC has not counted the lap: wait a little, then give up
      if u > LINE_WAIT then resetLap('projel cílem, ale AC kolo nezapočítalo') end
    elseif u > prevU then
      advance(u, t)
    end
    if T.clean and (not car.isLapValid or car.isInPitlane) then T.clean = false end
  end
  prevSpline, prevRawT = s, t
  if heldRawT then
    if now - heldClock < COUNT_WINDOW then prevRawT = heldRawT else heldRawT = nil end
  end

  finalizePending(now)
  local u = (T.flying or T.partial) and lapU(s) or s
  T.curSector = math.min(T.sectorCount, math.floor(u * T.sectorCount) + 1)
  updateDelta(dt, s, t, car)
end

-- Runs the tracker; a script error is kept for the diagnostics tab instead of being lost.
function T.update(dt)
  local ok, err = pcall(updateInner, dt)
  if not ok and not T.diag.error then
    T.diag.error = tostring(err)
    ac.error('MirrorDelta: ' .. T.diag.error)
  end
end

-- Clears saved data for this car + track and the session reference.
function T.clearSaved()
  store.delete()
  T.allTimeRefMs, T.sessionRefMs, T.provisionalMs = 0, 0, 0
  allTimeBestByCount = {}
  for i = 1, MAX_SECTORS do sessionBest[i] = 0 end
  setSectorCount(S.sectors)
  bestFlashMs, prevLapMs = 0, 0
  pendingActive, dirty = false, false
  T.hasDelta = false
end

function T.lapFraction()
  return curStart, prevU, nextK
end

function T.dataFile()
  return store.fileName()
end

if ac.onLapCompleted then
  ac.onLapCompleted(0, function (carIndex, lapTime, valid)
    cbClock, cbValid, cbMs = os.preciseClock(), valid ~= false, tonumber(lapTime) or 0
  end)
end
if ac.onSessionStart then
  ac.onSessionStart(function ()
    needSessionReset, needReset = true, true
    T.diag.sessionStarts = T.diag.sessionStarts + 1
    T.diag.lastReset = 'nová session nebo restart'
  end)
end
if ac.onCarJumped then
  ac.onCarJumped(0, function ()
    needReset = true
    T.diag.jumps = T.diag.jumps + 1
    T.diag.lastReset = 'teleport nebo reset auta'
  end)
end
if ac.onRelease then
  ac.onRelease(function ()
    if dirty then saveData() end
  end)
end

return T
