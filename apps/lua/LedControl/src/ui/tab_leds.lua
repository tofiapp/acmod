-- Tab Diody (docs/ledcontrol-ui.md "Diody"): live preview of the LEDs per group in their real order (hover = the LED
-- blinks on the car, click = test colour), brightness with presets and the automatic day / night brightness, test
-- patterns, then collapsed sections: order and groups (led_map), takeover method, diagnostics. Without LEDs: one line
-- with manual picking and the diagnostics copy.

local csp = require('src/csp')
local ac, ui, vec2, rgbm, bit = csp.ac, csp.ui, csp.vec2, csp.rgbm, csp.bit
local K = require('src/ui/kit')
local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local color = require('src/color')
local detect = require('src/detect')
local diag = require('src/diag')
local selftest = require('src/selftest')
local safety = require('src/safety')
local ledMap = require('src/ui/led_map')

local S = config.S
local M = {}

local CELL = vec2(24, 24)
local CELL_GAP = 4
local CELL_STEP = 28
local COL2 = 280          -- x of the second column when two small groups share a row
local HALF = 8            -- a group of up to this many LEDs can share a row with another one
local GAP = vec2(1, 6)
local SLIDER_W = 120

local LABELS, PREVIEW, SHOWN, POS_TIPS = {}, {}, {}, {}
for i = 1, detect.MAX_LEDS do
  LABELS[i] = '##led' .. i
  PREVIEW[i] = rgbm(0, 0, 0, 1)
  POS_TIPS[i] = i .. '. dioda\nKlik: vlastní barva'      -- by the position in its group
end

-- test patterns: button -> runtime mode (runtime.MODES; 1 'Původní stav' = Vlastní + "Všechny zpět autu")
local MODE_OF = { 0, 2, 3, 4, 5, 6 }
local MODE_LABELS = { 'Provoz##mode0', 'Duha##mode2', 'Běh##mode3', 'Zhasnout##mode4', 'Bílá##mode5', 'Vlastní##mode6' }
local BRIGHT = { 12, 30, 50 }
local BRIGHT_LABELS = { 'Noc##bright1', 'Den##bright2', 'Slunce##bright3' }
local METHOD_LABELS = { 'A kopie##method1', 'B překreslení##method2', 'C přímý zápis##method3' }

local BASE_WORD = 'základ'
local BASE_TIP = 'Žádný scénář teď neběží, svítí základ presetu (karta Scénáře).'
local TIP_INTENSITY = 'Síla svitu diod (AC u svých diod používá zhruba 10 až 60).'
local HELP_AUTO = 'Jas podle denní doby: přes den (8–17 h) hodnota Den, v noci (do 6 h a od 20 h) hodnota Noc,'
  .. ' mezi tím plynule.'
local HELP_TEST = 'Provoz: diody řídí scénáře presetu.\nDuha, Běh, Zhasnout, Bílá: testovací vzor, scénáře neběží.\n'
  .. 'Vlastní: klikněte na diodu nahoře a vyberte barvu.\nŠedá dioda svítí podle auta. Pod myší dioda na autě bliká.'
local HELP_METHOD = 'A kopie: diody nahradí jejich kopie (doporučeno).\nB překreslení: přes diody se kreslí nové.\n'
  .. 'C přímý zápis: mění přímo barvu diod.\nKdyž diody nesedí, blikají nebo se nemění, zkuste B nebo C.\n'
  .. 'Volba platí pro toto auto.'
local OFF_HINT = 'Diody teď řídí auto. Zapněte „Zapnuto“ nahoře.'
local WARN_TEXT = 'Pořadí diod může být nepřesné'
local WAIT_TEXT = 'Čekám na načtení auta…'
local NONE_TEXT = 'Diody nenalezeny.'
local MANUAL_NONE = 'Ruční výběr nenašel žádnou diodu.'

local seen = -1
local groupNames, plan, tips, ledLines, rejectedLines = {}, {}, {}, {}, {}
local warningTip, summaryLine = '', ''
local diagText, diagAt = '', -10
local copiedUntil, redetectedUntil = 0, 0
local nowTexts = {}

local function refresh()
  local v = runtime.version              -- everything shown here comes from the layout (not the takeover stats)
  if v == seen then return end
  seen = v
  groupNames, plan, tips, ledLines, rejectedLines = {}, {}, {}, {}, {}
  warningTip, summaryLine = '', ''
  local lay = runtime.layout
  if not lay then return end
  -- preview rows: the main row alone, small groups two per row (Levé | Pravé)
  for gi = 1, #lay.groups do
    local g = lay.groups[gi]
    groupNames[gi] = g.name
    for k = 1, #g.leds do tips[g.leds[k]] = POS_TIPS[k] end
    local small = #g.leds <= HALF and g.role ~= 'main'
    local last = plan[#plan]
    if small and last and last.small and last[2] == 0 then last[2] = gi
    else plan[#plan + 1] = { gi, 0, small = small } end
  end
  local n = #lay.leds
  summaryLine = string.format('%d %s, skupiny %s, zdroj %s', n, K.plural(n, 'dioda', 'diody', 'diod'), lay.signature,
    lay.source)
  for i = 1, n do
    local led = lay.leds[i]
    ledLines[i] = string.format('%d. %s – %s%s, instancí %d', i, led.name, lay.groups[led.group].name,
      led.rpm and string.format(', RPM %d', led.rpm) or '', #led.inst)
  end
  for i = 1, #lay.rejected do
    local r = lay.rejected[i]
    rejectedLines[i] = string.format('%s (%s): %s', r.name, r.source, r.reason)
  end
  warningTip = table.concat(lay.warnings, '\n')
end

-- ---------------------------------------------------------------- preview

local fb, running, normal, compiled = nil, false, true, nil   -- set once per frame by preview()
local CELL_LOCKED = bit.bor(ui.ColorPickerFlags.NoPicker or 0, ui.ColorPickerFlags.NoTooltip or 0)
local shortNames = {}            -- scenario name -> shortened name for two-column rows (cached, no allocation)
local function shortName(name)
  local s = shortNames[name]
  if not s then s = K.shorten(name, 24); shortNames[name] = s end
  return s
end

local function cell(i)
  local c = PREVIEW[i]
  local p = running and fb[i] or color.ORIGINAL
  -- refreshed only when the LED changed from elsewhere: the picker gets its own (unquantised) value back
  if p ~= SHOWN[i] then
    if p < 0 then c.r, c.g, c.b = 0.22, 0.22, 0.24
    else c.r, c.g, c.b = color.unpack(p) end
    SHOWN[i] = p
  end
  -- while the LEDs are not taken over (master off, failed) a cell is only shown: no picker, no manual mode
  if ui.colorButton(LABELS[i], c, running and ui.ColorPickerFlags.PickerHueBar or CELL_LOCKED, CELL) and running then
    local q = color.pack(c.r, c.g, c.b)
    SHOWN[i] = q
    runtime.setManual(i, q)
  end
  if ui.itemHovered() then
    runtime.markHover(i)
    ui.setTooltip(tips[i] or POS_TIPS[i])
  end
end

-- group name + what paints it now (active scenario, or the preset's base)
local function groupCaption(gi, narrow)
  K.caption(groupNames[gi] or '')
  local g = normal and running and compiled and compiled.groups[gi]
  if g then
    ui.sameLine()
    if g.activeName then
      ui.textColored(narrow and shortName(g.activeName) or g.activeName, K.GREEN)
      if narrow then K.tip(g.activeName) end
    else
      ui.textColored(BASE_WORD, K.DIM)
      K.tip(BASE_TIP)
    end
  end
end

local function groupCells(gi, perRow)
  local leds = runtime.layout.groups[gi].leds
  for k = 1, #leds do
    if k > 1 and (k - 1) % perRow ~= 0 then ui.sameLine(0, CELL_GAP) end
    cell(leds[k])
  end
end

local function preview()
  fb, running, normal, compiled = runtime.fb, runtime.state == 'run', S.testMode == runtime.NORMAL, runtime.compiled
  local perRow = math.max(1, math.floor(math.min(ui.availableSpaceX(), K.ROW_W) / CELL_STEP))
  for r = 1, #plan do
    local a, b = plan[r][1], plan[r][2]
    groupCaption(a, b > 0)
    if b > 0 then ui.sameLine(COL2); groupCaption(b, true) end
    groupCells(a, b > 0 and HALF or perRow)
    if b > 0 then ui.sameLine(COL2); groupCells(b, HALF) end
  end
  if runtime.state == 'off' then K.dim(OFF_HINT) end
end

-- ---------------------------------------------------------------- brightness and test rows

local function nowText()
  local v = math.floor(runtime.effectiveIntensity() + 0.5)
  local s = nowTexts[v]
  if not s then s = 'teď ' .. v; nowTexts[v] = s end
  return s
end

local function brightIndex()
  for i = 1, #BRIGHT do if S.intensity == BRIGHT[i] then return i end end
  return 0
end

local function levelSlider(label, key)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider(label, S[key], 1, 100, '%.0f')
  if changed then runtime.setBrightness(key, math.floor(v + 0.5)) end
end

local function brightnessRows()
  K.label('Jas')
  if S.autoBrightness then
    ui.textColored(nowText(), K.GREY)
  else
    ui.setNextItemWidth(SLIDER_W)
    local v, changed = ui.slider('##intensity', S.intensity, 1, 100, '%.0f')
    if changed then runtime.setIntensity(math.floor(v + 0.5)) end
    K.tip(TIP_INTENSITY)
    ui.sameLine(0, 8)
    local i = K.choice(BRIGHT_LABELS, brightIndex())
    if i then runtime.setIntensity(BRIGHT[i]) end
  end
  ui.sameLine(0, 14)
  if ui.checkbox('Auto##autoBrightness', S.autoBrightness) then
    runtime.setBrightness('autoBrightness', not S.autoBrightness)
  end
  K.help(HELP_AUTO)
  if S.autoBrightness then
    K.label('Den')
    levelSlider('##intensityDay', 'intensityDay')
    K.label('Noc')
    levelSlider('##intensityNight', 'intensityNight')
  end
end

local function modeIndex()
  for i = 1, #MODE_OF do if MODE_OF[i] == S.testMode then return i end end
  return 0
end

local function testRow()
  K.label('Test')
  local i = K.choice(MODE_LABELS, modeIndex())
  if i then runtime.setMode(MODE_OF[i]) end
  K.help(HELP_TEST)
  if S.testMode == runtime.MANUAL then
    K.label('')
    if ui.button('Všechny zpět autu##allBack') then
      for k = 1, runtime.n do runtime.manual[k] = color.ORIGINAL end
    end
  end
end

-- ---------------------------------------------------------------- sections

local function copyButton()
  if ui.button('Kopírovat diagnostiku') then
    ac.setClipboardText(diag.text())
    copiedUntil = runtime.clock + 2
  end
  if runtime.clock < copiedUntil then
    ui.sameLine()
    ui.textColored('Zkopírováno', K.GREEN)
  end
end

-- "Znovu najít": detection runs again; "Hotovo" for a few seconds, also when the result looks the same
local function redetectButton(label)
  if ui.button(label) then
    runtime.restart('redetect')
    redetectedUntil = runtime.clock + 3
  end
  K.tip('Hledá diody na autě znovu (s rovným volantem).')
  if runtime.clock < redetectedUntil and runtime.state ~= 'wait' then
    ui.sameLine()
    ui.textColored('Hotovo', K.GREEN)
  end
end

local function methodContent()
  local m = K.choice(METHOD_LABELS, runtime.method())
  if m then runtime.setMethod(m) end
  K.help(HELP_METHOD)
end

local copyInDiag = true
-- Self-test: start / stop, progress, the protocol (lines kept by selftest.lua) and a copy button
local SELFTEST_HELP = 'Projde všechny scénáře presetu a stránky displeje, každý na pár sekund, a zkontroluje skutečnou '
  .. 'barvu diod (čte ji zpět z materiálu). Protokol jde zkopírovat a poslat. Trvá asi minutu; auto může stát v boxech.'
local selftestProgress, seenSelftest = '', -1
local function selftestRows()
  if selftest.running then
    if seenSelftest ~= selftest.version then
      seenSelftest = selftest.version
      selftestProgress = string.format('Self-test: krok %d / %d – %s', selftest.step, selftest.total, selftest.current)
    end
    ui.text(selftestProgress)
    if ui.button('Zastavit##selftestStop') then selftest.stop() end
    return
  end
  if ui.button('Self-test##selftest') then selftest.start() end
  K.help(SELFTEST_HELP)
  if selftest.done then
    ui.sameLine()
    if ui.button('Kopírovat protokol##selftestCopy') then selftest.copy() end
    local lines = selftest.lines
    for i = 1, #lines do
      local l = lines[i]
      local b = l:byte(1)
      if b == 70 then ui.textColored(l, K.RED)          -- 'FAIL'
      elseif b == 79 and l:byte(2) == 75 then ui.textColored(l, K.GREEN)   -- 'OK'
      elseif b == 83 and l:byte(2) == 75 then K.dim(l)  -- 'SKIP'
      else ui.text(l) end
    end
  end
end

local function diagContent()
  selftestRows()
  ui.text(summaryLine)
  for i = 1, #ledLines do ui.text(ledLines[i]) end
  if #rejectedLines > 0 then
    K.caption('Odmítnuté')
    for i = 1, #rejectedLines do K.dim(rejectedLines[i]) end
  end
  redetectButton('Znovu najít##redetect')
  if copyInDiag then
    ui.sameLine()
    copyButton()
  end
  if ui.checkbox('Celý text##showDiag', S.showDiag) then config.set('showDiag', not S.showDiag) end
  if S.showDiag then
    if runtime.clock - diagAt > 1 then diagText, diagAt = diag.text(), runtime.clock end
    ui.textWrapped(diagText)
  end
end

local function warningLine()
  ui.textColored(WARN_TEXT, K.ORANGE)
  K.help(warningTip)
  ui.sameLine()
  redetectButton('Znovu najít##warnRedetect')
end

-- No LEDs: one line, manual picking inline, diagnostics below.
local function noLeds(lay)
  ui.text(NONE_TEXT)
  if not ledMap.open then
    ui.sameLine()
    if ui.button('Vybrat diody ručně##mapStart') then ledMap.startPicking() end
  end
  ui.sameLine()
  copyButton()
  if lay.manual and not ledMap.open then
    K.dim(MANUAL_NONE)
    ui.sameLine()
    if ui.button('Automaticky##mapAuto') then runtime.setMap(nil) end
  end
  if ledMap.open then ledMap.content() end
  copyInDiag = false
  K.section('Diagnostika##diag', false, diagContent)
end

local function draw()
  refresh()
  local lay = runtime.layout
  if safety.error then
    copyButton()        -- the header says what happened; the diagnostics carry the full error
    return
  end
  if not lay or runtime.state == 'wait' then
    K.dim(WAIT_TEXT)
    return
  end
  if #lay.leds == 0 then
    noLeds(lay)
    return
  end
  if warningTip ~= '' then warningLine() end
  preview()
  ui.dummy(GAP)
  brightnessRows()
  testRow()
  ui.dummy(GAP)
  K.section(ledMap.label(), false, ledMap.content)
  K.section('Způsob převzetí##method', false, methodContent)
  copyInDiag = true
  K.section('Diagnostika##diag', false, diagContent)
end

M.draw = draw

return M
