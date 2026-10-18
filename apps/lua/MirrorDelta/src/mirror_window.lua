-- Mirror window: AC's rear view (ui.drawVirtualMirror, as CSP's own OBS view draws it) in a movable rectangle, with
-- car markers like a GT3 digital rear view mirror with radar:
-- - the nearest cars behind (S.mirrorTargets) get a marker (corner brackets, a frame or an arrow), sized by distance,
--   coloured by threat (palette setting: not closing in / closing in / close), the nearest one a time gap label;
-- - a car behind but outside the shown crop gets a small arrow at that edge;
-- - a car alongside lights a bar at that side of the frame, the lit part shows where it is (ahead, level, behind).
-- Positions use a perspective projection of the car's position relative to ours (look/side/up), the field of view
-- is a setting (S.mirrorFov), the camera height a constant. Cars are matched to the track: only cars whose track
-- position is really behind us (spline, sim.trackLengthM) count, so a car on a parallel straight is ignored.
-- Car fields as in the official apps: position, look, up, side, velocity, splinePosition (Radar, gamepad assist,
-- RallyCopilot), wheels[i].position (ghost) decides which side is left. No allocation per frame.

local config = require('src/config')
local D = require('src/draw')
local S = config.S

local MAX_CARS = 64
local ALONGSIDE_BACK = 6       -- m: a car this far behind or ahead of us and close to the side is "alongside"
local ALONGSIDE_SIDE = 6       -- m
local SIDE_LIMIT = 14          -- m: further to the side than this is not a car on our piece of track
local CAM_UP = 0.6             -- m: rear view camera above the car's origin (driver's eye height, roughly)
local CAR_HALF_W, CAR_TOP, CAR_BOTTOM = 1.0, 0.75, -0.35   -- m around another car's origin
local SMOOTH = 0.07            -- s: smoothing of marker positions (no jitter)

local p1, p2 = vec2(), vec2()
local WHITE = rgbm(1, 1, 1, 1)
local FRAME = rgbm(0.07, 0.08, 0.1, 0.9)
local NONE = rgbm(0.07, 0.08, 0.1, 0.55)
local TEXT = rgbm(0.85, 0.87, 0.9, 0.9)
-- strong colours that stand out on any picture: green (not closing in), orange (closing in), red (close)
local FAR = rgbm(0.15, 1, 0.4, 1)
local YELLOW = rgbm(1, 0.6, 0, 1)
local RED = rgbm(1, 0.1, 0.1, 1)
local SHADOW = rgbm(0, 0, 0, 0.65)
local LABEL_BG = rgbm(0.03, 0.03, 0.04, 0.85)
-- colour schemes (setting S.mirrorPalette): not closing in / closing in / close
local PALETTES = {
  { FAR, YELLOW, RED },
  { rgbm(1, 1, 1, 1), rgbm(1, 0.85, 0.1, 1), RED },
  { rgbm(0.2, 0.75, 1, 1), rgbm(1, 0.85, 0.1, 1), RED },
}
local COLORS = PALETTES[1]
local chosen, chosenList, skipped = {}, {}, {}
for i = 1, 64 do chosen[i], chosenList[i], skipped[i] = false, 0, false end


-- A full frame (setting style 2).
local function frame(x1, y1, x2, y2, t, color)
  D.rect(x1, y1, x2, y1 + t, color, 0)
  D.rect(x1, y2 - t, x2, y2, color, 0)
  D.rect(x1, y1, x1 + t, y2, color, 0)
  D.rect(x2 - t, y1, x2, y2, color, 0)
end
local tint = rgbm()

-- per car (index 1..MAX_CARS-1): smoothed screen box, visibility fade, threat
local sx, sy, sw, sh, vis, threat = {}, {}, {}, {}, {}, {}
local tx, ty, tw, th, candBack = {}, {}, {}, {}, {}     -- this frame's raw box and distance (1e9: not a candidate)
for i = 1, MAX_CARS do
  sx[i], sy[i], sw[i], sh[i], vis[i], threat[i] = 0, 0, 0, 0, 0, 1
  tx[i], ty[i], tw[i], th[i], candBack[i] = 0, 0, 0, 0, 1e9
end

-- True when car i's raw box overlaps the box of car j (a few px of margin).
local function overlaps(i, j, margin)
  return math.abs(tx[i] - tx[j]) < tw[i] + tw[j] + margin
    and ty[i] < ty[j] + th[j] + margin and ty[j] < ty[i] + th[i] + margin
end
local lastClock = nil
local gapStrings = {}

-- For tests: what was drawn last frame (screen x of each marker and its threat 1 white, 2 yellow, 3 red).
local M = { shown = 0, drawnW = {}, drawnY = {}, drawnX = {}, drawnThreat = {}, edgeLeft = false, edgeRight = false, sideLeft = nil, sideRight = nil }

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

-- Corner brackets around a box (like a radar target frame).
local function brackets(x1, y1, x2, y2, t, color)
  local lw, lh = math.max(t * 2, (x2 - x1) * 0.28), math.max(t * 2, (y2 - y1) * 0.32)
  D.rect(x1, y1, x1 + lw, y1 + t, color, 0)
  D.rect(x1, y1, x1 + t, y1 + lh, color, 0)
  D.rect(x2 - lw, y1, x2, y1 + t, color, 0)
  D.rect(x2 - t, y1, x2, y1 + lh, color, 0)
  D.rect(x1, y2 - t, x1 + lw, y2, color, 0)
  D.rect(x1, y2 - lh, x1 + t, y2, color, 0)
  D.rect(x2 - lw, y2 - t, x2, y2, color, 0)
  D.rect(x2 - t, y2 - lh, x2, y2, color, 0)
end

local function gapText(seconds)
  local key = math.min(99, math.floor(seconds * 10 + 0.5))
  local str = gapStrings[key]
  if not str then
    str = string.format('%.1f s', key / 10):gsub('%.', ',')
    gapStrings[key] = str
  end
  return str
end

-- Metres the other car is behind us along the track (negative: ahead), from spline positions.
local function trackGap(mySpline, other, length)
  local d = (mySpline - other.splinePosition) % 1
  if d > 0.5 then d = d - 1 end
  return d * length
end

-- ---------------------------------------------------------------- projection
-- AC's rear view camera sits at the car's mirror position (car.ini [GRAPHICS] MIRROR_POSITION, local), not at the
-- car's origin; without it the driver's eyes (car.driverEyesPosition) are close. Another car's box is the projection
-- of the 8 corners of its bounding box (car.aabbCenter / car.aabbSize, local, full size, as the official Radar uses
-- it) through its car.transform, so the marker follows the car's real outline, also when it is turned in a corner.
-- Every field is probed under pcall; without them the old estimate (origin + CAM_UP, fixed car size) is used.
local camLocal, camWorld, cornerL, cornerW = vec3(), vec3(), vec3(), vec3()
local camState, camSession = 0, -1             -- 0 not read yet, 1 camLocal is valid, -1 no camera position
local camSource = 'odhad'                      -- for Diagnostika / tests: where the camera position comes from
local boxState = 0                             -- 0 not probed, 1 bounding boxes work, -1 they do not
local SX = { -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5 }
local SY = { -0.5, -0.5, 0.5, 0.5, -0.5, -0.5, 0.5, 0.5 }
local SZ = { -0.5, -0.5, -0.5, -0.5, 0.5, 0.5, 0.5, 0.5 }
local bx1, bx2, by1, by2 = 0, 0, 0, 0           -- last projected box

local function vectorFromIni(v)
  if type(v) == 'string' then
    local x, y, z = v:match('^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)')
    return tonumber(x), tonumber(y), tonumber(z)
  elseif type(v) == 'table' then
    return tonumber(v[1]), tonumber(v[2]), tonumber(v[3])
  end
end

local function readMirrorPosition()
  local ini = ac.INIConfig.carData(0, 'car.ini')
  if not ini then return false end
  local x, y, z = vectorFromIni(ini:get('GRAPHICS', 'MIRROR_POSITION', nil))
  if not (x and y and z) then return false end
  camLocal:set(x, y, z)
  return true
end

local function readEyes(me)
  local e = me.driverEyesPosition
  if not e or (e.x == 0 and e.y == 0 and e.z == 0) then return false end
  camLocal:set(e.x, e.y, e.z)
  return true
end

local function loadCamera(me)
  camState, camSource = -1, 'odhad'
  local ok, found = pcall(readMirrorPosition)
  if ok and found then camState, camSource = 1, 'MIRROR_POSITION' else
    ok, found = pcall(readEyes, me)
    if ok and found then camState, camSource = 1, 'oči řidiče' end
  end
  if camState == 1 and not pcall(me.transform.transformPointTo, me.transform, camWorld, camLocal) then
    camState, camSource = -1, 'odhad'
  end
end

-- World position of the rear view camera into camWorld.
local function cameraPosition(me, sim)
  if camState == 0 or sim.currentSessionIndex ~= camSession then
    camSession = sim.currentSessionIndex
    loadCamera(me)
  end
  if camState == 1 then
    me.transform:transformPointTo(camWorld, camLocal)
  else
    local p, u = me.position, me.up
    camWorld:set(p.x + u.x * CAM_UP, p.y + u.y * CAM_UP, p.z + u.z * CAM_UP)
  end
end

local function probeBox(c)
  local cc, hs = c.aabbCenter, c.aabbSize
  if not cc or not hs or hs.x <= 0 or hs.z <= 0 then return false end
  c.transform:transformPointTo(cornerW, cornerL:set(cc.x, cc.y, cc.z))
  return true
end

-- Projects car c's bounding box into bx1..by2; false when it cannot (no fields, a corner beside or ahead of the camera).
local function projectBox(c, lk, sd, up, ls, cx, cy, fx, fy)
  if boxState == 0 then
    local ok, works = pcall(probeBox, c)
    boxState = (ok and works) and 1 or -1
  end
  if boxState ~= 1 then return false end
  local cc, hs, tr = c.aabbCenter, c.aabbSize, c.transform
  if not cc or not hs or not tr or hs.x <= 0 then return false end
  local x1, x2, y1, y2 = 1e9, -1e9, 1e9, -1e9
  for k = 1, 8 do
    tr:transformPointTo(cornerW, cornerL:set(cc.x + SX[k] * hs.x, cc.y + SY[k] * hs.y, cc.z + SZ[k] * hs.z))
    local rx, ry, rz = cornerW.x - camWorld.x, cornerW.y - camWorld.y, cornerW.z - camWorld.z
    local back = -(rx * lk.x + ry * lk.y + rz * lk.z)
    if back < 0.5 then return false end
    local x = cx - (rx * sd.x + ry * sd.y + rz * sd.z) * ls / back * fx
    local y = cy - (rx * up.x + ry * up.y + rz * up.z) / back * fy
    if x < x1 then x1 = x end
    if x > x2 then x2 = x end
    if y < y1 then y1 = y end
    if y > y2 then y2 = y end
  end
  bx1, bx2, by1, by2 = x1, x2, y1, y2
  return true
end

local function markers(me, ox, oy, mw, mh, dx, dw, sc, a)
  local sim = ac.getSim()
  local now = os.preciseClock()
  local dt = lastClock and math.min(0.2, math.max(0, now - lastClock)) or 0
  lastClock = now
  local k = dt > 0 and (1 - math.exp(-dt / SMOOTH)) or 1
  local n = math.min(MAX_CARS, sim.carsCount)
  local mp, lk, sd, up, mv = me.position, me.look, me.side, me.up, me.velocity
  local ls = leftSign(me)
  local length = sim.trackLengthM or 0
  local mySpline = me.splinePosition
  local mySpeed = math.max(5, me.speedKmh / 3.6)
  local tanH = math.tan(math.rad(math.max(10, S.mirrorFov) / 2))
  local tanV = tanH / 4                          -- the rear view is 4:1 with square pixels
  local cx, cy = dx + dw / 2, oy + mh / 2        -- centre of the whole rear view
  cameraPosition(me, sim)
  -- camera relative to our origin (for the fallback estimate): forward, to the left, up
  local crx, cry, crz = camWorld.x - mp.x, camWorld.y - mp.y, camWorld.z - mp.z
  local camFwd = crx * lk.x + cry * lk.y + crz * lk.z
  local camLat = (crx * sd.x + cry * sd.y + crz * sd.z) * ls
  local camHgt = crx * up.x + cry * up.y + crz * up.z
  local offX, offY = S.mirrorOffsetX * sc, S.mirrorOffsetY * sc   -- manual calibration (px at 400x150)
  local fx, fy = dw / 2 / tanH, dw / 8 / tanV    -- pixels per unit of tangent
  local t = math.max(1, S.mirrorLineWidth * sc)
  COLORS = PALETTES[S.mirrorPalette] or PALETTES[1]
  local hasL, hasR, sideL, sideR = false, false, 0, 0   -- alongside: position -1 ahead .. +1 behind
  local edgeL, edgeR = 0, 0                      -- cars behind outside the crop (threat level)
  local nearest, nearestBack, second, secondBack = 0, 1e9, 0, 1e9
  local shown = 0
  for i = 1, n - 1 do
    local c = ac.getCar(i)
    candBack[i] = 1e9
    if c and not c.isInPit and c.isConnected ~= false then
      local p = c.position
      local rx, ry, rz = p.x - mp.x, p.y - mp.y, p.z - mp.z
      local fwd = rx * lk.x + ry * lk.y + rz * lk.z
      local lat = (rx * sd.x + ry * sd.y + rz * sd.z) * ls       -- + = to our left
      local hgt = rx * up.x + ry * up.y + rz * up.z
      local back = -fwd
      local onTrack = length <= 0 or math.abs(trackGap(mySpline, c, length) - back) < 25
      if onTrack and math.abs(lat) < SIDE_LIMIT then
        if math.abs(fwd) < ALONGSIDE_BACK and math.abs(lat) < ALONGSIDE_SIDE then
          local pos = math.max(-1, math.min(1, back / ALONGSIDE_BACK))
          if lat > 0 then
            sideL, hasL = hasL and math.min(sideL, pos) or pos, true
          else
            sideR, hasR = hasR and math.min(sideR, pos) or pos, true
          end
        elseif back > 2.5 and back < S.mirrorRange then
          local v = c.velocity
          local closing = (v.x - mv.x) * lk.x + (v.y - mv.y) * lk.y + (v.z - mv.z) * lk.z   -- m/s it gains on us
          local level = 1
          if back < 8 or (closing > 0.5 and back / closing < 1.5) then level = 3
          elseif closing > 1 then level = 2 end
          threat[i] = level
          -- perspective projection (mirror: a car behind on our left is on the left of the picture)
          local x, hw, yTop, yBot
          if projectBox(c, lk, sd, up, ls, cx, cy, fx, fy) then
            x, hw, yTop, yBot = (bx1 + bx2) / 2, (bx2 - bx1) / 2, by1, by2
          else
            local cb = back + camFwd                 -- distance from the camera, not from our origin
            local cl = lat - camLat
            x = cx - (cl / cb) * fx
            hw = CAR_HALF_W / cb * fx
            yTop = cy - ((hgt + CAR_TOP - camHgt) / cb) * fy
            yBot = cy - ((hgt + CAR_BOTTOM - camHgt) / cb) * fy
          end
          x, yTop, yBot = x + offX, yTop + offY, yBot + offY
          if x + hw < ox or x - hw > ox + mw then
            if x < ox then edgeL = math.max(edgeL, level) else edgeR = math.max(edgeR, level) end
          else
            tx[i], ty[i], tw[i], th[i], candBack[i] = x, yTop, hw, yBot - yTop, back
            if back < nearestBack then
              second, secondBack, nearest, nearestBack = nearest, nearestBack, i, back
            elseif back < secondBack then
              second, secondBack = i, back
            end
          end
        end
      end
    end
  end
  -- only the nearest S.mirrorTargets cars get markers; the rest fade out
  -- nearest first; with S.mirrorHideOverlap a car whose marker would overlap a nearer one is skipped
  for i = 1, n - 1 do chosen[i], skipped[i] = false, false end
  local picked, want = 0, math.max(1, math.min(6, math.floor(S.mirrorTargets)))
  local margin = 2 * sc
  while picked < want do
    local best, bestBack = 0, 1e9
    for i = 1, n - 1 do
      if not chosen[i] and not skipped[i] and candBack[i] < bestBack then best, bestBack = i, candBack[i] end
    end
    if best == 0 then break end
    local hidden = false
    if S.mirrorHideOverlap then
      for m = 1, picked do
        if overlaps(best, chosenList[m], margin) then hidden = true; break end
      end
    end
    if hidden then
      skipped[best] = true
    else
      chosen[best] = true
      picked = picked + 1
      chosenList[picked] = best
    end
  end
  local fade = dt > 0 and (1 - math.exp(-dt / 0.15)) or 1
  for i = 1, n - 1 do
    local target = chosen[i] and 1 or 0
    if target == 1 then
      if vis[i] <= 0.01 then sx[i], sy[i], sw[i], sh[i] = tx[i], ty[i], tw[i], th[i] end
      sx[i] = sx[i] + (tx[i] - sx[i]) * k
      sy[i] = sy[i] + (ty[i] - sy[i]) * k
      sw[i] = sw[i] + (tw[i] - sw[i]) * k
      sh[i] = sh[i] + (th[i] - sh[i]) * k
    end
    vis[i] = vis[i] + (target - vis[i]) * fade
    if target == 0 and vis[i] < 0.02 then vis[i] = 0 end
  end

  -- brackets, far ones first so near ones stay on top
  for pass = 1, 2 do
    for i = 1, n - 1 do
      if vis[i] > 0.02 and ((pass == 1) == (sw[i] < 14 * sc)) then
        local hw = math.max(5 * sc, sw[i])
        local x1, x2 = sx[i] - hw, sx[i] + hw
        local y1, y2 = sy[i], sy[i] + math.max(6 * sc, sh[i])
        -- a light fill, a dark outline for contrast, then the coloured marker (style setting)
        local base = COLORS[threat[i]]
        local style = S.mirrorMarkerStyle
        if S.mirrorFill and style ~= 3 then
          tint:set(base)
          tint.mult = 0.16 * a * vis[i]
          D.rect(x1, y1, x2, y2, tint, 2 * sc)
        end
        if style == 2 then
          frame(x1 - 1, y1 - 1, x2 + 1, y2 + 1, t + 2, col(SHADOW, a * vis[i]))
          frame(x1, y1, x2, y2, t, col(base, a * vis[i]))
        elseif style == 3 then
          local s = math.max(6 * sc, math.min(14 * sc, hw * 0.45))
          local ty = math.max(oy + s * 1.3, y1 - 2 * sc)
          triangle(sx[i] - s - 1, ty - s * 1.25 - 1, sx[i] + s + 1, ty - s * 1.25 - 1, sx[i], ty + 1, col(SHADOW, a * vis[i]))
          triangle(sx[i] - s, ty - s * 1.25, sx[i] + s, ty - s * 1.25, sx[i], ty, col(base, a * vis[i]))
        else
          brackets(x1 - 1, y1 - 1, x2 + 1, y2 + 1, t + 2, col(SHADOW, a * vis[i]))
          brackets(x1, y1, x2, y2, t, col(base, a * vis[i]))
        end
        if threat[i] == 3 and style ~= 3 then   -- red: a chevron above, pointing at the car
          local s = math.max(5 * sc, math.min(10 * sc, hw * 0.25))
          local ty = math.max(oy + s * 1.2, y1 - s * 0.4)
          triangle(sx[i] - s, ty - s * 1.1, sx[i] + s, ty - s * 1.1, sx[i], ty, col(COLORS[3], a * vis[i]))
        end
        shown = shown + 1
        M.drawnX[shown], M.drawnThreat[shown], M.drawnW[shown], M.drawnY[shown] = sx[i], threat[i], sw[i], sy[i]
      end
    end
  end
  for j = shown + 1, #M.drawnX do M.drawnX[j], M.drawnThreat[j], M.drawnW[j], M.drawnY[j] = nil, nil, nil, nil end

  -- time gap of the nearest car under its brackets
  if S.mirrorGapLabel and nearest > 0 and vis[nearest] > 0.5 then
    local str = gapText(nearestBack / mySpeed)
    local lx, ly = sx[nearest], sy[nearest] + math.max(6 * sc, sh[nearest]) + 3 * sc
    if ly + 15 * sc > oy + mh then                                     -- no room under the car: above it (and its chevron)
      ly = sy[nearest] - (threat[nearest] == 3 and 32 or 18) * sc
    end
    lx = math.max(ox + 20 * sc, math.min(ox + mw - 20 * sc, lx))
    ly = math.max(oy, math.min(oy + mh - 15 * sc, ly))
    ui.pushDWriteFont(D.FONT)
    D.rect(lx - 20 * sc, ly, lx + 20 * sc, ly + 15 * sc, col(LABEL_BG, a), 3 * sc)
    D.text(str, 12 * sc, lx - 20 * sc, ly, 40 * sc, 15 * sc, D.ALIGN_CENTER, col(COLORS[threat[nearest]], a))
    ui.popDWriteFont()
  end

  -- cars behind outside the crop: an arrow at that edge
  local s = 7 * sc
  if edgeL > 0 then triangle(ox + 3 * sc, cy, ox + 3 * sc + s * 1.3, cy - s, ox + 3 * sc + s * 1.3, cy + s, col(COLORS[edgeL], a)) end
  if edgeR > 0 then
    local x = ox + mw - 3 * sc
    triangle(x, cy, x - s * 1.3, cy + s, x - s * 1.3, cy - s, col(COLORS[edgeR], a))
  end
  M.edgeLeft, M.edgeRight = edgeL > 0, edgeR > 0

  -- alongside: a red bar along that side; its bright part shows where the car is (top = ahead, bottom = behind)
  if S.mirrorSideArrows then
    local bw = 5 * sc
    if hasL then
      D.rect(ox, oy, ox + bw, oy + mh, col(RED, a * 0.35), 0)
      local yc = oy + mh * (0.5 + 0.4 * sideL)
      D.rect(ox, yc - mh * 0.18, ox + bw, yc + mh * 0.18, col(RED, a), 0)
      triangle(ox + bw + 2 * sc, yc, ox + bw + 2 * sc + 9 * sc, yc - 8 * sc, ox + bw + 2 * sc + 9 * sc, yc + 8 * sc, col(RED, a))
    end
    if hasR then
      local x = ox + mw
      D.rect(x - bw, oy, x, oy + mh, col(RED, a * 0.35), 0)
      local yc = oy + mh * (0.5 + 0.4 * sideR)
      D.rect(x - bw, yc - mh * 0.18, x, yc + mh * 0.18, col(RED, a), 0)
      triangle(x - bw - 2 * sc, yc, x - bw - 2 * sc - 9 * sc, yc + 8 * sc, x - bw - 2 * sc - 9 * sc, yc - 8 * sc, col(RED, a))
    end
  end
  M.sideLeft, M.sideRight = hasL and sideL or nil, hasR and sideR or nil
  M.shown = shown
  M.camSource = camSource
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
