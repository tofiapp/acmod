-- Calibration checks of the simulator against the user's real logs (not part of the tuning cost).
--
--   python sim/calibrate.py                 (or: luajit sim/calibrate.lua <repoRoot> [noise|pulse|all] [seeds])
--
-- 1. noise: statistics of KeyDrive's own measured longitudinal slip (traction.sx = tc_sx in the in-game log, the
--    load-weighted |slip ratio| of the driven wheels / learned peak ratio, filtered SLIP_TAU) at steady full
--    throttle, uncut, on a straight: steps between 40 Hz samples per gear (Mustang, 3rd-6th). Real values (REAL.noise)
--    come from the Mustang logs of v0.10-v0.11.1 (17 sessions, ~6500 rows of steady full throttle, rows resampled to
--    40 Hz like the sim; |lat_g| < 0.3, 0.3 s after the run starts).
-- 2. pulse: whole key-held throttle pulsing in 1st/2nd gear, the same measure as the analysis of the in-game logs:
--    throttle direction changes per second (1 % deadband) on 40 Hz samples of the sent throttle, key held, from 0.5 s
--    after the key press, per gear run (a shift starts a new run, its first 0.3 s skipped). Run for the three
--    parameter sets the user drove: s12 (v0.10.x), r63 (v0.11.0) and r63 + RET_HOLD 0.5 (v0.11.1, core/tuned.lua).
--    Real low-gear values (REAL.pulse) and their order s12 < r63+hold < r63 are the check.
-- Deterministic (fixed seeds); pure LuaJIT, runs the game's own throttle core.

local ROOT, MODE, NSEEDS = ...
ROOT = ROOT or '.'
package.path = ROOT .. '/sim/?.lua;' .. ROOT .. '/extension/lua/joypad-assist/KeyDrive/?.lua;' .. package.path

local runner = require('runner')
local Throttle = require('core/throttle')

local M = {}

M.REAL = {
  -- tc_sx steps at 40 Hz, steady full throttle (Mustang logs): level = median tc_sx, mad = 1.4826 x MAD of the steps,
  -- ratio = std / (1.4826 MAD), kurt = kurtosis of the steps; p99 = 99th percentile of |step|
  noise = {
    [3] = { level = 0.39, std = 0.027, mad = 0.021, ratio = 1.33, kurt = 5.8, p99 = 0.091 },
    [4] = { level = 0.29, std = 0.024, mad = 0.018, ratio = 1.35, kurt = 5.9, p99 = 0.082 },
    [5] = { level = 0.22, std = 0.021, mad = 0.011, ratio = 1.80, kurt = 11.5, p99 = 0.077 },
    [6] = { level = 0.19, std = 0.019, mad = 0.011, ratio = 1.68, kurt = 9.9, p99 = 0.070 },
  },
  -- all gears together: lag-k correlation of the steps and of |step| / level (bursts last ~0.5 s and more)
  acf = { [1] = 0.58, [3] = -0.49, [4] = -0.52, [8] = 0.14 },
  vol = { [8] = 0.24, [20] = 0.21 },
  -- low-gear (1st/2nd) throttle direction changes per second, whole key-held time (Mustang logs): s12 1.6 in v0.10.1
  -- (the code the sim runs: pin fix), 2.5 in v0.10.0; r63 4.4-4.5 (v0.11.0, sim/data/real e*, f*); r63 + RET_HOLD
  -- 2.2 (Spa) - 3.0 (Sachsenring) (v0.11.1, g*). Ratios against v0.10.1: hold / s12 1.4-1.85, r63 / s12 2.75
  pulse = { s12 = { 1.6, 2.5 }, hold = { 2.2, 3.0 }, r63 = { 4.4, 4.5 } },
}

M.SETS = {
  { name = 's12', file = ROOT .. '/sim/data/params-s12.lua', label = 'v0.10.x s12' },
  { name = 'hold', file = ROOT .. '/extension/lua/joypad-assist/KeyDrive/core/tuned.lua', label = 'v0.11.1 r63+RET_HOLD' },
  { name = 'r63', file = ROOT .. '/sim/data/params-r63.lua', label = 'v0.11.0 r63' },
}

local SAMPLE = 0.025

local function hash(str)
  local h = 5381
  for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
  return h
end

-- controller that also records the traction core's measured slip (physics rate: one record per step)
local function recording(P, rec)
  return function (view)
    local th = Throttle.new(P.throttle, P.traction)
    th:configure(view)
    return {
      update = function (dt, key, v, ay)
        local o = th:update(dt, key, v, ay, 0)
        rec[#rec + 1] = th.traction.sx
        return o
      end,
      request = function () return th.request end,
    }
  end
end

local function stats(d)
  local n = #d
  if n < 30 then return nil end
  local s = {}
  for i = 1, n do s[i] = d[i] end
  table.sort(s)
  local med = n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
  local dev = {}
  for i = 1, n do dev[i] = math.abs(d[i] - med) end
  table.sort(dev)
  local mad = 1.4826 * (n % 2 == 1 and dev[(n + 1) / 2] or (dev[n / 2] + dev[n / 2 + 1]) / 2)
  local mean = 0
  for i = 1, n do mean = mean + d[i] end
  mean = mean / n
  local m2, m4 = 0, 0
  for i = 1, n do local e = d[i] - mean; m2 = m2 + e * e; m4 = m4 + e * e * e * e end
  m2, m4 = m2 / n, m4 / n
  local ab = {}
  for i = 1, n do ab[i] = math.abs(d[i]) end
  table.sort(ab)
  return { n = n, std = math.sqrt(m2), mad = mad, ratio = math.sqrt(m2) / math.max(mad, 1e-9), kurt = m4 / (m2 * m2),
    p99 = ab[math.max(1, math.floor(0.99 * n))] }
end
M.stats = stats

-- steady straight full throttle in one gear (no shift), from kmh0 (the logs' 10th percentile speed in that gear)
local function steadyScn(gear, kmh0, dur)
  return { group = 'dry', start = { gear = gear, kmh = kmh0 }, duration = dur, gas = { { 0, dur } }, maxGear = gear }
end
M.NOISE_SCNS = {
  { gear = 3, scn = steadyScn(3, 146, 3.0) },
  { gear = 4, scn = steadyScn(4, 176, 4.0) },
  { gear = 5, scn = steadyScn(5, 212, 6.0) },
  { gear = 6, scn = steadyScn(6, 243, 6.0) },
}

local function corr(x, y)
  local n = #x
  if n < 10 then return 0 / 0 end
  local mx, my = 0, 0
  for i = 1, n do mx, my = mx + x[i], my + y[i] end
  mx, my = mx / n, my / n
  local sxy, sxx, syy = 0, 0, 0
  for i = 1, n do
    local a, b = x[i] - mx, y[i] - my
    sxy, sxx, syy = sxy + a * b, sxx + a * a, syy + b * b
  end
  return sxy / math.sqrt(sxx * syy)
end

-- tc_sx step statistics of one parameter set on one car, per gear, nSeeds seeds; opts.sensor / opts.dt passed on.
-- Also: lag-k correlation of the steps (acf[k]) and of their size |step| / level (vol[k], volatility clustering),
-- std of the core's filtered slip rate (tc_slip_rate)
function M.noise(car, P, nSeeds, opts)
  opts = opts or {}
  local out = {}
  for _, ns in ipairs(M.NOISE_SCNS) do
    local steps, levels, rates, runs = {}, {}, {}, {}
    for seed = 1, nSeeds do
      local rec, recRate = {}, {}
      local ctrl = function (view)
        local th = Throttle.new(P.throttle, P.traction)
        th:configure(view)
        return {
          update = function (dt, key, v, ay)
            local o = th:update(dt, key, v, ay, 0)
            rec[#rec + 1], recRate[#recRate + 1] = th.traction.sx, th.traction.slipRate
            return o
          end,
          request = function () return th.request end,
        }
      end
      local tr = runner.run(ns.scn, { car = car, rate = 'physics', seed = hash('noise' .. ns.gear .. seed),
        controller = ctrl, sensor = opts.sensor, dt = opts.dt })
      local dt = tr.t[2] - tr.t[1]
      local every = SAMPLE / dt
      -- 40 Hz samples; steady = throttle full and uncut, 0.3 s after it got there, below the shift rpm
      local prev, steadySince, run = nil, nil, nil
      local k = 1
      while true do
        local i = math.floor(k * every + 0.5)
        if i > tr.n then break end
        local ok = tr.key[i] and tr.thr[i] > 0.98 and tr.req[i] - tr.thr[i] < 0.01 and tr.v[i] * 3.6 > 10
          and tr.rpm[i] < car.shiftRpm
        if ok then
          steadySince = steadySince or tr.t[i]
          if tr.t[i] - steadySince >= 0.3 then
            local sx = rec[i]
            if prev then
              steps[#steps + 1] = sx - prev; levels[#levels + 1] = sx
              run[#run + 1] = { sx - prev, sx }
            else
              run = {}
              runs[#runs + 1] = run
            end
            rates[#rates + 1] = recRate[i]
            prev = sx
          end
        else
          steadySince, prev = nil, nil
        end
        k = k + 1
      end
    end
    local st = stats(steps)
    if st then
      table.sort(levels)
      st.level = levels[math.floor(#levels / 2) + 1]
      st.acf, st.vol = {}, {}
      for _, lag in ipairs({ 1, 3, 4, 8, 20 }) do
        local x, y, ax, ay = {}, {}, {}, {}
        for _, r in ipairs(runs) do
          for j = 1, #r - lag do
            x[#x + 1], y[#y + 1] = r[j][1], r[j + lag][1]
            ax[#ax + 1] = math.abs(r[j][1]) / math.max(r[j][2], 0.1)
            ay[#ay + 1] = math.abs(r[j + lag][1]) / math.max(r[j + lag][2], 0.1)
          end
        end
        st.acf[lag], st.vol[lag] = corr(x, y), corr(ax, ay)
      end
      local m, v = 0, 0
      for _, r in ipairs(rates) do m = m + r end
      m = m / #rates
      for _, r in ipairs(rates) do v = v + (r - m) ^ 2 end
      st.rateStd = math.sqrt(v / #rates)
    end
    out[ns.gear] = st
  end
  return out
end

-- whole key-held low-gear throttle pulsing of one trace: returns held time (s) and direction changes in 1st/2nd
local function lowGearPulse(tr)
  local dt = tr.t[2] - tr.t[1]
  local every = SAMPLE / dt
  local dur, changes = 0, 0
  local keySince, gearSince, lastGear = nil, nil, nil
  local run = {}
  local function flush()
    if #run >= 10 then
      local d, ref = 0, run[1]
      for j = 2, #run do
        local x = run[j]
        if x > ref + 0.01 then
          if d < 0 then changes = changes + 1 end
          d, ref = 1, x
        elseif x < ref - 0.01 then
          if d > 0 then changes = changes + 1 end
          d, ref = -1, x
        end
      end
      dur = dur + (#run - 1) * SAMPLE
    end
    run = {}
  end
  local k = 1
  while true do
    local i = math.floor(k * every + 0.5)
    if i > tr.n then break end
    local t, g = tr.t[i], tr.gear[i]
    if tr.key[i] then keySince = keySince or t else keySince = nil end
    if g ~= lastGear then gearSince, lastGear = t, g; flush() end
    if keySince and t - keySince >= 0.5 and (g == 1 or g == 2) and t - gearSince >= 0.3 then
      run[#run + 1] = tr.thr[i]
    else
      flush()
    end
    k = k + 1
  end
  flush()
  return dur, changes
end
M.lowGearPulse = lowGearPulse

-- tuning scenarios that start in 1st/2nd gear, dry or tapping (the logs are dry driving; wet / cold tyres pulse much
-- more and would dominate); only their 1st/2nd-gear time counts
function M.pulseScenarios()
  local names = dofile(ROOT .. '/sim/scenarios/index.lua')
  local list = {}
  for _, n in ipairs(names) do
    local scn = dofile(ROOT .. '/sim/scenarios/' .. n .. '.lua')
    if (scn.group == 'dry' or scn.group == 'tapping') and (scn.start.gear or 1) <= 2 then
      list[#list + 1] = { name = n, def = scn }
    end
  end
  return list
end

-- low-gear pulse rate of one parameter set on one car; returns rate (/s), held time, per scenario rates
function M.pulse(car, P, nSeeds, opts)
  opts = opts or {}
  local scns = opts.scenarios or M.pulseScenarios()
  local dur, ch, per = 0, 0, {}
  for _, sc in ipairs(scns) do
    local d1, c1 = 0, 0
    for seed = 1, nSeeds do
      local tr = runner.run(sc.def, { car = car, rate = 'physics', seed = hash(sc.name .. car.name .. seed),
        controller = recording(P, {}), sensor = opts.sensor, dt = opts.dt })
      local d, c = lowGearPulse(tr)
      d1, c1 = d1 + d, c1 + c
    end
    per[sc.name] = d1 > 0 and c1 / d1 or nil
    dur, ch = dur + d1, ch + c1
  end
  return dur > 0 and ch / dur or 0, dur, per
end

-- Jobs (independent, so calibrate.py can run them in parallel): the noise statistics on the Mustang with the
-- shipped set, and the pulse rate of every parameter set on both rear-drive cars.
local CARS = { 'rwd_mustang', 'rwd_supra' }
function M.jobs(mode)
  local list = {}
  if mode == 'noise' or mode == 'all' then list[#list + 1] = { kind = 'noise' } end
  if mode == 'pulse' or mode == 'all' then
    for _, c in ipairs(CARS) do
      for _, s in ipairs(M.SETS) do list[#list + 1] = { kind = 'pulse', car = c, set = s.name } end
    end
  end
  return list
end

local function setByName(name)
  for _, s in ipairs(M.SETS) do if s.name == name then return s end end
end

local function serialize(v)
  if type(v) == 'table' then
    local parts = {}
    for k, x in pairs(v) do
      parts[#parts + 1] = '[' .. (type(k) == 'number' and string.format('%.17g', k) or string.format('%q', k)) .. ']=' ..
        serialize(x)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  elseif type(v) == 'number' then
    return string.format('%.17g', v)
  end
  return string.format('%q', tostring(v))
end

-- runs one job, returns its result as Lua source (a table constructor)
function M.runJob(job, nSeeds)
  if job.kind == 'noise' then
    local car = dofile(ROOT .. '/sim/cars/rwd_mustang.lua')
    -- (cheap and noisy: 4x the seeds)
    return serialize({ kind = 'noise', stats = M.noise(car, dofile(setByName('hold').file), 4 * nSeeds) })
  end
  local car = dofile(ROOT .. '/sim/cars/' .. job.car .. '.lua')
  local rate, dur = M.pulse(car, dofile(setByName(job.set).file), nSeeds)
  return serialize({ kind = 'pulse', car = job.car, set = job.set, rate = rate, dur = dur })
end

-- formats the results (list of runJob strings), prints them and writes sim/out/calibration.txt
function M.report(results, nSeeds)
  local lines = {}
  local function say(str) lines[#lines + 1] = str; print(str) end
  local noise, pulse = nil, {}
  for _, src in ipairs(results) do
    local r = assert(loadstring('return ' .. src))()
    if r.kind == 'noise' then noise = r.stats else pulse[r.car .. '|' .. r.set] = r end
  end
  if noise then
    say(string.format('tc_sx steps at 40 Hz, steady full throttle (rwd_mustang, %s, %d seeds) vs the logs:',
      setByName('hold').label, 4 * nSeeds))
    for g = 3, 6 do
      local st, r = noise[g], M.REAL.noise[g]
      if st then
        say(string.format('  gear %d: level %.2f (log %.2f)  std %.4f (%.4f)  1.4826MAD %.4f (%.4f)  std/MAD %.2f (%.2f)' ..
          '  kurtosis %4.1f (%4.1f)  p99 %.3f (%.3f)  n %d', g, st.level, r.level, st.std, r.std, st.mad, r.mad,
          st.ratio, r.ratio, st.kurt, r.kurt, st.p99, r.p99, st.n))
        say(string.format('          step acf lag 1/3/4/8 %+.2f %+.2f %+.2f %+.2f (log %+.2f %+.2f %+.2f %+.2f)  |step| acf ' ..
          'lag 8/20 %+.2f %+.2f (log %+.2f %+.2f)  tc_slip_rate std %.2f /s', st.acf[1], st.acf[3], st.acf[4], st.acf[8],
          M.REAL.acf[1], M.REAL.acf[3], M.REAL.acf[4], M.REAL.acf[8], st.vol[8], st.vol[20], M.REAL.vol[8],
          M.REAL.vol[20], st.rateStd))
      end
    end
  end
  if next(pulse) then
    say(string.format('Low-gear (1st/2nd) throttle direction changes /s, whole key-held time, %d seeds:', nSeeds))
    for _, c in ipairs(CARS) do
      local row, rates, dur = {}, {}, 0
      for _, s in ipairs(M.SETS) do
        local r = pulse[c .. '|' .. s.name]
        if r then
          rates[s.name], dur = r.rate, r.dur
          row[#row + 1] = string.format('%s %.2f (log %.1f-%.1f)', s.name, r.rate, M.REAL.pulse[s.name][1],
            M.REAL.pulse[s.name][2])
        end
      end
      say(string.format('  %-12s %s  [%.0f s held in 1st/2nd]', c, table.concat(row, '  '), dur))
      local a, b, d = rates.s12, rates.hold, rates.r63
      if a and b and d then
        say(string.format('  %-12s order s12 < r63+hold < r63: %s; ratios hold/s12 %.2f (log 1.4-1.85), r63/s12 %.2f ' ..
          '(log 2.75)', '', (a < b and b < d) and 'OK' or 'NO', b / math.max(a, 1e-9), d / math.max(a, 1e-9)))
      end
    end
  end
  local f = io.open(ROOT .. '/sim/out/calibration.txt', 'w')
  if f then f:write(table.concat(lines, '\n') .. '\n'); f:close() end
end

local function main()
  local nSeeds = tonumber(NSEEDS) or 4
  local results = {}
  for _, job in ipairs(M.jobs(MODE or 'all')) do results[#results + 1] = M.runJob(job, nSeeds) end
  M.report(results, nSeeds)
end

if MODE ~= 'lib' then main() end
return M
