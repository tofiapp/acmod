-- Pit lane lights of the delta window (delta line + mini sectors) and the colour of the timing window's BOX.
-- Styles (S.pitStyle):
--   1 scanner: one soft light runs from side to side and back (eased at the ends, like a scanner bar);
--   2 from the centre: waves run from the middle to both edges;
--   3 breathing: everything fades in and out slowly together;
--   4 halves: the left and right half light in turn (the first version; mini sectors per S.pitSectorPattern).
-- Every style gives a brightness 0..1 for a place u (0 left .. 1 right); the window mixes the pit colour over the idle
-- colour with it. Pure arithmetic, no allocation.

local config = require('src/config')
local S = config.S

local M = {}

-- S.pitColor: blue, orange, white, yellow (the first version)
local COLORS = {
  rgbm(0.18, 0.6, 1, 1),
  rgbm(1, 0.5, 0.05, 1),
  rgbm(0.95, 0.96, 0.98, 1),
  rgbm(1, 0.8, 0.1, 1),
}
local INK_DARK = rgbm(0.07, 0.08, 0.1, 1)
local INK_LIGHT = rgbm(1, 1, 1, 1)
M.NAMES = { 'Modrá', 'Oranžová', 'Bílá', 'Žlutá' }
M.STYLES = { 'Skener (světlo běhá ze strany na stranu)', 'Vlny ze středu ke krajům', 'Dýchání (pomalé pulzování)',
  'Poloviny na střídačku' }

function M.color() return COLORS[S.pitColor] or COLORS[1] end
-- Colour by its index in NAMES (other pit lights with their own colour setting).
function M.colorAt(i) return COLORS[i] or COLORS[2] end
-- Text colour on a pit coloured background.
function M.ink() return S.pitColor == 1 and INK_LIGHT or INK_DARK end

-- True while the lights should run (in the pit lane, setting on).
function M.active()
  if not S.pitBlink then return false end
  local car = ac.getCar(0)
  return car ~= nil and car.isInPitlane == true
end

local SCAN_PERIOD = 1.7        -- s there and back
local SCAN_WIDTH = 0.16        -- half width of the light, in parts of the whole width
local WAVE_PERIOD = 1.1        -- s per wave
local WAVE_WIDTH = 0.22
local BREATH_PERIOD = 1.6
local HALF_PERIOD = 0.35

-- Phase 1 or 2 of the halves style.
local function half(t) return math.floor(t / HALF_PERIOD) % 2 + 1 end

-- Brightness at place u (0..1) at time t.
function M.level(u, t)
  local style = S.pitStyle
  if style == 2 then
    local f = (t / WAVE_PERIOD) % 1                    -- the wave's distance from the centre, 0..1
    local d = math.abs(u - 0.5) * 2
    local k = math.max(0, 1 - math.abs(d - f) / WAVE_WIDTH)
    return k * k * (1 - 0.35 * f)
  elseif style == 3 then
    local k = 0.5 - 0.5 * math.cos(t / BREATH_PERIOD * 2 * math.pi)
    return 0.15 + 0.85 * k
  elseif style == 4 then
    return ((u < 0.5) == (half(t) == 1)) and 1 or 0
  end
  local p = 0.5 - 0.5 * math.cos(t / SCAN_PERIOD * 2 * math.pi)   -- eased: slows down at the edges
  p = 0.04 + 0.92 * p
  local k = math.max(0, 1 - math.abs(u - p) / SCAN_WIDTH)
  return k * k * (3 - 2 * k)                                         -- smooth edge
end

-- Brightness of mini sector i of count (its middle), with the halves style's own patterns.
function M.sectorLevel(i, count, t)
  if S.pitStyle == 4 then
    local h = half(t)
    local on
    if S.pitSectorPattern == 2 then on = (i <= count / 2) == (h == 1) else on = i % 2 == h % 2 end
    return on and 1 or 0
  end
  return M.level((i - 0.5) / count, t)
end

return M
