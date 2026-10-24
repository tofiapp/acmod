-- Global settings. Stored with ac.storage, copied once into a plain table (S) so the frame loop never goes through
-- the storage layer. Change settings only via M.set().

local defaults = {
  master = true,       -- master switch: false gives the car its own LEDs back
  method = 1,          -- default takeover method for cars without a profile: 1 shadow copy, 2 redraw, 3 direct write
  intensity = 25,      -- emissive strength of a full colour (AC's own LED configs use roughly 10..60)
  testMode = 1,        -- proof of concept test pattern (see runtime.MODES)
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
