-- Shared drawing helpers. Vectors and colours are reused, so drawing does not
-- allocate per frame. Strings are cached by the callers.

local D = {}

-- Bahnschrift ships with Windows 10 and 11; DirectWrite falls back to another font if it is missing.
D.FONT = 'Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed'

D.ALIGN_START = ui.Alignment.Start
D.ALIGN_CENTER = ui.Alignment.Center
D.ALIGN_END = ui.Alignment.End

local p1, p2 = vec2(), vec2()
local cursor, box = vec2(), vec2()
local tint = rgbm()
local shadow = rgbm(0, 0, 0, 0.6)

-- Returns a shared colour: base with its alpha multiplied by alpha. Use it right away.
function D.color(base, alpha)
  tint:set(base)
  tint.mult = base.mult * alpha
  return tint
end

function D.rect(x1, y1, x2, y2, color, rounding)
  ui.drawRectFilled(p1:set(x1, y1), p2:set(x2, y2), color, rounding or 0)
end

-- Draws str inside the box (x, y, w, h), vertically centred, with a soft drop shadow.
function D.text(str, size, x, y, w, h, align, color)
  box:set(w, h)
  local o = math.max(1, size * 0.05)
  shadow.mult = 0.6 * color.mult
  ui.setCursor(cursor:set(x + o, y + o))
  ui.dwriteTextAligned(str, size, align, D.ALIGN_CENTER, box, false, shadow)
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
