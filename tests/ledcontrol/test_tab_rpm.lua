-- LedControl: tab Otáčky through the mock UI. Live RPM (big number, bar with the start / shift / limiter markers and
-- the fill colour of the current phase, the main row's cells), the three rows (Auto on / off, sliders snapped to
-- 50 rpm, [Teď] with the engine running and without), the learned limiter with [Zapomenout], RPM per LED (enable =
-- spread from the effective start, one slider, [Teď], spread again, the car's own values, disable, values stored
-- for another LED count), hints, the LEDs on the car following every change, saving, the waiting / no LED lines,
-- GT3 (CSP thresholds, no ai.ini) and no allocation with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions (this file only)

-- every label a control was drawn with during the recorded frame, and the value a slider was drawn with
local drawn, sliderValue, recordDrawn = {}, {}, false
for _, name in ipairs({ 'slider', 'button', 'checkbox' }) do
  local f = ui[name]
  ui[name] = function (label, v, ...)
    if recordDrawn then
      drawn[label] = true
      if name == 'slider' then sliderValue[label] = v end
      if name == 'checkbox' then sliderValue[label] = v end
    end
    return f(label, v, ...)
  end
end
-- rectangles and circles drawn during the recorded frame (values copied: the tab reuses its vec2 / rgbm)
local rects, circles = {}, {}
do
  local fr, fc, fd = ui.drawRectFilled, ui.drawCircleFilled, ui.dummy
  ui.drawRectFilled = function (a, b, c, ...)
    if recordDrawn then rects[#rects + 1] = { x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y, c = c, r = c.r, g = c.g, b = c.b } end
    return fr(a, b, c, ...)
  end
  ui.drawCircleFilled = function (p, r, c, ...)
    if recordDrawn then circles[#circles + 1] = { r = c.r, g = c.g, b = c.b } end
    return fc(p, r, c, ...)
  end
  -- a dummy is an item: env.ui.hover = '#dummy' hovers every dot (K.dot draws one)
  ui.dummy = function (...)
    U.last = '#dummy'
    return fd(...)
  end
end

local TAB = 'Otáčky'
local app, rt, rpm, K
local function loadApp()
  app = H.loadApp()
  rt = app.runtime
  rpm = rt.rpm
  K = require('src/ui/kit')
  return app
end

local function show(n)
  env.windowOpen = true
  U.tab = TAB
  frame(n or 1)
end

local function capture()
  env.windowOpen = true
  U.tab = TAB
  U.record = true
  U.texts = {}
  drawn, sliderValue, rects, circles = {}, {}, {}, {}
  recordDrawn = true
  frame(1)
  recordDrawn = false
  U.record = false
  return table.concat(U.texts, '\n')
end
local function has(text, part) return text:find(part, 1, true) ~= nil end

local function click(label)
  U.tab = TAB
  H.click(label)
  frame(1)
end
local function slide(label, v)
  U.tab = TAB
  U.slide = { [label] = v }
  show(1)
  U.slide = nil
  frame(1)
end
local function setRpm(v, frames)
  env.car.rpm = v
  frame(frames or 3)
end

local function litCount()
  local count = 0
  for slot = 1, 15 do
    local r, g, b = env.seen(env.formula.hr[env.formula.slot[slot]])
    if r + g + b > 0.5 then count = count + 1 end
  end
  return count
end
local function limiterActive() return app.engine.find(rt.compiled, 'limiter').active end
local function manualOf(key) return rt.profile.rpm and rt.profile.rpm[key] end

-- the bar: background = the widest rect of BAR_H; fill = the rect drawn right after it
local function barRects()
  for i = 1, #rects do
    local r = rects[i]
    if r.x2 - r.x1 == 500 and r.y2 - r.y1 == 12 then return r, rects[i + 1] end
  end
  return nil, nil
end
local function sameColour(a, c) return a and math.abs(a.r - c.r) < 1e-6 and math.abs(a.g - c.g) < 1e-6 and math.abs(a.b - c.b) < 1e-6 end
local function markers()
  local out = {}
  for i = 1, #rects do
    local r = rects[i]
    if r.x2 - r.x1 == 2 and r.y2 - r.y1 == 18 then out[#out + 1] = r end
  end
  return out
end
local function cellRects()
  local out = {}
  for i = 1, #rects do
    local r = rects[i]
    if r.x2 - r.x1 == 16 and r.y2 - r.y1 == 16 then out[#out + 1] = r end
  end
  return out
end
local function ticks()
  local count = 0
  for i = 1, #rects do
    local r = rects[i]
    if math.abs(r.x2 - r.x1 - 1) < 1e-6 and r.y2 - r.y1 == 4 then count = count + 1 end
  end
  return count
end

-- ---------------------------------------------------------------- formula: live part and the three rows

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 8000
loadApp()
frame(3)
local text = capture()
check(app.safety.uiError == nil, 'tab drawn without an error (' .. tostring(app.safety.uiError) .. ')')
check(rpm.shift == 11500 and rpm.limiter == 13000 and rpm.start == 0, 'formula: shift 11500 from ai.ini, limiter 13000')
check(has(text, '8 000 ot/min'), 'big number: current RPM with a thousands space')
check(has(text, 'max 8 000'), 'highest RPM seen in small grey')
check(has(text, 'Začátek') and has(text, 'Plno / řazení') and has(text, 'Omezovač'), 'three rows')
check(has(text, '8 625') and has(text, '11 500') and has(text, '13 000'),
  'Auto values: start 75 % of 11500, shift point, limiter')
check(drawn['Auto##rpmAutoStart'] and drawn['Auto##rpmAutoShift'] and drawn['Auto##rpmAutoLimiter'], 'Auto checkboxes')
check(sliderValue['Auto##rpmAutoStart'] == true and sliderValue['Auto##rpmAutoLimiter'] == true, 'Auto checked by default')
check(drawn['Teď##rpmNowStart'] and drawn['Teď##rpmNowShift'] and drawn['Teď##rpmNowLimiter'], 'Teď buttons')
check(not drawn['##rpmStart'] and not drawn['##rpmShift'] and not drawn['##rpmLimiter'], 'no sliders while Auto')
check(has(text, 'Každá dioda zvlášť##rpmLeds') and drawn['Zapnout##rpmLeds'], 'per LED section with its switch')
check(drawn['Podle auta##rpmFromCar'], 'Podle auta offered: every main LED has the car\'s own RPM')
check(not drawn['Rozložit rovnoměrně##rpmSpread'] and not drawn['##rpmLed1'], 'per LED off: no rows, no spread button')
check(not has(text, 'naměřeno'), 'nothing learned yet')

-- the bar and the cells
local bg, fill = barRects()
check(bg ~= nil and fill ~= nil, 'bar drawn (background and fill)')
check(fill and math.abs(fill.x2 - 500 * 8000 / 13650) < 0.5, 'fill = current RPM of 0 .. limiter x 1.05')
check(fill and not sameColour(fill, K.GREEN) and not sameColour(fill, K.BLUE) and not sameColour(fill, K.RED),
  'below the start: grey fill')
local m = markers()
check(#m == 3 and sameColour(m[1], K.GREEN) and sameColour(m[2], K.BLUE) and sameColour(m[3], K.RED),
  'markers: start green, shift blue, limiter red')
check(#m == 3 and math.abs(m[1].x1 + 1 - 500 * 8625 / 13650) < 0.5 and math.abs(m[2].x1 + 1 - 500 * 11500 / 13650) < 0.5,
  'markers at the start and the shift point')
local cl = cellRects()
check(#cl == 15, 'main row: 15 cells (' .. #cl .. ')')
check(#cl == 15 and cl[1].r < 0.2 and cl[1].g < 0.2, 'cells dark below the start (F1: base off)')
setRpm(9000)
capture()
bg, fill = barRects()
check(sameColour(fill, K.GREEN), 'between start and shift: green fill')
cl = cellRects()
check(#cl == 15 and cl[1].g > 0.9 and cl[1].r < 0.1, 'first cell green while filling')
setRpm(11600)
capture()
bg, fill = barRects()
check(sameColour(fill, K.BLUE), 'past the shift point: blue fill')
cl = cellRects()
local allBlue = #cl == 15
for i = 1, #cl do if not (cl[i].b > 0.9 and cl[i].r < 0.1 and cl[i].g < 0.1) then allBlue = false end end
check(allBlue, 'cells: the whole row blue at the shift point (live from the car)')
setRpm(12950)
capture()
bg, fill = barRects()
check(sameColour(fill, K.RED), 'at the limiter: red fill')

-- tooltips: the source of each automatic value
U.hover = 'Auto##rpmAutoStart'
text = capture()
check(has(text, 'Auto: 75 % bodu řazení (preset F1 styl).'), 'start help: the preset percentage')
U.hover = 'Auto##rpmAutoShift'
text = capture()
check(has(text, 'Zdroj: ai.ini.'), 'shift help: source ai.ini')
U.hover = 'Auto##rpmAutoLimiter'
text = capture()
check(has(text, 'Zdroj: data auta.'), 'limiter help: from the car')
U.hover = 'Teď##rpmNowShift'
text = capture()
check(has(text, 'Vezme aktuální otáčky motoru.'), 'Teď tooltip')
U.hover = nil

-- start: Auto off -> slider at the automatic value, slider snapped to 50, LEDs follow, Auto on again
setRpm(8000)
click('Auto##rpmAutoStart')
check(rpm.start == 8625 and rt.ST.shiftStartManual == 8625, 'start Auto off: manual at the automatic value')
capture()
check(drawn['##rpmStart'] and sliderValue['##rpmStart'] == 8625, 'start slider shown at 8625')
check(sliderValue['Auto##rpmAutoStart'] == false, 'start Auto unchecked')
slide('##rpmStart', 7012)
check(rpm.start == 7000, 'start slider snapped to 50 rpm (' .. rpm.start .. ')')
setRpm(6990)
check(litCount() == 0, 'manual start 7000: dark at 6990')
setRpm(7100)
check(litCount() == 1, 'manual start 7000: first LED at 7100 (' .. litCount() .. ')')
click('Auto##rpmAutoStart')
check(rpm.start == 0 and rt.ST.shiftStartManual == 0, 'start Auto on again')
setRpm(7400)
check(litCount() == 0, 'automatic start 8625: dark at 7400')

-- shift point: Teď, slider, Auto, LEDs follow, saved
setRpm(9123)
click('Teď##rpmNowShift')
check(rpm.shift == 9120 and manualOf('shift') == 9120, 'Teď: shift point = current RPM rounded to 10')
text = capture()
check(drawn['##rpmShift'] and sliderValue['Auto##rpmAutoShift'] == false, 'shift row: slider after Teď')
setRpm(9150)
check(litCount() == 15, 'whole row lit past the new shift point')
frame(60)
local store = require('src/store')
local saved = store.loadCar('test_formula')
check(saved.rpm and saved.rpm.shift == 9120, 'shift point saved in the car profile')
slide('##rpmShift', 10037)
check(rpm.shift == 10050, 'shift slider snapped (' .. rpm.shift .. ')')
click('Auto##rpmAutoShift')
check(rpm.shift == 11500 and manualOf('shift') == nil, 'shift Auto on: back to ai.ini')

-- limiter: Auto off, slider, Teď, LEDs follow, Auto on
click('Auto##rpmAutoLimiter')
check(manualOf('limiter') == 13000, 'limiter Auto off: manual at 13000')
slide('##rpmLimiter', 12020)
check(rpm.limiter == 12000, 'limiter slider snapped')
setRpm(11800)
click('Teď##rpmNowLimiter')
check(rpm.limiter == 11800, 'Teď: limiter = current RPM')
setRpm(11760)
check(limiterActive(), 'limiter blinks at 11760 with the limiter at 11800')
click('Auto##rpmAutoLimiter')
check(rpm.limiter == 13000 and manualOf('limiter') == nil, 'limiter Auto on')
setRpm(11760)
check(not limiterActive(), 'automatic limiter: not at 11760')

-- Teď without the engine running: nothing changes, a short message
setRpm(300)
click('Teď##rpmNowStart')
text = capture()
check(rpm.start == 0, 'Teď with the engine off changes nothing')
check(has(text, 'Motor neběží.'), 'Teď with the engine off: message')
frame(200)
text = capture()
check(not has(text, 'Motor neběží.'), 'message gone after a few seconds')

-- learned limiter: shown, kept with a manual limiter, forgotten
setRpm(12400)
env.car.isEngineLimiterOn = true
frame(2)
env.car.isEngineLimiterOn = false
frame(2)
check(rpm.learned == 12400 and rpm.limiter == 12400, 'limiter learned from AC\'s flag')
text = capture()
check(has(text, 'naměřeno ve hře') and has(text, '12 400') and drawn['Zapomenout##rpmForget'],
  'learned limiter: row value, "naměřeno ve hře" and Zapomenout')
click('Auto##rpmAutoLimiter')
text = capture()
check(drawn['##rpmLimiter'] and sliderValue['##rpmLimiter'] == 12400 and has(text, 'naměřeno ve hře')
  and not has(text, 'naměřeno 12 400'), 'manual limiter at the learned value: the number is not repeated')
slide('##rpmLimiter', 12000)
text = capture()
check(has(text, 'naměřeno 12 400') and drawn['Zapomenout##rpmForget'], 'manual limiter: the learned value stays visible')
click('Auto##rpmAutoLimiter')
click('Zapomenout##rpmForget')
check(rpm.learned == 0 and rpm.limiter == 13000, 'Zapomenout: back to the car value')
text = capture()
check(not has(text, 'naměřeno') and not drawn['Zapomenout##rpmForget'], 'learned line gone')

-- ---------------------------------------------------------------- RPM per LED

local lay = rt.layout
local mainLeds = lay.groups[1].leds
check(lay.groups[1].role == 'main' and #mainLeds == 15, 'formula: main row of 15')
setRpm(8000)
click('Zapnout##rpmLeds')
check(rpm.ledRpm and #rpm.ledRpm == 15 and rpm.ledRpm[1] == 8625 and rpm.ledRpm[15] == 11308,
  'Zapnout: spread evenly from the effective start to one step before the shift point')
local v = {}
for k = 1, 15 do v[k] = rpm.ledRpm[k] end
setRpm(v[8] + 5)
check(litCount() == 8, 'LEDs follow their own values: 8 lit just above the 8th (' .. litCount() .. ')')
text = capture()
local allRows = true
for k = 1, 15 do
  if not (drawn['##rpmLed' .. k] and drawn['Teď##rpmNowLed' .. k] and sliderValue['##rpmLed' .. k] == v[k]) then allRows = false end
end
check(allRows, 'a row per LED: slider at its value and Teď')
check(drawn['Rozložit rovnoměrně##rpmSpread'] and drawn['Podle auta##rpmFromCar'], 'spread and from-car buttons')
check(sliderValue['Zapnout##rpmLeds'] == true, 'per LED switch checked')
check(ticks() == 15, 'a tick per LED under the bar')
local dots = {}
for i = #circles - 14, #circles do dots[#dots + 1] = circles[i] end
local dotsOk = #circles >= 15
for k = 1, 15 do
  local d = dots[k]
  local sum = d and d.r + d.g + d.b or 0
  if (k <= 8 and sum < 0.9) or (k > 8 and sum > 0.7) then dotsOk = false end
end
check(dotsOk, 'dots: lit LEDs bright in their fill colour, the rest dim')
check(dots[1] and dots[1].g > 0.9 and dots[1].r < 0.1 and dots[15] and dots[15].b > 0.3 and dots[15].r < 0.2,
  'dot colours from the F1 fill: first green, last blue')

-- hovering a dot blinks that LED on the car
U.hover = '#dummy'
text = capture()
U.hover = nil
check(rt.hover == mainLeds[15] and has(text, 'Na autě teď bliká.'), 'hover on a dot marks the LED (blinks on the car)')
frame(20)

-- one slider
slide('##rpmLed15', 11290)
check(rpm.ledRpm[15] == 11300, 'LED 15 slider snapped (' .. rpm.ledRpm[15] .. ')')
setRpm(11298)
check(litCount() == 14, 'LED 15 waits for its 11300 (' .. litCount() .. ')')
setRpm(11305)
check(litCount() == 15, 'LED 15 lit at 11305')

-- Teď on one LED
setRpm(9333)
click('Teď##rpmNowLed3')
check(rpm.ledRpm[3] == 9330, 'Teď on LED 3: current RPM (' .. rpm.ledRpm[3] .. ')')
setRpm(300)
click('Teď##rpmNowLed4')
check(rpm.ledRpm[4] == v[4], 'Teď on an LED with the engine off changes nothing')

-- spread again
click('Rozložit rovnoměrně##rpmSpread')
check(rpm.ledRpm[3] == v[3] and rpm.ledRpm[15] == 11308, 'Rozložit rovnoměrně: even values again')

-- the car's own values
click('Podle auta##rpmFromCar')
local fromCar = true
for k = 1, 15 do if rpm.ledRpm[k] ~= lay.leds[mainLeds[k]].rpm then fromCar = false end end
check(fromCar, 'Podle auta: the car\'s own RPM per LED')
local lowest = math.huge
for k = 1, 15 do lowest = math.min(lowest, rpm.ledRpm[k]) end
setRpm(lowest + 10)
check(litCount() == 1, 'car values: only the lowest LED lit just above it (' .. litCount() .. ')')

-- an LED above the limiter: hint
slide('##rpmLed15', 13000)
text = capture()
check(has(text, 'Některé diody jsou nad omezovačem.'), 'hint: LED above the limiter')

-- switched off
click('Zapnout##rpmLeds')
check(rpm.ledRpm == nil, 'per LED values switched off')
text = capture()
check(not drawn['##rpmLed1'] and sliderValue['Zapnout##rpmLeds'] == false, 'per LED rows gone')
check(not has(text, 'Některé diody'), 'LED hint gone')
setRpm(8600)
check(litCount() == 0, 'back to the relative fill: dark just below the start')
setRpm(8700)
check(litCount() == 1, 'back to the relative fill: first LED just above the start')

-- values stored for another LED count
rpm.setLeds({ 7000, 7500, 8000, 8500, 9000, 9500, 10000, 10500, 11000, 11400 }, rt.ST)
text = capture()
check(has(text, 'Uloženo pro 10 diod, řada má 15.') and sliderValue['Zapnout##rpmLeds'] == false,
  'values for 10 LEDs on a row of 15: note, switch off')
click('Zapnout##rpmLeds')
check(#rpm.ledRpm == 15, 'Zapnout replaces them with 15 even values')
click('Zapnout##rpmLeds')

-- ---------------------------------------------------------------- hints

click('Auto##rpmAutoStart')
slide('##rpmStart', 12000)
text = capture()
check(has(text, 'Začátek je nad bodem řazení.'), 'hint: start above the shift point')
click('Auto##rpmAutoStart')
click('Auto##rpmAutoShift')
slide('##rpmShift', 13000)
text = capture()
check(has(text, 'Řazení je nad omezovačem, diody nedosvítí.'), 'hint: shift point above the limiter')
click('Auto##rpmAutoShift')
text = capture()
check(not has(text, 'je nad'), 'no hint with the automatic range')
rt.setPreset('builtin:minimal')
frame(2)
text = capture()
check(has(text, 'Preset nepoužívá řadicí světla (karta Scénáře).'), 'hint: preset without shift lights')
rt.setPreset('builtin:f1')
frame(2)

-- master switch off
app.config.set('master', false)
frame(3)
text = capture()
check(rt.state == 'off' and has(text, 'Zapněte hlavní vypínač.'), 'master off: one hint line')
cl = cellRects()
check(#cl == 15 and math.abs(cl[1].r - 0.3) < 1e-6, 'master off: cells grey (the car drives its LEDs)')
app.config.set('master', true)
frame(3)
check(app.safety.uiError == nil, 'formula: no UI error (' .. tostring(app.safety.uiError) .. ')')

-- ---------------------------------------------------------------- GT3: CSP thresholds, no ai.ini

H.gt3Car(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 5000
loadApp()
frame(3)
U.hover = 'Auto##rpmAutoShift'
text = capture()
U.hover = nil
check(rt.presetId == 'builtin:gt3' and rpm.shift == 12610, 'gt3: shift point 97 % of the limiter')
check(has(text, 'Zdroj: 97 % omezovače.'), 'gt3: shift help names the source')
check(has(text, '10 088'), 'gt3: automatic start 80 % (GT3 styl)')
check(drawn['Podle auta##rpmFromCar'], 'gt3: Podle auta (CSP thresholds)')
click('Podle auta##rpmFromCar')
local gtLay = rt.layout
local gtOk = rpm.ledRpm and #rpm.ledRpm == #gtLay.groups[1].leds
for k = 1, #gtLay.groups[1].leds do
  if not gtOk or rpm.ledRpm[k] ~= gtLay.leds[gtLay.groups[1].leds[k]].rpm then gtOk = false end
end
check(gtOk, 'gt3: values 6000 / 7000 from the car')
check(app.safety.uiError == nil, 'gt3: no UI error (' .. tostring(app.safety.uiError) .. ')')

-- ---------------------------------------------------------------- not loaded, no LEDs

H.formulaCar(1)
env.carId = ''
env.storage = {}
loadApp()
frame(3)
text = capture()
check(has(text, 'Čekám na načtení auta…') and not drawn['Auto##rpmAutoStart'], 'no car yet: one line')

H.emptyCar()
env.storage = {}
loadApp()
frame(3)
text = capture()
check(rt.state == 'noleds' and has(text, 'Diody nenalezeny. Vyberte je na kartě Diody.')
  and not drawn['Auto##rpmAutoStart'], 'no LEDs: one line')
check(app.safety.uiError == nil, 'no UI error on the short lines (' .. tostring(app.safety.uiError) .. ')')

-- ---------------------------------------------------------------- no allocation with the tab open

H.formulaCar(1)
env.storage = {}
env.car.speedKmh = 120
env.car.rpm = 8000
loadApp()
show(10)
click('Zapnout##rpmLeds')
show(30)
local step = 0
local function sweep()
  step = step + 1
  env.car.rpm = 8000 + (step % 120) * 40
  show(1)
end
for _ = 1, 240 do sweep() end
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for _ = 1, 300 do sweep() end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
check(grown < 4, string.format('no per-frame allocation with the Otáčky tab open, per LED rows (%.2f KB / 300 frames)', grown))
if os.getenv('LC_SHOW_ALLOC') then print(string.format('alloc Otáčky: %.3f KB', grown)) end
env.windowOpen = false
check(app.safety.uiError == nil, 'no UI error (' .. tostring(app.safety.uiError) .. ')')

return H.finish('test_tab_rpm')
