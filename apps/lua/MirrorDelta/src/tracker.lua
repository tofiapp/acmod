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
  clean = false,               -- no cut and no pit lane so far in this lap
  hasDelta = false,
  delta = 0,                   -- smoothed delta in seconds, negative = faster
  deltaSign = 1,               -- -1 faster, +1 slower (with hysteresis)
  sectorCount = 24,
  curSector = 1,
  secState = {},               -- 0 not passed, 1 best ever, 2 faster than ref, 3 slower, 4 passed, no ref
  refMs = 0,                   -- lap time of the active reference
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
local sessionBest, allTimeBest = newList(MAX_SECTORS), newList(MAX_SECTORS)  -- best mini sector times, ms (0 = none)
local allTimeBestByCount = {}                           -- [sector count] = list, saved to disk
local loaded, dirty = false, false

local prevSpline, prevRawT, prevLapCount = 0, 0, -1     -- raw values of the previous frame
local prevU, prevT = 0, 0                               -- last recorded lap fraction and lap time
local curStart = 0                                       -- line spline position for the current lap
local nextK, nextSec, lastSecT = 1, 1, 0
local sectorsLive = false
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

local function activeRef()
  if S.referenceMode == 1 then
    if T.sessionRefMs > 0 then return sessionRef, T.sessionRefMs, sessionRefStart end
  elseif T.allTimeRefMs > 0 then
    return allTimeRef, T.allTimeRefMs, allTimeRefStart
  end
  return nil, 0, 0
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
  if T.flying and sectorsLive then
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
    else
      state = 4
    end
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
  if T.flying then
    local dt = t1 - t0
    while nextK <= GRID and nextK <= u1 * GRID do
      cur[nextK + 1] = t0 + dt * (nextK / GRID - u0) / du
      nextK = nextK + 1
    end
    local n = T.sectorCount
    while nextSec <= n and nextSec <= u1 * n do
      local tb = t0 + dt * (nextSec / n - u0) / du
      finishSector(nextSec, tb - lastSecT)
      lastSecT = tb
      nextSec = nextSec + 1
    end
  end
  prevU, prevT = u1, t1
end

local function startLap(flying, lineSpline)
  T.flying = flying
  T.clean = flying
  T.hasDelta = false
  sectorsLive = true
  curStart = lineSpline or 0
  cur[1] = 0
  nextK, nextSec, lastSecT = 1, 1, 0
  prevU, prevT = 0, 0
  for i = 1, MAX_SECTORS do T.secState[i] = 0 end
end

local function resetLap()
  startLap(false, nil)
end

local function lapFinished(lapMs, now)
  if T.flying then advance(1, lapMs) end
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
  else
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
  if valid then
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

local function updateDelta(dt, s, t)
  local ref, refMs, refStart = activeRef()
  T.refMs = refMs
  if T.flying and ref then
    local u = lapU(s)
    if prevU > 0.9 and u < 0.5 then u = 1 end   -- just past the line, AC has not counted the lap yet
    local uRef = u + circDiff(curStart, refStart)
    if uRef < 0 then uRef = 0 elseif uRef > 1 then uRef = 1 end
    local raw = (t - gridAt(ref, uRef)) / 1000
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
  else
    T.hasDelta = false
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

function T.update(dt)
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

  if needSessionReset then
    needSessionReset = false
    T.sessionRefMs = 0
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
    resetLap()
    updateDelta(dt, s, t)
    return
  end

  -- The lap timer restarting is the crossing. AC may bump lapCount a frame earlier or later than
  -- the timer, so a lapCount change only counts on its own while the timer is already small.
  local lapEvent = t + 500 < prevRawT or (lapCount ~= prevLapCount and t < 2000)
  local ds = circDiff(s, prevSpline)
  prevLapCount = lapCount

  if lapEvent and now - lastEventClock < EVENT_DEBOUNCE then
    -- second half of the same crossing (lapCount and timer in different frames): nothing to do
    lapEvent = false
  end
  if lapEvent and not (ds > 0 and ds < JUMP_LIMIT) then
    -- lap counter or timer changed without driving over the line (teleport, session reset)
    resetLap()
  elseif lapEvent then
    lastEventClock = now
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
    startLap(not car.isInPitlane and not car.isInPit, lineSpline)
    advance(lapU(s), t)
  elseif ds > JUMP_LIMIT or ds < -JUMP_LIMIT then
    resetLap()
  elseif T.flying then
    local u = lapU(s)
    if prevU > 0.9 and u < 0.5 then
      -- past the measured line, but AC has not counted the lap: wait a little, then give up
      if u > LINE_WAIT then resetLap() end
    elseif u > prevU then
      advance(u, t)
    end
    if T.clean and (not car.isLapValid or car.isInPitlane) then T.clean = false end
  end
  prevSpline, prevRawT = s, t

  finalizePending(now)
  local u = T.flying and lapU(s) or s
  T.curSector = math.min(T.sectorCount, math.floor(u * T.sectorCount) + 1)
  updateDelta(dt, s, t)
end

-- Clears saved data for this car + track and the session reference.
function T.clearSaved()
  store.delete()
  T.allTimeRefMs, T.sessionRefMs = 0, 0
  allTimeBestByCount = {}
  for i = 1, MAX_SECTORS do sessionBest[i] = 0 end
  setSectorCount(S.sectors)
  bestFlashMs, prevLapMs = 0, 0
  pendingActive, dirty = false, false
  T.hasDelta = false
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
  end)
end
if ac.onCarJumped then
  ac.onCarJumped(0, function ()
    needReset = true
  end)
end
if ac.onRelease then
  ac.onRelease(function ()
    if dirty then saveData() end
  end)
end

return T
