-- Quantities for the custom condition builder ("Vlastní podmínka"): a scenario is active while every row holds.
-- Rows are stored as { q = id, op = '<', v = number } and compiled into numeric arrays; evaluation does not allocate.

local M = {}

-- id, Czech name, unit, getter (ST -> number; booleans as 0 / 1), slider range, boolean
M.QUANTITIES = {
  { id = 'speed', name = 'Rychlost', unit = 'km/h', min = 0, max = 400, get = function (S) return S.speed end },
  { id = 'rpm', name = 'Otáčky', unit = 'ot/min', min = 0, max = 20000, get = function (S) return S.rpm end },
  { id = 'rpmPct', name = 'Otáčky (% omezovače)', unit = '%', min = 0, max = 110,
    get = function (S) return S.rpmLimiter > 0 and S.rpm / S.rpmLimiter * 100 or 0 end },
  { id = 'gear', name = 'Rychlostní stupeň', unit = '(-1 = R, 0 = N)', min = -1, max = 10, get = function (S) return S.gear end },
  { id = 'fuel', name = 'Palivo', unit = 'l', min = 0, max = 150, get = function (S) return S.fuel end },
  { id = 'gas', name = 'Plyn', unit = '%', min = 0, max = 100, get = function (S) return S.gas * 100 end },
  { id = 'brake', name = 'Brzda', unit = '%', min = 0, max = 100, get = function (S) return S.brake * 100 end },
  { id = 'rain', name = 'Déšť', unit = '%', min = 0, max = 100, get = function (S) return S.rain * 100 end },
  { id = 'wetness', name = 'Mokrá trať', unit = '%', min = 0, max = 100, get = function (S) return S.wetness * 100 end },
  { id = 'time', name = 'Denní doba', unit = 'h', min = 0, max = 24, get = function (S) return S.timeHours end },
  { id = 'lap', name = 'Kolo', unit = '', min = 0, max = 100, get = function (S) return S.lap end },
  { id = 'position', name = 'Pozice v závodě', unit = '', min = 0, max = 60, get = function (S) return S.position end },
  { id = 'damage', name = 'Poškození karoserie', unit = '', min = 0, max = 200, get = function (S) return S.damage end },
  { id = 'engine', name = 'Životnost motoru', unit = '', min = 0, max = 1000, get = function (S) return S.engineLife end },
  { id = 'pitlane', name = 'V pit lane', neg = 'mimo pit lane', bool = true, get = function (S) return S.inPitlane and 1 or 0 end },
  { id = 'limiter', name = 'Pit limiter zapnutý', neg = 'pit limiter vypnutý', bool = true, get = function (S) return S.pitLimiter and 1 or 0 end },
  { id = 'drs', name = 'DRS otevřené', neg = 'DRS zavřené', bool = true, get = function (S) return S.drsActive and 1 or 0 end },
  { id = 'abs', name = 'ABS zasahuje', neg = 'ABS nezasahuje', bool = true, get = function (S) return S.absInAction and 1 or 0 end },
  { id = 'tc', name = 'TC zasahuje', neg = 'TC nezasahuje', bool = true, get = function (S) return S.tcInAction and 1 or 0 end },
  { id = 'lights', name = 'Světla zapnutá', neg = 'světla vypnutá', bool = true, get = function (S) return S.headlights and 1 or 0 end },
}
M.OPS = { '<', '<=', '>', '>=', '=', '!=' }
M.OP_NAMES = { ['<'] = '<', ['<='] = '≤', ['>'] = '>', ['>='] = '≥', ['='] = '=', ['!='] = '≠' }

local BY_ID = {}
for i = 1, #M.QUANTITIES do BY_ID[M.QUANTITIES[i].id] = M.QUANTITIES[i] end
M.BY_ID = BY_ID
local OP_INDEX = {}
for i = 1, #M.OPS do OP_INDEX[M.OPS[i]] = i end

local function holds(op, x, v)
  if op == '<' then return x < v elseif op == '<=' then return x <= v
  elseif op == '>' then return x > v elseif op == '>=' then return x >= v
  elseif op == '=' then return math.abs(x - v) < 0.5 end
  return math.abs(x - v) >= 0.5
end

-- Sanitised copy of stored rows (unknown quantities and operators dropped, at most 8 rows). Rows of yes / no
-- quantities become "= 1" or "= 0" with the meaning eval gives them, so describe() and the UI agree.
function M.sanitise(rows)
  local out = {}
  if type(rows) ~= 'table' then return out end
  for i = 1, math.min(#rows, 8) do
    local r = rows[i]
    local v = type(r) == 'table' and tonumber(r.v)
    if v and v == v and v > -1e9 and v < 1e9 and BY_ID[r.q] and OP_INDEX[r.op] then
      if BY_ID[r.q].bool then
        out[#out + 1] = { q = r.q, op = '=', v = holds(r.op, 1, v) and 1 or 0 }
      else
        out[#out + 1] = { q = r.q, op = r.op, v = v }
      end
    end
  end
  return out
end

function M.compile(rows)
  rows = M.sanitise(rows)
  local c = { n = #rows, get = {}, op = {}, v = {} }
  for i = 1, #rows do
    c.get[i] = BY_ID[rows[i].q].get
    c.op[i] = OP_INDEX[rows[i].op]
    c.v[i] = rows[i].v
  end
  return c
end

-- true when every row holds (an empty condition never holds, so a new custom scenario stays dark).
function M.eval(c, S)
  if c.n == 0 then return false end
  for i = 1, c.n do
    local x, v, op = c.get[i](S), c.v[i], c.op[i]
    local ok
    if op == 1 then ok = x < v
    elseif op == 2 then ok = x <= v
    elseif op == 3 then ok = x > v
    elseif op == 4 then ok = x >= v
    elseif op == 5 then ok = math.abs(x - v) < 0.5
    else ok = math.abs(x - v) >= 0.5 end
    if not ok then return false end
  end
  return true
end

-- Name as used inside a sentence: first letter small unless the name starts with an abbreviation (DRS, ABS, TC).
local SMALL = { ['Ž'] = 'ž', ['Š'] = 'š', ['Č'] = 'č', ['Ř'] = 'ř', ['Ď'] = 'ď' }
local function inSentence(name)
  if name:match('^%u%u') then return name end
  local first2 = name:sub(1, 2)
  if SMALL[first2] then return SMALL[first2] .. name:sub(3) end
  return name:sub(1, 1):lower() .. name:sub(2)
end

function M.describe(rows)
  rows = M.sanitise(rows)
  if #rows == 0 then return 'bez podmínky (nikdy)' end
  local parts = {}
  for i = 1, #rows do
    local q = BY_ID[rows[i].q]
    if q.bool then
      local yes = (rows[i].v >= 0.5) == (rows[i].op ~= '!=')
      parts[i] = yes and inSentence(q.name) or (q.neg or ('ne ' .. inSentence(q.name)))
    else
      parts[i] = string.format('%s %s %g%s', inSentence(q.name), M.OP_NAMES[rows[i].op], rows[i].v,
        q.unit ~= '' and (' ' .. q.unit) or '')
    end
  end
  return table.concat(parts, ' a ')
end

return M
