-- Notifications: watches the session and queues short messages for the notification window.
-- Disconnects are only reported online (AI cars offline are not "connected" in the same sense).
-- Flags and the own car are checked every frame, other cars 10 times a second.
-- Strings are only built when an event fires, never per frame.

local config = require('src/config')
local D = require('src/draw')
local tracker = require('src/tracker')
local S = config.S

local N = { count = 0, lastLine = '-' }   -- count and last text for the Diagnostika tab

-- Kinds; colour and tag live in notify_window.lua.
N.FASTEST, N.DISCONNECT, N.PIT_IN, N.PIT_OUT, N.GAIN, N.LOSS = 1, 2, 3, 4, 5, 6
N.YELLOW, N.BLUE, N.BLACK, N.LAST_LAP, N.FINISH, N.INVALID, N.PENALTY = 7, 8, 9, 10, 11, 12, 13

local MAX_EVENTS = 8
local MAX_CARS = 64
local POLL = 0.1             -- s between checks of the other cars
local QUIET = 2              -- s without notifications after a session start (initial state is not news)
local POSITION_HOLD = 1      -- s a new position must hold, so side by side does not flicker
local FLAG_REPEAT = 15       -- s before the same flag is announced again

local events = {}
for i = 1, MAX_EVENTS do events[i] = { kind = 0, title = '', sub = '', line = '', born = -1000 } end
local head = 0

function N.push(kind, title, sub)
  head = head % MAX_EVENTS + 1
  local e = events[head]
  e.kind, e.title, e.sub = kind, title, sub or ''
  e.line = e.sub ~= '' and (title .. '  ·  ' .. e.sub) or title
  e.born = os.preciseClock()
  N.count = N.count + 1
  N.lastLine = e.line
end

-- The i-th newest event (1 = newest), or nil.
function N.get(i)
  if i > MAX_EVENTS then return nil end
  local e = events[(head - i) % MAX_EVENTS + 1]
  if e.kind == 0 then return nil end
  return e
end

function N.clear()
  for i = 1, MAX_EVENTS do events[i].kind = 0 end
end

-- A few sample notifications for placing the window.
function N.demo()
  N.push(N.FASTEST, 'NEJRYCHLEJŠÍ KOLO', 'Ukázkový jezdec · 1:42.345')
  N.push(N.GAIN, 'POSUN NA P3', 'Předjel jste ukázkového jezdce')
end

-- Flags AC reports (ac.FlagType values marked "works" in the SDK).
local FLAGS = {}
local function flag(key, kind, title, sub)
  local value = ac.FlagType and ac.FlagType[key]
  if value then FLAGS[value] = { kind, title, sub } end
end
flag('Caution', N.YELLOW, 'ŽLUTÁ VLAJKA', 'Pozor, nebezpečí na trati')
flag('FasterCar', N.BLUE, 'MODRÁ VLAJKA', 'Pusťte rychlejší auto')
flag('Stop', N.BLACK, 'ČERNÁ VLAJKA', 'Zajeďte do boxů')
flag('ReturnToPits', N.PENALTY, 'PENALIZACE', 'Zajeďte do boxů')
flag('OneLapLeft', N.LAST_LAP, 'POSLEDNÍ KOLO', 'Bílá vlajka')
flag('Finished', N.FINISH, 'CÍL', 'Konec session')

local wasPit, wasConnected, lastBest = {}, {}, {}
for i = 0, MAX_CARS - 1 do wasPit[i], wasConnected[i], lastBest[i] = false, true, 0 end
local flagClock = {}
local ready, sessionIndex, quietUntil, pollClock = false, -1, 0, 0
local overallBest, lastFlag, lastLapCount = 0, 0, 0
local myPos, pendingPos, pendingSince, wasValid = 0, 0, 0, true
local isRace = false

local function driverName(i)
  local ok, name = pcall(ac.getDriverName, i)
  if ok and type(name) == 'string' and name ~= '' then return name end
  return 'Auto ' .. (i + 1)
end

local function carAt(position)
  local n = math.min(MAX_CARS, ac.getSim().carsCount)
  for i = 1, n - 1 do
    local c = ac.getCar(i)
    if c and c.racePosition == position then return i end
  end
  return nil
end

-- Takes the current state as the starting point, without announcing it.
local function snapshot(sim)
  local n = math.min(MAX_CARS, sim.carsCount)
  overallBest = 0
  for i = 0, n - 1 do
    local c = ac.getCar(i)
    if c then
      wasPit[i] = c.isInPitlane
      wasConnected[i] = c.isConnected ~= false
      lastBest[i] = c.bestLapTimeMs
      if c.bestLapTimeMs > 0 and (overallBest == 0 or c.bestLapTimeMs < overallBest) then overallBest = c.bestLapTimeMs end
    end
  end
  local me = ac.getCar(0)
  myPos = me and me.racePosition or 0
  pendingPos = myPos
  wasValid = not me or me.isLapValid
  lastLapCount = me and me.lapCount or 0
  lastFlag = sim.raceFlagType or 0
  local session = ac.getSession(sim.currentSessionIndex)
  isRace = session ~= nil and ac.SessionType ~= nil and session.type == ac.SessionType.Race
  quietUntil = os.preciseClock() + QUIET
  ready = true
end

local function pollCars(sim, quiet)
  local n = math.min(MAX_CARS, sim.carsCount)
  local minBest = 0
  for i = 0, n - 1 do
    local c = ac.getCar(i)
    if c then
      local best = c.bestLapTimeMs
      if best > 0 then
        if best ~= lastBest[i] then
          lastBest[i] = best
          if overallBest == 0 or best < overallBest then
            overallBest = best
            if not quiet and S.notifyFastest then
              N.push(N.FASTEST, 'NEJRYCHLEJŠÍ KOLO', driverName(i) .. ' · ' .. D.formatLap(best, 3))
            end
          end
        end
        if minBest == 0 or best < minBest then minBest = best end
      else
        lastBest[i] = 0
      end
      if i > 0 then
        local pit = c.isInPitlane
        if pit ~= wasPit[i] then
          wasPit[i] = pit
          if not quiet and S.notifyPits and (isRace or not S.notifyRaceOnly) then
            N.push(pit and N.PIT_IN or N.PIT_OUT, pit and 'V BOXECH' or 'Z BOXŮ', driverName(i))
          end
        end
        local connected = c.isConnected ~= false
        if connected ~= wasConnected[i] then
          wasConnected[i] = connected
          if not quiet and not connected and S.notifyConnections and sim.isOnlineRace then
            N.push(N.DISCONNECT, 'ODPOJIL SE', driverName(i))
          end
        end
      end
    end
  end
  if minBest == 0 then overallBest = 0 end   -- nobody has a lap (restart): the next lap is the fastest
end

local function pollPosition(me, now, quiet)
  local pos = me.racePosition
  if pos ~= pendingPos then pendingPos, pendingSince = pos, now end
  if pendingPos == myPos or now - pendingSince < POSITION_HOLD then return end
  local from, to = myPos, pendingPos
  myPos = to
  if quiet or from <= 0 or to <= 0 or not S.notifyPositions or (S.notifyRaceOnly and not isRace) then return end
  if to < from then
    local other = carAt(to + 1)
    N.push(N.GAIN, 'POSUN NA P' .. to, other and ('Předjel jste: ' .. driverName(other)) or '')
  else
    local other = carAt(to - 1)
    N.push(N.LOSS, 'ZTRÁTA NA P' .. to, other and ('Předjel vás: ' .. driverName(other)) or '')
  end
end

function N.update()
  local sim = ac.getSim()
  if not sim or sim.isReplayActive then
    ready = false
    return
  end
  local me = ac.getCar(0)
  if not me then return end
  if not ready or sim.currentSessionIndex ~= sessionIndex or me.lapCount < lastLapCount then
    sessionIndex = sim.currentSessionIndex
    snapshot(sim)
    return
  end
  lastLapCount = me.lapCount
  local now = os.preciseClock()
  local quiet = now < quietUntil

  local f = sim.raceFlagType or 0
  if f ~= lastFlag then
    lastFlag = f
    local info = FLAGS[f]
    if info and not quiet and S.notifyFlags and now - (flagClock[info[1]] or -100) > FLAG_REPEAT then
      flagClock[info[1]] = now
      N.push(info[1], info[2], info[3])
    end
  end

  local valid = me.isLapValid
  if valid ~= wasValid then
    wasValid = valid
    -- only on a timed lap: AC also marks out laps and pit exits invalid, that is not news
    if not valid and not quiet and S.notifyInvalid and tracker.flying and not me.isInPitlane then
      N.push(N.INVALID, 'NEPLATNÉ KOLO', 'Řezání trati, kolo se nezapočítá')
    end
  end

  pollPosition(me, now, quiet)
  if now >= pollClock then
    pollClock = now + POLL
    pollCars(sim, quiet)
  end
end

return N
