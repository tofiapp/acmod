-- Car settings line: one line at the top of the screen when a driver aid or car setting changes
-- (TC, TC2, ABS, brake bias, engine brake, fuel map, turbo, MGU-K/H, limiters, auto shift, auto clutch).
-- Only car settings: AC's other system messages go to the notifications (originals.lua). AC's own message
-- about a setting is shown only when the app did not read that change itself (no doubles). A new change
-- replaces the line.
-- Car fields are the ones the official Unbound app reads; each is probed once under pcall,
-- so a field missing in an older CSP only disables that one setting.
-- Strings are built only when something changes, never per frame.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local M = { count = 0 }

local BASE_W, BASE_H = 300, 44   -- the panel always has this size (scaled with the window), whatever the text
local FADE_OUT = 0.4           -- s
local QUIET = 1.5              -- s after start / reset: the initial state is not news
local AC_WAIT = 0.5            -- s AC's settings message waits, so an own reading of the same change can win
local OWN_NEAR = 2             -- s around AC's message in which an own reading means it is the same change
local MAX_SEGS = 16            -- more steps than this: no step bar, only the number

-- The line shown now.
local line = { label = '', value = '', lit = 0, segs = 0, born = -100 }
local ownClock = -100

local function show(label, value, lit, segs, own)
  line.label, line.value = label, value or ''
  line.lit, line.segs = lit or 0, (segs and segs <= MAX_SEGS) and segs or 0
  line.born = os.preciseClock()
  if own then ownClock = line.born end
  M.count = M.count + 1
end

-- AC's system message about a car setting (already in Czech). Waits a moment and is dropped when the app read
-- the change itself shortly before or after; shown only for settings the app cannot read.
local pendingLabel, pendingValue, pendingAt = nil, nil, 0
function M.acMessage(label, value)
  pendingLabel, pendingValue, pendingAt = label, value, os.preciseClock()
end

local function flushPending(now)
  if not pendingLabel or now - pendingAt < AC_WAIT then return end
  if ownClock < pendingAt - OWN_NEAR then show(pendingLabel, pendingValue, 0, 0, false) end
  pendingLabel, pendingValue = nil, nil
end

-- The line shown now (for tests and Diagnostika).
function M.current() return line.label, line.value end

function M.demo()
  show('TC', '3 / 8', 3, 8, false)
end

-- ---------------------------------------------------------------- watched settings

local ON, OFF = 'zapnuto', 'vypnuto'

local function levelText(v, n)
  if v <= 0 then return OFF end
  return string.format('%d / %d', v, n)
end

-- kind 'level': value 0..n (0 = off), n from countField; 'step': value 0..n-1 shown as 1..n; 'bool'; custom text.
local WATCH = {
  { label = 'TC', kind = 'level', get = function (c) return c.tractionControlMode end,
    count = function (c) return c.tractionControlModes end },
  { label = 'TC2', kind = 'level', get = function (c) return c.tractionControl2 end,
    count = function (c) return c.tractionControl2Modes end },
  { label = 'ABS', kind = 'level', get = function (c) return c.absMode end, count = function (c) return c.absModes end },
  { label = 'BRZDY VPŘEDU', kind = 'bias', get = function (c) return math.floor(c.brakeBias * 1000 + 0.5) end },
  { label = 'MOTOR. BRZDA', kind = 'step', get = function (c) return c.currentEngineBrakeSetting end,
    count = function (c) return c.hasEngineBrakeSettings and c.engineBrakeSettingsCount or 0 end },
  { label = 'MAPA PALIVA', kind = 'level0', get = function (c) return c.fuelMap end, count = function (c) return c.fuelMaps end },
  { label = 'TURBO', kind = 'level0', get = function (c) return math.floor(c.turboWastegates[0] * 10 + 0.5) end,
    count = function (c) return c.adjustableTurbo and 10 or 0 end },
  { label = 'MGU-K', kind = 'mguk', get = function (c) return c.mgukDelivery end,
    count = function (c) return c.mgukDeliveryCount end },
  { label = 'MGU-K REKUP.', kind = 'level0', get = function (c) return c.mgukRecovery end,
    count = function (c) return c.mgukDeliveryCount > 0 and 10 or 0 end },
  { label = 'MGU-H NABÍJ.', kind = 'bool', get = function (c) return c.mguhChargingBatteries end,
    count = function (c) return c.hasCockpitMGUHMode and 1 or 0 end },
  { label = 'LIMITER BOX', kind = 'bool', get = function (c) return c.manualPitsSpeedLimiterEnabled end },
  { label = 'LIMITER', kind = 'bool', get = function (c) return c.userSpeedLimiterEnabled end,
    count = function (c) return c.hasCockpitSwitchForUserSpeedLimiter and 1 or 0 end },
  { label = 'AUTO ŘAZENÍ', kind = 'bool', get = function (c) return c.autoShift end },
  { label = 'AUTO SPOJKA', kind = 'bool', get = function (c) return c.autoClutch end },
}
for _, w in ipairs(WATCH) do w.ok, w.last = nil, nil end

local function probe(w, car)
  local ok = pcall(w.get, car)
  if ok and w.count then ok = pcall(w.count, car) end
  w.ok = ok
end

local function announce(w, v, car)
  local n = w.count and w.count(car) or 1
  if w.count and n <= 0 then return end          -- this car does not have the setting
  if w.kind == 'level' then
    show(w.label, n == 1 and (v > 0 and ON or OFF) or levelText(v, n), v, n > 1 and n or 0, true)
  elseif w.kind == 'level0' then
    show(w.label, string.format('%d / %d', v, n), v, n, true)
  elseif w.kind == 'step' then
    show(w.label, string.format('%d / %d', v + 1, n), v + 1, n, true)
  elseif w.kind == 'bias' then
    show(w.label, string.format('%.1f %%', v / 10):gsub('%.', ','), 0, 0, true)
  elseif w.kind == 'mguk' then
    local ok, name = pcall(ac.getMGUKDeliveryName, 0, v)
    show(w.label, ok and type(name) == 'string' and name ~= '' and name or string.format('%d / %d', v + 1, n),
      v + 1, n, true)
  else
    show(w.label, v and ON or OFF, 0, 0, true)
  end
end

local quietUntil, lastSession = 0, -1

function M.update()
  local car = ac.getCar(0)
  local sim = ac.getSim()
  if not car or not sim or sim.isReplayActive then return end
  local now = os.preciseClock()
  if sim.currentSessionIndex ~= lastSession then
    lastSession = sim.currentSessionIndex
    quietUntil = now + QUIET
  end
  local quiet = now < quietUntil or not S.setupLine
  if quiet then pendingLabel = nil end
  for i = 1, #WATCH do
    local w = WATCH[i]
    if w.ok == nil then probe(w, car) end
    if w.ok then
      local v = w.get(car)
      if v ~= w.last then
        local first = w.last == nil
        w.last = v
        if not first and not quiet then announce(w, v, car) end
      end
    end
  end
  flushPending(now)
end

-- Settings that work on this car / CSP (for Diagnostika).
function M.available()
  local n, total = 0, #WATCH
  for i = 1, total do if WATCH[i].ok then n = n + 1 end end
  return n, total
end

-- ---------------------------------------------------------------- drawing
-- Fixed panel: name on the left, value on the right, a thin step bar along the bottom for settings with levels.

local LABEL = rgbm(0.76, 0.79, 0.84, 1)
local SEG_ON = rgbm(0.96, 0.96, 0.97, 1)
local SEG_OFF = rgbm(0.96, 0.96, 0.97, 0.2)
local LABEL_SIZE, VALUE_SIZE = 15, 22
local PAD, BAR_Y, BAR_H, SEG_GAP = 14, 33, 4, 3
local x0, sc = 0, 1
local function X(v) return x0 + v * sc end

function M.draw()
  local w, wh = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or wh <= 0 then return end
  local now = os.preciseClock()
  local sample = false
  local t = now - line.born
  if t > S.setupTime or line.label == '' then
    if not ui.windowHovered() then return end
    sample = true
  end
  local alpha = sample and 0.6 or (t > S.setupTime - FADE_OUT and (S.setupTime - t) / FADE_OUT or 1)
  if line.label == '' then          -- nothing shown yet: a sample while hovering, so the window can be placed
    line.label, line.value, line.lit, line.segs = 'TC', '3 / 8', 3, 8
  end

  sc = math.min(w / BASE_W, wh / BASE_H)
  x0 = (w - BASE_W * sc) / 2
  D.panel(X(0), 0, X(BASE_W), BASE_H * sc, 8 * sc, alpha)
  local a = alpha * S.opacity
  local textH = (line.segs > 0 and BAR_Y or BASE_H) * sc
  ui.pushDWriteFont(D.FONT)
  D.text(line.label, LABEL_SIZE * sc, X(PAD), 0, (BASE_W - PAD * 2) * sc, textH, D.ALIGN_START, D.color(LABEL, a))
  D.text(line.value, VALUE_SIZE * sc, X(PAD), 0, (BASE_W - PAD * 2) * sc, textH, D.ALIGN_END, D.color(S.colText, a))
  ui.popDWriteFont()
  local n = line.segs
  if n > 0 then
    local segW = (BASE_W - PAD * 2 - (n - 1) * SEG_GAP) / n
    local y1, y2 = BAR_Y * sc, (BAR_Y + BAR_H) * sc
    for k = 1, n do
      local sx = PAD + (k - 1) * (segW + SEG_GAP)
      D.rect(X(sx), y1, X(sx + segW), y2, D.color(k <= line.lit and SEG_ON or SEG_OFF, a), 2 * sc)
    end
  end
end

return M
