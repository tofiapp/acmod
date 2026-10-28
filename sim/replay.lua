-- Open-loop replay of real driving (sim/data/real/*.csv, the user's KeyDrive logs): the logged slip, revs, gear and
-- lateral g are fed to the throttle core exactly as they were, at the game's 333 Hz. The car cannot react to a
-- different throttle here, so this measures only CAUTION: how long the core would hold the throttle back while the
-- tyres were in fact far from their limit (drive slip below LOW). The simulator judges safety, this judges the
-- "needlessly cautious" the user reported. Pure LuaJIT; wheel loads are not logged and taken as equal.

local Throttle = require('core/throttle')

local M = {}
M.LOW = 0.75         -- drive slip (combined ndSlip of the driven wheels) under which a cut counts as needless
                     -- (0.6 missed the corner cuts at 0.6-0.75 the user felt as caution)
M.CUT = 0.03         -- request - output above this counts as a cut

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

-- Returns needless cut time, total cut time and time with the gas key held (s) for one dataset.
function M.caution(path, throttleParams, tractionParams)
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
  local held, cut, needless = 0, 0, 0
  -- tc_state 5: the driver switched the traction off with TRACTION_KEY (burnout, spin on purpose): replayed with
  -- traction off as in the game and not counted
  local TC = c.tc_state
  local userOff = false
  local ON, OFF = { TRACTION = th.p.TRACTION }, { TRACTION = false }
  local prevT
  for _, r in ipairs(rows) do
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
    if key and not off then
      held = held + dt
      if th.request - g > M.CUT then
        cut = cut + dt
        if r[c.drive_slip_nd] < M.LOW then needless = needless + dt end
      end
    end
  end
  return needless, cut, held
end

-- All datasets in sim/data/real: the mean share of key-held time with a needless cut.
function M.cautionAll(root, throttleParams, tractionParams)
  local files = dofile(root .. '/sim/data/real/index.lua')
  local share, totalNeedless, totalHeld = 0, 0, 0
  for _, name in ipairs(files) do
    local needless, _, held = M.caution(root .. '/sim/data/real/' .. name, throttleParams, tractionParams)
    share = share + (held > 0 and needless / held or 0)
    totalNeedless, totalHeld = totalNeedless + needless, totalHeld + held
  end
  return share / #files, totalNeedless, totalHeld
end

return M
