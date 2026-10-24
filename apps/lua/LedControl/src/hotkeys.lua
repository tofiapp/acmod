-- Bindable buttons (CSP controls, ac.ControlButton as TimeShift uses it), polled in script.update so they work with
-- the window closed.

local config = require('src/config')

local S = config.S
local M = {}

local ok, button = pcall(ac.ControlButton, '__APP_LEDCONTROL_MASTER')
M.master = ok and button or nil

function M.update()
  if M.master and M.master:pressed() then config.set('master', not S.master) end
end

return M
