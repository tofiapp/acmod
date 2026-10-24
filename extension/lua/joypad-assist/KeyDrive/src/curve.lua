-- Piecewise linear curve from a string like "0:250, 60:160, 120:100" (x:y pairs), parsed once.

local M = {}

function M.parse(text, fallback)
  local xs, ys = {}, {}
  if type(text) == 'string' then
    for x, y in text:gmatch('(-?[%d%.]+)%s*:%s*(-?[%d%.]+)') do
      xs[#xs + 1], ys[#ys + 1] = tonumber(x), tonumber(y)
    end
  end
  if #xs == 0 then
    if fallback then return M.parse(fallback) end
    xs[1], ys[1] = 0, 100
  end
  -- insertion sort by x (tiny lists)
  for i = 2, #xs do
    local x, y, j = xs[i], ys[i], i - 1
    while j >= 1 and xs[j] > x do
      xs[j + 1], ys[j + 1] = xs[j], ys[j]
      j = j - 1
    end
    xs[j + 1], ys[j + 1] = x, y
  end
  return { xs = xs, ys = ys, n = #xs }
end

function M.eval(c, x)
  local xs, ys, n = c.xs, c.ys, c.n
  if x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end
  for i = 2, n do
    if x <= xs[i] then
      local t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
      return ys[i - 1] + (ys[i] - ys[i - 1]) * t
    end
  end
  return ys[n]
end

return M
