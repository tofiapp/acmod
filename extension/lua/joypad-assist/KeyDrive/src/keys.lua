-- Keyboard binds from AC's cfg/controls.ini, polled with ac.isKeyDown(). Re-read when AC's control settings change.
-- Driving keys live in [KEYBOARD] GAS/BRAKE/LEFT/RIGHT; buttons in their own sections ([GEARUP] KEY=...).
-- Content Manager writes the values as hex ("0x26"), so they are parsed with tonumber().
-- In gamepad input mode AC does not pass the keyboard gear buttons on, so KeyDrive forwards them itself.

local M = {
  gas = 38, brake = 40, left = 37, right = 39, -- defaults: arrow keys (VK codes)
  gearUp = -1, gearDown = -1, handbrake = -1,
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
end

local function down(k)
  return k > 0 and ac.isKeyDown(k)
end

function M.gasDown() return down(M.gas) end
function M.brakeDown() return down(M.brake) end
function M.leftDown() return down(M.left) end
function M.rightDown() return down(M.right) end
function M.gearUpDown() return down(M.gearUp) end
function M.gearDownDown() return down(M.gearDown) end
function M.handbrakeDown() return down(M.handbrake) end

return M
