-- Pure maths: a look (pattern + colours + speed) compiled once, evaluated per frame for a group of n LEDs into a
-- buffer of packed colours. UNSET in the buffer = transparent (the next scenario or the base look shows through),
-- color.ORIGINAL = the car's own logic, 0 = off.

local color = require('src/color')

local M = { UNSET = -3 }

local floor, cos, pi = math.floor, math.cos, math.pi

M.KINDS = { 'solid', 'blink', 'alternate', 'pulse', 'run', 'fill', 'frames', 'rainbow', 'off', 'original' }
M.NAMES = {
  solid = 'Svítí', blink = 'Bliká', alternate = 'Střídá liché a sudé', pulse = 'Pulzuje', run = 'Běžící světlo',
  fill = 'Plní se', frames = 'Vlastní snímky', rainbow = 'Duha', off = 'Zhasnuto', original = 'Podle auta',
}
M.DIRS = { 'left', 'right', 'edges', 'centre', 'bounce' }
M.DIR_NAMES = { left = 'zleva doprava', right = 'zprava doleva', edges = 'od krajů ke středu',
  centre = 'od středu ke krajům', bounce = 'tam a zpět' }
-- which settings a pattern uses (the UI shows only these)
M.USES = {
  solid = { c1 = true }, blink = { c1 = true, c2 = true, hz = true }, alternate = { c1 = true, c2 = true, hz = true },
  pulse = { c1 = true, c2 = true, hz = true }, run = { c1 = true, c2 = true, hz = true, dir = true, width = true },
  fill = { zones = true, c2 = true, dir = true }, frames = { frames = true }, rainbow = { hz = true }, off = {}, original = {},
}

M.DEFAULT_ZONES = { 0, '#00FF00', 0.4, '#FF0000', 0.75, '#0050FF' }

local KIND_INDEX = {}
for i = 1, #M.KINDS do KIND_INDEX[M.KINDS[i]] = i end
M.KIND_INDEX = KIND_INDEX

local SOLID, BLINK, ALTERNATE, PULSE, RUN, FILL, FRAMES, RAINBOW, OFF, ORIGINAL = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

local function num(v, def, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return def end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

-- look table (as stored in a preset) -> compiled look. Never fails: bad values fall back to defaults.
function M.compile(look)
  look = type(look) == 'table' and look or {}
  local cl = { kind = KIND_INDEX[look.p] or SOLID, p = KIND_INDEX[look.p] and look.p or 'solid' }
  local c = type(look.c) == 'table' and look.c or {}
  cl.c1 = color.parse(c[1], 0xFFFFFF)
  cl.c2 = color.parse(c[2], color.OFF)
  cl.hz = num(look.hz, 2, 0.05, 30)
  cl.dir = M.DIR_NAMES[look.dir] and look.dir or 'left'
  cl.width = floor(num(look.width, 1, 1, 64))
  cl.src = look.src == 'car' and 'car' or 'relative'
  cl.fps = num(look.fps, 4, 0.2, 30)
  -- fill zones: { start, colour, start, colour, ... } with starts 0..1 ascending
  cl.zu, cl.zc = {}, {}
  local z = type(look.zones) == 'table' and look.zones or M.DEFAULT_ZONES
  for i = 1, #z - 1, 2 do
    local u = num(z[i], nil, 0, 1)
    local col = color.parse(z[i + 1], nil)
    if u and col then cl.zu[#cl.zu + 1], cl.zc[#cl.zc + 1] = u, col end
  end
  if #cl.zu == 0 then cl.zu[1], cl.zc[1] = 0, cl.c1 end
  cl.zu[1] = 0
  -- frames: palette (1..9) and per group rows of characters ('.' transparent, '0' off, '1'..'9' palette)
  cl.palette = {}
  local pal = type(look.palette) == 'table' and look.palette or {}
  for i = 1, 9 do cl.palette[i] = color.parse(pal[i], 0xFFFFFF) end
  cl.groups = type(look.g) == 'table' and look.g or {}
  return cl
end

local function code(ch)
  if ch == '.' then return -1 end
  local d = tonumber(ch)
  return d or 0
end

-- One group's frames of a compiled look, rescaled to n cells by nearest-centre sampling. Returns
-- { rows = { {codes} ... }, ok = bool, srcN = n of the stored frames } or nil when the look has no frames for gi.
function M.framesFor(cl, gi, n, allowRescale)
  local g = cl.groups[gi] or cl.groups[tostring(gi)]
  if type(g) ~= 'table' or type(g.f) ~= 'table' or #g.f == 0 then return nil end
  local srcN = floor(num(g.n, 0, 0, 64))
  local out = { rows = {}, srcN = srcN, ok = true }
  if srcN ~= n and not allowRescale then out.ok = false end
  for fi = 1, math.min(#g.f, 64) do
    local s = tostring(g.f[fi])
    local row = {}
    local len = #s
    for k = 1, n do
      local src
      if len == n then src = k
      else src = floor((k - 0.5) * len / n) + 1 end
      row[k] = code(s:sub(src, src))
    end
    out.rows[fi] = row
  end
  return out
end

-- Rank of LED k (1..n) along the fill / run direction and the length of that path.
local function rank(dir, k, n)
  if dir == 'right' then return n - k + 1, n end
  if dir == 'edges' or dir == 'centre' then
    local half = floor((n + 1) / 2)
    local r = k <= n - k + 1 and k or n - k + 1
    if dir == 'centre' then r = half - r + 1 end
    return r, half
  end
  return k, n
end

local function zoneColour(cl, u)
  local zu, zc = cl.zu, cl.zc
  local col = zc[1]
  for i = 2, #zu do
    if zu[i] <= u + 1e-9 then col = zc[i] else break end
  end
  return col
end

-- Evaluates compiled look cl for n LEDs into buf[1..n].
-- t: seconds since the scenario became active; u: fill level 0..1; thr/rpm: per LED car thresholds (src = 'car');
-- frames: result of framesFor for this group.
function M.eval(cl, buf, n, t, u, thr, rpm, frames)
  local kind = cl.kind
  if kind == SOLID then
    local c = cl.c1
    for k = 1, n do buf[k] = c end
  elseif kind == BLINK then
    local c = (t * cl.hz) % 1 < 0.5 and cl.c1 or cl.c2
    for k = 1, n do buf[k] = c end
  elseif kind == ALTERNATE then
    local first = (t * cl.hz) % 1 < 0.5
    for k = 1, n do buf[k] = ((k % 2 == 1) == first) and cl.c1 or cl.c2 end
  elseif kind == PULSE then
    local b = floor((0.5 - 0.5 * cos(2 * pi * t * cl.hz)) * 16 + 0.5) / 16
    local c = color.mix(cl.c2, cl.c1, b)
    for k = 1, n do buf[k] = c end
  elseif kind == RUN then
    local dir = cl.dir
    local _, len = rank(dir == 'bounce' and 'left' or dir, 1, n)
    local ph = (t * cl.hz) % 1
    local pos
    if dir == 'bounce' then
      ph = ph * 2
      if ph > 1 then ph = 2 - ph end
      pos = floor(ph * (len - 1) + 0.5) + 1
    else
      pos = floor(ph * len) + 1
    end
    local w = cl.width
    for k = 1, n do
      local r = rank(dir == 'bounce' and 'left' or dir, k, n)
      buf[k] = (r >= pos and r < pos + w) and cl.c1 or cl.c2
    end
  elseif kind == FILL then
    local dir = cl.dir
    if thr and cl.src == 'car' then
      for k = 1, n do
        local tk = thr[k]
        buf[k] = (tk and rpm >= tk) and zoneColour(cl, thr.rank[k]) or cl.c2
      end
    else
      if u < 0 then u = 0 end
      for k = 1, n do
        local r, len = rank(dir == 'bounce' and 'left' or dir, k, n)
        local m = floor(u * len + 1e-4)
        if r <= m then
          buf[k] = zoneColour(cl, len > 1 and (r - 1) / (len - 1) or 1)
        else
          buf[k] = cl.c2
        end
      end
    end
  elseif kind == FRAMES then
    if frames and frames.ok and #frames.rows > 0 then
      local row = frames.rows[floor(t * cl.fps) % #frames.rows + 1]
      local pal = cl.palette
      for k = 1, n do
        local cd = row[k]
        buf[k] = cd < 0 and M.UNSET or (cd == 0 and color.OFF or pal[cd])
      end
    else
      for k = 1, n do buf[k] = M.UNSET end
    end
  elseif kind == RAINBOW then
    local step = floor(t * cl.hz * 24) / 24
    for k = 1, n do buf[k] = color.hsv((k - 1) / n + step, 1, 1) end
  elseif kind == OFF then
    for k = 1, n do buf[k] = color.OFF end
  else
    for k = 1, n do buf[k] = color.ORIGINAL end
  end
end

return M
