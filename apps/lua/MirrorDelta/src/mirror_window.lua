-- Mirror window: AC's rear view (ui.drawVirtualMirror, as CSP's own OBS view draws it) in a movable rectangle,
-- with car markers like a GT3 rear view camera: a triangle above every car behind (white, yellow when it closes
-- in, red when it is close), and a red arrow at the side of the frame when a car is alongside, out of the picture.
-- Car fields as in the official apps: position, look, up, side, velocity (Radar, gamepad assist), wheels[i].position
-- (ghost) decides which side is left. All maths on plain numbers, no allocation per frame.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local MAX_CARS = 64
local ALONGSIDE_BACK = 6       -- m: a car this far behind or ahead of us and close to the side is "alongside"
local ALONGSIDE_SIDE = 7       -- m

local p1, p2 = vec2(), vec2()
local WHITE = rgbm(1, 1, 1, 1)
local FRAME = rgbm(0.07, 0.08, 0.1, 0.9)
local NONE = rgbm(0.07, 0.08, 0.1, 0.55)
local TEXT = rgbm(0.85, 0.87, 0.9, 0.9)
local FAR = rgbm(0.96, 0.96, 0.97, 0.85)
local YELLOW = rgbm(1, 0.78, 0.15, 1)
local RED = rgbm(1, 0.25, 0.22, 1)
local tint = rgbm()

local M = { shown = 0 }   -- markers drawn last frame (tests, Diagnostika)

local function col(c, a)
  tint:set(c)
  tint.mult = c.mult * a
  return tint
end

local function triangle(x1, y1, x2, y2, x3, y3, color)
  ui.pathLineTo(p1:set(x1, y1))
  ui.pathLineTo(p1:set(x2, y2))
  ui.pathLineTo(p1:set(x3, y3))
  ui.pathFillConvex(color)
end

-- +1 when car.side points to the car's left (front left wheel minus front right wheel), else -1.
local function leftSign(car)
  local a, b, s = car.wheels[0].position, car.wheels[1].position, car.side
  local d = (a.x - b.x) * s.x + (a.y - b.y) * s.y + (a.z - b.z) * s.z
  return d >= 0 and 1 or -1
end

local function markers(me, ox, oy, mw, mh, dx, dw, sc, a)
  local sim = ac.getSim()
  local n = math.min(MAX_CARS, sim.carsCount)
  local mp, lk, sd, mv = me.position, me.look, me.side, me.velocity
  local ls = leftSign(me)
  local halfFov = math.rad(math.max(10, S.mirrorFov) / 2)
  local cx = dx + dw / 2          -- centre of the whole (wider) rear view
  local leftNear, rightNear = false, false
  local shown = 0
  for i = 1, n - 1 do
    local c = ac.getCar(i)
    if c and not c.isInPit and c.isConnected ~= false then
      local p = c.position
      local dx, dy, dz = p.x - mp.x, p.y - mp.y, p.z - mp.z
      local fwd = dx * lk.x + dy * lk.y + dz * lk.z
      local lat = (dx * sd.x + dy * sd.y + dz * sd.z) * ls       -- + = to our left
      local back = -fwd
      if math.abs(fwd) < ALONGSIDE_BACK and math.abs(lat) < ALONGSIDE_SIDE then
        if lat > 0 then leftNear = true else rightNear = true end
      elseif back > 2 and back < S.mirrorRange then
        local angle = math.atan(lat / back)
        local x0 = cx - angle / halfFov * dw / 2
        if math.abs(angle) < halfFov and x0 > ox + 6 * sc and x0 < ox + mw - 6 * sc then
          -- mirror: a car behind on our left is on the left of the picture
          local x = cx - angle / halfFov * dw / 2
          local v = c.velocity
          local closing = (v.x - mv.x) * lk.x + (v.y - mv.y) * lk.y + (v.z - mv.z) * lk.z   -- m/s it gains on us
          local color = FAR
          if back < 10 or (closing > 0.5 and back / closing < 1.2) then color = RED
          elseif closing > 1 and back < 45 then color = YELLOW end
          local k = 1 - back / S.mirrorRange
          local s = (8 + 10 * k) * sc
          local y = oy + mh * 0.12
          triangle(x - s, y, x + s, y, x, y + s * 1.2, col(color, a))
          shown = shown + 1
        end
      end
    end
  end
  if S.mirrorSideArrows then
    local s, y = 16 * sc, oy + mh / 2
    if leftNear then triangle(ox + 4 * sc, y, ox + 4 * sc + s * 1.2, y - s, ox + 4 * sc + s * 1.2, y + s, col(RED, a)) end
    if rightNear then
      local x = ox + mw - 4 * sc
      triangle(x, y, x - s * 1.2, y + s, x - s * 1.2, y - s, col(RED, a))
    end
  end
  M.shown = shown
end

-- The mirror texture is HDR. It is drawn the way CSP's own display.mirror() draws it (car_scriptable_display_utils):
-- inside ui.beginTonemapping() with ui.setShadingOffset(1, 0, 1, 1), closed by ui.endTonemapping(0, 0, true).
-- Without that the picture comes out dark and greenish. ui.drawVirtualMirror() keeps CSP's own piece mapping.
local hasTonemapping = type(ui.beginTonemapping) == 'function' and type(ui.endTonemapping) == 'function'
  and type(ui.setShadingOffset) == 'function' and type(ui.resetShadingOffset) == 'function'
M.tonemapping = hasTonemapping

function M.draw()
  local w, h = ui.windowWidth(), ui.windowHeight()
  if w <= 0 or h <= 0 then return end
  local me = ac.getCar(0)
  if not me then return end
  local sc = math.min(w / 400, h / 150)
  local b = math.max(1, 2 * sc)
  local ox, oy, mw, mh = b, b, w - 2 * b, h - 2 * b
  local a = S.opacity
  D.rect(0, 0, w, h, col(FRAME, a), 6 * sc)

  -- AC's rear view is 4:1 and is always drawn 4:1 (never stretched), big enough to cover the window, centred and
  -- clipped: a window narrower than 4:1 shows the middle of the width, a wider one the middle of the height.
  local dh = math.max(mh, mw / 4) * math.max(1, S.mirrorZoom)
  local dw = dh * 4
  local dx, dy = ox + (mw - dw) / 2, oy + (mh - dh) / 2
  ui.pushClipRect(p1:set(ox, oy), p2:set(ox + mw, oy + mh), true)
  if hasTonemapping then
    ui.beginTonemapping()
    ui.setShadingOffset(1, 0, 1, 1)
  end
  local k = math.min(1, S.mirrorBrightness)
  tint:set(WHITE)
  tint.r, tint.g, tint.b, tint.mult = k, k, k, a
  local ok = ui.drawVirtualMirror(p1:set(dx, dy), p2:set(dx + dw, dy + dh), tint)
  if hasTonemapping then
    ui.resetShadingOffset()
    ui.endTonemapping(0, 0, true)
  end
  ui.popClipRect()
  if not ok then
    D.rect(ox, oy, ox + mw, oy + mh, col(NONE, a), 4 * sc)
    ui.pushDWriteFont(D.FONT)
    D.text('Zpětné zrcátko teď AC nevykresluje', 14 * sc, ox, oy, mw, mh, D.ALIGN_CENTER, col(TEXT, a))
    ui.popDWriteFont()
    return
  end
  if S.mirrorMarkers then markers(me, ox, oy, mw, mh, dx, dw, sc, a) end
end

return M
