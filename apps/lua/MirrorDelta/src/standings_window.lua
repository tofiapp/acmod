-- Standings window (bottom centre): replaces AC's overlay leaderboard (F9), which originals.lua turns off.
-- One row: the player and the cars around them in AC's order (car.racePosition), each a tile with the position,
-- a short name and a gap: in a race the gap on track to the player (from lap count and spline position, in seconds
-- at the player's speed), otherwise the best lap difference to the player's best lap.
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
local names, nameSource = {}, {}          -- short names per car index
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
local function shortName(full)
  local last = full
  for word in full:gmatch('[^%s]+') do
    if word:find('[%a\128-\255]') then last = word end      -- the last word with a letter ("Jezdec 1" -> "Jezdec")
  end
  local out, letters, i = {}, 0, 1
  while i <= #last and letters < 3 do
    local c = last:sub(i, i)
    local b = c:byte()
    if b >= 0xC0 then                      -- two-byte UTF-8 letter
      local ch = last:sub(i, i + 1)
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

local function refreshNames(n)
  for i = 0, n - 1 do
    local ok, name = pcall(ac.getDriverName, i)
    name = ok and type(name) == 'string' and name ~= '' and name or ('AUTO ' .. (i + 1))
    if nameSource[i] ~= name then nameSource[i], names[i] = name, shortName(name) end
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

-- Gap text of car i relative to the player, cached by its value (tenths of a second / milliseconds / laps).
local function gapText(i, me, sim)
  local c = ac.getCar(i)
  if not c then return '' end
  if isRace then
    local length = sim.trackLengthM or 0
    if length <= 0 then return '' end
    local laps = (c.lapCount + c.splinePosition) - (me.lapCount + me.splinePosition)   -- + = ahead of the player
    if math.abs(laps) >= 1 then
      local whole = laps > 0 and math.floor(laps) or -math.floor(-laps)
      local key = 100000 + whole
      if gapKey[i] ~= key then
        gapKey[i], gapStr[i] = key, string.format('%+d KOLO', whole)
      end
      return gapStr[i]
    end
    local seconds = laps * length / math.max(20, me.speedKmh / 3.6)
    local key = math.floor(seconds * 10 + 0.5)
    if gapKey[i] ~= key then
      gapKey[i], gapStr[i] = key, (string.format('%+.1f', -key / 10):gsub('%.', ','))
    end
    return gapStr[i]
  end
  local best, mine = c.bestLapTimeMs, me.bestLapTimeMs
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
  if gapKey[i] ~= key then gapKey[i], gapStr[i] = key, (string.format('%+.3f', key / 1000):gsub('%.', ',')) end
  return gapStr[i]
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
  local baseW = want * BASE_TILE_W + (want - 1) * GAP
  local sc = math.min(w / baseW, h / BASE_H)
  local x = (w - baseW * sc) / 2
  local a = S.opacity
  local tw, th = BASE_TILE_W * sc, BASE_H * sc
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
      D.text(names[i] or '', 15 * sc, x + 38 * sc, 0, 40 * sc, th, D.ALIGN_START, col(ink, a))
      local gap, gapColor
      if c.isInPitlane and not mine then
        gap, gapColor = 'BOX', PIT
      elseif mine then
        gap, gapColor = myText(me), INK
      else
        gap, gapColor = gapText(i, me, sim), j < playerRank and AHEAD or BEHIND
      end
      D.text(gap, 13 * sc, x + 70 * sc, 0, tw - 76 * sc, th, D.ALIGN_END, col(gapColor, a))
    end
    x = x + tw + GAP * sc
  end
  ui.popDWriteFont()
  M.count, M.first = want, first
end

return M
