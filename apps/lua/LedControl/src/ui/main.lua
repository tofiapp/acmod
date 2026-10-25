-- The window: header (master switch, state, car, preset, one short line per problem) and the tabs.
-- Layout as docs/ledcontrol-ui.md "Header". Car name: ac.getCarName(0) (as RallyCopilot / SetupExchange use it), read
-- once per car under pcall, else the car id. Explanations sit in (?) tooltips, the main view stays short.

local K = require('src/ui/kit')
local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')
local presets = require('src/presets')
local lights = require('src/lights')

local S = config.S
local M = {}

local MASTER = 'Zapnuto##master'
local RETRY = 'Zkusit znovu##retry'
local HIDE_UI_ERROR = 'Skrýt##uiError'
local BACK_TO_NORMAL = 'Zpět na provoz##hdrNormal'
local CAR_NAME_MAX = 40

-- state -> word, colour, tooltip (the dot and the word carry the state, the tooltip says what it means)
local STATUS = {
  run = { 'běží', K.GREEN, 'Diody na autě řídí LedControl.' },
  off = { 'vypnuto', K.DIM, 'Hlavní vypínač je vypnutý: diody řídí auto.' },
  wait = { 'čeká na auto', K.DIM, 'Auto se ještě načítá.' },
  noleds = { 'bez diod', K.ORANGE, 'Na tomto autě nejsou rozpoznané diody (karta Diody).' },
  failed = { 'nefunguje', K.RED, 'Diody nejde převzít žádným způsobem.' },
  error = { 'chyba', K.RED, 'Nastala chyba, diody jsou vrácené autu.' },
}

local ERROR_TEXT = 'Chyba – diody jsou vrácené autu'
local UI_ERROR_TEXT = 'Chyba v okně'
local ONLINE_TEXT = 'Online: skutečná světla vidí i ostatní'
local TEST_TEXT = 'Testovací vzor'
local TEST_HELP = 'Diody ukazují testovací vzor z karty Diody (řádek Test), scénáře presetu teď neběží.'
local PRESET_TIP = 'Preset pro toto auto (každé auto si pamatuje svůj).'

-- "Běží B – překreslení" when another method than the chosen one runs (short names as in the Diody tab)
local SHORT_METHOD = { 'A – kopie', 'B – překreslení', 'C – přímý zápis' }
local FALLBACK_TEXT = {}
for m = 1, 3 do FALLBACK_TEXT[m] = 'Běží ' .. SHORT_METHOD[m] end

local seenError = nil
local errorTip = ''
local carShown, carName = nil, ''

-- Cuts a UTF-8 string to at most n bytes without splitting a character.
local function shorten(s, n)
  if #s <= n then return s end
  local cut = n
  while cut > 1 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end     -- the next byte starts a character: cut here
    cut = cut - 1
  end
  return s:sub(1, cut) .. '…'
end

-- Strings rebuilt only when what they show changed (car, error).
local function refresh()
  if runtime.carId ~= carShown then
    carShown = runtime.carId
    local name = nil
    if carShown ~= '' and ac.getCarName then
      local ok, n = pcall(ac.getCarName, 0)
      if ok and type(n) == 'string' and n ~= '' then name = n end
    end
    carName = shorten(name or carShown, CAR_NAME_MAX)
  end
  if safety.error ~= seenError then
    seenError = safety.error
    errorTip = safety.error and string.format('%s (%s)\n\nCelý text je v „Kopírovat diagnostiku“ (karta Diody).',
      safety.error, tostring(safety.where)) or ''
  end
end

-- Tabs are loaded on first use under pcall, so a broken tab shows its error instead of stopping the window.
local TABS = {
  { 'Diody', 'src/ui/tab_leds' },
  { 'Otáčky', 'src/ui/tab_rpm' },
  { 'Scénáře', 'src/ui/tab_scenarios' },
  { 'Editor', 'src/ui/tab_editor' },
  { 'Světla', 'src/ui/tab_lights' },
  { 'Nastavení', 'src/ui/tab_settings' },
}
local loaded, loadErrors, drawers = {}, {}, {}
local drawnTab = 0

local function tabDrawer(i)
  return function ()
    drawnTab = i
    local mod = loaded[i]
    if mod == nil then
      local ok, res = pcall(require, TABS[i][2])
      if ok and type(res) == 'table' and type(res.draw) == 'function' then mod = res
      else mod = false; loadErrors[i] = 'Karta se nenačetla: ' .. tostring(res) end
      loaded[i] = mod
    end
    if mod then mod.draw() else K.note(loadErrors[i], K.RED) end
  end
end
for i = 1, #TABS do drawers[i] = tabDrawer(i) end

-- header combo labels carry the preset id, so two presets with one name never share an ImGui id
local presetLabels, labelsVersion = {}, -1
local allPresets = {}
local function presetItems()
  if labelsVersion ~= presets.version then
    -- the list and its labels are rebuilt only when presets change, not every frame the combo is open
    presetLabels, labelsVersion, allPresets = {}, presets.version, presets.all()
  end
  local all = allPresets
  for i = 1, #all do
    local p = all[i]
    local label = presetLabels[p.id]
    if not label then label = p.name .. '##hdrPreset:' .. p.id; presetLabels[p.id] = label end
    if ui.selectable(label, p.id == runtime.presetId) then runtime.setPreset(p.id) end
  end
end

-- [x] Zapnuto   ● běží   Car name
local function stateRow()
  if ui.checkbox(MASTER, S.master) then config.set('master', not S.master) end
  K.tip('Hlavní vypínač. Vypnuto = diody i světla řídí auto samo.')
  ui.sameLine(0, 16)
  local st = STATUS[safety.error and 'error' or runtime.state] or STATUS.wait
  K.dot(st[2])
  ui.sameLine(0, 2)
  ui.textColored(st[1], st[2])
  K.tip(st[3])
  if runtime.state == 'failed' and not safety.error and takeover.fallback then K.help(takeover.fallback) end
  if carName ~= '' then
    ui.sameLine(0, 16)
    ui.textColored(carName, K.GREY)
  end
end

local function presetRow()
  K.label('Preset')
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##preset', runtime.preset().name, ui.ComboFlags.None, presetItems)
  K.tip(PRESET_TIP)
end

-- One line per problem, only while it lasts.
local function problemLines()
  if safety.error then
    ui.textColored(ERROR_TEXT, K.RED)
    K.help(errorTip)
    ui.sameLine()
    if ui.button(RETRY) then
      safety.retry()
      runtime.restart('retry')
    end
  end
  if safety.uiError then
    ui.textColored(UI_ERROR_TEXT, K.RED)
    K.help(safety.uiError)
    ui.sameLine()
    if ui.button(HIDE_UI_ERROR) then safety.uiError = nil end
  end
  local m = takeover.method
  if takeover.fallback and m > 0 and runtime.state == 'run' then
    ui.textColored(FALLBACK_TEXT[m] or '', K.ORANGE)
    K.help(takeover.fallback)
  end
  if runtime.ST.isOnline and lights.G and lights.G.realOnline and lights.online and lights.online.BANNER then
    ui.textColored(ONLINE_TEXT, K.ORANGE)
    K.help(lights.online.BANNER)
  end
  if S.testMode ~= runtime.NORMAL and runtime.state == 'run' then
    ui.textColored(TEST_TEXT, K.ORANGE)
    K.help(TEST_HELP)
    ui.sameLine()
    if ui.button(BACK_TO_NORMAL) then runtime.setMode(runtime.NORMAL) end
  end
end

local function tabs()
  for i = 1, #TABS do ui.tabItem(TABS[i][1], drawers[i]) end
end

local function draw()
  refresh()
  stateRow()
  presetRow()
  problemLines()
  drawnTab = 0
  ui.tabBar('tabs', tabs)
  -- a tab that was hidden this frame saves its pending edit (slider / colour picker still open)
  for i = 1, #TABS do
    local mod = loaded[i]
    if mod and mod.flush and drawnTab ~= i then mod.flush() end
  end
end

function M.draw()
  safety.ui(draw)
end

return M
