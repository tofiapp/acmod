-- Online state for the lights. sim.isOnlineRace (Unbound.lua, RGBControl conditions.lua) arrives through
-- car_state (ST.isOnline). The server's CSP online extras (ac.INIConfig.onlineExtras(), ac_extras_ini.lua; nil when
-- offline) are read on demand for the diagnostics only: no documented server switch blocks client visuals, so the
-- only block is the user's own setting "online also real lights".

local csp = require('src/csp')
local ac = csp.ac
local M = {
  isOnline = false,
  extrasRead = false,
  extrasText = '',
  BANNER = 'Skutečná světla (dálková, výstražná, přepínače) vidí i ostatní jezdci.',
  BLOCKED = 'online vypnuto v nastavení (skutečná světla vidí i ostatní jezdci)',
}

function M.update(ST)
  M.isOnline = ST.isOnline == true
end

-- Czech reason why real light controls may not be used now, or nil.
function M.realBlock(allowOnline)
  if M.isOnline and not allowOnline then return M.BLOCKED end
  return nil
end

-- Section names of the server's online extras (once, on demand).
function M.readExtras()
  if M.extrasRead then return M.extrasText end
  M.extrasRead = true
  local ok, cfg = pcall(ac.INIConfig.onlineExtras)
  if not ok then
    M.extrasText = 'online extras nejdou přečíst: ' .. tostring(cfg)
  elseif not cfg or type(cfg.sections) ~= 'table' then
    M.extrasText = 'server nemá online extras (nebo nejste online)'
  else
    local names = {}
    for name in pairs(cfg.sections) do names[#names + 1] = tostring(name) end
    table.sort(names)
    M.extrasText = #names > 0 and ('online extras: ' .. table.concat(names, ', ')) or 'online extras jsou prázdné'
  end
  return M.extrasText
end

-- Session change: read the extras again next time.
function M.reset()
  M.extrasRead, M.extrasText = false, ''
end

return M
