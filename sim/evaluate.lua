-- Evaluates a controller parameter set on a scenario set across cars, rates and grip/power shifts, with the oracle
-- and zero-throttle references cached in sim/out/refcache-<set>.lua (they do not depend on the controller, only on
-- the key ramp RISE/FALL). Used by optimize.lua; pure LuaJIT.

local runner = require('runner')
local metrics = require('metrics')
local controllers = require('controllers')

local M = {}

M.CARS = { 'rwd_supra', 'fwd_hothatch', 'awd_gt' }
-- robustness: nominal plus +-20 % grip and power (the user's spec)
M.SCALES = { { 1, 1 }, { 0.8, 1 }, { 1.2, 1 }, { 1, 0.8 }, { 1, 1.2 } }

local function hash(str)
  local h = 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
  return h
end
M.hash = hash

local function serialize(t)
  local out = { 'return {' }
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    out[#out + 1] = string.format('  [%q] = { peakSlip = %.17g, over13Time = %.17g, slideTime = %.17g, dist = %.17g },',
      k, v.peakSlip, v.over13Time, v.slideTime, v.dist)
  end
  out[#out + 1] = '}'
  return table.concat(out, '\n')
end

function M.load(root, set)
  local dir = set == 'hidden' and '/sim/scenarios/hidden/' or '/sim/scenarios/'
  local names = dofile(root .. dir .. 'index.lua')
  local scns = {}
  for i, n in ipairs(names) do scns[i] = { name = n, def = dofile(root .. dir .. n .. '.lua') } end
  local cars = {}
  for i, c in ipairs(M.CARS) do cars[i] = { name = c, def = dofile(root .. '/sim/cars/' .. c .. '.lua') } end
  return scns, cars
end

-- References for every scenario x car x scale (computed once, then read from the cache file).
function M.references(root, set, scns, cars, scales, rise, fall)
  local path = string.format('%s/sim/out/refcache-%s-r%.3f-f%.3f.lua', root, set, rise, fall)
  local ok, cache = pcall(dofile, path)
  if not ok or type(cache) ~= 'table' then cache = {} end
  local dirty = false
  for _, sc in ipairs(scns) do
    for _, car in ipairs(cars) do
      for _, sg in ipairs(scales) do
        local key = string.format('%s|%s|%.2f|%.2f', sc.name, car.name, sg[1], sg[2])
        if not cache[key .. '|o'] then
          local base = { car = car.def, grip = sg[1], power = sg[2], seed = hash(sc.name .. car.name) }
          local o = runner.run(sc.def, { car = car.def, grip = sg[1], power = sg[2], seed = base.seed, oracle = true,
            oracleRise = rise, oracleFall = fall })
          local z = runner.run(sc.def, { car = car.def, grip = sg[1], power = sg[2], seed = base.seed, zero = true })
          cache[key .. '|o'], cache[key .. '|z'] = metrics.summarize(o), metrics.summarize(z)
          dirty = true
        end
      end
    end
  end
  if dirty then
    local f = io.open(path, 'w')
    if f then f:write(serialize(cache)); f:close() end
  end
  return cache
end

-- Cost of one evaluated run (lower is better): 10 per failed check, plus how far each graded value is past its
-- bound, plus the loss itself (faster is better even when passing).
local BOUNDS = {
  peakSlip = 'peakSlip', over13Time = 'over13Time', slideTime = 'slideTime', steadyDirChanges = 'steadyDirChanges',
  steadyStd = 'steadyStd', maxRate = 'maxRate', recoveryTime = 'recoveryTime',
}
function M.runCost(res)
  local T = metrics.THRESHOLDS
  local c = 0
  for _, ok in pairs(res.checks) do if not ok then c = c + 10 end end
  local v = res.values
  for name, tk in pairs(BOUNDS) do
    if res.checks[name] ~= nil and v[name] then c = c + math.min(5, math.max(0, v[name] / T[tk] - 1)) end
  end
  if v.loss and v.lossBound then
    -- user v0.10: "sometimes needlessly cautious": speed weighs more (was 2 x loss)
    c = c + math.min(5, math.max(0, v.loss / v.lossBound - 1)) + 4 * math.max(0, v.loss)
  end
  return c
end

-- params = { throttle = {...}, traction = {...} }; opts = { rates = { 'physics' }, scales = M.SCALES }
function M.evaluate(root, set, params, opts)
  opts = opts or {}
  local scns, cars = M.load(root, set)
  local scales = opts.scales or M.SCALES
  local rates = opts.rates or { 'physics' }
  local rise = params.throttle and params.throttle.RISE or 1.2
  local fall = params.throttle and params.throttle.FALL or 4
  local cache = M.references(root, set, scns, cars, scales, rise, fall)
  local total, runs, passed = 0, 0, 0
  local fails = {}
  for _, sc in ipairs(scns) do
    for _, car in ipairs(cars) do
      for _, sg in ipairs(scales) do
        local key = string.format('%s|%s|%.2f|%.2f', sc.name, car.name, sg[1], sg[2])
        local ref = { oracle = cache[key .. '|o'], zero = cache[key .. '|z'], rise = rise, fall = fall }
        for _, rate in ipairs(rates) do
          local tr = runner.run(sc.def, { car = car.def, grip = sg[1], power = sg[2], rate = rate,
            seed = hash(sc.name .. car.name .. rate), controller = controllers.keydrive(params.throttle, params.traction) })
          local res = metrics.evaluate(sc.def, tr, ref)
          -- the user's own car (the Supra) counts double
          total = total + M.runCost(res) * (car.name == 'rwd_supra' and 2 or 1)
          runs = runs + 1
          if res.pass then passed = passed + 1 end
          for k, ok in pairs(res.checks) do if not ok then fails[k] = (fails[k] or 0) + 1 end end
        end
      end
    end
  end
  return total / runs, passed, runs, fails
end

return M
