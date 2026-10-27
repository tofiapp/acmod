-- Controllers the simulator can drive. Each factory returns function(view, car) -> { update(dt, key, view, ay),
-- request() }. The KeyDrive one runs the game's own core (extension/lua/joypad-assist/KeyDrive/core/throttle.lua).

local Throttle = require('core/throttle')

local M = {}

-- KeyDrive throttle core with its default settings (settings.ini) unless overridden.
function M.keydrive(params, tractionParams)
  return function (view)
    local th = Throttle.new(params, tractionParams)
    th:configure(view)
    return {
      core = th,
      update = function (dt, key, v, ay) return th:update(dt, key, v, ay, 0) end,
      request = function () return th.request end,
    }
  end
end

-- Baseline: the same ramp without traction control (what a plain gamepad-mode keyboard does).
function M.plainRamp(rise, fall)
  return M.keydrive({ TRACTION = false, RISE = rise or 1.2, FALL = fall or 4 })
end

return M
