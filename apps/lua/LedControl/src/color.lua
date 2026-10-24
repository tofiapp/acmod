-- Colours as packed integers 0xRRGGBB (0 = LED off, ORIGINAL = the car's own logic), so a change is one compare.

local M = { ORIGINAL = -1, OFF = 0, WHITE = 0xFFFFFF }

local floor = math.floor

local function byte(v)
  if v <= 0 then return 0 end
  if v >= 1 then return 255 end
  return floor(v * 255 + 0.5)
end

function M.pack(r, g, b)
  return byte(r) * 65536 + byte(g) * 256 + byte(b)
end

-- Returns r, g, b in 0..1.
function M.unpack(p)
  if p < 0 then return 0, 0, 0 end
  return floor(p / 65536) / 255, floor(p / 256) % 256 / 255, p % 256 / 255
end

-- HSV (all 0..1) to a packed colour.
function M.hsv(h, s, v)
  h = (h % 1) * 6
  local i = floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return M.pack(v, t, p)
  elseif i == 1 then return M.pack(q, v, p)
  elseif i == 2 then return M.pack(p, v, t)
  elseif i == 3 then return M.pack(p, q, v)
  elseif i == 4 then return M.pack(t, p, v)
  end
  return M.pack(v, p, q)
end

-- Packed colour between a (f = 0) and b (f = 1).
function M.mix(a, b, f)
  if a < 0 then a = 0 end
  if b < 0 then b = 0 end
  local ar, ag, ab = M.unpack(a)
  local br, bg, bb = M.unpack(b)
  return M.pack(ar + (br - ar) * f, ag + (bg - ag) * f, ab + (bb - ab) * f)
end

-- '#RRGGBB' / 'RRGGBB' / number -> packed, or fallback when it cannot be read.
function M.parse(v, fallback)
  if type(v) == 'number' then
    if v == M.ORIGINAL or (v >= 0 and v <= 0xFFFFFF) then return math.floor(v) end
    return fallback
  end
  if type(v) ~= 'string' then return fallback end
  local h = v:match('^#?(%x%x%x%x%x%x)$')
  if not h then return fallback end
  return tonumber(h, 16)
end

function M.hex(p)
  if p < 0 then return 'původní' end
  return string.format('#%06X', p)
end

return M
