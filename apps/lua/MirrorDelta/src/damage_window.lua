-- Damage window: twelve car-shaped styles. Every style draws in a 160 x 200 box that is scaled into the window.
-- Body zones come from car.damage[0..3] (front, rear, left, right), wheels from tyre wear / blown tyres
-- (wheels[i].tyreWear, wheels[i].isBlown, read under pcall), the engine from car.engineLifeLeft (1000 = healthy).
-- Undamaged parts keep the style's idle colour, damage goes from yellow to red, a part that was just hit
-- flashes white. Car shapes are fixed geometry, flattened once at load: no per-frame allocation.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local BOX_W, BOX_H = 160, 200
local FRONT, REAR, LEFT, RIGHT = 1, 2, 3, 4          -- zone keys; wheels are 5..8 (FL, FR, RL, RR)

-- ---------------------------------------------------------------- transform and primitives

local ox, oy, sc = 0, 0, 1
local fx, fy, flip = 0, 0, false                     -- frame offset inside the box, horizontal mirror
local pa, pb = vec2(), vec2()

local function X(v) if flip then v = -v end return ox + (fx + v) * sc end
local function Y(v) return oy + (fy + v) * sc end
local function setFrame(dx, dy, mirror) fx, fy, flip = dx or 0, dy or 0, mirror or false end

local function rectB(x, y, w, h, color, r)
  local x1, x2 = X(x), X(x + w)
  if x1 > x2 then x1, x2 = x2, x1 end
  D.rect(x1, Y(y), x2, Y(y + h), color, (r or 0) * sc)
end

local function polyB(pts, color)               -- convex polygon, flat {x1, y1, x2, y2, ...}
  for i = 1, #pts, 2 do ui.pathLineTo(pa:set(X(pts[i]), Y(pts[i + 1]))) end
  ui.pathFillConvex(color)
end

local function quadB(x1, y1, x2, y2, x3, y3, x4, y4, color)
  ui.pathLineTo(pa:set(X(x1), Y(y1)))
  ui.pathLineTo(pa:set(X(x2), Y(y2)))
  ui.pathLineTo(pa:set(X(x3), Y(y3)))
  ui.pathLineTo(pa:set(X(x4), Y(y4)))
  ui.pathFillConvex(color)
end

local function strokeB(pts, color, width, closed)
  for i = 1, #pts, 2 do ui.pathLineTo(pa:set(X(pts[i]), Y(pts[i + 1]))) end
  ui.pathStroke(color, closed ~= false, width * sc)
end

local function lineB(x1, y1, x2, y2, color, width)
  ui.drawLine(pa:set(X(x1), Y(y1)), pb:set(X(x2), Y(y2)), color, width * sc)
end

local function circleB(x, y, r, color)
  ui.drawCircleFilled(pa:set(X(x), Y(y)), r * sc, color, 24)
end

local function rectOutlineB(x, y, w, h, color, r, width)
  local x1, x2 = X(x), X(x + w)
  if x1 > x2 then x1, x2 = x2, x1 end
  ui.drawRect(pa:set(x1, Y(y)), pb:set(x2, Y(y + h)), color, r * sc, nil, width * sc)
end

local function clipB(x1, y1, x2, y2)
  local a, b = X(x1), X(x2)
  if a > b then a, b = b, a end
  ui.pushClipRect(pa:set(a, Y(y1)), pb:set(b, Y(y2)), true)
end

local function textB(str, cx, cy, size, color, w, font)
  w = w or 80
  if font then ui.pushDWriteFont(font) end
  D.text(str, size * sc, X(cx) - w / 2 * sc, Y(cy) - size * 0.75 * sc, w * sc, size * 1.5 * sc, D.ALIGN_CENTER, color)
  if font then ui.popDWriteFont() end
end

-- ---------------------------------------------------------------- geometry (built once)

local function addBezier(out, x0, y0, c1x, c1y, c2x, c2y, x, y, steps)
  for i = 1, steps do
    local t = i / steps
    local u = 1 - t
    out[#out + 1] = u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x
    out[#out + 1] = u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y
  end
end

-- Right half of a symmetric outline (front centre to rear centre), flattened.
local function rightHalf(start, segs)
  local out = { start[1], start[2] }
  for _, sg in ipairs(segs) do
    local x0, y0 = out[#out - 1], out[#out]
    if #sg == 6 then addBezier(out, x0, y0, sg[1], sg[2], sg[3], sg[4], sg[5], sg[6], 8)
    else out[#out + 1], out[#out + 2] = sg[1], sg[2] end
  end
  return out
end

-- Closed outline: right half plus its mirror.
local function mirrorOutline(half)
  local out = {}
  for i = 1, #half do out[i] = half[i] end
  for i = #half - 3, 3, -2 do out[#out + 1], out[#out + 2] = 160 - half[i], half[i + 1] end
  return out
end

-- Half width at y from a right half (y increases along it).
local function halfWidthAt(half, y)
  local best = 0
  for i = 1, #half - 3, 2 do
    local x0, y0, x1, y1 = half[i], half[i + 1], half[i + 2], half[i + 3]
    if y >= math.min(y0, y1) and y <= math.max(y0, y1) then
      local k = y1 ~= y0 and (y - y0) / (y1 - y0) or 1
      best = math.max(best, x0 + (x1 - x0) * k - 80)
    end
  end
  return best
end

-- Horizontal slices {y0, hw0, y1, hw1, ...} for filling a symmetric concave shape with convex quads.
local function slices(half, yTop, yBot, step)
  local out = {}
  local y = yTop
  while y < yBot do
    local y1 = math.min(yBot, y + step)
    out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = y, halfWidthAt(half, y), y1, halfWidthAt(half, y1)
    y = y1
  end
  return out
end

local function profileHalf(profile)             -- {y, hw, y, hw, ...} -> right half points
  local out = {}
  for i = 1, #profile, 2 do out[#out + 1], out[#out + 2] = 80 + profile[i + 1], profile[i] end
  return out
end

local GT_HALF = rightHalf({ 80, 12 }, {
  { 98, 12, 113, 15, 118, 28 }, { 121, 36, 125, 44, 125, 58 }, { 125, 66, 121, 72, 120, 80 },
  { 119, 96, 119, 116, 121, 132 }, { 124, 140, 127, 150, 126, 164 }, { 125, 180, 110, 189, 80, 189 } })
local GT_OUT, GT_SL = mirrorOutline(GT_HALF), slices(GT_HALF, 12, 189, 5)
local GT_Z = { 52, 158, 62, 98 }                 -- front edge, rear edge, left edge, right edge
local GT_WHEELS = { 31, 58, 129, 58, 30, 152, 130, 152 }
local GT_WINDSCREEN = { 65, 64, 95, 64, 99, 84, 61, 84 }
local GT_REAR_WINDOW = { 61, 126, 99, 126, 96, 140, 64, 140 }
local CHASE_OUT = { 54, 30, 106, 30, 114, 40, 126, 132, 134, 166, 26, 166, 34, 132, 46, 40 }

local LMP_HALF = rightHalf({ 80, 8 }, {
  { 96, 8, 110, 12, 116, 22 }, { 122, 32, 126, 44, 125, 60 }, { 124, 70, 116, 76, 106, 80 },
  { 104, 92, 116, 100, 124, 114 }, { 129, 128, 129, 160, 126, 176 }, { 126, 180 }, { 80, 182 } })
local LMP_OUT, LMP_SL = mirrorOutline(LMP_HALF), slices(LMP_HALF, 8, 182, 4)
local LMP_Z = { 62, 162, 66, 94 }

local RALLY_HALF = rightHalf({ 80, 30 }, {
  { 96, 30, 108, 32, 112, 40 }, { 116, 48, 116, 56, 116, 64 }, { 116, 140 }, { 116, 154, 112, 164, 100, 166 }, { 80, 166 } })
local RALLY_OUT, RALLY_SL = mirrorOutline(RALLY_HALF), slices(RALLY_HALF, 30, 166, 4)
local RALLY_Z = { 62, 142, 62, 98 }

local F1_HALF = profileHalf({ 18, 4, 60, 8, 74, 13, 110, 14, 160, 10, 176, 4 })
local F1_SL = slices(F1_HALF, 18, 176, 4)

-- Formula sidepod (right), flattened; convex.
local SIDEPOD = { 92, 84 }
addBezier(SIDEPOD, 92, 84, 104, 84, 115, 92, 115, 106, 6)
SIDEPOD[#SIDEPOD + 1], SIDEPOD[#SIDEPOD + 2] = 113, 128
addBezier(SIDEPOD, 113, 128, 112, 144, 100, 158, 92, 164, 6)
local SIDEPOD_L = {}
for i = 1, #SIDEPOD, 2 do SIDEPOD_L[i], SIDEPOD_L[i + 1] = 160 - SIDEPOD[i], SIDEPOD[i + 1] end

-- Wireframe width profile and its line list {x1, y1, x2, y2, zone, width, ...} with static zones.
local WIRE = { 12, 10, 14, 22, 18, 32, 26, 38, 40, 43, 56, 45, 72, 42, 90, 40, 110, 40, 130, 41,
  146, 45, 160, 46, 172, 44, 182, 36, 188, 22, 189, 10 }
local function zoneAt(x, y)
  if y < 52 then return FRONT end
  if y > 158 then return REAR end
  if x < 62 then return LEFT end
  if x > 98 then return RIGHT end
  return 0
end
local WIRE_LINES = {}
do
  local function add(x1, y1, x2, y2, w)
    local n = #WIRE_LINES
    WIRE_LINES[n + 1], WIRE_LINES[n + 2], WIRE_LINES[n + 3], WIRE_LINES[n + 4] = x1, y1, x2, y2
    WIRE_LINES[n + 5], WIRE_LINES[n + 6] = zoneAt((x1 + x2) / 2, (y1 + y2) / 2), w
  end
  local count = #WIRE / 2
  for _, f in ipairs({ -1, -0.66, -0.33, 0, 0.33, 0.66, 1 }) do
    for i = 1, count - 1 do
      local y0, h0, y1, h1 = WIRE[i * 2 - 1], WIRE[i * 2], WIRE[i * 2 + 1], WIRE[i * 2 + 2]
      add(80 + f * h0, y0, 80 + f * h1, y1, math.abs(f) == 1 and 2 or 0.9)
    end
  end
  for i = 2, count - 1 do
    local y, h = WIRE[i * 2 - 1], WIRE[i * 2]
    for j = 0, 5 do add(80 + (-1 + j / 3) * h, y, 80 + (-1 + (j + 1) / 3) * h, y, 0.9) end
  end
  add(80 - WIRE[2], WIRE[1], 80 + WIRE[2], WIRE[1], 2)
  add(80 - WIRE[#WIRE], WIRE[#WIRE - 1], 80 + WIRE[#WIRE], WIRE[#WIRE - 1], 2)
end

-- Side profile (nose to the right, wheels on y = 42): columns {x0, top0, bot0, x1, top1, bot1} and outline.
local SIDE_TOP = { 6, 40, 6, 27 }
addBezier(SIDE_TOP, 6, 27, 8, 21, 18, 19, 32, 18, 6)
addBezier(SIDE_TOP, 32, 18, 46, 17, 54, 6, 70, 4, 6)
SIDE_TOP[#SIDE_TOP + 1], SIDE_TOP[#SIDE_TOP + 2] = 94, 4
addBezier(SIDE_TOP, 94, 4, 106, 5, 114, 14, 124, 18, 6)
SIDE_TOP[#SIDE_TOP + 1], SIDE_TOP[#SIDE_TOP + 2] = 146, 23
addBezier(SIDE_TOP, 146, 23, 152, 25, 155, 31, 153, 39, 6)
SIDE_TOP[#SIDE_TOP + 1], SIDE_TOP[#SIDE_TOP + 2] = 152, 42
local function sideTop(x)
  for i = 3, #SIDE_TOP - 3, 2 do
    local x0, y0, x1, y1 = SIDE_TOP[i], SIDE_TOP[i + 1], SIDE_TOP[i + 2], SIDE_TOP[i + 3]
    if x >= math.min(x0, x1) and x <= math.max(x0, x1) and x1 ~= x0 then return y0 + (y1 - y0) * (x - x0) / (x1 - x0) end
  end
  return 30
end
local function sideBottom(x)
  for _, cx in ipairs({ 124, 34 }) do
    local d = x - cx
    if math.abs(d) < 14 then return 42 - math.sqrt(196 - d * d) end
  end
  return 42
end
local SIDE_COLS, SIDE_OUT = {}, {}
do
  local x = 6
  while x < 152 do
    local x1 = math.min(152, x + 2)
    local n = #SIDE_COLS
    SIDE_COLS[n + 1], SIDE_COLS[n + 2], SIDE_COLS[n + 3] = x, sideTop(x), sideBottom(x)
    SIDE_COLS[n + 4], SIDE_COLS[n + 5], SIDE_COLS[n + 6] = x1, sideTop(x1), sideBottom(x1)
    x = x1
  end
  for i = 1, #SIDE_TOP do SIDE_OUT[i] = SIDE_TOP[i] end
  local bx = 152
  while bx > 6 do
    bx = math.max(6, bx - 2)
    SIDE_OUT[#SIDE_OUT + 1], SIDE_OUT[#SIDE_OUT + 2] = bx, sideBottom(bx)
  end
end

-- Ellipse polygon for the LMP canopy.
local CANOPY = {}
for i = 0, 19 do
  local a = i / 20 * math.pi * 2
  CANOPY[#CANOPY + 1], CANOPY[#CANOPY + 2] = 80 + 14 * math.cos(a), 92 + 26 * math.sin(a)
end
local SHADOW = {}
for i = 0, 19 do
  local a = i / 20 * math.pi * 2
  SHADOW[#SHADOW + 1], SHADOW[#SHADOW + 2] = 80 + 64 * math.cos(a), 172 + 10 * math.sin(a)
end

-- Thermal cells inside the GT body: {x0, y0, x1, y1, cx, cy, ...}
local HEAT_CELLS = {}
do
  local y = 12
  while y < 189 do
    local y1 = math.min(189, y + 6)
    local hw = halfWidthAt(GT_HALF, (y + y1) / 2)
    local x = 80 - hw
    while x < 80 + hw do
      local x1 = math.min(80 + hw, x + 6)
      local n = #HEAT_CELLS
      HEAT_CELLS[n + 1], HEAT_CELLS[n + 2], HEAT_CELLS[n + 3], HEAT_CELLS[n + 4] = x, y, x1, y1
      HEAT_CELLS[n + 5], HEAT_CELLS[n + 6] = (x + x1) / 2, (y + y1) / 2
      x = x1
    end
    y = y1
  end
end

-- ---------------------------------------------------------------- colours and state

local function C(r, g, b, a) return rgbm(r, g, b, a or 1) end
local TYRE = C(0.04, 0.047, 0.06)
local GLASS = C(0.047, 0.07, 0.11, 0.92)
local PART = C(0.29, 0.32, 0.37)
local MID = C(0.165, 0.19, 0.224)
local ROOF = C(0.125, 0.145, 0.176)
local SHADOWC = C(0.106, 0.122, 0.149)
local SEAM = C(0.02, 0.027, 0.04, 0.7)
local OUTLINE = C(0, 0, 0, 0.6)
local WHEEL_IDLE = C(0.27, 0.31, 0.35, 0.95)
local SUSP_IDLE = C(0.47, 0.5, 0.55, 0.9)
local HEAD = C(1, 0.95, 0.77)
local TAIL = C(1, 0.23, 0.23)
local WHITE = C(1, 1, 1)
local TILE_WHITE = C(0.957, 0.961, 0.969)
local INK = C(0.067, 0.078, 0.094)
local LABEL = C(0.9, 0.91, 0.93, 0.75)
local DARK = C(0.03, 0.04, 0.055, 0.76)
local PLATE = C(0.03, 0.04, 0.055, 0.6)
local CYAN = C(0.43, 0.84, 1, 0.85)
local CYAN_GLOW = C(0.43, 0.84, 1, 0.22)
local CYAN_DIM = C(0.43, 0.84, 1, 0.5)
local LIVERY = C(0.8, 0.82, 0.86, 0.95)
local CARBON = C(0.1, 0.114, 0.137)
local COCKPIT = C(0.02, 0.027, 0.04)
local AC_IDLE = C(0.84, 0.86, 0.89, 0.88)
local AC_CORE = C(0.03, 0.04, 0.055, 0.8)
local PICTO = C(0.227, 0.255, 0.3)
local SIDE_IDLE = C(0.227, 0.255, 0.3)
local REAR_IDLE = C(0.247, 0.278, 0.32)
local BUMPER = C(0.02, 0.027, 0.04, 0.55)
local PLATE_W = C(0.94, 0.95, 0.96, 0.9)
local BLUEPRINT = C(0.05, 0.165, 0.29, 0.92)
local BP_GRID = C(0.55, 0.75, 1, 0.12)
local BP_INK = C(0.86, 0.92, 1, 0.92)
local BP_DIM = C(0.86, 0.92, 1, 0.5)
local WIRE_IDLE = C(0.47, 0.78, 1, 0.5)
local WIRE_TEXT = C(0.63, 0.88, 1, 0.95)
local WIRE_BACK = C(0.02, 0.04, 0.07, 0.85)
local THERMAL_BACK = C(0.016, 0.02, 0.04, 0.82)
local THERMAL_LINE = C(0.55, 0.67, 1, 0.4)
local THERMAL_TEXT = C(0.78, 0.84, 1, 0.9)
local LIGHT_BAR = C(0.043, 0.05, 0.063)
local MUD = C(0.7, 0.15, 0.12)

local level = { 0, 0, 0, 0, 0, 0, 0, 0 }         -- 0..1 per zone key
local prevLevel = { 0, 0, 0, 0, 0, 0, 0, 0 }
local hitAt = { -100, -100, -100, -100, -100, -100, -100, -100 }
local zc = {}                                     -- per zone key colour object, refilled before each use
for i = 1, 8 do zc[i] = rgbm() end
local tmp = rgbm()
local enginePct = 100
local now = 0
local started = false

local function opa(c) return D.color(c, S.opacity) end

local function flashing(k)
  local dt = now - hitAt[k]
  return dt < 0.7 and math.floor(dt / 0.09) % 2 == 0
end

-- Colour of zone k with the style's idle colour; the returned object belongs to k.
local function zcol(k, idle)
  local c = zc[k]
  local l = level[k]
  if flashing(k) then c:set(WHITE)
  elseif l <= 0.01 then c:set(idle)
  else c:setLerp(S.colYellow, S.colRed, l) end
  c.mult = c.mult * S.opacity
  return c
end
local function hot(k) return level[k] > 0.01 or flashing(k) end

local function engineTile()
  if enginePct < 50 then return S.colRed, WHITE end
  if enginePct < 95 then return S.colYellow, INK end
  return TILE_WHITE, INK
end

local pctStrings, motorStrings, engStrings, tagStrings = {}, {}, {}, {}
local function cached(cache, p, fmt)
  local str = cache[p]
  if not str then str = string.format(fmt, p); cache[p] = str end
  return str
end
local function pctText() return cached(pctStrings, enginePct, '%d') end
local function zonePct(k) return cached(tagStrings, math.floor(math.min(1, level[k]) * 100 + 0.5), '%d%%') end

-- Thermal palette 0 cold .. 1 white hot, written into tmp.
local HEAT = { 0, 0.118, 0.196, 0.55, 0.25, 0.47, 0.157, 0.63, 0.5, 0.9, 0.196, 0.196, 0.75, 1, 0.667, 0.157, 1, 1, 0.98, 0.86 }
local function heat(t)
  t = math.max(0, math.min(1, t))
  local i = 1
  while i < 4 and HEAT[(i + 1) * 4 - 3] < t do i = i + 1 end
  local a, b = i * 4 - 3, (i + 1) * 4 - 3
  local k = (t - HEAT[a]) / (HEAT[b] - HEAT[a])
  tmp.r = HEAT[a + 1] + (HEAT[b + 1] - HEAT[a + 1]) * k
  tmp.g = HEAT[a + 2] + (HEAT[b + 2] - HEAT[a + 2]) * k
  tmp.b = HEAT[a + 3] + (HEAT[b + 3] - HEAT[a + 3]) * k
  tmp.mult = S.opacity
  return tmp
end

-- ---------------------------------------------------------------- shared pieces

local function fillSlices(sl, color)
  for i = 1, #sl, 4 do
    local y0, h0, y1, h1 = sl[i], sl[i + 1], sl[i + 2], sl[i + 3]
    quadB(80 - h0, y0, 80 + h0, y0, 80 + h1, y1, 80 - h1, y1, color)
  end
end

local function fillSlicesClipped(sl, color, x1, y1, x2, y2)
  clipB(x1, y1, x2, y2)
  fillSlices(sl, color)
  ui.popClipRect()
end

-- Body split into zones: middle, then front, rear, left, right clipped from the same slices.
local function zones(sl, z, mid, part)
  fillSlices(sl, opa(mid))
  fillSlicesClipped(sl, zcol(FRONT, part), 0, 0, 160, z[1])
  fillSlicesClipped(sl, zcol(REAR, part), 0, z[2], 160, 200)
  fillSlicesClipped(sl, zcol(LEFT, part), 0, z[1], z[3], z[2])
  fillSlicesClipped(sl, zcol(RIGHT, part), z[4], z[1], 160, z[2])
end

local function seams(z, x0, x1)
  local c = opa(SEAM)
  lineB(x0, z[1], x1, z[1], c, 1.6)
  lineB(x0, z[2], x1, z[2], c, 1.6)
  lineB(z[3], z[1], z[3], z[2], c, 1.6)
  lineB(z[4], z[1], z[4], z[2], c, 1.6)
end

local function topWheel(i, x, y, w, h, idle)
  rectB(x - w / 2, y - h / 2, w, h, opa(TYRE), w * 0.35)
  rectB(x - w / 2 + 2.5, y - h / 2 + 2.5, w - 5, h - 5, zcol(4 + i, idle or WHEEL_IDLE), w * 0.22)
end

local function gtWheels(w, h)
  for i = 0, 3 do topWheel(i + 1, GT_WHEELS[i * 2 + 1], GT_WHEELS[i * 2 + 2], w, h) end
end

local function gtGlass()
  quadB(65, 64, 95, 64, 99, 84, 61, 84, opa(GLASS))
  rectB(62, 88, 36, 34, opa(ROOF), 6)
  quadB(61, 126, 99, 126, 96, 140, 64, 140, opa(GLASS))
end

local function engineText(x, y, size, withLabel)
  local tile = engineTile()
  textB(pctText(), x, y, size, opa(tile), 44, D.FONT_GEAR)
  if withLabel then textB('MOTOR', x, y + size * 0.95, 6.5, opa(LABEL), 44, D.FONT) end
end

local function engineTileBox(x, y, w, h, numSize, label)
  local tile, ink = engineTile()
  rectB(x, y, w, h, opa(tile), 7)
  textB(pctText(), x + w / 2, y + h * 0.42, numSize, opa(ink), w, D.FONT_GEAR)
  textB(label, x + w / 2, y + h * 0.78, 6, opa(ink), w, D.FONT)
end

-- ---------------------------------------------------------------- the twelve styles

local STYLES = {}

-- 1 GT from above
STYLES[1] = function ()
  gtWheels(13, 30)
  fillSlices(GT_SL, opa(SHADOWC))
  zones(GT_SL, GT_Z, MID, PART)
  seams(GT_Z, 36, 124)
  gtGlass()
  rectB(29, 77, 9, 5, zcol(LEFT, PART), 2)
  rectB(122, 77, 9, 5, zcol(RIGHT, PART), 2)
  quadB(50, 22, 64, 16, 63, 22, 49, 29, opa(HEAD))
  quadB(110, 22, 111, 29, 97, 22, 96, 16, opa(HEAD))
  rectB(50, 182, 18, 4, opa(TAIL), 2)
  rectB(92, 182, 18, 4, opa(TAIL), 2)
  strokeB(GT_OUT, opa(OUTLINE), 1.5)
  engineText(80, 101, 13, true)
end

-- 2 neon outline
STYLES[2] = function ()
  strokeB(GT_OUT, opa(CYAN_GLOW), 7)
  strokeB(GT_OUT, opa(CYAN), 2.6)
  local dim = opa(CYAN_DIM)
  strokeB(GT_WINDSCREEN, dim, 1.4)
  strokeB(GT_REAR_WINDOW, opa(CYAN_DIM), 1.4)
  for i = 0, 3 do
    local k = 5 + i
    rectOutlineB(GT_WHEELS[i * 2 + 1] - 5, GT_WHEELS[i * 2 + 2] - 13, 10, 26, hot(k) and zcol(k, CYAN) or opa(CYAN), 4, 2.2)
  end
  for k = FRONT, RIGHT do
    if hot(k) then
      if k == FRONT then clipB(0, 0, 160, GT_Z[1])
      elseif k == REAR then clipB(0, GT_Z[2], 160, 200)
      elseif k == LEFT then clipB(0, GT_Z[1], GT_Z[3], GT_Z[2])
      else clipB(GT_Z[4], GT_Z[1], 160, GT_Z[2]) end
      local c = zcol(k, CYAN)
      local m = c.mult
      c.mult = m * 0.3
      strokeB(GT_OUT, c, 9)
      c.mult = m
      strokeB(GT_OUT, c, 3.6)
      ui.popClipRect()
    end
  end
  local tile = engineTile()
  textB(pctText(), 80, 104, 15, opa(enginePct >= 95 and CYAN or tile), 44, D.FONT_GEAR)
  textB('MOTOR', 80, 118, 6.5, opa(CYAN_DIM), 44, D.FONT)
end

-- 3 both sides (side profile twice)
local function sideFill(color)
  for i = 1, #SIDE_COLS, 6 do
    quadB(SIDE_COLS[i], SIDE_COLS[i + 1], SIDE_COLS[i + 3], SIDE_COLS[i + 4], SIDE_COLS[i + 3], SIDE_COLS[i + 5], SIDE_COLS[i], SIDE_COLS[i + 2], color)
  end
end
local function sideCar(sideKey, frontWheel, rearWheel)
  sideFill(zcol(sideKey, PART))
  clipB(118, -10, 160, 60)
  sideFill(zcol(FRONT, PART))
  ui.popClipRect()
  clipB(0, -10, 40, 60)
  sideFill(zcol(REAR, PART))
  ui.popClipRect()
  local seam = opa(SEAM)
  lineB(40, sideTop(40), 40, 42, seam, 1.6)
  lineB(118, sideTop(118), 118, 42, seam, 1.6)
  lineB(80, 18, 80, 40, seam, 1.6)
  quadB(50, 17, 68, 7, 93, 7, 112, 17, opa(GLASS))
  rectB(79, 7, 3, 10, opa(SHADOWC), 0)
  strokeB(SIDE_OUT, opa(OUTLINE), 1.4)
  rectB(145, 25, 7, 4, opa(HEAD), 2)
  rectB(6, 26, 5, 5, opa(TAIL), 1.5)
  circleB(124, 42, 11.5, opa(TYRE))
  circleB(124, 42, 7, zcol(frontWheel, SUSP_IDLE))
  circleB(124, 42, 2.2, opa(TYRE))
  circleB(34, 42, 11.5, opa(TYRE))
  circleB(34, 42, 7, zcol(rearWheel, SUSP_IDLE))
  circleB(34, 42, 2.2, opa(TYRE))
end
STYLES[3] = function ()
  textB('LEVÝ BOK', 30, 12, 7.5, opa(LABEL), 60, D.FONT)
  setFrame(4, 20, false)
  sideCar(LEFT, 5, 7)
  setFrame(156, 94, true)
  sideCar(RIGHT, 6, 8)
  setFrame()
  textB('PRAVÝ BOK', 32, 86, 7.5, opa(LABEL), 60, D.FONT)
  rectB(14, 160, 132, 30, opa(DARK), 9)
  textB('MOTOR', 34, 175, 8, opa(LABEL), 40, D.FONT)
  local tile = engineTile()
  rectB(60, 172, 50, 6, opa(PLATE), 3)
  rectB(60, 172, 50 * enginePct / 100, 6, opa(tile), 3)
  textB(pctText(), 126, 175.5, 11, opa(tile), 26, D.FONT_GEAR)
end

-- 4 formula car
local ARMS = { 30, 46, 64, 52, 1, 130, 46, 96, 52, 2, 30, 152, 68, 148, 3, 130, 152, 92, 148, 4 }
STYLES[4] = function ()
  for i = 1, #ARMS, 5 do
    local c = zcol(4 + ARMS[i + 4], SUSP_IDLE)
    lineB(ARMS[i], ARMS[i + 1], ARMS[i + 2], ARMS[i + 3], c, 2.2)
    lineB(ARMS[i], ARMS[i + 1] + 8, ARMS[i + 2], ARMS[i + 3] + 6, c, 2.2)
  end
  topWheel(1, 30, 48, 20, 34)
  topWheel(2, 130, 48, 20, 34)
  topWheel(3, 30, 156, 24, 40)
  topWheel(4, 130, 156, 24, 40)
  quadB(22, 15, 80, 11, 80, 22, 25, 25, zcol(FRONT, LIVERY))
  quadB(80, 11, 138, 15, 135, 25, 80, 22, zcol(FRONT, LIVERY))
  rectB(16, 7, 6, 22, zcol(FRONT, LIVERY), 2)
  rectB(138, 7, 6, 22, zcol(FRONT, LIVERY), 2)
  polyB(SIDEPOD, zcol(RIGHT, LIVERY))
  polyB(SIDEPOD_L, zcol(LEFT, LIVERY))
  fillSlices(F1_SL, opa(CARBON))
  rectB(36, 178, 88, 10, zcol(REAR, LIVERY), 2)
  rectB(31, 171, 6, 23, zcol(REAR, LIVERY), 2)
  rectB(123, 171, 6, 23, zcol(REAR, LIVERY), 2)
  rectB(70, 72, 20, 24, opa(COCKPIT), 8)
  ui.pathArcTo(pa:set(X(80), Y(85)), 13 * sc, math.pi * 1.05, math.pi * 1.95, 16)
  ui.pathStroke(opa(LIVERY), false, 2.6 * sc)
  lineB(80, 72, 80, 64, opa(LIVERY), 2.6)
  engineTileBox(69, 106, 22, 40, 10, 'MOT')
end

-- 5 LMP prototype
STYLES[5] = function ()
  fillSlices(LMP_SL, opa(SHADOWC))
  zones(LMP_SL, LMP_Z, MID, PART)
  seams(LMP_Z, 40, 120)
  topWheel(1, 47, 50, 12, 26)
  topWheel(2, 113, 50, 12, 26)
  topWheel(3, 43, 146, 13, 30)
  topWheel(4, 117, 146, 13, 30)
  quadB(108, 14, 118, 22, 116, 27, 106, 19, opa(HEAD))
  quadB(52, 14, 54, 19, 44, 27, 42, 22, opa(HEAD))
  polyB(CANOPY, opa(GLASS))
  lineB(80, 142, 80, 180, opa(LIVERY), 2)
  rectB(24, 180, 112, 10, zcol(REAR, PART), 2)
  rectB(20, 174, 6, 22, zcol(REAR, PART), 2)
  rectB(134, 174, 6, 22, zcol(REAR, PART), 2)
  strokeB(LMP_OUT, opa(OUTLINE), 1.5)
  engineText(80, 128, 11, false)
end

-- 6 blueprint
local BP_LABELS = { 80, 7, 80, 194, 30, 105, 130, 105 }
STYLES[6] = function ()
  rectB(2, 2, 156, 196, opa(BLUEPRINT), 8)
  local grid = opa(BP_GRID)
  for x = 10, 150, 10 do lineB(x, 4, x, 196, grid, 0.6) end
  for y = 10, 190, 10 do lineB(4, y, 156, y, grid, 0.6) end
  for k = FRONT, RIGHT do
    if hot(k) then
      local x1, y1, x2, y2 = 0, GT_Z[1], GT_Z[3], GT_Z[2]
      if k == FRONT then x1, y1, x2, y2 = 0, 0, 160, GT_Z[1]
      elseif k == REAR then x1, y1, x2, y2 = 0, GT_Z[2], 160, 200
      elseif k == RIGHT then x1, y1, x2, y2 = GT_Z[4], GT_Z[1], 160, GT_Z[2] end
      clipB(x1, y1, x2, y2)
      local c = zcol(k, BP_INK)
      local m = c.mult
      c.mult = m * 0.22
      fillSlices(GT_SL, c)
      c.mult = m
      for i = 1, #GT_SL, 4 do                 -- hatching: a thin stripe across every slice
        local y0, h0 = GT_SL[i], GT_SL[i + 1]
        quadB(80 - h0, y0, 80 + h0, y0, 80 + h0, y0 + 1.4, 80 - h0, y0 + 1.4, c)
      end
      ui.popClipRect()
    end
  end
  for i = 0, 3 do
    local k = 5 + i
    rectOutlineB(GT_WHEELS[i * 2 + 1] - 5.5, GT_WHEELS[i * 2 + 2] - 14, 11, 28, hot(k) and zcol(k, BP_INK) or opa(BP_INK), 3, 1.2)
  end
  strokeB(GT_OUT, opa(BP_INK), 1.3)
  strokeB(GT_WINDSCREEN, opa(BP_DIM), 0.9)
  rectOutlineB(62, 88, 36, 34, opa(BP_DIM), 6, 0.9)
  strokeB(GT_REAR_WINDOW, opa(BP_DIM), 0.9)
  lineB(80, 4, 80, 60, opa(BP_DIM), 0.7)
  lineB(80, 142, 80, 196, opa(BP_DIM), 0.7)
  for k = FRONT, RIGHT do
    if level[k] > 0.01 then
      textB(zonePct(k), BP_LABELS[k * 2 - 1], BP_LABELS[k * 2], 8.5, zcol(k, BP_INK), 40, D.FONT_MONO)
    end
  end
  rectB(56, 96, 48, 18, opa(BLUEPRINT), 3)
  local tile = engineTile()
  textB(cached(engStrings, enginePct, 'ENG %d%%'), 80, 105, 8.5, opa(enginePct >= 95 and BP_INK or tile), 48, D.FONT_MONO)
end

-- 7 segments like AC
local function cornerColor(k, a, b, idle)
  local c = zc[k]
  if flashing(a) or flashing(b) then c:set(WHITE)
  else
    local l = math.max(level[a], level[b])
    if l <= 0.01 then c:set(idle) else c:setLerp(S.colYellow, S.colRed, l) end
  end
  c.mult = c.mult * S.opacity
  return c
end
STYLES[7] = function ()
  rectB(26, 20, 8, 28, zcol(5, SUSP_IDLE), 3)
  rectB(126, 20, 8, 28, zcol(6, SUSP_IDLE), 3)
  rectB(26, 152, 8, 28, zcol(7, SUSP_IDLE), 3)
  rectB(126, 152, 8, 28, zcol(8, SUSP_IDLE), 3)
  rectB(38, 14, 23, 40, cornerColor(FRONT, FRONT, LEFT, AC_IDLE), 12)
  rectB(64, 14, 29, 34, zcol(FRONT, AC_IDLE), 4)
  rectB(96, 14, 26, 40, cornerColor(REAR, FRONT, RIGHT, AC_IDLE), 12)
  rectB(38, 57, 20, 86, zcol(LEFT, AC_IDLE), 4)
  rectB(102, 57, 20, 86, zcol(RIGHT, AC_IDLE), 4)
  rectB(38, 146, 23, 40, cornerColor(5, REAR, LEFT, AC_IDLE), 12)
  rectB(64, 152, 29, 34, zcol(REAR, AC_IDLE), 4)
  rectB(96, 146, 26, 40, cornerColor(6, REAR, RIGHT, AC_IDLE), 12)
  rectB(61, 51, 38, 98, opa(AC_CORE), 8)
  engineTileBox(66, 82, 28, 36, 11, 'MOT')
end

-- 8 rally hatchback
STYLES[8] = function ()
  topWheel(1, 42, 64, 13, 28)
  topWheel(2, 118, 64, 13, 28)
  topWheel(3, 42, 138, 13, 28)
  topWheel(4, 118, 138, 13, 28)
  fillSlices(RALLY_SL, opa(SHADOWC))
  zones(RALLY_SL, RALLY_Z, MID, PART)
  seams(RALLY_Z, 44, 116)
  rectB(56, 33, 48, 10, opa(LIGHT_BAR), 4)
  for x = 62, 98, 12 do circleB(x, 38, 3.6, opa(HEAD)) end
  quadB(60, 70, 100, 70, 104, 86, 56, 86, opa(GLASS))
  rectB(58, 88, 44, 40, opa(ROOF), 5)
  rectB(74, 89, 12, 7, opa(LIGHT_BAR), 2)
  quadB(58, 130, 102, 130, 100, 140, 60, 140, opa(GLASS))
  rectB(34, 154, 10, 7, opa(MUD), 1.5)
  rectB(116, 154, 10, 7, opa(MUD), 1.5)
  rectB(50, 161, 60, 6, zcol(REAR, PART), 2)
  strokeB(RALLY_OUT, opa(OUTLINE), 1.5)
  circleB(80, 111, 12.5, opa(TILE_WHITE))
  local tile = engineTile()
  textB(pctText(), 80, 111.5, 9.5, opa(enginePct >= 95 and INK or tile), 22, D.FONT_GEAR)
  textB('MOTOR', 80, 180, 7, opa(LABEL), 40, D.FONT)
end

-- 9 chase camera (from behind)
local function topL(y) return 34 + (132 - y) / 102 * 20 end
local function topR(y) return 160 - topL(y) end
STYLES[9] = function ()
  polyB(SHADOW, opa(BUMPER))
  rectB(15, 138, 15, 34, opa(TYRE), 5)
  rectB(18, 141, 9, 28, zcol(7, WHEEL_IDLE), 3)
  rectB(130, 138, 15, 34, opa(TYRE), 5)
  rectB(133, 141, 9, 28, zcol(8, WHEEL_IDLE), 3)
  rectB(41, 40, 9, 20, opa(TYRE), 3)
  rectB(42.5, 42, 6, 16, zcol(5, WHEEL_IDLE), 2)
  rectB(110, 40, 9, 20, opa(TYRE), 3)
  rectB(111.5, 42, 6, 16, zcol(6, WHEEL_IDLE), 2)
  quadB(54, 30, 34, 132, 26, 166, 46, 40, zcol(LEFT, SIDE_IDLE))
  quadB(106, 30, 114, 40, 134, 166, 126, 132, zcol(RIGHT, SIDE_IDLE))
  quadB(topL(30), 30, topR(30), 30, topR(62), 62, topL(62), 62, zcol(FRONT, PART))
  quadB(topL(62), 62, topR(62), 62, topR(118), 118, topL(118), 118, opa(MID))
  quadB(topL(118), 118, topR(118), 118, topR(132), 132, topL(132), 132, zcol(REAR, PART))
  quadB(34, 132, 126, 132, 134, 166, 26, 166, zcol(REAR, REAR_IDLE))
  quadB(topL(64) + 6, 64, topR(64) - 6, 64, topR(80) - 5, 80, topL(80) + 5, 80, opa(GLASS))
  quadB(topL(80) + 5, 80, topR(80) - 5, 80, topR(104) - 4, 104, topL(104) + 4, 104, opa(ROOF))
  quadB(topL(104) + 4, 104, topR(104) - 4, 104, topR(116) - 3, 116, topL(116) + 3, 116, opa(GLASS))
  rectB(36, 138, 24, 7, opa(TAIL), 2)
  rectB(100, 138, 24, 7, opa(TAIL), 2)
  rectB(66, 146, 28, 10, opa(PLATE_W), 2)
  rectB(30, 158, 100, 8, opa(BUMPER), 3)
  strokeB(CHASE_OUT, opa(OUTLINE), 1.2)
  engineText(80, 92, 9.5, false)
  textB(cached(motorStrings, enginePct, 'MOTOR %d %%'), 80, 190, 7.5, opa(LABEL), 80, D.FONT)
end

-- 10 pictogram
STYLES[10] = function ()
  rectB(27, 34, 14, 36, zcol(5, PICTO), 7)
  rectB(119, 34, 14, 36, zcol(6, PICTO), 7)
  rectB(27, 130, 14, 36, zcol(7, PICTO), 7)
  rectB(119, 130, 14, 36, zcol(8, PICTO), 7)
  rectB(46, 18, 68, 30, zcol(FRONT, PICTO), 15)
  rectB(46, 152, 68, 30, zcol(REAR, PICTO), 15)
  rectB(46, 52, 16, 96, zcol(LEFT, PICTO), 8)
  rectB(98, 52, 16, 96, zcol(RIGHT, PICTO), 8)
  local tile, ink = engineTile()
  rectB(66, 52, 28, 96, opa(tile), 10)
  textB(pctText(), 80, 96, 13, opa(ink), 28, D.FONT_GEAR)
  textB('MOT', 80, 112, 6.5, opa(ink), 28, D.FONT)
end

-- 11 wireframe
STYLES[11] = function ()
  local idle = opa(WIRE_IDLE)
  for i = 1, #WIRE_LINES, 6 do
    local k, w = WIRE_LINES[i + 4], WIRE_LINES[i + 5]
    if k > 0 and hot(k) then
      local c = zcol(k, WIRE_IDLE)
      local m = c.mult
      c.mult = m * 0.3
      lineB(WIRE_LINES[i], WIRE_LINES[i + 1], WIRE_LINES[i + 2], WIRE_LINES[i + 3], c, w + 3)
      c.mult = m
      lineB(WIRE_LINES[i], WIRE_LINES[i + 1], WIRE_LINES[i + 2], WIRE_LINES[i + 3], c, w + 0.5)
    else
      lineB(WIRE_LINES[i], WIRE_LINES[i + 1], WIRE_LINES[i + 2], WIRE_LINES[i + 3], idle, w)
      idle = opa(WIRE_IDLE)
    end
  end
  for i = 0, 3 do
    local k, x, y = 5 + i, GT_WHEELS[i * 2 + 1], GT_WHEELS[i * 2 + 2]
    local c = hot(k) and zcol(k, WIRE_IDLE) or opa(WIRE_IDLE)
    rectOutlineB(x - 5, y - 13, 10, 26, c, 0, 1.2)
    lineB(x - 5, y - 13, x + 5, y + 13, c, 1.2)
    lineB(x + 5, y - 13, x - 5, y + 13, c, 1.2)
  end
  rectB(63, 92, 34, 22, opa(WIRE_BACK), 5)
  local tile = engineTile()
  textB(pctText(), 80, 103.5, 11, opa(enginePct >= 95 and WIRE_TEXT or tile), 30, D.FONT_GEAR)
end

-- 12 thermal camera
local BLOBS = { 80, 22, FRONT, 80, 182, REAR, 38, 105, LEFT, 122, 105, RIGHT }
STYLES[12] = function ()
  rectB(4, 4, 152, 192, opa(THERMAL_BACK), 10)
  for i = 0, 3 do
    local k = 5 + i
    local l = flashing(k) and 1 or level[k]
    rectB(GT_WHEELS[i * 2 + 1] - 6, GT_WHEELS[i * 2 + 2] - 14, 12, 28, heat(0.12 + l * 0.8), 4)
  end
  for i = 1, #HEAT_CELLS, 6 do
    local cx, cy = HEAT_CELLS[i + 4], HEAT_CELLS[i + 5]
    local t = 0.04
    for b = 1, #BLOBS, 3 do
      local k = BLOBS[b + 2]
      local l = flashing(k) and 1 or math.min(1, level[k])
      if l > 0.01 then
        local dx, dy = cx - BLOBS[b], cy - BLOBS[b + 1]
        local r = 24 + 46 * l
        local d2 = (dx * dx + dy * dy) / (r * r)
        if d2 < 1 then t = t + (1 - d2) * (0.35 + 0.65 * l) end
      end
    end
    rectB(HEAT_CELLS[i], HEAT_CELLS[i + 1], HEAT_CELLS[i + 2] - HEAT_CELLS[i], HEAT_CELLS[i + 3] - HEAT_CELLS[i + 1], heat(t), 0)
  end
  strokeB(GT_WINDSCREEN, opa(THERMAL_LINE), 1)
  strokeB(GT_REAR_WINDOW, opa(THERMAL_LINE), 1)
  strokeB(GT_OUT, opa(THERMAL_LINE), 1)
  local tile = engineTile()
  textB(pctText(), 80, 104, 13, opa(enginePct >= 95 and THERMAL_TEXT or tile), 34, D.FONT_GEAR)
  textB('MOTOR', 80, 117, 6.5, opa(THERMAL_LINE), 34, D.FONT)
end

-- ---------------------------------------------------------------- inputs

-- 0 = undamaged, 1 = at the configured full damage
local function bodyLevel(car, side)
  return math.max(0, math.min(1, car.damage[side] / math.max(0.001, S.damageFull)))
end

-- Tyre fields come from the official RGBControl app; still read under pcall once.
local wheelFieldsOk = nil
local function wheelLevel(car, i)
  if wheelFieldsOk == nil then
    wheelFieldsOk = pcall(function () return car.wheels[0].tyreWear + 0, car.wheels[0].isBlown end)
  end
  if not wheelFieldsOk then return 0 end
  local w = car.wheels[i]
  if w.isBlown then return 1 end
  return math.max(0, math.min(1, (w.tyreWear - 0.25) / 0.6))
end

-- AC's own damage displayer is toggled by a sim key command (same as the official Unbound app).
-- Retry at most once a second, so a toggle that has not applied yet is not undone by the next frame.
local nextHideAttempt = 0
local function hideOriginal()
  if not S.damageHideOriginal then return end
  local sim = ac.getSim()
  if not sim or not sim.damageDisplayerShown then return end
  local t = os.preciseClock()
  if t < nextHideAttempt then return end
  nextHideAttempt = t + 1
  ac.trySimKeyPressCommand('Hide Damage')
end

local M = {}

M.STYLE_NAMES = { 'GT shora', 'Neonový obrys', 'Oba boky', 'Formule', 'LMP prototyp', 'Výkres',
  'Segmenty jako v AC', 'Rallye hatchback', 'Pohled zezadu', 'Piktogram', 'Drátěný model', 'Termokamera' }

function M.wheelFieldsOk() return wheelFieldsOk end

function M.draw()
  hideOriginal()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  now = os.preciseClock()

  for side = 0, 3 do level[side + 1] = bodyLevel(car, side) end
  for i = 0, 3 do level[5 + i] = wheelLevel(car, i) end
  for k = 1, 8 do
    if not started then prevLevel[k] = level[k] end   -- damage already there when the window opens is no hit
    if level[k] > prevLevel[k] + 0.02 then hitAt[k] = now end
    if level[k] > prevLevel[k] + 0.02 or level[k] < prevLevel[k] then prevLevel[k] = level[k] end
  end
  started = true
  enginePct = math.max(0, math.min(100, math.floor(car.engineLifeLeft / 10 + 0.5)))

  local anyDamage = enginePct < 99
  for k = 1, 8 do if level[k] > 0.01 then anyDamage = true end end
  if S.damageAutoHide and not anyDamage then return end

  sc = math.min(w / BOX_W, h / BOX_H)
  ox, oy = (w - BOX_W * sc) / 2, (h - BOX_H * sc) / 2
  setFrame()
  ui.pushDWriteFont(D.FONT_GEAR)
  if S.damagePlate then D.rect(ox, oy, ox + BOX_W * sc, oy + BOX_H * sc, opa(PLATE), 10 * sc) end
  local style = STYLES[S.damageStyle] or STYLES[1]
  style()
  setFrame()
  ui.popDWriteFont()
end

return M
