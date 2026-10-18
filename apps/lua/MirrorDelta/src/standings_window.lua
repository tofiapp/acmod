-- Standings window (bottom centre): replaces AC's overlay leaderboard (F9), which originals.lua turns off.
-- One row: the player and the cars around them in AC's order (car.racePosition), each a tile with the position,
-- a name and a gap to the player or to the car ahead (setting). In a race the gap is either live (distance on track
-- at the player's speed) or measured like a timing loop: every car's crossing time of evenly spaced checkpoints
-- (S.standingsSectors per lap) is recorded each frame (interpolated inside the frame), and the gap is the
-- difference of two cars' times at the last checkpoint both passed: after every sector, or only at the line.
-- Outside a race: best lap difference.
-- Fields as in the official apps / notify.lua: racePosition, lapCount, splinePosition, bestLapTimeMs, isInPitlane,
-- isConnected, ac.getDriverName, ac.getSession(i).type, sim.trackLengthM. The order is refreshed 4 times a second,
-- names every few seconds; strings are cached, nothing is allocated per frame.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local MAX_CARS = 64
local BASE_TILE_W, BASE_H, GAP = 118, 40, 6
local REFRESH, NAME_REFRESH = 0.25, 5

local order, count = {}, 0                -- car indices in AC's order
for i = 1, MAX_CARS do order[i] = 0 end
local names, fullNames, nameSource = {}, {}, {}   -- per car index: 3 letters, surname

-- timing loop: per car the continuous progress (laps + spline), the last checkpoint index passed and a ring of
-- crossing times (RING slots, enough for two laps at the most checkpoints)
local RING = 32
local loopClock = 0
local prevQ, lastIdx, ringT, ringP = {}, {}, {}, {}
local loopK = 0
local gapKey, gapStr = {}, {}             -- per car index: last gap key and its text
local nextRefresh, nextNames = 0, 0
local isRace, raceCheck = false, -100
local playerRank = 0

local TILE = rgbm(0.06, 0.07, 0.09, 0.82)
local ME = rgbm(0.93, 0.94, 0.96, 0.95)
local POS = rgbm(0.96, 0.96, 0.97, 1)
local NAME = rgbm(0.9, 0.91, 0.93, 1)
local INK = rgbm(0.07, 0.08, 0.1, 1)
local AHEAD = rgbm(1, 0.45, 0.4, 1)       -- car ahead (gap to it, it is in front)
local BEHIND = rgbm(0.35, 0.9, 0.5, 1)    -- car behind
local PIT = rgbm(0.3, 0.6, 1, 1)
local tint = rgbm()

local M = { count = 0, first = 0 }        -- for tests: entries and first rank drawn

local function col(c, a)
  tint:set(c)
  tint.mult = c.mult * a
  return tint
end

-- "Jan Novák" -> "NOV" (last word, three letters, upper case incl. Czech letters via originals-style map).
local UPPER = { ['á'] = 'Á', ['č'] = 'Č', ['ď'] = 'Ď', ['é'] = 'É', ['ě'] = 'Ě', ['í'] = 'Í', ['ň'] = 'Ň',
  ['ó'] = 'Ó', ['ř'] = 'Ř', ['š'] = 'Š', ['ť'] = 'Ť', ['ú'] = 'Ú', ['ů'] = 'Ů', ['ý'] = 'Ý', ['ž'] = 'Ž' }
local function upperWord(word, maxLetters)
  local out, letters, i = {}, 0, 1
  while i <= #word and letters < maxLetters do
    local c = word:sub(i, i)
    if c:byte() >= 0xC0 then               -- two-byte UTF-8 letter
      local ch = word:sub(i, i + 1)
      out[#out + 1] = UPPER[ch] or ch
      i = i + 2
    else
      out[#out + 1] = c:upper()
      i = i + 1
    end
    letters = letters + 1
  end
  return table.concat(out)
end

local function lastWord(full)
  local last = full
  for word in full:gmatch('[^%s]+') do
    if word:find('[%a\128-\255]') then last = word end      -- the last word with a letter ("Jezdec 1" -> "Jezdec")
  end
  return last
end

local function refreshNames(n)
  for i = 0, n - 1 do
    local ok, name = pcall(ac.getDriverName, i)
    name = ok and type(name) == 'string' and name ~= '' and name or ('AUTO ' .. (i + 1))
    if nameSource[i] ~= name then
      local last = lastWord(name)
      nameSource[i], names[i], fullNames[i] = name, upperWord(last, 3), upperWord(last, 9)
    end
  end
end

local function byPosition(a, b)
  local ca, cb = ac.getCar(a), ac.getCar(b)
  local pa, pb = ca and ca.racePosition or 0, cb and cb.racePosition or 0
  if pa <= 0 then pa = 1000 + a end
  if pb <= 0 then pb = 1000 + b end
  return pa < pb
end

local function refresh(sim, now)
  local n = math.min(MAX_CARS, sim.carsCount)
  if now >= nextNames then
    nextNames = now + NAME_REFRESH
    refreshNames(n)
  end
  if now - raceCheck > 2 then
    raceCheck = now
    local session = ac.getSession(sim.currentSessionIndex)
    isRace = session ~= nil and ac.SessionType ~= nil and session.type == ac.SessionType.Race
  end
  count = 0
  for i = 0, n - 1 do
    local c = ac.getCar(i)
    if c and (i == 0 or c.isConnected ~= false) then
      count = count + 1
      order[count] = i
    end
  end
  for j = count + 1, MAX_CARS do order[j] = nil end
  table.sort(order, byPosition)
  for j = count + 1, MAX_CARS do order[j] = 0 end
  playerRank = 1
  for j = 1, count do if order[j] == 0 then playerRank = j end end
end

-- Crossing time of car i at checkpoint index p (nil when not recorded).
local function crossTime(i, p)
  local rp = ringP[i]
  if not rp then return nil end
  local slot = p % RING + 1
  if rp[slot] ~= p then return nil end
  return ringT[i][slot]
end

local function cacheGap(i, key, fmt, value)
  if gapKey[i] ~= key then gapKey[i], gapStr[i] = key, (string.format(fmt, value):gsub('%.', ',')) end
  return gapStr[i]
end

-- Gap text of car i relative to car r (the player or the car ahead), cached by value. Negative: i is ahead of r.
local function gapText(i, r, sim)
  local c, ref = ac.getCar(i), ac.getCar(r)
  if not c or not ref then return '' end
  if isRace then
    local laps = (c.lapCount + c.splinePosition) - (ref.lapCount + ref.splinePosition)   -- + = i ahead of r
    if math.abs(laps) >= 1 then
      local whole = laps > 0 and math.floor(laps) or -math.floor(-laps)
      if gapKey[i] ~= 100000 + whole then
        gapKey[i], gapStr[i] = 100000 + whole, string.format('%+d KOLO', -whole)
      end
      return gapStr[i]
    end
    if S.standingsGapMode == 1 or loopK == 0 then
      local length = sim.trackLengthM or 0
      if length <= 0 then return '' end
      local me = ac.getCar(0)
      local seconds = laps * length / math.max(20, me.speedKmh / 3.6)
      local key = math.floor(-seconds * 10 + 0.5)
      return cacheGap(i, key, '%+.1f', key / 10)
    end
    -- timing loop: the last checkpoint both cars passed (only the line in mode 3)
    local pi, pr = lastIdx[i], lastIdx[r]
    if not pi or not pr then return gapStr[i] or '–' end
    local common = math.min(pi, pr)
    if S.standingsGapMode == 3 then common = math.floor(common / loopK) * loopK end
    local ti, tr = crossTime(i, common), crossTime(r, common)
    if not ti or not tr then return gapStr[i] or '–' end
    local key = math.floor((ti - tr) * 10 + 0.5)
    return cacheGap(i, key, '%+.1f', key / 10)
  end
  local best, mine = c.bestLapTimeMs, ref.bestLapTimeMs
  if best <= 0 then
    if gapKey[i] ~= -1e9 then gapKey[i], gapStr[i] = -1e9, '–' end
    return gapStr[i]
  end
  if mine <= 0 then
    local key = -2e9 - best
    if gapKey[i] ~= key then gapKey[i], gapStr[i] = key, (D.formatLap(best, 1):gsub('%.', ',')) end
    return gapStr[i]
  end
  local key = best - mine
  return cacheGap(i, key, '%+.3f', key / 1000)
end

-- Runs every frame from script.update: records checkpoint crossing times of every car (timing loop).
function M.update(dt)
  local sim = ac.getSim()
  if not sim or sim.isPaused or sim.isReplayActive then return end
  loopClock = loopClock + dt
  local k = math.max(1, math.min(12, math.floor(S.standingsSectors)))
  if k ~= loopK then
    loopK = k
    for i in pairs(prevQ) do prevQ[i] = nil end
  end
  local n = math.min(MAX_CARS, sim.carsCount)
  for i = 0, n - 1 do
    local c = ac.getCar(i)
    if c and c.splinePosition and c.lapCount then
      local q = c.lapCount + c.splinePosition
      local pq = prevQ[i]
      if not pq or math.abs(q - pq) > 0.5 or c.isInPit then
        lastIdx[i] = math.floor(q * k)              -- start (or teleport, pits): nothing crossed yet
      else
        local p = math.floor(q * k)
        if p > lastIdx[i] and q > pq then
          if not ringT[i] then
            ringT[i], ringP[i] = {}, {}
            for j = 1, RING do ringT[i][j], ringP[i][j] = 0, -1 end
          end
          while lastIdx[i] < p do
            local idx = lastIdx[i] + 1
            local frac = (idx / k - pq) / (q - pq)
            local slot = idx % RING + 1
            ringT[i][slot], ringP[i][slot] = loopClock - dt * (1 - math.max(0, math.min(1, frac))), idx
            lastIdx[i] = idx
          end
        end
      end
      prevQ[i] = q
    end
  end
end

local myBestCache = { key = -1, str = '' }
local function myText(me)
  local best = me.bestLapTimeMs
  local key = best > 0 and best or -1
  if myBestCache.key ~= key then
    myBestCache.key = key
    myBestCache.str = best > 0 and (D.formatLap(best, 3):gsub('%.', ',')) or 'JÁ'
  end
  return myBestCache.str
end

local posStrings = {}
local function posText(p)
  local str = posStrings[p]
  if not str then str = p > 0 and tostring(p) or '-'; posStrings[p] = str end
  return str
end

function M.draw()
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  local sim = ac.getSim()
  local me = ac.getCar(0)
  if not sim or not me then return end
  local now = os.preciseClock()
  if now >= nextRefresh then
    nextRefresh = now + REFRESH
    refresh(sim, now)
  end
  if count == 0 then return end

  -- the player and the cars around them, as many as the setting says (odd number, player in the middle)
  local want = math.max(1, math.min(count, math.floor(S.standingsCount)))
  local first = math.max(1, math.min(playerRank - math.floor(want / 2), count - want + 1))
  local nameMode = S.standingsNames
  local tileW = nameMode == 2 and BASE_TILE_W + 34 or nameMode == 3 and BASE_TILE_W - 36 or BASE_TILE_W
  local baseW = want * tileW + (want - 1) * GAP
  local sc = math.min(w / baseW, h / BASE_H)
  local x = (w - baseW * sc) / 2
  local a = S.opacity
  local tw, th = tileW * sc, BASE_H * sc
  local nameW = nameMode == 2 and 74 or nameMode == 3 and 0 or 40
  local toAhead = S.standingsGapTo == 2
  ui.pushDWriteFont(D.FONT)
  for j = first, first + want - 1 do
    local i = order[j]
    local c = ac.getCar(i)
    if c then
      local mine = i == 0
      D.rect(x, 0, x + tw, th, col(mine and ME or TILE, a), 6 * sc)
      local ink = mine and INK or NAME
      D.text(posText(c.racePosition > 0 and c.racePosition or j), 18 * sc, x + 6 * sc, 0, 30 * sc, th, D.ALIGN_CENTER,
        col(mine and INK or POS, a))
      if nameMode ~= 3 then
        D.text((nameMode == 2 and fullNames[i] or names[i]) or '', 15 * sc, x + 38 * sc, 0, nameW * sc, th, D.ALIGN_START, col(ink, a))
      end
      local gap, gapColor
      if c.isInPitlane and not mine then
        gap, gapColor = 'BOX', PIT
      elseif toAhead then
        -- interval to the car ahead (the leader shows its own best lap / nothing)
        if j > 1 then gap = gapText(i, order[j - 1], sim) else gap = mine and myText(me) or '' end
        gapColor = mine and INK or NAME
      elseif mine then
        gap, gapColor = myText(me), INK
      else
        gap = gapText(i, 0, sim)
        gapColor = not S.standingsGapColors and NAME or j < playerRank and AHEAD or BEHIND
      end
      local gx = x + (38 + nameW + 4) * sc
      D.text(gap, 13 * sc, gx, 0, x + tw - 6 * sc - gx, th, D.ALIGN_END, col(gapColor, a))
    end
    x = x + tw + GAP * sc
  end
  ui.popDWriteFont()
  M.count, M.first = want, first
end

return M
