-- Car settings line: one line at the top of the screen when a driver aid or car setting changes
-- (TC, TC2, ABS, brake bias, engine brake, fuel map, turbo, MGU-K/H, limiters, auto shift, auto clutch),
-- and AC's own system messages (translated in originals.lua). A new change replaces the line.
-- Car fields are the ones the official Unbound app reads; each is probed once under pcall,
-- so a field missing in an older CSP only disables that one setting.
-- Strings are built only when something changes, never per frame.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local M = { count = 0 }

local BASE_W, BASE_H = 520, 44
local FADE_OUT = 0.4           -- s
local QUIET = 1.5              -- s after start / reset: the initial state is not news
local OWN_WINS = 0.5           -- s an own reading wins over AC's message about the same change
local MAX_SEGS = 12            -- more steps than this: no step bar, only the number

-- The line shown now.
local line = { label = '', value = '', lit = 0, segs = 0, born = -100, labelW = 0, valueW = 0, measured = false }
local ownClock = -100

local function show(label, value, lit, segs, own)
  line.label, line.value = label, value or ''
  line.lit, line.segs = lit or 0, (segs and segs <= MAX_SEGS) and segs or 0
  line.born = os.preciseClock()
  line.measured = false
  if own then ownClock = line.born end
  M.count = M.count + 1
end

-- An AC system message (already in Czech); skipped when an own reading just showed the same change.
function M.message(label, value)
  if not S.setupLine then return false end
  if os.preciseClock() - ownClock < OWN_WINS then return true end
  show(label, value, 0, 0, false)
  return true
end

-- The line shown now (for tests and Diagnostika).
function M.current() return line.label, line.value end

function M.demo()
  show('TRAKČNÍ KONTROLA', '3 / 8', 3, 8, false)
end

-- ---------------------------------------------------------------- watched settings

local ON, OFF = 'zapnuto', 'vypnuto'

local function levelText(v, n)
  if v <= 0 then return OFF end
  return string.format('%d / %d', v, n)
end

-- kind 'level': value 0..n (0 = off), n from countField; 'step': value 0..n-1 shown as 1..n; 'bool'; custom text.
local WATCH = {
  { label = 'TRAKČNÍ KONTROLA', kind = 'level', get = function (c) return c.tractionControlMode end,
    count = function (c) return c.tractionControlModes end },
  { label = 'TRAKČNÍ KONTROLA 2', kind = 'level', get = function (c) return c.tractionControl2 end,
    count = function (c) return c.tractionControl2Modes end },
  { label = 'ABS', kind = 'level', get = function (c) return c.absMode end, count = function (c) return c.absModes end },
  { label = 'ROZLOŽENÍ BRZD', kind = 'bias', get = function (c) return math.floor(c.brakeBias * 1000 + 0.5) end },
  { label = 'BRZDĚNÍ MOTOREM', kind = 'step', get = function (c) return c.currentEngineBrakeSetting end,
    count = function (c) return c.hasEngineBrakeSettings and c.engineBrakeSettingsCount or 0 end },
  { label = 'MAPA PALIVA', kind = 'level0', get = function (c) return c.fuelMap end, count = function (c) return c.fuelMaps end },
  { label = 'TURBO', kind = 'level0', get = function (c) return math.floor(c.turboWastegates[0] * 10 + 0.5) end,
    count = function (c) return c.adjustableTurbo and 10 or 0 end },
  { label = 'MGU-K VÝDEJ', kind = 'mguk', get = function (c) return c.mgukDelivery end,
    count = function (c) return c.mgukDeliveryCount end },
  { label = 'MGU-K REKUPERACE', kind = 'level0', get = function (c) return c.mgukRecovery end,
    count = function (c) return c.mgukDeliveryCount > 0 and 10 or 0 end },
  { label = 'MGU-H NABÍJENÍ', kind = 'bool', get = function (c) return c.mguhChargingBatteries end,
    count = function (c) return c.hasCockpitMGUHMode and 1 or 0 end },
  { label = 'OMEZOVAČ V BOXECH', kind = 'bool', get = function (c) return c.manualPitsSpeedLimiterEnabled end },
  { label = 'OMEZOVAČ RYCHLOSTI', kind = 'bool', get = function (c) return c.userSpeedLimiterEnabled end,
    count = function (c) return c.hasCockpitSwitchForUserSpeedLimiter and 1 or 0 end },
  { label = 'AUTOMATICKÉ ŘAZENÍ', kind = 'bool', get = function (c) return c.autoShift end },
  { label = 'AUTOMATICKÁ SPOJKA', kind = 'bool', get = function (c) return c.autoClutch end },
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
    show(w.label, string.format('%.1f %% vpředu', v / 10):gsub('%.', ','), 0, 0, true)
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
end

-- Settings that work on this car / CSP (for Diagnostika).
function M.available()
  local n, total = 0, #WATCH
  for i = 1, total do if WATCH[i].ok then n = n + 1 end end
  return n, total
end

-- ---------------------------------------------------------------- drawing

local LABEL = rgbm(0.76, 0.79, 0.84, 1)
local SEG_ON = rgbm(0.96, 0.96, 0.97, 1)
local SEG_OFF = rgbm(0.96, 0.96, 0.97, 0.22)
local LABEL_SIZE, VALUE_SIZE = 14, 22
local SEG_W, SEG_GAP = 7, 3

function M.draw()
  local w = ui.windowWidth()
  if w <= 0 then return end
  local now = os.preciseClock()
  local sample = false
  local t = now - line.born
  if t > S.setupTime or line.label == '' then
    if not ui.windowHovered() then return end
    sample = true
  end
  local alpha = sample and 0.6 or (t > S.setupTime - FADE_OUT and (S.setupTime - t) / FADE_OUT or 1)
  if line.label == '' then          -- nothing shown yet: a sample while hovering, so the window can be placed
    line.label, line.value, line.lit, line.segs = 'TRAKČNÍ KONTROLA', '3 / 8', 3, 8
  end
  local label, value, lit, segs = line.label, line.value, line.lit, line.segs

  ui.pushDWriteFont(D.FONT)
  if not line.measured then        -- once per shown line
    line.labelW = ui.measureDWriteText(label, LABEL_SIZE).x
    line.valueW = ui.measureDWriteText(value, VALUE_SIZE).x
    line.measured = true
  end
  local sc = w / BASE_W
  local segsW = segs > 0 and (segs * SEG_W + (segs - 1) * SEG_GAP + 14) or 0
  local total = (line.labelW + 12 + line.valueW + segsW) * sc
  local x = (w - total) / 2
  local h = BASE_H * sc
  D.panel(x - 14 * sc, 2 * sc, x + total + 14 * sc, h - 2 * sc, 8 * sc, alpha)
  local a = alpha * S.opacity
  D.text(label, LABEL_SIZE * sc, x, 0, line.labelW * sc + 4, h, D.ALIGN_START, D.color(LABEL, a))
  x = x + (line.labelW + 12) * sc
  D.text(value, VALUE_SIZE * sc, x, 0, line.valueW * sc + 4, h, D.ALIGN_START, D.color(S.colText, a))
  if segs > 0 then
    x = x + (line.valueW + 14) * sc
    local y1, y2 = h / 2 - 7 * sc, h / 2 + 7 * sc
    for k = 1, segs do
      D.rect(x, y1, x + SEG_W * sc, y2, D.color(k <= lit and SEG_ON or SEG_OFF, a), 2 * sc)
      x = x + (SEG_W + SEG_GAP) * sc
    end
  end
  ui.popDWriteFont()
end

return M
