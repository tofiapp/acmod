-- Gear window: 12-segment RPM bar on top, speed on the left and a big gear number.
-- The RPM range comes from the car (rpmLimiter).

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local BASE_W, PAD = 260, 6
local BAR_H, BAR_GAP, ROW_H = 14, 6, 70
local SEGMENTS = 12

local IDLE = rgbm(0.19, 0.21, 0.24, 1)
local BLUE = rgbm(0.25, 0.55, 1, 1)
local LABEL = rgbm(0.76, 0.79, 0.84, 1)
local PLATE = rgbm(0.03, 0.04, 0.055, 0.6)

local gearStrings = { [-1] = 'R', [0] = 'N' }
local speedStrings = {}

local function gearText(g)
  local str = gearStrings[g]
  if not str then
    str = tostring(g)
    gearStrings[g] = str
  end
  return str
end

local function speedText(v)
  local n = math.floor(v + 0.5)
  local str = speedStrings[n]
  if not str then
    str = tostring(n)
    speedStrings[n] = str
  end
  return str
end

local function segmentColor(i)
  if i <= 6 then return S.colGreen end
  if i <= 10 then return S.colYellow end
  return S.colRed
end

local function baseHeight()
  return PAD * 2 + (S.gearShowBar and BAR_H + BAR_GAP or 0) + ROW_H
end

local M = {}

function M.draw()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  local baseH = baseHeight()
  if w <= 0 or h <= 0 then return end
  local sc = math.min(w / BASE_W, h / baseH)
  local cw = BASE_W * sc
  ui.pushDWriteFont(D.FONT)
  if S.gearPlate then D.rect(0, 0, cw, baseH * sc, D.color(PLATE, S.opacity), 8 * sc) end
  local y = PAD * sc

  if S.gearShowBar then
    local limiter = car.rpmLimiter > 0 and car.rpmLimiter or 8000
    local startRpm = limiter * S.gearRpmStart
    local k = (car.rpm - startRpm) / math.max(1, limiter * 0.98 - startRpm)
    local lit = math.max(0, math.min(SEGMENTS, math.floor(k * SEGMENTS + 0.5)))
    local atLimit = car.rpm >= limiter * 0.98
    local blinkOn = atLimit and S.gearShiftFlash and math.floor(os.preciseClock() * 8) % 2 == 0
    local gap = 3 * sc
    local x0 = PAD * sc
    local segW = (cw - x0 * 2 - gap * (SEGMENTS - 1)) / SEGMENTS
    for i = 1, SEGMENTS do
      local col
      if atLimit and S.gearShiftFlash then
        col = blinkOn and BLUE or IDLE
      elseif i <= lit then
        col = segmentColor(i)
      else
        col = IDLE
      end
      local x = x0 + (i - 1) * (segW + gap)
      D.rect(x, y, x + segW, y + BAR_H * sc, D.color(col, S.opacity), 2 * sc)
    end
    y = y + (BAR_H + BAR_GAP) * sc
  end

  local rowH = ROW_H * sc
  local half = cw / 2
  if S.gearShowSpeed then
    D.text(speedText(car.speedKmh), 34 * sc, PAD * sc, y, half - PAD * sc - 6 * sc, rowH * 0.72, D.ALIGN_END,
      D.color(S.colText, S.opacity))
    D.text('km/h', 13 * sc, PAD * sc, y + rowH * 0.62, half - PAD * sc - 6 * sc, rowH * 0.3, D.ALIGN_END,
      D.color(LABEL, S.opacity))
  end
  if S.gearShowSpeed then
    D.text(gearText(car.gear), 64 * sc, half, y, half - PAD * sc, rowH, D.ALIGN_START, D.color(S.colText, S.opacity))
  else
    D.text(gearText(car.gear), 64 * sc, 0, y, cw, rowH, D.ALIGN_CENTER, D.color(S.colText, S.opacity))
  end
  ui.popDWriteFont()
end

return M
