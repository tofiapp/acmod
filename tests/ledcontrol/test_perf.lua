-- Performance in the simulation: material / visibility writes and allocation per frame, per takeover method.
--   * steady state (nothing changes): no LED write at all, except the direct method putting back what AC wrote;
--   * no app write ever repeats its own last value on an object (mock write log, "redundant");
--   * an RPM sweep writes only LEDs whose colour changed;
--   * allocation per frame with the window closed stays near zero.
-- The numbers are printed; they say nothing about the game's real cost of a write or of a render.mesh call.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame

local report = {}

for method = 1, 3 do
  H.formulaCar(1)
  env.storage = {}
  env.car.speedKmh, env.car.gear = 150, 4
  local app = H.loadApp()
  frame(3)
  local rt = app.runtime
  if method ~= 1 then rt.setMethod(method); frame(3) end
  local name = app.takeover.NAMES[method]
  env.car.rpm = math.floor(rt.ST.shiftUp * 0.9)
  frame(60)
  -- steady state
  local w0, red0 = env.writeCount.app, env.redundant.emissive + env.redundant.visible
  local mw0 = env.materialWrites or 0
  frame(300)
  local steady = env.writeCount.app - w0
  local perFrame = steady / 300
  local fightLeds = 0
  for i = 1, app.takeover.n do if app.takeover.items[i].fight then fightLeds = fightLeds + #app.takeover.items[i].inst end end
  if method == 3 then
    check(perFrame <= fightLeds + 0.01, string.format('%s, steady: only the LEDs AC writes are put back (%.1f per frame, %d fought)',
      name, perFrame, fightLeds))
  else
    check(steady == 0, string.format('%s, steady: no write while nothing changes (%d writes in 300 frames)', name, steady))
  end
  -- RPM sweep: writes follow colour changes
  local changes = 0
  local last = {}
  for i = 1, rt.n do last[i] = rt.fb[i] end
  local w1 = env.writeCount.app
  for f = 1, 240 do
    env.car.rpm = math.floor(rt.ST.shiftUp * (0.7 + 0.3 * f / 240))
    frame(1)
    for i = 1, rt.n do
      if rt.fb[i] ~= last[i] then changes = changes + #rt.layout.leds[i].inst; last[i] = rt.fb[i] end
    end
  end
  local sweep = env.writeCount.app - w1
  local allowedWrites = changes + (method == 3 and fightLeds * 240 or 0)
  check(sweep <= allowedWrites, string.format('%s, RPM sweep: %d writes for %d LED colour changes', name, sweep, changes))
  local redundant = env.redundant.emissive + env.redundant.visible - red0
  check(redundant == 0, string.format('%s: no write repeats the app\'s own last value (%d)', name, redundant))
  -- allocation, window closed
  frame(30)
  jit.off()
  collectgarbage('collect')
  collectgarbage('stop')
  local m0 = collectgarbage('count')
  for f = 1, 300 do
    env.car.rpm = math.floor(rt.ST.shiftUp * (0.8 + 0.2 * (f % 60) / 60))
    frame(1)
  end
  local kb = collectgarbage('count') - m0
  collectgarbage('restart')
  jit.on()
  check(kb < 4, string.format('%s: allocation %.2f KB over 300 frames', name, kb))
  report[#report + 1] = string.format('  %-18s steady %.2f writes/frame, sweep %d writes / %d changes, %.2f KB / 300 frames, '
    .. 'material writes total %d', name, perFrame, sweep, changes, kb, (env.materialWrites or 0) - mw0)
end
print('performance:\n' .. table.concat(report, '\n'))

return H.finish('test_perf')
