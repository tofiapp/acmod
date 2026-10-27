-- Throttle core: key -> smooth, grip-aware throttle. Pure Lua (Lua 5.1 / LuaJIT), no CSP API, no allocation per update.
--
-- Inputs per update: dt (s, any rate), the gas key (boolean), the car state (CSP's car or the simulator's table with
-- the same field names: gear, rpm, localVelocity.z, tractionType, wheels[0..3].ndSlip/load/angularSpeed/tyreRadius),
-- lateral g and the current steering output (-1..1, for the optional corner cap). Output: throttle 0..1.
-- Debug fields on the instance: request (ramped key throttle), cap, corner, out, and the traction instance (`traction`).
--
-- Steps: corner cap (off by default) -> ramp of the key ("the foot") -> traction cap (core/traction.lua) -> final slew:
-- the sent throttle never jumps; it falls at FALL only when the driver lifts, otherwise (assists) at most ASSIST_FALL
-- per second, or ASSIST_FALL_SEVERE while the wheels really spin (slip over twice the target).

local ramp = require('core/ramp')
local Traction = require('core/traction')

local M = {}
M.__index = M

M.DEFAULTS = {
  RISE = 1.2,              -- per second (settings: THROTTLE_RISE_RATE %/s)
  FALL = 4,                -- per second when the key is released (THROTTLE_FALL_RATE)
  MAX = 1,                 -- throttle cap (MAX_THROTTLE)
  TRACTION = true,         -- traction cap on (TRACTION)
  TARGET_SLIP = 1,         -- ndSlip units, 1 = tyre peak (TARGET_SLIP %)
  RESPONSE = 1,            -- scales the traction rates (TRACTION_RESPONSE %)
  CORNER_REDUCTION = 0,    -- cap reduction at full lateral load or full steering (CORNER_THROTTLE_REDUCTION)
  ASSIST_FALL = 1.5,       -- per second: fastest throttle reduction an assist may make
  ASSIST_FALL_SEVERE = 4,  -- per second while the wheels really spin
  CORNER_G_FULL = 1.5,     -- lateral g at which the corner cap reduction is complete
  CORNER_TAU = 0.15,       -- s, smoothing of the corner factor
}

local function merged(defaults, params)
  local p = {}
  for k, v in pairs(defaults) do p[k] = v end
  if params then for k, v in pairs(params) do if defaults[k] ~= nil then p[k] = v end end end
  return p
end

-- `params` overrides DEFAULTS, `tractionParams` overrides core/traction.lua DEFAULTS.
function M.new(params, tractionParams)
  return setmetatable({
    p = merged(M.DEFAULTS, params),
    traction = Traction.new(tractionParams),
    request = 0, -- ramped key throttle (the "foot" before limits)
    out = 0,     -- last output
    corner = 0,  -- smoothed 0..1 corner load factor
    cap = 1,
    tractionOn = false,
  }, M)
end

-- Replaces parameters (e.g. a driving mode); keys not in DEFAULTS are ignored.
function M:setParams(params)
  for k, v in pairs(params) do if M.DEFAULTS[k] ~= nil then self.p[k] = v end end
end

function M:configure(carState)
  self.traction:configure(carState)
end

-- Teleport, pits, session restart: outputs to zero; the traction memory is kept.
function M:reset(carState)
  self.request, self.out, self.corner = 0, 0, 0
  if carState then self.traction:configure(carState) else self.traction:reset() end
end

function M:update(dt, keyGas, carState, latG, steer)
  local P = self.p
  local g = math.abs(latG) / P.CORNER_G_FULL
  local st = math.abs(steer)
  local c = g > st and g or st
  if c > 1 then c = 1 end
  self.corner = self.corner + (c - self.corner) * math.min(1, dt / P.CORNER_TAU)
  local cap = P.MAX * (1 - P.CORNER_REDUCTION * self.corner)
  self.cap = cap

  local request = ramp.step(self.request, keyGas and cap or 0, P.RISE, P.FALL, dt)
  self.request = request

  -- Traction in every forward gear. Not by the direction of travel: in a spin the car moves sideways or backwards
  -- relative to its nose, and switching traction off there sent full throttle into the spin (user log, v0.9).
  local traction = self.traction
  local on = P.TRACTION and carState.gear > 0
  self.tractionOn = on
  local target
  if on then
    target = traction:update(dt, carState, request, P.TARGET_SLIP, P.RESPONSE)
  else
    traction:reset()
    target = request
  end
  local out = self.out
  local fall = request < out and P.FALL or (traction.severe and on) and P.ASSIST_FALL_SEVERE or P.ASSIST_FALL
  local rise = P.RISE * (on and traction.riseScale or 1)
  out = ramp.step(out, target, rise, fall, dt)
  self.out = out
  return out
end

return M
