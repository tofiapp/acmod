-- Driving log for tuning (render thread; io.save is used the same way by CSP's own Mobile gamepad script).
--
-- Keeps the last 60 s at 40 Hz in preallocated ring buffers: key inputs, what KeyDrive sent, what the car ran,
-- slip of every wheel, body slide, collisions, and event flags. Files go to Documents/Assetto Corsa/logs/keydrive
-- (survives reinstalling the script; falls back to the script folder if that cannot be written):
--   keydrive-log.csv               rolling log, rewritten every 10 s while driving
--   keydrive-incident-N.csv        written 3 s after a spin, a crash or leaving the track (N = 1..5, rotating),
--                                  so the moment is kept even if the driver keeps going
-- Event flags (column `events`): WSPIN driven wheels over the slip target by 30 %, SLIDE body slip angle > 10 deg,
-- SPIN > 30 deg, CRASH collision, OFF two or more wheels off the track, TC traction limiter reducing the throttle,
-- LOCK a wheel over 1.5x the brake slip target while braking, ABS brake limiter reducing the brake,
-- STEER grip window limiting the steering, CS countersteer assist active, UNDER front slip angle > 1.3x the peak.

local M = {}

local RATE = 40
local SECONDS = 60
local SIZE = RATE * SECONDS
local SAVE_EVERY = 10
local INCIDENT_DELAY = 3
local INCIDENT_FILES = 5
local INCIDENT_COOLDOWN = 10 -- s after an incident file before the next incident can start

local EV_WSPIN, EV_SLIDE, EV_SPIN, EV_CRASH, EV_OFF, EV_TC, EV_LOCK, EV_ABS = 1, 2, 4, 8, 16, 32, 64, 128
local EV_STEER, EV_CS, EV_UNDER = 256, 512, 1024
local EVENT_NAMES = { { EV_WSPIN, 'WSPIN' }, { EV_SLIDE, 'SLIDE' }, { EV_SPIN, 'SPIN' }, { EV_CRASH, 'CRASH' },
  { EV_OFF, 'OFF' }, { EV_TC, 'TC' }, { EV_LOCK, 'LOCK' }, { EV_ABS, 'ABS' }, { EV_STEER, 'STEER' }, { EV_CS, 'CS' },
  { EV_UNDER, 'UNDER' } }

-- name, format; values are filled in `sample` in this order
local COLUMNS = {
  { 't', '%.3f' },
  { 'key_gas', '%d' }, { 'key_brake', '%d' }, { 'key_left', '%d' }, { 'key_right', '%d' },
  { 'gas_request', '%.3f' }, { 'gas_out', '%.3f' }, { 'car_gas', '%.3f' }, { 'tc_cap', '%.3f' }, { 'tc_state', '%d' },
  { 'drive_slip_nd', '%.3f' }, { 'drive_slip_ratio', '%.3f' }, { 'slip_target', '%.2f' },
  { 'brake_out', '%.3f' }, { 'car_brake', '%.3f' },
  { 'brake_request', '%.3f' }, { 'brake_k', '%.3f' }, { 'brake_slip', '%.3f' }, { 'brake_memory', '%.3f' },
  { 'brake_state', '%d' },
  { 'brake_peak_ratio', '%.3f' }, { 'tc_memory', '%.3f' },
  { 'steer_out', '%.3f' }, { 'steer_deg', '%.1f' },
  { 'steer_request', '%.3f' }, { 'steer_lo', '%.3f' }, { 'steer_hi', '%.3f' }, { 'front_alpha', '%.2f' },
  { 'alpha_peak', '%.2f' }, { 'beta_f', '%.2f' }, { 'deg_per_unit', '%.2f' }, { 'steer_state', '%d' },
  { 'speed_kmh', '%.1f' }, { 'gear', '%d' }, { 'rpm', '%.0f' },
  { 'lat_g', '%.2f' }, { 'lon_g', '%.2f' }, { 'yaw_rate', '%.3f' }, { 'body_slip_deg', '%.1f' },
  { 'nd_fl', '%.2f' }, { 'nd_fr', '%.2f' }, { 'nd_rl', '%.2f' }, { 'nd_rr', '%.2f' },
  { 'ratio_fl', '%.3f' }, { 'ratio_fr', '%.3f' }, { 'ratio_rl', '%.3f' }, { 'ratio_rr', '%.3f' },
  { 'angle_fl', '%.1f' }, { 'angle_fr', '%.1f' }, { 'angle_rl', '%.1f' }, { 'angle_rr', '%.1f' },
  { 'collision_depth', '%.3f' }, { 'wheels_out', '%d' },
  { 'in_gas', '%.3f' }, { 'in_brake', '%.3f' }, { 'in_steer', '%.3f' }, { 'steer_from_ac', '%d' }, { 'ac_votes', '%d' },
  { 'tc_mode', '%d' }, { 'tc_sx', '%.3f' }, { 'tc_lateral', '%.3f' }, { 'tc_target_x', '%.3f' }, { 'tc_slip_rate', '%.2f' },
  { 'tc_kappa_peak', '%.4f' },
  { 'events', '%d' },
}
local NC = #COLUMNS
local EVENTS_COL = NC

local header, rowFormat
local carId = '?'
local lastLive = nil
do
  local names, fmts = {}, {}
  for i, c in ipairs(COLUMNS) do names[i], fmts[i] = c[1], c[2] end
  header = table.concat(names, ',')
  fmts[NC] = '%s'
  rowFormat = table.concat(fmts, ',')
end

local buf = {}
for i = 1, NC do
  local col = {}
  for j = 1, SIZE do col[j] = 0 end
  buf[i] = col
end

local head, count = 0, 0
local time, sampleTimer, saveTimer = 0, 0, 0
local incidentTimer, incidentIndex, incidentReason, lastIncidentTime = -1, 0, 0, -1e9
local dirty = false
local dir, fallbackDir

M.lastIncident = ''
M.error = nil
M.folderLabel = ''
M.statusText = ''

function M.init(scriptFolder)
  fallbackDir = scriptFolder
  local ok, logs = pcall(ac.getFolder, ac.FolderID.Logs)
  if ok and type(logs) == 'string' and logs ~= '' then
    dir = logs .. '/keydrive'
    pcall(io.createDir, dir)
    M.folderLabel = 'Dokumenty\\Assetto Corsa\\logs\\keydrive'
  else
    dir = scriptFolder
    M.folderLabel = 'složka skriptu KeyDrive'
  end
  M.statusText = 'záznam běží: keydrive-log.csv v ' .. M.folderLabel
  local okC, id = pcall(ac.getCarID, 0)
  carId = okC and type(id) == 'string' and id or '?'
end

local function bit(x, b) return math.floor(x / b) % 2 == 1 end

local function eventText(flags)
  if flags == 0 then return '' end
  local s = ''
  for _, e in ipairs(EVENT_NAMES) do
    if bit(flags, e[1]) then s = s == '' and e[2] or s .. '|' .. e[2] end
  end
  return s
end

local function sample(live, c)
  head = head % SIZE + 1
  if count < SIZE then count = count + 1 end
  local m = live.keyMask
  local w0, w1, w2, w3 = c.wheels[0], c.wheels[1], c.wheels[2], c.wheels[3]
  local lv = c.localVelocity
  local bodySlip = math.abs(lv.z) > 1 and math.deg(math.atan2(lv.x, math.abs(lv.z))) or 0
  local out = c.wheelsOutside

  local flags = 0
  if live.slip > live.targetSlip * 1.3 and live.gasRequest > 0.05 then flags = flags + EV_WSPIN end
  if c.speedKmh > 30 and math.abs(bodySlip) > 10 then flags = flags + EV_SLIDE end
  if c.speedKmh > 20 and math.abs(bodySlip) > 30 then flags = flags + EV_SPIN end
  if c.collisionDepth > 0 and c.speedKmh > 5 then flags = flags + EV_CRASH end
  if out >= 2 then flags = flags + EV_OFF end
  if live.tcState == 4 then flags = flags + EV_TC end
  if live.brakeRequest > 0.05 and live.brakeSlip > live.brakeTargetSlip * 1.5 then flags = flags + EV_LOCK end
  if live.brakeState == 4 then flags = flags + EV_ABS end
  if live.steerState == 3 then flags = flags + EV_STEER end
  if live.steerState == 4 then flags = flags + EV_CS end
  if c.speedKmh > 30 and math.abs(live.frontAlpha) > 1.3 * live.alphaPeak then flags = flags + EV_UNDER end

  local v = buf
  v[1][head] = time
  v[2][head] = m % 2; v[3][head] = bit(m, 2) and 1 or 0; v[4][head] = bit(m, 4) and 1 or 0; v[5][head] = bit(m, 8) and 1 or 0
  v[6][head] = live.gasRequest; v[7][head] = live.outGas; v[8][head] = c.gas; v[9][head] = live.tcLimit
  v[10][head] = live.tcState
  v[11][head] = live.slip; v[12][head] = live.slipRatio; v[13][head] = live.targetSlip
  v[14][head] = live.outBrake; v[15][head] = c.brake
  v[16][head] = live.brakeRequest; v[17][head] = live.brakeK; v[18][head] = live.brakeSlip
  v[19][head] = live.brakeMemory; v[20][head] = live.brakeState
  v[21][head] = live.brakePeakRatio; v[22][head] = live.tcMemory
  v[23][head] = live.outSteer; v[24][head] = c.steer
  v[25][head] = live.steerRequest; v[26][head] = live.steerLo; v[27][head] = live.steerHi
  v[28][head] = live.frontAlpha; v[29][head] = live.alphaPeak; v[30][head] = live.betaF
  v[31][head] = live.degPerUnit; v[32][head] = live.steerState
  v[33][head] = c.speedKmh; v[34][head] = c.gear; v[35][head] = c.rpm
  v[36][head] = live.gx; v[37][head] = c.acceleration.z; v[38][head] = c.localAngularVelocity.y; v[39][head] = bodySlip
  v[40][head] = w0.ndSlip; v[41][head] = w1.ndSlip; v[42][head] = w2.ndSlip; v[43][head] = w3.ndSlip
  v[44][head] = w0.slipRatio; v[45][head] = w1.slipRatio; v[46][head] = w2.slipRatio; v[47][head] = w3.slipRatio
  v[48][head] = w0.slipAngle; v[49][head] = w1.slipAngle; v[50][head] = w2.slipAngle; v[51][head] = w3.slipAngle
  v[52][head] = c.collisionDepth; v[53][head] = out
  v[54][head] = live.inGas; v[55][head] = live.inBrake; v[56][head] = live.inSteer
  v[57][head] = live.steerFromAC and 1 or 0; v[58][head] = live.acSteerVotes
  v[59][head] = live.tractionMode; v[60][head] = live.tcSx; v[61][head] = live.tcLateral
  v[62][head] = live.tcTargetX; v[63][head] = live.tcSlipRate; v[64][head] = live.tcKappaPeak
  v[EVENTS_COL][head] = flags
  return flags
end

local row = {}
local function write(path)
  if not dir or count == 0 then return end
  -- first line: '#' meta (which car, traction mode and target), like ac-reference.csv
  local L = lastLive
  local lines = { string.format('# car=%s tc_mode=%d slip_target=%.3f', carId, L and L.tractionMode or 0,
    L and L.targetSlip or 0), header }
  local start = count < SIZE and 1 or head % SIZE + 1
  for n = 0, count - 1 do
    local i = (start - 1 + n) % SIZE + 1
    for k = 1, NC do row[k] = buf[k][i] end
    row[EVENTS_COL] = eventText(row[EVENTS_COL])
    lines[#lines + 1] = string.format(rowFormat, unpack(row, 1, NC))
  end
  local data = table.concat(lines, '\n')
  local ok, res = pcall(io.save, dir .. '/' .. path, data)
  if (not ok or res == false) and dir ~= fallbackDir then
    dir = fallbackDir
    M.folderLabel = 'složka skriptu KeyDrive'
    M.statusText = 'záznam běží: keydrive-log.csv v ' .. M.folderLabel
    pcall(io.save, dir .. '/' .. path, data)
  end
end

function M.save()
  if dirty then write('keydrive-log.csv') end
  dirty = false
end

-- Call every render frame. Nothing is recorded while the car stands still with no keys pressed.
function M.update(dt, live, carState)
  lastLive = live
  if M.error then return end
  time = time + dt
  if incidentTimer >= 0 then
    incidentTimer = incidentTimer + dt
    if incidentTimer >= INCIDENT_DELAY then
      incidentIndex = incidentIndex % INCIDENT_FILES + 1
      local name = string.format('keydrive-incident-%d.csv', incidentIndex)
      write(name)
      M.lastIncident = string.format('%s (%s)', name, eventText(incidentReason))
      incidentTimer = -1
      lastIncidentTime = time
    end
  end

  local idle = carState.speedKmh < 1 and live.keyMask == 0
  if idle then return end
  sampleTimer = sampleTimer + dt
  if sampleTimer >= 1 / RATE then
    sampleTimer = sampleTimer % (1 / RATE)
    local ok, flags = pcall(sample, live, carState)
    if not ok then
      M.error = tostring(flags) -- a car state field is missing: stop recording, show why
      return
    end
    dirty = true
    local serious = (bit(flags, EV_SPIN) and EV_SPIN or 0) + (bit(flags, EV_CRASH) and EV_CRASH or 0)
      + (bit(flags, EV_OFF) and EV_OFF or 0)
    if serious > 0 and incidentTimer < 0 and time - lastIncidentTime > INCIDENT_COOLDOWN then
      incidentTimer = 0
      incidentReason = serious
    end
  end
  saveTimer = saveTimer + dt
  if saveTimer >= SAVE_EVERY then
    saveTimer = 0
    M.save()
  end
end

M.header = header
return M
