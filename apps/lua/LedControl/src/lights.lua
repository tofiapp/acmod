-- Lights of the player's car (tab Světla). Placeholder interface; phase 6 fills it in.
local M = { available = false, items = {}, version = 0 }

function M.init(carId, profile, layout, info) end
function M.update(dt, ST) end
function M.release() end
function M.flash() end
function M.draw3D() end
function M.frameBegin() end

return M
