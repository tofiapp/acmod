-- Driving keys: AC's own keyboard binds from cfg/controls.ini, polled with ac.isKeyDown()
-- (same source Advanced Gamepad Assist uses). Re-read when AC's control settings change.

local M = { gas = 38, brake = 40, left = 37, right = 39 } -- defaults: arrow keys (VK codes)

local function bind(cfg, key, fallback)
  local v = tonumber(cfg:get('KEYBOARD', key, fallback)) or fallback
  return v
end

function M.read()
  local ok, cfg = pcall(ac.INIConfig.load, ac.getFolder(ac.FolderID.Cfg) .. '\\controls.ini')
  if not ok or not cfg then return end
  M.gas = bind(cfg, 'GAS', M.gas)
  M.brake = bind(cfg, 'BRAKE', M.brake)
  M.left = bind(cfg, 'LEFT', M.left)
  M.right = bind(cfg, 'RIGHT', M.right)
end

local function down(k)
  return k > 0 and ac.isKeyDown(k)
end

function M.gasDown() return down(M.gas) end
function M.brakeDown() return down(M.brake) end
function M.leftDown() return down(M.left) end
function M.rightDown() return down(M.right) end

return M
