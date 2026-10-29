-- Window "KeyDrive": in-game settings for the KeyDrive Gamepad FX script, written through the shared live struct
-- (src/shared.lua, cfg* fields) and remembered with ac.storage. Nothing is sent until the user changes something, so
-- settings.ini (Content Manager) applies until then.
--   - "Zobrazit diagnostiku": shows / hides the diagnostic overlay (SHOW_DIAGNOSTICS)
--   - "Síla zásahu": traction intervention 0..100, 50 = as tuned; the core scales the allowed slip and the cap
--     recovery with it (assist.lua strengthScales)

local shared = require('src/shared')

local M = {}

local live = shared.connect()
-- (real keys: 'keydrive_' .. name; each control has its own *Set flag: moving the slider while KeyDrive was not running
-- used to copy the zeroed live.showDiagnostics and hide the overlay for good)
-- (v0.13 moved the scale: the old 100 is the new 50, so the strength lives under new keys and starts at 50 again;
-- the diagnostics choice keeps its key)
local stored = ac.storage({ diagSet = false, showDiag = true, strength13Set = false, strength13 = 50 }, 'keydrive')

local lastAlive, staleTime = -1, 0
local WARN = rgbm(1, 0.6, 0.3, 1)
-- texts are rebuilt only when their values change (no allocation per frame)
local textStrength, textStrengthFor = '', -1
local textTarget, textTargetFor = '', -1

function M.update(dt)
  if live.alive ~= lastAlive then lastAlive, staleTime = live.alive, 0 else staleTime = staleTime + dt end
  if stored.diagSet then live.cfgShowDiag, live.cfgDiagSet = stored.showDiag, true end
  if stored.strength13Set then live.cfgStrength, live.cfgStrengthSet = stored.strength13, true end
end

local function strengthText(s)
  if s < 20 then return 'odvážné (jako 0.12)' elseif s < 40 then return 'méně opatrné' elseif s <= 60 then return 'výchozí'
  elseif s <= 80 then return 'opatrnější' end
  return 'nejopatrnější'
end

function M.window()
  local running = staleTime < 0.5 and lastAlive >= 0
  if not running then
    ui.textColored('KeyDrive teď neběží (Gamepad FX vypnutý, opakování nebo AI).', WARN)
    ui.text('Nastavení se uloží a použije, až poběží.')
    ui.separator()
  end

  local show
  if stored.diagSet then show = stored.showDiag else show = live.showDiagnostics end
  if ui.checkbox('Zobrazit diagnostiku', show) then
    stored.showDiag, stored.diagSet = not show, true
  end

  ui.text('Síla zásahu (hlídání prokluzu):')
  ui.setNextItemWidth(ui.windowWidth() - 24)
  local s = stored.strength13Set and stored.strength13 or 50
  local value, changed = ui.slider('##strength', s, 0, 100, '%.0f', true)
  if changed then
    stored.strength13, stored.strength13Set = math.floor(value + 0.5), true
  end
  local si = math.floor(s + 0.5)
  if si ~= textStrengthFor then
    textStrengthFor = si
    textStrength = string.format('%d = %s   (0 = nejméně, 50 = výchozí, 100 = nejvíc)', si, strengthText(si))
  end
  ui.text(textStrength)
  if running then
    local tp = math.floor(live.targetSlip * 100 + 0.5)
    if tp ~= textTargetFor then
      textTargetFor = tp
      textTarget = string.format('Povolený prokluz: %d %% vrcholu pneumatiky', tp)
    end
    ui.text(textTarget)
  end
  if ui.button('Výchozí (50)') then
    stored.strength13, stored.strength13Set = 50, true
  end
  ui.separator()
  ui.textWrapped('Méně zásahu = víc plynu, kola se víc protáčí. Víc zásahu = klidnější, ale pomalejší. Klávesa X hlídání úplně vypne a zase zapne.')
end

return M
