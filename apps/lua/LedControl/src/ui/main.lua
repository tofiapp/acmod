-- The window: header (master switch, car, state, method, errors) and the five tabs.

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')
local presets = require('src/presets')

local S = config.S
local M = {}

local RED = rgbm(1, 0.35, 0.3, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)

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
  { 'Scénáře', 'src/ui/tab_scenarios' },
  { 'Editor', 'src/ui/tab_editor' },
  { 'Světla', 'src/ui/tab_lights' },
  { 'Nastavení', 'src/ui/tab_settings' },
}
local loaded, loadErrors, drawers = {}, {}, {}

local function tabDrawer(i)
  return function ()
    local mod = loaded[i]
    if mod == nil then
      local ok, res = pcall(require, TABS[i][2])
      if ok and type(res) == 'table' and type(res.draw) == 'function' then mod = res
      else mod = false; loadErrors[i] = 'Karta se nenačetla: ' .. tostring(res) end
      loaded[i] = mod
    end
    if mod then mod.draw() else ui.textColored(loadErrors[i], RED) end
  end
end
for i = 1, #TABS do drawers[i] = tabDrawer(i) end

local function presetItems()
  local all = presets.all()
  for i = 1, #all do
    if ui.selectable(all[i].name, all[i].id == runtime.presetId) then runtime.setPreset(all[i].id) end
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
  if takeover.fallback then ui.textColored(takeover.fallback, ORANGE) end
  if errorLine ~= '' then
    ui.textColored(errorLine, RED)
    if ui.button('Zkusit znovu') then
      safety.retry()
      runtime.restart('retry')
    end
  end
  if safety.uiError then ui.textColored(safety.uiError, RED) end
  ui.tabBar('tabs', tabs)
end

function M.draw()
  safety.ui(draw)
end

return M
