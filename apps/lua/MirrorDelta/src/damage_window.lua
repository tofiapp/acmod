-- Damage window: the car outline from above, split by gaps into front, sides and rear (car.damage[0..3]),
-- tyres outside the outline (tyre wear / blown tyre), a coil-over per wheel inside the outline (suspension
-- damage, read under pcall), engine life in the middle (car.engineLifeLeft, 1000 = healthy).
-- Undamaged parts are light grey, damage goes from yellow to red, a part that was just hit flashes white.
-- Everything is drawn in a 160 x 200 box scaled into the window; geometry is built once at load.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local BOX_W, BOX_H = 160, 200
local FRONT, REAR, LEFT, RIGHT = 1, 2, 3, 4
-- zone keys: 1..4 body, 5..8 tyres (FL, FR, RL, RR), 9..12 suspension (FL, FR, RL, RR)
local KEYS = 12

-- ---------------------------------------------------------------- transform and primitives

local ox, oy, sc = 0, 0, 1
local pa, pb = vec2(), vec2()
local function X(v) return ox + v * sc end
local function Y(v) return oy + v * sc end

local function rectB(x, y, w, h, color, r)
  D.rect(X(x), Y(y), X(x + w), Y(y + h), color, (r or 0) * sc)
end

local function lineB(x1, y1, x2, y2, color, width)
  ui.drawLine(pa:set(X(x1), Y(y1)), pb:set(X(x2), Y(y2)), color, width * sc)
end

local function strokeB(pts, color, width, closed)
  for i = 1, #pts, 2 do ui.pathLineTo(pa:set(X(pts[i]), Y(pts[i + 1]))) end
  ui.pathStroke(color, closed ~= false, width * sc)
end

-- Rounded rectangle outline from arcs and a path stroke.
local function roundOutlineB(x, y, w, h, r, color, width)
  local h2 = math.pi / 2
  ui.pathArcTo(pa:set(X(x + r), Y(y + r)), r * sc, math.pi, math.pi + h2, 4)
  ui.pathArcTo(pa:set(X(x + w - r), Y(y + r)), r * sc, -h2, 0, 4)
  ui.pathArcTo(pa:set(X(x + w - r), Y(y + h - r)), r * sc, 0, h2, 4)
  ui.pathArcTo(pa:set(X(x + r), Y(y + h - r)), r * sc, h2, math.pi, 4)
  ui.pathStroke(color, true, width * sc)
end

local function clipB(x1, y1, x2, y2)
  ui.pushClipRect(pa:set(X(x1), Y(y1)), pb:set(X(x2), Y(y2)), true)
end

local function textB(str, cx, cy, size, color, w, font)
  ui.pushDWriteFont(font)
  D.text(str, size * sc, X(cx) - w / 2 * sc, Y(cy) - size * 0.75 * sc, w * sc, size * 1.5 * sc, D.ALIGN_CENTER, color)
  ui.popDWriteFont()
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

-- GT outline from above (nose up): right half from the front centre to the rear centre, then mirrored.
local OUTLINE = {}
do
  local half = { 80, 12 }
  local segs = {
    { 98, 12, 113, 15, 118, 28 }, { 121, 36, 125, 44, 125, 58 }, { 125, 66, 121, 72, 120, 80 },
    { 119, 96, 119, 116, 121, 132 }, { 124, 140, 127, 150, 126, 164 }, { 125, 180, 110, 189, 80, 189 } }
  for _, sg in ipairs(segs) do
    addBezier(half, half[#half - 1], half[#half], sg[1], sg[2], sg[3], sg[4], sg[5], sg[6], 16)
  end
  for i = 1, #half do OUTLINE[i] = half[i] end
  for i = #half - 3, 3, -2 do OUTLINE[#OUTLINE + 1], OUTLINE[#OUTLINE + 2] = 160 - half[i], half[i + 1] end
end

-- Clip rectangles of the four body parts, separated by gaps.
local GAP = 6
local CLIPS = { 0, 0, 160, 52 - GAP, 0, 158 + GAP, 160, 200, 0, 52 + GAP, 62 - GAP, 158 - GAP,
  98 + GAP, 52 + GAP, 160, 158 - GAP }

-- Tyres outside the outline, coil-overs inside it.
local TYRES = { 19, 58, 141, 58, 18, 152, 142, 152 }
local SPRING_X = { 44, 116, 44, 116 }
local SIDE = { 1, -1, 1, -1 }
local SPRINGS = {}
for i = 1, 4 do
  local x0, y, side = SPRING_X[i], TYRES[i * 2], SIDE[i]
  local x1, n = x0 + side * 18, 6
  local pts = { x0, y }
  for k = 0, n - 1 do
    pts[#pts + 1], pts[#pts + 2] = x0 + (x1 - x0) / n * (k + 0.5), y + (k % 2 == 0 and -4 or 4)
  end
  pts[#pts + 1], pts[#pts + 2] = x1, y
  SPRINGS[i] = pts
end

-- ---------------------------------------------------------------- colours and state

local IDLE = rgbm(0.91, 0.93, 0.95, 0.6)
local TYRE = rgbm(0.04, 0.047, 0.06, 0.85)
local WHITE = rgbm(1, 1, 1, 1)
local TILE_WHITE = rgbm(0.93, 0.94, 0.96, 1)
local LABEL = rgbm(0.91, 0.93, 0.95, 0.75)

local level, prevLevel, hitAt = {}, {}, {}
for k = 1, KEYS do level[k], prevLevel[k], hitAt[k] = 0, 0, -100 end
local zc = {}
for k = 1, KEYS do zc[k] = rgbm() end
local enginePct, now, started, lastHit = 100, 0, false, -1000

local function opa(c) return D.color(c, S.opacity) end

local function flashing(k)
  local dt = now - hitAt[k]
  return dt < 0.7 and math.floor(dt / 0.09) % 2 == 0
end
local function hot(k) return level[k] > 0.01 or flashing(k) end

-- Colour of a damaged zone (its own colour object, use right away).
local function zcol(k)
  local c = zc[k]
  if flashing(k) then c:set(WHITE) else c:setLerp(S.colYellow, S.colRed, math.min(1, level[k])) end
  c.mult = c.mult * S.opacity
  return c
end

local pctStrings = {}
local function pctText()
  local str = pctStrings[enginePct]
  if not str then str = tostring(enginePct); pctStrings[enginePct] = str end
  return str
end

-- ---------------------------------------------------------------- drawing

local function drawCar()
  for i = 1, 4 do
    local x, y = TYRES[i * 2 - 1], TYRES[i * 2]
    local tk, sk = 4 + i, 8 + i
    -- suspension: two mounts and the spring between them
    local x0, x1 = SPRING_X[i], SPRING_X[i] + SIDE[i] * 18
    local w = hot(sk) and 3 or 2
    local c = hot(sk) and zcol(sk) or opa(IDLE)
    lineB(x0, y - 6, x0, y + 6, c, w)
    lineB(x1, y - 6, x1, y + 6, c, w)
    strokeB(SPRINGS[i], c, w, false)
    -- tyre: dark when fine, coloured when worn or punctured
    if hot(tk) then
      rectB(x - 7, y - 16, 14, 32, zcol(tk), 5)
      roundOutlineB(x - 7, y - 16, 14, 32, 5, zcol(tk), 2)
    else
      rectB(x - 7, y - 16, 14, 32, opa(TYRE), 5)
      roundOutlineB(x - 7, y - 16, 14, 32, 5, opa(IDLE), 2)
    end
  end
  for k = FRONT, RIGHT do
    local j = (k - 1) * 4
    clipB(CLIPS[j + 1], CLIPS[j + 2], CLIPS[j + 3], CLIPS[j + 4])
    if hot(k) then strokeB(OUTLINE, zcol(k), 7) else strokeB(OUTLINE, opa(IDLE), 4) end
    ui.popClipRect()
  end
  local tile = enginePct < 50 and S.colRed or enginePct < 95 and S.colYellow or TILE_WHITE
  textB(pctText(), 80, 101, 22, opa(tile), 64, D.FONT_GEAR)
  textB('MOTOR', 80, 122, 9, opa(LABEL), 50, D.FONT)
end

-- ---------------------------------------------------------------- inputs

local function bodyLevel(car, side)
  return math.max(0, math.min(1, car.damage[side] / math.max(0.001, S.damageFull)))
end

-- Tyre fields come from the official RGBControl app; still read under pcall once.
local tyreFieldsOk = nil
local function tyreLevel(car, i)
  if tyreFieldsOk == nil then
    tyreFieldsOk = pcall(function () return car.wheels[0].tyreWear + 0, car.wheels[0].isBlown end)
  end
  if not tyreFieldsOk then return 0 end
  local w = car.wheels[i]
  if w.isBlown then return 1 end
  return math.max(0, math.min(1, (w.tyreWear - 0.25) / 0.6))
end

-- Suspension damage is not used by any official app, so it is read under pcall; without it the springs stay grey.
local suspFieldOk = nil
local function suspensionLevel(car, i)
  if suspFieldOk == nil then
    suspFieldOk = pcall(function () return car.wheels[0].suspensionDamage + 0 end)
  end
  if not suspFieldOk then return 0 end
  return math.max(0, math.min(1, car.wheels[i].suspensionDamage))
end

-- AC's own damage displayer is toggled by a sim key command (same as the official Unbound app).
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

-- Reads the car every frame (also while the window is hidden by the "after a hit" mode).
local function readCar(car)
  for side = 0, 3 do level[side + 1] = bodyLevel(car, side) end
  for i = 0, 3 do level[5 + i], level[9 + i] = tyreLevel(car, i), suspensionLevel(car, i) end
  local engineNow = math.max(0, math.min(100, math.floor(car.engineLifeLeft / 10 + 0.5)))
  if started and engineNow < enginePct then lastHit = now end
  enginePct = engineNow
  for k = 1, KEYS do
    if not started then prevLevel[k] = level[k] end   -- damage already there when the window opens is no hit
    if level[k] > prevLevel[k] + 0.02 then hitAt[k], lastHit = now, now end
    if level[k] > prevLevel[k] + 0.02 or level[k] < prevLevel[k] then prevLevel[k] = level[k] end
  end
  started = true
end

local M = {}

function M.tyreFieldsOk() return tyreFieldsOk end
function M.suspensionFieldOk() return suspFieldOk end

function M.draw()
  hideOriginal()
  local car = ac.getCar(0)
  if not car then return end
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  now = os.preciseClock()
  readCar(car)

  -- 1: always, 2: while something is damaged, 3: for a few seconds after a hit (like AC). Hovering always shows it.
  if not ui.windowHovered() then
    if S.damageShow == 2 then
      local anyDamage = enginePct < 99
      for k = 1, KEYS do if level[k] > 0.01 then anyDamage = true end end
      if not anyDamage then return end
    elseif S.damageShow == 3 and now - lastHit > S.damageShowTime then
      return
    end
  end

  sc = math.min(w / BOX_W, h / BOX_H)
  ox, oy = (w - BOX_W * sc) / 2, (h - BOX_H * sc) / 2
  if S.damagePanel then D.panel(ox, oy, ox + BOX_W * sc, oy + BOX_H * sc, 10 * sc) end
  drawCar()
end

return M
