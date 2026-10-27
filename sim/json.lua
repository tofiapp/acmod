-- Minimal JSON encoder (sorted keys, numbers rounded to 6 significant digits).
local M = {}

local function enc(v, out, indent, pad)
  local t = type(v)
  if t == 'table' then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = '['
      for i, x in ipairs(v) do
        out[#out + 1] = (i > 1 and ',' or '') .. '\n' .. pad .. indent
        enc(x, out, indent, pad .. indent)
      end
      out[#out + 1] = '\n' .. pad .. ']'
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = '{'
      for i, k in ipairs(keys) do
        out[#out + 1] = (i > 1 and ',' or '') .. '\n' .. pad .. indent .. string.format('%q', k) .. ': '
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        enc(x, out, indent, pad .. indent)
      end
      out[#out + 1] = '\n' .. pad .. '}'
    end
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = 'null'
    else out[#out + 1] = string.format('%.6g', v) end
  elseif t == 'boolean' then
    out[#out + 1] = tostring(v)
  elseif v == nil then
    out[#out + 1] = 'null'
  else
    out[#out + 1] = string.format('%q', tostring(v)):gsub('\\\n', '\\n')
  end
end

function M.encode(v)
  local out = {}
  enc(v, out, '  ', '')
  return table.concat(out)
end

return M
