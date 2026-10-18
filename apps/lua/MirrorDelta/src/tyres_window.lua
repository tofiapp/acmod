-- Tyres window. The big number is always the core temperature.
-- Style 1: big coloured core numbers with a three-part bar for the tread
--          (inner / middle / outer zone) under each.
-- Style 2: big core number, tyre shape (tread zones on the edges, core in the middle)
--          and the three zone temperatures under the tyre.

local config = require('src/config')
local D = require('src/draw')
local carData = require('src/car_data')
local S = config.S

local PAD, COL_GAP, ROW_GAP, ITEM_GAP, PAIR_GAP = 6, 16, 12, 8, 22
local NUM_ROW_1, NUM_ROW_2 = 42, 38
local TYRE_W, TYRE_H = 46, 72

-- Colour stops relative to the optimum temperature, °C
local STOPS = { -30, -15, -6, 6, 13, 22 }
local COLD = rgbm(0.23, 0.51, 0.96, 1)
local COOL = rgbm(0.13, 0.76, 0.84, 1)
local DARK = rgbm(0.04, 0.047, 0.06, 1)
local GROOVE = rgbm(0, 0, 0, 0.4)
local BAR_BACK = rgbm(0, 0, 0, 0.75)

local tempColor = rgbm()
local core, zin, zmid, zout = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
local optLo, optHi = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }   -- optimal window per tyre, °C
local fieldsOk, optimumOk = nil, false
local degreeStrings, plainStrings = {}, {}

local function checkFields(car)
  fieldsOk = pcall(function ()
    local w = car.wheels[0]
    return w.tyreCoreTemperature + w.tyreInsideTemperature + w.tyreMiddleTemperature + w.tyreOutsideTemperature
  end)
  optimumOk = pcall(function ()
    return car.wheels[0].tyreOptimumTemperature + 0
  end)
  if not fieldsOk then ac.warn('MirrorDelta: tyre temperatures are not available in this CSP version') end
end

local function readTyres(car)
  for i = 1, 4 do
    local wheel = car.wheels[i - 1]
    core[i] = wheel.tyreCoreTemperature
    zin[i] = wheel.tyreInsideTemperature
    zmid[i] = wheel.tyreMiddleTemperature
    zout[i] = wheel.tyreOutsideTemperature
    -- optimal window: the car's tyre curve (tyres.ini), else CSP's optimum, else the manual value
    local lo, hi = S.tyreOptimum, S.tyreOptimum
    local axle = i <= 2 and 1 or 2
    if S.tyreOptimumAuto and carData.tyreLo[axle] > 0 then
      lo, hi = carData.tyreLo[axle], carData.tyreHi[axle]
    elseif S.tyreOptimumAuto and optimumOk then
      local v = wheel.tyreOptimumTemperature
      if v > 1 then lo, hi = v, v end
    end
    optLo[i], optHi[i] = lo, hi
  end
end

-- Zone temperature in screen order k = 1..3 (left to right). The inner edge faces the car centre.
local function zoneTemp(i, k)
  if k == 2 then return zmid[i] end
  local left = i == 1 or i == 3
  if (k == 1) == left then return zout[i] end
  return zin[i]
end

local function stopColor(k)
  if k == 1 then return COLD end
  if k == 2 then return COOL end
  if k <= 4 then return S.colGreen end
  if k == 5 then return S.colYellow end
  return S.colRed
end

-- Shared colour for a temperature of tyre i (distance from its optimal window); use it right away.
local function colorFor(temp, i)
  if not fieldsOk then return D.color(S.colNeutral, S.opacity) end
  local d = 0
  if temp < optLo[i] then d = temp - optLo[i] elseif temp > optHi[i] then d = temp - optHi[i] end
  if d <= STOPS[1] then
    tempColor:set(COLD)
  elseif d >= STOPS[6] then
    tempColor:set(S.colRed)
  else
    for k = 2, 6 do
      if d <= STOPS[k] then
        tempColor:setLerp(stopColor(k - 1), stopColor(k), (d - STOPS[k - 1]) / (STOPS[k] - STOPS[k - 1]))
        break
      end
    end
  end
  tempColor.mult = S.opacity
  return tempColor
end

local function degreeText(temp)
  if not fieldsOk then return '-' end
  local n = math.floor(temp + 0.5)
  local str = degreeStrings[n]
  if not str then
    str = tostring(n) .. '°'
    degreeStrings[n] = str
  end
  return str
end

local function plainText(temp)
  if not fieldsOk then return '-' end
  local n = math.floor(temp + 0.5)
  local str = plainStrings[n]
  if not str then
    str = tostring(n)
    plainStrings[n] = str
  end
  return str
end

-- Cell size in px at scale 1
local function cellSize()
  if S.tyreStyle == 2 then
    local h = (S.tyreNumbers and NUM_ROW_2 or 0) + TYRE_H + (S.tyreZones and 24 or 0)
    return 78, h
  end
  return 74, (S.tyreNumbers and NUM_ROW_1 or 0) + 14
end

local function baseSize()
  local cw, ch = cellSize()
  if S.tyreArrange == 2 then return PAD * 2 + cw * 4 + ITEM_GAP * 2 + PAIR_GAP, PAD * 2 + ch end
  return PAD * 2 + cw * 2 + COL_GAP, PAD * 2 + ch * 2 + ROW_GAP
end

-- Top-left corner of tyre i (1 FL, 2 FR, 3 RL, 4 RR) in px at scale 1
local function cellPos(i)
  local cw, ch = cellSize()
  if S.tyreArrange == 2 then
    return PAD + (i - 1) * (cw + ITEM_GAP) + (i >= 3 and PAIR_GAP - ITEM_GAP or 0), PAD
  end
  local col, row = (i - 1) % 2, i > 2 and 1 or 0
  return PAD + col * (cw + COL_GAP), PAD + row * (ch + ROW_GAP)
end

-- Three-part bar for the tread zones (one core-coloured bar when zones are off).
local function drawBar(x, y, w, h, i, sc)
  local b = math.max(1, 1.6 * sc)
  D.rect(x - b, y - b, x + w + b, y + h + b, D.color(BAR_BACK, S.opacity), h / 2 + b)
  if not S.tyreZones then
    D.rect(x, y, x + w, y + h, colorFor(core[i], i), h / 2)
    return
  end
  local sw = (w - b * 2) / 3
  local r = math.min(h / 2, 3 * sc)
  for k = 1, 3 do
    local sx = x + (k - 1) * (sw + b)
    D.rect(sx, y, sx + sw, y + h, colorFor(zoneTemp(i, k), i), r)
  end
end

-- Tyre shape: tread zones across the width, core as an inset in the middle.
local function drawTyre(x, y, w, h, i, sc)
  local r = math.min(w * 0.34, 10 * sc)
  D.rect(x, y, x + w, y + h, D.color(DARK, S.opacity), r)
  local inset = math.max(1.5, 3 * sc)
  local ix, iy, iw, ih = x + inset, y + inset, w - inset * 2, h - inset * 2
  local ri = math.max(0, r - inset)
  if not S.tyreZones then
    D.rect(ix, iy, ix + iw, iy + ih, colorFor(core[i], i), ri)
    return
  end
  local zw = iw / 3
  -- overlapping rects give the outer zones rounded outer corners and a square middle
  D.rect(ix, iy, ix + iw, iy + ih, colorFor(zoneTemp(i, 1), i), ri)
  D.rect(ix + zw, iy, ix + iw, iy + ih, colorFor(zoneTemp(i, 3), i), ri)
  D.rect(ix + zw, iy, ix + zw * 2, iy + ih, colorFor(zoneTemp(i, 2), i), 0)
  local gw = math.max(1, 1.6 * sc)
  D.rect(ix + zw - gw / 2, iy, ix + zw + gw / 2, iy + ih, D.color(GROOVE, S.opacity))
  D.rect(ix + zw * 2 - gw / 2, iy, ix + zw * 2 + gw / 2, iy + ih, D.color(GROOVE, S.opacity))
  local cw, ch = iw * 0.5, ih * 0.52
  local cx, cy = ix + (iw - cw) / 2, iy + (ih - ch) / 2
  local b, cr = math.max(1, 2 * sc), 5 * sc
  D.rect(cx - b, cy - b, cx + cw + b, cy + ch + b, D.color(DARK, S.opacity), cr + b)
  D.rect(cx, cy, cx + cw, cy + ch, colorFor(core[i], i), cr)
end

local function drawCell(i, x, y, sc)
  local cw = cellSize() * sc
  if S.tyreStyle == 2 then
    local cy = y
    if S.tyreNumbers then
      D.text(degreeText(core[i]), 32 * sc, x, cy, cw, NUM_ROW_2 * sc, D.ALIGN_CENTER, D.color(S.colText, S.opacity))
      cy = cy + NUM_ROW_2 * sc
    end
    local tw, th = TYRE_W * sc, TYRE_H * sc
    drawTyre(x + (cw - tw) / 2, cy, tw, th, i, sc)
    if S.tyreZones then
      local zy, third = cy + th + 4 * sc, cw / 3
      for k = 1, 3 do
        D.text(plainText(zoneTemp(i, k)), 17 * sc, x + (k - 1) * third, zy, third, 20 * sc, D.ALIGN_CENTER,
          D.color(S.colText, S.opacity))
      end
    end
  else
    local cy = y
    if S.tyreNumbers then
      D.text(degreeText(core[i]), 40 * sc, x, cy, cw, NUM_ROW_1 * sc, D.ALIGN_CENTER, colorFor(core[i], i))
      cy = cy + NUM_ROW_1 * sc
    end
    local bw = 56 * sc
    drawBar(x + (cw - bw) / 2, cy + 5 * sc, bw, 9 * sc, i, sc)
  end
end

local M = {}

function M.available()
  return fieldsOk
end

function M.optimumFromCar()
  return optimumOk or carData.tyreFromCurve
end

function M.draw()
  local car = ac.getCar(0)
  if not car then return end
  if fieldsOk == nil then checkFields(car) end
  if fieldsOk then readTyres(car) end
  local w, h = ui.windowWidth(), ui.windowHeight()
  local baseW, baseH = baseSize()
  if w <= 0 or h <= 0 then return end
  local sc = math.min(w / baseW, h / baseH)
  ui.pushDWriteFont(D.FONT)
  if S.tyresPanel then D.panel(0, 0, baseW * sc, baseH * sc, 8 * sc) end
  for i = 1, 4 do
    local cx, cy = cellPos(i)
    drawCell(i, cx * sc, cy * sc, sc)
  end
  ui.popDWriteFont()
end

return M
