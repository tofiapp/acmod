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

-- The mirror texture is HDR (before AC's post-processing): drawn as it is, it is dark and greenish. Four ways to turn it
-- into a normal picture, switched by clicking the window (hovering shows the version and the active one):
-- 1 gamma: ui.drawVirtualMirror into a float canvas, then a shader with exposure and the HDR -> LDR conversion from
--   the CSP SDK example for virtual mirrors (pow(hdr, 0.4545), ac_wfx_impl.lua);
-- 2 YEBIS: a canvas with render.AntialiasingMode.SimplifiedYEBIS and exposure 30, as CSP's OBS "Virtual mirror" view;
-- 3 UI tonemapping: ui.beginTonemapping / setShadingOffset / endTonemapping, as CSP's display.mirror();
-- 4 raw: ui.drawVirtualMirror as it is.
local MODES = 4
local MODE_NAMES = { 'gamma', 'YEBIS', 'tonemapping UI', 'bez úprav' }
local LABELS = {}
local CANVAS_W, CANVAS_H = 1024, 256
local cp1, cp2 = vec2(0, 0), vec2(CANVAS_W, CANVAS_H)
local uv1, uv2 = vec2(), vec2()
local canvases, failed = {}, {}
local canvasOk = false
local function fillCanvas()
  canvasOk = ui.drawVirtualMirror(cp1, cp2, WHITE)
end

local function getCanvas(mode)
  if canvases[mode] or failed[mode] then return canvases[mode] end
  local ok, result = pcall(function ()
    local aa = mode == 2 and render.AntialiasingMode.SimplifiedYEBIS or render.AntialiasingMode.None
    local c = ui.ExtraCanvas(vec2(CANVAS_W, CANVAS_H), 1, aa, render.TextureFormat.R16G16B16A16.Float)
    if mode == 2 then c:setExposure(30) end
    return c
  end)
  if ok and result then canvases[mode] = result else failed[mode] = tostring(result) end
  return canvases[mode]
end

local SHADER = {
  async = true,
  p1 = vec2(), p2 = vec2(), uv1 = vec2(), uv2 = vec2(),
  textures = { txMirror = false },
  values = { gExposure = 1, gAlpha = 1 },
  shader = [[
    float4 main(PS_IN pin) {
      float4 c = txMirror.SampleLevel(samLinearClamp, pin.Tex, 0);
      return float4(pow(saturate(c.rgb * gExposure), 0.4545), gAlpha);
    }
  ]],
}

local hasTonemapping = type(ui.beginTonemapping) == 'function' and type(ui.endTonemapping) == 'function'
  and type(ui.setShadingOffset) == 'function' and type(ui.resetShadingOffset) == 'function'

-- Draws the picture; returns false when AC has no rear view right now.
local function drawPicture(mode, ox, oy, mw, mh, fw, fh, dx, dw, a)
  uv1:set(0.5 - fw / 2, 0.5 - fh / 2)
  uv2:set(0.5 + fw / 2, 0.5 + fh / 2)
  local c = (mode == 1 or mode == 2) and getCanvas(mode) or nil
  if c then
    if mode == 2 then c:setExposure(30 * S.mirrorBrightness) end
    c:clear()
    c:update(fillCanvas)
    if not canvasOk then return false end
    if mode == 1 then
      SHADER.p1:set(ox, oy)
      SHADER.p2:set(ox + mw, oy + mh)
      SHADER.uv1:set(uv1.x, uv1.y)
      SHADER.uv2:set(uv2.x, uv2.y)
      SHADER.textures.txMirror = c
      SHADER.values.gExposure = S.mirrorBrightness
      SHADER.values.gAlpha = a
      ui.renderShader(SHADER)
    else
      ui.drawImage(c, p1:set(ox, oy), p2:set(ox + mw, oy + mh), col(WHITE, a), uv1, uv2)
    end
    return true
  end
  -- modes 3 and 4 (and 1, 2 without a canvas): the virtual mirror itself, 4:1, cropped by a clip rect
  local dh = dw / 4
  ui.pushClipRect(p1:set(ox, oy), p2:set(ox + mw, oy + mh), true)
  local tone = mode == 3 and hasTonemapping
  if tone then
    ui.beginTonemapping()
    ui.setShadingOffset(1, 0, 1, 1)
  end
  local ok = ui.drawVirtualMirror(p1:set(dx, oy + (mh - dh) / 2), p2:set(dx + dw, oy + (mh + dh) / 2), col(WHITE, a))
  if tone then
    ui.resetShadingOffset()
    ui.endTonemapping(0, 0, true)
  end
  ui.popClipRect()
  return ok
end

local function modeLabel(mode)
  local key = mode * 10 + ((failed[mode] or (mode == 3 and not hasTonemapping)) and 1 or 0)
  local str = LABELS[key]
  if not str then
    str = string.format('MirrorDelta %s · obraz %d/%d: %s%s · klik = další', config.VERSION, mode, MODES,
      MODE_NAMES[mode], key % 10 == 1 and ' (v tomto CSP nejde)' or '')
    LABELS[key] = str
  end
  return str
end

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

  local hovered = ui.windowHovered()
  if hovered and ui.mouseClicked() then config.set('mirrorMode', S.mirrorMode % MODES + 1) end
  local mode = math.max(1, math.min(MODES, math.floor(S.mirrorMode)))

  -- AC's rear view is 4:1. The window shows a part of it in the window's own proportions (never stretched):
  -- a window narrower than 4:1 shows the middle of the width, a wider one the middle of the height. Zoom crops more.
  local zoom = math.max(1, S.mirrorZoom)
  local aspect = mw / mh
  local fw = math.min(1, aspect / 4) / zoom      -- part of the width shown
  local fh = math.min(1, 4 / aspect) / zoom      -- part of the height shown
  local dw = mw / fw                             -- width the whole rear view has at this scale
  local dx = ox + (mw - dw) / 2

  local ok = drawPicture(mode, ox, oy, mw, mh, fw, fh, dx, dw, a)
  if not ok then
    D.rect(ox, oy, ox + mw, oy + mh, col(NONE, a), 4 * sc)
    ui.pushDWriteFont(D.FONT)
    D.text('Zpětné zrcátko teď AC nevykresluje', 14 * sc, ox, oy, mw, mh, D.ALIGN_CENTER, col(TEXT, a))
    ui.popDWriteFont()
  elseif S.mirrorMarkers then
    markers(me, ox, oy, mw, mh, dx, dw, sc, a)
  end
  if hovered then
    ui.pushDWriteFont(D.FONT)
    D.rect(ox, oy + mh - 18 * sc, ox + mw, oy + mh, col(NONE, a), 0)
    D.text(modeLabel(mode), 11 * sc, ox + 6 * sc, oy + mh - 18 * sc, mw - 12 * sc, 18 * sc, D.ALIGN_START, col(TEXT, a))
    ui.popDWriteFont()
  end
end

return M
