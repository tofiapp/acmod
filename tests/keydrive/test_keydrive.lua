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
  check('throttle rise 150 %/s after 0.3 s', near(results[1], 0.45, 0.01), results[1])
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
  check('dt clamp after a hitch', near(mock.joypad.gas, 1.5 * 0.05), mock.joypad.gas)
  s.update(0)
  check('dt = 0 is ignored', near(mock.joypad.gas, 1.5 * 0.05), mock.joypad.gas)
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
  check('rebound gas key', mock.joypad.gas > 0.25, mock.joypad.gas)
  check('binds published', mock.connected['KeyDrive.Live.v1'].bindGas == 87)
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
  local live = mock.connected['KeyDrive.Live.v1']
  check('incoming value published', live.inGas == 1, live.inGas)
  check('key mask', live.keyMask == 1, live.keyMask)
  check('render module requested', mock.renderModules[1] == 'module_render')
  local core = CORE
  local r = mock.load(core, 'module_render.lua')
  mock.connected['KeyDrive.Live.v1'] = live
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

print(string.format('KeyDrive: %d passed, %d failed', passed, failed))
return failed > 0
