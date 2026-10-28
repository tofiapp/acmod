-- Bindable buttons (CSP controls, ac.ControlButton as TimeShift uses it; bound in the Nastavení tab with
-- :control()), polled in script.update so they work with the window closed. Handlers are set by the entry script.

local csp = require('src/csp')
local ac = csp.ac
local M = { list = {} }

local function make(key, id, name)
  local ok, button = pcall(ac.ControlButton, id)
  local e = { key = key, id = id, name = name, button = ok and button or nil, handler = nil }
  M.list[#M.list + 1] = e
  M[key] = e
end

make('master', '__APP_LEDCONTROL_MASTER', 'Hlavní vypínač (zapnout / vypnout vše)')
make('nextPreset', '__APP_LEDCONTROL_NEXT_PRESET', 'Další preset')
make('flash', '__APP_LEDCONTROL_FLASH', 'Problik dálkovými světly')
make('displayPage', '__APP_LEDCONTROL_DISPLAY_PAGE', 'Další stránka displeje')

function M.on(key, fn)
  if M[key] then M[key].handler = fn end
end

function M.update()
  local list = M.list
  for i = 1, #list do
    local e = list[i]
    if e.button and e.handler and e.button:pressed() then e.handler() end
  end
end

return M
