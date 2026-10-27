-- Runs one scenario on one car with one controller and records a trace at the physics rate.
--
-- Timing: physics at 333 Hz. The controller is called either every physics step ("physics": Gamepad FX, the chosen
-- input method) or at render frames ("fps": 50-165 fps picked per run, +-30 % jitter per frame and occasional
-- hitches; variant A / robustness). Between calls the last throttle is held.
-- Sensor: the controller sees ndSlip / slipRatio with noise and a delay (physics steps), everything else exact.
-- The oracle ("perfect foot") is run by the same loop but reads the model directly; it is only a benchmark. It keeps
-- the driven wheels exactly at the best slip for the current lateral load, but presses no faster than the driver's key
-- ramp (opts.oracleRise / oracleFall, the controller's own RISE / FALL): the key ramp is a feel setting the user chose,
-- the loss should measure only what the traction control gives away.

local model = require('model')
local tyre = require('tyre')

local M = {}

local DT = 1 / 333

local function parseCurve(text)
  local xs, ys = {}, {}
  for x, y in tostring(text):gmatch('(-?[%d%.]+)%s*:%s*(-?[%d%.]+)') do
    xs[#xs + 1], ys[#ys + 1] = tonumber(x), tonumber(y)
  end
  if #xs == 0 then xs[1], ys[1] = 0, tonumber(text) or 0 end
  return { xs = xs, ys = ys, n = #xs }
end

local function evalCurve(c, x)
  local xs, ys, n = c.xs, c.ys, c.n
  if x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end
  for i = 2, n do
    if x <= xs[i] then return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / (xs[i] - xs[i - 1]) end
  end
  return ys[n]
end

-- Deterministic PRNG (LCG) + Gaussian (Box-Muller).
local function newRng(seed)
  local st = (seed * 7919 + 17) % 2147483648
  local r = {}
  function r.uniform()
    st = (st * 1103515245 + 12345) % 2147483648
    return (st + 0.5) / 2147483648
  end
  function r.gauss()
    local u1, u2 = r.uniform(), r.uniform()
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
  end
  return r
end
M.newRng = newRng

-- Optimal longitudinal slip (in peak units) for a lateral share u: maximises the drive force on the friction
-- ellipse (similarity method). Table at 0.01 steps, used by the oracle.
local SX_OPT = {}
do
  for i = 0, 100 do
    local u = i / 100
    local best, bestSx = -1, 0
    -- coarse scan then refine
    local lo, hi = 0, 1.5
    for _ = 1, 3 do
      local step = (hi - lo) / 30
      for k = 0, 30 do
        local sx = lo + step * k
        local sy, ok = tyre.solveLateral(sx, u)
        if ok then
          local s = math.sqrt(sx * sx + sy * sy)
          local fx = s > 1e-9 and tyre.f(s) * sx / s or 0
          if fx > best then best, bestSx = fx, sx end
        end
      end
      lo, hi = math.max(0, bestSx - step), bestSx + step
    end
    SX_OPT[i] = bestSx
  end
end
function M.sxOpt(u)
  if u <= 0 then return SX_OPT[0] end
  if u >= 1 then return 0 end
  local x = u * 100
  local i = math.floor(x)
  return SX_OPT[i] + (SX_OPT[i + 1] - SX_OPT[i]) * (x - i)
end

local function keyAt(scn, t)
  for _, iv in ipairs(scn.gas or {}) do
    if t >= iv[1] and t < iv[2] then return true end
  end
  return false
end
M.keyAt = keyAt

-- opts: { car = profile table, rate = 'physics'|'fps', seed, grip, power, controller = factory(view, car) or nil,
--         oracle = true, sensor = { noise = 0.02, noiseRel = 0.03, delay = 2 } }
function M.run(scn, opts)
  local car = model.prepare(opts.car, { grip = opts.grip, power = opts.power })
  local rng = newRng(opts.seed or 1)
  local sensor = opts.sensor or {}
  local noiseAbs = sensor.noise or 0.02
  local noiseRel = sensor.noiseRel or 0.03
  local delay = sensor.delay or 2

  local st = scn.start
  local v0 = st.kmh and st.kmh / 3.6 or model.speedForRpm(car, st.gear, st.rpm)
  local s = model.newState(car, v0, st.gear)
  local muCurve = parseCurve(scn.mu or '0:1')
  local ayCurve = parseCurve(scn.ay or '0:0')
  local env = { muScale = 1, muWheel = { [0] = 1, 1, 1, 1 }, ay = 0 }
  local driven = car.drive == 'RWD' and { 2 } or car.drive == 'FWD' and { 0 } or { 0, 2 }

  -- view of the car for the controller, same field names as CSP's car state
  local function v3() return { x = 0, y = 0, z = 0 } end
  local view = {
    gear = s.gear, rpm = s.rpm, speedKmh = v0 * 3.6, localVelocity = v3(), tractionType = car.tractionType,
    look = { x = 0, y = 0, z = 1 }, side = { x = 1, y = 0, z = 0 }, acceleration = v3(), wheels = {},
  }
  for i = 0, 3 do
    view.wheels[i] = { ndSlip = 0, slipRatio = 0, slipAngle = 0, load = 3000, angularSpeed = 0,
      tyreRadius = car.tyreRadius, look = { x = 0, y = 0, z = 1 }, velocity = v3() }
  end
  -- delay lines for the slip signals
  local lineNd, lineRatio = {}, {}
  for i = 0, 3 do
    lineNd[i], lineRatio[i] = {}, {}
    for k = 1, delay + 1 do lineNd[i][k], lineRatio[i][k] = 0, 0 end
  end
  local linePos = 1

  local function updateView()
    view.gear, view.rpm, view.speedKmh = s.gear, s.rpm, s.v * 3.6
    view.localVelocity.z = s.v
    view.acceleration.x, view.acceleration.z = env.ay, s.ax
    local readPos = linePos % (delay + 1) + 1 -- oldest entry
    for i = 0, 3 do
      local w = view.wheels[i]
      w.ndSlip = lineNd[i][readPos]
      w.slipRatio = lineRatio[i][readPos]
      w.slipAngle = s.sy[i] * car.alphaPeakDeg
      w.load = s.fz[i]
      w.angularSpeed = i < 2 and s.wf or s.wr
    end
  end

  local ctrl = opts.controller and opts.controller(view, car) or nil
  local oracle = opts.oracle
  local tmp = model.copyState(s)
  local oracleRise, oracleFall = opts.oracleRise or 1.2, opts.oracleFall or 4
  local oracleReq = 0
  -- how far the driven wheels would go past their best slip after one step at this throttle
  local function excess(thr)
    model.copyState(s, tmp)
    model.step(car, tmp, env, thr, DT)
    local e = -1e9
    for _, i0 in ipairs(driven) do
      local u = i0 == 0 and tmp.uF or tmp.uR
      local d = tmp.kappa[i0] / car.kappaPeak - M.sxOpt(u)
      if d > e then e = d end
    end
    return e
  end

  -- controller call timing
  local fps = 50 + rng.uniform() * 115
  local nextCall, lastCall = 0, 0
  local throttle, request = 0, 0
  local lastShift = -10
  local maxGear = scn.maxGear or #car.ratios
  local explicit = type(scn.shift) == 'table' and scn.shift or {}
  local autoShift = scn.shift == 'auto' or scn.shiftAuto
  local nextExplicit = 1

  local n = math.floor(scn.duration / DT + 0.5)
  local tr = { t = {}, v = {}, thr = {}, req = {}, key = {}, nd = {}, slideR = {}, slideF = {}, gear = {}, rpm = {},
    uDrive = {}, n = n, v0 = v0, fps = opts.rate == 'fps' and fps or 333, car = car.name, drive = car.drive,
    shifts = {}, kerbs = scn.kerbs or {} }
  local kerbs = scn.kerbs or {}

  for step = 1, n do
    local t = (step - 1) * DT
    -- environment
    env.muScale = evalCurve(muCurve, t)
    env.ay = evalCurve(ayCurve, t)
    for i = 0, 3 do env.muWheel[i] = 1 end
    for _, kb in ipairs(kerbs) do
      if t >= kb.t and t < kb.t + kb.len then
        for _, wi in ipairs(kb.wheels) do env.muWheel[wi] = kb.mu end
      end
    end
    -- driver: gear changes
    while explicit[nextExplicit] and t >= explicit[nextExplicit][1] do
      local what = explicit[nextExplicit][2]
      if what == 'up' then model.shiftUp(car, s) elseif what == 'neutral' then s.gear = 0 end
      tr.shifts[#tr.shifts + 1] = t
      lastShift = t
      nextExplicit = nextExplicit + 1
    end
    if autoShift and s.gear >= 1 and s.gear < maxGear and s.rpm > car.shiftRpm and t - lastShift > 0.8 then
      model.shiftUp(car, s)
      tr.shifts[#tr.shifts + 1] = t
      lastShift = t
    end
    local key = keyAt(scn, t)

    -- sensor delay line (true values in, noisy delayed values out)
    linePos = linePos % (delay + 1) + 1
    for i = 0, 3 do
      local nd = s.nd[i]
      lineNd[i][linePos] = math.max(0, nd + rng.gauss() * (noiseAbs + noiseRel * nd))
      lineRatio[i][linePos] = s.kappa[i] + rng.gauss() * (noiseAbs + noiseRel * nd) * car.kappaPeak
    end

    if oracle then
      if key then oracleReq = math.min(1, oracleReq + oracleRise * DT)
      else oracleReq = math.max(0, oracleReq - oracleFall * DT) end
      if oracleReq <= 0 or s.gear == 0 then
        throttle = 0
      elseif s.gear < 0 then
        throttle = oracleReq
      elseif excess(oracleReq) <= 0 then
        throttle = oracleReq
      elseif excess(0) > 0 then
        throttle = 0
      else
        local lo, hi = 0, oracleReq
        for _ = 1, 10 do
          local mid = (lo + hi) * 0.5
          if excess(mid) > 0 then hi = mid else lo = mid end
        end
        throttle = lo
      end
      request = oracleReq
    elseif ctrl then
      local call = opts.rate ~= 'fps' or t >= nextCall
      if call then
        local dtc = opts.rate ~= 'fps' and DT or math.max(DT, t - lastCall)
        if step == 1 then dtc = DT end
        updateView()
        throttle = ctrl.update(dtc, key, view, env.ay)
        request = ctrl.request and ctrl.request() or throttle
        if throttle ~= throttle then throttle = 0 end -- NaN guard (counted below)
        lastCall = t
        if opts.rate == 'fps' then
          local frame = (1 / fps) * (1 + (rng.uniform() - 0.5) * 0.6)
          if rng.uniform() < 0.01 then frame = frame * 3 end -- hitch
          nextCall = t + frame
        end
      end
    end
    if throttle < 0 then throttle = 0 elseif throttle > 1 then throttle = 1 end

    model.step(car, s, env, throttle, DT)

    local nd = 0
    local uD = 0
    for _, i0 in ipairs(driven) do
      if s.nd[i0] > nd then nd = s.nd[i0] end
      local u = i0 == 0 and s.uF or s.uR
      if u > uD then uD = u end
    end
    tr.t[step], tr.v[step], tr.thr[step], tr.req[step] = t + DT, s.v, throttle, request
    tr.key[step], tr.nd[step], tr.gear[step], tr.rpm[step] = key, nd, s.gear, s.rpm
    tr.slideR[step], tr.slideF[step], tr.uDrive[step] = s.slideR, s.slideF, uD
  end
  return tr
end

return M
