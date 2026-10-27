-- Steering core: keys -> steering output -1..1 (+ = right). Pure Lua (Lua 5.1 / LuaJIT), no CSP API, no allocation
-- per update.
--
-- Default style = exact copy of AC's own keyboard steering (measured in keyboard mode, docs/keydrive-research.md):
-- outwards STEERING_SPEED x a factor that falls with the car's speed, back to the centre STEER_RESET_SPEED x
-- STEERING_SPEED, towards the other side while the wheels still point the other way STEERING_OPPOSITE_DIRECTION_SPEED x
-- STEERING_SPEED. RATE scales all three; SLOWDOWN blends the speed factor between the standstill value (0) and AC's
-- curve (1). Style "curve" uses CURVE (km/h -> % of full lock per second) and RETURN instead.
-- No deadzone, no filter: the output is the rate-limited key target. The optional grip window / countersteer
-- (core/steer_assist.lua, off by default) can only make it follow more slowly, except an opt-in countersteer.
--
-- Inputs per update: dt, left/right keys, the car state (speedKmh, gear, localVelocity.z, plus the assist's fields when
-- the assist is on). Debug fields: request (ramped key steering), out, assist (core/steer_assist.lua instance).

local ramp = require('core/ramp')
local curve = require('core/curve')
local SteerAssist = require('core/steer_assist')

local M = {}
M.__index = M

-- Outward speed factor of AC's keyboard steering against km/h (measured).
local AC_SPEED_CURVE = curve.parse('0:0.74 55:0.60 95:0.50 105:0.366 125:0.302 145:0.236 165:0.184 185:0.142 ' ..
  '205:0.108 215:0.10 400:0.10')
local AC_STANDSTILL = curve.eval(AC_SPEED_CURVE, 0)
M.AC_SPEED_CURVE = AC_SPEED_CURVE

M.DEFAULTS = {
  STYLE_AC = true,          -- true: copy of AC's keyboard steering; false: CURVE
  RATE = 1,                 -- scales AC's three rates (STEER_RATE %)
  SLOWDOWN = 1,             -- share of AC's slowdown with speed (STEER_SPEED_SLOWDOWN %)
  KB_SPEED = 1.75,          -- AC controls.ini [KEYBOARD] STEERING_SPEED
  KB_OPPOSITE = 2.5,        -- STEERING_OPPOSITE_DIRECTION_SPEED
  KB_RESET = 1.8,           -- STEER_RESET_SPEED
  CURVE = curve.parse('0:250 60:160 120:100 200:70'), -- STEER_SPEED_CURVE, % of full lock per second
  RETURN = 1.5,             -- curve style: return speed as a multiple of the steering speed
  BOTH_RETURN = false,      -- both keys: false holds the angle, true returns smoothly to the centre
  LIMIT_STRENGTH = 0,       -- grip window strength 0..1 (STEER_LIMIT_STRENGTH)
  TARGET = 1.2,             -- grip window: allowed front slip angle in units of the peak (STEER_TARGET)
  COUNTERSTEER = 0,         -- countersteer assist 0..1 (COUNTERSTEER_ASSIST)
  COUNTER_HOLD = 0.6,       -- s after a countersteer while the assist may move the wheels faster than the keys
}

function M.new(params)
  local p = {}
  for k, v in pairs(M.DEFAULTS) do p[k] = v end
  if params then for k, v in pairs(params) do if M.DEFAULTS[k] ~= nil then p[k] = v end end end
  return setmetatable({ p = p, request = 0, out = 0, counterHold = 0, rate = 0, assist = SteerAssist.new() }, M)
end

function M:setParams(params)
  for k, v in pairs(params) do if M.DEFAULTS[k] ~= nil then self.p[k] = v end end
end

function M:configure(carState, steerLock, steerRatio)
  self.assist:configure(carState, steerLock, steerRatio)
end

function M:reset()
  self.request, self.out, self.counterHold = 0, 0, 0
  self.assist:reset()
end

-- Sets request and output to a value steered by someone else (AC's own steering), so taking over never jumps.
function M:follow(value)
  self.request, self.out = value, value
end

function M:update(dt, kLeft, kRight, carState)
  local P = self.p
  local request = self.request
  local target
  if kLeft and kRight then
    target = P.BOTH_RETURN and 0 or request -- both keys: hold the angle, or return smoothly
  else
    target = (kRight and 1 or 0) - (kLeft and 1 or 0)
  end
  local rate
  local speed = math.abs(carState.speedKmh)
  if P.STYLE_AC then
    local back
    if target == 0 or (kLeft and kRight) then
      back = P.KB_RESET * P.KB_SPEED
    else
      back = P.KB_OPPOSITE * P.KB_SPEED
    end
    local f = curve.eval(AC_SPEED_CURVE, speed)
    f = AC_STANDSTILL - P.SLOWDOWN * (AC_STANDSTILL - f)
    rate = P.KB_SPEED * f * P.RATE
    back = back * P.RATE
    request = ramp.stepSigned(request, target, rate, back, dt)
    if back > rate then rate = back end
  else
    rate = curve.eval(P.CURVE, speed) / 100
    request = ramp.stepSigned(request, target, rate, rate * P.RETURN, dt)
  end
  self.request = request
  self.rate = rate
  local assist = self.assist
  if carState.gear < 0 or carState.localVelocity.z < 0 then
    assist:reset()
    self.out = request -- reversing: plain keys
    return request
  end
  local out = self.out
  local wanted = assist:update(dt, carState, request, out, P.TARGET, P.LIMIT_STRENGTH, P.COUNTERSTEER)
  -- The assist may never move the wheels faster than the keys do (user report: it grabbed the steering).
  -- A countersteer (opt-in) has to be quick, and so does taking it back, else the car swings the other way.
  if assist.countering then
    self.counterHold = P.COUNTER_HOLD
  elseif self.counterHold > 0 then
    self.counterHold = self.counterHold - dt
  end
  if self.counterHold > 0 then
    self.out = wanted
    return wanted
  end
  local maxRate = rate * math.max(1, P.RETURN)
  out = ramp.stepSigned(out, wanted, maxRate, maxRate, dt)
  self.out = out
  return out
end

return M
