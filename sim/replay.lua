-- Open-loop replay of real driving (sim/data/real/*.csv, the user's KeyDrive logs): the logged slip, revs, gear and
-- lateral g are fed to the throttle core exactly as they were, at the game's 333 Hz. The car cannot react to a
-- different throttle here, so this measures only CAUTION: how long the core would hold the throttle back while the
-- tyres were in fact far from their limit (drive slip below LOW). The simulator judges safety, this judges the
-- "needlessly cautious" the user reported. Pure LuaJIT; wheel loads are not logged and taken as equal.
-- It also counts the PULSE of the replayed output (metrics.pulseStats, the same definition as the sim and the
-- measurements of the user's logs): an open-loop replay cannot show a limit cycle the car closes, but it reproduced
-- the logged direction changes within ~10 % (r63 on the 0.11.0 logs 1.60 vs 1.63 /s), because the real slip that
-- drove the logged cycle is fed again and a jumpier core answers it again.

local Throttle = require('core/throttle')
local metrics = require('metrics')

local M = {}
M.LOW = 0.75         -- drive slip (combined ndSlip of the driven wheels) under which a cut counts as needless
                     -- (0.6 missed the corner cuts at 0.6-0.75 the user felt as caution)
M.CUT = 0.03         -- request - output above this counts as a cut
M.MIN_HELD = 5       -- s of key-held time before a dataset counts in the caution mean
M.RISK_SLIP = 1      -- RISK: the real tyres were past their peak (drive slip ndSlip above this) ...
M.RISK_MARGIN = 0.05 -- ... and the replayed core sends more than the game did (logged gas_out + this): a core that
                     -- cuts less where the real car was already over the limit. Without it a core that never cuts
                     -- scored 0 caution and 0 pulse on the logs and won the cost despite its sim spins.

local cache = {}

local function load(path)
  if cache[path] then return cache[path] end
  local f = assert(io.open(path, 'r'))
  local header
  local cols, data = {}, {}
  for line in f:lines() do
    line = line:gsub('\r$', '')
    if line ~= '' and line:sub(1, 1) ~= '#' then
      if not header then
        header = true
        local i = 0
        for name in line:gmatch('[^,]+') do i = i + 1; cols[name] = i end
      else
        local row, i = {}, 0
        for v in line:gmatch('[^,]+') do i = i + 1; row[i] = tonumber(v) or 0 end
        data[#data + 1] = row
      end
    end
  end
  f:close()
  local d = { cols = cols, rows = data }
  cache[path] = d
  return d
end
M.load = load

-- Returns needless cut time, total cut time and time with the gas key held (s) for one dataset, plus the pulse
-- accumulator of the replayed output (metrics.newPulseAcc; pass acc to add to it).
function M.caution(path, throttleParams, tractionParams, acc)
  local d = load(path)
  local c, rows = d.cols, d.rows
  local th = Throttle.new(throttleParams, tractionParams)
  local w = {}
  for i = 0, 3 do w[i] = { ndSlip = 0, slipRatio = 0, slipAngle = 0, load = 3000, angularSpeed = 0, tyreRadius = 0.33 } end
  local car = { gear = 1, rpm = 1000, speedKmh = 0, localVelocity = { x = 0, y = 0, z = 0 }, tractionType = 0, wheels = w }
  th:configure(car)
  local ND = { c.nd_fl, c.nd_fr, c.nd_rl, c.nd_rr }
  local RA = { c.ratio_fl, c.ratio_fr, c.ratio_rl, c.ratio_rr }
  local AN = { c.angle_fl, c.angle_fr, c.angle_rl, c.angle_rr }
  local held, cut, needless, risk = 0, 0, 0, 0
  local GO = c.gas_out
  -- tc_state 5: the driver switched the traction off with TRACTION_KEY (burnout, spin on purpose): replayed with
  -- traction off as in the game and not counted
  local TC = c.tc_state
  local userOff = false
  local ON, OFF = { TRACTION = th.p.TRACTION }, { TRACTION = false }
  local prevT
  local pt, px, pk, pg = {}, {}, {}, {}
  for ri, r in ipairs(rows) do
    local t = r[c.t]
    local dt = (prevT and t - prevT < 0.1 and t > prevT) and t - prevT or 0.025
    prevT = t
    local kmh = r[c.speed_kmh]
    car.gear, car.rpm, car.speedKmh, car.localVelocity.z = r[c.gear], r[c.rpm], kmh, kmh / 3.6
    for i = 0, 3 do
      local wi = w[i]
      wi.ndSlip, wi.slipRatio, wi.slipAngle = r[ND[i + 1]], r[RA[i + 1]], r[AN[i + 1]]
      wi.angularSpeed = kmh / 3.6 / 0.33
    end
    local off = TC ~= nil and r[TC] == 5
    if off ~= userOff then userOff = off; th:setParams(off and OFF or ON) end
    local key = r[c.key_gas] > 0
    local n = math.max(1, math.floor(dt / 0.003 + 0.5))
    local g
    for _ = 1, n do g = th:update(dt / n, key, car, r[c.lat_g], 0) end
    pt[ri], px[ri], pk[ri], pg[ri] = t, g, key and not off, car.gear
    if key and not off then
      held = held + dt
      if th.request - g > M.CUT then
        cut = cut + dt
        if r[c.drive_slip_nd] < M.LOW then needless = needless + dt end
      end
      if GO and r[c.drive_slip_nd] > M.RISK_SLIP and g > r[GO] + M.RISK_MARGIN then risk = risk + dt end
    end
  end
  acc = metrics.pulseStats(pt, px, pk, pg, #rows, acc)
  return needless, cut, held, acc, risk
end

-- All datasets in sim/data/real: the mean share of key-held time with a needless cut, and the pulse rates of the
-- replayed output (metrics.pulseRates: rate, rateLow (gears 1-2), big, travel, held, ...) pooled over the datasets
-- that carry the logged output (gas_out, 0.11+ logs): only there can the replay be checked against what the game
-- did. Open-loop caveat: those logs were driven by r63-like cores, so their slip carries r63's own cycle; a core
-- that answers it more calmly scores better here (the closed-loop check is the sim's pulse metric).
function M.realAll(root, throttleParams, tractionParams)
  local files = dofile(root .. '/sim/data/real/index.lua')
  local share, counted, totalNeedless, totalHeld = 0, 0, 0, 0
  local riskTime, riskHeld = 0, 0
  local acc = metrics.newPulseAcc()
  for _, name in ipairs(files) do
    local path = root .. '/sim/data/real/' .. name
    local hasOut = load(path).cols.gas_out ~= nil
    local needless, _, held, _, risk = M.caution(path, throttleParams, tractionParams, hasOut and acc or nil)
    if hasOut then riskTime, riskHeld = riskTime + risk, riskHeld + held end
    -- a dataset with (almost) no key-held time says nothing about caution (f3: 0 s held; it used to enter the mean as
    -- a share of 0 and diluted every set's caution by 1/24)
    if held >= M.MIN_HELD then
      share, counted = share + needless / held, counted + 1
    end
    totalNeedless, totalHeld = totalNeedless + needless, totalHeld + held
  end
  return counted > 0 and share / counted or 0, metrics.pulseRates(acc), totalNeedless, totalHeld,
    riskHeld > 0 and riskTime / riskHeld or 0
end

function M.cautionAll(root, throttleParams, tractionParams)
  local share, _, needless, held = M.realAll(root, throttleParams, tractionParams)
  return share, needless, held
end

-- Pulse of the LOGGED output (gas_out column, the 0.11+ logs only): the reference the replay is checked against.
function M.loggedPulse(path)
  local d = load(path)
  local c = d.cols
  if not c.gas_out then return nil end
  local pt, px, pk, pg = {}, {}, {}, {}
  for i, r in ipairs(d.rows) do
    pt[i], px[i], pg[i] = r[c.t], r[c.gas_out], r[c.gear]
    pk[i] = r[c.key_gas] > 0 and not (c.tc_state and r[c.tc_state] == 5)
  end
  return metrics.pulseStats(pt, px, pk, pg, #d.rows)
end

return M
