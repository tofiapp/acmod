-- Settings. Stored with ac.storage, but copied into a plain table (S) once,
-- so drawing code never goes through the storage layer every frame.

local defaults = {
  -- Delta window
  deltaLayout = 2,          -- 1: delta number on top, mini sectors at the bottom; 2: mini sectors on top, number at the bottom
  showSectors = true,
  showDeltaLine = true,
  showDeltaNumber = true,
  sectors = 24,
  sectorGroups = 3,         -- 24 sectors in 3 groups = 8 | 8 | 8
  groupGap = 8,             -- px at window width 600
  lineThickness = 9.5,      -- px at window width 600
  lineGap = 12,             -- px at window width 600
  numberSize = 30,          -- px at window width 600
  opacity = 1,
  intensityByDelta = false,
  intensityFullAt = 0.5,    -- seconds of delta for full colour
  referenceKind = 3,        -- 1: best lap of this session, 2: all-time best lap (saved), 3: previous lap (best until there is one)
  deltaPanel = true,        -- matte translucent background behind the delta window
  deltaLimiterFlash = true, -- the delta line and the mini sectors blink blue at the rev limiter, like the gear window
  deltaLineMode = 1,        -- 1: split line (green to the right gaining now, red to the left losing now), 2: colour by total delta
  splitFull = 0.1,          -- s gained or lost over the last 3 s for a full half of the split line
  deltaSource = 1,          -- 1: own measurement, AC's delta when it has none; 2: own only; 3: AC only

  -- Timing window
  showPosition = true,
  showLaps = true,
  showCurrent = true,
  showBest = true,
  showLast = true,
  setupLine = true,           -- car settings line at the top (TC, ABS, brake bias...) and AC's system messages
  setupTime = 2.5,            -- s the line stays
  timingLayout = 2,         -- 1: stacked, 2: side by side
  bestHighlight = true,
  lapFlash = true,
  lapFlashTime = 4,         -- seconds
  timingPanel = true,       -- matte translucent background sized to the content

  -- Tyres window
  tyreStyle = 1,            -- 1: big core numbers + zone bar, 2: big core number + tyre + three zone numbers
  tyreArrange = 1,          -- 1: 2 x 2 like on the car, 2: in a row
  tyreNumbers = true,
  tyreZones = true,
  tyreOptimumAuto = true,   -- use the optimum temperature of the car's tyres when CSP provides it
  tyreOptimum = 85,         -- fallback optimum, °C
  tyresPanel = true,        -- matte translucent background sized to the content

  -- Gear window
  gearShowBar = true,
  gearShowSpeed = true,
  gearRpmStart = 0.6,       -- first segment lights up at this share of the rev limiter
  gearShiftFlash = true,    -- bar and gear tile blink blue at the limiter
  gearSpeedStep = 3,        -- km/h; the speed only changes once it moved a whole step
  gearPlate = false,

  -- Damage window
  damageShow = 3,           -- 1: always, 2: while something is damaged, 3: for damageShowTime s after a hit
  damageShowTime = 8,       -- s
  damageFull = 50,          -- raw car.damage value drawn as full red
  damagePanel = true,       -- matte translucent background
  damageHideOriginal = true, -- hide AC's own damage display while this window is open

  -- Notification window
  notifyLook = 4,           -- 1: rounded pill, 2: slanted strip, 3: thin line, 4: top right corner next to the flag
  notifyTime = 4.5,         -- seconds a notification stays
  notifyCount = 2,          -- notifications shown at once
  notifyFastest = true,     -- fastest lap of the session (any car)
  notifyPositions = true,   -- own position gained or lost
  notifyPits = true,        -- other cars entering and leaving the pit lane
  notifyFlags = false,      -- also as notifications (the flag window shows them anyway)
  notifySystem = true,      -- AC's own system messages (ABS, TC, penalties...) as notifications
  hideOverlayLeaderboard = true, -- turn off AC's overlay leaderboard (F9)
  hideSystemMessages = true, -- hide AC's own system messages (CSP option gui.ini [HIDE] HIDE_SYSTEM_MESSAGES)
  notifyInvalid = true,     -- own lap invalidated (track cut)
  notifyConnections = true, -- driver disconnected (online)
  notifyRaceOnly = true,    -- positions and pits only in a race session

  panelOpacity = 0.4,       -- how dark the matte backgrounds are (0 = clear, 1 = solid)
  layoutVersion = 0,        -- windows were opened and placed around the screen centre for this layout version

  -- Colours
  colPurple = rgbm(0.69, 0.36, 1, 1),
  colGreen = rgbm(0.18, 0.83, 0.42, 1),
  colYellow = rgbm(0.95, 0.76, 0.19, 1),
  colRed = rgbm(1, 0.27, 0.27, 1),
  colIdle = rgbm(0.19, 0.21, 0.24, 1),
  colCurrent = rgbm(0.42, 0.45, 0.5, 1),
  colNeutral = rgbm(0.35, 0.38, 0.42, 1),
  colText = rgbm(0.9, 0.91, 0.93, 1),
}

local stored = ac.storage(defaults, 'md_')

local function isColor(v)
  return rgbm.isrgbm(v)
end

local function copy(v)
  if isColor(v) then return v:clone() end
  return v
end

local S = {}
for key, default in pairs(defaults) do
  local value = stored[key]
  if value == nil or (type(value) ~= type(default)) then value = default end
  S[key] = copy(value)
end

local M = { S = S, defaults = defaults, VERSION = '1.13.1' }

function M.set(key, value)
  S[key] = value
  stored[key] = copy(value)
end

function M.reset(key)
  M.set(key, copy(defaults[key]))
end

return M
