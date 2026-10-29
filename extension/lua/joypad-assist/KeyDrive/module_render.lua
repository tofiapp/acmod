-- KeyDrive render-thread module: diagnostic overlay.
-- Runs in the render thread, shares no Lua state with assist.lua; data comes through ac.connect.

local shared = require('src/shared')
local recorder = require('src/recorder')

local live = shared.connect()
-- text input focus (chat, CSP text fields): the physics script then ignores TRACTION_KEY
local okUI, uiState = pcall(ac.getUI)
if not okUI then uiState = nil end
local okCapture = uiState ~= nil and pcall(function () return uiState.wantCaptureKeyboard end)
local carState = ac.getCar(__carIndex)
recorder.init(__dirname)
ac.onRelease(recorder.save)

local W, H = 540, 316
local P = {
  origin = vec2(24, 0),
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
  request = rgbm(0.35, 0.8, 1, 0.9),
  cap = rgbm(1, 1, 1, 0.45),
  ok = rgbm(0.4, 0.9, 0.4, 1),
  warn = rgbm(1, 0.75, 0.2, 1),
  bad = rgbm(1, 0.35, 0.3, 1),
}

local TC_TEXT = { [0] = 'bez dat o kolech', 'vypnutá', 'kola ve vzduchu', 'připravena', 'OMEZUJE', 'VYPNUTÁ klávesou' }
local BRAKE_TEXT = { [0] = 'bez dat o kolech', 'hlídání vypnuto', 'reguluje ABS auta', 'připravena', 'POVOLUJE' }
local STEER_TEXT = { [0] = 'bez dat o kolech', 'nízká rychlost', 'volné', 'OMEZUJE', 'PROTIPOHYB' }

local lastAlive, staleTime = -1, 0

-- the KeyDriveConfig app's "Zobrazit diagnostiku" wins over SHOW_DIAGNOSTICS in settings.ini once it has been set
local function showDiagnostics()
  if live.cfgSet then return live.cfgShowDiag end
  return live.showDiagnostics
end
local textTimer = 0
local lines = { '', '', '', '', '', '', '', '' }

local function gearText(g)
  return g == -1 and 'R' or g == 0 and 'N' or tostring(g)
end

function script.update(dt)
  live.keyboardCaptured = okCapture and uiState.wantCaptureKeyboard == true
  -- the badge for traction switched off with TRACTION_KEY shows even with the diagnostics hidden
  ac.setDrawUIActive(showDiagnostics() or live.tcState == 5)
  if live.recordLog then recorder.update(dt, live, carState) end
  if live.alive ~= lastAlive then
    lastAlive = live.alive
    staleTime = 0
  else
    staleTime = staleTime + dt
  end
  textTimer = textTimer - dt
  if textTimer <= 0 then
    textTimer = 0.1
    local m = live.keyMask
    lines[1] = string.format('Jádro: %s   fyzika %.0f Hz', staleTime < 0.5 and 'běží' or 'NEBĚŽÍ', live.physicsHz)
    lines[2] = string.format('Trakce: %s  prokluz %.0f %% vrcholu (cíl %.0f %%)%s  strop %.0f %%  převod unese %.0f %%',
      TC_TEXT[live.tcState] or '?', live.slip * 100, live.targetSlip * 100, live.usesNdSlip and '' or ' [náhradní]',
      live.tcLimit * 100, live.tcMemory * 100)
    lines[3] = string.format('Auto: plyn %.0f %%  brzda %.0f %%  převod %s  %.0f ot/min',
      carState.gas * 100, carState.brake * 100, gearText(carState.gear), carState.rpm)
    lines[4] = string.format('Vstup do skriptu: plyn %.0f %%  brzda %.0f %%  řízení %.0f %%',
      live.inGas * 100, live.inBrake * 100, live.inSteer * 100)
    lines[5] = string.format('Klávesy (VK): plyn %d  brzda %d  vlevo %d  vpravo %d  řazení %d%s / %d%s',
      live.bindGas, live.bindBrake, live.bindLeft, live.bindRight,
      live.bindGearUp, math.floor(m / 16) % 2 == 1 and '*' or '', live.bindGearDown, math.floor(m / 32) % 2 == 1 and '*' or '')
    lines[7] = string.format('Brzda: %s  podélný prokluz %.0f %% vrcholu (vrchol %.0f %%)  brzda ×%.2f  paměť %.0f %%',
      BRAKE_TEXT[live.brakeState] or '?', live.brakeSlip * 100, live.brakePeakRatio * 100, live.brakeK,
      live.brakeMemory * 100)
    lines[8] = string.format('Řízení: %s  (z AC %.0f %%, hlasy %d)  skluz předních %.1f° (vrchol %.1f°)',
      live.steerFromAC and 'AC, beze změny' or 'KeyDrive', live.inSteer * 100, live.acSteerVotes, live.frontAlpha,
      live.alphaPeak)
    lines[6] = live.leak and 'POZOR: auto jede s větším plynem, než KeyDrive posílá (AC přimíchává klávesnici)' or ''
  end
end

local BAR_X, BAR_W, BAR_H = 92, 400, 12

local function marker(x, y, color, w)
  P.a:set(x - w, y - 3); P.b:set(x + w, y + BAR_H + 3)
  ui.drawRectFilled(P.a, P.b, color, 0)
end

local function keyDot(y, on)
  P.a:set(P.origin.x + 76, y + 2); P.b:set(P.origin.x + 84, y + 10)
  ui.drawRectFilled(P.a, P.b, on and C.key or C.track, 2)
end

-- 0..1 bar: track and value in the given colour. Returns the bar's left edge.
local function bar01(y, value, color)
  local x0 = P.origin.x + BAR_X
  P.a:set(x0, y); P.b:set(x0 + BAR_W, y + BAR_H)
  ui.drawRectFilled(P.a, P.b, C.track, 2)
  P.a:set(x0, y); P.b:set(x0 + BAR_W * math.clamp(value, 0, 1), y + BAR_H)
  ui.drawRectFilled(P.a, P.b, color, 2)
  return x0
end

local function label(x, y, s, color)
  P.cursor:set(x, y)
  ui.setCursor(P.cursor)
  if color then ui.textColored(s, color) else ui.text(s) end
end

-- Small badge at the top centre while the driver has the traction control switched off (tcState 5).
local function tractionOffBadge()
  local x = math.floor(ui.windowWidth() / 2) - 110
  P.a:set(x, 56); P.b:set(x + 220, 82)
  ui.drawRectFilled(P.a, P.b, C.bg, 4)
  P.a:set(x, 56); P.b:set(x + 4, 82)
  ui.drawRectFilled(P.a, P.b, C.bad, 2)
  ui.pushFont(ui.Font.Small)
  label(x + 14, 61, 'KeyDrive: hlídání prokluzu VYP', C.bad)
  ui.popFont()
end

function script.drawUI()
  if live.tcState == 5 then tractionOffBadge() end
  if not showDiagnostics() then return end
  local o = P.origin
  o.y = math.floor(ui.windowHeight() * 0.3)
  P.a:set(o.x, o.y); P.b:set(o.x + W, o.y + H)
  ui.drawRectFilled(P.a, P.b, C.bg, 6)

  ui.pushFont(ui.Font.Small)
  label(o.x + 10, o.y + 8, 'KeyDrive – diagnostika')
  local mask = live.keyMask

  -- Throttle: orange = sent, blue line = key ramp before limits, grey = cap, white = car
  label(o.x + 10, o.y + 32, 'Plyn')
  keyDot(o.y + 34, mask % 2 == 1)
  local x0 = bar01(o.y + 34, live.outGas, C.out)
  marker(x0 + BAR_W * math.clamp(live.cap, 0, 1), o.y + 34, C.cap, 1)
  marker(x0 + BAR_W * math.clamp(live.gasRequest, 0, 1), o.y + 34, C.request, 1)
  marker(x0 + BAR_W * math.clamp(carState.gas, 0, 1), o.y + 34, C.car, 1)

  -- Slip: full bar = twice the target, the middle line is the target
  label(o.x + 10, o.y + 54, 'Prokluz')
  local target = live.targetSlip > 0 and live.targetSlip or 0.1
  local k = live.slip / (2 * target)
  x0 = bar01(o.y + 56, k, k > 0.6 and C.bad or k > 0.4 and C.warn or C.ok)
  marker(x0 + BAR_W * 0.5, o.y + 56, C.car, 1)

  label(o.x + 10, o.y + 76, 'Brzda')
  keyDot(o.y + 78, math.floor(mask / 2) % 2 == 1)
  x0 = bar01(o.y + 78, live.outBrake, C.out)
  marker(x0 + BAR_W * math.clamp(live.brakeCap, 0, 1), o.y + 78, C.cap, 1)
  marker(x0 + BAR_W * math.clamp(live.brakeRequest, 0, 1), o.y + 78, C.request, 1)
  marker(x0 + BAR_W * math.clamp(carState.brake, 0, 1), o.y + 78, C.car, 1)

  label(o.x + 10, o.y + 98, 'Řízení')
  keyDot(o.y + 100, math.floor(mask / 4) % 2 == 1 or math.floor(mask / 8) % 2 == 1)
  x0 = o.x + BAR_X
  P.a:set(x0, o.y + 100); P.b:set(x0 + BAR_W, o.y + 100 + BAR_H)
  ui.drawRectFilled(P.a, P.b, C.track, 2)
  local mid = x0 + BAR_W * 0.5
  local e = mid + math.clamp(live.outSteer, -1, 1) * BAR_W * 0.5
  P.a:set(math.min(mid, e), o.y + 100); P.b:set(math.max(mid, e), o.y + 100 + BAR_H)
  ui.drawRectFilled(P.a, P.b, C.out, 2)
  if live.steerState >= 2 then
    marker(mid + math.clamp(live.steerLo, -1, 1) * BAR_W * 0.5, o.y + 100, C.cap, 1)
    marker(mid + math.clamp(live.steerHi, -1, 1) * BAR_W * 0.5, o.y + 100, C.cap, 1)
  end
  marker(mid + math.clamp(live.steerRequest, -1, 1) * BAR_W * 0.5, o.y + 100, C.request, 1)

  label(o.x + 10, o.y + 124, lines[1])
  label(o.x + 10, o.y + 142, lines[2], live.tcState == 5 and C.bad or live.tcState == 4 and C.warn or nil)
  label(o.x + 10, o.y + 160, lines[7], live.brakeState == 4 and C.warn or nil)
  label(o.x + 10, o.y + 178, lines[8], live.steerState >= 3 and C.warn or nil)
  label(o.x + 10, o.y + 196, lines[3])
  label(o.x + 10, o.y + 214, lines[4])
  label(o.x + 10, o.y + 232, lines[5])
  if live.leak then label(o.x + 10, o.y + 250, lines[6], C.bad) end
  label(o.x + 10, o.y + 272, 'oranžová = posláno, modrá = klávesa, šedá = strop, bílá = auto')
  if live.recordLog then
    if recorder.error then
      label(o.x + 10, o.y + 290, 'záznam nefunguje: ' .. recorder.error, C.bad)
    elseif recorder.lastIncident ~= '' then
      label(o.x + 10, o.y + 290, 'záznam běží, poslední incident: ' .. recorder.lastIncident, C.warn)
    else
      label(o.x + 10, o.y + 290, recorder.statusText)
    end
  end
  ui.popFont()
end
