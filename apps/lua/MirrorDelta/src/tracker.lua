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
local LIVE_HYSTERESIS = 0.005  -- s; live (current sector) colour flips past ±5 ms
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
  liveDelta = 0,               -- s gained (-) or lost (+) since the current mini sector started
  liveSign = 1,                -- -1 gaining right now, +1 losing (with hysteresis, kept across sector starts)
  sectorCount = 24,
  curSector = 1,
  secState = {},               -- 0 not passed, 1 best ever, 2 faster than ref, 3 slower, 4 passed, no ref
  refMs = 0,                   -- lap time of the active reference
  refKind = 0,                 -- active reference: 0 none, 1 session, 2 all-time, 3 provisional, 4 AC best (estimate), 5 previous lap
  prevLapMs = 0,               -- previous lap (reference kind 5); an out lap counts from where it was measured
  prevLapPartial = false,      -- the previous lap is an out lap (compared only from its first measured point)
  lastLapMs = 0,               -- last finished lap for the timing window (0 = none yet)
  lastLapState = 0,            -- 0 none, 1 valid, 2 deleted (cut or invalidated by AC), 3 not timed (out lap, pits)
  nowDelta = 0,                -- s gained (-) or lost (+) over the last ~3 s of driving: the split delta line
  estimateMs = 0,              -- AC's best lap time behind the estimated reference (0 = none)
  provisionalMs = 0,           -- best full lap that cannot be a reference (out lap, cut), used until a valid one exists
  sessionRefMs = 0,
  allTimeRefMs = 0,
  -- lap end flash: 1 new best, 2 faster than previous lap, 3 slower, 4 not a timed lap, 5 deleted (cut / invalid)
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
  status = 'Delta: čekám na první data',  -- why there is no delta (nil when there is one), for Diagnostika
  -- diagnostics for the settings tab (strings are constants, so no allocation)
  diag = {
    error = nil,          -- first script error, if any
    lapEvents = 0,        -- line crossings seen
    timedLaps = 0,        -- laps that were complete and clean
    references = 0,       -- laps that became a reference
    lastReset = '-',      -- why the running lap was last dropped
    lastReject = '-',     -- why the last finished lap was not timed or not used
    lastDeleted = '-',    -- why the last lap was shown as deleted (or why AC's "invalid" was not taken)
    lastCallback = '-',   -- last ac.onLapCompleted: time, valid, cuts
    callbacks = 0,
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
-- Estimated reference from AC's best lap time: the shape of a recorded lap (or even pace) scaled to it.
local estimateRef, estimateStart, estimateShape = newList(GRID + 1), 0, -1
local estimateStartKnown = false
-- Last fully recorded lap of any kind; adopted as the reference when AC confirms it as its best lap.
local lastFull, lastFullMs, lastFullStart, lastFullClock = newList(GRID + 1), 0, 0, -100
local prevLapRef, prevLapStart, prevLapAnchor = newList(GRID + 1), 0, 0   -- anchor: first measured u (out lap)
local curK0 = 0                -- first grid index recorded in the current lap (0 on a full lap)
local lapCut = false           -- the current timed lap was cut (AC marked it invalid on track)
local lapCutU = 0              -- lap fraction where it happened (for Diagnostika)
local lapSeenValid = false     -- AC reported this lap valid at least once (a cut is a change from valid to invalid)
local DELETED_N = 8
local deletedLaps, deletedHead = newList(DELETED_N), 0   -- times of deleted laps, so AC's best is not taken from them
local deletedByAC = {}         -- per entry: AC's lap callback said invalid (else only the app's own observation)
for i = 1, DELETED_N do deletedByAC[i] = false end
local ownBestMs = 0            -- best valid lap seen by the tracker this session
local cutWait, cutWaitMs, cutWaitClock = false, 0, 0   -- cut lap waiting for AC's verdict (callback)
local NOW_WINDOW, NOW_STEP = 3, 0.05  -- s: the split line compares the last 3 s, sampled 20 times a second
local NOW_N = math.floor(NOW_WINDOW / NOW_STEP) + 3
local NOW_SMOOTH = 0.25                -- s: smoothing of the split line, so it does not jump
local nowT, nowD, nowHead, nowCount, nowNext = newList(NOW_N), newList(NOW_N), 0, 0, 0
local secValidNow = false      -- this frame: lap still valid and out of the pits (sector times count)
local partialLineKnown = false -- the out lap's line position is known, not guessed (its sectors may set bests)
-- Line position measured at confirmed crossings, saved per car + track, so an out lap can be split
-- into mini sectors before the first crossing even without a reference.
local lineKnown, knownLine = false, 0
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
local liveSector, liveStart, liveValid = 0, 0, false
local acNow, acSecStart = nil, nil -- AC's delta this frame and at the last sector boundary (nil = none)
local COUNT_WINDOW = 0.5       -- s between lapCount change and timer restart that still belong together
local heldRawT, heldClock = nil, 0 -- timer value before a rejected restart, kept briefly for a late lapCount
local needReset, needSessionReset, wasReplay = false, false, false
local pendingActive, pendingMs, pendingStart, pendingClock = false, 0, 0, 0
local cbClock, cbValid, cbMs, cbCuts = -100, true, 0, nil
local seenACBest, keptACBest = 0, 0   -- AC's best time and its previous value that was not a deleted lap
local prevLapMs, bestFlashMs, bestFlashBefore = 0, 0, 0
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

-- "Previous lap" mode compares strictly with the lap driven just before (the out lap too, from where it was
-- measured) and with nothing else: no saved best, no estimate, no AC delta. The other modes take the chosen
-- reference first, then the other one, then the estimate and the provisional lap.
-- Returns grid, lap ms, line position, kind and the anchor (first lap fraction the grid holds).
local function activeRef()
  if S.referenceKind == 3 then
    if T.prevLapMs > 0 then return prevLapRef, T.prevLapMs, prevLapStart, 5, prevLapAnchor end
    return nil, 0, 0, 0, 0
  end
  if S.referenceKind == 1 then
    if T.sessionRefMs > 0 then return sessionRef, T.sessionRefMs, sessionRefStart, 1, 0 end
    if T.allTimeRefMs > 0 then return allTimeRef, T.allTimeRefMs, allTimeRefStart, 2, 0 end
  else
    if T.allTimeRefMs > 0 then return allTimeRef, T.allTimeRefMs, allTimeRefStart, 2, 0 end
    if T.sessionRefMs > 0 then return sessionRef, T.sessionRefMs, sessionRefStart, 1, 0 end
  end
  if T.estimateMs > 0 then return estimateRef, T.estimateMs, estimateStart, 4, 0 end
  if T.provisionalMs > 0 then return provisionalRef, T.provisionalMs, provisionalStart, 3, 0 end
  return nil, 0, 0, 0, 0
end

-- Best known line position: the reference's, else the measured one, else a saved lap's (nil when unknown).
local function linePosition()
  local ref, _, refStart, kind = activeRef()
  if ref and (kind ~= 4 or estimateStartKnown) then return refStart end
  if lineKnown then return knownLine end
  if T.allTimeRefMs > 0 then return allTimeRefStart end
  if T.sessionRefMs > 0 then return sessionRefStart end
  return nil
end

-- True when a known line position is clearly elsewhere: the timer restarted off the line.
local function awayFromLine(s)
  local line = linePosition()
  return line ~= nil and math.abs(circDiff(s, line)) > 0.03
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
  store.save({ version = 1, lapMs = T.allTimeRefMs, start = allTimeRefStart, grid = grid, sectors = sectors,
    line = lineKnown and knownLine or nil })
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
  local line = tonumber(data.line)
  if line and line >= 0 and line < 1 then lineKnown, knownLine = true, line end
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
    local ref, _, _, kind, anchor = activeRef()
    -- a sector counts on its own: driven without a cut and outside the pits, even if the lap is not clean
    -- (on an out lap only when the line position is known, else the sector would be the wrong stretch)
    local counts = secValidNow and ms > 0 and (T.flying or partialLineKnown)
    local best = S.referenceKind == 1 and sessionBest[j] or allTimeBest[j]
    local useAC = S.referenceKind ~= 3 and acNow and acSecStart and (not ref or kind == 3 or kind == 4)
    local n = T.sectorCount
    if counts and best > 0 and ms < best then
      state = 1
    elseif useAC then
      -- AC's delta (to its valid best lap) beats an estimate: colour by how it changed over the sector
      if math.abs(acNow - acSecStart) >= 0.001 then state = acNow < acSecStart and 2 or 3 else state = 4 end
    elseif ref and (j - 1) / n >= anchor - 1e-9 then
      local refSec = gridAt(ref, j / n) - gridAt(ref, (j - 1) / n)
      if ms < refSec then
        state = 2
      else
        state = 3
      end
    else
      state = 4
    end
    acSecStart = acNow
    if counts then
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
    do   -- full laps from the line, out laps from their first grid point
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
  nowCount = 0                 -- a new lap restarts the delta: the 3 s window must not span the line
  T.flying = flying
  T.partial = false
  skipFirstSector = false
  T.clean = flying and clean ~= false
  lapCut, lapSeenValid = false, false
  curK0 = 0
  T.hasDelta = false
  sectorsLive = true
  curStart = lineSpline or 0
  cur[1] = 0
  nextK, nextSec, lastSecT = 1, 1, 0
  prevU, prevT = 0, 0
  for i = 1, MAX_SECTORS do T.secState[i] = 0 end
  acSecStart = acNow
end

-- Out lap: once the car is on track, measure from here to the line (mini sectors always; delta against
-- the reference when there is one). Line position: reference, measured, or spline zero as a last guess.
local function startPartial(s, t, refStart)
  startLap(false, refStart)
  T.partial = true
  local u0 = lapU(s)
  partialU0, partialT0 = u0, t
  nextSec = math.floor(u0 * T.sectorCount) + 1
  curK0 = math.min(GRID, math.ceil(u0 * GRID - 1e-9))
  nextK = curK0
  skipFirstSector = true
  lastSecT = t
  prevU, prevT = u0, t
end

local function resetLap(reason)
  startLap(false, nil)
  if reason then T.diag.lastReset = reason end
end

local function rememberDeleted(ms, byAC)
  deletedHead = deletedHead % DELETED_N + 1
  deletedLaps[deletedHead], deletedByAC[deletedHead] = ms, byAC == true
end

-- True when ms is (within 2 ms) the time of a lap that was deleted this session.
function T.isDeletedLap(ms)
  if ms <= 0 then return false end
  for i = 1, DELETED_N do
    if deletedLaps[i] > 0 and math.abs(deletedLaps[i] - ms) <= 2 then return true end
  end
  return false
end

-- Keeps the just finished lap (full or out lap) as the "previous lap" reference.
local function keepPreviousLap(lapMs, lineSpline)
  copyList(prevLapRef, cur, GRID + 1)
  for i = 1, curK0 do prevLapRef[i] = cur[curK0 + 1] end   -- before the anchor: flat, never compared
  prevLapRef[GRID + 1] = lapMs
  T.prevLapMs, prevLapStart, prevLapAnchor = lapMs, lineSpline, curK0 / GRID
  T.prevLapPartial = curK0 > 0
end

local function lapFinished(lapMs, now, lineSpline)
  if T.flying or T.partial then advance(1, lapMs) end
  local full = nextK > GRID
  if T.flying and lapConfirmed and full then
    copyList(lastFull, cur, GRID + 1)
    lastFull[GRID + 1] = lapMs
    lastFullMs, lastFullStart, lastFullClock = lapMs, curStart, now
    keepPreviousLap(lapMs, curStart)   -- any fully driven lap (valid or not), the one just finished
  elseif T.partial and full and (partialLineKnown or math.abs(circDiff(lineSpline, curStart)) < 0.003) then
    -- out lap measured to the line with the right line position: the next lap compares with it
    keepPreviousLap(lapMs, curStart)
  end
  local complete = T.flying and T.clean and full
  T.lastLapMs = lapMs
  if complete then
    bestFlashBefore = bestFlashMs
    if bestFlashMs == 0 or lapMs < bestFlashMs then
      T.flashKind = 1
      bestFlashMs = lapMs
    elseif prevLapMs > 0 and lapMs < prevLapMs then
      T.flashKind = 2
    else
      T.flashKind = 3
    end
    prevLapMs = lapMs
    T.lastLapState = 1
    -- keep the finished grid until AC confirms the lap (or the wait runs out)
    cur, cand = cand, cur
    pendingActive, pendingMs, pendingStart, pendingClock = true, lapMs, curStart, now
    T.diag.timedLaps = T.diag.timedLaps + 1
  else
    if T.flying and lapConfirmed and full then offerProvisional(cur, lapMs, curStart) end
    if not T.flying then
      T.diag.lastReject = 'kolo nezačalo průjezdem cílem (out lap z boxu, reset)'
    elseif not T.clean then
      T.diag.lastReject = 'neplatné kolo (řezání podle AC nebo boxová ulička)'
    else
      T.diag.lastReject = 'chybí část kola (záznam nedošel do konce)'
    end
    if T.flying and lapCut then
      -- a cut lap is deleted: red, never the best (unless AC's lap callback still calls it valid)
      T.flashKind, T.lastLapState = 5, 2
      cutWait, cutWaitMs, cutWaitClock = true, lapMs, now
    else
      T.flashKind, T.lastLapState = 4, 3
    end
    if dirty then saveData() end
  end
  T.flashLapMs = lapMs
  T.flashUntil = now + S.lapFlashTime
end

-- A cut lap is deleted once AC's callback agrees (or does not come); AC calling it valid wins.
local function settleCut(now)
  local fresh = cbClock >= cutWaitClock - CALLBACK_WAIT
  if not fresh and now - cutWaitClock < CALLBACK_WAIT then return end
  cutWait = false
  local tookAsBest = seenACBest > 0 and math.abs(seenACBest - cutWaitMs) <= 2
  if (fresh and cbValid) or tookAsBest then
    T.lastLapState = 1
    if T.flashKind == 5 then T.flashKind = (prevLapMs > 0 and cutWaitMs < prevLapMs) and 2 or 3 end
    T.diag.lastDeleted = string.format('nesmazáno: isLapValid=ne na %.0f %% kola, ale AC kolo uznalo%s', lapCutU * 100,
      fresh and '' or ' (vzalo ho jako nejlepší čas)')
  else
    rememberDeleted(cutWaitMs, fresh)
    if fresh and cbMs > 0 then rememberDeleted(cbMs, true) end
    T.diag.lastDeleted = string.format('smazáno: isLapValid=ne na %.0f %% kola, %s', lapCutU * 100,
      fresh and 'AC potvrdilo neplatné' or 'AC kolo nepotvrdilo (callback nepřišel)')
  end
end

local function finalizePending(now)
  if cutWait then settleCut(now) end
  if not pendingActive then return end
  local fresh = cbClock >= pendingClock - CALLBACK_WAIT
  if not fresh and now - pendingClock < CALLBACK_WAIT then return end
  pendingActive = false
  local ms = pendingMs
  local valid = true
  if fresh then
    valid = cbValid
    if cbMs > 0 and math.abs(cbMs - ms) < 1000 then ms = cbMs end
    -- AC's "invalid" without any cut, on a lap we saw clean all the way, is not a deleted lap
    if not valid and cbCuts == 0 then
      valid = true
      T.diag.lastDeleted = 'nesmazáno: AC hlásí neplatné, ale bez řezání (0 cuts)'
    end
  end
  -- AC already took the lap as its best: AC counts it, whatever the callback said
  if not valid and seenACBest > 0 and math.abs(seenACBest - ms) <= 2 then
    valid = true
    T.diag.lastDeleted = 'nesmazáno: AC kolo vzalo jako svůj nejlepší čas'
  end
  if T.lastLapMs == pendingMs then T.lastLapMs = ms end
  if T.flashLapMs == pendingMs then T.flashLapMs = ms end
  if not valid then
    T.diag.lastReject = 'AC kolo po dojetí označilo jako neplatné'
    T.diag.lastDeleted = string.format('smazáno: AC po dojetí valid=ne, řezů %s', cbCuts and tostring(cbCuts) or '?')
    offerProvisional(cand, ms, pendingStart)   -- only confirmed laps get this far
    -- the lap was deleted: not the best, shown red
    if bestFlashMs == pendingMs then bestFlashMs = bestFlashBefore end
    T.flashKind, T.lastLapState = 5, 2
    rememberDeleted(ms, true)
    rememberDeleted(pendingMs, true)
  end
  if valid then
    T.diag.references = T.diag.references + 1
    if ownBestMs == 0 or ms < ownBestMs then ownBestMs = ms end
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

-- AC confirmed our last recorded lap as its best lap: it is valid, whatever our own checks said.
local function adoptACBest(car, now)
  if lastFullMs <= 0 then return end
  if now - lastFullClock > 3 then lastFullMs = 0; return end
  local best = car.bestLapTimeMs
  if best <= 0 or math.abs(best - lastFullMs) > 15 then return end
  if T.isDeletedLap(best) then return end
  lastFullMs = 0
  if T.sessionRefMs > 0 and best >= T.sessionRefMs - 1 then return end
  lastFull[GRID + 1] = best
  copyList(sessionRef, lastFull, GRID + 1)
  T.sessionRefMs, sessionRefStart = best, lastFullStart
  T.diag.references = T.diag.references + 1
  T.diag.lastReject = 'kolo uznané podle nejlepšího času AC'
  if ownBestMs == 0 or best < ownBestMs then ownBestMs = best end
  if T.allTimeRefMs == 0 or best < T.allTimeRefMs then
    copyList(allTimeRef, lastFull, GRID + 1)
    T.allTimeRefMs, allTimeRefStart = best, lastFullStart
    saveData()
  end
end

-- No own valid reference but AC knows a best lap: scale the provisional lap's shape (or even pace)
-- to that time. Rebuilt only when the best time or the shape changes.
local function updateEstimate(car)
  local best = car.bestLapTimeMs
  if best <= 0 or T.sessionRefMs > 0 or T.allTimeRefMs > 0 or S.deltaSource == 2 then
    T.estimateMs = 0
    return
  end
  -- only with the shape of a really driven lap: an even-pace guess made the first-lap delta jump around
  local shape = T.provisionalMs
  if shape <= 0 then
    T.estimateMs = 0
    return
  end
  if best == T.estimateMs and shape == estimateShape then return end
  T.estimateMs, estimateShape = best, shape
  local k = best / shape
  for i = 1, GRID + 1 do estimateRef[i] = provisionalRef[i] * k end
  estimateStart, estimateStartKnown = provisionalStart, true
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

-- Own delta against the reference at the same place on track.
-- An out lap as the reference holds AC's lap timer, which runs from the pit box like a whole lap, so it is
-- compared directly (the pit lane counts too, the delta at the line equals the lap time difference); there is
-- nothing to compare before its first measured point. The current out lap against a full lap counts from the pit exit.
local function ownDelta(ref, refStart, anchor, s, t)
  local shift = circDiff(curStart, refStart)       -- reference u = current u + shift
  local u = lapU(s)
  if T.partial then
    u = math.max(partialU0, u)
  elseif prevU > 0.9 and u < 0.5 then
    u = 1                                          -- just past the line, AC has not counted the lap yet
  end
  local uRef = u + shift
  if uRef < 0 then uRef = 0 elseif uRef > 1 then uRef = 1 end
  if anchor > 0 then
    if uRef < anchor then return nil end
    return (t - gridAt(ref, uRef)) / 1000
  end
  if not T.partial then
    return (t - gridAt(ref, uRef)) / 1000
  end
  local u0Ref = partialU0 + shift
  if u0Ref < 0 then u0Ref = 0 elseif u0Ref > 1 then u0Ref = 1 end
  return ((t - partialT0) - (gridAt(ref, uRef) - gridAt(ref, u0Ref))) / 1000
end

local function updateDelta(dt, s, t, car)
  local ref, refMs, refStart, kind, anchor = activeRef()
  T.refMs, T.refKind = refMs, kind
  local own = S.deltaSource ~= 3 and (T.flying or T.partial) and ref
  -- "previous lap" mode never falls back to AC's delta (that compares with AC's best lap)
  local strict = S.referenceKind == 3 and S.deltaSource ~= 3
  if not strict and (not own or kind == 3 or kind == 4) then
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
  local raw = own and ownDelta(ref, refStart, anchor, s, t)
  if raw then
    T.status = kind == 3 and 'Delta proti dočasnému kolu (out lap nebo neplatné), platné kolo ho nahradí'
      or kind == 4 and 'Delta proti nejlepšímu času z AC (odhad průběhu kola)' or nil
    smoothInto(raw, dt)
  else
    T.hasDelta = false
    if own then
      T.status = 'Delta: předchozí kolo (out lap) začalo dál, porovnává se od tohoto místa'
    elseif S.deltaSource == 3 then
      T.status = 'Delta z AC: AC zatím nemá nejlepší kolo'
    elseif strict then
      T.status = 'Delta: zatím není předchozí kolo, porovnává se od dalšího kola'
    elseif T.partial then
      T.status = 'Out lap: mini sektory se měří, delta až s referencí'
    elseif not T.flying then
      T.status = 'Delta: čekám na průjezd cílovou čárou'
    else
      T.status = 'Delta: první kolo, zatím není s čím porovnat (od dalšího průjezdu cílem už ano)'
    end
  end
end

-- AC took a deleted lap as its best lap: AC counts it, so it is valid (AC does not keep invalid laps as its best).
-- The best time AC shows is the final word; the app never hides a lap AC counts.
local function undeleteIfACBest(ms)
  local found = false
  for i = 1, DELETED_N do
    if deletedLaps[i] > 0 and math.abs(deletedLaps[i] - ms) <= 2 then
      deletedLaps[i], found = 0, true
    end
  end
  if not found then return end
  if ownBestMs == 0 or ms < ownBestMs then ownBestMs = ms end
  if math.abs(T.lastLapMs - ms) <= 2 then
    T.lastLapState = 1
    if T.flashKind == 5 then
      if bestFlashMs == 0 or ms < bestFlashMs then T.flashKind, bestFlashMs = 1, ms
      else T.flashKind = (prevLapMs > 0 and ms < prevLapMs) and 2 or 3 end
    end
  end
  T.diag.lastDeleted = 'nesmazáno: AC kolo vzalo jako svůj nejlepší čas'
end

-- Validity of the running timed lap. AC may still report the previous lap (an out lap is always invalid) for a while
-- after the line, so only a change from valid to invalid within this lap is a cut.
local function checkValidity(car)
  if car.isInPitlane then T.clean = false end
  if car.isLapValid then
    lapSeenValid = true
    return
  end
  if not lapSeenValid then return end
  T.clean = false
  if not lapCut and not car.isInPitlane and not car.isInPit then lapCut, lapCutU = true, prevU end
end

local function updateTiming(sim, car, now)
  T.position = car.racePosition
  T.carsCount = sim.carsCount
  T.lap = car.lapCount + 1
  T.currentMs = car.lapTimeMs
  -- AC's best, unless it is a lap that was deleted: then AC's best before it, or the tracker's own best valid lap
  local best = car.bestLapTimeMs
  T.acBestMs = best
  if best ~= seenACBest then
    if best > 0 then undeleteIfACBest(best) end
    if seenACBest > 0 and not T.isDeletedLap(seenACBest) and (keptACBest == 0 or seenACBest < keptACBest) then
      keptACBest = seenACBest
    end
    seenACBest = best
  end
  if best > 0 and T.isDeletedLap(best) then
    best = keptACBest
    if ownBestMs > 0 and (best == 0 or ownBestMs < best) then best = ownBestMs end
  end
  T.bestMs = best
  if now - sessionCheckClock > 1 then
    sessionCheckClock = now
    local session = ac.getSession(sim.currentSessionIndex)
    T.totalLaps = (session and not session.isTimedRace and session.laps) or 0
  end
end

-- Delta trends for the delta line, kept out of updateInner (LuaJIT allows at most 60 upvalues per function).
local function updateTrend(now, dt)
  -- split delta line: how the delta moved over the last 3 s. The value 3 s ago is interpolated between the two
  -- ring buffer samples around it (20 Hz), and the result is smoothed, so the line glides instead of stepping.
  if T.hasDelta then
    if now >= nowNext then
      nowNext = now + NOW_STEP
      nowHead = nowHead % NOW_N + 1
      nowT[nowHead], nowD[nowHead] = now, T.delta
      if nowCount < NOW_N then nowCount = nowCount + 1 end
    end
    local target, old = now - NOW_WINDOW, nil
    if nowCount > 1 then
      local idx = (nowHead - nowCount) % NOW_N + 1   -- oldest sample (the buffer restarts at every lap)
      local prev = nil
      for _ = 1, nowCount do
        if nowT[idx] >= target then
          if prev and nowT[idx] > nowT[prev] then
            old = nowD[prev] + (nowD[idx] - nowD[prev]) * (target - nowT[prev]) / (nowT[idx] - nowT[prev])
          else
            old = nowD[idx]
          end
          break
        end
        prev = idx
        idx = idx % NOW_N + 1
      end
    end
    local raw = old and T.delta - old or 0
    T.nowDelta = T.nowDelta + (raw - T.nowDelta) * (1 - math.exp(-dt / NOW_SMOOTH))
  else
    nowCount = 0
    T.nowDelta = T.nowDelta * math.exp(-dt / NOW_SMOOTH)
  end

  -- live trend for the delta line: how the delta moved since the current mini sector started
  if T.hasDelta then
    if not liveValid or T.curSector ~= liveSector then
      liveSector, liveStart, liveValid = T.curSector, T.delta, true
    end
    T.liveDelta = T.delta - liveStart
    if T.liveDelta < -LIVE_HYSTERESIS then T.liveSign = -1
    elseif T.liveDelta > LIVE_HYSTERESIS then T.liveSign = 1 end
  else
    liveValid, T.liveDelta = false, 0
  end
end

-- New session or restart: everything that belongs to the session starts over (saved data stays).
local function resetSession()
  needSessionReset = false
  T.sessionRefMs, T.provisionalMs, T.estimateMs, estimateShape, lastFullMs = 0, 0, 0, -1, 0
  T.prevLapMs = 0
  for i = 1, MAX_SECTORS do sessionBest[i] = 0 end
  bestFlashMs, prevLapMs, ownBestMs = 0, 0, 0
  T.lastLapMs, T.lastLapState, T.prevLapPartial = 0, 0, false
  for i = 1, DELETED_N do deletedLaps[i], deletedByAC[i] = 0, false end
  cutWait, seenACBest, keptACBest = false, 0, 0
  pendingActive = false
  T.flashUntil = 0
  prevLapCount = -1
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
  secValidNow = car.isLapValid and not car.isInPitlane and not car.isInPit
  adoptACBest(car, now)
  updateEstimate(car)

  if needSessionReset then resetSession() end

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
    lapFinished(lapMs, now, lineSpline)
    -- a lap starting in the pit lane is recorded too (provisional reference), it just is not clean
    local base = not car.isInPitlane and not car.isInPit
    startLap(true, lineSpline, base)
    lapConfirmed = now - lastCountChange < COUNT_WINDOW
    cleanIfConfirmed = base
    if not lapConfirmed then T.clean = false end
    if lapConfirmed and (not lineKnown or math.abs(circDiff(lineSpline, knownLine)) > 0.002) then
      lineKnown, knownLine = true, lineSpline
      estimateShape = -1          -- rebuild the estimate with the measured line
      saveData()
    end
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
    local line = linePosition()
    startPartial(s, t, line or 0)
    partialLineKnown = line ~= nil
  elseif T.flying then
    local u = lapU(s)
    if prevU > 0.9 and u < 0.5 then
      -- past the measured line, but AC has not counted the lap: wait a little, then give up
      if u > LINE_WAIT then resetLap('projel cílem, ale AC kolo nezapočítalo') end
    elseif u > prevU then
      advance(u, t)
    end
    checkValidity(car)
  end
  prevSpline, prevRawT = s, t
  if heldRawT then
    if now - heldClock < COUNT_WINDOW then prevRawT = heldRawT else heldRawT = nil end
  end

  finalizePending(now)
  local u = (T.flying or T.partial) and lapU(s) or s
  T.curSector = math.min(T.sectorCount, math.floor(u * T.sectorCount) + 1)
  updateDelta(dt, s, t, car)

  updateTrend(now, dt)
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
  T.allTimeRefMs, T.sessionRefMs, T.provisionalMs, T.estimateMs, estimateShape = 0, 0, 0, 0, -1
  T.prevLapMs = 0
  lineKnown = false             -- learned and saved again at the next crossing
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
  -- arguments as in CSP's own p2p mode: carIndex, lapTime, valid, cuts, lapsCount, ...
  ac.onLapCompleted(0, function (carIndex, lapTime, valid, cuts)
    cbClock, cbValid, cbMs, cbCuts = os.preciseClock(), valid ~= false, tonumber(lapTime) or 0, tonumber(cuts)
    T.diag.callbacks = T.diag.callbacks + 1
    T.diag.lastCallback = string.format('%d ms, valid=%s, řezů %s', cbMs, tostring(valid), tostring(cuts))
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
