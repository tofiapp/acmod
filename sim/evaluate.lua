-- Evaluates a controller parameter set on a scenario set across cars, rates and grip/power shifts, with the oracle
-- and zero-throttle references cached in sim/out/refcache-<set>.lua (they do not depend on the controller, only on
-- the key ramp RISE/FALL). Used by optimize.lua; pure LuaJIT.

local runner = require('runner')
local metrics = require('metrics')
local controllers = require('controllers')

local M = {}

-- Weights. Target (the user's own verdicts on the three parameter sets he drove): v0.11.1 (core/tuned.lua) better
-- than BOTH v0.10.x s12 ("sometimes needlessly cautious", "after a kerb it refused to accelerate") and v0.11.0 r63
-- ("braver, but the jerking came back"); both complaints were equally serious, so the caution s12 shows over v0.11.1
-- should cost about as much as the pulsing r63 shows over it. Measured (tuning set, 333 Hz, 2026-10-29): with the old
-- weights caution was nearly free (real needless share 0.30 vs 0.12: +5; sim loss 0.23 vs 0.08 of the oracle's gain:
-- +0.6) while the pulse was uncapped (5 /s on the user's cars cost 10 + 24 per run, wet/cold runs at 10-15 /s
-- dominated), so the cost ranked s12 64 < v0.11.1 75 < r63 89, the opposite of the user. Now (sim/compare.py):
-- v0.11.1 75 < r63 80 < s12 82 at 333 Hz, 78 < 82 < 86 at 50-165 fps; r63 still costs more than s12 on every pulse
-- term (sim 13.7 vs 8.3, real 19.8 vs 11.5).
M.REAL_WEIGHT = 80      -- per unit share of key-held time with a needless cut on the real logs (was 30): the logs are
                        -- the only place where the user's "needlessly cautious" was measured on his own cars; the gap
                        -- s12 - v0.11.1 (0.18) now costs ~14.5, about r63's extra pulsing over v0.11.1 (real 5.5,
                        -- sim 1.3, steady checks ~1) plus the safety margin s12 earns in the sim (~7)
-- Throttle pulse (v0.11.0 user: "the jerking came back"; 0.11.1: "clearly smaller, but I want to perfect it"):
-- per direction change/s over the bound, where the bound is the USER 1 /s or, if higher, what the perfect foot itself
-- does in the same run (it reverses too where the slip limit moves; short scenarios measured 0.5-1 /s for it).
M.PULSE_WEIGHT = 2      -- per run: whole key-held time
M.PULSE_LOW_WEIGHT = 2  -- per run: gears 1-2 on top (where the real pulsing is: 0.11.0 logs 4.4 /s vs 1.7-2.7 overall)
M.PULSE_USER = 1.5      -- the user's own cars on top of their x2 run weight (their pulsing is what the user feels)
M.PULSE_CAP = 10        -- per run, before the run weight: at most one failed check's worth (the failed pulse check
                        -- itself adds its 10 on top). Uncapped, 5 /s on the user's cars cost 10 + 24 per run and one
                        -- pulsing run outweighed several spins (a failed peakSlip check is 10)
-- wet / cold tyres / grip change: x0.25 on the pulse cost (the failed check included; it still counts as a failure
-- in the pass numbers). Their pulsing comes from extrapolated physics (the noise model is fitted to dry logs only)
-- and reached 10-15 /s for every controller, which dominated the pulse cost without telling the sets apart
M.PULSE_GROUP = { wet = 0.25, cold = 0.25, grip = 0.25 }
M.REAL_PULSE_WEIGHT = 8 -- per direction change/s over 1 of the REPLAYED output in gears 1-2 on the logs with the
                        -- logged output (gas_out: 0.11+ logs), where the replay reproduces the logged low-gear rate
                        -- (core/tuned.lua g1-g5: 2.1-3.0 replayed vs 2.0-3.0 logged; r63 e/f 4.0/4.1 vs 4.3/4.6)
M.LOSS_WEIGHT = 20      -- per unit loss (share of the oracle's gain over no throttle), on top of the failed check and
                        -- its bound grading, also when passing (was 4, before that 2): s12 averages 0.23 in the sim vs
                        -- 0.08 for v0.11.1, and 4 x 0.15 = 0.6 was less than a single failed check in 16 runs; now a
                        -- loss of half the oracle's gain costs as much as a failed check
M.REAL_RISK_WEIGHT = 300 -- per unit share of key-held time on the 0.11+ logs where the real tyres were past their peak
                        -- and the replayed core sends more than the game did (replay.lua RISK_*). A core that never
                        -- cuts paid 0 on both real-log terms and won the cost (57.6 vs 74.7 for v0.11.1) although it
                        -- failed the peak-slip check in 285 of 380 sim runs
M.SAFETY_FAIL = { peakSlip = 10, over13Time = 10, slideTime = 10 } -- per failed safety check on top of its 10: a spin
                        -- or slide must cost more than a pulsing or cautious run
M.GRADE_WEIGHT = {      -- per graded value past its bound (default 1, each capped at 5 before the weight)
  recoveryTime = 3,     -- v0.10 user: "after a kerb it refused to accelerate on straight asphalt" (a named complaint;
                        -- 1 s late costs 3, the cap 15)
}
M.CARS = { 'rwd_supra', 'rwd_mustang', 'fwd_hothatch', 'awd_gt' }
-- robustness: nominal plus +-20 % grip and power (the user's spec)
M.SCALES = { { 1, 1 }, { 0.8, 1 }, { 1.2, 1 }, { 1, 0.8 }, { 1, 1.2 } }

local function hash(str)
  local h = 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
  return h
end
M.hash = hash

local function num(x) return x and string.format('%.17g', x) or 'nil' end
local function serialize(t)
  local out = { 'return {' }
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    out[#out + 1] = string.format('  [%q] = { peakSlip = %s, over13Time = %s, slideTime = %s, dist = %s, pulse = %s, ' ..
      'pulseLow = %s, pulseHeld = %s, pulseHeldLow = %s, sig = %s },', k, num(v.peakSlip), num(v.over13Time),
      num(v.slideTime), num(v.dist), num(v.pulse), num(v.pulseLow), num(v.pulseHeld), num(v.pulseHeldLow), num(v.sig))
  end
  out[#out + 1] = '}'
  return table.concat(out, '\n')
end
M.serialize = serialize

function M.load(root, set)
  local dir = set == 'hidden' and '/sim/scenarios/hidden/' or '/sim/scenarios/'
  local names = dofile(root .. dir .. 'index.lua')
  local scns = {}
  for i, n in ipairs(names) do
    local path = root .. dir .. n .. '.lua'
    local f = assert(io.open(path, 'rb'))
    local src = f:read('*a')
    f:close()
    -- sig: hash of the scenario source; a cached reference of an edited scenario is recomputed
    scns[i] = { name = n, def = dofile(path), sig = hash(src) }
  end
  local cars = {}
  for i, c in ipairs(M.CARS) do cars[i] = { name = c, def = dofile(root .. '/sim/cars/' .. c .. '.lua') } end
  return scns, cars
end

-- References for every scenario x car x scale (computed once, then read from the cache file). An entry is
-- recomputed when its scenario changed (sig) or when it lacks the pulse fields (caches written before them).
M.refKey = function (sc, car, sg) return string.format('%s|%s|%.2f|%.2f', sc.name, car.name, sg[1], sg[2]) end
function M.refFresh(cache, sc, key)
  local o = cache[key .. '|o']
  return o ~= nil and cache[key .. '|z'] ~= nil and o.sig == sc.sig and o.pulseHeld ~= nil
end
-- oracle and zero-throttle summaries of one scenario x car x scale
function M.refEntry(sc, car, sg, rise, fall)
  local seed = hash(sc.name .. car.name)
  local o = runner.run(sc.def, { car = car.def, grip = sg[1], power = sg[2], seed = seed, oracle = true,
    oracleRise = rise, oracleFall = fall })
  local z = runner.run(sc.def, { car = car.def, grip = sg[1], power = sg[2], seed = seed, zero = true })
  local so, sz = metrics.summarize(o, sc.def), metrics.summarize(z)
  so.sig, sz.sig = sc.sig, sc.sig
  return so, sz
end
function M.refPath(root, set, rise, fall)
  return string.format('%s/sim/out/refcache-%s-r%.3f-f%.3f.lua', root, set, rise, fall)
end
-- only: optional filter, a scenario name or 'scenario|car' (sim/refcache.py fills a cache in parallel, one process
-- per scenario x car, with write = false, and merges)
function M.references(root, set, scns, cars, scales, rise, fall, only, write)
  local path = M.refPath(root, set, rise, fall)
  local ok, cache = pcall(dofile, path)
  if not ok or type(cache) ~= 'table' then cache = {} end
  local dirty = false
  for _, sc in ipairs(scns) do
    for _, car in ipairs(cars) do
      if not only or only == sc.name or only == sc.name .. '|' .. car.name then
        for _, sg in ipairs(scales) do
          local key = M.refKey(sc, car, sg)
          if not M.refFresh(cache, sc, key) then
            cache[key .. '|o'], cache[key .. '|z'] = M.refEntry(sc, car, sg, rise, fall)
            dirty = true
          end
        end
      end
    end
  end
  if dirty and write ~= false then
    local f = io.open(path, 'w')
    if f then f:write(serialize(cache)); f:close() end
  end
  return cache, dirty
end

-- Cost of one evaluated run (lower is better): 10 per failed check, plus how far each graded value is past its
-- bound (x GRADE_WEIGHT), plus the loss itself (x LOSS_WEIGHT: faster is better even when passing), plus the pulse
-- part (its failed check, the excess over max(1 /s, oracle), capped, x PULSE_GROUP). Returns total and pulse part.
local BOUNDS = {
  peakSlip = 'peakSlip', over13Time = 'over13Time', slideTime = 'slideTime', steadyDirChanges = 'steadyDirChanges',
  steadyStd = 'steadyStd', maxRate = 'maxRate', recoveryTime = 'recoveryTime',
}
function M.runCost(res, userCar, group)
  local T = metrics.THRESHOLDS
  local c, cp = 0, 0
  for name, ok in pairs(res.checks) do
    if not ok then if name == 'pulse' then cp = cp + 10 else c = c + 10 + (M.SAFETY_FAIL[name] or 0) end end
  end
  local v = res.values
  for name, tk in pairs(BOUNDS) do
    if res.checks[name] ~= nil and v[name] then
      c = c + (M.GRADE_WEIGHT[name] or 1) * math.min(5, math.max(0, v[name] / T[tk] - 1))
    end
  end
  if v.loss and v.lossBound then
    c = c + math.min(5, math.max(0, v.loss / v.lossBound - 1)) + M.LOSS_WEIGHT * math.max(0, v.loss)
  end
  if v.pulse ~= nil then -- also when the check is n/a (oracle above 1 /s): graded against max(1, oracle) anyway
    -- graded against what the perfect foot itself does in the same run (it reverses the throttle too where the slip
    -- limit moves: short scenarios measured 0.5-1 /s for the oracle), never against less than the USER bound
    local base = math.max(T.pulse, v.oraclePulse or 0)
    local baseLow = math.max(T.pulse, v.oraclePulseLow or 0)
    local p = M.PULSE_WEIGHT * math.max(0, (v.pulse or 0) - base)
      + M.PULSE_LOW_WEIGHT * math.max(0, (v.pulseLow or 0) - baseLow)
    cp = cp + math.min(M.PULSE_CAP, p * (userCar and M.PULSE_USER or 1))
  end
  cp = cp * (M.PULSE_GROUP[group] or 1)
  return c + cp, cp
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
  local total, totalPulse, runs, passed = 0, 0, 0, 0
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
          -- the user's own cars (Supercars Gen3 Supra and Mustang) count double
          local user = car.name == 'rwd_supra' or car.name == 'rwd_mustang'
          local rc, rp = M.runCost(res, user, sc.def.group)
          local w = user and 2 or 1
          total, totalPulse = total + rc * w, totalPulse + rp * w
          runs = runs + 1
          if res.pass then passed = passed + 1 end
          for k, ok in pairs(res.checks) do if not ok then fails[k] = (fails[k] or 0) + 1 end end
        end
      end
    end
  end
  local cost = total / runs
  -- breakdown (5th return value): sim without pulse, sim pulse, real caution, real pulse
  local parts = { sim = (total - totalPulse) / runs, simPulse = totalPulse / runs, realCaution = 0, realPulse = 0 }
  -- real driving (open-loop replay of the user's logs): share of key-held time with a needless cut. The sim judges
  -- safety, this judges caution (user v0.10: "sometimes needlessly cautious", "after a kerb it refused to accelerate").
  if opts.real ~= false then
    local share, pulse, _, _, risk = require('replay').realAll(root, params.throttle, params.traction)
    fails.realCaution = math.floor(share * 1000 + 0.5) -- per mille, for the log
    fails.realPulseLow = math.floor((pulse.rateLow or 0) * 100 + 0.5) -- 1/100 changes/s, for the log
    parts.realCaution = M.REAL_WEIGHT * share
    parts.realPulse = M.REAL_PULSE_WEIGHT * math.max(0, (pulse.rateLow or 0) - 1)
    parts.realRisk = M.REAL_RISK_WEIGHT * risk
    fails.realRisk = math.floor(risk * 1000 + 0.5) -- per mille, for the log
    parts.realShare, parts.realPulseLow, parts.realRiskShare = share, pulse.rateLow, risk
    cost = cost + parts.realCaution + parts.realPulse + parts.realRisk
  end
  return cost, passed, runs, fails, parts
end

return M
