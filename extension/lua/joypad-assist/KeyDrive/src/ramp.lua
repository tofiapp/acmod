-- Rate limiters. Rates are in units per second, so results do not depend on the physics rate.

local M = {}

-- Moves `x` towards `target`, rising at most `rise` and falling at most `fall` units per second.
function M.step(x, target, rise, fall, dt)
  local d = target - x
  if d > 0 then
    local s = rise * dt
    if d > s then d = s end
  else
    local s = fall * dt
    if -d > s then d = -s end
  end
  return x + d
end

-- Symmetric version for signed values (steering): `out` moves away from zero, `back` towards zero
-- or across it.
function M.stepSigned(x, target, out, back, dt)
  local rate = out
  if (x > 0 and target < x) or (x < 0 and target > x) then rate = back end
  local d = target - x
  local s = rate * dt
  if d > s then d = s elseif d < -s then d = -s end
  return x + d
end

return M
