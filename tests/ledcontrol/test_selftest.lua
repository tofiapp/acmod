-- Self-test (Diody → Diagnostika → Self-test, src/selftest.lua): runs every scenario and display page, reads the LED
-- colours back in the render pass and writes a protocol that can be copied.
--   * clean car, method A and C: no FAIL, OK lines for the scenarios, versions in the header, copy to clipboard;
--   * method B: colours cannot be read back: SKIP, no FAIL;
--   * the game writing red over the LEDs right before the picture (jammer, switching off): FAIL lines name it;
--   * display car: every page and takeover screen painted.
-- What the self-test itself cannot see in the game: the picture (bloom, a mesh in front), the display texture.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local jammerPath = appDir .. '/../../../tests/ledcontrol/jammer.lua'

local function runSelftest(app, maxSeconds)
  env.windowOpen = true
  env.ui.tab = 'Diody'
  frame(2)
  H.click('Self-test##selftest')
  local st = require('src/selftest')
  local frames = 0
  while st.running and frames < (maxSeconds or 200) * 60 do frame(1); frames = frames + 1 end
  return st
end

local function count(st, kind)
  local n = 0
  for _, l in ipairs(st.lines) do if l:sub(1, #kind) == kind then n = n + 1 end end
  return n
end

for _, method in ipairs({ 1, 3 }) do
  H.formulaCar(1)
  env.storage = {}
  env.car.speedKmh, env.car.rpm, env.car.gear = 0, 5000, 0
  env.car.isInPitlane, env.car.isInPit = true, true
  local app = H.loadApp()
  frame(3)
  if method ~= 1 then app.runtime.setMethod(method); frame(3) end
  local st = runSelftest(app)
  local name = app.takeover.NAMES[method]
  check(st.done and not st.running, name .. ': self-test finished')
  check(st.fail == 0, name .. ': no FAIL on a clean car (' .. st.fail .. ')\n' .. (st.fail > 0 and st.text() or ''))
  check(st.ok >= 15, name .. ': OK lines for the scenarios (' .. st.ok .. ')')
  local text = st.text()
  check(text:find('LuaJIT', 1, true) and text:find('CSP: 0.2.11-mock (3400)', 1, true) and text:find('Výsledek', 1, true),
    name .. ': protocol with the versions and the result line')
  H.click('Kopírovat protokol##selftestCopy')
  check(env.clipboard == st.text(), name .. ': protocol copied as text')
  check(app.runtime.compiled.solo == nil, name .. ': normal operation after the self-test')
  print(name .. ': OK ' .. st.ok .. ', FAIL ' .. st.fail .. ', SKIP ' .. st.skip)
end

-- method B: nothing to read back
H.formulaCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
app.runtime.setMethod(2)
frame(3)
local st = runSelftest(app)
check(st.done and st.fail == 0 and count(st, 'SKIP') >= 10 and st.text():find('metoda B kreslí', 1, true),
  'method B: SKIP with the reason, no FAIL')

-- the game writes red over the LEDs right before the picture and the method may not switch: the self-test says so
H.formulaCar(1)
env.storage = {}
app = H.loadApp()
frame(3)
app.runtime.setMethod(3)
frame(3)
app.takeover.stats.switched = 3            -- (no switch to the redraw: the self-test must see the game win)
local J = dofile(jammerPath)(env)
local all = {}
for i = 1, #app.runtime.layout.leds do
  local led = app.runtime.layout.leds[i]
  for k = 1, #led.inst do all[#all + 1] = led.inst[k].ref[1] end
end
J.watch(all)
env.jammer = J
J.set({ when = 'always', target = 'mesh', phase = 'after' })
st = runSelftest(app)
env.jammer = nil
local named = false
for _, l in ipairs(st.lines) do if l:find('^FAIL') and l:find('čteno 30.0 0.0 0.0', 1, true) then named = true end end
check(st.fail >= 5 and named, 'game writing red before the picture: FAIL lines with the colour read back (' .. st.fail .. ')')

-- display car: pages and takeover screens
H.displayCar(1)
env.storage = {}
app = H.loadApp()
frame(3)
local display = require('src/display')
display.cfg().on = true
env.car.speedKmh, env.car.rpm = 80, 7000
frame(10)
st = runSelftest(app)
local pagesOk = 0
for _, l in ipairs(st.lines) do if l:find('^OK') and l:find('Displej:', 1, true) then pagesOk = pagesOk + 1 end end
check(st.done and st.fail == 0 and pagesOk == 12, 'display: 4 pages + 8 takeover screens painted (' .. pagesOk .. ')')
check(st.text():find('zkontrolujte okem', 1, true), 'display: the protocol asks to check the picture by eye')
check(display.page == 1 and display.forced == nil, 'display back to its page after the self-test')

-- not running: no allocation from the self-test code
env.windowOpen = true
env.ui.tab = 'Diody'
frame(60)
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for f = 1, 300 do env.car.rpm = 7000 + (f % 60) * 20; frame(1) end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
check(grown < 4, string.format('no per-frame allocation with the protocol shown (%.2f KB / 300 frames)', grown))

return H.finish('test_selftest')
