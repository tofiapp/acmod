-- Keyboard binds from AC's cfg/controls.ini, polled with ac.isKeyDown(). Re-read when AC's control settings change.
-- Driving keys live in [KEYBOARD] GAS/BRAKE/LEFT/RIGHT; buttons in their own sections ([GEARUP] KEY=...).
-- Content Manager writes the values as hex ("0x26"), so they are parsed with tonumber().
-- In gamepad input mode AC does not pass the keyboard gear buttons on, so KeyDrive forwards them itself.

local M = {
  gas = 38, brake = 40, left = 37, right = 39, -- defaults: arrow keys (VK codes)
  gearUp = -1, gearDown = -1, handbrake = -1,
  -- AC's own keyboard steering rates (per second, full lock = 1), as set in AC / Content Manager controls
  steerSpeed = 1.75, steerOppositeSpeed = 2.5, steerResetSpeed = 1.8,
}

local function parse(cfg, section, key, fallback)
  local v = cfg:get(section, key, '')
  if type(v) == 'number' then return v end
  v = type(v) == 'string' and tonumber((v:match('^%s*(%S+)'))) or nil
  return v or fallback
end

function M.read()
  local ok, cfg = pcall(ac.INIConfig.load, ac.getFolder(ac.FolderID.Cfg) .. '\\controls.ini')
  if not ok or not cfg then return end
  M.gas = parse(cfg, 'KEYBOARD', 'GAS', M.gas)
  M.brake = parse(cfg, 'KEYBOARD', 'BRAKE', M.brake)
  M.left = parse(cfg, 'KEYBOARD', 'LEFT', M.left)
  M.right = parse(cfg, 'KEYBOARD', 'RIGHT', M.right)
  M.gearUp = parse(cfg, 'GEARUP', 'KEY', -1)
  M.gearDown = parse(cfg, 'GEARDN', 'KEY', -1)
  M.handbrake = parse(cfg, 'HANDBRAKE', 'KEY', -1)
  M.steerSpeed = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEERING_SPEED', 1.75))
  M.steerOppositeSpeed = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEERING_OPPOSITE_DIRECTION_SPEED', 2.5))
  M.steerResetSpeed = math.max(0.1, parse(cfg, 'KEYBOARD', 'STEER_RESET_SPEED', 1.8))
end

local function down(k)
  return k > 0 and ac.isKeyDown(k)
end

-- KeyDrive's own key from settings.ini: a letter or digit ("X"), F1-F12, or a key code ("0x58", "88").
-- Returns the VK code, or -1 for empty / "0" / unknown text (no key).
function M.parseKey(v)
  if type(v) == 'number' then return v > 0 and math.floor(v) or -1 end
  if type(v) ~= 'string' then return -1 end
  local s = v:match('^%s*(%S*)'):upper()
  if s == '' or tonumber(s) == 0 then return -1 end -- "0" means no key, not the digit key (that one is 0x30)
  if s:match('^[A-Z0-9]$') then return s:byte() end
  local f = tonumber(s:match('^F(%d%d?)$'))
  if f and f >= 1 and f <= 12 then return 111 + f end
  local n = tonumber(s)
  return n and n > 0 and math.floor(n) or -1
end

-- The traction switch key. assist.lua takes the press edge of the raw key and ignores it when Ctrl or Alt is held
-- at that moment (some other shortcut), so releasing Ctrl first while X is still down does not toggle either.
M.tractionKey = -1
function M.tractionKeyDown() return down(M.tractionKey) end
function M.modifierDown() return ac.isKeyDown(17) or ac.isKeyDown(18) end

-- True when `k` is one of AC's driving or button keys read above (a switch there would fire while driving).
function M.isDrivingKey(k)
  return k == M.gas or k == M.brake or k == M.left or k == M.right or k == M.gearUp or k == M.gearDown
    or k == M.handbrake
end

function M.gasDown() return down(M.gas) end
function M.brakeDown() return down(M.brake) end
function M.leftDown() return down(M.left) end
function M.rightDown() return down(M.right) end
function M.gearUpDown() return down(M.gearUp) end
function M.gearDownDown() return down(M.gearDown) end
function M.handbrakeDown() return down(M.handbrake) end

return M
