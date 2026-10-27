-- Normalised tyre: Pacejka "magic formula" in units of the peak slip, combined slip by the similarity method.
--   sx = slip ratio / kappaPeak, sy = slip angle / alphaPeak, s = sqrt(sx^2 + sy^2) (= AC's ndSlip: 1 at the peak)
--   force / (mu * Fz) = f(s), split along (sx, sy) / s
-- f peaks at exactly 1 at s = 1 and falls to ~0.83 at s = 3 and ~0.64 at s = 10 (a spinning tyre keeps most grip).

local M = {}

local B, C, E = 1.57, 1.65, 0.3   -- chosen so that the maximum sits at s = 1 (C * atan(arg(1)) = pi / 2)
local atan, sin, sqrt = math.atan, math.sin, math.sqrt

-- Past the peak the force falls towards a tail; TAIL scales that fall (1 = plain Pacejka, f(10) = 0.64; 0.72 fitted to
-- the user's Supra logs: median longitudinal g at rear ndSlip 20-80 is ~0.7 of the value at the peak).
local TAIL = 1

function M.setTail(k)
  TAIL = k or 1
end

function M.f(s)
  if s < 0 then return -M.f(-s) end
  local bs = B * s
  local v = sin(C * atan(bs - E * (bs - atan(bs))))
  if s > 1 then v = 1 - (1 - v) * TAIL end
  return v
end

-- Lateral share g(sy) = f(s) * sy / s for a given sx (both >= 0).
local function g(sx, sy)
  local s = sqrt(sx * sx + sy * sy)
  if s < 1e-9 then return 0 end
  return M.f(s) * sy / s
end
M.g = g

-- Largest lateral share for this longitudinal slip and the sy where it is reached (golden-section search).
function M.lateralMax(sx)
  sx = sx < 0 and -sx or sx
  local a, b = 0, 4
  local r = 0.6180339887
  local c, d = b - r * (b - a), a + r * (b - a)
  local gc, gd = g(sx, c), g(sx, d)
  for _ = 1, 28 do
    if gc > gd then
      b, d, gd = d, c, gc
      c = b - r * (b - a); gc = g(sx, c)
    else
      a, c, gc = c, d, gd
      d = a + r * (b - a); gd = g(sx, d)
    end
  end
  local sy = (a + b) * 0.5
  return g(sx, sy), sy
end

-- sy giving the lateral share u (0..1) at this sx; if u cannot be reached, the sy of the maximum and false.
function M.solveLateral(sx, u)
  if u <= 0 then return 0, true end
  sx = sx < 0 and -sx or sx
  local gmax, symax = M.lateralMax(sx)
  if u >= gmax then return symax, false end
  local lo, hi = 0, symax
  for _ = 1, 30 do
    local mid = (lo + hi) * 0.5
    if g(sx, mid) < u then lo = mid else hi = mid end
  end
  return (lo + hi) * 0.5, true
end

return M
