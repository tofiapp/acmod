-- The window: header (master switch, car, state, method, errors) and the five tabs.

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')
local hotkeys = require('src/hotkeys')
local tabLeds = require('src/ui/tab_leds')

local S = config.S
local M = {}

local RED = rgbm(1, 0.35, 0.3, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)
local HOTKEY_SIZE = vec2(220, 0)

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

local function placeholder(text)
  return function () ui.textWrapped(text) end
end

local tabScenarios = placeholder('Scénáře (pit limiter, vlajky, řazení, DRS, ABS/TC, palivo, …) přijdou ve fázi 4.')
local tabEditor = placeholder('Ruční editor presetů přijde ve fázi 5.')
local tabLights = placeholder('Světla přijdou ve fázi 6.')

local function tabSettings()
  ui.text('Klávesa pro hlavní vypínač:')
  if hotkeys.master then hotkeys.master:control(HOTKEY_SIZE) else ui.text('(ovládání kláves není k dispozici)') end
  ui.textWrapped('Ostatní nastavení (presety, import/export, smazání dat) přijdou v dalších fázích.')
end

local function tabs()
  ui.tabItem('Diody', tabLeds.draw)
  ui.tabItem('Scénáře', tabScenarios)
  ui.tabItem('Editor', tabEditor)
  ui.tabItem('Světla', tabLights)
  ui.tabItem('Nastavení', tabSettings)
end

local function draw()
  refresh()
  if ui.checkbox('Zapnuto (hlavní vypínač)', S.master) then config.set('master', not S.master) end
  ui.textWrapped(statusLine)
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
