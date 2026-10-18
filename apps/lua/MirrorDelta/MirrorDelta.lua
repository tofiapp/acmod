-- MirrorDelta: minimal delta bar with mini sectors for the mirror position,
-- plus optional lap timing, tyres, gear, damage and notification windows.

local tracker = require('src/tracker')
local deltaWindow = require('src/delta_window')
local timingWindow = require('src/timing_window')
local tyresWindow = require('src/tyres_window')
local gearWindow = require('src/gear_window')
local damageWindow = require('src/damage_window')
local notify = require('src/notify')
local notifyWindow = require('src/notify_window')
local settingsWindow = require('src/settings_window')

local layout = require('src/layout')
local originals = require('src/originals')
local flagWindow = require('src/flag_window')
local setupLine = require('src/setup_line')
local mirrorWindow = require('src/mirror_window')
local standingsWindow = require('src/standings_window')
local D = require('src/draw')

-- A window that fails shows the error inside itself and keeps the rest of the app running.
local ERROR_COLOR = rgbm(1, 0.35, 0.35, 1)
local errorText = {}
local function safe(name, draw)
  local ok, err = pcall(draw)
  if ok then return end
  local text = errorText[name]
  if not text then
    text = 'MirrorDelta ' .. name .. ': ' .. tostring(err)
    errorText[name] = text
    ac.error(text)
    if not tracker.diag.error then tracker.diag.error = text end
  end
  D.rect(0, 0, ui.windowWidth(), 4, ERROR_COLOR, 0)
  pcall(D.text, text, 12, 0, 6, ui.windowWidth(), 40, D.ALIGN_START, ERROR_COLOR)
end

-- Runs every frame even when all windows are hidden, so laps are always recorded.
function script.update(dt)
  tracker.update(dt)
  local ok, err = pcall(notify.update)
  if not ok and not tracker.diag.error then tracker.diag.error = 'notifikace: ' .. tostring(err) end
  ok, err = pcall(originals.update)
  if not ok and not tracker.diag.error then tracker.diag.error = 'původní prvky AC: ' .. tostring(err) end
  ok, err = pcall(setupLine.update)
  if not ok and not tracker.diag.error then tracker.diag.error = 'nastavení auta: ' .. tostring(err) end
  ok, err = pcall(layout.update)
  if not ok and not tracker.diag.error then tracker.diag.error = 'rozmístění oken: ' .. tostring(err) end
end

function script.windowDelta(dt) safe('delta', deltaWindow.draw) end
function script.windowTiming(dt) safe('časy', timingWindow.draw) end
function script.windowTyres(dt) safe('pneumatiky', tyresWindow.draw) end
function script.windowGear(dt) safe('převody', gearWindow.draw) end
function script.windowDamage(dt) safe('poškození', damageWindow.draw) end
function script.windowNotify(dt) safe('notifikace', notifyWindow.draw) end
function script.windowFlags(dt) safe('vlajky', flagWindow.draw) end
function script.windowStandings(dt) safe('pořadí', standingsWindow.draw) end
function script.windowMirror(dt) safe('zrcátko', mirrorWindow.draw) end
function script.windowSetup(dt) safe('nastavení auta', setupLine.draw) end
function script.windowSettings(dt) safe('nastavení', settingsWindow.draw) end
