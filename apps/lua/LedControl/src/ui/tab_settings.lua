-- Tab Nastavení (docs/ledcontrol-ui.md): what a new car starts with (default preset, default takeover method),
-- hotkeys, colour guard, export / import of presets through the clipboard, deleting saved data and restoring defaults
-- (both confirmed by a second click) and the version line. Brightness lives in the Diody tab.
-- No allocation per frame: labels are prebuilt, preset combo labels are rebuilt only when presets.version changes,
-- messages are built on a click.
-- CSP calls: ac.ControlButton:control(size, flags, emptyLabel) (TimeShift, CspDebug), ui.combo / ui.selectable /
-- ui.slider (official apps), ac.setClipboardText / ui.getClipboardText (official apps), ui.pushStyleColor with
-- ui.StyleColor.Button (WebBrowser).

local csp = require('src/csp')
local ac, ui, vec2 = csp.ac, csp.ui, csp.vec2
local K = require('src/ui/kit')
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

local HOTKEY_SIZE = vec2(K.CONTROL_W, 0)
local CONFIRM_TIME = 4
local MESSAGE_TIME = 6
local COMBO = ui.ComboFlags.None
local BUTTON = ui.StyleColor and ui.StyleColor.Button or nil

local T = {
  newCar = 'Nové auto',
  preset = 'Preset',
  presetHelp = 'Preset pro auta, kde jste žádný nevybrali.\nAutomaticky: F1 styl pro dlouhou řadu diod nebo DRS, '
    .. 'jinak GT3 styl.',
  auto = 'Automaticky',
  method = 'Převzetí',
  methodHelp = 'Jak aplikace převezme diody u auta, kde jste způsob nezměnili (karta Diody).\n'
    .. 'A kopie (doporučeno): každá dioda dostane vlastní kopii.\n'
    .. 'B překreslení: dioda se znovu vykreslí přes původní.\n'
    .. 'C přímý zápis: barva se zapisuje přímo do diody.\n'
    .. 'Když diody nesedí, blikají nebo se nemění, zkuste jiný způsob.',
  keys = 'Klávesy',
  keysHelp = 'Fungují i se zavřeným oknem. Klikněte na tlačítko a stiskněte klávesu nebo tlačítko volantu.',
  keyEmpty = 'Klikněte pro přiřazení',
  keyMissing = 'V této verzi CSP nejde',
  colours = 'Barvy',
  guard = 'Ochrana barev',
  guardHelp = 'Při vysokém jasu se barva s malou příměsí jiné barvy slije: zelená přejde do tyrkysové, červená do '
    .. 'oranžové.\nOchrana barev tuto příměs ztlumí, takže odstín zůstane věrný. Když barvy při vysokém jasu ujíždějí, '
    .. 'zvyšte ji.\n0 % = vypnuto. Vysoká hodnota posune smíšené barvy (oranžová, růžová) blíž k hlavní barvě.\n'
    .. 'Barvy z rychlé volby vedle výběru barvy zůstanou věrné vždy.',
  sharing = 'Sdílení',
  shareHelp = 'Preset se přenáší jako jeden řádek textu přes schránku (do zprávy, na fórum).\n'
    .. 'Kopírovat: preset tohoto auta. Vložit: načte preset ze schránky a toto auto ho začne používat.',
  export = 'Do schránky##export',
  import = 'Ze schránky##import',
  data = 'Data',
  dataHelp = 'Smazat: odstraní vaše presety a nastavení všech aut.\n'
    .. 'Výchozí nastavení: vrátí jas, ochranu barev, způsob převzetí, výchozí preset a scénáře světel '
    .. '(hlavní vypínač zůstane).\nObojí potvrďte druhým kliknutím.',
  delete = 'Smazat uložená data##delete',
  deleteConfirm = 'Opravdu smazat? Klikněte znovu##delete',
  defaults = 'Výchozí nastavení##defaults',
  defaultsConfirm = 'Opravdu obnovit? Klikněte znovu##defaults',
  deleted = 'Uložená data jsou smazaná.',
  restored = 'Nastavení je výchozí.',
  importFailed = 'Preset nejde načíst.',
  version = 'LedControl ' .. diag.VERSION,
  versionTip = 'Změny diod jsou jen vizuální a jen na vašem autě.',
}

-- hotkey labels by hotkeys.lua key (its names are longer); unknown keys use the module's own name
local KEY_LABELS = { master = 'Zapnout / vypnout', nextPreset = 'Další preset', flash = 'Problik dálkovými' }

local METHOD_LABELS = { 'A kopie##defaultMethod', 'B překreslení##defaultMethod', 'C přímý zápis##defaultMethod' }
local AUTO_ITEM = T.auto .. '##defp_auto'

-- ---------------------------------------------------------------- messages (shown under the row they belong to)

local message, messageColour, messageAt, messageUntil = '', K.GREEN, nil, 0
local confirmDelete, confirmDefaults = -1, -1

local function say(at, text, colour)
  message, messageColour, messageAt, messageUntil = text, colour or K.GREEN, at, runtime.clock + MESSAGE_TIME
end

local function showMessage(at)
  if messageAt == at and runtime.clock < messageUntil then K.note(message, messageColour) end
end

-- ---------------------------------------------------------------- Nové auto

local presetLabels, labelsVersion = {}, -1

local function defaultName()
  if S.defaultPreset == 'auto' then return T.auto end
  local p = presets.get(S.defaultPreset)
  return p and p.name or T.auto
end

local function setDefault(id)
  config.set('defaultPreset', id)
  runtime.defaultPresetChanged()
end

-- combo content (module level: no closure per frame); labels carry the preset id (two presets may share a name)
local function defaultItems()
  if labelsVersion ~= presets.version then presetLabels, labelsVersion = {}, presets.version end
  if ui.selectable(AUTO_ITEM, S.defaultPreset == 'auto') and S.defaultPreset ~= 'auto' then setDefault('auto') end
  local all = presets.all()
  for i = 1, #all do
    local p = all[i]
    local label = presetLabels[p.id]
    if not label then label = p.name .. '##defp:' .. p.id; presetLabels[p.id] = label end
    if ui.selectable(label, S.defaultPreset == p.id) and S.defaultPreset ~= p.id then setDefault(p.id) end
  end
end

local function newCar()
  K.header(T.newCar)
  K.label(T.preset)
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##defaultPreset', defaultName(), COMBO, defaultItems)
  K.help(T.presetHelp)
  K.label(T.method)
  local m = K.choice(METHOD_LABELS, S.method)
  if m then
    config.set('method', m)
    runtime.restart('method')
  end
  K.help(T.methodHelp)
end

-- ---------------------------------------------------------------- Klávesy

local function keys()
  K.header(T.keys)
  K.help(T.keysHelp)
  local list = hotkeys.list
  for i = 1, #list do
    local e = list[i]
    K.label(KEY_LABELS[e.key] or e.name)
    if e.button then e.button:control(HOTKEY_SIZE, nil, T.keyEmpty)
    else K.dim(T.keyMissing) end
  end
end

-- ---------------------------------------------------------------- Barvy

local function colours()
  K.header(T.colours)
  K.label(T.guard)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider('##colourGuard', (S.colourGuard or 0) * 100, 0, 100, '%.0f %%')
  if changed then
    v = math.floor(v + 0.5)
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    -- whole percents only: dragging writes the setting only when the shown value changes
    if v / 100 ~= S.colourGuard then runtime.setBrightness('colourGuard', v / 100) end
  end
  K.help(T.guardHelp)
end

-- ---------------------------------------------------------------- Sdílení

local function sharing()
  K.header(T.sharing)
  if ui.button(T.export) then
    local text = presets.export(runtime.presetId)
    if text then
      ac.setClipboardText(text)
      local ed = package.loaded['src/ui/tab_editor']
      if type(ed) == 'table' and ed.unsaved and ed.unsaved() then
        say('share', 'Preset „' .. runtime.preset().name .. '“ je ve schránce, ale bez neuložených změn z Editoru.', K.ORANGE)
      else
        say('share', 'Preset „' .. runtime.preset().name .. '“ je ve schránce.')
      end
    end
  end
  ui.sameLine()
  if ui.button(T.import) then
    local id, why = presets.import(ui.getClipboardText())
    if id then
      runtime.setPreset(id)
      say('share', 'Načteno: „' .. presets.get(id).name .. '“, toto auto ho teď používá.')
    else
      say('share', why or T.importFailed, K.RED)
    end
  end
  K.help(T.shareHelp)
  showMessage('share')
end

-- ---------------------------------------------------------------- Data

local function deleteAll()
  store.deleteAll({ runtime.carId })
  presets.deleteAllUser()
  runtime.profile = { v = 1 }
  runtime.restart('deleted')
end

local function restoreDefaults()
  for k in pairs(config.defaults) do
    if k ~= 'hiddenGuard' and k ~= 'master' then config.reset(k) end   -- the master switch stays as the driver set it
  end
  pcall(lights.resetScenarios)
  takeover.invalidate()
  runtime.defaultPresetChanged()
  runtime.restart('defaults')
end

-- a button that waits for its second click is drawn red
local function confirmButton(armed, label, armedLabel)
  if not armed then return ui.button(label) end
  if BUTTON and ui.pushStyleColor then ui.pushStyleColor(BUTTON, K.RED) end
  local clicked = ui.button(armedLabel)
  if BUTTON and ui.popStyleColor then ui.popStyleColor() end
  return clicked
end

local function data()
  K.header(T.data)
  local now = runtime.clock
  local armed = confirmDelete > now
  if confirmButton(armed, T.delete, T.deleteConfirm) then
    if armed then
      confirmDelete = -1
      deleteAll()
      say('data', T.deleted)
    else
      confirmDelete, confirmDefaults = now + CONFIRM_TIME, -1
    end
  end
  ui.sameLine()
  armed = confirmDefaults > now
  if confirmButton(armed, T.defaults, T.defaultsConfirm) then
    if armed then
      confirmDefaults = -1
      restoreDefaults()
      say('data', T.restored)
    else
      confirmDefaults, confirmDelete = now + CONFIRM_TIME, -1
    end
  end
  K.help(T.dataHelp)
  showMessage('data')
end

function M.draw()
  newCar()
  keys()
  colours()
  sharing()
  data()
  ui.separator()
  K.dim(T.version)
  K.tip(T.versionTip)
end

return M
