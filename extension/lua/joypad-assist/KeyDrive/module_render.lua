-- KeyDrive render-thread module: diagnostic overlay for the proof of concept.
-- Runs in the render thread, shares no Lua state with assist.lua; data comes through ac.connect.

local shared = require('src/shared')

local live = shared.connect()
local carState = ac.getCar(__carIndex)

local P = {
  origin = vec2(24, 0),
  size = vec2(430, 236),
  a = vec2(),
  b = vec2(),
  cursor = vec2(),
}
local C = {
  bg = rgbm(0, 0, 0, 0.6),
  track = rgbm(1, 1, 1, 0.12),
  key = rgbm(0.35, 0.8, 1, 1),
  out = rgbm(1, 0.62, 0.15, 1),
  car = rgbm(1, 1, 1, 1),
  ok = rgbm(0.4, 0.9, 0.4, 1),
  bad = rgbm(1, 0.35, 0.3, 1),
}

local lastAlive, staleTime = -1, 0
local textTimer = 0
local lines = { '', '', '', '', '' }

function script.update(dt)
  ac.setDrawUIActive(live.showDiagnostics)
  if live.alive ~= lastAlive then
    lastAlive = live.alive
    staleTime = 0
  else
    staleTime = staleTime + dt
  end
  textTimer = textTimer - dt
  if textTimer <= 0 then
    textTimer = 0.1
    lines[1] = string.format('Jádro: %s   fyzika %.0f Hz', staleTime < 0.5 and 'běží' or 'NEBĚŽÍ', live.physicsHz)
    lines[2] = string.format('Vstup do skriptu: plyn %.0f %%  brzda %.0f %%  řízení %.0f %%',
      live.inGas * 100, live.inBrake * 100, live.inSteer * 100)
    lines[3] = string.format('Klávesy (VK): plyn %d  brzda %d  vlevo %d  vpravo %d',
      live.bindGas, live.bindBrake, live.bindLeft, live.bindRight)
    local m = live.keyMask
    lines[4] = string.format('Auto (fyzika): plyn %.0f %%  brzda %.0f %%  rychlost %s',
      carState.gas * 100, carState.brake * 100, carState.gear == -1 and 'R' or carState.gear == 0 and 'N' or tostring(carState.gear))
    lines[5] = string.format('Řazení (VK): nahoru %d%s  dolů %d%s', live.bindGearUp,
      math.floor(m / 16) % 2 == 1 and ' [stisk]' or '', live.bindGearDown, math.floor(m / 32) % 2 == 1 and ' [stisk]' or '')
  end
end

-- Horizontal bar: track, KeyDrive output (orange), car value marker (white). Signed values grow from the middle.
local function bar(y, out, carValue, signed, keyOn)
  local x0, w, h = P.origin.x + 92, 310, 12
  P.a:set(x0, y); P.b:set(x0 + w, y + h)
  ui.drawRectFilled(P.a, P.b, C.track, 2)
  if signed then
    local mid = x0 + w * 0.5
    local e = mid + out * w * 0.5
    P.a:set(math.min(mid, e), y); P.b:set(math.max(mid, e), y + h)
  else
    P.a:set(x0, y); P.b:set(x0 + w * math.clamp(out, 0, 1), y + h)
  end
  ui.drawRectFilled(P.a, P.b, C.out, 2)
  local m = signed and (x0 + w * 0.5 + carValue * w * 0.5) or (x0 + w * math.clamp(carValue, 0, 1))
  P.a:set(m - 1, y - 3); P.b:set(m + 1, y + h + 3)
  ui.drawRectFilled(P.a, P.b, C.car, 0)
  P.a:set(P.origin.x + 76, y + 2); P.b:set(P.origin.x + 84, y + 10)
  ui.drawRectFilled(P.a, P.b, keyOn and C.key or C.track, 2)
end

local function label(x, y, s)
  P.cursor:set(x, y)
  ui.setCursor(P.cursor)
  ui.text(s)
end

function script.drawUI()
  local o = P.origin
  o.y = math.floor(ui.windowHeight() * 0.3)
  P.a:set(o.x, o.y); P.b:set(o.x + P.size.x, o.y + P.size.y)
  ui.drawRectFilled(P.a, P.b, C.bg, 6)

  ui.pushFont(ui.Font.Small)
  label(o.x + 10, o.y + 8, 'KeyDrive – diagnostika (PoC)')
  local mask = live.keyMask
  label(o.x + 10, o.y + 34, 'Plyn')
  bar(o.y + 36, live.outGas, carState.gas, false, mask % 2 == 1)
  label(o.x + 10, o.y + 56, 'Brzda')
  bar(o.y + 58, live.outBrake, carState.brake, false, math.floor(mask / 2) % 2 == 1)
  label(o.x + 10, o.y + 78, 'Řízení')
  -- car.steer is in degrees, so the marker shows the written joypad value
  bar(o.y + 80, live.outSteer, live.outSteer, true,
    math.floor(mask / 4) % 2 == 1 or math.floor(mask / 8) % 2 == 1)
  label(o.x + 10, o.y + 104, lines[1])
  label(o.x + 10, o.y + 124, lines[2])
  label(o.x + 10, o.y + 144, lines[3])
  label(o.x + 10, o.y + 164, lines[4])
  label(o.x + 10, o.y + 184, lines[5])
  label(o.x + 10, o.y + 208, 'modrá = klávesa, oranžová = KeyDrive, bílá = auto')
  ui.popFont()
end
