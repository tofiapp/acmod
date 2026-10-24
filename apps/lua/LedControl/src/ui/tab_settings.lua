-- Tab Nastavení: global brightness, default method and preset for cars without their own choice, hotkeys,
-- export / import of presets through the clipboard, deleting saved data and restoring defaults (both with an
-- in-window confirmation).

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local presets = require('src/presets')
local store = require('src/store')
local hotkeys = require('src/hotkeys')
local diag = require('src/diag')
local lights = require('src/lights')

local S = config.S
local M = {}

local GREY = rgbm(0.6, 0.6, 0.6, 1)
local GREEN = rgbm(0.4, 1, 0.5, 1)
local RED = rgbm(1, 0.4, 0.35, 1)
local HOTKEY_SIZE = vec2(240, 0)
local CONFIRM_TIME = 4

local ABOUT = 'LedControl ' .. diag.VERSION .. ' – změny diod jsou jen vizuální a jen na vašem autě.'
local METHOD_LABELS = {}
for m = 1, 3 do METHOD_LABELS[m] = takeover.NAMES[m] .. '##defaultMethod' end

local message, messageColour, messageUntil = '', GREEN, 0
local confirmDelete, confirmDefaults = -1, -1

local function say(text, colour)
  message, messageColour, messageUntil = text, colour or GREEN, runtime.clock + 6
end

local DEFAULT_LABEL = 'Automaticky (F1 styl pro dlouhou řadu nebo DRS, jinak GT3)'
local function defaultName()
  if S.defaultPreset == 'auto' then return DEFAULT_LABEL end
  local p = presets.get(S.defaultPreset)
  return p and p.name or DEFAULT_LABEL
end

local function defaultItems()
  if ui.selectable(DEFAULT_LABEL, S.defaultPreset == 'auto') then config.set('defaultPreset', 'auto') end
  local all = presets.all()
  for i = 1, #all do
    if ui.selectable(all[i].name, S.defaultPreset == all[i].id) then config.set('defaultPreset', all[i].id) end
  end
end

local function brightness()
  ui.header('Diody')
  local v, changed = ui.slider('##intensitySettings', S.intensity, 1, 100, 'Jas diod: %.0f')
  if changed then runtime.setIntensity(math.floor(v + 0.5)) end
  ui.textColored('Síla svitu převzatých diod (AC u svých diod používá zhruba 10 až 60).', GREY)
  ui.text('Způsob převzetí pro auta, kde jste ho nezměnili:')
  for m = 1, 3 do
    if ui.radioButton(METHOD_LABELS[m], S.method == m) and S.method ~= m then
      config.set('method', m)
      runtime.restart('method')
    end
    if m < 3 then ui.sameLine() end
  end
  ui.text('Preset pro auta bez vlastní volby:')
  ui.setNextItemWidth(-1)
  ui.combo('##defaultPreset', defaultName(), ui.ComboFlags.None, defaultItems)
end

local function hotkeyRows()
  ui.header('Klávesy')
  ui.textColored('Fungují i se zavřeným oknem. Klikněte na tlačítko a stiskněte klávesu nebo tlačítko volantu.', GREY)
  for i = 1, #hotkeys.list do
    local e = hotkeys.list[i]
    ui.text(e.name)
    if e.button then e.button:control(HOTKEY_SIZE, nil, 'Klikněte pro přiřazení')
    else ui.textColored('Ovládání kláves není v této verzi CSP k dispozici.', GREY) end
  end
end

local function exchange()
  ui.header('Presety: sdílení')
  ui.textColored('Preset se přenáší jako jeden řádek textu přes schránku (např. do zprávy nebo na fórum).', GREY)
  if ui.button('Kopírovat aktuální preset do schránky') then
    local text = presets.export(runtime.presetId)
    if text then
      ac.setClipboardText(text)
      say('Preset „' .. runtime.preset().name .. '“ je ve schránce.')
    end
  end
  ui.sameLine()
  if ui.button('Vložit preset ze schránky') then
    local id, why = presets.import(ui.getClipboardText())
    if id then
      runtime.setPreset(id)
      say('Načteno: „' .. presets.get(id).name .. '“, toto auto ho teď používá.')
    else
      say(why or 'Preset nejde načíst.', RED)
    end
  end
  if ui.button('Kopírovat diagnostiku do schránky') then
    ac.setClipboardText(diag.text())
    say('Diagnostika je ve schránce.')
  end
end

local function deleteAll()
  store.deleteAll({ runtime.carId })
  presets.deleteAllUser()
  runtime.profile = { v = 1 }
  runtime.restart('deleted')
end

local function restoreDefaults()
  for k in pairs(config.defaults) do
    if k ~= 'hiddenGuard' then config.reset(k) end
  end
  pcall(lights.resetScenarios)
  takeover.invalidate()
  runtime.restart('defaults')
end

local function danger()
  ui.header('Uložená data')
  local now = runtime.clock
  if confirmDelete > now then
    if ui.button('Opravdu smazat vše? Klikněte znovu##delete') then
      confirmDelete = -1
      deleteAll()
      say('Uložená data jsou smazaná (vlastní presety a nastavení aut).')
    end
  elseif ui.button('Smazat uložená data##delete') then
    confirmDelete = now + CONFIRM_TIME
  end
  ui.sameLine()
  if confirmDefaults > now then
    if ui.button('Opravdu obnovit? Klikněte znovu##defaults') then
      confirmDefaults = -1
      restoreDefaults()
      say('Nastavení je výchozí.')
    end
  elseif ui.button('Obnovit výchozí nastavení##defaults') then
    confirmDefaults = now + CONFIRM_TIME
  end
  ui.textColored('Smazání odstraní vaše presety a nastavení všech aut. Obnovení vrátí jas, metodu, výchozí preset a'
    .. ' scénáře světel.', GREY)
end

function M.draw()
  brightness()
  hotkeyRows()
  exchange()
  danger()
  if runtime.clock < messageUntil then ui.textColored(message, messageColour) end
  ui.separator()
  ui.textColored(ABOUT, GREY)
end

return M
