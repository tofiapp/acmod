-- Lifecycle and the LED frame loop. States: wait (no car yet) -> run | off (master switch) | noleds | failed.
-- A restart (session start, car change, method change, "Znovu najít") gives every LED back, heals what an earlier run
-- left hidden, reads the car again and attaches the takeover. Phase 3 fills the LEDs from test patterns.

local config = require('src/config')
local store = require('src/store')
local carInfo = require('src/car_info')
local detect = require('src/detect')
local takeover = require('src/takeover')
local color = require('src/color')

local S = config.S

local M = {
  state = 'wait', carId = '', info = nil, layout = nil, profile = { v = 1 },
  fb = {}, manual = {}, n = 0, hover = 0, hoverUntil = 0, healed = 0,
  clock = 0, version = 0, restartReason = 'start', lastRestart = '',
}

M.MODES = { 'Původní stav', 'Duha', 'Běžící světlo', 'Vše zhasnout', 'Vše bílé', 'Ruční barvy' }
M.MANUAL = 6
M.STATES = {
  wait = 'čekám na auto',
  run = 'běží',
  off = 'vypnuto hlavním vypínačem',
  noleds = 'auto nemá rozpoznané diody',
  failed = 'žádná metoda převzetí nefunguje',
}

local CHASE = 0x00C8FF

local function bump() M.version = M.version + 1 end

function M.restart(reason)
  M.restartReason = reason or 'restart'
end

function M.method()
  return M.profile.method or S.method
end

function M.setMethod(m)
  M.profile.method = m
  if M.carId ~= '' then store.saveCar(M.carId, M.profile) end
  M.restart('method')
end

function M.setMode(mode)
  config.set('testMode', mode)
end

function M.setManual(i, p)
  if i < 1 or i > M.n then return end
  if S.testMode ~= M.MANUAL then
    -- start from what the LEDs show now, so editing one LED keeps the others
    for k = 1, M.n do M.manual[k] = M.fb[k] or color.ORIGINAL end
    config.set('testMode', M.MANUAL)
  end
  M.manual[i] = p
end

function M.setIntensity(v)
  config.set('intensity', v)
  takeover.invalidate()
end

-- The window marks an LED under the mouse; it blinks on the car while marked.
function M.markHover(i)
  M.hover, M.hoverUntil = i, M.clock + 0.15
end

local function attach()
  takeover.attach(M.layout, M.method(), M.carId)
  M.state = takeover.method ~= 0 and 'run' or 'failed'
end

local function detectCar(car, id)
  M.carId = id
  M.healed = M.healed + takeover.heal(id)
  M.info = carInfo.read()
  M.profile = store.loadCar(id)
  M.layout = detect.run(car, M.info)
  if M.layout.notReady then return false end
  local n = #M.layout.leds
  M.n = n
  for i = 1, detect.MAX_LEDS do
    M.fb[i] = color.ORIGINAL
    if i > n or M.manual[i] == nil then M.manual[i] = color.ORIGINAL end
  end
  if n == 0 then M.state = 'noleds'
  elseif not S.master then M.state = 'off'
  else attach() end
  bump()
  return true
end

local floor = math.floor

local function fill(t)
  local n, fb, mode = M.n, M.fb, S.testMode
  if mode == 2 then
    local step = floor(t * 8) / 48
    for i = 1, n do fb[i] = color.hsv((i - 1) / n + step, 1, 1) end
  elseif mode == 3 then
    local pos = floor(t * 8) % n + 1
    for i = 1, n do fb[i] = i == pos and CHASE or color.OFF end
  elseif mode == 4 then
    for i = 1, n do fb[i] = color.OFF end
  elseif mode == 5 then
    for i = 1, n do fb[i] = color.WHITE end
  elseif mode == M.MANUAL then
    local manual = M.manual
    for i = 1, n do fb[i] = manual[i] end
  else
    for i = 1, n do fb[i] = color.ORIGINAL end
  end
  local h = M.hover
  if h > 0 and h <= n and M.clock < M.hoverUntil then
    fb[h] = floor(t * 6) % 2 == 0 and color.WHITE or color.OFF
  end
end

local carCheck = 0
local waitTimer = 0

function M.update(dt)
  M.clock = M.clock + dt
  if M.restartReason then
    takeover.dispose()
    M.lastRestart = M.restartReason
    M.restartReason = nil
    M.state = 'wait'
    waitTimer = 0
    bump()
  end
  if M.state == 'wait' then
    waitTimer = waitTimer - dt
    if waitTimer > 0 then return end
    waitTimer = 1          -- model not loaded yet: try again in a second
    local car = ac.getCar(0)
    local id = ac.getCarID(0)
    if car and id and id ~= '' and detectCar(car, id) then waitTimer = 0 end
    return
  end
  carCheck = carCheck + dt
  if carCheck >= 1 then
    carCheck = 0
    if ac.getCarID(0) ~= M.carId then M.restart('car'); return end
  end
  if M.state == 'off' then
    if S.master then attach(); bump() end
    return
  end
  if M.state ~= 'run' then return end
  if not S.master then
    takeover.dispose()
    M.state = 'off'
    bump()
    return
  end
  fill(M.clock)
  local fb = M.fb
  for i = 1, M.n do takeover.set(i, fb[i]) end
  takeover.guard(dt)
end

-- Error boundary restorer: everything back to the car.
function M.halt()
  takeover.dispose()
  M.state = 'wait'
end

return M
