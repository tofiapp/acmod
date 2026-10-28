-- Display pages: what LedControl draws on the car's display (src/display.lua paints it into the display texture, the
-- Displej tab draws the same into the window as a preview). Every layout works in its own W x H box, positions and
-- sizes relative to it, so one page fits 800 x 480, 480 x 272 and square screens alike.
--
-- Drawing: ui.drawRectFilled and ui.dwriteDrawTextClipped(text, size, p1, p2, hAlign, vAlign, wrap, colour) (both as
-- official CSP apps call them); text is clipped to its box by the game and sized here to fit it: the width of a string
-- is measured once at size 100 with ui.measureDWriteText (official Navigator app) and scaled, so a long text shrinks
-- instead of running over the edge. Font: Bahnschrift SemiBold SemiCondensed (Windows 10/11, as MirrorDelta).
-- No allocation per paint once the strings are known: colours and vectors are reused, widths cached per string.
--
-- data (filled by display.lua): gear, speed, rpm, lap, last, best, fuel, pos, laps, delta (strings), deltaSign
-- (-1 / 0 / 1), cells (packed 0xRRGGBB of the virtual LED row, -2 = unset), nCells, overlay (nil or an OVERLAYS
-- entry), overlaySub (string), blink (bool: overlay phase).

local csp = require('src/csp')
local ui, vec2, rgbm = csp.ui, csp.vec2, csp.rgbm
local M = {}

M.FONT = 'Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed'

local P1, P2 = vec2(), vec2()
local ox, oy, sc = 0, 0, 1

-- packed colour -> rgbm, cached (a page uses a handful of colours)
local colours = {}
local function col(p)
  local c = colours[p]
  if not c then
    c = rgbm(math.floor(p / 65536) % 256 / 255, math.floor(p / 256) % 256 / 255, p % 256 / 255, 1)
    colours[p] = c
  end
  return c
end

local BG, CELL_OFF, TEXT, LABEL, GREEN, RED = 0x000000, 0x1E1E1E, 0xFFFFFF, 0x9A9A9A, 0x20D040, 0xFF3030
M.BG = BG

-- width of a string at size 100 (cleared when it grows large: lap times keep producing new strings)
local widths, nWidths = {}, 0
local function width100(s)
  local w = widths[s]
  if not w then
    local m = ui.measureDWriteText(s, 100)
    w = m and m.x or #s * 55
    if nWidths > 400 then widths, nWidths = {}, 0 end
    widths[s], nWidths = w, nWidths + 1
  end
  return w
end

-- font size so s fits a w x h box: at most `size`, at most 92 % of the height, at most 96 % of the width
function M.fit(s, size, w, h)
  if size > h * 0.92 then size = h * 0.92 end
  local need = width100(s) * size / 100
  if need > w * 0.96 then size = size * w * 0.96 / need end
  return size
end

-- Sets where the next page goes (origin and scale: 1 in the texture, < 1 in the window preview).
function M.origin(x, y, scale) ox, oy, sc = x, y, scale end

local function rect(x, y, w, h, p)
  P1.x, P1.y = ox + x * sc, oy + y * sc
  P2.x, P2.y = ox + (x + w) * sc, oy + (y + h) * sc
  ui.drawRectFilled(P1, P2, col(p))
end
M.rect = rect

-- text fitted into the box x, y, w, h; align 0 start, 0.5 centre, 1 end
local ALIGN = nil
local function text(s, x, y, w, h, size, align, p)
  if not s or s == '' then return end
  if not ALIGN then ALIGN = { [0] = ui.Alignment.Start, [0.5] = ui.Alignment.Center, [1] = ui.Alignment.End } end
  local fs = M.fit(s, size, w, h)
  P1.x, P1.y = ox + x * sc, oy + y * sc
  P2.x, P2.y = ox + (x + w) * sc, oy + (y + h) * sc
  ui.dwriteDrawTextClipped(s, fs * sc, P1, P2, ALIGN[align] or ALIGN[0.5], ALIGN[0.5], false, col(p))
end
M.text = text

-- the virtual LED row as a bar of cells
local function cells(d, x, y, w, h)
  local n = d.nCells or 0
  if n <= 0 then return end
  local gap = math.max(1, w * 0.008)
  local cw = (w - gap * (n - 1)) / n
  for k = 1, n do
    local p = d.cells[k]
    rect(x + (k - 1) * (cw + gap), y, cw, h, (p and p > 0) and p or CELL_OFF)
  end
end

local function deltaColour(d) return d.deltaSign < 0 and GREEN or (d.deltaSign > 0 and RED or TEXT) end

-- ---------------------------------------------------------------- pages

-- Závod: LED row on top, speed | gear | lap time, a strip with position, lap and delta at the bottom
local function race(W, H, d)
  local m = W * 0.03
  cells(d, m, m, W - 2 * m, H * 0.13)
  local top, bottom = H * 0.13 + 2 * m, H * 0.82
  local colW = (W - 2 * m) / 10
  -- speed (left)
  text('km/h', m, top, colW * 3, (bottom - top) * 0.2, 200, 0.5, LABEL)
  text(d.speed, m, top + (bottom - top) * 0.2, colW * 3, (bottom - top) * 0.6, 400, 0.5, TEXT)
  -- gear (middle)
  text(d.gear, m + colW * 3, top, colW * 4, bottom - top, 900, 0.5, TEXT)
  -- lap time, last lap, fuel (right)
  local rx, rw, rh = m + colW * 7, colW * 3, (bottom - top) / 4
  text(d.lap, rx, top, rw, rh * 1.3, 300, 1, TEXT)
  text(d.last, rx, top + rh * 1.4, rw, rh, 300, 1, LABEL)
  text(d.fuel, rx, top + rh * 2.6, rw, rh * 1.1, 300, 1, TEXT)
  -- bottom strip
  rect(0, bottom, W, H - bottom, 0x101010)
  text(d.pos, m, bottom, W * 0.45, H - bottom, 200, 0, TEXT)
  text(d.delta, W * 0.5, bottom, W * 0.5 - m, H - bottom, 200, 1, deltaColour(d))
end

-- Otáčky: a big LED row, the RPM and the gear
local function revs(W, H, d)
  local m = W * 0.03
  cells(d, m, m, W - 2 * m, H * 0.34)
  local top = H * 0.34 + 2 * m
  text(d.rpm, m, top, W * 0.62, H - top - m, 500, 0, TEXT)
  text(d.gear, W * 0.64, top, W * 0.36 - m, H - top - m, 900, 0.5, TEXT)
end

-- Kola: lap times and the race position
local LAP_LABELS = { 'Aktuální', 'Poslední', 'Nejlepší', 'Pozice', 'Kolo' }
local lapValues = {}
local function laps(W, H, d)
  local m = W * 0.04
  cells(d, m, m, W - 2 * m, H * 0.08)
  local top = H * 0.08 + 2 * m
  local rh = (H - top - m) / 5
  lapValues[1], lapValues[2], lapValues[3], lapValues[4], lapValues[5] = d.lap, d.last, d.best, d.pos, d.laps
  for i = 1, 5 do
    local y = top + (i - 1) * rh
    if i % 2 == 0 then rect(m, y, W - 2 * m, rh, 0x0E0E0E) end
    text(LAP_LABELS[i], m * 1.5, y, W * 0.38, rh, 200, 0, LABEL)
    text(lapValues[i], W * 0.44, y, W * 0.56 - m * 1.5, rh, 260, 1, i == 3 and 0xC080FF or TEXT)
  end
end

M.PAGES = {
  { id = 'race', name = 'Závod', draw = race },
  { id = 'revs', name = 'Otáčky', draw = revs },
  { id = 'laps', name = 'Kola', draw = laps },
}

-- Situations that take the whole display over, in priority order (first active wins). `scenario` is the id of the
-- catalogue scenario whose test decides (src/scenarios.lua), `group` the setting that switches it.
M.OVERLAYS = {
  { scenario = 'pitLimiter', group = 'pit', title = 'PIT LIMITER', bg = 0xFF5000, fg = 0x000000, blink = 2, sub = 'speed' },
  { scenario = 'pitLane', group = 'pit', title = 'ZAPNI LIMITER', bg = 0xE00000, fg = 0xFFFFFF, blink = 4, sub = 'speed' },
  { scenario = 'flagPenalty', group = 'flags', title = 'PENALIZACE', bg = 0xE00000, fg = 0xFFFFFF, blink = 1 },
  { scenario = 'flagBlack', group = 'flags', title = 'ČERNÁ VLAJKA', bg = 0x000000, fg = 0xFFFFFF, blink = 1 },
  { scenario = 'flagBlue', group = 'flags', title = 'MODRÁ VLAJKA', bg = 0x0030FF, fg = 0xFFFFFF, blink = 2 },
  { scenario = 'flagYellow', group = 'flags', title = 'ŽLUTÁ VLAJKA', bg = 0xFFC800, fg = 0x000000, blink = 2 },
  { scenario = 'flagChequered', group = 'flags', title = 'CÍL', bg = 0xFFFFFF, fg = 0x000000 },
  { scenario = 'lowFuel', group = 'fuel', title = 'MÁLO PALIVA', bg = 0xFF8000, fg = 0x000000, sub = 'fuel', banner = true },
}
M.OVERLAY_GROUPS = { { 'pit', 'Pit limiter a pit lane' }, { 'flags', 'Vlajky' }, { 'fuel', 'Málo paliva' } }

-- full screen (or a banner over the page for warnings)
local function overlay(W, H, d, o)
  local bg = (o.blink and not d.blink) and BG or o.bg
  local fg = (o.blink and not d.blink) and o.bg or o.fg
  if o.banner then
    local h = H * 0.3
    rect(0, H - h, W, h, bg)
    text(o.title, W * 0.04, H - h, W * 0.55, h, 300, 0, fg)
    text(d.overlaySub, W * 0.6, H - h, W * 0.36, h, 300, 1, fg)
    return
  end
  rect(0, 0, W, H, bg)
  local hasSub = d.overlaySub and d.overlaySub ~= ''
  text(o.title, W * 0.05, H * (hasSub and 0.12 or 0.2), W * 0.9, H * (hasSub and 0.46 or 0.6), 500, 0.5, fg)
  if hasSub then text(d.overlaySub, W * 0.05, H * 0.6, W * 0.9, H * 0.3, 400, 0.5, fg) end
end

-- Draws page `page` (index in PAGES) of size W x H at the current origin, with a takeover overlay on top.
function M.draw(page, W, H, d)
  ui.pushDWriteFont(M.FONT)
  rect(0, 0, W, H, BG)
  local o = d.overlay
  if not o or o.banner then
    local p = M.PAGES[page] or M.PAGES[1]
    p.draw(W, H, d)
  end
  if o then overlay(W, H, d, o) end
  ui.popDWriteFont()
end

return M
