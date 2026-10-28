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
  displayHz = 20,      -- display takeover: at most this many paints per second (only when something changed)
  displayPit = true,   -- the display shows the pit limiter / pit lane full screen
  displayFlags = true, -- ... flags
  displayFuel = true,  -- ... a low fuel banner
  displayGuard = '',   -- self-heal marker of display meshes hidden by the display takeover
  displayTheme = 1,    -- display design: 1..4 = display_pages.THEMES, 0 = own colours (displayColours)
  displayColours = '', -- own colours "#bg,#text,#label,#accent,#cellOff,#strip"
  displayFont = 1,     -- display_pages.FONTS
  displayRounding = 0, -- 0..100 % rounding of the LED cells and strips
  displayBrightness = 100, -- 20..100 %
  displayCellsOn = true,   -- the LED row on the pages
  displayCells = 12,   -- cells of the LED row (4..24)
  displayCellH = 100,  -- height of the LED row, % of the page's own
  displayCellGap = 8,  -- gap between cells, per mille of the width
  displayUnits = 1,    -- 1 km/h, 2 mph
  displayZones = 'speed,gear,lap,last,fuel,pos,delta', -- page Vlastní: field per zone
  displayTextScale = 100, -- text size, % (always fitted to its box)
  displayMargin = 3,   -- page margin, % of the shorter side
  displayGlow = 100,   -- glow of the display: % of its material's own ksEmissive
  displayNightOn = false, -- dim the display at night (sim time before 6:00 or from 20:00)
  displayNight = 50,   -- ... to this % of the glow and of the colours
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

-- Live edits (a slider or colour picker being dragged): the value takes effect at once, ac.storage is written only by
-- flushLive (the tab calls it once the control rests, and when it is hidden).
local dirty, dirtyAny = {}, false
function M.setLive(key, value)
  S[key] = value
  dirty[key], dirtyAny = true, true
end
function M.flushLive()
  if not dirtyAny then return end
  for k in pairs(dirty) do stored[k] = S[k]; dirty[k] = nil end
  dirtyAny = false
end
function M.hasLive() return dirtyAny end

return M
