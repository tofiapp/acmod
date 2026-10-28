-- Display pages: what LedControl draws on the car's display (src/display.lua paints it into the display texture, the
-- Displej tab draws the same into the window as a preview). Every layout works in its own W x H box, positions and
-- sizes relative to it, so one page fits 800 x 480, 480 x 272 and square screens alike.
--
-- Drawing: ui.drawRectFilled(p1, p2, colour, rounding) and ui.dwriteDrawTextClipped(text, size, p1, p2, hAlign,
-- vAlign, wrap, colour) (both as official CSP apps call them); text is clipped to its box by the game and sized here
-- to fit it: the width of a string is measured once at size 100 with ui.measureDWriteText (official Navigator app)
-- and scaled, so a long text shrinks instead of running over the edge.
-- Style (M.setStyle, from the Displej tab settings): colours (theme or own), font, rounding, brightness, the LED row
-- (shown, number of cells, height, gap) and the zones of the page Vlastní.
-- No allocation per paint once the strings are known: colours and vectors are reused, widths cached per string.
--
-- data (filled by display.lua): gear, speed, speedUnit, rpm, lap, last, best, fuel, pos, laps, delta (strings),
-- deltaSign (-1 / 0 / 1), cells (packed 0xRRGGBB of the virtual LED row, -2 = unset), nCells, overlay (nil or an
-- OVERLAYS entry), overlaySub (string), blink (bool: overlay phase).

local csp = require('src/csp')
local ui, vec2, rgbm = csp.ui, csp.vec2, csp.rgbm
local M = {}

-- ---------------------------------------------------------------- style

-- DirectWrite font names (Windows fonts; the Bahnschrift string is the one MirrorDelta uses)
M.FONTS = {
  { name = 'Bahnschrift', font = 'Bahnschrift;Weight=SemiBold;Stretch=SemiCondensed' },
  { name = 'Segoe UI', font = 'Segoe UI;Weight=Bold' },
  { name = 'Arial', font = 'Arial;Weight=Bold' },
  { name = 'Consolas', font = 'Consolas;Weight=Bold' },
}
M.FONT = M.FONTS[1].font

-- colour themes: background, text, labels, accent (best lap, highlights), unlit LED cell, strips
M.THEMES = {
  { name = 'Tmavý', bg = 0x000000, text = 0xFFFFFF, label = 0x9A9A9A, accent = 0xC080FF, cellOff = 0x1E1E1E, strip = 0x101010 },
  { name = 'Světlý', bg = 0xF2F2F2, text = 0x101010, label = 0x5A5A5A, accent = 0x6020C0, cellOff = 0xC8C8C8, strip = 0xDCDCDC },
  { name = 'Závodní', bg = 0x0C0C0C, text = 0xFFD200, label = 0xB4A050, accent = 0xFF5000, cellOff = 0x2A2A1E, strip = 0x1C1C10 },
  { name = 'Modrý', bg = 0x041028, text = 0xE8F0FF, label = 0x7A90B8, accent = 0x40C0FF, cellOff = 0x14243C, strip = 0x0A1A34 },
}
M.COLOUR_KEYS = { 'bg', 'text', 'label', 'accent', 'cellOff', 'strip' }
M.COLOUR_NAMES = { 'Pozadí', 'Text', 'Popisky', 'Zvýraznění', 'Zhasnutá dioda', 'Pruhy' }

local style = { bg = 0x000000, text = 0xFFFFFF, label = 0x9A9A9A, accent = 0xC080FF, cellOff = 0x1E1E1E, strip = 0x101010,
  font = M.FONT, rounding = 0, brightness = 1, cells = true, cellH = 1, cellGap = 0.008,
  zones = { 'speed', 'gear', 'lap', 'last', 'fuel', 'pos', 'delta' } }
M.style = style

-- fields a zone of the page Vlastní can show
M.FIELDS = {
  { id = 'none', name = '—' },
  { id = 'gear', name = 'Převod' },
  { id = 'speed', name = 'Rychlost' },
  { id = 'rpm', name = 'Otáčky', label = 'ot/min' },
  { id = 'lap', name = 'Čas kola', label = 'Kolo' },
  { id = 'last', name = 'Poslední kolo', label = 'Poslední' },
  { id = 'best', name = 'Nejlepší kolo', label = 'Nejlepší' },
  { id = 'delta', name = 'Delta', label = 'Delta' },
  { id = 'fuel', name = 'Palivo', label = 'Palivo' },
  { id = 'pos', name = 'Pozice', label = 'Pozice' },
  { id = 'laps', name = 'Kolo (počet)', label = '' },
}
M.FIELD_BY_ID = {}
for i = 1, #M.FIELDS do M.FIELD_BY_ID[M.FIELDS[i].id] = M.FIELDS[i] end
M.ZONE_NAMES = { 'Vlevo', 'Uprostřed', 'Vpravo nahoře', 'Vpravo uprostřed', 'Vpravo dole', 'Dole vlevo', 'Dole vpravo' }
M.DEFAULT_ZONES = { 'speed', 'gear', 'lap', 'last', 'fuel', 'pos', 'delta' }

-- packed colour -> rgbm with the display brightness, cached (a page uses a handful of colours)
local colours = {}
local function col(p)
  local c = colours[p]
  if not c then
    local k = style.brightness
    c = rgbm(math.floor(p / 65536) % 256 / 255 * k, math.floor(p / 256) % 256 / 255 * k, p % 256 / 255 * k, 1)
    colours[p] = c
  end
  return c
end

-- Applies settings (st: any of the style keys). Colours are packed 0xRRGGBB.
function M.setStyle(st)
  for k, v in pairs(st) do style[k] = v end
  colours = {}
  M.FONT = style.font
end

-- ---------------------------------------------------------------- drawing

local P1, P2 = vec2(), vec2()
local ox, oy, sc = 0, 0, 1

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
function M.clearWidths() widths, nWidths = {}, 0 end       -- (the font changed)

-- font size so s fits a w x h box: at most `size`, at most 92 % of the height, at most 96 % of the width
function M.fit(s, size, w, h)
  if size > h * 0.92 then size = h * 0.92 end
  local need = width100(s) * size / 100
  if need > w * 0.96 then size = size * w * 0.96 / need end
  return size
end

-- Sets where the next page goes (origin and scale: 1 in the texture, < 1 in the window preview).
function M.origin(x, y, scale) ox, oy, sc = x, y, scale end

-- rectangle; r = rounding in pixels of the page (0 = square corners)
local function rect(x, y, w, h, p, r)
  P1.x, P1.y = ox + x * sc, oy + y * sc
  P2.x, P2.y = ox + (x + w) * sc, oy + (y + h) * sc
  ui.drawRectFilled(P1, P2, col(p), (r or 0) * sc)
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

-- the virtual LED row as a bar of cells; returns the height used (0 when the row is switched off)
local function cells(d, x, y, w, h)
  local n = d.nCells or 0
  if n <= 0 or not style.cells then return 0 end
  h = h * style.cellH
  local gap = math.max(1, w * style.cellGap)
  local cw = (w - gap * (n - 1)) / n
  local r = style.rounding * math.min(cw, h) * 0.5
  for k = 1, n do
    local p = d.cells[k]
    rect(x + (k - 1) * (cw + gap), y, cw, h, (p and p > 0) and p or style.cellOff, r)
  end
  return h
end

local function deltaColour(d) return d.deltaSign < 0 and 0x20D040 or (d.deltaSign > 0 and 0xFF3030 or style.text) end

-- ---------------------------------------------------------------- pages

-- Závod: LED row on top, speed | gear | lap time, a strip with position, lap and delta at the bottom
local function race(W, H, d)
  local m = W * 0.03
  local ch = cells(d, m, m, W - 2 * m, H * 0.13)
  local top, bottom = (ch > 0 and ch + 2 * m or m), H * 0.82
  local colW = (W - 2 * m) / 10
  text(d.speedUnit, m, top, colW * 3, (bottom - top) * 0.2, 200, 0.5, style.label)
  text(d.speed, m, top + (bottom - top) * 0.2, colW * 3, (bottom - top) * 0.6, 400, 0.5, style.text)
  text(d.gear, m + colW * 3, top, colW * 4, bottom - top, 900, 0.5, style.text)
  local rx, rw, rh = m + colW * 7, colW * 3, (bottom - top) / 4
  text(d.lap, rx, top, rw, rh * 1.3, 300, 1, style.text)
  text(d.last, rx, top + rh * 1.4, rw, rh, 300, 1, style.label)
  text(d.fuel, rx, top + rh * 2.6, rw, rh * 1.1, 300, 1, style.text)
  rect(0, bottom, W, H - bottom, style.strip)
  text(d.pos, m, bottom, W * 0.45, H - bottom, 200, 0, style.text)
  text(d.delta, W * 0.5, bottom, W * 0.5 - m, H - bottom, 200, 1, deltaColour(d))
end

-- Otáčky: a big LED row, the RPM and the gear
local function revs(W, H, d)
  local m = W * 0.03
  local ch = cells(d, m, m, W - 2 * m, H * 0.34)
  local top = ch > 0 and ch + 2 * m or m
  text(d.rpm, m, top, W * 0.62, H - top - m, 500, 0, style.text)
  text(d.gear, W * 0.64, top, W * 0.36 - m, H - top - m, 900, 0.5, style.text)
end

-- Kola: lap times and the race position
local LAP_LABELS = { 'Aktuální', 'Poslední', 'Nejlepší', 'Pozice', 'Kolo' }
local lapValues = {}
local function laps(W, H, d)
  local m = W * 0.04
  local ch = cells(d, m, m, W - 2 * m, H * 0.08)
  local top = ch > 0 and ch + 2 * m or m
  local rh = (H - top - m) / 5
  lapValues[1], lapValues[2], lapValues[3], lapValues[4], lapValues[5] = d.lap, d.last, d.best, d.pos, d.laps
  local r = style.rounding * rh * 0.3
  for i = 1, 5 do
    local y = top + (i - 1) * rh
    if i % 2 == 0 then rect(m, y, W - 2 * m, rh, style.strip, r) end
    text(LAP_LABELS[i], m * 1.5, y, W * 0.38, rh, 200, 0, style.label)
    text(lapValues[i], W * 0.44, y, W * 0.56 - m * 1.5, rh, 260, 1, i == 3 and style.accent or style.text)
  end
end

-- Vlastní: the layout of Závod with a field of the user's choice in each of the 7 zones
local function valueOf(d, id)
  if id == 'none' then return nil end
  return d[id]
end
local function colourOf(d, id)
  if id == 'delta' then return deltaColour(d) end
  if id == 'best' then return style.accent end
  return style.text
end
local function labelOf(d, id)
  if id == 'speed' then return d.speedUnit end
  local f = M.FIELD_BY_ID[id]
  return f and f.label or nil
end
-- a zone: a small label on top, the value under it
local function zone(d, id, x, y, w, h, size, align)
  local v = valueOf(d, id)
  if not v then return end
  local l = labelOf(d, id)
  if l and l ~= '' and h > 40 then
    text(l, x, y, w, h * 0.22, 200, align, style.label)
    text(v, x, y + h * 0.22, w, h * 0.78, size, align, colourOf(d, id))
  else
    text(v, x, y, w, h, size, align, colourOf(d, id))
  end
end
local function custom(W, H, d)
  local z = style.zones
  local m = W * 0.03
  local ch = cells(d, m, m, W - 2 * m, H * 0.13)
  local top, bottom = (ch > 0 and ch + 2 * m or m), H * 0.82
  local colW = (W - 2 * m) / 10
  zone(d, z[1] or 'none', m, top, colW * 3, bottom - top, 400, 0.5)
  zone(d, z[2] or 'none', m + colW * 3, top, colW * 4, bottom - top, 900, 0.5)
  local rx, rw, rh = m + colW * 7, colW * 3, (bottom - top) / 3
  for k = 1, 3 do zone(d, z[2 + k] or 'none', rx, top + (k - 1) * rh, rw, rh, 300, 1) end
  rect(0, bottom, W, H - bottom, style.strip)
  zone(d, z[6] or 'none', m, bottom, W * 0.45, H - bottom, 200, 0)
  zone(d, z[7] or 'none', W * 0.5, bottom, W * 0.5 - m, H - bottom, 200, 1)
end

M.PAGES = {
  { id = 'race', name = 'Závod', draw = race },
  { id = 'revs', name = 'Otáčky', draw = revs },
  { id = 'laps', name = 'Kola', draw = laps },
  { id = 'custom', name = 'Vlastní', draw = custom },
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
  local off = o.blink and not d.blink
  local bg = off and style.bg or o.bg
  local fg = off and o.bg or o.fg
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
  ui.pushDWriteFont(style.font)
  rect(0, 0, W, H, style.bg)
  local o = d.overlay
  if not o or o.banner then
    local p = M.PAGES[page] or M.PAGES[1]
    p.draw(W, H, d)
  end
  if o then overlay(W, H, d, o) end
  ui.popDWriteFont()
end

return M
