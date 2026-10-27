-- Metrics and pass/fail checks for one run (phase 4). Thresholds are the user's; change them only with a reason
-- written next to them.

local M = {}

M.THRESHOLDS = {
  peakSlip = 1.5,        -- peak driven-wheel slip <= 1.5 x target
  over13Time = 0.10,     -- s: slip above 1.3 x target at most 0.1 s in one go
  steadyDirChanges = 1,  -- per second: throttle direction changes in steady state
  steadyStd = 0.02,      -- throttle standard deviation in steady state ("variance < 2 %": std of the 0..1 throttle)
  lossDry = 0.05,        -- loss against the oracle in the dry (speed gain integral)
  rearSlideTime = 0.10,  -- s, RWD: rear axle cannot carry its lateral load (friction ellipse), proposed by Claude:
                         -- same budget as the slip overshoot (the user gave no number)
}

local SAMPLE = 0.025 -- s, 40 Hz resampling for rates (like the in-game log)

-- Longest contiguous time (s) where pred(i) holds, among samples where gate(i) holds.
local function longest(tr, dt, pred, gate)
  local best, cur = 0, 0
  for i = 1, tr.n do
    if gate(i) and pred(i) then
      cur = cur + dt
      if cur > best then best = cur end
    else
      cur = 0
    end
  end
  return best
end

-- target: the controller's slip target (ndSlip units, 1 = tyre peak)
function M.evaluate(scn, tr, oracleTr, target)
  target = target or 1
  local T = M.THRESHOLDS
  local dt = tr.t[2] - tr.t[1]
  local res = { checks = {}, values = {} }
  local val, chk = res.values, res.checks
  local nan = false
  for i = 1, tr.n do if tr.thr[i] ~= tr.thr[i] then nan = true end end
  chk.noNaN = not nan

  -- gas phases: key held, forward gear, 50 ms after the press (the press itself is the driver's)
  local held = {}
  local since = 0
  for i = 1, tr.n do
    if tr.key[i] then since = since + dt else since = 0 end
    held[i] = tr.key[i] and tr.gear[i] > 0 and since > 0.05
  end
  local gate = function (i) return held[i] end

  if scn.group ~= 'reverse' then
    local peak = 0
    for i = 1, tr.n do if held[i] and tr.nd[i] > peak then peak = tr.nd[i] end end
    val.peakSlip = peak / target
    chk.peakSlip = val.peakSlip <= T.peakSlip
    val.over13Time = longest(tr, dt, function (i) return tr.nd[i] > 1.3 * target end, gate)
    chk.over13Time = val.over13Time <= T.over13Time
    if tr.drive == 'RWD' then
      val.rearSlideTime = longest(tr, dt, function (i) return tr.slideR[i] end, gate)
      chk.rearSlideTime = val.rearSlideTime <= T.rearSlideTime
    end
  end

  -- smoothness on a 40 Hz resample: max rate and jerk of the throttle while the key is held (driver edges excluded)
  local every = math.max(1, math.floor(SAMPLE / dt + 0.5))
  local maxRate, maxJerk, prevRate = 0, 0, nil
  local edgeGuard = 0.3
  local function nearEdge(i)
    local k = math.floor(edgeGuard / dt)
    for j = math.max(1, i - k), math.min(tr.n, i + k), math.max(1, math.floor(k / 6)) do
      if tr.key[j] ~= tr.key[i] then return true end
    end
    return false
  end
  for i = 1 + every, tr.n, every do
    if held[i] and held[i - every] and not nearEdge(i) then
      local rate = (tr.thr[i] - tr.thr[i - every]) / (every * dt)
      if math.abs(rate) > maxRate then maxRate = math.abs(rate) end
      if prevRate then
        local jerk = math.abs(rate - prevRate) / (every * dt)
        if jerk > maxJerk then maxJerk = jerk end
      end
      prevRate = rate
    else
      prevRate = nil
    end
  end
  val.maxRate, val.maxJerk = maxRate, maxJerk

  -- steady state windows from the scenario
  if scn.steady then
    local worstDir, worstStd = 0, 0
    for _, w in ipairs(scn.steady) do
      local xs = {}
      for i = 1, tr.n, every do
        if tr.t[i] >= w[1] and tr.t[i] <= w[2] then xs[#xs + 1] = tr.thr[i] end
      end
      if #xs > 4 then
        local dir, changes, mean = 0, 0, 0
        for k = 1, #xs do mean = mean + xs[k] end
        mean = mean / #xs
        local var = 0
        for k = 1, #xs do var = var + (xs[k] - mean) ^ 2 end
        local std = math.sqrt(var / #xs)
        local ref = xs[1]
        for k = 2, #xs do
          local d = xs[k] - ref
          if math.abs(d) > 0.002 then
            local sgn = d > 0 and 1 or -1
            if dir ~= 0 and sgn ~= dir then changes = changes + 1 end
            dir, ref = sgn, xs[k]
          end
        end
        local perSec = changes / (w[2] - w[1])
        if perSec > worstDir then worstDir = perSec end
        if std > worstStd then worstStd = std end
      end
    end
    val.steadyDirChanges, val.steadyStd = worstDir, worstStd
    chk.steadyDirChanges = worstDir <= T.steadyDirChanges
    chk.steadyStd = worstStd < T.steadyStd
  end

  -- loss against the oracle: integral of the speed gain
  if oracleTr then
    local function gain(x)
      local g = 0
      for i = 1, x.n do g = g + (x.v[i] - x.v0) * dt end
      return g
    end
    local go, gc = gain(oracleTr), gain(tr)
    val.loss = go > 1e-6 and 1 - gc / go or 0
    if scn.group == 'dry' then chk.lossDry = val.loss <= T.lossDry end
  end

  res.pass = true
  for _, ok in pairs(chk) do if not ok then res.pass = false end end
  return res
end

return M
