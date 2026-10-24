-- Tab Diody: takeover method, brightness, live preview of the LEDs in their real order per group (hover = the LED
-- blinks on the car, click = pick its colour), test patterns, LED list, rejected candidates, diagnostics.

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local color = require('src/color')
local detect = require('src/detect')
local diag = require('src/diag')
local ledMap = require('src/ui/led_map')

local S = config.S
local M = {}

local ORANGE = rgbm(1, 0.7, 0.2, 1)
local GREY = rgbm(0.6, 0.6, 0.6, 1)
local CELL = vec2(24, 24)
local CELL_STEP = 28

local LABELS, PREVIEW = {}, {}
for i = 1, detect.MAX_LEDS do
  LABELS[i] = '##led' .. i
  PREVIEW[i] = rgbm(0, 0, 0, 1)
end
local MODE_LABELS, MODE_ACTIVE, MODE_NAMES = {}, {}, {}
MODE_NAMES[0] = 'Normální provoz'
for i = 1, #runtime.MODES do MODE_NAMES[i] = 'Test: ' .. runtime.MODES[i] end
for i = 0, #runtime.MODES do
  MODE_LABELS[i] = MODE_NAMES[i] .. '##mode' .. i
  MODE_ACTIVE[i] = '> ' .. MODE_NAMES[i] .. ' <##mode' .. i
end
local GREEN = rgbm(0.4, 1, 0.5, 1)

local seen = -1
local groupLabels, tips, ledLines, rejectedLines, warningLines = {}, {}, {}, {}, {}
local diagText, diagAt = '', -10
local copiedUntil = 0

local function refresh()
  local v = runtime.version * 100000 + takeover.version
  if v == seen then return end
  seen = v
  groupLabels, tips, ledLines, rejectedLines, warningLines = {}, {}, {}, {}, {}
  local lay = runtime.layout
  if not lay then return end
  for gi = 1, #lay.groups do
    local g = lay.groups[gi]
    groupLabels[gi] = string.format('%s – %d %s', g.name, #g.leds, #g.leds == 1 and 'dioda' or (#g.leds < 5 and 'diody' or 'diod'))
  end
  for i = 1, #lay.leds do
    local led = lay.leds[i]
    tips[i] = string.format('%d. %s\nNa autě teď bliká bíle.\nKlik = vlastní barva.', i, led.name)
    ledLines[i] = string.format('%d. %s – %s, zdroj %s%s, instancí %d', i, led.name, lay.groups[led.group].name,
      led.source, led.rpm and string.format(', RPM %d', led.rpm) or '', #led.inst)
  end
  for i = 1, #lay.rejected do
    local r = lay.rejected[i]
    rejectedLines[i] = string.format('%s (%s): %s', r.name, r.source, r.reason)
  end
  for i = 1, #lay.warnings do warningLines[i] = lay.warnings[i] end
end

local function methodRow()
  ui.text('Způsob převzetí diod:')
  local cur = runtime.method()
  for m = 1, 3 do
    if ui.radioButton(takeover.NAMES[m], cur == m) and cur ~= m then runtime.setMethod(m) end
    if m < 3 then ui.sameLine() end
  end
  ui.textWrapped('A je doporučená. Když diody na autě nesedí, blikají nebo se nemění, zkuste B a C.')
  local v, changed = ui.slider('##intensity', S.intensity, 1, 100, 'Jas diod: %.0f')
  if changed then runtime.setIntensity(math.floor(v + 0.5)) end
end

local function modeRow()
  ui.text('Co diody ukazují:')
  local avail = ui.availableSpaceX()
  local used = 0
  for i = 0, #runtime.MODES do
    local w = 12 + 8 * #MODE_NAMES[i]
    if i > 0 then
      if used + w < avail then ui.sameLine() else used = 0 end
    end
    used = used + w
    if ui.button(S.testMode == i and MODE_ACTIVE[i] or MODE_LABELS[i]) then runtime.setMode(i) end
  end
end

local function preview()
  local lay = runtime.layout
  local fb = runtime.fb
  local running = runtime.state == 'run'
  local perRow = math.max(1, math.floor(ui.availableSpaceX() / CELL_STEP))
  local C = runtime.compiled
  local normal = S.testMode == runtime.NORMAL
  for gi = 1, #lay.groups do
    local g = lay.groups[gi]
    ui.text(groupLabels[gi] or '')
    if normal and running and C and C.groups[gi] then
      ui.sameLine()
      ui.textColored(C.groups[gi].activeName or '(nic, základ presetu)', GREEN)
    end
    for k = 1, #g.leds do
      local i = g.leds[k]
      local c = PREVIEW[i]
      local p = running and fb[i] or color.ORIGINAL
      if p < 0 then c.r, c.g, c.b = 0.22, 0.22, 0.24
      else c.r, c.g, c.b = color.unpack(p) end
      if k > 1 and (k - 1) % perRow ~= 0 then ui.sameLine() end
      if ui.colorButton(LABELS[i], c, ui.ColorPickerFlags.PickerHueBar, CELL) then
        runtime.setManual(i, color.pack(c.r, c.g, c.b))
      end
      if ui.itemHovered() then
        runtime.markHover(i)
        ui.setTooltip(tips[i] or '')
      end
    end
  end
  ui.textColored('Šedá = dioda řízená autem. Najetím myší dioda na autě bliká, klik = vlastní barva (test).', GREY)
  if S.testMode == runtime.MANUAL and ui.button('Všechny zpět autu') then
    for i = 1, runtime.n do runtime.manual[i] = color.ORIGINAL end
  end
end

local function draw()
  refresh()
  methodRow()
  ui.separator()
  local lay = runtime.layout
  if not lay or runtime.state == 'wait' then
    ui.text('Čekám na načtení auta…')
    return
  end
  for i = 1, #warningLines do ui.textColored(warningLines[i], ORANGE) end
  if #lay.leds == 0 then
    ui.textWrapped('Na tomto autě jsem nenašel žádné diody (digital_instruments.ini, CSP config, označení actsAsLED ani'
      .. ' jména meshů). Vyberte je ručně ze seznamu meshů kokpitu tlačítkem níže.')
  else
    modeRow()
    preview()
  end
  ledMap.draw()
  if ui.button('Znovu najít diody') then runtime.restart('redetect') end
  ui.sameLine()
  if ui.button('Kopírovat diagnostiku') then
    ac.setClipboardText(diag.text())
    copiedUntil = runtime.clock + 2
  end
  if runtime.clock < copiedUntil then
    ui.sameLine()
    ui.text('Zkopírováno')
  end
  ui.separator()
  for i = 1, #ledLines do ui.text(ledLines[i]) end
  if #rejectedLines > 0 then
    ui.text('Odmítnuté kandidáty:')
    for i = 1, #rejectedLines do ui.textColored(rejectedLines[i], GREY) end
  end
  if ui.checkbox('Zobrazit diagnostiku', S.showDiag) then config.set('showDiag', not S.showDiag) end
  if S.showDiag then
    if runtime.clock - diagAt > 1 then diagText, diagAt = diag.text(), runtime.clock end
    ui.textWrapped(diagText)
  end
end

M.draw = draw

return M
