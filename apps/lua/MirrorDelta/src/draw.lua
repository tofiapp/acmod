-- Shared drawing helpers. Vectors and colours are reused, so drawing does not
-- allocate per frame. Strings are cached by the callers.

local D = {}

-- Bahnschrift ships with Windows 10 and 11; DirectWrite falls back to another font if it is missing.
D.FONT = 'Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed'
-- Unbounded Bold ships with the app (fonts/, SIL OFL); the path is relative to the AC root,
-- the same form official CSP code uses for its own fonts.
D.FONT_GEAR = 'Unbounded:apps/lua/MirrorDelta/fonts;Weight=Bold'
D.FONT_MONO = 'Consolas;Weight=Bold'

D.ALIGN_START = ui.Alignment.Start
D.ALIGN_CENTER = ui.Alignment.Center
D.ALIGN_END = ui.Alignment.End

local p1, p2 = vec2(), vec2()
local cursor, box = vec2(), vec2()
local tint = rgbm()

-- Returns a shared colour: base with its alpha multiplied by alpha. Use it right away.
function D.color(base, alpha)
  tint:set(base)
  tint.mult = base.mult * alpha
  return tint
end

-- Matte translucent panel behind a widget: a tinted rectangle the game shows through, with a faint top edge.
-- (CSP's ui.beginBlurring only blurs what the window draws itself, not the scene behind it.)
local PANEL = rgbm(0.07, 0.08, 0.1, 0.4)
local PANEL_EDGE = rgbm(1, 1, 1, 0.1)
local pa, pb = vec2(), vec2()
local S = require('src/config').S
function D.panel(x1, y1, x2, y2, rounding, opacity)
  local a = (opacity or 1) * S.opacity
  PANEL.mult = S.panelOpacity * a
  PANEL_EDGE.mult = 0.1 * a
  rounding = rounding or 0
  ui.drawRectFilled(pa:set(x1, y1), pb:set(x2, y2), PANEL, rounding)
  ui.drawRectFilled(pa:set(x1 + rounding, y1), pb:set(x2 - rounding, y1 + 1), PANEL_EDGE, 0)
end

function D.rect(x1, y1, x2, y2, color, rounding)
  ui.drawRectFilled(p1:set(x1, y1), p2:set(x2, y2), color, rounding or 0)
end

-- Convex quad (corners in order), e.g. a slanted banner.
local q = vec2()
function D.quad(x1, y1, x2, y2, x3, y3, x4, y4, color)
  ui.pathLineTo(q:set(x1, y1))
  ui.pathLineTo(q:set(x2, y2))
  ui.pathLineTo(q:set(x3, y3))
  ui.pathLineTo(q:set(x4, y4))
  ui.pathFillConvex(color)
end

-- Draws str inside the box (x, y, w, h), vertically centred. Plain text, no shadow behind it.
function D.text(str, size, x, y, w, h, align, color)
  box:set(w, h)
  ui.setCursor(cursor:set(x, y))
  ui.dwriteTextAligned(str, size, align, D.ALIGN_CENTER, box, false, color)
end

-- Text width, cached in the given cache table until the string or size changes.
function D.measure(cache, str, size)
  if cache.str ~= str or cache.size ~= size then
    cache.str, cache.size = str, size
    cache.width = ui.measureDWriteText(str, size).x
  end
  return cache.width
end

-- Lap time as m:ss.ttt (decimals = 3) or m:ss.t (decimals = 1). Allocates: cache the result.
function D.formatLap(ms, decimals)
  if not ms or ms <= 0 then return decimals == 3 and '-:--.---' or '-:--.-' end
  local per = decimals == 3 and 1000 or 10
  local units = math.floor(ms * per / 1000)
  local seconds = math.floor(units / per)
  local frac = units - seconds * per
  local minutes = math.floor(seconds / 60)
  seconds = seconds - minutes * 60
  if decimals == 3 then return string.format('%d:%02d.%03d', minutes, seconds, frac) end
  return string.format('%d:%02d.%d', minutes, seconds, frac)
end

return D
