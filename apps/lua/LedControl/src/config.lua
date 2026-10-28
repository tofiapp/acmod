-- Global settings. Stored with ac.storage, copied once into a plain table (S) so the frame loop never goes through
-- the storage layer. Change settings only via M.set().

local csp = require('src/csp')
local ac = csp.ac
local defaults = {
  master = true,       -- master switch: false gives the car its own LEDs back
  method = 1,          -- default takeover method for cars without a profile: 1 shadow copy, 2 redraw, 3 direct write
  intensity = 25,      -- emissive strength of a full colour (AC's own LED configs use roughly 10..60)
  colourGuard = 0.7,   -- 0..1: keeps hues true at high brightness (the weaker channels are pushed down)
  autoBrightness = false, -- brightness follows the time of day between intensityNight and intensityDay
  intensityDay = 35,
  intensityNight = 12,
  testMode = 0,        -- 0 = normal operation (scenarios), 1..6 = test pattern of the Diody tab (runtime.MODES)
  defaultPreset = 'auto', -- preset for cars without their own choice ('auto': F1 styl for long rows / DRS, else GT3)
  showDiag = false,    -- Diody tab: show the diagnostics block
  hiddenGuard = '',    -- self-heal marker: "carId|mesh|mesh|..." of original meshes hidden by the shadow method
}

local stored = ac.storage(defaults, 'lc_')

local S = {}
for k in pairs(defaults) do S[k] = stored[k] end

local M = { S = S, defaults = defaults }

function M.set(key, value)
  S[key] = value
  stored[key] = value
end

function M.reset(key)
  M.set(key, defaults[key])
end

return M
