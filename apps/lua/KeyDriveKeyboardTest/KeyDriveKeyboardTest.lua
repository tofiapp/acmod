-- KeyDrive Keyboard Test: input method research, variant A ("pure keyboard").
--
-- Question: with AC's Input method = Keyboard, can a script fully take over gas, brake and steering, so that AC's own
-- keyboard handling (hidden throttle traction help, brake regulation, steering filter) no longer touches them, while
-- every other key (gears, lights, DRS, ...) keeps working natively?
--
-- How: CSP's ac.overrideCarControls() (Lua apps; the official Unbound app drives the car with it). combineAxis = false
-- replaces the pedals and the handbrake instead of taking the maximum with AC's values; steer replaces AC's steering
-- unless set to math.huge. While the test is on, this app computes its own gas, brake and steering from AC's keyboard
-- binds (smooth ramps, steering = KeyDrive's copy of AC's keyboard steering) and writes them every frame. It then
-- compares what the car really runs (car.gas, car.brake, car.steer) with what was written:
--   - equal everywhere, also with the driven wheels spinning (AC's keyboard throttle help), with brake above 0.75 (AC
--     holds keyboard brake at 0.55-0.70) and while steering faster than AC's keyboard filter allows above 100 km/h: AC
--     does not process the override, variant A works;
--   - different: AC still applies its keyboard filter after the override.
-- The app runs only while its window is open (LAZY = FULL); closing it gives the car back to AC.
-- A CSV of the last 120 s goes to Documents/Assetto Corsa/logs/keydrive/kb-test.csv.

local car = ac.getCar(0)
local sim = ac.getSim()

local S = ac.storage({
  maxGas = 100,      -- % throttle with the gas key held
  gasRise = 150,     -- % per second
  maxBrake = 100,    -- % brake with the brake key held
  brakeRise = 300,   -- % per second
  steerRate = 100,   -- % of AC's keyboard steering rates
  slowdown = 0,      -- % of AC's steering slowdown with speed. 0 by default: the test must steer faster than AC's own
                     -- keyboard filter, else a filter applied after the override would pass our values unchanged
}, 'kdkt2_')

local GAS_FALL = 6       -- per second
local BRAKE_FALL = 8     -- per second
local SETTLE = 0.3       -- s after switching on before measuring
local GAS_TOL = 0.03     -- tolerated difference, pedal units
local STEER_TOL = 0.02   -- tolerated difference, units of full lock (~5 deg of steering wheel at 270 deg)

-- AC's keyboard steering, measured in keyboard mode (docs/keydrive-research.md): outward rate = STEERING_SPEED x factor
-- by speed; back to centre STEER_RESET_SPEED x STEERING_SPEED; towards the other side OPPOSITE x STEERING_SPEED.
local CURVE_X = { 0, 55, 95, 105, 125, 145, 165, 185, 205, 215, 400 }
local CURVE_Y = { 0.74, 0.60, 0.50, 0.366, 0.302, 0.236, 0.184, 0.142, 0.108, 0.10, 0.10 }
local function speedFactor(kmh)
  if kmh <= CURVE_X[1] then return CURVE_Y[1] end
  for i = 2, #CURVE_X do
    if kmh <= CURVE_X[i] then
      local t = (kmh - CURVE_X[i - 1]) / (CURVE_X[i] - CURVE_X[i - 1])
      return CURVE_Y[i - 1] + (CURVE_Y[i] - CURVE_Y[i - 1]) * t
    end
  end
  return CURVE_Y[#CURVE_Y]
end

------------------------------------------------------------------------------------------------------------------------
-- AC keyboard binds and input method

local K = { gas = 38, brake = 40, left = 37, right = 39, handbrake = -1,
  steerSpeed = 1.75, steerOpposite = 2.5, steerReset = 1.8, method = '?', mouseSteer = 0, mousePedals = 0 }

local function parse(cfg, section, key, fallback)
  local v = cfg:get(section, key, '')
  if type(v) == 'number' then return v end
  v = type(v) == 'string' and tonumber((v:match('^%s*(%S+)'))) or nil
  return v or fallback
end

local function readControls()
  local ok, cfg = pcall(ac.INIConfig.load, ac.getFolder(ac.FolderID.Cfg) .. '\\controls.ini')
  if not ok or not cfg then return end
  K.gas = parse(cfg, 'KEYBOARD', 'GAS', K.gas)
  K.brake = parse(cfg, 'KEYBOARD', 'BRAKE', K.brake)
  K.left = parse(cfg, 'KEYBOARD', 'LEFT', K.left)
  K.right = parse(cfg, 'KEYBOARD', 'RIGHT', K.right)
  K.handbrake = parse(cfg, 'HANDBRAKE', 'KEY', -1) -- Content Manager keeps the keyboard handbrake here
  if K.handbrake <= 0 then K.handbrake = parse(cfg, 'KEYBOARD', 'HANDBRAKE', -1) end
  K.mouseSteer = parse(cfg, 'KEYBOARD', 'MOUSE_STEER', 0)
  K.mousePedals = parse(cfg, 'KEYBOARD', 'MOUSE_ACCELERATOR_BRAKE', 0)
  K.steerSpeed = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEERING_SPEED', 1.75))
  K.steerOpposite = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEERING_OPPOSITE_DIRECTION_SPEED', 2.5))
  K.steerReset = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEER_RESET_SPEED', 1.8))
  K.method = tostring(cfg:get('HEADER', 'INPUT_METHOD', '?'))
end

readControls()
pcall(ac.onControlSettingsChanged, readControls)

local function down(k) return k > 0 and ac.isKeyDown(k) end

------------------------------------------------------------------------------------------------------------------------
-- Controls override

local controls = nil     -- ac.overrideCarControls() struct, taken on the first switch-on
local combineOk = true   -- false: this CSP has no combineAxis (older than 0.3.0-preview125)
local enabled = false
local onTime = 0
local status = ''

local function setCombine(v)
  combineOk = pcall(function () controls.combineAxis = v end)
end

-- Values that leave everything to AC: pedals combine with max(original, 0), clutch with min(original, 1), steering
-- passes through, KERS/MGU-H/gear untouched.
local function writeSafe()
  if not controls then return end
  pcall(function ()
    controls.steer = math.huge
    controls.gas = 0
    controls.brake = 0
    controls.handbrake = 0
    controls.clutch = 1
    controls.kers = ac.CarControlsInput.Flag.Skip
    controls.mguhMode = -1
    controls.requestedGearIndex = 0
  end)
  setCombine(true)
end

ac.onRelease(writeSafe)

local function acquire()
  if controls then return true end
  local ok, c = pcall(ac.overrideCarControls, 0)
  if not ok or c == nil then
    status = 'Tato verze CSP nemá ac.overrideCarControls.'
    return false
  end
  controls = c
  writeSafe()
  return true
end

------------------------------------------------------------------------------------------------------------------------
-- Measurement

local function newStat() return { n = 0, bad = 0, max = 0, sum = 0 } end
local stats = {
  gas = newStat(), gasSpin = newStat(),       -- all samples / driven wheels spinning (where AC's keyboard TC acts)
  brake = newStat(), brakeHigh = newStat(),   -- all / written brake above 0.75 (AC's keyboard brake stays <= 0.7)
  steer = newStat(), steerFast = newStat(),   -- all / above 100 km/h while steering faster than AC's keyboard filter
}
local function resetStats()
  for _, s in pairs(stats) do s.n, s.bad, s.max, s.sum = 0, 0, 0, 0 end
end
local function add(s, err, tol)
  s.n = s.n + 1
  s.sum = s.sum + err
  if err > s.max then s.max = err end
  if err > tol then s.bad = s.bad + 1 end
end

-- Written values: this frame and the previous one (physics may still have used the older value).
local wGas, wBrake, wSteer = 0, 0, 0
local pGas, pBrake, pSteer = 0, 0, 0
local readByPhysics = false
local lastStep = 1 / 60  -- dt of the last write step (rate of the last steering change)

local function errOf(actual, now, prev)
  local a, b = math.abs(actual - now), math.abs(actual - prev)
  return a < b and a or b
end

------------------------------------------------------------------------------------------------------------------------
-- Recorder: 40 Hz, last 120 s

local RATE, SECONDS = 40, 120
local SIZE = RATE * SECONDS
local COLUMNS = {
  { 't', '%.3f' }, { 'dt_ms', '%.1f' }, { 'on', '%d' }, { 'physics_read', '%d' },
  { 'key_gas', '%d' }, { 'key_brake', '%d' }, { 'key_left', '%d' }, { 'key_right', '%d' },
  { 'w_gas', '%.3f' }, { 'car_gas', '%.3f' }, { 'w_brake', '%.3f' }, { 'car_brake', '%.3f' },
  { 'w_steer', '%.4f' }, { 'car_steer', '%.4f' }, { 'steer_deg', '%.2f' },
  { 'speed_kmh', '%.1f' }, { 'gear', '%d' }, { 'rpm', '%.0f' },
  { 'nd_fl', '%.3f' }, { 'nd_fr', '%.3f' }, { 'nd_rl', '%.3f' }, { 'nd_rr', '%.3f' },
  { 'car_clutch', '%.3f' }, { 'tc_active', '%d' }, { 'abs_active', '%d' },
}
local NC = #COLUMNS
local header, rowFormat
do
  local names, fmts = {}, {}
  for i, c in ipairs(COLUMNS) do names[i], fmts[i] = c[1], c[2] end
  header, rowFormat = table.concat(names, ','), table.concat(fmts, ',')
end
local buf = {}
for i = 1, NC do
  local col = {}
  for j = 1, SIZE do col[j] = 0 end
  buf[i] = col
end
local head, count, time, sampleTimer, saveTimer, dirty, lastSaved = 0, 0, 0, 0, 0, false, -1
local path
do
  local ok, logs = pcall(ac.getFolder, ac.FolderID.Logs)
  if ok and type(logs) == 'string' and logs ~= '' then
    pcall(io.createDir, logs .. '/keydrive')
    path = logs .. '/keydrive/kb-test.csv'
  end
end

-- Optional car fields (not in the public SDK): probed once, logged as -1 when missing.
local function probe(name)
  return pcall(function () return car[name] and 1 or 0 end)
end
local hasClutch = pcall(function () return car.clutch + 0 end)
local hasTC, hasABS = probe('tractionControlInAction'), probe('absInAction')

local lastDt = 0
local function sample(steerLock)
  head = head % SIZE + 1
  if count < SIZE then count = count + 1 end
  local v, w = buf, car.wheels
  v[1][head] = time; v[2][head] = lastDt * 1000; v[3][head] = enabled and 1 or 0
  v[4][head] = readByPhysics and 1 or 0
  v[5][head] = down(K.gas) and 1 or 0; v[6][head] = down(K.brake) and 1 or 0
  v[7][head] = down(K.left) and 1 or 0; v[8][head] = down(K.right) and 1 or 0
  -- w_* = the value written in the previous frame: the one the car state of this frame can already show
  v[9][head] = pGas; v[10][head] = car.gas; v[11][head] = pBrake; v[12][head] = car.brake
  v[13][head] = pSteer; v[14][head] = car.steer / steerLock; v[15][head] = car.steer
  v[16][head] = car.speedKmh; v[17][head] = car.gear; v[18][head] = car.rpm
  v[19][head] = w[0].ndSlip; v[20][head] = w[1].ndSlip; v[21][head] = w[2].ndSlip; v[22][head] = w[3].ndSlip
  v[23][head] = hasClutch and car.clutch or -1
  v[24][head] = hasTC and (car.tractionControlInAction and 1 or 0) or -1
  v[25][head] = hasABS and (car.absInAction and 1 or 0) or -1
end

local row = {}
local function save()
  if not path or count == 0 or not dirty then return end
  local lines = { string.format('# input=%s steering_speed=%.2f opposite=%.2f reset=%.2f steer_lock=%.1f car=%s ' ..
    'max_gas=%d gas_rise=%d max_brake=%d brake_rise=%d steer_rate=%d slowdown=%d combine_axis_ok=%s',
    K.method, K.steerSpeed, K.steerOpposite, K.steerReset, car.steerLock, tostring(ac.getCarID(0)),
    S.maxGas, S.gasRise, S.maxBrake, S.brakeRise, S.steerRate, S.slowdown, tostring(combineOk)), header }
  local start = count < SIZE and 1 or head % SIZE + 1
  for n = 0, count - 1 do
    local i = (start - 1 + n) % SIZE + 1
    for k = 1, NC do row[k] = buf[k][i] end
    lines[#lines + 1] = string.format(rowFormat, unpack(row, 1, NC))
  end
  if pcall(io.save, path, table.concat(lines, '\n')) then lastSaved = time end
  dirty = false
end

ac.onRelease(save)

------------------------------------------------------------------------------------------------------------------------
-- Driving logic (only while the test is on)

local function approach(x, target, up, downRate, dt)
  if x < target then
    x = x + up * dt
    return x > target and target or x
  end
  x = x - downRate * dt
  return x < target and target or x
end

local function steerStep(dt, kLeft, kRight)
  local target = (kRight and 1 or 0) - (kLeft and 1 or 0)
  if kLeft and kRight then target = wSteer end -- both keys: hold the angle
  local scale = S.steerRate / 100
  local f0 = CURVE_Y[1]
  local f = f0 - (S.slowdown / 100) * (f0 - speedFactor(math.abs(car.speedKmh)))
  local out = K.steerSpeed * f * scale
  local s = wSteer
  if target == 0 then
    local back = K.steerReset * K.steerSpeed * scale
    if s > 0 then s = math.max(0, s - back * dt) else s = math.min(0, s + back * dt) end
    return s
  end
  if s * target < 0 then
    -- still pointing the other way: AC's faster "opposite direction" rate until the centre
    local opp = K.steerOpposite * K.steerSpeed * scale
    s = s + target * opp * dt
    if s * target > 0 then s = 0 end
    return s
  end
  return approach(s, target, out, out, dt)
end

local function canRun()
  if K.method ~= 'KEYBOARD' then return false, 'Input method v AC není Keyboard (teď: ' .. K.method .. ').' end
  if K.mouseSteer ~= 0 or K.mousePedals ~= 0 then return false, 'Vypněte v AC řízení a pedály myší.' end
  if not car.isUserControlled or car.isAIControlled then return false, 'Auto teď neřídíte vy.' end
  if sim.isReplayActive then return false, 'Běží replay.' end
  return true, ''
end

function script.update(dt)
  time = time + dt
  lastDt = dt
  local steerLock = car.steerLock > 1 and car.steerLock or 1

  local ok, why = canRun()
  if enabled and not ok then
    enabled = false
    status = why
    writeSafe()
  end

  if enabled and controls then
    -- 1. Compare what the car runs with what was written (after a short settle time).
    readByPhysics = controls:active()
    onTime = onTime + dt
    if onTime > SETTLE and readByPhysics then
      local eG = errOf(car.gas, wGas, pGas)
      local eB = errOf(car.brake, wBrake, pBrake)
      local eS = errOf(car.steer / steerLock, wSteer, pSteer)
      add(stats.gas, eG, GAS_TOL)
      add(stats.brake, eB, GAS_TOL)
      add(stats.steer, eS, STEER_TOL)
      local w, t = car.wheels, car.tractionType
      local spin = t == 1 and math.max(w[0].ndSlip, w[1].ndSlip) or t == 0 and math.max(w[2].ndSlip, w[3].ndSlip)
        or math.max(w[0].ndSlip, w[1].ndSlip, w[2].ndSlip, w[3].ndSlip)
      if spin > 1.2 and wGas > 0.3 then add(stats.gasSpin, eG, GAS_TOL) end
      if wBrake > 0.75 then add(stats.brakeHigh, eB, GAS_TOL) end
      -- Steering only tells something where the written value moved faster than AC's own keyboard filter would let it
      -- (else a filter after the override would pass it unchanged).
      local acRate = K.steerSpeed * speedFactor(math.abs(car.speedKmh))
      if car.speedKmh > 100 and math.abs(wSteer - pSteer) > 1.5 * acRate * lastStep then
        add(stats.steerFast, eS, STEER_TOL)
      end
    end

    -- 2. New values from the keys.
    local d = dt > 0.05 and 0.05 or dt
    lastStep = d
    pGas, pBrake, pSteer = wGas, wBrake, wSteer
    wGas = approach(wGas, down(K.gas) and S.maxGas / 100 or 0, S.gasRise / 100, GAS_FALL, d)
    wBrake = approach(wBrake, down(K.brake) and S.maxBrake / 100 or 0, S.brakeRise / 100, BRAKE_FALL, d)
    wSteer = steerStep(d, down(K.left), down(K.right))

    pcall(function ()
      controls.gas = wGas
      controls.brake = wBrake
      controls.steer = wSteer
      controls.handbrake = down(K.handbrake) and 1 or 0
      controls.clutch = 1
    end)
    setCombine(false)
    if not combineOk then
      status = 'Tato verze CSP nemá combineAxis (potřeba 0.3.0-preview125 nebo novější): AC by plyn a brzdu míchalo.'
      enabled = false
      writeSafe()
    end
  else
    readByPhysics = false
    -- follow the car so that switching on never jumps
    wGas, wBrake, wSteer = car.gas, car.brake, car.steer / steerLock
    pGas, pBrake, pSteer = wGas, wBrake, wSteer
  end

  if car.speedKmh > 1 then
    sampleTimer = sampleTimer + dt
    if sampleTimer >= 1 / RATE then
      sampleTimer = sampleTimer % (1 / RATE)
      sample(steerLock)
      dirty = true
    end
  end
  saveTimer = saveTimer + dt
  if saveTimer >= 10 then
    saveTimer = 0
    save()
  end
end

------------------------------------------------------------------------------------------------------------------------
-- Window

local GOOD = rgbm(0.45, 0.9, 0.45, 1)
local BAD = rgbm(1, 0.4, 0.35, 1)
local WARN = rgbm(1, 0.75, 0.2, 1)

local function verdictLine(name, s, tol, unitScale, unit)
  if s.n < 40 then
    ui.text(string.format('%s: málo dat (%d vzorků)', name, s.n))
    return
  end
  local share = s.bad / s.n
  local text = string.format('%s: %s  (%d vzorků, mimo toleranci %.1f %%, max odchylka %.1f %s)', name,
    share < 0.01 and 'SEDÍ' or 'NESEDÍ', s.n, share * 100, s.max * unitScale, unit)
  ui.textColored(text, share < 0.01 and GOOD or BAD)
end

local function slider(key, label, min, max)
  local v = ui.slider('##' .. key, S[key], min, max, label .. ': %.0f %%')
  v = math.floor(v + 0.5)
  if v ~= S[key] then S[key] = v end
end

function script.windowMain(dt)
  ui.pushFont(ui.Font.Small)
  local ok, why = canRun()
  if not ok then ui.textColored(why, WARN) end

  if enabled then
    if ui.button('Vypnout test (vrátit řízení AC)') then
      enabled = false
      writeSafe()
      save()
    end
  elseif ui.button('Zapnout test') then
    if ok and acquire() then
      enabled, onTime, status = true, 0, ''
    elseif not ok then
      status = why
    end
  end
  ui.sameLine(0, 8)
  if ui.button('Vynulovat měření') then resetStats() end

  if status ~= '' then ui.textColored(status, WARN) end
  if enabled then
    ui.text(readByPhysics and 'Fyzika AC čte přepis: ano' or 'Fyzika AC čte přepis: zatím ne')
  end

  ui.separator()
  verdictLine('Plyn', stats.gas, GAS_TOL, 100, '%')
  verdictLine('Plyn při prokluzu', stats.gasSpin, GAS_TOL, 100, '%')
  verdictLine('Brzda', stats.brake, GAS_TOL, 100, '%')
  verdictLine('Brzda nad 75 %', stats.brakeHigh, GAS_TOL, 100, '%')
  verdictLine('Řízení', stats.steer, STEER_TOL, car.steerLock, '°')
  verdictLine('Řízení rychleji než AC (nad 100 km/h)', stats.steerFast, STEER_TOL, car.steerLock, '°')
  if S.slowdown > 60 then
    ui.textColored('Pro test řízení nastavte zpomalení s rychlostí na 0 (jinak AC filtr nejde poznat).', WARN)
  end
  ui.text(string.format('Teď: plyn %.0f/%.0f %%, brzda %.0f/%.0f %%, volant %.0f/%.0f°  (zapsáno/v autě)',
    wGas * 100, car.gas * 100, wBrake * 100, car.brake * 100, wSteer * car.steerLock, car.steer))

  ui.separator()
  slider('maxGas', 'Plyn s klávesou', 20, 100)
  slider('gasRise', 'Náběh plynu za sekundu', 50, 600)
  slider('maxBrake', 'Brzda s klávesou', 20, 100)
  slider('brakeRise', 'Náběh brzdy za sekundu', 50, 1000)
  slider('steerRate', 'Rychlost řízení (AC = 100)', 30, 300)
  slider('slowdown', 'Zpomalení řízení s rychlostí (AC = 100)', 0, 100)
  ui.text(lastSaved >= 0 and 'Záznam uložen: Dokumenty\\Assetto Corsa\\logs\\keydrive\\kb-test.csv'
    or 'Záznam se ukládá každých 10 s jízdy do logs\\keydrive\\kb-test.csv')
  ui.popFont()
end
