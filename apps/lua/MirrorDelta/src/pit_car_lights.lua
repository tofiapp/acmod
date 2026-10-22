-- Pit lane: the car's headlights (and, as an option, the hazard lights) blink while we are in the pit lane, like a
-- pit limiter warning. ac.setHeadlights(bool) and ac.setTurningLights(ac.TurningLights.Hazards / None) are what the
-- official Unbound app uses for its light buttons; car.headlightsActive / car.hazardLights give the current state.
-- The state at the pit entry is put back at the pit exit. Nothing is written while the state already matches.

local config = require('src/config')
local S = config.S

local M = { active = false, phase = false }

local PERIOD = 0.4             -- s on, s off
local wasActive = false
local hadHeadlights, hadHazards = false, false
local testUntil = -1

function M.test(seconds) testUntil = os.preciseClock() + (seconds or 8) end

local function setHeadlights(on) ac.setHeadlights(on) end
local function setHazards(on) ac.setTurningLights(on and ac.TurningLights.Hazards or ac.TurningLights.None) end

local function step()
  local car, sim = ac.getCar(0), ac.getSim()
  if not car or not sim or sim.isReplayActive then return end
  local now = os.preciseClock()
  local inPit = car.isInPitlane or now < testUntil
  local active = inPit and (S.pitHeadlights or S.pitHazards)
  if active and not wasActive then                  -- pit entry: remember what was on
    hadHeadlights, hadHazards = car.headlightsActive == true, car.hazardLights == true
  end
  if active then
    local on = math.floor(now / PERIOD) % 2 == 0
    M.phase = on
    if S.pitHeadlights and car.headlightsActive ~= on then pcall(setHeadlights, on) end
    if S.pitHazards and (car.hazardLights == true) ~= on then pcall(setHazards, on) end
  elseif wasActive then                             -- pit exit: back to what the driver had
    if S.pitHeadlights and car.headlightsActive ~= hadHeadlights then pcall(setHeadlights, hadHeadlights) end
    if S.pitHazards and (car.hazardLights == true) ~= hadHazards then pcall(setHazards, hadHazards) end
  end
  wasActive, M.active = active, active
end

local failed = false
function M.update()
  if failed then return end
  local ok, err = pcall(step)
  if not ok then
    failed = true
    M.error = tostring(err)
  end
end

return M
