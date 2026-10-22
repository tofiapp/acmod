-- Damage window ("cross"): front and rear as horizontal bars, the sides as vertical bars (car.damage[0..3]),
-- a tyre in each corner (tyre wear / blown tyre) with a small square for its suspension next to it
-- (suspension damage, read under pcall), engine life in the middle (car.engineLifeLeft, 1000 = healthy).
-- Undamaged parts are light grey, damage goes from yellow to red, a part that was just hit flashes white.
-- Everything is drawn in a 160 x 160 box scaled into the window, with rectangles only.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local BOX_W, BOX_H = 160, 160
local FRONT, REAR, LEFT, RIGHT = 1, 2, 3, 4
-- zone keys: 1..4 body, 5..8 tyres (FL, FR, RL, RR), 9..12 suspension (FL, FR, RL, RR)
local KEYS = 12

-- ---------------------------------------------------------------- transform and primitives

local ox, oy, sc = 0, 0, 1
local function X(v) return ox + v * sc end
local function Y(v) return oy + v * sc end

local function rectB(x, y, w, h, color, r)
  D.rect(X(x), Y(y), X(x + w), Y(y + h), color, (r or 0) * sc)
end

local function textB(str, cx, cy, size, color, w, font)
  ui.pushDWriteFont(font)
  D.text(str, size * sc, X(cx) - w / 2 * sc, Y(cy) - size * 0.75 * sc, w * sc, size * 1.5 * sc, D.ALIGN_CENTER, color)
  ui.popDWriteFont()
end

-- ---------------------------------------------------------------- geometry (box units)

-- body bars: x, y, w, h for front, rear, left, right
local BARS = { 44, 8, 72, 8, 44, 144, 72, 8, 8, 44, 8, 72, 144, 44, 8, 72 }
-- per corner (FL, FR, RL, RR): tyre top left (16 x 26) and suspension square top left (10 x 10)
local TYRES = { 22, 20, 122, 20, 22, 114, 122, 114 }
local SUSP = { 42, 30, 108, 30, 42, 120, 108, 120 }

-- ---------------------------------------------------------------- colours and state

local IDLE = rgbm(0.91, 0.93, 0.95, 0.55)
local WHITE = rgbm(1, 1, 1, 1)
local TILE_WHITE = rgbm(0.93, 0.94, 0.96, 1)
local LABEL = rgbm(0.91, 0.93, 0.95, 0.75)

local level, prevLevel, hitAt = {}, {}, {}
for k = 1, KEYS do level[k], prevLevel[k], hitAt[k] = 0, 0, -100 end
local zc = {}
for k = 1, KEYS do zc[k] = rgbm() end
local enginePct, now, started, lastHit = 100, 0, false, -1000

local function opa(c) return D.color(c, S.opacity) end

local function flashing(k)
  local dt = now - hitAt[k]
  return dt < 0.7 and math.floor(dt / 0.09) % 2 == 0
end
local function hot(k) return level[k] > 0.01 or flashing(k) end

-- Colour of a damaged zone (its own colour object, use right away).
local function zcol(k)
  local c = zc[k]
  if flashing(k) then c:set(WHITE) else c:setLerp(S.colYellow, S.colRed, math.min(1, level[k])) end
  c.mult = c.mult * S.opacity
  return c
end

local pctStrings = {}
local function pctText()
  local str = pctStrings[enginePct]
  if not str then str = tostring(enginePct); pctStrings[enginePct] = str end
  return str
end

-- ---------------------------------------------------------------- drawing

local function drawCar()
  for k = FRONT, RIGHT do
    local j = (k - 1) * 4
    rectB(BARS[j + 1], BARS[j + 2], BARS[j + 3], BARS[j + 4], hot(k) and zcol(k) or opa(IDLE), 3)
  end
  for i = 1, 4 do
    local tk, sk = 4 + i, 8 + i
    rectB(TYRES[i * 2 - 1], TYRES[i * 2], 16, 26, hot(tk) and zcol(tk) or opa(IDLE), 5)
    rectB(SUSP[i * 2 - 1], SUSP[i * 2], 10, 10, hot(sk) and zcol(sk) or opa(IDLE), 2)
  end
  local tile = enginePct < 50 and S.colRed or enginePct < 95 and S.colYellow or TILE_WHITE
  textB(pctText(), 80, 76, 22, opa(tile), 64, D.FONT_GEAR)
  textB('MOTOR', 80, 95, 9, opa(LABEL), 50, D.FONT)
end

-- ---------------------------------------------------------------- inputs

local function bodyLevel(car, side)
  return math.max(0, math.min(1, car.damage[side] / math.max(0.001, S.damageFull)))
end

-- Tyre fields come from the official RGBControl app; still read under pcall once.
local tyreFieldsOk = nil
local function tyreLevel(car, i)
  if tyreFieldsOk == nil then
    tyreFieldsOk = pcall(function () return car.wheels[0].tyreWear + 0, car.wheels[0].isBlown end)
  end
  if not tyreFieldsOk then return 0 end
  local w = car.wheels[i]
  if w.isBlown then return 1 end
  return math.max(0, math.min(1, (w.tyreWear - 0.25) / 0.6))
end

-- Suspension damage is not used by any official app, so it is read under pcall; without it the springs stay grey.
local suspFieldOk = nil
local function suspensionLevel(car, i)
  if suspFieldOk == nil then
    suspFieldOk = pcall(function () return car.wheels[0].suspensionDamage + 0 end)
  end
  if not suspFieldOk then return 0 end
  return math.max(0, math.min(1, car.wheels[i].suspensionDamage))
end

-- AC's own damage displayer is toggled by a sim key command (same as the official Unbound app).
local nextHideAttempt = 0
local function hideOriginal()
  if not S.damageHideOriginal then return end
  local sim = ac.getSim()
  if not sim or not sim.damageDisplayerShown then return end
  local t = os.preciseClock()
  if t < nextHideAttempt then return end
  nextHideAttempt = t + 1
  ac.trySimKeyPressCommand('Hide Damage')
end

-- Reads the car every frame (also while the window is hidden by the "after a hit" mode).
local function readCar(car)
  for side = 0, 3 do level[side + 1] = bodyLevel(car, side) end
  for i = 0, 3 do level[5 + i], level[9 + i] = tyreLevel(car, i), suspensionLevel(car, i) end
  local engineNow = math.max(0, math.min(100, math.floor(car.engineLifeLeft / 10 + 0.5)))
  if started and engineNow < enginePct then lastHit = now end
  enginePct = engineNow
  for k = 1, KEYS do
    if not started then prevLevel[k] = level[k] end   -- damage already there when the window opens is no hit
    if level[k] > prevLevel[k] + 0.02 then hitAt[k], lastHit = now, now end
    if level[k] > prevLevel[k] + 0.02 or level[k] < prevLevel[k] then prevLevel[k] = level[k] end
  end
  started = true
end

local M = {}

function M.tyreFieldsOk() return tyreFieldsOk end
function M.suspensionFieldOk() return suspFieldOk end

function M.draw()
  hideOriginal()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  now = os.preciseClock()
  readCar(car)

  -- 1: always, 2: while something is damaged, 3: for a few seconds after a hit (like AC). Hovering always shows it.
  if not ui.windowHovered() then
    if S.damageShow == 2 then
      local anyDamage = enginePct < 99
      for k = 1, KEYS do if level[k] > 0.01 then anyDamage = true end end
      if not anyDamage then return end
    elseif S.damageShow == 3 and now - lastHit > S.damageShowTime then
      return
    end
  end

  sc = math.min(w / BOX_W, h / BOX_H)
  ox, oy = (w - BOX_W * sc) / 2, (h - BOX_H * sc) / 2
  if S.damagePanel then D.panel(ox, oy, ox + BOX_W * sc, oy + BOX_H * sc, 10 * sc) end
  drawCar()
end

return M
