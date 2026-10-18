-- Timing window: position, lap count, current lap time and best lap.
-- The best lap has a purple frame; after the line the current time briefly shows
-- the finished lap in a coloured pill (purple new best, green faster than the
-- previous lap, red slower, grey not a timed lap).

local config = require('src/config')
local tracker = require('src/tracker')
local D = require('src/draw')
local S = config.S

local ITEM_POS, ITEM_LAPS, ITEM_CUR, ITEM_BEST = 1, 2, 3, 4
local LABELS = { 'POZ', 'KOLO', 'ČAS', 'NEJ' }
local PAD, PILL = 6, 6
-- side by side
local ROW_W = { 64, 60, 104, 104 }
local ROW_GAP, LABEL_H, VALUE_H = 14, 15, 32
-- stacked
local STACK_W = 214
local STACK_H = { 36, 30, 30, 30 }
local STACK_GAP = 3

local LABEL_COLOR = rgbm(0.76, 0.79, 0.84, 1)
local BEST_TEXT = rgbm(0.89, 0.8, 1, 1)
local PILL_FILL = rgbm(0.06, 0.03, 0.1, 0.72)
local WHITE = rgbm(1, 1, 1, 1)

local numStrings, lapStrings = {}, {}
local curCache = { key = -1, str = '' }
local bestCache = { key = -1, str = '' }
local flashCache = { key = -1, str = '' }
local mPos, mTail, mBest, mFlash = {}, {}, {}, {}

local function visible(item)
  if item == ITEM_POS then return S.showPosition end
  if item == ITEM_LAPS then return S.showLaps end
  if item == ITEM_CUR then return S.showCurrent end
  return S.showBest
end

local function numText(n)
  local str = numStrings[n]
  if not str then
    str = n > 0 and tostring(n) or '-'
    numStrings[n] = str
  end
  return str
end

local function tailText(n)
  local key = -1 - n
  local str = numStrings[key]
  if not str then
    str = '/' .. tostring(n)
    numStrings[key] = str
  end
  return str
end

local function lapsText()
  local key = tracker.lap * 1000 + tracker.totalLaps
  local str = lapStrings[key]
  if not str then
    if tracker.totalLaps > 0 then
      str = string.format('%d/%d', math.min(tracker.lap, tracker.totalLaps), tracker.totalLaps)
    else
      str = tostring(tracker.lap)
    end
    lapStrings[key] = str
  end
  return str
end

local function lapText(cache, ms, decimals)
  local key = ms > 0 and math.floor(decimals == 3 and ms or ms / 100) or -2
  if cache.key ~= key then
    cache.key = key
    cache.str = D.formatLap(ms, decimals)
  end
  return cache.str
end

local function flashColor()
  local kind = tracker.flashKind
  if kind == 1 then return S.colPurple end
  if kind == 2 then return S.colGreen end
  if kind == 3 then return S.colRed end
  return S.colNeutral
end

local function baseSize()
  local n, w, h = 0, 0, 0
  for item = 1, 4 do
    if visible(item) then
      n = n + 1
      if S.timingLayout == 1 then
        h = h + STACK_H[item] + (n > 1 and STACK_GAP or 0)
      else
        w = w + ROW_W[item] + (n > 1 and ROW_GAP or 0)
      end
    end
  end
  if S.timingLayout == 1 then return STACK_W, h + PAD * 2, n end
  return w + PAD * 2, PAD * 2 + LABEL_H + VALUE_H, n
end

-- Pill behind text. Anchor ax is the text start (left align) or end (right align).
local function pill(ax, cy, tw, size, sc, rightAligned, outline, color)
  local x0 = rightAligned and ax - tw - PILL * sc or ax - PILL * sc
  local x1 = x0 + tw + PILL * 2 * sc
  local hh = size * 0.66
  local r = 5 * sc
  D.rect(x0, cy - hh, x1, cy + hh, D.color(color, S.opacity), r)
  if outline then
    local b = math.max(1, 2 * sc)
    D.rect(x0 + b, cy - hh + b, x1 - b, cy + hh - b, D.color(PILL_FILL, S.opacity), math.max(0, r - b))
  end
end

-- Draws a value; ax is the left edge (row layout) or the right edge (stack layout).
local function drawValue(item, ax, y, boxW, h, size, sc, rightAligned)
  local align = rightAligned and D.ALIGN_END or D.ALIGN_START
  local bx = rightAligned and ax - boxW or ax
  local cy = y + h / 2
  if item == ITEM_LAPS then
    D.text(lapsText(), size, bx, y, boxW, h, align, D.color(S.colText, S.opacity))
  elseif item == ITEM_CUR then
    if S.lapFlash and os.preciseClock() < tracker.flashUntil then
      local str = lapText(flashCache, tracker.flashLapMs, 3)
      pill(ax, cy, D.measure(mFlash, str, size), size, sc, rightAligned, false, flashColor())
      D.text(str, size, bx, y, boxW, h, align, D.color(WHITE, S.opacity))
    else
      D.text(lapText(curCache, tracker.currentMs, 1), size, bx, y, boxW, h, align, D.color(S.colText, S.opacity))
    end
  else
    local str = lapText(bestCache, tracker.bestMs, 3)
    if S.bestHighlight and tracker.bestMs > 0 then
      pill(ax, cy, D.measure(mBest, str, size), size, sc, rightAligned, true, S.colPurple)
      D.text(str, size, bx, y, boxW, h, align, D.color(BEST_TEXT, S.opacity))
    else
      D.text(str, size, bx, y, boxW, h, align, D.color(S.colText, S.opacity))
    end
  end
end

-- Position: big number plus a smaller "/total".
local function drawPosition(ax, y, boxW, h, big, small, sc, rightAligned)
  local num, tail = numText(tracker.position), tailText(tracker.carsCount)
  local tailY = y + (big - small) * 0.18
  if rightAligned then
    local tw = D.measure(mTail, tail, small)
    D.text(tail, small, ax - boxW, tailY, boxW, h, D.ALIGN_END, D.color(LABEL_COLOR, S.opacity))
    D.text(num, big, ax - boxW - tw - 2 * sc, y, boxW, h, D.ALIGN_END, D.color(S.colText, S.opacity))
  else
    local nw = D.measure(mPos, num, big)
    D.text(num, big, ax, y, boxW, h, D.ALIGN_START, D.color(S.colText, S.opacity))
    D.text(tail, small, ax + nw + 2 * sc, tailY, boxW, h, D.ALIGN_START, D.color(LABEL_COLOR, S.opacity))
  end
end

local M = {}

function M.draw()
  local w, h = ui.windowWidth(), ui.windowHeight()
  local baseW, baseH, n = baseSize()
  if n == 0 or w <= 0 or h <= 0 then return end
  local sc = math.min(w / baseW, h / baseH)
  ui.pushDWriteFont(D.FONT)
  if S.timingPanel then D.panel(0, 0, baseW * sc, baseH * sc, 8 * sc) end
  local pad, pillPad = PAD * sc, PILL * sc
  if S.timingLayout == 1 then
    local y, first = pad, true
    local right = baseW * sc - pad - pillPad
    for item = 1, 4 do
      if visible(item) then
        if not first then y = y + STACK_GAP * sc end
        first = false
        local rh = STACK_H[item] * sc
        local boxW = (STACK_W - PAD * 2 - PILL) * sc
        D.text(LABELS[item], 13 * sc, pad, y, boxW, rh, D.ALIGN_START, D.color(LABEL_COLOR, S.opacity))
        if item == ITEM_POS then
          drawPosition(right, y, boxW, rh, 32 * sc, 18 * sc, sc, true)
        else
          drawValue(item, right, y, boxW, rh, 23 * sc, sc, true)
        end
        y = y + rh
      end
    end
  else
    local x, first = pad, true
    local labelH, valueH = LABEL_H * sc, VALUE_H * sc
    for item = 1, 4 do
      if visible(item) then
        if not first then x = x + ROW_GAP * sc end
        first = false
        local ax = x + pillPad
        local boxW = (ROW_W[item] - PILL) * sc
        D.text(LABELS[item], 12 * sc, ax, pad, boxW, labelH, D.ALIGN_START, D.color(LABEL_COLOR, S.opacity))
        if item == ITEM_POS then
          drawPosition(ax, pad + labelH, boxW, valueH, 28 * sc, 16 * sc, sc, false)
        else
          drawValue(item, ax, pad + labelH, boxW, valueH, 24 * sc, sc, false)
        end
        x = x + ROW_W[item] * sc
      end
    end
  end
  ui.popDWriteFont()
end

return M
