-- Opens all MirrorDelta windows and places them around the middle of the screen, so they are easy to find.
-- Runs once automatically after installing this version, and from a button in the settings.
-- Uses ac.getAppWindows() / ac.accessAppWindow() (window title = NAME from manifest.ini).

local config = require('src/config')
local S = config.S

local LAYOUT_VERSION = 2

-- Each window's top left corner: offset from the screen centre ('c') or from the top right corner ('tr'), px,
-- and the layout version that introduced it (an update places only windows that are new to the user).
local PLACES = {
  ['MirrorDelta Notifications'] = { -260, -400, 'c', 1 },
  ['MirrorDelta'] = { -300, -270, 'c', 1 },
  ['MirrorDelta Timing'] = { -195, -170, 'c', 1 },
  ['MirrorDelta Tyres'] = { -460, 60, 'c', 1 },
  ['MirrorDelta Gear'] = { -130, 90, 'c', 1 },
  ['MirrorDelta Damage'] = { 280, 40, 'c', 1 },
  ['MirrorDelta Flags'] = { -290, 40, 'tr', 2 },
}

local M = { lastResult = '-' }

-- Returns the number of windows placed (only those introduced after layout version `after`).
function M.arrange(after)
  after = after or 0
  local windows = ac.getAppWindows()
  local screen = ac.getUI().windowSize
  local cx, cy = screen.x / 2, screen.y / 2
  local placed = 0
  for _, v in ipairs(windows) do
    local title = type(v.title) == 'string' and v.title:match('^%s*(.-)%s*$') or ''
    local place = PLACES[title]
    if place and place[4] > after then
      local window = ac.accessAppWindow(v.name)
      if window then
        local x = place[3] == 'tr' and screen.x + place[1] or cx + place[1]
        local y = place[3] == 'tr' and place[2] or cy + place[2]
        window:move(vec2(math.max(0, x), math.max(0, y)))
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
  local ok, placed = pcall(M.arrange, S.layoutVersion)
  if not ok then M.lastResult = 'chyba: ' .. tostring(placed) end
  config.set('layoutVersion', LAYOUT_VERSION)    -- also on failure: never retry every frame
end

return M
