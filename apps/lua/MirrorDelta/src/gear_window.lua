-- Gear window: 12-segment RPM bar across the top (lights from both edges towards the
-- centre), the gear on a rounded tile coloured by the revs, and the speed on a dark bar
-- under it. The RPM range comes from the car (rpmLimiter).

local config = require('src/config')
local D = require('src/draw')
local S = config.S


local BASE_W, PAD = 260, 6
local BAR_H, BAR_GAP = 13, 7
local TILE_W, TILE_H, TILE_R = 68, 66, 14
local SPEED_GAP, SPEED_H, SPEED_R = 6, 28, 10
local SEGMENTS = 12

local IDLE = rgbm(0.16, 0.18, 0.21, 0.92)
local BLUE = rgbm(0.25, 0.55, 1, 1)
local TILE_WHITE = rgbm(0.957, 0.961, 0.969, 1)
local TEXT_DARK = rgbm(0.067, 0.078, 0.094, 1)
local WHITE = rgbm(1, 1, 1, 1)
local SPEED_BACK = rgbm(0.03, 0.04, 0.055, 0.74)
local PLATE = rgbm(0.03, 0.04, 0.055, 0.6)

local gearStrings = { [-1] = 'R', [0] = 'N' }
local speedStrings = {}
local shownSpeed = -1000

local function gearText(g)
  local str = gearStrings[g]
  if not str then
    str = tostring(g)
    gearStrings[g] = str
  end
  return str
end

local function speedText(v)
  local str = speedStrings[v]
  if not str then
    str = tostring(v)
    speedStrings[v] = str
  end
  return str
end

-- Calm speed: only change once the real speed is a whole step away, then round to the step.
local function calmSpeed(speed)
  local step = math.max(1, S.gearSpeedStep)
  if math.abs(speed - shownSpeed) >= step then
    shownSpeed = math.floor(speed / step + 0.5) * step
  end
  return math.max(0, shownSpeed)
end

-- Segment i (1..12) counted from the nearest edge: 0 at the edges, 5 in the middle.
local function edgeDistance(i)
  return i <= 6 and i - 1 or SEGMENTS - i
end

local function segmentColor(d)
  if d < 3 then return S.colGreen end
  if d < 5 then return S.colYellow end
  return S.colRed
end

local function baseHeight()
  local h = PAD + TILE_H + PAD
  if S.gearShowBar then h = h + BAR_H + BAR_GAP end
  if S.gearShowSpeed then h = h + SPEED_GAP + SPEED_H end
  return h
end

local M = {}

function M.draw()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  local baseH = baseHeight()
  local sc = math.min(w / BASE_W, h / baseH)
  local ox = (w - BASE_W * sc) / 2           -- keep the drawing centred in the window
  local alpha = S.opacity

  local limiter = car.rpmLimiter > 0 and car.rpmLimiter or 8000
  local startRpm = limiter * S.gearRpmStart
  local k = math.max(0, math.min(1, (car.rpm - startRpm) / math.max(1, limiter * 0.98 - startRpm)))
  local atLimit = car.rpm >= limiter * 0.98
  local blinkOn = atLimit and S.gearShiftFlash and math.floor(os.preciseClock() * 8) % 2 == 0

  ui.pushDWriteFont(D.FONT_GEAR)
  if S.gearPlate then D.rect(ox, 0, ox + BASE_W * sc, baseH * sc, D.color(PLATE, alpha), 10 * sc) end
  local y = PAD * sc

  if S.gearShowBar then
    local lit = math.floor(k * 6 + 0.5)
    local gap = 4 * sc
    local x0 = ox + PAD * sc
    local segW = (BASE_W * sc - PAD * 2 * sc - gap * (SEGMENTS - 1)) / SEGMENTS
    for i = 1, SEGMENTS do
      local col
      if atLimit and S.gearShiftFlash then
        col = blinkOn and BLUE or IDLE
      else
        local d = edgeDistance(i)
        col = d < lit and segmentColor(d) or IDLE
      end
      local x = x0 + (i - 1) * (segW + gap)
      D.rect(x, y, x + segW, y + BAR_H * sc, D.color(col, alpha), 3 * sc)
    end
    y = y + (BAR_H + BAR_GAP) * sc
  end

  -- gear tile: white, then yellow and red with the revs, blinking blue at the limiter
  local tile = TILE_WHITE
  if atLimit and S.gearShiftFlash then
    tile = blinkOn and BLUE or TILE_WHITE
  elseif k > 0.85 then
    tile = S.colRed
  elseif k > 0.6 then
    tile = S.colYellow
  end
  local text = (tile == TILE_WHITE or tile == S.colYellow) and TEXT_DARK or WHITE
  local tx = ox + (BASE_W - TILE_W) / 2 * sc
  local tw, th = TILE_W * sc, TILE_H * sc
  D.rect(tx, y, tx + tw, y + th, D.color(tile, alpha), TILE_R * sc)
  D.text(gearText(car.gear), 46 * sc, tx, y, tw, th, D.ALIGN_CENTER, D.color(text, alpha))
  y = y + th

  if S.gearShowSpeed then
    y = y + SPEED_GAP * sc
    local sh = SPEED_H * sc
    D.rect(tx, y, tx + tw, y + sh, D.color(SPEED_BACK, alpha), SPEED_R * sc)
    D.text(speedText(calmSpeed(car.speedKmh)), 18 * sc, tx, y, tw, sh, D.ALIGN_CENTER, D.color(S.colText, alpha))
  end
  ui.popDWriteFont()
end

return M
