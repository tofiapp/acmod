-- The window: header (master switch, car, state, method, errors) and the five tabs.

local common = require('src/ui/common')
local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')
local presets = require('src/presets')
local lights = require('src/lights')

local S = config.S
local M = {}

local RED = rgbm(1, 0.35, 0.3, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)

local TEST_NOTE = 'Diody ukazují testovací vzor z karty Diody (scénáře neběží). Zpět: Diody → Normální provoz.'
local HIDE_UI_ERROR = 'Skrýt##uiError'

local seen = -1
local statusLine = ''
local errorLine = ''

local function refresh()
  local v = runtime.version * 100000 + takeover.version
  if v == seen and (safety.error == nil) == (errorLine == '') then return end
  seen = v
  local lay = runtime.layout
  local count = lay and #lay.leds or 0
  statusLine = string.format('%s | %s | diod %d (%s) | %s', runtime.carId ~= '' and runtime.carId or '-',
    runtime.STATES[runtime.state] or runtime.state, count, lay and lay.signature or '0',
    takeover.NAMES[takeover.method] or 'nepřevzato')
  errorLine = safety.error and string.format('Chyba (%s): %s', tostring(safety.where), safety.error) or ''
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
    if mod then mod.draw() else common.note(loadErrors[i], RED) end
  end
end
for i = 1, #TABS do drawers[i] = tabDrawer(i) end

-- header combo labels carry the preset id, so two presets with one name never share an ImGui id
local presetLabels, labelsVersion = {}, -1
local function presetItems()
  local all = presets.all()
  if labelsVersion ~= presets.version then
    presetLabels, labelsVersion = {}, presets.version
  end
  for i = 1, #all do
    local p = all[i]
    local label = presetLabels[p.id]
    if not label then label = p.name .. '##hdrPreset:' .. p.id; presetLabels[p.id] = label end
    if ui.selectable(label, p.id == runtime.presetId) then runtime.setPreset(p.id) end
  end
end

local function presetRow()
  ui.text('Preset pro toto auto:')
  ui.sameLine()
  ui.setNextItemWidth(220)
  ui.combo('##preset', runtime.preset().name, ui.ComboFlags.None, presetItems)
end

local function tabs()
  for i = 1, #TABS do ui.tabItem(TABS[i][1], drawers[i]) end
end

local function draw()
  refresh()
  if ui.checkbox('Zapnuto (hlavní vypínač)', S.master) then config.set('master', not S.master) end
  ui.textWrapped(statusLine)
  presetRow()
  if takeover.fallback then common.note(takeover.fallback, ORANGE) end
  if errorLine ~= '' then
    common.note(errorLine, RED)
    if ui.button('Zkusit znovu') then
      safety.retry()
      runtime.restart('retry')
    end
  end
  if safety.uiError then
    common.note(safety.uiError, RED)
    if ui.button(HIDE_UI_ERROR) then safety.uiError = nil end
  end
  if runtime.ST.isOnline and lights.online and lights.online.BANNER then common.note(lights.online.BANNER, ORANGE) end
  if S.testMode ~= runtime.NORMAL and runtime.state == 'run' then common.note(TEST_NOTE, ORANGE) end
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
