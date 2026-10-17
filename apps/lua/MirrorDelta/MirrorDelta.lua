-- MirrorDelta: minimal delta bar with mini sectors for the mirror position,
-- plus optional lap timing and tyre temperature windows.

local tracker = require('src/tracker')
local deltaWindow = require('src/delta_window')
local timingWindow = require('src/timing_window')
local tyresWindow = require('src/tyres_window')
local gearWindow = require('src/gear_window')
local settingsWindow = require('src/settings_window')

-- Runs every frame even when all windows are hidden, so laps are always recorded.
function script.update(dt)
  tracker.update(dt)
end

function script.windowDelta(dt)
  deltaWindow.draw()
end

function script.windowTiming(dt)
  timingWindow.draw()
end

function script.windowTyres(dt)
  tyresWindow.draw()
end

function script.windowGear(dt)
  gearWindow.draw()
end

function script.windowSettings(dt)
  settingsWindow.draw()
end
