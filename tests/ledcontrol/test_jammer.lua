-- Part A (the user's bug): on the limiter and at the shift point the LEDs showed AC's red instead of the user's own
-- animation, with takeover method A, B and C alike. The jammer (jammer.lua) imitates the ways the game can fight the
-- app; every case runs with every method on the formula car at the limiter, with the limiter animation set to solid
-- green. After a reaction window of REACT frames every LED must show what the app wants in every frame.
-- What this cannot prove: which of these ways the real game uses (see UNSURE in mock_csp.lua and jammer.lua).

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local jammerPath = appDir .. '/../../../tests/ledcontrol/jammer.lua'

local REACT = 3          -- frames the app may need to notice a change of the game's behaviour
local REACT_SWITCH = 100 -- frames to notice that the game wins anyway and switch the method (render checks: a
                         -- read-back once a second, every 15 frames after a lost one, two lost ones switch)
local RUN = 240          -- frames per case

local CASES = {
  { id = 'every-frame', name = 'AC writes the LED material every frame',
    opts = { when = 'always', target = 'original', phase = 'before' } },
  { id = 'after-n', name = 'AC starts writing after 120 frames',
    opts = { when = 'always', target = 'original', phase = 'before', after = 120 } },
  -- the direct method cannot keep an LED the game hides: it has to switch to the redraw
  { id = 'limiter-blink', name = 'AC blinks its LEDs on the limiter by visibility + red', react = { [3] = 'switch' },
    opts = { when = 'limiter', target = 'original', phase = 'before', reshow = true, blinkHz = 8 } },
  -- nothing of the app runs between this write and the picture: the app has to notice it at the render check and
  -- switch to the redraw, so it gets a longer reaction window (REACT_SWITCH)
  { id = 'by-name', name = 'CSP writes red by material name right before the picture', react = 'switch',
    opts = { when = 'limiter', target = 'byName', phase = 'after' } },
  { id = 'lod', name = 'LOD switch for 30 frames, LOD A shown again', lod = 30,
    opts = { when = 'limiter', target = 'original', phase = 'before' } },
  { id = 'session', name = 'session reset (originals shown, emissive black)', session = true,
    opts = { when = 'limiter', target = 'original', phase = 'before' } },
}

local results = {}
local function runCase(case, method)
  H.formulaCar(1)
  env.storage = {}
  env.car.speedKmh, env.car.gear, env.car.rpm = 150, 5, 8000
  local app = H.loadApp()
  frame(3)
  local rt = app.runtime
  rt.setMethod(method)
  frame(3)
  -- the user's own limiter animation: solid green
  rt.editScenario('limiter', 'look', { p = 'solid', c = { '#00FF00' } })
  frame(2)
  local J = dofile(jammerPath)(env)
  local all = {}
  for i = 1, #rt.layout.leds do
    local led = rt.layout.leds[i]
    for k = 1, #led.inst do all[#all + 1] = led.inst[k].ref[1] end
  end
  J.watch(all)
  env.jammer = J
  env.car.rpm = env.car.rpmLimiter * 0.995       -- on the limiter
  J.set(case.opts)
  local red0 = env.redundant.emissive + env.redundant.visible
  local bad, firstBad, why = 0, nil, nil
  local eventAt = env.frameNo + (case.opts.after or 0)
  for f = 1, RUN do
    if case.lod and f == 60 then J.lodSwitch(case.lod); eventAt = env.frameNo end
    if case.lod and f == 60 + case.lod then eventAt = env.frameNo + 1 end
    if case.session and f == 60 then J.sessionReset(); eventAt = env.frameNo end
    frame(1)
    local react = type(case.react) == 'table' and case.react[method] or case.react
    if env.frameNo > eventAt + (react == 'switch' and REACT_SWITCH or REACT) then
      local main = rt.layout.groups[1].leds
      for k = 1, #main do
        local ok, w = H.ledMatches(main[k])
        if not ok then
          bad = bad + 1
          if not firstBad then firstBad, why = f, w end
          break
        end
      end
    end
  end
  local redundant = env.redundant.emissive + env.redundant.visible - red0
  if redundant > 0 then
    local o = env.redundant.lastObj
    print(string.format('    redundant: %s %s at frame %d', tostring(o and o.name), tostring(env.redundant.lastKind),
      env.redundant.lastFrame))
  end
  local tk = app.takeover
  local running = tk.method
  -- the app switched off while the game still fights: every original as it was, no copy shown, nothing drawn
  J.on = false
  env.jammer = nil
  app.config.set('master', false)
  frame(3)
  local restored, whyNot = true, nil
  for i = 1, #all do
    local m = all[i]
    -- hidden by the app (the jammer's own blink may have left it hidden: that is the game's state)
    local w = env.lastWrite(m)
    if not m.visible and w and w.kind == 'visible' and w.writer == 'app' then
      restored, whyNot = false, m.name .. ' still hidden by the app'
    end
  end
  local function walk(o)
    if o.kind == 'mesh' then
      if o.created and not o.disposed and o.visible then restored, whyNot = false, o.name .. ' copy still shown' end
      return
    end
    for i = 1, #o.children do walk(o.children[i]) end
  end
  walk(env.root)
  local drawnAfter = false
  for _, d in pairs(env.draws) do if d.frame == env.frameNo then drawnAfter = true end end
  if drawnAfter then restored, whyNot = false, 'still drawn' end
  results[#results + 1] = string.format('  %-14s method %d (runs %d): %s%s%s', case.id, method, running,
    bad == 0 and 'OK' or string.format('FAIL %d bad frames, first at %d: %s', bad, firstBad, tostring(why)),
    restored and '' or (', NOT RESTORED: ' .. tostring(whyNot)), redundant == 0 and '' or (', redundant writes ' .. redundant))
  check(restored, string.format('%s, method %d: master off restores the car (%s)', case.id, method, tostring(whyNot)))
  check(redundant == 0, string.format('%s, method %d: no write without a change (%d)', case.id, method, redundant))
  return bad == 0, bad, firstBad, why, running
end

for _, case in ipairs(CASES) do
  for method = 1, 3 do
    local ok, bad, firstBad, why, running = runCase(case, method)
    check(ok, string.format('%s, method %d (running %d): the takeover holds (%d bad frames, first %s: %s)', case.name,
      method, running, bad, tostring(firstBad), tostring(why)))
  end
end
print('jammer matrix:\n' .. table.concat(results, '\n'))

return H.finish('test_jammer')
