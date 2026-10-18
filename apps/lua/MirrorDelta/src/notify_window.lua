-- Notification window: the newest messages from notify.lua at the top of the screen.
-- Three styles: rounded pill, slanted TV strip, thin line. Sizes scale with the window width.

local config = require('src/config')
local notify = require('src/notify')
local D = require('src/draw')
local S = config.S

local BASE_W = 520
local SLIDE_IN = 0.35          -- s
local FADE_OUT = 0.5           -- s

local DARK = rgbm(0.03, 0.04, 0.055, 0.78)
local BLUE = rgbm(0.25, 0.55, 1, 1)
local WHITE = rgbm(0.96, 0.96, 0.97, 1)
local INK = rgbm(0.067, 0.078, 0.094, 1)
local STOP = rgbm(0.12, 0.13, 0.15, 1)
local STRIP = rgbm(0.957, 0.961, 0.969, 0.95)
local STRIP_LABEL = rgbm(0.29, 0.32, 0.38, 1)

local TAGS = { 'NEJ', 'ODP', 'BOX', 'VÝJ', '▲', '▼', '!', '»', 'STOP', '1', 'CÍL', '✕', 'PEN', 'AC' }

local function kindColor(k)
  if k == notify.FASTEST then return S.colPurple end
  if k == notify.DISCONNECT or k == notify.INVALID or k == notify.PENALTY then return S.colRed end
  if k == notify.PIT_IN or k == notify.PIT_OUT or k == notify.BLUE then return BLUE end
  if k == notify.GAIN then return S.colGreen end
  if k == notify.LOSS or k == notify.YELLOW then return S.colYellow end
  if k == notify.BLACK then return STOP end
  return WHITE
end

-- Text colour on the coloured tag.
local function tagInk(k)
  if k == notify.GAIN or k == notify.LOSS or k == notify.YELLOW or k == notify.LAST_LAP or k == notify.FINISH
    or k == notify.SYSTEM then return INK end
  return WHITE
end

-- Title colour on a dark background (black flag would be invisible).
local function titleColor(k)
  if k == notify.BLACK then return WHITE end
  return kindColor(k)
end

-- Visibility of an event: alpha and slide (1 = still hidden above, 0 = in place), or nil when gone.
local function life(e, now)
  local t = now - e.born
  local total = S.notifyTime
  if t < 0 or t > total then return nil end
  local inK = math.min(1, t / SLIDE_IN)
  local alpha = t > total - FADE_OUT and (total - t) / FADE_OUT or 1
  local ease = 1 - (1 - inK) ^ 3
  return alpha, 1 - ease
end

-- 1: rounded pill with a coloured tag tile on the left
local function drawPill(e, idx, a, slide, sc, w)
  local pw, ph = 300 * sc, 40 * sc
  local x = (w - pw) / 2
  local y = (10 + idx * 48 - slide * 50) * sc
  local k = e.kind
  D.rect(x, y, x + pw, y + ph, D.color(DARK, a), 20 * sc)
  D.rect(x + 5 * sc, y + 5 * sc, x + 51 * sc, y + 35 * sc, D.color(kindColor(k), a), 15 * sc)
  D.text(TAGS[k], 13 * sc, x + 5 * sc, y + 5 * sc, 46 * sc, 30 * sc, D.ALIGN_CENTER, D.color(tagInk(k), a))
  D.text(e.title, 10 * sc, x + 62 * sc, y + 4 * sc, pw - 72 * sc, 14 * sc, D.ALIGN_START, D.color(titleColor(k), a))
  D.text(e.sub, 15 * sc, x + 62 * sc, y + 16 * sc, pw - 72 * sc, 21 * sc, D.ALIGN_START, D.color(S.colText, a))
end

-- 2: slanted TV strip, coloured block with the tag and a white strip with the text
local function drawStrip(e, idx, a, slide, sc, w)
  local pw, ph, sk = 330 * sc, 36 * sc, 12 * sc
  local x = (w - pw) / 2 - slide * 40 * sc
  local y = (12 + idx * 46) * sc
  local k = e.kind
  local tagW = 70 * sc
  D.quad(x + sk, y, x + tagW + sk, y, x + tagW, y + ph, x, y + ph, D.color(kindColor(k), a))
  D.text(TAGS[k], 13 * sc, x, y, tagW + sk, ph, D.ALIGN_CENTER, D.color(tagInk(k), a))
  local sx = x + tagW + 6 * sc
  D.quad(sx + sk, y, x + pw + sk, y, x + pw, y + ph, sx, y + ph, D.color(STRIP, a))
  D.text(e.title, 9 * sc, sx + 16 * sc, y + 3 * sc, pw - tagW - 30 * sc, 12 * sc, D.ALIGN_START, D.color(STRIP_LABEL, a))
  D.text(e.sub, 14 * sc, sx + 16 * sc, y + 14 * sc, pw - tagW - 30 * sc, 20 * sc, D.ALIGN_START, D.color(INK, a))
end

-- 3: plain text and a short coloured line under it
local function drawLine(e, idx, a, slide, sc, w)
  local y = (6 + idx * 46) * sc
  D.text(e.line, 17 * sc, 0, y, w, 24 * sc, D.ALIGN_CENTER, D.color(S.colText, a))
  local lw = 120 * sc * (1 - slide)
  D.rect((w - lw) / 2, y + 26 * sc, (w + lw) / 2, y + 30 * sc, D.color(kindColor(e.kind), a), 2 * sc)
end

-- 4: top right corner, next to the flag: coloured tag tile at the right edge, title and text to its left,
-- a matte translucent panel sized to the text. Text widths are measured once per event (base sizes).
local TITLE_SIZE, SUB_SIZE = 13, 18
local function measure(e)
  if e.measuredFor ~= e.born then
    e.measuredFor = e.born
    e.textW = math.max(ui.measureDWriteText(e.title, TITLE_SIZE).x, ui.measureDWriteText(e.sub, SUB_SIZE).x)
  end
  return e.textW
end
local function drawCorner(e, idx, a, slide, sc, w)
  local k = e.kind
  local R = w - 4 * sc + slide * 60 * sc
  local y = (6 + idx * 48) * sc
  local textW = measure(e) * sc
  local textR = R - 56 * sc
  D.panel(textR - textW - 12 * sc, y - 4 * sc, R + 4 * sc, y + 38 * sc, 8 * sc, a)
  D.rect(R - 44 * sc, y, R, y + 34 * sc, D.color(kindColor(k), a), 8 * sc)
  D.text(TAGS[k], 16 * sc, R - 44 * sc, y, 44 * sc, 34 * sc, D.ALIGN_CENTER, D.color(tagInk(k), a))
  local titleCol = (k == notify.SYSTEM or k == notify.BLACK) and S.colText or kindColor(k)
  D.text(e.title, TITLE_SIZE * sc, textR - textW, y, textW, 16 * sc, D.ALIGN_END, D.color(titleCol, a))
  D.text(e.sub, SUB_SIZE * sc, textR - textW - 40 * sc, y + 13 * sc, textW + 40 * sc, 22 * sc, D.ALIGN_END, D.color(S.colText, a))
end

local STYLES = { drawPill, drawStrip, drawLine, drawCorner }

local M = {}

function M.draw()
  local w = ui.windowWidth()
  if w <= 0 then return end
  local sc = w / BASE_W
  local now = os.preciseClock()
  local style = STYLES[S.notifyLook] or drawCorner
  ui.pushDWriteFont(D.FONT)
  local shown = 0
  for i = 1, 8 do
    if shown >= S.notifyCount then break end
    local e = notify.get(i)
    if not e then break end
    local a, slide = life(e, now)
    if not a then break end      -- events are in time order: everything older is gone too
    style(e, shown, a, slide, sc, w)
    shown = shown + 1
  end
  ui.popDWriteFont()
end

return M
