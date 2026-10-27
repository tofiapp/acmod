-- Longitudinal car model for testing the KeyDrive throttle core (phase 3).
--
-- What is modelled:
--   - body: mass, rolling resistance, aero drag and downforce, longitudinal and lateral weight transfer;
--   - lateral load: not simulated as yaw dynamics, the scenario prescribes the lateral acceleration ay(t); each axle
--     must deliver its share of m * ay, which uses up part of the friction ellipse (combined slip, tyre.lua);
--     an axle that cannot deliver it is "sliding" (for the RWD rear: the start of a spin);
--   - tyres: normalised Pacejka, peak at kappaPeak slip ratio, grip mu per wheel (scenario multipliers: wet, cold,
--     kerbs, grass);
--   - drivetrain: engine torque curve x throttle (engine braking when off), rev limiter, gear ratios, auto-clutch at
--     launch (engine held at the launch rpm while the clutch slips), sequential upshift with an ignition cut and the
--     engine's speed mismatch released into the wheels after the shift (the slip spike seen in real logs);
--     every wheel has its own speed; per axle a locked differential (both wheels at one speed, the inside wheel
--     spins first in corners: the user's Supra logs) or an open one (equal torque, each wheel free); AWD = open
--     centre with a fixed torque split;
--   - wheel and engine inertia (engine inertia reflected through the gear ratio once the clutch is locked).
-- Integration: fixed physics step (333 Hz like AC) split into substeps (the wheel slip equation is stiff at low speed).
-- Not modelled yet (extensible): yaw/steering dynamics, brakes, limited-slip differentials, tyre temperature.

local tyre = require('tyre')

local M = {}

local G = 9.81
local RHO = 1.2
local VMIN = 2          -- m/s, slip ratio denominator floor (stiffness at standstill)
local SUBSTEPS = 12
local TAU_SYNC = 0.03   -- s, engine speed mismatch after a shift released over this time

local function parseCurve(text)
  local xs, ys = {}, {}
  for x, y in text:gmatch('(-?[%d%.]+)%s*:%s*(-?[%d%.]+)') do xs[#xs + 1], ys[#ys + 1] = tonumber(x), tonumber(y) end
  return { xs = xs, ys = ys, n = #xs }
end

local function evalCurve(c, x)
  local xs, ys, n = c.xs, c.ys, c.n
  if x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end
  for i = 2, n do
    if x <= xs[i] then
      return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / (xs[i] - xs[i - 1])
    end
  end
  return ys[n]
end

-- Prepares a car profile (sim/cars/*.lua) with optional scaling: { grip = 1, power = 1 }.
function M.prepare(profile, scale)
  local c = {}
  for k, v in pairs(profile) do c[k] = v end
  scale = scale or {}
  c.mu = profile.mu * (scale.grip or 1)                         -- longitudinal peak friction
  c.muLat = (profile.muLat or profile.mu) * (scale.grip or 1)   -- lateral peak friction
  c.torqueCurve = parseCurve(profile.torque)
  c.clutchCurve = profile.clutchSlipRpm and parseCurve(profile.clutchSlipRpm) or nil
  tyre.setTail(profile.tyreTail or 1)
  c.torqueScale = scale.power or 1
  -- overall ratio (engine rad/s per wheel rad/s) from rpm per km/h: omega_e / omega_w = rpmPerKmh * 0.377 * r
  c.ratios = {}
  for i, rpk in ipairs(profile.rpmPerKmh) do c.ratios[i] = rpk * 0.377 * profile.tyreRadius end
  c.reverseRatio = -(profile.reverseRpmPerKmh or profile.rpmPerKmh[1]) * 0.377 * profile.tyreRadius
  c.driveFront = profile.drive == 'FWD' and 1 or profile.drive == 'AWD' and (profile.frontShare or 0.4) or 0
  c.driveRear = 1 - c.driveFront
  c.tractionType = profile.drive == 'RWD' and 0 or profile.drive == 'FWD' and 1 or 2
  c.lockedF = profile.diffFront == 'locked'
  c.lockedR = (profile.diffRear or 'locked') == 'locked'
  return c
end

local function ratioOf(car, gear)
  if gear > 0 then return car.ratios[gear] end
  if gear < 0 then return car.reverseRatio end
  return 0
end

function M.speedForRpm(car, gear, rpm)
  return rpm / car.rpmPerKmh[gear] / 3.6
end

-- New state at speed v (m/s), in `gear`, wheels rolling freely.
function M.newState(car, v, gear)
  local r = car.tyreRadius
  local s = {
    t = 0, x = 0, v = v, ax = 0,
    w = { [0] = v / r, v / r, v / r, v / r }, -- wheel angular speeds
    wf = v / r, wr = v / r,       -- axle mean angular speeds
    we = 0,                       -- engine angular speed
    gear = gear or 1,
    cut = 0,                      -- remaining ignition cut of a shift, s
    sync = 0,                     -- engine speed mismatch after a shift, rad/s (engine side)
    locked = true,                -- clutch locked
    -- outputs of the last step (per wheel 0 FL, 1 FR, 2 RL, 3 RR)
    fz = { [0] = 0, 0, 0, 0 }, kappa = { [0] = 0, 0, 0, 0 }, nd = { [0] = 0, 0, 0, 0 },
    sy = { [0] = 0, 0, 0, 0 }, fx = { [0] = 0, 0, 0, 0 }, slideF = false, slideR = false, uF = 0, uR = 0, fxTotal = 0,
    rpm = 0, driveTorque = 0, limiter = false,
  }
  local ratio = ratioOf(car, s.gear)
  local ws = ratio * (car.driveFront > 0 and s.wf or s.wr)
  s.we = math.max(car.idleRpm * math.pi / 30, ws)
  s.locked = ws >= car.idleRpm * math.pi / 30
  s.rpm = s.we * 30 / math.pi
  return s
end

function M.copyState(src, dst)
  dst = dst or { fz = {}, kappa = {}, nd = {}, sy = {}, w = {}, fx = {} }
  for k, v in pairs(src) do
    if type(v) ~= 'table' then dst[k] = v end
  end
  for i = 0, 3 do
    dst.fz[i], dst.kappa[i], dst.nd[i], dst.sy[i] = src.fz[i], src.kappa[i], src.nd[i], src.sy[i]
    dst.w[i], dst.fx[i] = src.w[i], src.fx[i]
  end
  return dst
end

-- Sequential upshift: ignition cut for shiftTime; the engine keeps its speed, so the new (lower) engine-side speed
-- leaves a mismatch. Part of it is lost during the cut, the rest (shiftKeep) is released into the wheels afterwards.
function M.shiftUp(car, s)
  if s.gear >= 1 and s.gear < #car.ratios and s.cut <= 0 then
    s.gear = s.gear + 1
    s.cut = car.shiftTime
    local ws = (car.driveFront * s.wf + car.driveRear * s.wr) * car.ratios[s.gear]
    if s.locked then s.sync = s.we - (ws < 0 and -ws or ws) end
  end
end

function M.setGear(car, s, gear)
  s.gear = gear
end

local function rr(w, val)
  if w > 0.1 then return -val elseif w < -0.1 then return val end
  return -w / 0.1 * val
end

local function engineTorque(car, rpm, throttle)
  local tmax = evalCurve(car.torqueCurve, rpm) * car.torqueScale
  local tbrake = -(car.engineBrake or 40) * math.min(1, rpm / 6000)
  if rpm < car.idleRpm * 0.95 then tbrake = 0 end
  return tbrake + (tmax - tbrake) * throttle
end
M.engineTorque = engineTorque

-- Integrates one axle's wheel speeds. Locked: one speed, torque minus both tyre forces. Open: equal torque to each
-- wheel, each with its own tyre force (the engine's reflected inertia split between them, a diagonal approximation).
-- Rolling resistance acts as a wheel torque (keeps standstill stable).
local function integrateAxle(car, s, i0, locked, torque, jEngine, jWheel, h)
  local r = car.tyreRadius
  local w = s.w
  if locked then
    local wa = (w[i0] + w[i0 + 1]) * 0.5
    local rra = car.crr * (s.fz[i0] + s.fz[i0 + 1]) * r
    wa = wa + (torque - (s.fx[i0] + s.fx[i0 + 1]) * r + rr(wa, rra)) / (2 * jWheel + jEngine) * h
    w[i0], w[i0 + 1] = wa, wa
  else
    for i = i0, i0 + 1 do
      w[i] = w[i] + (torque * 0.5 - s.fx[i] * r + rr(w[i], car.crr * s.fz[i] * r)) / (jWheel + jEngine * 0.5) * h
    end
  end
end

-- One wheel: slip ratio from the wheel speed w and the wheel's own ground speed vi, lateral share u.
-- Returns Fx and whether the lateral share could be carried. When it cannot (the axle slides), the lateral demand
-- gets priority: the longitudinal force is what is left of the total force f(s) (a sliding car turns its tyre forces
-- sideways; without this, spinning the wheels in a corner would cost nothing).
local function wheelForce(car, s, i, w, vi, fz, mu, u)
  local kappa = (w * car.tyreRadius - vi) / math.max(math.abs(vi), VMIN)
  local sx = kappa / car.kappaPeak
  local sxa = sx < 0 and -sx or sx
  local sy, ok = 0, true
  if u > 0 then sy, ok = tyre.solveLateral(sxa, u) end
  local sAbs = math.sqrt(sxa * sxa + sy * sy)
  local f = sAbs > 1e-9 and tyre.f(sAbs) or 0
  local share
  if ok then
    share = sAbs > 1e-9 and f * sxa / sAbs or 0
  else
    local rest = f * f - u * u
    share = rest > 0 and math.sqrt(rest) or 0
  end
  if sx < 0 then share = -share end
  s.kappa[i], s.nd[i], s.sy[i] = kappa, sAbs, sy
  return mu * fz * share, ok
end

-- One axle. In a corner the inside wheel travels a shorter path (yaw rate ay / v): with a locked axle it slips more
-- and spins first, as in the user's logs (rear max/min ndSlip ~1.2-1.3 in corners). Forces go to s.fx[i].
local function axleForces(car, s, env, i0, v, fzL, fzR, ay, axleShare)
  local kL, kR = env.muScale * env.muWheel[i0], env.muScale * env.muWheel[i0 + 1]
  -- lateral share this axle must carry, split by load x grip (lateral friction may be higher than longitudinal,
  -- as in AC's tyres)
  local fyNeed = car.mass * math.abs(ay) * G * axleShare
  local cap = car.muLat * (kL * fzL + kR * fzR)
  local u = cap > 1 and fyNeed / cap or 0
  local yaw = ay * G / math.max(math.abs(v), 3)       -- ay > 0: left turn, left wheels inside
  local dv = yaw * car.track * 0.5
  local fxL, okL = wheelForce(car, s, i0, s.w[i0], v - dv, fzL, car.mu * kL, u)
  local fxR, okR = wheelForce(car, s, i0 + 1, s.w[i0 + 1], v + dv, fzR, car.mu * kR, u)
  s.fx[i0], s.fx[i0 + 1] = fxL, fxR
  return fxL + fxR, okL and okR, u
end

-- Advances the car by dt. `throttle` 0..1 (what the controller sent); env: { muScale, muWheel[0..3], ay (g) }.
function M.step(car, s, env, throttle, dt)
  local h = dt / SUBSTEPS
  local r = car.tyreRadius
  local m = car.mass
  local L = car.wheelbase
  local idleW = car.idleRpm * math.pi / 30
  local limitW = car.revLimit * math.pi / 30
  local ratio = ratioOf(car, s.gear)
  local Jw = car.wheelInertia          -- per wheel
  local Je = car.engineInertia
  local ay = env.ay or 0
  for _ = 1, SUBSTEPS do
    local v = s.v
    -- loads: static + aero + longitudinal transfer (last acceleration) + lateral transfer
    local down = 0.5 * RHO * car.cla * v * v
    local fzF = m * G * car.frontWeight + down * car.aeroFront - m * s.ax * G * car.cgHeight / L
    local fzR = m * G * (1 - car.frontWeight) + down * (1 - car.aeroFront) + m * s.ax * G * car.cgHeight / L
    if fzF < 100 then fzF = 100 end
    if fzR < 100 then fzR = 100 end
    local latT = m * math.abs(ay) * G * car.cgHeight / car.track
    local dF, dR = latT * car.frontWeight, latT * (1 - car.frontWeight)
    local sg = ay >= 0 and 1 or -1 -- ay > 0: the left wheels are on the inside (each loses dF, the outside gains dF)
    local fzFL, fzFR = fzF * 0.5 - dF * sg, fzF * 0.5 + dF * sg
    local fzRL, fzRR = fzR * 0.5 - dR * sg, fzR * 0.5 + dR * sg
    if fzFL < 50 then fzFL = 50 end
    if fzFR < 50 then fzFR = 50 end
    if fzRL < 50 then fzRL = 50 end
    if fzRR < 50 then fzRR = 50 end
    s.fz[0], s.fz[1], s.fz[2], s.fz[3] = fzFL, fzFR, fzRL, fzRR

    local fxF, okF, uF = axleForces(car, s, env, 0, v, fzFL, fzFR, ay, car.frontWeight)
    local fxR, okR, uR = axleForces(car, s, env, 2, v, fzRL, fzRR, ay, 1 - car.frontWeight)
    s.slideF, s.slideR, s.uF, s.uR = not okF, not okR, uF, uR

    -- drivetrain
    local wsF, wsR = s.wf * ratio, s.wr * ratio -- engine-side speeds of each axle
    local ws = car.driveFront * wsF + car.driveRear * wsR
    local thr = throttle
    if s.cut > 0 then thr = 0 end
    local tEng, tClutch
    local engineJ = 0
    if s.gear == 0 then
      -- neutral: engine free
      tEng = engineTorque(car, s.we * 30 / math.pi, thr)
      s.we = math.max(idleW, s.we + tEng / Je * h)
      if s.we > limitW then s.we = limitW end
      tClutch = 0
      s.locked = false
    else
      local wsAbs = ws < 0 and -ws or ws
      -- auto-clutch (like AC's, fitted to the user's logs): while the wheels turn the engine slower than the
      -- clutch-slip speed for this throttle, the clutch slips and the engine revs towards that speed (with its own
      -- inertia, no jumps); it locks once the wheels reach it and opens again only near a stall. In the logs the
      -- Supra's clutch slips in 1st gear up to 50-60 km/h at 4000-5600 rpm.
      local target = (car.clutchCurve and evalCurve(car.clutchCurve, thr) or
        (car.idleRpm + (car.launchRpm - car.idleRpm) * thr)) * math.pi / 30
      if s.locked and s.cut <= 0 and s.sync == 0 and wsAbs < idleW * 1.1 then s.locked = false end
      if not s.locked then
        if wsAbs >= target or wsAbs >= s.we then
          s.locked = true
          s.we = wsAbs
        else
          s.we = s.we + (target - s.we) * math.min(1, h / 0.12)
          if s.we < idleW then s.we = idleW end
          tEng = engineTorque(car, s.we * 30 / math.pi, thr)
          tClutch = tEng > 0 and tEng * (car.slipClutchScale or 1) or 0
        end
      end
      if s.locked then
        if s.we > limitW * 1.001 or wsAbs > limitW then
          s.limiter = true
        elseif s.we < limitW * 0.985 then
          s.limiter = false
        end
        if s.limiter then thr = 0 end
        s.we = wsAbs + s.sync
        tEng = engineTorque(car, s.we * 30 / math.pi, thr)
        tClutch = tEng
        engineJ = Je
        if s.cut > 0 then
          -- during the cut the engine sheds part of the mismatch on its own (no torque to the wheels)
          s.sync = s.sync * math.exp(math.log(car.shiftKeep or 0.6) * h / car.shiftTime)
          tClutch = 0
        elseif s.sync ~= 0 then
          -- release the rest of the mismatch (an upshift drives the wheels harder for a moment)
          local d = s.sync * math.min(1, h / (car.syncTau or TAU_SYNC))
          tClutch = tClutch + Je * d / h
          s.sync = s.sync - d
          if math.abs(s.sync) < 0.5 then s.sync = 0 end
        end
      end
    end
    -- wheel torque per driven axle (sign of the ratio handles reverse)
    local tw = (tClutch or 0) * ratio
    local twF, twR = tw * car.driveFront, tw * car.driveRear
    local JeW = engineJ * ratio * ratio
    integrateAxle(car, s, 0, car.lockedF, twF, JeW * car.driveFront, Jw, h)
    integrateAxle(car, s, 2, car.lockedR, twR, JeW * car.driveRear, Jw, h)
    s.wf, s.wr = (s.w[0] + s.w[1]) * 0.5, (s.w[2] + s.w[3]) * 0.5
    s.fxTotal = fxF + fxR

    local drag = 0.5 * RHO * car.cda * v * math.abs(v)
    local a = (fxF + fxR - drag) / m
    s.ax = s.ax + (a / G - s.ax) * math.min(1, h / 0.05) -- load transfer follows with a little lag (suspension)
    s.v = v + a * h
    s.x = s.x + s.v * h
    s.driveTorque = tw
    s.uF, s.uR = uF, uR
  end
  if s.cut > 0 then
    s.cut = s.cut - dt
    if s.cut < 0 then s.cut = 0 end
  end
  s.rpm = s.we * 30 / math.pi
  s.t = s.t + dt
end

return M
