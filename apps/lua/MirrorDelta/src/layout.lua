-- Opens all MirrorDelta windows and places them around the middle of the screen, so they are easy to find.
-- Runs once automatically after installing this version, and from a button in the settings.
-- Uses ac.getAppWindows() / ac.accessAppWindow() (window title = NAME from manifest.ini).

local config = require('src/config')
local S = config.S

local LAYOUT_VERSION = 1

-- Offsets of each window's top left corner from the screen centre, px.
local PLACES = {
  ['MirrorDelta Notifications'] = { -260, -400 },
  ['MirrorDelta'] = { -300, -270 },
  ['MirrorDelta Timing'] = { -195, -170 },
  ['MirrorDelta Tyres'] = { -460, 60 },
  ['MirrorDelta Gear'] = { -130, 90 },
  ['MirrorDelta Damage'] = { 280, 40 },
}

local M = { lastResult = '-' }

-- Returns the number of windows placed.
function M.arrange()
  local windows = ac.getAppWindows()
  local screen = ac.getUI().windowSize
  local cx, cy = screen.x / 2, screen.y / 2
  local placed = 0
  for _, v in ipairs(windows) do
    local title = type(v.title) == 'string' and v.title:match('^%s*(.-)%s*$') or ''
    local place = PLACES[title]
    if place then
      local window = ac.accessAppWindow(v.name)
      if window then
        window:move(vec2(math.max(0, cx + place[1]), math.max(0, cy + place[2])))
        window:setVisible(true)
        placed = placed + 1
      end
    end
  end
  M.lastResult = string.format('rozmístěno oken: %d', placed)
  return placed
end

-- Called from script.update: once per layout version, a few seconds after start (windows exist by then).
local startClock = nil
function M.update()
  if S.layoutVersion >= LAYOUT_VERSION then return end
  local now = os.preciseClock()
  startClock = startClock or now
  if now - startClock < 3 then return end
  local ok, placed = pcall(M.arrange)
  if not ok then M.lastResult = 'chyba: ' .. tostring(placed) end
  config.set('layoutVersion', LAYOUT_VERSION)    -- also on failure: never retry every frame
end

return M
