-- Reference recorder: what AC itself does with keyboard steering, throttle and brake in the normal keyboard input
-- mode (KeyDrive not involved). The user said KeyDrive's steering "feels like a joystick, not like the keyboard";
-- AC's keyboard filter is not documented, so it is measured: keys held, the steering wheel angle AC makes of them
-- (car.steer) and the front wheel angle (wheels' look vectors), speed, pedals and slip, 40 Hz, last 120 s.
-- File: Documents/Assetto Corsa/logs/keydrive/ac-reference.csv, rewritten every 10 s while driving.

local M = {}

local RATE = 40
local SECONDS = 120
local SIZE = RATE * SECONDS
local SAVE_EVERY = 10

local COLUMNS = {
  { 't', '%.3f' }, { 'key_gas', '%d' }, { 'key_brake', '%d' }, { 'key_left', '%d' }, { 'key_right', '%d' },
  { 'car_gas', '%.3f' }, { 'car_brake', '%.3f' }, { 'steer_deg', '%.2f' }, { 'wheel_deg', '%.3f' },
  { 'speed_kmh', '%.2f' }, { 'gear', '%d' }, { 'rpm', '%.0f' }, { 'lat_g', '%.3f' }, { 'yaw_rate', '%.4f' },
  { 'nd_fl', '%.3f' }, { 'nd_fr', '%.3f' }, { 'nd_rl', '%.3f' }, { 'nd_rr', '%.3f' },
  { 'angle_fl', '%.2f' }, { 'angle_fr', '%.2f' }, { 'ratio_rl', '%.4f' }, { 'ratio_rr', '%.4f' },
}
local NC = #COLUMNS

local header, rowFormat
do
  local names, fmts = {}, {}
  for i, c in ipairs(COLUMNS) do names[i], fmts[i] = c[1], c[2] end
  header = table.concat(names, ',')
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
local dirty = false
local dir, path
local carState
local binds = { gas = 38, brake = 40, left = 37, right = 39 }
local meta = ''
local inputMethod = '?'
local status = ''
local lastSaved = -1
local lineMode, lineState = '', ''
local textTimer = 0
local WARN = rgbm(1, 0.75, 0.2, 1)

local function parse(cfg, section, key, fallback)
  local v = cfg:get(section, key, '')
  if type(v) == 'number' then return v end
  v = type(v) == 'string' and tonumber((v:match('^%s*(%S+)'))) or nil
  return v or fallback
end

local function readControls()
  local ok, cfg = pcall(ac.INIConfig.load, ac.getFolder(ac.FolderID.Cfg) .. '\\controls.ini')
  if not ok or not cfg then return end
  binds.gas = parse(cfg, 'KEYBOARD', 'GAS', binds.gas)
  binds.brake = parse(cfg, 'KEYBOARD', 'BRAKE', binds.brake)
  binds.left = parse(cfg, 'KEYBOARD', 'LEFT', binds.left)
  binds.right = parse(cfg, 'KEYBOARD', 'RIGHT', binds.right)
  inputMethod = tostring(cfg:get('HEADER', 'INPUT_METHOD', '?'))
  meta = string.format('# input=%s steering_speed=%s opposite=%s reset=%s combine=%s car=%s',
    inputMethod, tostring(cfg:get('KEYBOARD', 'STEERING_SPEED', '?')),
    tostring(cfg:get('KEYBOARD', 'STEERING_OPPOSITE_DIRECTION_SPEED', '?')),
    tostring(cfg:get('KEYBOARD', 'STEER_RESET_SPEED', '?')),
    tostring(cfg:get('ADVANCED', 'COMBINE_WITH_KEYBOARD_CONTROL', '?')), tostring(ac.getCarID(0)))
end

function M.init()
  carState = ac.getCar(0)
  local ok, logs = pcall(ac.getFolder, ac.FolderID.Logs)
  dir = (ok and type(logs) == 'string' and logs ~= '') and logs .. '/keydrive' or nil
  if dir then pcall(io.createDir, dir) end
  path = dir and dir .. '/ac-reference.csv' or nil
  readControls()
  pcall(ac.onControlSettingsChanged, readControls)
end

local function down(k) return k > 0 and ac.isKeyDown(k) end

local function wheelAngle(c)
  local l0, l1, look, side = c.wheels[0].look, c.wheels[1].look, c.look, c.side
  local x = (l0.x + l1.x) * side.x + (l0.y + l1.y) * side.y + (l0.z + l1.z) * side.z
  local z = (l0.x + l1.x) * look.x + (l0.y + l1.y) * look.y + (l0.z + l1.z) * look.z
  return math.deg(math.atan2(x, z))
end

local function sample()
  local c = carState
  head = head % SIZE + 1
  if count < SIZE then count = count + 1 end
  local v = buf
  v[1][head] = time
  v[2][head] = down(binds.gas) and 1 or 0
  v[3][head] = down(binds.brake) and 1 or 0
  v[4][head] = down(binds.left) and 1 or 0
  v[5][head] = down(binds.right) and 1 or 0
  v[6][head] = c.gas; v[7][head] = c.brake; v[8][head] = c.steer; v[9][head] = wheelAngle(c)
  v[10][head] = c.speedKmh; v[11][head] = c.gear; v[12][head] = c.rpm
  v[13][head] = c.acceleration.x; v[14][head] = c.localAngularVelocity.y
  local w = c.wheels
  v[15][head] = w[0].ndSlip; v[16][head] = w[1].ndSlip; v[17][head] = w[2].ndSlip; v[18][head] = w[3].ndSlip
  v[19][head] = w[0].slipAngle; v[20][head] = w[1].slipAngle; v[21][head] = w[2].slipRatio; v[22][head] = w[3].slipRatio
end

local row = {}
local function save()
  if not path or count == 0 or not dirty then return end
  local lines = { meta, header }
  local start = count < SIZE and 1 or head % SIZE + 1
  for n = 0, count - 1 do
    local i = (start - 1 + n) % SIZE + 1
    for k = 1, NC do row[k] = buf[k][i] end
    lines[#lines + 1] = string.format(rowFormat, unpack(row, 1, NC))
  end
  local ok = pcall(io.save, path, table.concat(lines, '\n'))
  if ok then lastSaved = time end
  dirty = false
end

function M.update(dt)
  if not carState or not M.ok then
    if M.ok == nil then
      M.ok = pcall(sample)
      if not M.ok then status = 'Záznam nefunguje: chybí data o autě.' return end
      head, count = 0, 0
    else
      return
    end
  end
  time = time + dt
  local moving = carState.speedKmh > 1
  if moving then
    sampleTimer = sampleTimer + dt
    if sampleTimer >= 1 / RATE then
      sampleTimer = sampleTimer % (1 / RATE)
      sample()
      dirty = true
    end
  end
  saveTimer = saveTimer + dt
  if saveTimer >= SAVE_EVERY then
    saveTimer = 0
    save()
  end
  textTimer = textTimer - dt
  if textTimer <= 0 then
    textTimer = 0.5
    lineMode = inputMethod == 'KEYBOARD' and 'Režim klávesnice: zaznamenávám, jak AC řídí z klávesnice.'
      or 'Ovládání v AC není Klávesnice (teď: ' .. inputMethod .. '). Pro záznam přepněte Input method na Keyboard.'
    lineState = string.format('Záznam: %d s jízdy, uloženo %s', math.floor(count / RATE), lastSaved >= 0 and 'ano' or 'zatím ne')
  end
end

function M.window()
  ui.pushFont(ui.Font.Small)
  if inputMethod ~= 'KEYBOARD' then ui.textColored(lineMode, WARN) else ui.text(lineMode) end
  ui.text(status ~= '' and status or lineState)
  ui.text('Soubor: Dokumenty\\Assetto Corsa\\logs\\keydrive\\ac-reference.csv')
  ui.popFont()
end

return M
