-- Damage window: the car seen from above with four rounded bars for the body sides
-- (front, rear, left, right from car.damage[0..3]) and an engine tile in the middle
-- (car.engineLifeLeft, 1000 = healthy). Undamaged sides stay dark; damage goes from
-- yellow to red. Same rounded style and font as the gear window.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local BASE_W, BASE_H = 150, 168
-- body and bars in px at scale 1
local BODY_X, BODY_Y, BODY_W, BODY_H = 44, 22, 62, 124
local BAR = 10
local ENGINE_X, ENGINE_Y, ENGINE_W, ENGINE_H = 51, 58, 48, 52

local IDLE = rgbm(0.16, 0.18, 0.21, 0.92)
local BODY = rgbm(0.03, 0.04, 0.055, 0.62)
local TILE_WHITE = rgbm(0.957, 0.961, 0.969, 1)
local TEXT_DARK = rgbm(0.067, 0.078, 0.094, 1)
local WHITE = rgbm(1, 1, 1, 1)
local PLATE = rgbm(0.03, 0.04, 0.055, 0.6)
local damageColor = rgbm()

local pctStrings = {}
local ox, oy, sc = 0, 0, 1

local function X(v) return ox + v * sc end
local function Y(v) return oy + v * sc end

local function pctText(p)
  local str = pctStrings[p]
  if not str then
    str = tostring(p)
    pctStrings[p] = str
  end
  return str
end

-- 0 = undamaged, 1 = at the configured full damage
local function level(car, side)
  return math.max(0, math.min(1, car.damage[side] / math.max(0.001, S.damageFull)))
end

-- Shared colour for a damage level; use it right away.
local function sideColor(l)
  if l <= 0.01 then return D.color(IDLE, S.opacity) end
  damageColor:setLerp(S.colYellow, S.colRed, l)
  damageColor.mult = S.opacity
  return damageColor
end

-- AC's own damage displayer is toggled by a sim key command (same as the official Unbound app).
-- Retry at most once a second, so a toggle that has not applied yet is not undone by the next frame.
local nextHideAttempt = 0
local function hideOriginal()
  if not S.damageHideOriginal then return end
  local sim = ac.getSim()
  if not sim or not sim.damageDisplayerShown then return end
  local now = os.preciseClock()
  if now < nextHideAttempt then return end
  nextHideAttempt = now + 1
  ac.trySimKeyPressCommand('Hide Damage')
end

local M = {}

function M.draw()
  hideOriginal()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end

  local front, rear, left, right = level(car, 0), level(car, 1), level(car, 2), level(car, 3)
  local pct = math.max(0, math.min(100, math.floor(car.engineLifeLeft / 10 + 0.5)))
  if S.damageAutoHide and front <= 0.01 and rear <= 0.01 and left <= 0.01 and right <= 0.01 and pct >= 99 then
    return
  end

  sc = math.min(w / BASE_W, h / BASE_H)
  ox, oy = (w - BASE_W * sc) / 2, 0

  ui.pushDWriteFont(D.FONT_GEAR)
  if S.damagePlate then D.rect(X(0), Y(0), X(BASE_W), Y(BASE_H), D.color(PLATE, S.opacity), 10 * sc) end

  D.rect(X(BODY_X), Y(BODY_Y), X(BODY_X + BODY_W), Y(BODY_Y + BODY_H), D.color(BODY, S.opacity), 18 * sc)
  local r = BAR / 2 * sc
  D.rect(X(BODY_X), Y(BODY_Y - BAR - 6), X(BODY_X + BODY_W), Y(BODY_Y - 6), sideColor(front), r)
  D.rect(X(BODY_X), Y(BODY_Y + BODY_H + 6), X(BODY_X + BODY_W), Y(BODY_Y + BODY_H + 6 + BAR), sideColor(rear), r)
  D.rect(X(BODY_X - BAR - 4), Y(BODY_Y + 8), X(BODY_X - 4), Y(BODY_Y + BODY_H - 8), sideColor(left), r)
  D.rect(X(BODY_X + BODY_W + 4), Y(BODY_Y + 8), X(BODY_X + BODY_W + 4 + BAR), Y(BODY_Y + BODY_H - 8), sideColor(right), r)

  -- engine tile: white when healthy, yellow below 95 %, red below 50 %
  local tile, text = TILE_WHITE, TEXT_DARK
  if pct < 50 then
    tile, text = S.colRed, WHITE
  elseif pct < 95 then
    tile = S.colYellow
  end
  local ex, ey = X(ENGINE_X), Y(ENGINE_Y)
  local ew, eh = ENGINE_W * sc, ENGINE_H * sc
  D.rect(ex, ey, ex + ew, ey + eh, D.color(tile, S.opacity), 12 * sc)
  D.text(pctText(pct), 15 * sc, ex, ey + 4 * sc, ew, eh * 0.55, D.ALIGN_CENTER, D.color(text, S.opacity))
  D.text('MOTOR', 7 * sc, ex, ey + eh * 0.6, ew, eh * 0.3, D.ALIGN_CENTER, D.color(text, S.opacity))
  ui.popDWriteFont()
end

return M
