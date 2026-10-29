-- Optimizer for the KeyDrive throttle core (phase 5): random search, then Nelder-Mead, in a normalised parameter box.
-- TUNING SET ONLY (never the hidden set), every candidate scored at nominal and +-20 % grip/power (evaluate.lua).
-- Usage (via optimize.py): luajit sim/optimize.lua <root> <mode 1|2> <seed> <randomIters> <nmIters> <outPrefix> [start]
--   writes <outPrefix>.lua (best params so far, Lua table) and <outPrefix>.log

local ROOT, MODE, SEED, NRAND, NNM, OUT, START, ANCHOR = ...
-- ANCHOR: optional parameter file: evaluate's anchor mode (smoother than it, not slower or more cautious)
local anchorParams = (ANCHOR and ANCHOR ~= '') and dofile(ANCHOR) or nil
package.path = ROOT .. '/sim/?.lua;' .. ROOT .. '/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path
MODE, SEED, NRAND, NNM = tonumber(MODE) or 2, tonumber(SEED) or 1, tonumber(NRAND) or 30, tonumber(NNM) or 60

local evaluate = require('evaluate')
local Throttle = require('core/throttle')
local Traction = require('core/traction')

-- name, group, lo, hi, log scale
local SPACE = {
  { 'TARGET_SLIP', 'throttle', 0.7, 1.0 }, -- the core caps it at 1 (tyre peak)
  { 'ASSIST_FALL', 'throttle', 0.5, 5 },
  { 'ASSIST_FALL_SEVERE', 'throttle', 1, 5 },
  { 'SLIP_TAU', 'traction', 0.005, 0.08, true },
  { 'K_DOWN', 'traction', 0.5, 25, true },
  { 'K_DOWN_SEVERE', 'traction', 0.5, 30, true },
  { 'K_BACK', 'traction', 0.2, 5, true },
  { 'HOLD_BAND', 'traction', 0.55, 0.98 },
  { 'FLOOR', 'traction', 0.05, 0.5 },
  { 'RETURN', 'traction', 0.7, 1.0 },
  { 'LEARN_MARGIN', 'traction', 0.85, 1.0 },
  { 'CREEP', 'traction', 0.0, 0.3 },
}
if MODE == 2 then
  for _, p in ipairs({
    { 'D_TAU', 'traction', 0.005, 0.1, true },
    { 'PRED', 'traction', 0, 0.1 },
    { 'AW', 'traction', 0.01, 0.3 },
    { 'K_UP', 'traction', 0.1, 3, true },
    { 'FALL_MAX', 'traction', 1, 5 },
    { 'V_REF', 'traction', 0, 8 },
    { 'MEM', 'traction', 0, 1 },
    { 'LAT_SPLIT', 'traction', 0, 1 },
    { 'SPARE', 'traction', 0.3, 1.0 },
    { 'FORGET_DELAY', 'traction', 0.05, 1.0, true },
    { 'FORGET_RATE', 'traction', 0.2, 5, true },
    { 'LEARN_LAT', 'traction', 0.2, 1.0 },
    { 'FLOOR_LAT', 'traction', 0.05, 0.4 },
    { 'HOLD_RISE', 'traction', 0, 0.6 },
    { 'ELLIPSE', 'traction', 0.75, 1.2 },
    { 'GUARD_LEVEL', 'traction', 0.75, 1.3 },
    { 'RET_HOLD', 'traction', 0, 0.8 },
    { 'RET_ARM', 'traction', 0.9, 1.3 },
    { 'RET_LOW', 'traction', 0.3, 0.9 },
    { 'PRED_KD', 'traction', 0.2, 1 },       -- cut rate scale while only the prediction is over the target
  }) do SPACE[#SPACE + 1] = p end
else
  for _, p in ipairs({
    { 'PULL', 'traction', 0.5, 0.98 },
    { 'PERSIST', 'traction', 0.05, 1 },
    { 'K_PRE', 'traction', 0.2, 4, true },
  }) do SPACE[#SPACE + 1] = p end
end
local D = #SPACE

local function defaults()
  local t = { throttle = {}, traction = { MODE = MODE } }
  for _, sp in ipairs(SPACE) do
    local src = sp[2] == 'throttle' and Throttle.DEFAULTS or Traction.DEFAULTS
    t[sp[2]][sp[1]] = src[sp[1]]
  end
  return t
end

local function toParams(x)
  local t = { throttle = {}, traction = { MODE = MODE } }
  for i, sp in ipairs(SPACE) do
    local u = math.min(1, math.max(0, x[i]))
    local v
    if sp[5] then v = math.exp(math.log(sp[3]) + (math.log(sp[4]) - math.log(sp[3])) * u)
    else v = sp[3] + (sp[4] - sp[3]) * u end
    if sp[1] == 'MEM' or sp[1] == 'LAT_SPLIT' then v = v >= 0.5 and 1 or 0 end
    t[sp[2]][sp[1]] = v
  end
  return t
end

local function toX(params)
  local x = {}
  for i, sp in ipairs(SPACE) do
    local v = params[sp[2]][sp[1]]
    if v == nil then v = (sp[2] == 'throttle' and Throttle.DEFAULTS or Traction.DEFAULTS)[sp[1]] end
    local u
    if sp[5] then u = (math.log(math.max(v, sp[3])) - math.log(sp[3])) / (math.log(sp[4]) - math.log(sp[3]))
    else u = (v - sp[3]) / (sp[4] - sp[3]) end
    x[i] = math.min(1, math.max(0, u))
  end
  return x
end

local function serialize(params, cost, passed, runs, nscales)
  local lines = { string.format('-- cost %.4f, %d/%d runs pass (tuning set, physics rate, %d grip/power scale(s))',
    cost, passed, runs, nscales), 'return {' }
  for _, g in ipairs({ 'throttle', 'traction' }) do
    local keys = {}
    for k in pairs(params[g]) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format('%s = %.6g', k, params[g][k]) end
    lines[#lines + 1] = string.format('  %s = { %s },', g, table.concat(parts, ', '))
  end
  lines[#lines + 1] = '}'
  return table.concat(lines, '\n') .. '\n'
end

local logf = io.open(OUT .. '.log', 'a')
local function log(msg)
  logf:write(msg .. '\n'); logf:flush()
  print(msg)
end

local st = (SEED * 7919 + 17) % 2147483648
local function rnd()
  st = (st * 1103515245 + 12345) % 2147483648
  return (st + 0.5) / 2147483648
end
local function gauss()
  return math.sqrt(-2 * math.log(rnd())) * math.cos(2 * math.pi * rnd())
end

-- Random search scores on the nominal cars only (fast); Nelder-Mead on nominal plus two opposite +-20 % shifts.
local SCALES_RANDOM = { { 1, 1 } }
local SCALES_NM = { { 1, 1 }, { 0.8, 1.2 }, { 1.2, 0.8 } }
local scales = SCALES_RANDOM

local best, bestX, bestInfo = math.huge, nil, nil
local evals = 0
local function f(x)
  local p = toParams(x)
  local cost, passed, runs, fails = evaluate.evaluate(ROOT, 'tuning', p, { scales = scales, anchor = anchorParams })
  evals = evals + 1
  if cost < best then
    best, bestX = cost, { unpack(x) }
    bestInfo = string.format('%d/%d pass', passed, runs)
    local fh = io.open(OUT .. '.lua', 'w')
    fh:write(serialize(p, cost, passed, runs, #scales)); fh:close()
    local fk = {}
    for k, n in pairs(fails) do fk[#fk + 1] = k .. ' ' .. n end
    table.sort(fk)
    log(string.format('eval %d: NEW BEST cost %.4f, %s, fails: %s', evals, cost, bestInfo, table.concat(fk, ', ')))
  end
  return cost
end

local start = START and START ~= '' and dofile(START) or defaults()
start.traction = start.traction or {}
start.traction.MODE = MODE
local x0 = toX(start)
log(string.format('mode %d seed %d: %d parameters, start cost %.4f', MODE, SEED, D, f(x0)))

-- 1. random search: half uniform in the box, half around the best
for i = 1, NRAND do
  local x = {}
  if i % 2 == 1 then
    for k = 1, D do x[k] = rnd() end
  else
    for k = 1, D do x[k] = math.min(1, math.max(0, bestX[k] + 0.15 * gauss())) end
  end
  f(x)
end
log(string.format('random search done: best %.4f (%s) after %d evals', best, bestInfo, evals))

-- 2. Nelder-Mead from the best point (re-scored on the wider scale set)
scales = SCALES_NM
best = math.huge
local x1 = { unpack(bestX) }
local simplex, values = { x1 }, { f(x1) }
for k = 1, D do
  local x = { unpack(bestX) }
  x[k] = x[k] + (x[k] < 0.5 and 0.12 or -0.12)
  simplex[#simplex + 1] = x
  values[#values + 1] = f(x)
end
local function clamp(x) for k = 1, D do x[k] = math.min(1, math.max(0, x[k])) end return x end
for it = 1, NNM do
  -- sort
  local idx = {}
  for i = 1, D + 1 do idx[i] = i end
  table.sort(idx, function (a, b) return values[a] < values[b] end)
  local s2, v2 = {}, {}
  for i, j in ipairs(idx) do s2[i], v2[i] = simplex[j], values[j] end
  simplex, values = s2, v2
  local c = {}
  for k = 1, D do
    local sum = 0
    for i = 1, D do sum = sum + simplex[i][k] end
    c[k] = sum / D
  end
  local w = simplex[D + 1]
  local xr = {}
  for k = 1, D do xr[k] = c[k] + (c[k] - w[k]) end
  clamp(xr)
  local fr = f(xr)
  if fr < values[1] then
    local xe = {}
    for k = 1, D do xe[k] = c[k] + 2 * (c[k] - w[k]) end
    clamp(xe)
    local fe = f(xe)
    if fe < fr then simplex[D + 1], values[D + 1] = xe, fe else simplex[D + 1], values[D + 1] = xr, fr end
  elseif fr < values[D] then
    simplex[D + 1], values[D + 1] = xr, fr
  else
    local xc = {}
    for k = 1, D do xc[k] = c[k] + 0.5 * (w[k] - c[k]) end
    local fc = f(xc)
    if fc < values[D + 1] then
      simplex[D + 1], values[D + 1] = xc, fc
    else
      for i = 2, D + 1 do
        for k = 1, D do simplex[i][k] = simplex[1][k] + 0.5 * (simplex[i][k] - simplex[1][k]) end
        values[i] = f(simplex[i])
      end
    end
  end
  if it % 10 == 0 then log(string.format('NM iteration %d: best %.4f (%s), %d evals', it, best, bestInfo, evals)) end
end
log(string.format('done: best %.4f (%s) after %d evals -> %s.lua', best, bestInfo, evals, OUT))
logf:close()
