-- Flag window (top right corner by default): the flag AC shows right now, as a flag tile with its name.
-- Stays while the flag is active; the first seconds it pulses. Empty when there is no flag,
-- hovering shows a sample so the window can be placed.

local config = require('src/config')
local notify = require('src/notify')
local D = require('src/draw')
local S = config.S

local BASE_W, BASE_H = 260, 80
local YELLOW = rgbm(0.98, 0.8, 0.1, 1)
local BLUE = rgbm(0.15, 0.45, 1, 1)
local BLACK = rgbm(0.05, 0.05, 0.06, 1)
local WHITE = rgbm(0.96, 0.96, 0.97, 1)
local RED = rgbm(0.95, 0.2, 0.2, 1)
local POLE = rgbm(0.75, 0.77, 0.8, 1)
local TEXT = rgbm(0.96, 0.96, 0.97, 1)
local SUB = rgbm(0.85, 0.87, 0.9, 0.85)
local tmp = rgbm()

local shownKind, since = 0, 0
local ox, sc = 0, 1
local center = vec2()
local function X(v) return ox + v * sc end
local textWidth = {}            -- [size][string] -> width at base size, measured once per string
local function widthOf(str, size)
  local bySize = textWidth[size]
  if not bySize then bySize = {}; textWidth[size] = bySize end
  local wd = bySize[str]
  if not wd then wd = ui.measureDWriteText(str, size).x; bySize[str] = wd end
  return wd
end

local function flagColor(kind)
  if kind == notify.YELLOW then return YELLOW end
  if kind == notify.BLUE then return BLUE end
  if kind == notify.BLACK then return BLACK end
  return WHITE
end

local M = {}

function M.draw()
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  local now = os.preciseClock()
  local kind, title, sub = notify.flagKind, notify.flagTitle, notify.flagSub
  if kind ~= shownKind then shownKind, since = kind, now end
  local sample = false
  if kind == 0 then
    if not ui.windowHovered() then return end
    kind, title, sub, sample = notify.YELLOW, 'ŽLUTÁ VLAJKA', 'ukázka, okno přesuňte za titulek', true
  end

  sc = math.min(w / BASE_W, h / BASE_H)
  ox = w - BASE_W * sc                       -- right aligned: grows to the left
  local alpha = S.opacity * (sample and 0.6 or 1)
  -- pulse for the first two seconds
  local t = now - since
  if not sample and t < 2 and math.floor(t * 4) % 2 == 1 then alpha = alpha * 0.45 end

  -- flag on a pole at the right edge, matte panel behind the flag and the text
  local fx, fy, fw, fh = 176, 10, 70, 50
  ui.pushDWriteFont(D.FONT)
  local tw = math.max(widthOf(title, 20), widthOf(sub, 13))
  ui.popDWriteFont()
  D.panel(X(fx - 10) - tw * sc - 12 * sc, 2 * sc, X(fx + fw + 12), 78 * sc, 8 * sc, alpha / S.opacity)
  D.rect(X(fx + fw), fy * sc, X(fx + fw + 4), (fy + 64) * sc, D.color(POLE, alpha), 2 * sc)
  if kind == notify.FINISH then
    local cw, ch = fw / 6, fh / 4
    for r = 0, 3 do
      for c = 0, 5 do
        local col = (r + c) % 2 == 0 and WHITE or BLACK
        D.rect(X(fx + c * cw), (fy + r * ch) * sc, X(fx + (c + 1) * cw), (fy + (r + 1) * ch) * sc, D.color(col, alpha), 0)
      end
    end
  elseif kind == notify.PENALTY then
    -- black flag with an orange disc ("meatball") = come to the pits
    D.rect(X(fx), fy * sc, X(fx + fw), (fy + fh) * sc, D.color(BLACK, alpha), 3 * sc)
    tmp:set(RED)
    tmp.mult = alpha
    ui.drawCircleFilled(center:set(X(fx + fw / 2), (fy + fh / 2) * sc), 14 * sc, tmp, 24)
  else
    D.rect(X(fx), fy * sc, X(fx + fw), (fy + fh) * sc, D.color(flagColor(kind), alpha), 3 * sc)
    if kind == notify.BLACK then
      -- thin white edge so a black flag reads on dark backgrounds
      D.rect(X(fx), fy * sc, X(fx + fw), (fy + 2) * sc, D.color(WHITE, alpha), 0)
      D.rect(X(fx), (fy + fh - 2) * sc, X(fx + fw), (fy + fh) * sc, D.color(WHITE, alpha), 0)
    end
  end

  ui.pushDWriteFont(D.FONT)
  D.text(title, 20 * sc, X(0), 10 * sc, (fx - 10) * sc, 30 * sc, D.ALIGN_END, D.color(TEXT, alpha))
  D.text(sub, 13 * sc, X(0), 40 * sc, (fx - 10) * sc, 20 * sc, D.ALIGN_END, D.color(SUB, alpha))
  ui.popDWriteFont()
end

return M
