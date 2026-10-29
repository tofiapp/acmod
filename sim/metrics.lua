-- Metrics and pass/fail checks for one run (phase 4).
-- The user's thresholds are marked USER; the ones Claude had to add are marked PROPOSAL (shown to the user, change
-- only with a reason written here).

local M = {}

M.THRESHOLDS = {
  peakSlip = 1.5,        -- USER: peak driven-wheel slip <= 1.5 x target (target = tyre peak, ndSlip 1)
  over13Time = 0.10,     -- USER: slip above 1.3 x target at most 0.1 s in one go
  steadyDirChanges = 1,  -- USER: throttle direction changes per second in steady state
  steadyStd = 0.02,      -- USER: "variance < 2 %": std of the 0..1 throttle around its 0.5 s moving average in steady
                         -- state (a ramp or a plateau is not variance, wobble is)
  lossDry = 0.05,        -- USER: loss against the oracle in the dry
  lossOther = 0.15,      -- PROPOSAL: loss bound in wet / cold / grip-change / tapping (else a timid controller
                         -- would pass them for free)
  slideTime = 0.10,      -- PROPOSAL: an axle cannot carry its lateral load (friction ellipse) at most 0.1 s in one
                         -- go, every drive type (USER asked for RWD ellipse safety, no number given)
  maxRate = 5,           -- PROPOSAL: throttle changes made by the assist at most 5 /s (the user wants smooth, never a
                         -- step); the driver's own key edges are excluded
  recoveryTime = 0.5,    -- PROPOSAL: after a disturbance ends (scn.recovery.after) the throttle is back at the request
                         -- (or the tyres are really near their peak again) at most 0.5 s later than the driver's own
                         -- key ramp would bring it back (user report v0.10: after a
                         -- kerb the car refused to accelerate on straight asphalt)
  reverseFollow = 0.01,  -- PROPOSAL: in reverse/neutral the throttle is the plain key ramp (no regulation)
  pulse = 1,             -- USER (the steady-state number, applied to the WHOLE key-held time): throttle direction
                         -- changes per second while the gas key is held in a forward gear, 40 Hz, 1 % deadband, from
                         -- 0.5 s after the key press and 0.3 s after a gear change; graded on the whole run and on
                         -- gears 1-2 alone (v0.11.0 user: "the jerking came back": real 1st/2nd gear 4.4 /s, overall
                         -- 1.7-2.7 /s, while the settled-window check above saw almost nothing)
}

-- Whole key-held pulse measure (shared with sim/replay.lua for the real logs, so the sim and the logs are counted
-- the same way; the same definition as the measurements of the user's logs in the v0.11 history).
M.PULSE = {
  DEADBAND = 0.01,  -- a direction change needs a move of at least 1 % from the last reference
  SKIP_KEY = 0.5,   -- s after the key press (the driver's own ramp)
  SKIP_GEAR = 0.3,  -- s after a gear change (cut + upshift kick)
  BIG = 0.05,       -- amplitude: a reversal whose swing (turning point to turning point) is >= 5 % is a big one
  MIN_RUN = 8,      -- samples (0.2 s at 40 Hz): shorter stretches are not counted
  GAP = 0.1,        -- s: a time gap between samples larger than this splits the stream (paused game, missing rows)
  SKIP_DIST = 0.5,  -- s after a scenario kerb or grip step (sim only)
}

local function newPulseAcc()
  return { held = 0, changes = 0, big = 0, travel = 0, heldLow = 0, changesLow = 0, bigLow = 0, travelLow = 0 }
end
M.newPulseAcc = newPulseAcc

-- One contiguous run of samples xs[1..n] (one gear, key held): direction changes (meas.py definition: reference
-- moves with every step beyond the deadband), big reversals (zig-zag with the deadband, swing >= BIG) and travel.
local function pulseRun(xs, n)
  local P = M.PULSE
  local db = P.DEADBAND
  local changes, dir, ref = 0, 0, xs[1]
  local big, zdir, ext, piv = 0, 0, xs[1], xs[1]
  local travel = 0
  for k = 2, n do
    local x = xs[k]
    travel = travel + math.abs(x - xs[k - 1])
    if x > ref + db then
      if dir < 0 then changes = changes + 1 end
      dir, ref = 1, x
    elseif x < ref - db then
      if dir > 0 then changes = changes + 1 end
      dir, ref = -1, x
    end
    if zdir == 0 then
      if x > piv + db then zdir, ext = 1, x elseif x < piv - db then zdir, ext = -1, x end
    elseif zdir > 0 then
      if x > ext then ext = x
      elseif x < ext - db then
        if ext - piv >= P.BIG then big = big + 1 end
        zdir, piv, ext = -1, ext, x
      end
    else
      if x < ext then ext = x
      elseif x > ext + db then
        if piv - ext >= P.BIG then big = big + 1 end
        zdir, piv, ext = 1, ext, x
      end
    end
  end
  return changes, big, travel
end

-- Pulse statistics over a 40 Hz stream: t[i] (s), thr[i] (0..1 output), key[i] (gas key held and the assist active),
-- gear[i]; accumulates into acc (see newPulseAcc) and returns it. Only forward gears count; a gap splits the stream.
-- skip: optional list of { t0, t1 } windows left out (sim disturbances where the throttle MUST move: a kerb, a grip
-- step; the perfect foot itself changes direction twice there).
function M.pulseStats(t, thr, key, gear, n, acc, skip)
  local P = M.PULSE
  acc = acc or newPulseAcc()
  local xs, nx, t0, t1, runGear = {}, 0, 0, 0, 0
  local function flush()
    if nx >= P.MIN_RUN then
      local c, b, tv = pulseRun(xs, nx)
      local dur = t1 - t0
      acc.held, acc.changes, acc.big, acc.travel = acc.held + dur, acc.changes + c, acc.big + b, acc.travel + tv
      if runGear <= 2 then
        acc.heldLow, acc.changesLow = acc.heldLow + dur, acc.changesLow + c
        acc.bigLow, acc.travelLow = acc.bigLow + b, acc.travelLow + tv
      end
    end
    nx = 0
  end
  local keyT, gearT, lastGear
  for i = 1, n do
    local ti = t[i]
    if i > 1 and (ti - t[i - 1] > P.GAP or ti <= t[i - 1]) then flush(); keyT, lastGear = nil, nil end
    if not key[i] then
      flush(); keyT, lastGear = nil, nil
    else
      if not keyT then keyT = ti end
      local g = gear[i]
      if g ~= lastGear then flush(); gearT, lastGear = ti, g end
      local skipped = false
      if skip then
        for _, w in ipairs(skip) do if ti >= w[1] and ti <= w[2] then skipped = true; break end end
      end
      if g > 0 and ti - keyT >= P.SKIP_KEY and ti - gearT >= P.SKIP_GEAR and not skipped then
        nx = nx + 1
        xs[nx] = thr[i]
        if nx == 1 then t0, runGear = ti, g end
        t1 = ti
      else
        flush()
      end
    end
  end
  flush()
  return acc
end

-- Rates per second from an accumulator: all, gears 1-2, big reversals, travel.
function M.pulseRates(acc)
  local function r(a, b) return b > 0 and a / b or nil end
  return {
    rate = r(acc.changes, acc.held), rateLow = r(acc.changesLow, acc.heldLow),
    big = r(acc.big, acc.held), bigLow = r(acc.bigLow, acc.heldLow),
    travel = r(acc.travel, acc.held), travelLow = r(acc.travelLow, acc.heldLow),
    held = acc.held, heldLow = acc.heldLow,
  }
end

local TARGET = 1          -- grading reference: the tyre peak, independent of the controller's TARGET_SLIP
local SAMPLE = 0.025      -- s, 40 Hz resampling for the steady-state statistics (like the in-game log)
local RATE_WINDOW = 0.1   -- s, throttle rate and jerk are measured over 100 ms (at 50 fps with hitches the throttle
                          -- moves in frame-sized steps; what the driver feels is the change over ~0.1 s)
local DEADBAND = 0.005    -- a throttle direction change must be at least 0.5 % to count
local SETTLE = 1.0        -- s after a disturbance (key edge, shift, kerb, grip change) before "steady state"
M.PULSE_MIN_HELD = 1.0  -- s of measured key-held time before the pulse rate is graded
local MIN_GAIN = 0.5      -- m: loss is n/a when the oracle covers less than this more than a car with no throttle

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

-- Raw values shared by controller and oracle traces.
local function raw(tr, dt)
  local held = {}
  local since = 0
  for i = 1, tr.n do
    if tr.key[i] then since = since + dt else since = 0 end
    held[i] = tr.key[i] and tr.gear[i] > 0 and since > 0.05
  end
  local gate = function (i) return held[i] end
  local peak = 0
  for i = 1, tr.n do if held[i] and tr.nd[i] > peak then peak = tr.nd[i] end end
  return {
    held = held,
    peakSlip = peak / TARGET,
    over13Time = longest(tr, dt, function (i) return tr.nd[i] > 1.3 * TARGET end, gate),
    slideTime = longest(tr, dt, function (i) return tr.slideR[i] or tr.slideF[i] end, gate),
  }
end

local function distance(tr, dt)
  local d = 0
  for i = 1, tr.n do d = d + math.abs(tr.v[i]) * dt end
  return d
end

-- Disturbance times: key edges, shifts, kerbs, grip changes (from the scenario).
local function disturbances(scn, tr)
  local t = { 0 }
  for i = 2, tr.n do if tr.key[i] ~= tr.key[i - 1] or tr.gear[i] ~= tr.gear[i - 1] then t[#t + 1] = tr.t[i] end end
  for _, s in ipairs(tr.shifts or {}) do t[#t + 1] = s end
  for _, k in ipairs(scn.kerbs or {}) do t[#t + 1] = k.t; t[#t + 1] = k.t + k.len end
  if scn.mu then
    local prev
    for x, y in tostring(scn.mu):gmatch('(-?[%d%.]+)%s*:%s*(-?[%d%.]+)') do
      if prev and math.abs(tonumber(y) - prev) > 0.05 then t[#t + 1] = tonumber(x) end
      prev = tonumber(y)
    end
  end
  table.sort(t)
  return t
end

-- Direction changes per second and std of the throttle around its own 0.5 s moving average over [t0, t1]
-- (a slow trend, e.g. the key ramp reaching full throttle, is not variance; wobble faster than ~1 Hz is).
local MA_WINDOW = 0.5
local function windowStats(tr, every, t0, t1)
  local xs = {}
  for i = 1, tr.n, every do
    if tr.t[i] >= t0 and tr.t[i] <= t1 then xs[#xs + 1] = tr.thr[i] end
  end
  local n = #xs
  if n < 8 then return nil end
  local dt = (tr.t[2] - tr.t[1]) * every
  local half = math.max(1, math.floor(MA_WINDOW / dt / 2 + 0.5))
  local var, cnt = 0, 0
  for k = 1 + half, n - half do
    local m = 0
    for j = k - half, k + half do m = m + xs[j] end
    m = m / (2 * half + 1)
    var = var + (xs[k] - m) ^ 2
    cnt = cnt + 1
  end
  local changes, dir, ref = 0, 0, xs[1]
  for k = 2, n do
    local d = xs[k] - ref
    if math.abs(d) > DEADBAND then
      local sgn = d > 0 and 1 or -1
      if dir ~= 0 and sgn ~= dir then changes = changes + 1 end
      dir, ref = sgn, xs[k]
    end
  end
  return changes / (t1 - t0), cnt > 0 and math.sqrt(var / cnt) or 0
end

-- Whole key-held pulse of a trace (40 Hz like the in-game log; kerbs and grip steps of the scenario left out): rates
-- (pulseRates) and the accumulator (pulseStats). Also used by sim/calibrate.lua.
local function pulseOf(scn, tr)
  local dt = tr.t[2] - tr.t[1]
  local every = math.max(1, math.floor(SAMPLE / dt + 0.5))
  local pt, px, pk, pg, pn = {}, {}, {}, {}, 0
  for i = 1, tr.n, every do
    pn = pn + 1
    pt[pn], px[pn], pk[pn], pg[pn] = tr.t[i], tr.thr[i], tr.key[i], tr.gear[i]
  end
  local skip = {}
  for _, k in ipairs(scn.kerbs or {}) do skip[#skip + 1] = { k.t, k.t + k.len + M.PULSE.SKIP_DIST } end
  if scn.mu then
    local prev
    for x, y in tostring(scn.mu):gmatch('(-?[%d%.]+)%s*:%s*(-?[%d%.]+)') do
      if prev and math.abs(tonumber(y) - prev[2]) > 0.05 and tonumber(x) - prev[1] <= 0.5 then -- a step, not a slow drift
        skip[#skip + 1] = { prev[1], tonumber(x) + M.PULSE.SKIP_DIST }
      end
      prev = { tonumber(x), tonumber(y) }
    end
  end
  local acc = M.pulseStats(pt, px, pk, pg, pn, nil, skip)
  return M.pulseRates(acc), acc
end
M.pulseOf = pulseOf

-- Summary of a reference trace (oracle or zero throttle) that evaluate() needs; lets the optimizer cache them.
-- scn (optional): adds the whole key-held pulse (pulse, pulseLow: nil when held < PULSE_MIN_HELD; pulseHeld,
-- pulseHeldLow), so the pulse can be graded against what the perfect foot itself does in the same run.
function M.summarize(tr, scn)
  local dt = tr.t[2] - tr.t[1]
  local r = raw(tr, dt)
  local s = { peakSlip = r.peakSlip, over13Time = r.over13Time, slideTime = r.slideTime, dist = distance(tr, dt) }
  if scn then
    local pr = pulseOf(scn, tr)
    s.pulseHeld, s.pulseHeldLow = pr.held, pr.heldLow
    if pr.held >= M.PULSE_MIN_HELD then s.pulse = pr.rate end
    if pr.heldLow >= M.PULSE_MIN_HELD then s.pulseLow = pr.rateLow end
  end
  return s
end

-- ref: { oracle = trace or summary, zero = trace or summary (throttle 0), rise, fall (the controller's key ramp) }
function M.evaluate(scn, tr, ref)
  local T = M.THRESHOLDS
  local dt = tr.t[2] - tr.t[1]
  local res = { checks = {}, values = {}, na = {} }
  local val, chk, na = res.values, res.checks, res.na
  chk.noNaN = (tr.nanCount or 0) == 0
  local every = math.max(1, math.floor(SAMPLE / dt + 0.5))

  if scn.group == 'reverse' then
    -- no regulation: the throttle must be the plain key ramp
    -- (at render-frame rate the controller holds its value between calls: compare with the ramp at the last call)
    local r, worst, held = 0, 0, 0
    local rise, fall = ref.rise or 1.2, ref.fall or 4
    for i = 1, tr.n do
      if tr.key[i] then r = math.min(1, r + rise * dt) else r = math.max(0, r - fall * dt) end
      if tr.called[i] then held = r end
      if tr.gear[i] <= 0 then
        local d = math.abs(tr.thr[i] - held)
        if d > worst then worst = d end
      end
    end
    -- at render-frame rate a key edge is seen up to one frame late: allow the ramp of the longest frame gap
    local gap, last = 0, 0
    for i = 1, tr.n do
      if tr.called[i] then
        if tr.t[i] - last > gap then gap = tr.t[i] - last end
        last = tr.t[i]
      end
    end
    val.reverseFollow = worst
    chk.reverseFollow = worst <= T.reverseFollow + math.max(rise, fall) * gap
  else
    local c = raw(tr, dt)
    local o = ref.oracle and (ref.oracle.dist and ref.oracle or M.summarize(ref.oracle, scn)) or nil
    local z = ref.zero and (ref.zero.dist and ref.zero or M.summarize(ref.zero)) or nil
    val.peakSlip, val.over13Time, val.slideTime = c.peakSlip, c.over13Time, c.slideTime
    if o then val.oraclePeakSlip, val.oracleOver13Time, val.oracleSlideTime = o.peakSlip, o.over13Time, o.slideTime end
    -- a check the oracle itself cannot meet is not graded (scenario infeasible for this car)
    local function graded(name, value, bound, oracleValue)
      if oracleValue and oracleValue > bound then na[#na + 1] = name; return end
      chk[name] = value <= bound
    end
    graded('peakSlip', c.peakSlip, T.peakSlip, o and o.peakSlip)
    graded('over13Time', c.over13Time, T.over13Time, o and o.over13Time)
    graded('slideTime', c.slideTime, T.slideTime, o and o.slideTime)

    -- recovery after a disturbance: time until the throttle is back at the request or the slip is near the peak
    if scn.recovery then
      -- measured from the moment the spin of the disturbance is over (slip back under 0.8 of the peak) as the delay
      -- beyond what the driver's own key ramp (RISE) needs from the throttle at that moment
      local t0 = scn.recovery.after
      local i0 = nil
      for i = 1, tr.n do
        if tr.t[i] >= t0 and tr.nd[i] < 0.8 * TARGET then i0 = i; break end
      end
      local rec, thr0
      if i0 then
        thr0 = tr.thr[i0]
        for i = i0, tr.n do
          if tr.key[i] and (tr.thr[i] >= tr.req[i] - 0.05 or tr.nd[i] >= 0.8 * TARGET) then
            rec = tr.t[i] - tr.t[i0]
            break
          end
        end
      end
      local rampTime = thr0 and math.max(0, (1 - 0.05 - thr0) / (ref.rise or 1.2)) or 0
      local span = i0 and (tr.t[tr.n] - tr.t[i0]) or 0
      val.recoveryTime = math.max(0, (rec or span) - rampTime)
      chk.recoveryTime = val.recoveryTime <= T.recoveryTime
    end

    -- loss: distance covered, normalised by what the oracle gains over a car with no throttle at all
    if o and z then
      local go, gc, gz = o.dist, distance(tr, dt), z.dist
      val.lossBase = go - gz
      if go - gz >= MIN_GAIN then
        val.loss = (go - gc) / (go - gz)
        local bound = scn.group == 'dry' and T.lossDry or T.lossOther
        val.lossBound = bound
        chk.loss = val.loss <= bound
      else
        na[#na + 1] = 'loss'
      end
    end

    -- smoothness: rate of the throttle while the key is held, away from the driver's key edges
    local maxRate, maxJerk, prevRate = 0, 0, nil
    local guard = math.floor(0.3 / dt)
    local lastEdge = -1e9
    local edgeAt = {}
    for i = 2, tr.n do if tr.key[i] ~= tr.key[i - 1] then edgeAt[#edgeAt + 1] = i end end
    local function nearEdge(i)
      for _, e in ipairs(edgeAt) do if math.abs(e - i) <= guard then return true end end
      return false
    end
    local rw = math.max(1, math.floor(RATE_WINDOW / dt + 0.5))
    for i = 1 + rw, tr.n, rw do
      if c.held[i] and c.held[i - rw] and not nearEdge(i) then
        local rate = (tr.thr[i] - tr.thr[i - rw]) / (rw * dt)
        if math.abs(rate) > maxRate then maxRate = math.abs(rate) end
        if prevRate then
          local jerk = math.abs(rate - prevRate) / (rw * dt)
          if jerk > maxJerk then maxJerk = jerk end
        end
        prevRate = rate
      else
        prevRate = nil
      end
    end
    val.maxRate, val.maxJerk = maxRate, maxJerk
    chk.maxRate = maxRate <= T.maxRate

    -- steady state: every stretch with the key held in one forward gear, at least SETTLE after a disturbance and
    -- at least 1 s long; plus the scenario's own windows
    local dist = disturbances(scn, tr)
    local windows = {}
    local startT
    local function close(tEnd)
      if startT and tEnd - startT >= 1 then windows[#windows + 1] = { startT, tEnd } end
      startT = nil
    end
    local di = 1
    for i = 1, tr.n do
      local t = tr.t[i]
      while dist[di + 1] and dist[di + 1] <= t do di = di + 1 end
      local quiet = t - (dist[di] or 0) >= SETTLE
      if c.held[i] and quiet then
        if not startT then startT = t end
      else
        close(t)
      end
    end
    close(tr.t[tr.n])
    for _, w in ipairs(scn.steady or {}) do windows[#windows + 1] = w end
    local worstDir, worstStd = 0, 0
    for _, w in ipairs(windows) do
      local d, sd = windowStats(tr, every, w[1], w[2])
      if d then
        if d > worstDir then worstDir = d end
        if sd > worstStd then worstStd = sd end
      end
    end
    val.steadyWindows = #windows
    if #windows > 0 then
      val.steadyDirChanges, val.steadyStd = worstDir, worstStd
      chk.steadyDirChanges = worstDir <= T.steadyDirChanges
      chk.steadyStd = worstStd < T.steadyStd
    end

    -- pulse over the whole key-held forward-gear time (40 Hz like the in-game log)
    local pr = pulseOf(scn, tr)
    val.pulseHeld, val.pulseHeldLow = pr.held, pr.heldLow
    if o then val.oraclePulse, val.oraclePulseLow = o.pulse, o.pulseLow end
    if pr.held >= M.PULSE_MIN_HELD then
      val.pulse, val.pulseBig, val.pulseTravel = pr.rate, pr.big, pr.travel
      local worst = pr.rate
      if pr.heldLow >= M.PULSE_MIN_HELD then
        val.pulseLow, val.pulseBigLow, val.pulseTravelLow = pr.rateLow, pr.bigLow, pr.travelLow
        if pr.rateLow > worst then worst = pr.rateLow end
      end
      -- like every other check: not graded where the perfect foot itself cannot meet the bound (it has to move the
      -- throttle there: a slip limit that changes with the revs, a long slide)
      local oWorst = o and math.max(o.pulse or 0, o.pulseLow or 0) or nil
      graded('pulse', worst, T.pulse, oWorst)
    end
  end

  res.pass = true
  for _, ok in pairs(chk) do if not ok then res.pass = false end end
  return res
end

return M
