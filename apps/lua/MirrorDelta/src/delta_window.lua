-- Delta window: mini sector line, delta line and the delta in seconds.
-- Lines span the full window width; thickness, gaps and text scale with the window.

local config = require('src/config')
local tracker = require('src/tracker')
local D = require('src/draw')
local S = config.S

local BASE_W = 600             -- sizes in settings are pixels at this window width
local ROW_NUMBER, ROW_LINE, ROW_SECTORS = 1, 2, 3

local rows = { 0, 0, 0 }
local ERROR_COLOR = rgbm(1, 0.35, 0.35, 1)
local LIMITER_BLUE = rgbm(0.25, 0.55, 1, 1)

-- True on the "on" half of the 8 Hz blink while the engine is at the rev limiter.
local function limiterBlink()
  if not S.deltaLimiterFlash then return false end
  local car = ac.getCar(0)
  if not car then return false end
  local limiter = car.rpmLimiter > 0 and car.rpmLimiter or 8000
  return car.rpm >= limiter * 0.98 and math.floor(os.preciseClock() * 8) % 2 == 0
end
local deltaStrings = {}        -- cache: hundredths -> "+0.23"

local function enabled(row)
  if row == ROW_NUMBER then return S.showDeltaNumber end
  if row == ROW_LINE then return S.showDeltaLine end
  return S.showSectors
end

local function rowHeight(row)
  return row == ROW_NUMBER and S.numberSize * 1.15 or S.lineThickness
end

local function rowSpacing(a, b)
  return (a == ROW_NUMBER or b == ROW_NUMBER) and 4 or S.lineGap
end

-- Layout 1: number, line, sectors. Layout 2: sectors, line, number.
local function layoutRows()
  local first, last = ROW_NUMBER, ROW_SECTORS
  if S.deltaLayout ~= 1 then first, last = ROW_SECTORS, ROW_NUMBER end
  local n = 0
  if enabled(first) then n = n + 1; rows[n] = first end
  if enabled(ROW_LINE) then n = n + 1; rows[n] = ROW_LINE end
  if enabled(last) then n = n + 1; rows[n] = last end
  local h = 0
  for i = 1, n do
    h = h + rowHeight(rows[i])
    if i > 1 then h = h + rowSpacing(rows[i - 1], rows[i]) end
  end
  return n, h
end

local function deltaText(d)
  local c = math.min(9999, math.floor(math.abs(d) * 100 + 0.5))
  local key = c == 0 and 0 or (d < 0 and -c or c)
  local str = deltaStrings[key]
  if not str then
    if c == 0 then
      str = '0.00'
    else
      str = string.format('%s%d.%02d', d < 0 and '-' or '+', math.floor(c / 100), c % 100)
    end
    deltaStrings[key] = str
  end
  return str
end

local function sectorColor(i)
  if i == tracker.curSector then return S.colCurrent end
  local state = tracker.secState[i]
  if state == 1 then return S.colPurple end
  if state == 2 then return S.colGreen end
  if state == 3 then return S.colYellow end
  if state == 4 then return S.colNeutral end
  return S.colIdle
end

local function drawSectors(x, y, w, h, sc, blink)
  local count = tracker.sectorCount
  local groups = math.max(1, math.min(math.floor(S.sectorGroups + 0.5), count))
  local gap = math.max(1, 1.2 * sc)
  local groupGap = groups > 1 and math.max(gap, S.groupGap * sc) or gap
  local segW = (w - (count - groups) * gap - (groups - 1) * groupGap) / count
  if segW <= 0 then return end
  local px, nextGroup = x, 1
  local boundary = math.floor(count / groups + 0.5)   -- first segment (0-based) of the next group
  for i = 1, count do
    if i > 1 then
      if groups > 1 and i - 1 == boundary then
        px = px + groupGap
        nextGroup = nextGroup + 1
        boundary = math.floor(count * nextGroup / groups + 0.5)
      else
        px = px + gap
      end
    end
    D.rect(px, y, px + segW, y + h, D.color(blink and LIMITER_BLUE or sectorColor(i), S.opacity))
    px = px + segW
  end
end

local function deltaColor()
  if not tracker.hasDelta then return S.colNeutral end
  return tracker.deltaSign < 0 and S.colGreen or S.colRed
end

local function drawLine(x, y, w, h, blink)
  local alpha = S.opacity
  if S.intensityByDelta and tracker.hasDelta then
    local k = math.min(1, math.abs(tracker.delta) / math.max(0.05, S.intensityFullAt))
    alpha = alpha * (0.22 + 0.78 * k)
  end
  local col = deltaColor()
  if blink then col, alpha = LIMITER_BLUE, S.opacity end
  D.rect(x, y, x + w, y + h, D.color(col, alpha))
end

local function drawNumber(x, y, w, h, size)
  local str = tracker.hasDelta and deltaText(tracker.delta) or '-.--'
  D.text(str, size, x, y, w, h, D.ALIGN_CENTER, D.color(deltaColor(), S.opacity))
end


local STATUS_COLOR = rgbm(0.93, 0.94, 0.96, 0.9)

local function drawInner()
  local w, h = ui.windowWidth(), ui.windowHeight()
  local n, contentH = layoutRows()
  if n == 0 or w <= 0 or h <= 0 then return end
  local sc = math.min(w / BASE_W, h / contentH)
  local blink = limiterBlink()
  local y = (h - contentH * sc) / 2
  for i = 1, n do
    local row = rows[i]
    if i > 1 then y = y + rowSpacing(rows[i - 1], row) * sc end
    local rh = rowHeight(row) * sc
    if row == ROW_SECTORS then
      drawSectors(0, y, w, rh, sc, blink)
    elseif row == ROW_LINE then
      drawLine(0, y, w, rh, blink)
    else
      drawNumber(0, y, w, rh, S.numberSize * sc)
    end
    y = y + rh
  end
  if tracker.diag.error then
    D.text('MirrorDelta: chyba skriptu, viz Nastavení > Diagnostika', 12, 0, 0, w, 16, D.ALIGN_START, ERROR_COLOR)
  elseif S.deltaShowStatus and tracker.status then
    D.text(tracker.status, 12, 0, 0, w, 16, D.ALIGN_START, STATUS_COLOR)
  end
end

local M = {}

function M.draw()
  ui.pushDWriteFont(D.FONT)
  local ok, err = pcall(drawInner)
  ui.popDWriteFont()
  if not ok then
    if not tracker.diag.error then tracker.diag.error = 'okno delty: ' .. tostring(err) end
    -- a plain red bar, so a broken window is visible even when text drawing is what failed
    D.rect(0, 0, ui.windowWidth(), 4, ERROR_COLOR)
  end
end

return M
