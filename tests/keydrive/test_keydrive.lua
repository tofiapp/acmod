-- KeyDrive tests: run through tests/keydrive/run_tests.py.
local selfPath, CORE = ...
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
  check('brake rises', mock.joypad.brake > 0.5 and mock.joypad.brake < 0.7, mock.joypad.brake)
  mock.keys[VK_DOWN] = nil
  mock.keys[VK_LEFT] = true
  run(s, 0.2, 0.003)
  local held = mock.joypad.steer
  check('left steers negative', held < -0.3, held)
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
  check('binds published', mock.connected['KeyDrive.Live.v3'].bindGas == 87)
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
  local live = mock.connected['KeyDrive.Live.v3']
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
  local live = mock.connected['KeyDrive.Live.v3']
  check('incoming value published', live.inGas == 1, live.inGas)
  check('key mask', live.keyMask == 1, live.keyMask)
  check('render module requested', mock.renderModules[1] == 'module_render')
  local core = CORE
  local r = mock.load(core, 'module_render.lua')
  mock.connected['KeyDrive.Live.v3'] = live
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
  local m, r, J, N, mu = 1300, 0.32, 1.2, 3500, 1.1
  local torque = 4000                  -- Nm at the axle at full throttle (first gear, much more than grip)
  local v, w = 0, 0
  local slips, gases, t = {}, {}, 0
  mock.keys[VK_UP] = true
  local steps = math.floor(seconds / dt + 0.5)
  for _ = 1, steps do
    s.update(dt)
    local gasNow = mock.joypad.gas
    c.gas = gasNow
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
    for i = 2, 3 do c.wheels[i].angularSpeed = w end
    for i = 0, 1 do c.wheels[i].angularSpeed = v / r end
    c.localVelocity.z = v
    c.speedKmh = v * 3.6
    t = t + dt
    if t > 1.0 then
      slips[#slips + 1] = (w * r - v) / math.max(v, 5)
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
  return { v = v, slipMean = sm, slipStd = ss, slipMax = smax, gasMean = gm, gasStd = gs }
end

do
  local free = launch(0.003, { TRACTION = 0 }, 3)
  if os.getenv('KD_VERBOSE') then for _, x in ipairs({ free, launch(0.003, nil, 3), launch(0.003, { TARGET_SLIP = 20 }, 3), launch(0.003, { TRACTION_RESPONSE = 300 }, 3) }) do print(string.format('v %.2f slip %.3f±%.3f max %.3f gas %.3f±%.3f', x.v, x.slipMean, x.slipStd, x.slipMax, x.gasMean, x.gasStd)) end end
  check('model: without traction the wheels spin', free.slipMean > 0.5, free.slipMean)
  local a = launch(0.003, nil, 3)
  check('traction holds slip near 10 %', a.slipMean > 0.06 and a.slipMean < 0.14, a.slipMean)
  check('traction: no oscillation in slip', a.slipStd < 0.03, a.slipStd)
  check('traction: smooth throttle', a.gasStd < 0.06, a.gasStd)
  check('traction: limited throttle', a.gasMean < 0.9, a.gasMean)
  check('traction beats wheelspin', a.v > free.v, string.format('%.1f vs %.1f', a.v, free.v))
  local b = launch(1 / 400, nil, 3)
  local c = launch(1 / 250, nil, 3)
  check('traction independent of physics rate', math.abs(a.v - b.v) / a.v < 0.03 and math.abs(a.v - c.v) / a.v < 0.03,
    string.format('%.2f %.2f %.2f', a.v, b.v, c.v))
  local hi = launch(0.003, { TARGET_SLIP = 20 }, 3)
  check('target slip setting', hi.slipMean > 0.14 and hi.slipMean < 0.26, hi.slipMean)
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
  check('reverse: traction state ready/off', mock.connected['KeyDrive.Live.v3'].tcState ~= 4)

  s = fresh()
  for i = 0, 3 do mock.car.wheels[i].tyreRadius = 0 end
  s = mock.load(CORE, 'assist.lua')
  mock.keys[VK_UP] = true
  run(s, 0.5, 0.003)
  check('no wheel data: plain ramp', near(mock.joypad.gas, 0.6, 0.01), mock.joypad.gas)
  check('no wheel data: state 0', mock.connected['KeyDrive.Live.v3'].tcState == 0)

  s = fresh()
  mock.keys[VK_UP] = true
  run(s, 0.3, 0.003)
  for i = 2, 3 do mock.car.wheels[i].load = 0; mock.car.wheels[i].angularSpeed = 200 end
  run(s, 0.2, 0.003)
  check('airborne: state 2', mock.connected['KeyDrive.Live.v3'].tcState == 2)
  check('airborne: throttle not cut', mock.joypad.gas > 0.4, mock.joypad.gas)

  s = fresh()
  mock.joypad.gForces.x = 1.5
  mock.keys[VK_UP] = true
  run(s, 2, 0.003)
  check('corner cap 25 % at 1.5 g', near(mock.joypad.gas, 0.75, 0.01), mock.joypad.gas)

  s = fresh()
  mock.keys[VK_UP] = true
  s.update(0.003)
  for _ = 1, 200 do mock.car.gas = 1; s.update(0.003) end
  check('leak detected', mock.connected['KeyDrive.Live.v3'].leak == true)
  s = fresh()
  mock.keys[VK_UP] = true
  for _ = 1, 200 do s.update(0.003); mock.car.gas = mock.joypad.gas end
  check('no false leak', mock.connected['KeyDrive.Live.v3'].leak == false)
end

print(string.format('KeyDrive: %d passed, %d failed', passed, failed))
return failed > 0
