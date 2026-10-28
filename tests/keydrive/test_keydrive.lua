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

-- 1. Throttle ramps up at THROTTLE_RISE_RATE, independent of the physics rate.
do
  local results = {}
  for _, dt in ipairs({ 0.003, 1 / 60, 0.01 }) do
    local s = fresh()
    mock.keys[VK_UP] = true
    run(s, 0.3, dt)
    results[#results + 1] = mock.joypad.gas
  end
  check('throttle rise 120 %/s after 0.3 s', near(results[1], 0.36, 0.01), results[1])
  check('throttle rise independent of dt', near(results[1], results[2], 0.01) and near(results[1], results[3], 0.01),
    table.concat(results, ', '))
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
  local s = fresh({ THROTTLE_RISE_RATE = 500 })
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
  local s = fresh()
  mock.controls.KEYBOARD.GAS = 87 -- W
  for _, cb in ipairs(mock.callbacks.controls) do cb() end
  mock.keys[87] = true
  run(s, 0.2, 0.003)
  check('rebound gas key', mock.joypad.gas > 0.2, mock.joypad.gas)
  check('binds published', mock.connected['KeyDrive.Live.v9'].bindGas == 87)
end

-- 7b. Gear and handbrake keys from their own sections, hex values as Content Manager writes them.
do
  mock.reset()
  mock.controls.GEARUP = { KEY = '0x53' }   -- S
  mock.controls.GEARDN = { KEY = '0x46' }   -- F
  mock.controls.HANDBRAKE = { KEY = '0x20' }
  mock.controls.KEYBOARD.GAS = '0x57'       -- W as hex string
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
  local live = mock.connected['KeyDrive.Live.v9']
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
  local live = mock.connected['KeyDrive.Live.v9']
  check('incoming value published', live.inGas == 1, live.inGas)
  check('key mask', live.keyMask == 1, live.keyMask)
  check('render module requested', mock.renderModules[1] == 'module_render')
  local core = CORE
  local r = mock.load(core, 'module_render.lua')
  mock.connected['KeyDrive.Live.v9'] = live
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
  check('reverse: traction state ready/off', mock.connected['KeyDrive.Live.v9'].tcState ~= 4)

  s = fresh()
  for i = 0, 3 do mock.car.wheels[i].tyreRadius = 0 end
  s = mock.load(CORE, 'assist.lua')
  mock.keys[VK_UP] = true
  run(s, 0.5, 0.003)
  check('no wheel data: plain ramp', near(mock.joypad.gas, 0.6, 0.01), mock.joypad.gas)
  check('no wheel data: state 0', mock.connected['KeyDrive.Live.v9'].tcState == 0)

  s = fresh()
  mock.keys[VK_UP] = true
  run(s, 0.3, 0.003)
  for i = 2, 3 do mock.car.wheels[i].load = 0; mock.car.wheels[i].angularSpeed = 200 end
  run(s, 0.2, 0.003)
  check('airborne: state 2', mock.connected['KeyDrive.Live.v9'].tcState == 2)
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
  check('leak detected', mock.connected['KeyDrive.Live.v9'].leak == true)
  s = fresh()
  mock.keys[VK_UP] = true
  for _ = 1, 200 do s.update(0.003); mock.car.gas = mock.joypad.gas end
  check('no false leak', mock.connected['KeyDrive.Live.v9'].leak == false)
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
    check('log meta line names the car', log:match('^# car=test_car') ~= nil, log:match('^[^\n]+'))
    local header = log:match('^#[^\n]*\n([^\n]+)')
    check('log header', header:find('key_gas', 1, true) and header:find('nd_rl', 1, true) and header:find('events', 1, true))
    local _, rows = log:gsub('\n', '')
    check('log has ~40 Hz rows (10 s)', rows > 380 and rows < 420, rows)
    check('log rows have every column', select(2, log:match('\n([^\n]+)$'):gsub(',', '')) == select(2, header:gsub(',', '')))
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
  local live = mock.connected['KeyDrive.Live.v9']
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
    live = mock.connected['KeyDrive.Live.v9'] }
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
-- spin much less than the first, by easing off just before the revs reach the band where it spun.
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
        local l = mock.connected['KeyDrive.Live.v9']
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
  check('second launch spins no more than the first (memory per rpm band; mode 2 may not spin at all)', s2 <= s1 * 0.7 + 0.005, string.format('%.2f vs %.2f', s2, s1))
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
  local live = mock.connected['KeyDrive.Live.v9']
  check('AC steering detected', live.steerFromAC == true, live.acSteerVotes)
  check('AC steering passed through untouched', mock.joypad.steer == acSteer, mock.joypad.steer)
  mock.keys[VK_RIGHT] = nil

  -- AC sends nothing (the state keeps what KeyDrive wrote): KeyDrive steers.
  s = fresh()
  mock.car.speedKmh, mock.car.localVelocity.z = 100, 28
  mock.keys[VK_RIGHT] = true
  run(s, 0.6, 0.003)
  check('no AC steering: KeyDrive steers', mock.connected['KeyDrive.Live.v9'].steerFromAC == false and mock.joypad.steer > 0.3,
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
-- crossed in a corner (high lateral slip) must not be remembered at all.
do
  local Throttle = dofile(CORE .. '/core/throttle.lua')
  local tuned = dofile(CORE .. '/core/tuned.lua')
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
  local th2 = Throttle.new(tuned.throttle, tuned.traction)
  local c2 = newCar()
  th2:configure(c2)
  for _ = 1, 400 do setRear(c2, 0.7, 0.03, 4); th2:update(0.003, true, c2, 1.5, 0) end
  for _ = 1, 60 do setRear(c2, 0.9, 0.08, 4); th2:update(0.003, true, c2, 1.5, 0) end
  check('mode 2: corner crossing teaches no limit', th2.traction.memoryNow > 0.99, th2.traction.memoryNow)
  check('mode 2: corner cut keeps at least the corner floor', th2.traction.limit >= 0.19, th2.traction.limit)
end

print(string.format('KeyDrive: %d passed, %d failed', passed, failed))
return failed > 0
