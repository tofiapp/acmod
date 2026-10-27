-- Tab Otáčky: the RPM range of this car for the shift lights (src/rpm.lua). On top the live RPM (big number, a bar
-- with the start / shift / limiter markers and the main row as the car shows it now), below three rows (Začátek,
-- Plno / řazení, Omezovač) with Auto, a slider and [Teď], the learned limiter with [Zapomenout], and a collapsed
-- section with an RPM value for every LED of the main row.
-- Drawing: ui.drawRectFilled in window coordinates from ui.getCursorX / getCursorY, then ui.dummy reserves the space
-- (ControllerTweaks drawCurveBase); ui.pushFont(ui.Font.Title) (WebBrowser Blanks). No allocation per frame: labels
-- are prebuilt, texts are rebuilt only when rpm / preset / runtime versions change, RPM numbers come from caches.

local K = require('src/ui/kit')
local runtime = require('src/runtime')
local presets = require('src/presets')
local patterns = require('src/patterns')
local color = require('src/color')
local detect = require('src/detect')
local LIMITER_AT = require('src/scenarios').LIMITER_AT

local rpm = runtime.rpm
local ST = runtime.ST
local M = {}

local floor = math.floor

-- ---------------------------------------------------------------- layout and labels

local SLIDER_X = 222            -- value / slider column of the three rows (after "[x] Auto")
local SLIDER_W = 188            -- 222 + 188 = 410
local NOW_X = 418               -- [Teď] column of every row
local BAR_H = 12
local MIN_RPM = 1000            -- slider minimum; [Teď] needs the engine above it
local STEP = 50                 -- slider step

local KEYS = { 'start', 'shift', 'limiter' }
local NAMES = { 'Začátek', 'Plno / řazení', 'Omezovač' }
local TIPS = {
  'Při těchto otáčkách se rozsvítí první dioda.',
  'Všechny diody svítí, čas přeřadit.',
  'Od těchto otáček diody blikají.',
}
local AUTO = { 'Auto##rpmAutoStart', 'Auto##rpmAutoShift', 'Auto##rpmAutoLimiter' }
local SLIDERS = { '##rpmStart', '##rpmShift', '##rpmLimiter' }
local NOW = { 'Teď##rpmNowStart', 'Teď##rpmNowShift', 'Teď##rpmNowLimiter' }
local MARK = { K.GREEN, K.BLUE, K.RED }
local NOW_TIP = 'Vezme aktuální otáčky motoru.'

local FORGET = 'Zapomenout##rpmForget'
local FORGET_TIP = 'Smaže naměřený omezovač tohoto auta.'
local SECTION = 'Každá dioda zvlášť##rpmLeds'
local LEDS_ON = 'Zapnout##rpmLeds'
local LEDS_HELP = 'Každá dioda řady se rozsvítí při svých otáčkách. Zapnutí je rozloží rovnoměrně od začátku po krok před řazením.'
local SPREAD = 'Rozložit rovnoměrně##rpmSpread'
local SPREAD_TIP = 'Od začátku po krok před řazením, aby byla plná řada vidět dřív, než začne blikání.'
local FROM_CAR = 'Podle auta##rpmFromCar'
local FROM_CAR_TIP = 'Otáčky, při kterých diody rozsvěcí auto samo.'
local DOT_TIP = 'Na autě teď bliká.'
local MAX_TIP = 'Nejvyšší otáčky od načtení auta.'

local WAITING = 'Čekám na načtení auta…'
local NO_LEDS = 'Diody nenalezeny. Vyberte je na kartě Diody.'
local MASTER_OFF = 'Zapněte hlavní vypínač.'
local ENGINE_OFF = 'Motor neběží.'
local HINT_NO_SHIFT = 'Preset nepoužívá řadicí světla (karta Scénáře).'
local HINT_START = 'Začátek je nad bodem řazení.'
local HINT_SHIFT = 'Řazení je nad omezovačem, diody nedosvítí.'
local HINT_LEDS = 'Některé diody jsou nad omezovačem.'

local LIMITER_FROM = {
  ['naměřeno ve hře'] = 'Naměřeno ve hře.',
  ['z auta'] = 'Zdroj: data auta.',
  ['neznámý'] = 'Neznámý: bliká, jen když omezovač hlásí hra.',
}

local MAX_LEDS = detect.MAX_LEDS
local IDX, LED_SLIDERS, LED_NOW = {}, {}, {}
local LEDC, LEDC_DIM, CELLC = {}, {}, {}
for k = 1, MAX_LEDS do
  IDX[k] = tostring(k)
  LED_SLIDERS[k] = '##rpmLed' .. k
  LED_NOW[k] = 'Teď##rpmNowLed' .. k
  LEDC[k], LEDC_DIM[k], CELLC[k] = rgbm(1, 1, 1, 1), rgbm(0.3, 0.3, 0.3, 1), rgbm(0.3, 0.3, 0.3, 1)
end

local BAR_BG = rgbm(0.16, 0.16, 0.18, 1)
local BAR_IDLE = rgbm(0.55, 0.55, 0.58, 1)
local p1, p2 = vec2(), vec2()
local barSize, cellsSize = vec2(), vec2()

-- ---------------------------------------------------------------- numbers as text (cached, no allocation)

local function grouped(n)
  n = floor(n + 0.5)
  if n >= 1000 then return string.format('%d %03d', floor(n / 1000), n % 1000) end
  return tostring(n)
end

-- big number and "max": one string per 10 rpm, built once
local rpmTexts, maxTexts = {}, {}
local function cachedText(cache, v, prefix, suffix)
  if v ~= v or v < 0 then v = 0 elseif v > 30000 then v = 30000 end
  local key = floor(v / 10 + 0.5)
  local s = cache[key]
  if not s then
    s = prefix .. grouped(key * 10) .. suffix
    cache[key] = s
  end
  return s
end

-- ---------------------------------------------------------------- state rebuilt on a version change

local seenRpm, seenPresets, seenRuntime = -1, -1, -1
local main, n = nil, 0               -- main row (group with role 'main') and its LED count
local shiftOn = true                 -- the preset's shift lights scenario is on
local start = 0                      -- effective start (manual, else the preset's percentage of the shift point)
local value, manual = { 0, 0, 0 }, { false, false, false }
local valueText, helpText = { '', '', '' }, { nil, nil, nil }
local learnedText = nil
local ledsOn, ledMin, ledMax = false, 0, 0
local mismatch = nil                 -- per LED values stored for another LED count
local carList = nil                  -- the car's own RPM per LED of the main row (all of them), else nil
local hint = nil
local message, messageUntil = nil, 0

local function zoneColour(cl, u)
  local zu, zc = cl.zu, cl.zc
  local col = zc[1]
  for i = 2, #zu do
    if zu[i] <= u + 1e-9 then col = zc[i] else break end
  end
  return col
end

local function setColours(k, packed)
  local r, g, b = color.unpack(packed)
  if r + g + b < 0.1 then r, g, b = 0.4, 0.4, 0.42 end
  LEDC[k].r, LEDC[k].g, LEDC[k].b = r, g, b
  LEDC_DIM[k].r, LEDC_DIM[k].g, LEDC_DIM[k].b = 0.1 + r * 0.25, 0.1 + g * 0.25, 0.1 + b * 0.25
end

local function refresh()
  if rpm.version == seenRpm and presets.version == seenPresets and runtime.version == seenRuntime then return end
  seenRpm, seenPresets, seenRuntime = rpm.version, presets.version, runtime.version
  local lay = runtime.layout
  main = nil
  if lay then
    for gi = 1, #lay.groups do
      if lay.groups[gi].role == 'main' then main = lay.groups[gi]; break end
    end
    main = main or lay.groups[1]
  end
  n = main and math.min(#main.leds, MAX_LEDS) or 0

  -- the preset's shift lights: start percentage, on / off, fill colours
  local preset = runtime.preset()
  local entry = nil
  local list = presets.effective(preset)
  for i = 1, #list do if list[i].id == 'shiftLights' then entry = list[i] end end
  local pct = entry and tonumber(entry.param) or 75
  shiftOn = entry ~= nil and entry.on ~= false
  local autoStart = floor(rpm.shift * pct / 100 + 0.5)
  start = rpm.start > 0 and rpm.start or autoStart
  local cl = patterns.compile(entry and entry.look)

  local c = runtime.profile and runtime.profile.rpm or {}
  value[1], value[2], value[3] = start, rpm.shift, rpm.limiter
  manual[1], manual[2], manual[3] = rpm.manual.start, rpm.manual.shift, rpm.manual.limiter
  for i = 1, 3 do valueText[i] = grouped(value[i]) end
  helpText[1] = string.format('Auto: %d %% bodu řazení (preset %s).', pct, preset and preset.name or '')
  helpText[2] = 'Zdroj: ' .. tostring(rpm.auto.shiftFrom or '') .. '.'
  local from = rpm.auto.limiterFrom or ''
  helpText[3] = LIMITER_FROM[from] or ('Zdroj: ' .. from .. '.')
  learnedText = nil
  if rpm.learned > 0 then
    -- the number only when the row shows another one (a manual limiter)
    if manual[3] and rpm.limiter ~= rpm.learned then learnedText = 'naměřeno ' .. grouped(rpm.learned)
    else learnedText = 'naměřeno ve hře' end
    if not manual[3] then helpText[3] = nil end
  end

  -- RPM per LED
  local leds = rpm.ledRpm
  ledsOn = leds ~= nil and n > 0 and #leds == n
  mismatch = nil
  if leds and not ledsOn and n > 0 then
    mismatch = string.format('Uloženo pro %d %s, řada má %d.', #leds, K.plural(#leds, 'diodu', 'diody', 'diod'), n)
  end
  ledMin, ledMax = math.huge, 0
  if ledsOn then
    for k = 1, n do
      if leds[k] < ledMin then ledMin = leds[k] end
      if leds[k] > ledMax then ledMax = leds[k] end
    end
  end
  carList = nil
  if lay and n > 0 then
    carList = {}
    for k = 1, n do
      local r = tonumber(lay.leds[main.leds[k]].rpm)
      if not r or r <= 0 then carList = nil; break end
      carList[k] = r
    end
  end

  -- cell / dot colours as the engine paints them: by RPM rank with per-LED values or the car's own thresholds,
  -- else by the LED's rank along the preset's fill direction (GT3 styl: from both edges)
  local carLo, carHi = math.huge, 0
  if carList then for k = 1, n do carLo, carHi = math.min(carLo, carList[k]), math.max(carHi, carList[k]) end end
  local half = floor((n + 1) / 2)
  for k = 1, n do
    local u
    if ledsOn then u = ledMax > ledMin and (leds[k] - ledMin) / (ledMax - ledMin) or 1
    elseif cl.src == 'car' and carList then u = carHi > carLo and (carList[k] - carLo) / (carHi - carLo) or 1
    else
      local r, len = k, n
      if cl.dir == 'right' then r = n - k + 1
      elseif cl.dir == 'edges' or cl.dir == 'centre' then
        r, len = math.min(k, n - k + 1), half
        if cl.dir == 'centre' then r = half - r + 1 end
      end
      u = len > 1 and (r - 1) / (len - 1) or 1
    end
    setColours(k, cl.p == 'fill' and zoneColour(cl, u) or cl.c1)
  end

  local limit = rpm.limiter * LIMITER_AT
  if not shiftOn then hint = HINT_NO_SHIFT
  elseif ledsOn and ledMax >= limit then hint = HINT_LEDS
  elseif not ledsOn and start >= rpm.shift then hint = HINT_START
  elseif rpm.shift >= limit then hint = HINT_SHIFT
  else hint = nil end
end

-- ---------------------------------------------------------------- actions

local function snap(v, hi)
  v = floor(v / STEP + 0.5) * STEP
  if v < MIN_RPM then v = MIN_RPM elseif v > hi then v = hi end
  return v
end

-- current RPM rounded to 10, or nil (with a short message) when the engine is not running
local function nowRpm()
  local r = ST.rpm
  if not r or r < MIN_RPM then
    message, messageUntil = ENGINE_OFF, runtime.clock + 3
    return nil
  end
  return floor(r / 10 + 0.5) * 10
end

-- slider maximum: never from the value being dragged (it would run away), from the car's own limiter and the RPM seen
local function rangeMax()
  local hi = math.max(9000, (rpm.auto.limiter or 0) * 1.25, rpm.maxSeen * 1.05)
  return math.ceil(hi / 500) * 500
end

-- ---------------------------------------------------------------- live part

local function bigNumber()
  ui.pushFont(ui.Font.Title)
  ui.text(cachedText(rpmTexts, ST.rpm, '', ' ot/min'))
  ui.popFont()
  if rpm.maxSeen > 0 then
    ui.sameLine(NOW_X)
    K.dim(cachedText(maxTexts, rpm.maxSeen, 'max ', ''))
    K.tip(MAX_TIP)
  end
end

local function xAt(v, x0, w, range)
  local f = v / range
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return x0 + w * f
end

local function rect(x1, y1, x2, y2, colour)
  p1:set(x1, y1)
  p2:set(x2, y2)
  ui.drawRectFilled(p1, p2, colour)
end

-- 0 .. limiter * 1.05: the fill takes the colour of the last marker passed (grey before the start)
local function bar(w)
  local x0, y0 = ui.getCursorX(), ui.getCursorY() + 4
  local range = math.max(rpm.limiter * 1.05, 1)
  local r = ST.rpm
  local first = ledsOn and ledMin or start
  local fill = BAR_IDLE
  if ST.engineLimiter or r >= rpm.limiter * LIMITER_AT then fill = K.RED
  elseif r >= rpm.shift then fill = K.BLUE
  elseif r >= first then fill = K.GREEN end
  rect(x0, y0, x0 + w, y0 + BAR_H, BAR_BG)
  rect(x0, y0, xAt(r, x0, w, range), y0 + BAR_H, fill)
  if ledsOn then
    local leds = rpm.ledRpm
    for k = 1, n do
      local x = xAt(leds[k], x0, w, range)
      rect(x, y0 + BAR_H, x + 1, y0 + BAR_H + 4, LEDC[k])
    end
  end
  for i = 1, 3 do
    local x = xAt(value[i], x0, w, range)
    rect(x - 1, y0 - 3, x + 1, y0 + BAR_H + 3, MARK[i])
  end
  ui.dummy(barSize:set(w, BAR_H + 12))
end

-- the main row as the car shows it now (grey = the car's own logic)
local function cells(w)
  if n == 0 then return end
  local x0, y0 = ui.getCursorX(), ui.getCursorY()
  local step = floor(w / n)
  if step > 20 then step = 20 elseif step < 6 then step = 6 end
  local size = step - 4
  local fb = runtime.fb
  local running = runtime.state == 'run'
  for k = 1, n do
    local p = running and fb[main.leds[k]] or color.ORIGINAL
    local c = CELLC[k]
    if p == nil or p < 0 then c.r, c.g, c.b = 0.3, 0.3, 0.32
    else
      local r, g, b = color.unpack(p)
      if r + g + b < 0.08 then r, g, b = 0.12, 0.12, 0.13 end
      c.r, c.g, c.b = r, g, b
    end
    local x = x0 + (k - 1) * step
    p1:set(x, y0)
    p2:set(x + size, y0 + size)
    ui.drawRectFilled(p1, p2, c, 2)
  end
  ui.dummy(cellsSize:set(n * step, size + 2))
end

-- ---------------------------------------------------------------- rows

-- small coloured bar at the end of the label column: the same colour as the row's marker on the bar (drawn into the
-- free space of the label column, so it takes no item of its own)
local function legend(colour)
  local y = ui.getCursorY()
  rect(K.LABEL_W - 12, y + 2, K.LABEL_W - 9, y + 17, colour)
end

local function row(i, hi)
  legend(MARK[i])
  K.label(NAMES[i])
  K.tip(TIPS[i])
  local key = KEYS[i]
  if ui.checkbox(AUTO[i], not manual[i]) then
    if manual[i] then rpm.set(key, nil, ST) else rpm.set(key, value[i], ST) end
    refresh()
  end
  ui.sameLine(SLIDER_X)
  if manual[i] then
    ui.setNextItemWidth(SLIDER_W)
    local v, changed = ui.slider(SLIDERS[i], value[i], MIN_RPM, hi, '%.0f')
    if changed then rpm.set(key, snap(v, hi), ST) end
  else
    ui.text(valueText[i])
    if helpText[i] then K.help(helpText[i]) end
  end
  ui.sameLine(NOW_X)
  if ui.button(NOW[i]) then
    local r = nowRpm()
    if r then rpm.set(key, r, ST) end
  end
  K.tip(NOW_TIP)
end

local function learnedRow()
  if not learnedText then return end
  ui.text('')
  ui.sameLine(SLIDER_X)
  K.dim(learnedText)
  ui.sameLine(0, 10)
  if ui.button(FORGET) then rpm.forgetLearned(ST) end
  K.tip(FORGET_TIP)
end

-- ---------------------------------------------------------------- per LED section

-- direction in which the car's preset fills the row, so "spread" lights the LEDs in the same order
local function fillDir()
  local list = presets.effective(runtime.preset())
  for i = 1, #list do
    local e = list[i]
    if e.id == 'shiftLights' then return e.look and e.look.dir or 'left' end
  end
  return 'left'
end

local function ledSection()
  if ui.checkbox(LEDS_ON, ledsOn) then
    if ledsOn then rpm.setLeds(nil, ST) else rpm.spread(n, start, ST, fillDir()) end
  end
  K.help(LEDS_HELP)
  if ledsOn then
    ui.sameLine(0, 14)
    if ui.button(SPREAD) then rpm.spread(n, start, ST, fillDir()) end
    K.tip(SPREAD_TIP)
  end
  if carList then
    ui.sameLine(0, ledsOn and 6 or 14)
    if ui.button(FROM_CAR) then rpm.setLeds(carList, ST) end
    K.tip(FROM_CAR_TIP)
  end
  refresh()                                    -- a click above switched or replaced the values
  if mismatch then K.note(mismatch, K.ORANGE) end
  if not ledsOn then return end
  local leds = rpm.ledRpm
  local hi = rangeMax()
  local r = ST.rpm
  for k = 1, n do
    ui.text(IDX[k])
    ui.sameLine(0, 6)
    K.dot(r >= leds[k] and LEDC[k] or LEDC_DIM[k])
    if ui.itemHovered() then
      runtime.markHover(main.leds[k])
      ui.setTooltip(DOT_TIP)
    end
    ui.sameLine(K.LABEL_W)
    ui.setNextItemWidth(K.CONTROL_W)
    local v, changed = ui.slider(LED_SLIDERS[k], leds[k], MIN_RPM, hi, '%.0f')
    if changed then rpm.setLed(k, snap(v, hi), ST) end
    ui.sameLine(NOW_X)
    if ui.button(LED_NOW[k]) then
      local now = nowRpm()
      if now then rpm.setLed(k, now, ST) end
    end
    K.tip(NOW_TIP)
    if leds ~= rpm.ledRpm then break end      -- switched off or replaced this frame
  end
end

-- ---------------------------------------------------------------- tab

local function draw()
  local lay = runtime.layout
  if not lay or runtime.state == 'wait' then
    ui.text(WAITING)
    return
  end
  if #lay.leds == 0 then
    ui.text(NO_LEDS)
    return
  end
  refresh()
  local w = math.min(ui.availableSpaceX(), K.ROW_W)
  bigNumber()
  bar(w)
  cells(w)
  if runtime.state == 'off' then K.dim(MASTER_OFF) end
  local hi = rangeMax()
  for i = 1, 3 do
    row(i, hi)
    refresh()                                  -- a click above changed the values: the next row shows them now
  end
  learnedRow()
  refresh()
  if hint then K.note(hint, K.ORANGE) end
  if message then
    if runtime.clock < messageUntil then K.note(message, K.ORANGE) else message = nil end
  end
  K.section(SECTION, ledsOn, ledSection)
end

M.draw = draw

return M
