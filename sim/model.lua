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
--     driven axles have their own speed (locked axle; AWD = open centre with a fixed torque split);
--   - wheel and engine inertia (engine inertia reflected through the gear ratio once the clutch is locked).
-- Integration: fixed physics step (333 Hz like AC) split into substeps (the wheel slip equation is stiff at low speed).
-- Not modelled yet (extensible): yaw/steering dynamics, brakes, differential locking, tyre temperature.

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
  c.torqueScale = scale.power or 1
  -- overall ratio (engine rad/s per wheel rad/s) from rpm per km/h: omega_e / omega_w = rpmPerKmh * 0.377 * r
  c.ratios = {}
  for i, rpk in ipairs(profile.rpmPerKmh) do c.ratios[i] = rpk * 0.377 * profile.tyreRadius end
  c.reverseRatio = -(profile.reverseRpmPerKmh or profile.rpmPerKmh[1]) * 0.377 * profile.tyreRadius
  c.driveFront = profile.drive == 'FWD' and 1 or profile.drive == 'AWD' and (profile.frontShare or 0.4) or 0
  c.driveRear = 1 - c.driveFront
  c.tractionType = profile.drive == 'RWD' and 0 or profile.drive == 'FWD' and 1 or 2
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
    wf = v / r, wr = v / r,       -- axle angular speeds
    we = 0,                       -- engine angular speed
    gear = gear or 1,
    cut = 0,                      -- remaining ignition cut of a shift, s
    sync = 0,                     -- engine speed mismatch after a shift, rad/s (engine side)
    locked = true,                -- clutch locked
    -- outputs of the last step (per wheel 0 FL, 1 FR, 2 RL, 3 RR)
    fz = { [0] = 0, 0, 0, 0 }, kappa = { [0] = 0, 0, 0, 0 }, nd = { [0] = 0, 0, 0, 0 },
    sy = { [0] = 0, 0, 0, 0 }, slideF = false, slideR = false, uF = 0, uR = 0,
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
  dst = dst or { fz = {}, kappa = {}, nd = {}, sy = {} }
  for k, v in pairs(src) do
    if type(v) ~= 'table' then dst[k] = v end
  end
  for i = 0, 3 do
    dst.fz[i], dst.kappa[i], dst.nd[i], dst.sy[i] = src.fz[i], src.kappa[i], src.nd[i], src.sy[i]
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

-- One axle's force for wheel speed w; returns Fx (both wheels) and fills per-wheel outputs.
local function axleForces(car, s, env, i0, w, v, fzL, fzR, ay, axleShare)
  local r = car.tyreRadius
  local kappa = (w * r - v) / math.max(math.abs(v), VMIN)
  local sx = kappa / car.kappaPeak
  local kL, kR = env.muScale * env.muWheel[i0], env.muScale * env.muWheel[i0 + 1]
  local muL, muR = car.mu * kL, car.mu * kR
  -- lateral share this axle must carry (lateral friction may be higher than longitudinal, as in AC's tyres)
  local fyNeed = car.mass * math.abs(ay) * G * axleShare
  local cap = car.muLat * (kL * fzL + kR * fzR)
  local u = cap > 1 and fyNeed / cap or 0
  local sxa = sx < 0 and -sx or sx
  local sy, ok = 0, true
  if u > 0 then sy, ok = tyre.solveLateral(sxa, u) end
  local sAbs = math.sqrt(sxa * sxa + sy * sy)
  local fshare = sAbs > 1e-9 and tyre.f(sAbs) * sx / sAbs or 0
  local fx = (muL * fzL + muR * fzR) * fshare
  s.kappa[i0], s.kappa[i0 + 1] = kappa, kappa
  s.nd[i0], s.nd[i0 + 1] = sAbs, sAbs
  s.sy[i0], s.sy[i0 + 1] = sy, sy
  return fx, ok, u
end

-- Advances the car by dt. `throttle` 0..1 (what the controller sent); env: { muScale, muWheel[0..3], ay (g) }.
function M.step(car, s, env, throttle, dt)
  local h = dt / SUBSTEPS
  local r = car.tyreRadius
  local m = car.mass
  local L = car.wheelbase
  local idleW = car.idleRpm * math.pi / 30
  local launchW = car.launchRpm * math.pi / 30
  local limitW = car.revLimit * math.pi / 30
  local ratio = ratioOf(car, s.gear)
  local Jw = car.wheelInertia * 2       -- per axle
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
    local sg = ay >= 0 and 0.5 or -0.5 -- ay > 0: the left wheels are on the inside
    local fzFL, fzFR = fzF * 0.5 - dF * sg, fzF * 0.5 + dF * sg
    local fzRL, fzRR = fzR * 0.5 - dR * sg, fzR * 0.5 + dR * sg
    if fzFL < 50 then fzFL = 50 end
    if fzFR < 50 then fzFR = 50 end
    if fzRL < 50 then fzRL = 50 end
    if fzRR < 50 then fzRR = 50 end
    s.fz[0], s.fz[1], s.fz[2], s.fz[3] = fzFL, fzFR, fzRL, fzRR

    local fxF, okF, uF = axleForces(car, s, env, 0, s.wf, v, fzFL, fzFR, ay, car.frontWeight)
    local fxR, okR, uR = axleForces(car, s, env, 2, s.wr, v, fzRL, fzRR, ay, 1 - car.frontWeight)
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
      -- auto-clutch (like AC's): slips while the wheels turn the engine slower than the launch speed for this
      -- throttle, so the engine stays between idle and the launch rpm; locks above it, re-opens below 90 % of it
      -- (a spin that briefly lifts the wheel speed does not lock the clutch for good)
      local target = idleW + (launchW - idleW) * thr
      if s.locked and s.cut <= 0 and s.sync == 0 and wsAbs < target * 0.9 and s.gear ~= 0 then s.locked = false end
      if not s.locked then
        if wsAbs >= target then
          s.locked = true
          s.we = wsAbs
        else
          s.we = target
          tEng = engineTorque(car, s.we * 30 / math.pi, thr)
          tClutch = tEng > 0 and tEng or 0
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
          s.sync = s.sync - s.sync * math.min(1, h / (car.shiftTime * 2))
          tClutch = 0
        elseif s.sync ~= 0 then
          -- release the rest of the mismatch (an upshift drives the wheels harder for a moment)
          local d = s.sync * math.min(1, h / TAU_SYNC)
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
    local JF = Jw + JeW * car.driveFront
    local JR = Jw + JeW * car.driveRear
    -- rolling resistance as a wheel torque (keeps standstill stable)
    local rrF = car.crr * (fzF) * r
    local rrR = car.crr * (fzR) * r
    s.wf = s.wf + (twF - fxF * r + rr(s.wf, rrF)) / JF * h
    s.wr = s.wr + (twR - fxR * r + rr(s.wr, rrR)) / JR * h

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
