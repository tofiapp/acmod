-- KeyDrive tests: run through tests/keydrive/run_tests.py.
local selfPath, CORE, APP, KBTEST = ...
local here = selfPath:match('^(.*)[/\\]')
package.path = here .. '/?.lua;' .. package.path
local mock = require('mock_csp')

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print('FAIL: ' .. name .. (detail and (' (' .. tostring(detail) .. ')') or ''))
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT = 38, 40, 37, 39

local function fresh(settings)
  mock.reset()
  if settings then mock.settings = { KEYDRIVE = settings } end
  return mock.load(CORE, 'assist.lua')
end

local function run(s, seconds, dt)
  local n = math.floor(seconds / dt + 0.5)
  for _ = 1, n do s.update(dt) end
end

-- 1. Throttle ramps up at THROTTLE_RISE_RATE, independent of the physics rate (the key ramp alone: traction off, since
-- with traction on the cap's recovery K_BACK also limits the onset, see 1b).
do
  local results = {}
  for _, dt in ipairs({ 0.003, 1 / 60, 0.01 }) do
    local s = fresh({ TRACTION = 0 })
    mock.keys[VK_UP] = true
    run(s, 0.3, dt)
    results[#results + 1] = mock.joypad.gas
  end
  check('throttle rise 120 %/s after 0.3 s', near(results[1], 0.36, 0.01), results[1])
  check('throttle rise independent of dt', near(results[1], results[2], 0.01) and near(results[1], results[3], 0.01),
    table.concat(results, ', '))
end

-- 1b. With traction on, the cap comes back at K_BACK, which can be slower than the key ramp, so even without wheelspin
-- it limits the onset after the anti-windup head start (v0.13.0: K_BACK 0.73, ~1.35 s to full; v0.13.1: 1.03, ~0.95 s;
-- the key ramp alone 0.83 s).
do
  local s = fresh()
  mock.keys[VK_UP] = true
  run(s, 0.3, 0.003)
  local g03 = mock.joypad.gas
  run(s, 1.2, 0.003)
  check('default onset: ~0.32 after 0.3 s (key ramp alone 0.36; v0.13.0 0.23)', g03 > 0.27 and g03 < 0.36, g03)
  check('default onset: full throttle within 1.5 s', mock.joypad.gas > 0.97, mock.joypad.gas)
  mock.keys[VK_UP] = nil
end

-- 2. Reaches the cap and stays there; falls at THROTTLE_FALL_RATE after release.
do
  local s = fresh({ MAX_THROTTLE = 80 })
  mock.keys[VK_UP] = true
  run(s, 2, 0.003)
  check('throttle capped by MAX_THROTTLE', near(mock.joypad.gas, 0.8), mock.joypad.gas)
  mock.keys[VK_UP] = nil
  run(s, 0.1, 0.003)
  check('throttle falls at 400 %/s', near(mock.joypad.gas, 0.4, 0.015), mock.joypad.gas)
  run(s, 1, 0.003)
  check('throttle returns to zero', mock.joypad.gas == 0, mock.joypad.gas)
end

-- 3. Rates come from settings.ini.
do
  local s = fresh({ THROTTLE_RISE_RATE = 500, TRACTION = 0 })
  mock.keys[VK_UP] = true
  run(s, 0.1, 0.003)
  check('custom rise rate', near(mock.joypad.gas, 0.5, 0.015), mock.joypad.gas)
end

-- 4. A long hitch does not jump the ramp more than 50 ms.
do
  local s = fresh()
  mock.keys[VK_UP] = true
  s.update(1.0)
  check('dt clamp after a hitch', near(mock.joypad.gas, 1.2 * 0.05), mock.joypad.gas)
  s.update(0)
  check('dt = 0 is ignored', near(mock.joypad.gas, 1.2 * 0.05), mock.joypad.gas)
end

-- 5. Teleport resets every output.
do
  local s = fresh()
  mock.keys[VK_UP] = true
  mock.keys[VK_RIGHT] = true
  run(s, 0.5, 0.003)
  mock.keys[VK_UP] = nil
  mock.keys[VK_RIGHT] = nil
  mock.jump()
  s.update(0.003)
  check('jump resets gas', mock.joypad.gas == 0, mock.joypad.gas)
  check('jump resets steering', mock.joypad.steer == 0, mock.joypad.steer)
end

-- 6. Brake and steering placeholders.
do
  local s = fresh()
  mock.keys[VK_DOWN] = true
  run(s, 0.1, 0.003)
  check('brake rises', mock.joypad.brake > 0.35 and mock.joypad.brake < 0.45, mock.joypad.brake)
  mock.keys[VK_DOWN] = nil
  mock.keys[VK_LEFT] = true
  run(s, 0.2, 0.003)
  local held = mock.joypad.steer
  check('left steers negative', held < -0.2, held)
  mock.keys[VK_RIGHT] = true
  run(s, 0.3, 0.003)
  check('both steering keys hold the angle', near(mock.joypad.steer, held), mock.joypad.steer)
  mock.keys[VK_LEFT] = nil
  mock.keys[VK_RIGHT] = nil
  run(s, 1, 0.003)
  check('steering returns to centre', mock.joypad.steer == 0, mock.joypad.steer)
end

-- 7. Rebound keys from controls.ini, re-read on change.
do
  local s = fresh({ TRACTION = 0 })
  mock.controls.KEYBOARD.GAS = 87 -- W
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  mock.keys[87] = true
  run(s, 0.2, 0.003)
  check('rebound gas key', mock.joypad.gas > 0.2, mock.joypad.gas)
  check('binds published', mock.connected['KeyDrive.Live.v11'].bindGas == 87)
end

-- 7b. Gear and handbrake keys from their own sections, hex values as Content Manager writes them.
do
  mock.reset()
  mock.controls.GEARUP = { KEY = '0x53' }   -- S
  mock.controls.GEARDN = { KEY = '0x46' }   -- F
  mock.controls.HANDBRAKE = { KEY = '0x20' }
  mock.controls.KEYBOARD.GAS = '0x57'       -- W as hex string
  mock.settings = { KEYDRIVE = { TRACTION = 0 } } -- the key ramp alone
  local s = mock.load(CORE, 'assist.lua')
  mock.joypad.gearUp, mock.joypad.gearDown = false, false
  s.update(0.003)
  check('no gear press without keys', mock.joypad.gearUp == false and mock.joypad.gearDown == false)
  mock.keys[0x53] = true
  s.update(0.003)
  check('gear up key forwarded', mock.joypad.gearUp == true)
  mock.keys[0x53] = nil
  mock.joypad.gearUp = false -- AC refills the state every step
  mock.keys[0x46] = true
  s.update(0.003)
  check('gear down key forwarded', mock.joypad.gearDown == true and mock.joypad.gearUp == false)
  mock.keys[0x20] = true
  s.update(0.003)
  check('handbrake key forwarded', mock.joypad.handbrake == 1)
  mock.keys[0x57] = true
  run(s, 0.1, 0.003)
  check('hex GAS bind', mock.joypad.gas > 0.1, mock.joypad.gas)
  local live = mock.connected['KeyDrive.Live.v11']
  check('gear binds published', live.bindGearUp == 0x53 and live.bindGearDown == 0x46)
end

-- 8. AI-controlled car: the script does nothing.
do
  mock.reset()
  mock.car.isAIControlled = true
  mock.load(CORE, 'assist.lua')
  check('AI car: no update function', script.update == nil)
end

-- 9. Diagnostics are published and the render module loads and draws.
do
  local s = fresh()
  mock.keys[VK_UP] = true
  mock.joypad.gas = 1 -- pretend AC sent raw keyboard gas
  s.update(0.003)
  local live = mock.connected['KeyDrive.Live.v11']
  check('incoming value published', live.inGas == 1, live.inGas)
  check('key mask', live.keyMask == 1, live.keyMask)
  check('render module requested', mock.renderModules[1] == 'module_render')
  local core = CORE
  local r = mock.load(core, 'module_render.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  r.update(0.016)
  r.drawUI()
  check('render module draws', (mock.calls.drawRectFilled or 0) > 5 and (mock.calls.text or 0) >= 6)
end

-- 10. No per-step allocation in the physics update.
do
  local s = fresh()
  mock.keys[VK_UP] = true
  mock.keys[VK_LEFT] = true
  jit.off()
  run(s, 0.5, 0.003)
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count')
  run(s, 3, 0.003)
  local grown = collectgarbage('count') - before
  collectgarbage('restart')
  jit.on()
  check('no allocation in update (KB)', grown < 1, grown)
end

-- 11. Traction: a simple RWD launch model (wheel inertia + Pacejka-like tyre). With far too much torque the
-- limiter must hold the slip near the target without oscillating, the same at any physics rate.
local function launch(dt, settings, seconds)
  local s = fresh(settings)
  local c = mock.car
  local m, r, J, N, mu = 1300, 0.32, 8, 3500, 1.1 -- J includes engine + gearbox inertia in first gear
  local torque = settings and settings.__torque or 3000 -- Nm at the axle at full throttle (first gear, more than grip)
  local v, w = 0, 0
  local slips, gases, t = {}, {}, 0
  local maxJump, prevGas = 0, 0
  mock.keys[VK_UP] = true
  local steps = math.floor(seconds / dt + 0.5)
  for _ = 1, steps do
    s.update(dt)
    local gasNow = mock.joypad.gas
    c.gas = gasNow
    if math.abs(gasNow - prevGas) > maxJump then maxJump = math.abs(gasNow - prevGas) end
    prevGas = gasNow
    local sub = 20
    local h = dt / sub
    local F
    for _ = 1, sub do
      local sr = (w * r - v) / math.max(v, 3)
      F = mu * N * math.sin(1.6 * math.atan(9 * sr))   -- per wheel, peak near 12 % slip
      v = v + 2 * F / m * h
      w = w + (gasNow * torque / 2 - F * r) / J * h
      if w < 0 then w = 0 end
    end
    for i = 2, 3 do
      c.wheels[i].angularSpeed = w
      c.wheels[i].slipRatio = (w * r - v) / math.max(v, 3)
      c.wheels[i].ndSlip = math.abs(c.wheels[i].slipRatio) / 0.166 -- 1 at the model's peak
    end
    for i = 0, 1 do c.wheels[i].angularSpeed = v / r end
    c.localVelocity.z = v
    c.speedKmh = v * 3.6
    t = t + dt
    if t > 1.0 then
      slips[#slips + 1] = c.wheels[2].ndSlip
      gases[#gases + 1] = gasNow
    end
  end
  mock.keys[VK_UP] = nil
  local function stats(a)
    local sum, sq, mx = 0, 0, -1e9
    for _, x in ipairs(a) do sum = sum + x; if x > mx then mx = x end end
    local mean = sum / #a
    for _, x in ipairs(a) do sq = sq + (x - mean) ^ 2 end
    return mean, math.sqrt(sq / #a), mx
  end
  local sm, ss, smax = stats(slips)
  local gm, gs = stats(gases)
  return { v = v, slipMean = sm, slipStd = ss, slipMax = smax, gasMean = gm, gasStd = gs, maxJump = maxJump / dt }
end

do
  local free = launch(0.003, { TRACTION = 0 }, 3)
  if os.getenv('KD_VERBOSE') then for _, x in ipairs({ free, launch(0.003, nil, 3), launch(0.003, { __torque = 4500 }, 3) }) do print(string.format('v %.2f slip %.3f±%.3f max %.3f gas %.3f±%.3f jump %.2f/s', x.v, x.slipMean, x.slipStd, x.slipMax, x.gasMean, x.gasStd, x.maxJump)) end end
  check('model: without traction the wheels spin', free.slipMean > 0.5, free.slipMean)
  local a = launch(0.003, nil, 3)
  check('traction keeps the slip moderate', a.slipMean < 1.6, a.slipMean)
  check('traction: no runaway spin (one short spike allowed)', a.slipMax < 4, a.slipMax)
  check('traction: no throttle steps (assist cuts at most 1.5 /s, 4 /s in a real spin)', a.maxJump < 4.05, a.maxJump)
  check('traction: throttle mostly kept', a.gasMean > 0.6, a.gasMean)
  check('traction: no pulsing (steady throttle once the limit is known)', a.gasStd < 0.06, a.gasStd)
  check('traction beats wheelspin', a.v > free.v, string.format('%.1f vs %.1f', a.v, free.v))
  local b = launch(1 / 400, nil, 3)
  local c = launch(1 / 250, nil, 3)
  check('traction independent of physics rate', math.abs(a.v - b.v) / a.v < 0.03 and math.abs(a.v - c.v) / a.v < 0.03,
    string.format('%.2f %.2f %.2f', a.v, b.v, c.v))
  local strong = launch(0.003, { __torque = 4500 }, 3)
  check('very strong car: throttle without steps', strong.maxJump < 4.05,
    string.format('jump %.2f std %.3f', strong.maxJump, strong.gasStd))
end

-- 12. Reverse, missing wheel data, wheels in the air, corner cap, leak detection.
do
  local s = fresh()
  local c = mock.car
  c.gear = -1
  for i = 2, 3 do c.wheels[i].angularSpeed = 50 end -- spinning wildly backwards would confuse traction
  mock.keys[VK_UP] = true
  run(s, 0.5, 0.003)
  check('reverse: no traction limit', near(mock.joypad.gas, 0.6, 0.01), mock.joypad.gas)
  check('reverse: traction state ready/off', mock.connected['KeyDrive.Live.v11'].tcState ~= 4)

  s = fresh()
  for i = 0, 3 do mock.car.wheels[i].tyreRadius = 0 end
  s = mock.load(CORE, 'assist.lua')
  mock.keys[VK_UP] = true
  run(s, 0.5, 0.003)
  check('no wheel data: plain ramp', near(mock.joypad.gas, 0.6, 0.01), mock.joypad.gas)
  check('no wheel data: state 0', mock.connected['KeyDrive.Live.v11'].tcState == 0)

  s = fresh()
  mock.keys[VK_UP] = true
  run(s, 0.3, 0.003)
  for i = 2, 3 do mock.car.wheels[i].load = 0; mock.car.wheels[i].angularSpeed = 200 end
  run(s, 0.2, 0.003)
  check('airborne: state 2', mock.connected['KeyDrive.Live.v11'].tcState == 2)
  check('airborne: throttle not cut', mock.joypad.gas > 0.4, mock.joypad.gas)

  s = fresh({ CORNER_THROTTLE_REDUCTION = 25 })
  mock.joypad.gForces.x = 1.5
  mock.keys[VK_UP] = true
  run(s, 2, 0.003)
  check('corner cap 25 % at 1.5 g', near(mock.joypad.gas, 0.75, 0.01), mock.joypad.gas)

  s = fresh()
  mock.keys[VK_UP] = true
  s.update(0.003)
  for _ = 1, 200 do mock.car.gas = 1; s.update(0.003) end
  check('leak detected', mock.connected['KeyDrive.Live.v11'].leak == true)
  s = fresh()
  mock.keys[VK_UP] = true
  for _ = 1, 200 do s.update(0.003); mock.car.gas = mock.joypad.gas end
  check('no false leak', mock.connected['KeyDrive.Live.v11'].leak == false)
end

-- 13. Fast corner: 200 km/h, rear axle already at the limit sideways (ndSlip from cornering, wheels turning at road
-- speed). Pressing the throttle must not send full power.
do
  local s = fresh()
  local c = mock.car
  c.gear = 4
  c.localVelocity.z = 55
  c.speedKmh = 198
  mock.joypad.gForces.x = 1.4
  for i = 0, 3 do c.wheels[i].angularSpeed = 55 / 0.32 end
  for i = 2, 3 do c.wheels[i].ndSlip = 1.15 end
  mock.keys[VK_UP] = true
  local maxGas = 0
  for _ = 1, math.floor(1.5 / 0.003) do
    s.update(0.003)
    if mock.joypad.gas > maxGas then maxGas = mock.joypad.gas end
  end
  check('fast corner at the limit: throttle held back smoothly', maxGas < 0.8, maxGas)
  for i = 2, 3 do c.wheels[i].ndSlip = 0.5 end
  mock.joypad.gForces.x = 0
  run(s, 1.5, 0.003)
  check('fast corner: throttle comes back when grip returns', mock.joypad.gas > 0.95, mock.joypad.gas)
end

-- 14. Recorder: rolling log, incident file after a crash, header and events.
do
  local s = fresh()
  local r = mock.load(CORE, 'module_render.lua')
  local c = mock.car
  c.speedKmh = 80
  c.localVelocity.z = 22
  mock.keys[VK_UP] = true
  for _ = 1, 11 * 60 do s.update(1 / 60); r.update(1 / 60) end
  local log = mock.saved['cfg/keydrive/keydrive-log.csv']
  check('log written', log ~= nil)
  if log then
    check('log meta line names the car and track', log:match('^# car=test_car track=test_track') ~= nil, log:match('^[^\n]+'))
    local header = log:match('^#[^\n]*\n([^\n]+)')
    check('log header', header:find('key_gas', 1, true) and header:find('nd_rl', 1, true) and header:find('events', 1, true))
    local _, rows = log:gsub('\n', '')
    check('log has ~40 Hz rows (10 s)', rows > 380 and rows < 420, rows)
    check('log rows have every column', select(2, log:match('\n([^\n]+)$'):gsub(',', '')) == select(2, header:gsub(',', '')))
  end
  -- physics core not running (replay, AI, pause): the car moves but the live values are frozen -> no rows
  do
    local _, before = (mock.saved['cfg/keydrive/keydrive-log.csv'] or ''):gsub('\n', '')
    for _ = 1, 11 * 60 do r.update(1 / 60) end
    local _, after = (mock.saved['cfg/keydrive/keydrive-log.csv'] or ''):gsub('\n', '')
    check('no rows while the physics core is stale', after <= before + 8, before .. ' -> ' .. after)
  end
  c.collisionDepth = 0.2
  for _ = 1, 10 do s.update(1 / 60); r.update(1 / 60) end
  c.collisionDepth = 0
  for _ = 1, 4 * 60 do s.update(1 / 60); r.update(1 / 60) end
  local inc = mock.saved['cfg/keydrive/keydrive-incident-1.csv']
  check('incident file after a crash', inc ~= nil)
  check('crash flagged in events', inc and inc:find('CRASH', 1, true) ~= nil)
  mock.saved['cfg/keydrive/keydrive-incident-2.csv'] = nil
  c.collisionDepth = 0.2
  for _ = 1, 4 * 60 do s.update(1 / 60); r.update(1 / 60) end
  check('incident cooldown', mock.saved['cfg/keydrive/keydrive-incident-2.csv'] == nil)

  -- A missing car field stops the recorder instead of breaking the overlay.
  mock.reset()
  s = mock.load(CORE, 'assist.lua')
  r = mock.load(CORE, 'module_render.lua')
  mock.car.wheels[0] = { angularSpeed = 0, tyreRadius = 0.32, load = 3000 }
  setmetatable(mock.car, { __index = function (_, k) error('no field ' .. k) end })
  mock.car.wheelsOutside = nil
  mock.car.speedKmh = 50
  mock.keys[VK_UP] = true
  local ok = pcall(function () for _ = 1, 30 do s.update(1 / 60); r.update(1 / 60); r.drawUI() end end)
  check('missing field: overlay keeps running', ok)
end

-- 15. Brake: straight-line stop from 150 km/h with brakes strong enough to lock every wheel.
local function stop(dt, settings, seconds, abs)
  local s = fresh(settings)
  local c = mock.car
  c.absMode = abs or 0
  local m, r, J, mu = 1300, 0.32, 1.0, 1.2
  local N = { [0] = 4000, 4000, 2500, 2500 }
  local maxTorque = { [0] = 3000, 3000, 1600, 1600 } -- Nm per wheel at full brake (locks easily)
  local v = 150 / 3.6
  local w = {}
  for i = 0, 3 do w[i] = v / r end
  c.gear = 3
  local slips, t, dist, locked = {}, 0, 0, 0
  mock.keys[VK_DOWN] = true
  while v > 40 / 3.6 and t < seconds do
    c.localVelocity.z = v
    c.speedKmh = v * 3.6
    s.update(dt)
    local b = mock.joypad.brake
    c.brake = b
    local sub = 20
    local h = dt / sub
    for _ = 1, sub do
      local Ftot = 0
      for i = 0, 3 do
        local sr = (w[i] * r - v) / math.max(v, 3)
        local F = mu * N[i] * math.sin(1.6 * math.atan(9 * sr))
        Ftot = Ftot + F
        local tb = maxTorque[i] * b
        w[i] = w[i] + (-F * r - tb) / J * h
        if w[i] < 0 then w[i] = 0 end
      end
      v = v + Ftot / m * h
      dist = dist + v * h
    end
    for i = 0, 3 do
      local sr = (w[i] * r - v) / math.max(v, 3)
      c.wheels[i].angularSpeed = w[i]
      c.wheels[i].slipRatio = sr
      c.wheels[i].ndSlip = math.abs(sr) / 0.166
    end
    t = t + dt
    local nd = math.max(c.wheels[0].ndSlip, c.wheels[2].ndSlip)
    if t > 0.4 then
      slips[#slips + 1] = nd
      if nd > 2 then locked = locked + 1 end
    end
  end
  mock.keys[VK_DOWN] = nil
  local sum = 0
  for _, x in ipairs(slips) do sum = sum + x end
  local live = mock.connected['KeyDrive.Live.v11']
  return { t = t, dist = dist, slipMean = sum / math.max(1, #slips), lockedShare = locked / math.max(1, #slips),
    memory = live.brakeMemory, state = live.brakeState, peak = live.brakePeakRatio }
end

do
  local raw = stop(0.003, { BRAKE_LIMITER = 0 }, 10)
  local lim = stop(0.003, nil, 10)
  if os.getenv('KD_VERBOSE') then
    for _, x in ipairs({ raw, lim }) do
      print(string.format('stop t %.2f dist %.1f slip %.2f locked %.2f memory %.2f', x.t, x.dist, x.slipMean, x.lockedShare, x.memory))
    end
  end
  check('model: raw brake locks the wheels', raw.lockedShare > 0.8, raw.lockedShare)
  check('brake limiter: no locked wheels', lim.lockedShare < 0.02, lim.lockedShare)
  check('brake limiter: slip near the tyre peak', lim.slipMean > 0.7 and lim.slipMean < 1.15, lim.slipMean)
  check('brake limiter: shorter stop', lim.dist < raw.dist * 0.92, string.format('%.1f vs %.1f', lim.dist, raw.dist))
  check('brake limiter: remembers the lock point', lim.memory < 0.95, lim.memory)
  local other = stop(1 / 250, nil, 10)
  check('brake limiter independent of physics rate', math.abs(other.dist - lim.dist) / lim.dist < 0.03,
    string.format('%.1f vs %.1f', other.dist, lim.dist))
  local abs = stop(0.003, nil, 10, 1)
  check('car ABS on: KeyDrive leaves it alone', abs.state == 2 and abs.lockedShare > 0.8, abs.state)
  check('brake learns the peak slip ratio', math.abs(lim.peak - 0.166) < 0.02, lim.peak)
end

-- 16. Brake ramp, cap and trail-brake release.
do
  local s = fresh({ BRAKE_LIMITER = 0 })
  mock.keys[VK_DOWN] = true
  run(s, 0.1, 0.003)
  check('brake rises at 400 %/s', near(mock.joypad.brake, 0.4, 0.015), mock.joypad.brake)
  run(s, 1, 0.003)
  check('full brake', near(mock.joypad.brake, 1), mock.joypad.brake)
  mock.keys[VK_LEFT] = true
  run(s, 3, 0.003)
  local withSteer = mock.joypad.brake
  check('trail braking releases with steering', withSteer < 0.85 and withSteer > 0.4, withSteer)
  mock.keys[VK_LEFT] = nil
  mock.keys[VK_DOWN] = nil
  run(s, 0.2, 0.003)
  check('brake released', mock.joypad.brake == 0, mock.joypad.brake)
end

-- 17. Steering: single-track model at 100 km/h (front peak slip angle 7.2 deg, 15 deg road wheel lock). The rear has
-- a little more grip than the front (mild understeer at the limit, like most road and race cars).
local function corner(settings, seconds, init, keys)
  local s = fresh(settings)
  local c = mock.car
  local m, Iz, a, b, mu, g = 1300, 1900, 1.15, 1.45, 1.2, 9.81
  local L = a + b
  local Nf, Nr = m * g * b / L, m * g * a / L
  local peak = math.rad(7.2)
  local B = 1.49 / peak
  local vx, vy, r = 28, init and init.vy or 0, init and init.r or 0
  local dpu = 15
  local fronts, maxR, latSum, n, t = {}, 0, 0, 0, 0
  for k, v in pairs(keys or { [VK_RIGHT] = true }) do mock.keys[k] = v end
  local dt = 0.003
  while t < seconds do
    local delta = math.rad(mock.joypad.steer * dpu)
    local vf = vy + a * r
    local af = delta - math.atan2(vf, vx)
    local ar = -math.atan2(vy - b * r, vx)
    -- car state for the script
    c.localVelocity.z, c.localVelocity.x, c.speedKmh = vx, vy, vx * 3.6
    c.localAngularVelocity.y = r
    for i = 0, 1 do
      local w = c.wheels[i]
      w.look.x, w.look.z = math.sin(delta), math.cos(delta)
      w.velocity.x, w.velocity.z = vf, vx
      w.slipAngle, w.ndSlip, w.slipRatio = -math.deg(af), math.abs(af) / peak, 0
    end
    for i = 2, 3 do
      local w = c.wheels[i]
      w.velocity.x, w.velocity.z = vy - b * r, vx
      w.slipAngle, w.ndSlip, w.slipRatio = -math.deg(ar), math.abs(ar) / peak, 0
      w.angularSpeed = vx / 0.32
    end
    for i = 0, 1 do c.wheels[i].angularSpeed = vx / 0.32 end
    s.update(dt)
    local sub, h = 10, dt / 10
    for _ = 1, sub do
      vf = vy + a * r
      af = delta - math.atan2(vf, vx)
      ar = -math.atan2(vy - b * r, vx)
      local Ff = mu * Nf * math.sin(1.6 * math.atan(B * af))
      local Fr = mu * 1.12 * Nr * math.sin(1.6 * math.atan(B * ar))
      local ay = (Ff * math.cos(delta) + Fr) / m
      vy = vy + (ay - vx * r) * h
      r = r + (a * Ff * math.cos(delta) - b * Fr) / Iz * h
    end
    t = t + dt
    if t > seconds / 2 then
      fronts[#fronts + 1] = math.abs(af) / peak
      latSum = latSum + vx * r
      n = n + 1
    end
    if math.abs(r) > maxR then maxR = math.abs(r) end
  end
  for k in pairs(keys or { [VK_RIGHT] = true }) do mock.keys[k] = nil end
  local sum = 0
  for _, x in ipairs(fronts) do sum = sum + x end
  return { front = sum / #fronts, lat = latSum / n, r = r, vy = vy, maxR = maxR,
    live = mock.connected['KeyDrive.Live.v11'] }
end

do
  local raw = corner({ STEER_LIMIT_STRENGTH = 0, COUNTERSTEER_ASSIST = 0 }, 4)
  local lim = corner({ STEER_LIMIT_STRENGTH = 100, STEER_TARGET = 100 }, 4)
  local soft = corner({ STEER_LIMIT_STRENGTH = 100 }, 4)
  check('steer limit at 120 % only stops clear overdriving', soft.front > 1.0 and soft.front < 1.35, soft.front)
  local default = corner(nil, 4)
  check('default: no steering intervention at all', default.live.steerState ~= 3 and default.live.steerState ~= 4
    and math.abs(default.front - raw.front) < 0.01, default.front)
  if os.getenv('KD_VERBOSE') then
    for _, x in ipairs({ raw, lim }) do
      print(string.format('corner front %.2f lat %.2f r %.3f peak %.2f dpu %.2f', x.front, x.lat, x.r, x.live.alphaPeak, x.live.degPerUnit))
    end
  end
  check('model: unlimited key steering overdrives the fronts', raw.front > 1.5, raw.front)
  check('steer limit keeps the fronts near their peak', lim.front > 0.8 and lim.front < 1.1, lim.front)
  check('steer limit: more cornering force', math.abs(lim.lat) >= math.abs(raw.lat) * 0.98,
    string.format('%.2f vs %.2f', lim.lat, raw.lat))
  check('steer: learns the peak slip angle', math.abs(lim.live.alphaPeak - 7.2) < 0.5, lim.live.alphaPeak)
  check('steer: learns degrees per unit', math.abs(lim.live.degPerUnit - 15) < 1, lim.live.degPerUnit)

  -- A slide with no keys: the rear has stepped out (car rotating right, front axle moving left of the nose).
  local slide = { vy = -5, r = 0.9 }
  local free = corner({ COUNTERSTEER_ASSIST = 0 }, 2, slide, {})
  local cs = corner({ COUNTERSTEER_ASSIST = 100, STEER_LIMIT_STRENGTH = 100 }, 2, slide, {})
  if os.getenv('KD_VERBOSE') then
    print(string.format('slide free r %.3f vy %.2f | cs r %.3f vy %.2f', free.r, free.vy, cs.r, cs.vy))
  end
  check('countersteer catches the slide better', math.abs(cs.r) < math.abs(free.r) * 0.8 or math.abs(cs.vy) < math.abs(free.vy) * 0.8,
    string.format('r %.3f vs %.3f', cs.r, free.r))
  check('countersteer state reported', cs.live.steerState >= 2)
end

-- 18. Steering keys: both keys hold or return; reversing gets plain keys.
do
  local s = fresh()
  mock.keys[VK_LEFT] = true
  run(s, 0.2, 0.003)
  local held = mock.joypad.steer
  mock.keys[VK_RIGHT] = true
  run(s, 0.3, 0.003)
  check('both keys hold by default', near(mock.joypad.steer, held), mock.joypad.steer)
  s = fresh({ STEER_BOTH_KEYS = 1 })
  mock.keys[VK_LEFT] = true
  run(s, 0.2, 0.003)
  mock.keys[VK_RIGHT] = true
  run(s, 1, 0.003)
  check('both keys return when set', mock.joypad.steer == 0, mock.joypad.steer)
  mock.keys[VK_LEFT], mock.keys[VK_RIGHT] = nil, nil
  s = fresh({ STEER_STYLE = 1, STEER_SPEED_CURVE = '0:100 100:50' })
  mock.keys[VK_RIGHT] = true
  run(s, 0.5, 0.003)
  check('steer speed curve at standstill', near(mock.joypad.steer, 0.5, 0.01), mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil
end

-- 19. Recorder falls back to the script folder when the logs folder cannot be written.
do
  local s = fresh()
  local r = mock.load(CORE, 'module_render.lua')
  local realSave = io.save
  io.save = function (path, data)
    if path:sub(1, 4) == 'cfg/' then return false end
    return realSave(path, data)
  end
  mock.car.speedKmh, mock.car.localVelocity.z = 80, 22
  mock.keys[VK_UP] = true
  for _ = 1, 11 * 60 do s.update(1 / 60); r.update(1 / 60) end
  io.save = realSave
  mock.keys[VK_UP] = nil
  check('log falls back to the script folder', mock.saved['KD/keydrive-log.csv'] ~= nil)
end

-- 20. Default steering = copy of AC's keyboard filter (measured): outward STEERING_SPEED * speed factor, back to the
-- centre STEER_RESET_SPEED * STEERING_SPEED, other side STEERING_OPPOSITE_DIRECTION_SPEED * STEERING_SPEED.
do
  mock.reset()
  mock.controls.KEYBOARD.STEERING_SPEED = '2'
  mock.controls.KEYBOARD.STEERING_OPPOSITE_DIRECTION_SPEED = '2.5'
  mock.controls.KEYBOARD.STEER_RESET_SPEED = '1.5'
  local s = mock.load(CORE, 'assist.lua')
  mock.car.speedKmh, mock.car.localVelocity.z = 145, 40
  mock.keys[VK_RIGHT] = true
  run(s, 0.3, 0.003)
  check('AC copy: outward 2 * 0.236 /s at 145 km/h', near(mock.joypad.steer, 0.3 * 2 * 0.236, 0.005), mock.joypad.steer)
  mock.car.speedKmh, mock.car.localVelocity.z = 55, 15
  run(s, 0.3, 0.003)
  check('AC copy: faster at 55 km/h', near(mock.joypad.steer, 0.3 * 2 * 0.236 + 0.3 * 2 * 0.6, 0.01), mock.joypad.steer)
  local before = mock.joypad.steer
  mock.keys[VK_RIGHT] = nil
  run(s, 0.05, 0.003)
  check('AC copy: back to centre at RESET * SPEED', near(mock.joypad.steer, before - 0.05 * 3, 0.01), mock.joypad.steer)
  local before2 = mock.joypad.steer
  mock.keys[VK_LEFT] = true
  run(s, 0.03, 0.003)
  check('AC copy: other side at OPPOSITE * SPEED', near(mock.joypad.steer, before2 - 0.03 * 5, 0.01), mock.joypad.steer)
  mock.keys[VK_LEFT] = nil
end

-- 21. Torque peak at 5300 rpm (like the user's car): the memory per gear and rpm band makes the second launch
-- spin much less than the first, by easing off just before the revs reach the band where it spun. Since v0.11 the
-- memory is off by default (TRACTION_MEMORY 0) and in this launch it does not act either way (identical results), so
-- this now guards the launch itself with the default settings. KNOWN TRADE-OFF of v0.12 (less low-gear pulsing, gentler
-- cuts): v0.11.1 launched clean (time over 1.3x 0 % / 0 %, max ndSlip 1.06 / 1.26), v0.12 spins briefly (2.2 % / 3.2 %,
-- max 1.43 / 1.57) at the same speed. The bounds below allow that much and no more.
do
  local s = fresh()
  local c = mock.car
  local m, r, J, N, mu, G = 1300, 0.32, 8, 3500, 1.1, 18
  local function torque(rpm)
    if rpm > 7500 then return 0 end
    return 1700 + 2200 * math.exp(-((rpm - 5300) / 900) ^ 2)
  end
  local function launch()
    local v, w, spin, n, maxNd = 0, 0, 0, 0, 0
    mock.keys[VK_UP] = nil
    for _ = 1, 60 do s.update(0.003) end
    mock.keys[VK_UP] = true
    for _ = 1, 1000 do
      c.rpm = math.max(900, w * G * 60 / (2 * math.pi))
      c.localVelocity.z, c.speedKmh = v, v * 3.6
      s.update(0.003)
      local g = mock.joypad.gas
      for _ = 1, 20 do
        local rpm = math.max(900, w * G * 60 / (2 * math.pi))
        local sr = (w * r - v) / math.max(v, 3)
        local F = mu * N * math.sin(1.6 * math.atan(9 * sr))
        v = v + 2 * F / m * 0.00015
        w = w + (g * torque(rpm) / 2 - F * r) / J * 0.00015
        if w < 0 then w = 0 end
      end
      local srNow = (w * r - v) / math.max(v, 3)
      local nd = math.abs(srNow) / 0.166
      for i = 2, 3 do c.wheels[i].angularSpeed = w; c.wheels[i].ndSlip = nd; c.wheels[i].slipRatio = srNow end
      for i = 0, 1 do c.wheels[i].angularSpeed = v / r end
      n = n + 1
      if nd > 1.3 then spin = spin + 1 end
      if nd > maxNd then maxNd = nd end
      if os.getenv('KD_TRACE') and n % 25 == 0 then
        local l = mock.connected['KeyDrive.Live.v11']
        print(string.format('  t %.2f rpm %4.0f gas %.2f cap %.2f mem %.2f nd %.2f', n * 0.003, c.rpm, g, l.tcLimit, l.tcMemory, nd))
      end
    end
    mock.keys[VK_UP] = nil
    return spin / n, maxNd, v
  end
  local s1, m1, v1 = launch()
  local s2, m2, v2 = launch()
  if os.getenv('KD_VERBOSE') then
    print(string.format('rpm launch 1: spin %.2f max %.1f v %.1f | 2: spin %.2f max %.1f v %.1f', s1, m1, v1, s2, m2, v2))
  end
  check('launches: at most 4 % of the time over 1.3x the peak (v0.12: 2.2 / 3.2 %)', s1 <= 0.04 and s2 <= 0.04,
    string.format('%.3f / %.3f', s1, s2))
  check('launches: peak slip at most 1.65x (v0.12: 1.43 / 1.57; USER bound 1.5 on the simulator)', m1 <= 1.65 and m2 <= 1.65,
    string.format('%.2f / %.2f', m1, m2))
  check('second launch not slower', v2 > v1 * 0.97, string.format('%.1f vs %.1f', v2, v1))
end

-- 22. STEER_STYLE 0: when AC computes the keyboard steering itself, KeyDrive passes it through untouched.
do
  local s = fresh()
  mock.car.speedKmh, mock.car.localVelocity.z = 100, 28
  mock.keys[VK_RIGHT] = true
  local acSteer = 0
  for _ = 1, 200 do
    acSteer = math.min(1, acSteer + 0.004)   -- AC's own (different) steering curve
    mock.joypad.steer = acSteer              -- AC fills the joypad state before the script runs
    s.update(0.003)
  end
  local live = mock.connected['KeyDrive.Live.v11']
  check('AC steering detected', live.steerFromAC == true, live.acSteerVotes)
  check('AC steering passed through untouched', mock.joypad.steer == acSteer, mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil

  -- AC sends nothing (the state keeps what KeyDrive wrote): KeyDrive steers.
  s = fresh()
  mock.car.speedKmh, mock.car.localVelocity.z = 100, 28
  mock.keys[VK_RIGHT] = true
  run(s, 0.6, 0.003)
  check('no AC steering: KeyDrive steers', mock.connected['KeyDrive.Live.v11'].steerFromAC == false and mock.joypad.steer > 0.3,
    mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil
end

-- 23. KeyDriveConfig reference recorder (normal keyboard mode): records keys and AC's own steering.
do
  mock.reset()
  mock.controls.HEADER = { INPUT_METHOD = 'KEYBOARD' }
  mock.controls.KEYBOARD.STEERING_SPEED = '1.75'
  local app = mock.load(APP, 'KeyDriveConfig.lua')
  local c = mock.car
  c.speedKmh = 90
  mock.keys[VK_LEFT] = true
  for i = 1, 11 * 60 do
    c.steer = -math.min(120, i * 2)
    app.update(1 / 60)
  end
  app.windowReference(1 / 60)
  local f = mock.saved['cfg/keydrive/ac-reference.csv']
  check('reference file written', f ~= nil)
  check('reference meta line', f and f:find('# input=KEYBOARD', 1, true) ~= nil)
  check('reference rows', f and select(2, f:gsub('\n', '')) > 380, f and select(2, f:gsub('\n', '')))
  check('reference records the key', f and f:find('\n[%d%.]+,0,0,1,0,', 1) ~= nil)
  mock.keys[VK_LEFT] = nil
end

-- 24. A spin in a forward gear: the car moves sideways/backwards relative to its nose (localVelocity.z < 0).
-- Traction must stay on (it used to switch off and send full throttle into the spin).
do
  local s = fresh()
  local c = mock.car
  c.gear, c.speedKmh, c.localVelocity.z = 1, 40, -3
  for i = 2, 3 do c.wheels[i].ndSlip = 8; c.wheels[i].angularSpeed = 30 end
  mock.keys[VK_UP] = true
  run(s, 1.5, 0.003)
  check('spin in a forward gear: throttle held low', mock.joypad.gas < 0.45, mock.joypad.gas)
  mock.keys[VK_UP] = nil
  c.gear = -1
  s = fresh()
  mock.car.gear, mock.car.localVelocity.z = -1, -2
  for i = 2, 3 do mock.car.wheels[i].ndSlip = 8 end
  mock.keys[VK_UP] = true
  run(s, 1.5, 0.003)
  check('reverse gear: plain throttle', mock.joypad.gas > 0.95, mock.joypad.gas)
  mock.keys[VK_UP] = nil
end

-- 25. STEER_RATE scales AC's keyboard steering rates; STEER_SPEED_SLOWDOWN 0 keeps the standstill rate at any speed.
do
  local s = fresh({ STEER_RATE = 200 })
  mock.car.speedKmh, mock.car.localVelocity.z = 145, 40
  mock.keys[VK_RIGHT] = true
  run(s, 0.2, 0.003)
  check('STEER_RATE 200: twice AC outward rate', near(mock.joypad.steer, 0.2 * 1.75 * 0.236 * 2, 0.005), mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil
  local before = mock.joypad.steer
  run(s, 0.012, 0.003)
  check('STEER_RATE 200: twice AC reset rate', near(mock.joypad.steer, before - 0.012 * 1.8 * 1.75 * 2, 0.004), mock.joypad.steer)
  s = fresh({ STEER_SPEED_SLOWDOWN = 0 })
  mock.car.speedKmh, mock.car.localVelocity.z = 145, 40
  mock.keys[VK_RIGHT] = true
  run(s, 0.2, 0.003)
  check('SLOWDOWN 0: standstill rate at 145 km/h', near(mock.joypad.steer, 0.2 * 1.75 * 0.74, 0.005), mock.joypad.steer)
  s = fresh({ STEER_SPEED_SLOWDOWN = 50 })
  mock.car.speedKmh, mock.car.localVelocity.z = 145, 40
  mock.keys[VK_RIGHT] = true
  run(s, 0.2, 0.003)
  check('SLOWDOWN 50: half of AC slowdown', near(mock.joypad.steer, 0.2 * 1.75 * (0.74 - 0.5 * (0.74 - 0.236)), 0.005),
    mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil
end

-- 26. KeyDrive Keyboard Test app (input method variant A): drives through ac.overrideCarControls only in keyboard
-- mode, replaces pedals (combineAxis = false), measures the car against what it wrote, and hands everything back.
do
  local function window(app)
    mock.texts = {}
    app.windowMain(1 / 60)
    return table.concat(mock.texts, '\n')
  end
  local function frames(app, n, echo)
    for _ = 1, n do
      app.update(1 / 60)
      local o = mock.override
      if o and echo then
        local f = o.fields
        mock.car.gas = echo(f.gas)
        mock.car.brake = f.brake
        if f.steer ~= math.huge then mock.car.steer = f.steer * mock.car.steerLock end
      end
    end
  end

  -- Gamepad mode: refuses, never touches the controls.
  mock.reset()
  mock.controls.HEADER = { INPUT_METHOD = 'X360' }
  local app = mock.load(KBTEST, 'KeyDriveKeyboardTest.lua')
  mock.click['Zapnout test'] = true
  local t = window(app)
  frames(app, 30)
  check('kb test: refused outside keyboard mode', mock.overrideCalls == 0 and t:find('není Keyboard', 1, true) ~= nil, t)

  -- Keyboard mode: drives, pedals replaced, AC copy steering.
  mock.reset()
  mock.controls.HEADER = { INPUT_METHOD = 'KEYBOARD' }
  app = mock.load(KBTEST, 'KeyDriveKeyboardTest.lua')
  local c = mock.car
  c.speedKmh, c.localVelocity.z = 145, 40
  frames(app, 5)
  check('kb test: no override before switching on', mock.overrideCalls == 0)
  mock.click['Zapnout test'] = true
  window(app)
  check('kb test: override taken on switch-on', mock.overrideCalls == 1 and mock.override ~= nil)
  mock.keys[VK_UP] = true
  mock.keys[VK_RIGHT] = true
  local same = function (g) return g end
  frames(app, 30, same) -- 0.5 s
  local f = mock.override.fields
  check('kb test: combineAxis off while driving', f.combineAxis == false)
  check('kb test: gas ramps 1.5 /s', near(f.gas, 0.75, 0.03), f.gas)
  check('kb test: steering faster than AC at 145 km/h (slowdown 0)', near(f.steer, 0.5 * 1.75 * 0.74, 0.01), f.steer)
  check('kb test: KERS left alone', f.kers == -1 and f.mguhMode == -1)
  frames(app, 120, same)
  t = window(app)
  check('kb test: equal values reported as matching', t:find('Plyn: SEDÍ', 1, true) ~= nil and
    t:find('Řízení: SEDÍ', 1, true) ~= nil, t)
  check('kb test: fast steering, equal values not reported as different',
    t:find('Řízení rychleji než AC (nad 100 km/h): NESEDÍ', 1, true) == nil, t)

  -- AC applies its own keyboard steering filter after the override: the fast-steering check catches it.
  mock.click['Vynulovat měření'] = true
  window(app)
  mock.keys[VK_RIGHT] = nil
  frames(app, 60, same)
  mock.keys[VK_LEFT] = true
  local acSteer = mock.car.steer / 270
  for _ = 1, 40 do
    app.update(1 / 60)
    local fl = mock.override.fields
    mock.car.gas, mock.car.brake = fl.gas, fl.brake
    -- AC's filter: towards the written value at most 1.75 * 0.236 /s
    local step = 1.75 * 0.236 / 60
    acSteer = acSteer + math.max(-step, math.min(step, fl.steer - acSteer))
    mock.car.steer = acSteer * 270
  end
  t = window(app)
  check('kb test: AC steering filter after the override reported', t:find('Řízení rychleji než AC (nad 100 km/h): NESEDÍ', 1, true) ~= nil, t)
  mock.keys[VK_LEFT] = nil
  mock.keys[VK_RIGHT] = true

  -- AC changes the throttle after the override: reported.
  mock.click['Vynulovat měření'] = true
  window(app)
  frames(app, 120, function (g) return g * 0.5 end)
  t = window(app)
  check('kb test: different throttle reported', t:find('Plyn: NESEDÍ', 1, true) ~= nil, t)

  -- Mouse steering on: refused.
  mock.controls.KEYBOARD.MOUSE_STEER = '1'
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  frames(app, 2)
  check('kb test: mouse steering switches the test off', f.steer == math.huge and f.combineAxis == true)
  mock.controls.KEYBOARD.MOUSE_STEER = '0'
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  mock.click['Zapnout test'] = true
  window(app)
  frames(app, 30, same)

  -- Input method changed to gamepad mid-test: hands the car back.
  mock.controls.HEADER.INPUT_METHOD = 'X360'
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  frames(app, 2)
  check('kb test: gamepad mode switches the test off', f.steer == math.huge and f.combineAxis == true and f.gas == 0
    and f.clutch == 1, tostring(f.steer) .. ' ' .. tostring(f.combineAxis))

  -- Switch off by the button, release on unload, CSV saved.
  mock.controls.HEADER.INPUT_METHOD = 'KEYBOARD'
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  mock.click['Zapnout test'] = true
  window(app)
  frames(app, 30, same)
  check('kb test: back on', f.combineAxis == false and f.gas > 0.3, f.gas)
  mock.release()
  check('kb test: release hands everything back', f.steer == math.huge and f.combineAxis == true and f.gas == 0
    and f.brake == 0 and f.handbrake == 0 and f.clutch == 1)
  local csv = mock.saved['cfg/keydrive/kb-test.csv']
  check('kb test: CSV saved with meta line', csv ~= nil and csv:find('# input=KEYBOARD', 1, true) ~= nil)
  check('kb test: CSV has rows', csv and select(2, csv:gsub('\n', '')) > 30, csv and select(2, csv:gsub('\n', '')))
  mock.keys[VK_UP], mock.keys[VK_RIGHT] = nil, nil

  -- Old CSP without combineAxis: refuses instead of mixing AC's keyboard pedals in.
  mock.reset()
  mock.controls.HEADER = { INPUT_METHOD = 'KEYBOARD' }
  mock.noCombineAxis = true
  app = mock.load(KBTEST, 'KeyDriveKeyboardTest.lua')
  mock.click['Zapnout test'] = true
  window(app)
  frames(app, 5)
  t = window(app)
  check('kb test: no combineAxis -> test off with a message', t:find('combineAxis', 1, true) ~= nil and
    mock.override.fields.steer == math.huge and mock.override.fields.gas == 0, t)
end

-- 27. Core purity: core/*.lua run in a bare Lua 5.1 environment (no ac, ui, vec2, math.clamp ...), from plain tables,
-- so the simulator and an external program can run them. Any unknown global is an error.
do
  local STD = { 'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'select', 'setmetatable', 'getmetatable',
    'tonumber', 'tostring', 'type', 'unpack', 'rawget', 'rawset', 'xpcall' }
  local bareMath = {}
  for k, v in pairs(math) do if k ~= 'clamp' then bareMath[k] = v end end
  local env = { math = bareMath, string = string, table = table }
  for _, k in ipairs(STD) do env[k] = _G[k] end
  local loaded = {}
  env.require = function (name)
    if loaded[name] then return loaded[name] end
    assert(name:sub(1, 5) == 'core/', 'core requires non-core module ' .. name)
    local chunk = assert(loadfile(CORE .. '/' .. name .. '.lua'))
    setfenv(chunk, env)
    loaded[name] = chunk()
    return loaded[name]
  end
  setmetatable(env, { __index = function (_, k) error('core uses a non-standard global: ' .. tostring(k), 2) end,
    __newindex = function (_, k) error('core sets a global: ' .. tostring(k), 2) end })
  local ok, err = pcall(function ()
    local Throttle, Steering = env.require('core/throttle'), env.require('core/steering')
    local function v3(x, y, z) return { x = x, y = y, z = z } end
    local wheels = {}
    for i = 0, 3 do
      wheels[i] = { ndSlip = 0.5, load = 3000, angularSpeed = 60, tyreRadius = 0.32, slipRatio = 0.01, slipAngle = 1,
        look = v3(0, 0, 1), velocity = v3(0.02, 0, 20) }
    end
    local carState = { gear = 2, rpm = 5200, speedKmh = 72, localVelocity = v3(0, 0, 20), tractionType = 0,
      wheels = wheels, look = v3(0, 0, 1), side = v3(1, 0, 0) }
    local tuned = env.require('core/tuned')
    local th = Throttle.new(tuned.throttle, tuned.traction) -- mode 2, the default the user drives
    local st = Steering.new({ LIMIT_STRENGTH = 1, COUNTERSTEER = 1 })
    th:configure(carState)
    st:configure(carState, 540, 18)
    local g, sOut
    for i = 1, 400 do
      wheels[2].ndSlip, wheels[3].ndSlip = i > 200 and 1.6 or 0.5, i > 200 and 1.6 or 0.5
      g = th:update(0.003, true, carState, 0.4, sOut or 0)
      sOut = st:update(0.003, false, true, carState)
    end
    return g, sOut
  end)
  check('core runs in a bare Lua environment', ok, err)
  -- two instances do not share state
  local Traction = dofile(CORE .. '/core/traction.lua')
  local a, b = Traction.new(), Traction.new({ K_DOWN = 9 })
  check('traction instances keep their own parameters', a.p.K_DOWN == 2.5 and b.p.K_DOWN == 9 and a.memory ~= b.memory)
end

-- 28. Mode 2 regression (user's v0.10 logs): after a limit was learned, the cap must not stay pinned to
-- RETURN x memory while the tyres have plenty of grip (v0.10.0 held 0.55-0.64 for 6 s on a straight), and a limit
-- crossed in a corner (high lateral slip) must not be remembered at all. (v0.12.0 set: core/tuned.lua moves on.)
do
  local Throttle = dofile(CORE .. '/core/throttle.lua')
  local tuned = dofile(here .. '/fixtures/tuned_v0120.lua')
  local function v3(x, y, z) return { x = x, y = y, z = z } end
  local function newCar()
    local wheels = {}
    for i = 0, 3 do
      wheels[i] = { ndSlip = 0.2, load = 3000, angularSpeed = 100, tyreRadius = 0.33, slipRatio = 0.02, slipAngle = 0.5,
        look = v3(0, 0, 1), velocity = v3(0, 0, 33) }
    end
    return { gear = 3, rpm = 5200, speedKmh = 120, localVelocity = v3(0, 0, 33), tractionType = 0, wheels = wheels }
  end
  local function setRear(c, nd, sr, sa) for i = 2, 3 do c.wheels[i].ndSlip, c.wheels[i].slipRatio, c.wheels[i].slipAngle = nd, sr, sa end end
  -- straight: spin then grip -> limit learned; then low slip: the throttle must come back
  local tp = {}
  for k, v in pairs(tuned.traction) do tp[k] = v end
  tp.FORGET_RATE = 0 -- isolate the return path from the forgetting
  tp.MEM = 1         -- memory on (TRACTION_MEMORY = 1; the tuned v0.11 set runs without it)
  local th = Throttle.new(tuned.throttle, tp)
  local c = newCar()
  th:configure(c)
  for _ = 1, 400 do setRear(c, 0.3, 0.035, 0.3); th:update(0.003, true, c, 0, 0) end
  for _ = 1, 60 do setRear(c, 2.0, 0.25, 0.3); th:update(0.003, true, c, 0, 0) end
  local learned = th.traction.memoryNow
  for _ = 1, math.floor(1.5 / 0.003) do setRear(c, 0.2, 0.024, 0.3); th:update(0.003, true, c, 0, 0) end
  check('mode 2: a limit was learned on the straight spin', learned < 0.99, learned)
  check('mode 2: throttle back to full 1.5 s after grip returned (no pin)', th.out > 0.97, th.out)
  -- corner: high lateral slip, the longitudinal part crosses its small target -> cut, but nothing learned
  local tp2 = {}
  for k, v in pairs(tuned.traction) do tp2[k] = v end
  tp2.MEM = 1
  local th2 = Throttle.new(tuned.throttle, tp2)
  local c2 = newCar()
  th2:configure(c2)
  for _ = 1, 400 do setRear(c2, 0.7, 0.03, 4); th2:update(0.003, true, c2, 1.5, 0) end
  for _ = 1, 60 do setRear(c2, 0.9, 0.08, 4); th2:update(0.003, true, c2, 1.5, 0) end
  check('mode 2: corner crossing teaches no limit', th2.traction.memoryNow > 0.99, th2.traction.memoryNow)
  check('mode 2: corner cut keeps at least the corner floor', th2.traction.limit >= 0.19, th2.traction.limit)
end

-- 30. Mode 2 RET_HOLD (v0.11.1): after a cut caused by a real overshoot the cap does not climb straight back into
-- the next one (v0.11.0 pulsed at ~0.35 s in 1st/2nd gear); it holds for RET_HOLD while the slip stays above
-- RET_LOW x target, then recovers as before; with the slip low it recovers at once. (v0.12.0 set, frozen.)
do
  local Throttle = dofile(CORE .. '/core/throttle.lua')
  local tuned = dofile(here .. '/fixtures/tuned_v0120.lua')
  local function v3(x, y, z) return { x = x, y = y, z = z } end
  local function newCar()
    local wheels = {}
    for i = 0, 3 do
      wheels[i] = { ndSlip = 0.2, load = 3000, angularSpeed = 60, tyreRadius = 0.33, slipRatio = 0.02, slipAngle = 0.5,
        look = v3(0, 0, 1), velocity = v3(0, 0, 20) }
    end
    return { gear = 2, rpm = 5000, speedKmh = 72, localVelocity = v3(0, 0, 20), tractionType = 0, wheels = wheels }
  end
  local function setRear(c, nd, sr) for i = 2, 3 do c.wheels[i].ndSlip, c.wheels[i].slipRatio, c.wheels[i].slipAngle = nd, sr, 0.3 end end
  local function run(hold, afterRatio)
    local tp = {}
    for k, v in pairs(tuned.traction) do tp[k] = v end
    tp.RET_HOLD = hold
    local th = Throttle.new(tuned.throttle, tp)
    local c = newCar()
    th:configure(c)
    for _ = 1, 400 do setRear(c, 0.3, 0.04); th:update(0.003, true, c, 0, 0) end
    for _ = 1, 30 do setRear(c, 1.6, 0.2); th:update(0.003, true, c, 0, 0) end -- real overshoot: cut
    for _ = 1, 15 do setRear(c, 0.6, afterRatio); th:update(0.003, true, c, 0, 0) end
    local a0 = th.traction.A
    for _ = 1, 100 do setRear(c, 0.6, afterRatio); th:update(0.003, true, c, 0, 0) end
    local a1 = th.traction.A -- 0.3 s later
    for _ = 1, 200 do setRear(c, 0.6, afterRatio); th:update(0.003, true, c, 0, 0) end
    return a0, a1, th.traction.A -- and 0.9 s later
  end
  check('tuned set holds after a cut', (tuned.traction.RET_HOLD or 0) > 0)
  local h0, h1, h2 = run(tuned.traction.RET_HOLD, 0.07) -- slip ~0.58 of the peak: above RET_LOW x target
  local n0, n1 = run(0, 0.07)
  check('RET_HOLD: no climb right after an overshoot', h1 - h0 < 0.01, string.format('%.3f -> %.3f', h0, h1))
  check('RET_HOLD off: climbs back at once (the old cycle)', n1 - n0 > 0.2, string.format('%.3f -> %.3f', n0, n1))
  check('RET_HOLD: recovers after the hold', h2 - h1 > 0.2, string.format('%.3f -> %.3f', h1, h2))
  local l0, l1 = run(tuned.traction.RET_HOLD, 0.03) -- slip ~0.25 of the peak: plenty of grip
  check('RET_HOLD: low slip recovers at once', l1 - l0 > 0.2, string.format('%.3f -> %.3f', l0, l1))
  -- lift and press again inside the window (slip still above RET_LOW x target): the throttle follows the key
  do
    local th = Throttle.new(tuned.throttle, tuned.traction)
    local c = newCar()
    th:configure(c)
    for _ = 1, 400 do setRear(c, 0.3, 0.04); th:update(0.003, true, c, 0, 0) end
    for _ = 1, 30 do setRear(c, 1.6, 0.2); th:update(0.003, true, c, 0, 0) end
    for _ = 1, 80 do setRear(c, 0.6, 0.07); th:update(0.003, false, c, 0, 0) end -- 0.24 s lift
    local out
    for _ = 1, 60 do setRear(c, 0.6, 0.07); out = th:update(0.003, true, c, 0, 0) end -- 0.18 s re-press
    check('RET_HOLD: a re-press inside the window follows the key', out > th.request - 0.02,
      string.format('out %.3f request %.3f', out, th.request))
  end
end

-- 29. TRACTION_KEY (default X) switches the traction control off and on while driving (burnout, spin on purpose).
do
  local VK_X = 88
  local function spinning()
    local c = mock.car
    c.gear, c.speedKmh, c.localVelocity.z = 1, 40, 11
    for i = 2, 3 do c.wheels[i].ndSlip = 8; c.wheels[i].slipRatio = 1; c.wheels[i].angularSpeed = 60 end
  end
  local s = fresh()
  spinning()
  mock.keys[VK_UP] = true
  run(s, 1.5, 0.003)
  local live = mock.connected['KeyDrive.Live.v11']
  check('switch: traction holds a spin back first', mock.joypad.gas < 0.45 and live.tcState ~= 5, mock.joypad.gas)
  mock.keys[VK_X] = true
  run(s, 0.3, 0.003) -- held: toggles once, not every step
  mock.keys[VK_X] = nil
  check('switch: off after one press', live.tcState == 5, live.tcState)
  check('switch: message shown', mock.messages[#mock.messages] == 'Hlídání prokluzu VYPNUTO', mock.messages[#mock.messages])
  local prev, maxRise = mock.joypad.gas, 0
  for _ = 1, 500 do s.update(0.003); maxRise = math.max(maxRise, mock.joypad.gas - prev); prev = mock.joypad.gas end
  check('switch off: full throttle into the spin', mock.joypad.gas > 0.95, mock.joypad.gas)
  check('switch off: throttle rises at the key ramp, no step', maxRise <= 1.2 * 0.003 + 1e-9, maxRise)
  mock.jump()
  run(s, 0.1, 0.003)
  check('switch: a teleport keeps it off', live.tcState == 5, live.tcState)
  run(s, 1.0, 0.003)
  mock.keys[17], mock.keys[VK_X] = true, true -- Ctrl+X is some other shortcut
  run(s, 0.1, 0.003)
  mock.keys[17] = nil                         -- Ctrl released first, X still held: still no toggle
  run(s, 0.1, 0.003)
  mock.keys[VK_X] = nil
  check('switch: Ctrl+X ignored (also when Ctrl is released first)', live.tcState == 5, live.tcState)
  mock.keys[18], mock.keys[VK_X] = true, true
  run(s, 0.1, 0.003)
  mock.keys[18], mock.keys[VK_X] = nil, nil
  check('switch: Alt+X ignored', live.tcState == 5, live.tcState)
  live.keyboardCaptured = true -- typing an x in the chat
  mock.keys[VK_X] = true
  run(s, 0.05, 0.003)
  mock.keys[VK_X] = nil
  live.keyboardCaptured = false
  check('switch: ignored while a text field has the keyboard', live.tcState == 5, live.tcState)
  sim.isWindowForeground = false
  mock.keys[VK_X] = true
  run(s, 0.05, 0.003)
  mock.keys[VK_X] = nil
  sim.isWindowForeground = nil
  s.update(0.003) -- key up seen
  check('switch: ignored with AC in the background', live.tcState == 5, live.tcState)
  mock.keys[VK_X] = true
  s.update(0.003)
  mock.keys[VK_X] = nil
  check('switch: on again with the next press', live.tcState ~= 5 and mock.messages[#mock.messages] == 'Hlídání prokluzu zapnuto',
    live.tcState)
  prev = mock.joypad.gas
  local maxFall = 0
  for _ = 1, 500 do s.update(0.003); maxFall = math.max(maxFall, prev - mock.joypad.gas); prev = mock.joypad.gas end
  check('switch on: the spin is caught again', mock.joypad.gas < 0.5, mock.joypad.gas)
  check('switch on: smooth cut, no step', maxFall <= 4.05 * 0.003, maxFall)
  mock.keys[VK_UP] = nil

  -- the badge shows even with the diagnostics hidden
  s = fresh({ SHOW_DIAGNOSTICS = 0 })
  mock.keys[VK_X] = true
  s.update(0.003)
  mock.keys[VK_X] = nil
  live = mock.connected['KeyDrive.Live.v11']
  local r = mock.load(CORE, 'module_render.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  mock.texts = {}
  r.update(0.016)
  r.drawUI()
  check('switch: badge drawn with the diagnostics hidden', mock.drawUIActive == true
    and mock.texts[1] == 'KeyDrive: hlídání prokluzu VYP' and #mock.texts == 1, tostring(mock.texts[1]))

  -- TRACTION = 0 in the settings: the key does nothing
  s = fresh({ TRACTION = 0 })
  mock.keys[VK_X] = true
  s.update(0.003)
  check('switch: no effect with TRACTION off', mock.connected['KeyDrive.Live.v11'].tcState == 1 and #mock.messages == 0)
  mock.keys[VK_X] = nil

  -- a driving key is refused; other key formats
  s = fresh({ TRACTION_KEY = '0x26' })
  check('switch: a driving key is refused with a message', #mock.messages == 1)
  mock.keys[VK_UP] = true
  run(s, 0.1, 0.003)
  check('switch: gas key does not toggle', mock.connected['KeyDrive.Live.v11'].tcState ~= 5)
  mock.keys[VK_UP] = nil
  s = fresh({ TRACTION_KEY = '0' })
  mock.keys[VK_X], mock.keys[48] = true, true
  s.update(0.003)
  check('switch: 0 = no key (neither X nor the digit 0)', mock.connected['KeyDrive.Live.v11'].tcState ~= 5)
  mock.keys[VK_X], mock.keys[48] = nil, nil

  -- a controls change that makes the switch key a driving key while traction is off: back on, never stuck off
  s = fresh()
  mock.keys[VK_X] = true
  s.update(0.003)
  mock.keys[VK_X] = nil
  check('switch: off before the controls change', mock.connected['KeyDrive.Live.v11'].tcState == 5)
  mock.controls.GEARUP = { KEY = '0x58' }
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  s.update(0.003)
  check('switch: key taken by a driving bind turns traction back on', mock.connected['KeyDrive.Live.v11'].tcState ~= 5)

  -- the render module publishes text input focus
  s = fresh()
  live = mock.connected['KeyDrive.Live.v11']
  r = mock.load(CORE, 'module_render.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  mock.uiState.wantCaptureKeyboard = true
  r.update(0.016)
  check('render module: text input focus published', live.keyboardCaptured == true)
  mock.uiState.wantCaptureKeyboard = false
  r.update(0.016)
  check('render module: focus released', live.keyboardCaptured == false)
  local keys = require('src/keys')
  check('key parse', keys.parseKey('x') == 88 and keys.parseKey('F5') == 116 and keys.parseKey('0x58') == 88
    and keys.parseKey('88') == 88 and keys.parseKey('7') == 55 and keys.parseKey('') == -1 and keys.parseKey('F13') == -1
    and keys.parseKey('0') == -1 and keys.parseKey(' 0 ') == -1 and keys.parseKey('0x30') == 48
    and keys.parseKey(88) == 88)
end

-- 31. Mode 2 PRED_KD: a cut made by the prediction alone (measured slip at or below the target, predicted slip over
-- it, guard not the cause) falls at PRED_KD x the normal rate (v0.11.1 logs: 52 of 63 low-gear cap falls began on the
-- prediction alone and fed the pulsing). PRED_KD = 1 must be bit-exact with v0.11.1 (fixtures/traction_v0111.lua =
-- core/traction.lua before PRED_KD; drop the fixture comparison once traction.lua changes behaviour on purpose).
do
  local Traction = dofile(CORE .. '/core/traction.lua')
  local Old = dofile(here .. '/fixtures/traction_v0111.lua')
  -- the v0.11.1 parameter set (frozen: core/tuned.lua moves on with every retune); RET_HOLD off for the bit-exact
  -- part because v0.12 ends a hold window when the driver lifts below the cap (a deliberate change)
  local tuned = dofile(here .. '/fixtures/tuned_v0111.lua')
  local function v3(x, y, z) return { x = x, y = y, z = z } end
  local function newCar()
    local wheels = {}
    for i = 0, 3 do
      wheels[i] = { ndSlip = 0.2, load = 3000, angularSpeed = 60, tyreRadius = 0.33, slipRatio = 0.02, slipAngle = 0.3 }
    end
    return { gear = 1, rpm = 4000, localVelocity = v3(0, 0, 10), tractionType = 0, wheels = wheels }
  end
  local function params(extra)
    local tp = {}
    for k, v in pairs(tuned.traction) do tp[k] = v end
    for k, v in pairs(extra or {}) do tp[k] = v end
    return tp
  end
  -- (a) bit-exact against v0.11.1 on a long pseudo-random trace (lifts, shifts, spins, slides, airborne, 333 Hz-50 fps)
  local function trace(extra, steps)
    local st = 12345
    local function rnd() st = (st * 1103515245 + 12345) % 2147483648; return st / 2147483648 end
    local a, b = Traction.new(params(extra)), Old.new(params(extra))
    local ca, cb = newCar(), newCar()
    a:configure(ca); b:configure(cb)
    local nd, sr, sa, req, gear, maxd = 0.3, 0.04, 0.3, 0, 1, 0
    for i = 1, steps do
      if i % 97 == 0 then req = rnd() < 0.15 and 0 or rnd() end
      if i % 1301 == 0 then gear = 1 + math.floor(rnd() * 5) end
      local u = rnd()
      if u < 0.02 then nd = 0.2 + rnd() * 2.5 elseif u < 0.1 then nd = nd + (rnd() - 0.5) * 0.4 end
      if nd < 0 then nd = 0.05 end
      sr = nd * (0.06 + rnd() * 0.12)
      if i % 211 == 0 then sa = rnd() < 0.5 and 0.3 or rnd() * 8 end
      local load = (i % 3001 < 15) and 10 or 3000
      local dt = (i % 2000 < 1000) and 0.003 or (1 / (50 + (i % 7) * 18))
      for _, c in ipairs({ ca, cb }) do
        c.gear, c.rpm, c.localVelocity.z = gear, 1500 + (i % 900) * 7, 3 + (i % 5000) * 0.01
        for w = 2, 3 do
          local wh = c.wheels[w]
          wh.ndSlip, wh.slipRatio, wh.slipAngle, wh.load = nd * (w == 2 and 1.05 or 0.95), sr, sa, load
        end
      end
      local oa = a:update(dt, ca, req, 0.935, 1)
      local ob = b:update(dt, cb, req, 0.935, 1)
      local d = math.abs(oa - ob) + math.abs(a.A - b.A) + math.abs(a.slip - b.slip) + math.abs(a.sx - b.sx)
      if d > maxd then maxd = d end
    end
    return maxd
  end
  check('PRED_KD 1: bit-exact with v0.11.1 (v0.11.1 set, RET_HOLD off)', trace({ RET_HOLD = 0 }, 30000) == 0)
  check('PRED_KD 1: bit-exact with v0.11.1 (memory on, no RET_HOLD)', trace({ MEM = 1, RET_HOLD = 0 }, 30000) == 0)
  check('PRED_KD default is 1', Traction.DEFAULTS.PRED_KD == 1 and Traction.new(tuned.traction).p.PRED_KD == 1)
  -- (b) the same cut with PRED_KD 1 and 0.3: steady slip, then a fast rise that stays under the target
  -- (prediction-only), then a real overshoot, then a lateral slide (guard). Per-step falls of the cap are compared.
  local TGT = 0.935
  local function cut(kdScale)
    local t = Traction.new(params({ PRED_KD = kdScale }))
    local c = newCar()
    t:configure(c)
    local function set(nd, sa, srScale)
      for w = 2, 3 do c.wheels[w].ndSlip, c.wheels[w].slipRatio, c.wheels[w].slipAngle = nd, nd * 0.12 * (srScale or 1), sa end
    end
    local res = { pred = 0, over = {}, guard = {} }
    for _ = 1, 400 do set(0.3, 0.3); t:update(0.003, c, 1, TGT, 1) end
    local a0 = t.A
    local nd = 0.3
    for _ = 1, 60 do -- rise at 6 /s to 0.85 (0.91 of the target), then hold there
      nd = nd + 6 * 0.003; if nd > 0.85 then nd = 0.85 end
      set(nd, 0.3); t:update(0.003, c, 1, TGT, 1)
      assert(t.sx <= t.targetX, 'measured slip stayed under the target')
    end
    res.pred = a0 - t.A
    for _ = 1, 200 do set(0.3, 0.3); t:update(0.003, c, 1, TGT, 1) end
    t.A = 0.9
    for _ = 1, 40 do -- real overshoot
      local before = t.A
      set(1.6, 0.3); t:update(0.003, c, 1, TGT, 1)
      if t.sx > t.targetX then res.over[#res.over + 1] = before - t.A end
    end
    for _ = 1, 200 do set(0.3, 0.3); t:update(0.003, c, 1, TGT, 1) end
    t.A = 0.9
    for _ = 1, 40 do -- lateral slide: combined slip over the guard level, little wheelspin
      local before = t.A
      set(1.4, 6, 0.15); t:update(0.003, c, 1, TGT, 1)
      if t.slip > tuned.traction.GUARD_LEVEL then res.guard[#res.guard + 1] = before - t.A end
    end
    return res
  end
  local r1, r3 = cut(1), cut(0.3)
  check('PRED_KD: the rise under the target is cut by the prediction', r1.pred > 0.02, r1.pred)
  check('PRED_KD 0.3: prediction-only cut ~0.3 x as deep', math.abs(r3.pred / r1.pred - 0.3) < 0.03,
    string.format('%.4f vs %.4f', r3.pred, r1.pred))
  local function same(x, y)
    if #x ~= #y or #x < 5 then return false end
    for i = 1, #x do if math.abs(x[i] - y[i]) > 1e-12 then return false end end
    return true
  end
  check('PRED_KD 0.3: a real overshoot cut is unchanged', same(r1.over, r3.over), #r1.over .. '/' .. #r3.over)
  check('PRED_KD 0.3: a guard (lateral slide) cut is unchanged', same(r1.guard, r3.guard), #r1.guard .. '/' .. #r3.guard)
end

-- 32. KeyDriveConfig window "KeyDrive" (v0.12.1): diagnostics on/off and the intervention strength slider, sent to the
-- core and the render module through the shared struct; nothing changes until the user touches a control.
do
  -- the app's copy of the shared layout must equal the core's
  local function layout(dir)
    mock.reset()
    mock.install(dir)
    local captured
    ac.connect = function (l) captured = l; return {} end
    dofile(dir .. '/src/shared.lua').connect()
    local key, fields = captured[1].__key, {}
    for k in pairs(captured) do if type(k) == 'string' then fields[#fields + 1] = k end end
    table.sort(fields)
    return key .. ':' .. table.concat(fields, ',')
  end
  check('app and core share the same live layout', layout(APP) == layout(CORE))

  mock.reset()
  mock.settings = { KEYDRIVE = { SHOW_DIAGNOSTICS = 1 } }
  local s = mock.load(CORE, 'assist.lua')
  local live = mock.connected['KeyDrive.Live.v11']
  s.update(0.003)
  local target50 = live.targetSlip
  local kBack50 = nil
  local app = mock.load(APP, 'KeyDriveConfig.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  for _ = 1, 10 do app.update(1 / 60); s.update(0.003) end
  app.windowSettings(1 / 60)
  check('app: untouched sends nothing', live.cfgDiagSet == false and live.cfgStrengthSet == false and live.targetSlip == target50
    and live.strength == 50)
  check('app: checkbox shows the settings.ini value', mock.checkboxState == true)

  -- hide the diagnostics
  mock.click['Zobrazit diagnostiku'] = true
  app.windowSettings(1 / 60)
  app.update(1 / 60)
  check('app: diagnostics switched off', live.cfgDiagSet == true and live.cfgShowDiag == false and live.cfgStrengthSet == false)
  local r = mock.load(CORE, 'module_render.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  r.update(0.016)
  check('render: overlay hidden by the app', mock.drawUIActive == false)
  check('app: setting remembered', mock.storage['keydrive_diagSet'] == true and mock.storage['keydrive_showDiag'] == false)

  -- strength 100: less allowed slip; 0: up to the tyre peak at most; back to 50: as tuned
  mock.sliderSet = { ['##strength'] = 100 }
  app.windowSettings(1 / 60)
  app.update(1 / 60)
  s.update(0.003)
  check('strength 100: allowed slip 0.85x', math.abs(live.targetSlip - target50 * 0.85) < 1e-9 and live.strength == 100,
    live.targetSlip)
  mock.sliderSet = { ['##strength'] = 0 }
  app.windowSettings(1 / 60)
  app.update(1 / 60)
  s.update(0.003)
  check('strength 0: more slip, never past the tyre peak', live.targetSlip > target50 and live.targetSlip <= 1, live.targetSlip)
  mock.click['Výchozí (50)'] = true
  app.windowSettings(1 / 60)
  app.update(1 / 60)
  s.update(0.003)
  check('strength back to 50 = as tuned', live.targetSlip == target50 and live.strength == 50)

  -- the remembered values come back with the next session
  local app2 = mock.load(APP, 'KeyDriveConfig.lua')
  mock.connected['KeyDrive.Live.v11'] = live
  live.cfgDiagSet, live.cfgStrengthSet = false, false
  app2.update(1 / 60)
  check('app: remembered settings sent again', live.cfgDiagSet == true and live.cfgShowDiag == false and live.cfgStrengthSet)

  -- moving only the slider while KeyDrive is not running must not touch the diagnostics (review v0.12.1)
  mock.reset()
  mock.settings = { KEYDRIVE = { SHOW_DIAGNOSTICS = 1 } }
  local app3 = mock.load(APP, 'KeyDriveConfig.lua')
  local live3 = mock.connected['KeyDrive.Live.v11']
  mock.sliderSet = { ['##strength'] = 70 }
  app3.windowSettings(1 / 60)
  app3.update(1 / 60)
  check('slider alone leaves the diagnostics to settings.ini', live3.cfgDiagSet == false and live3.cfgStrengthSet == true
    and live3.cfgStrength == 70)
end

print(string.format('KeyDrive: %d passed, %d failed', passed, failed))
return failed > 0
