-- Files in the app's ScriptConfig folder. Phase 3 keeps only the per car profile (takeover method).
-- Stored text is parsed with stringify.parse under pcall and sanitised, never executed as code.

local M = {}

function M.folder()
  return ac.getFolder(ac.FolderID.ScriptConfig)
end

local function carFile(carId)
  return M.folder() .. '/car_' .. tostring(carId):gsub('[^%w%-_%.]', '_') .. '.lon'
end

local function sanitise(t)
  local out = { v = 1 }
  if type(t) ~= 'table' then return out end
  local m = tonumber(t.method)
  if m and m >= 1 and m <= 3 then out.method = math.floor(m) end
  return out
end

function M.loadCar(carId)
  local path = carFile(carId)
  if not io.fileExists(path) then return sanitise(nil) end
  local ok, data = pcall(stringify.parse, io.load(path))
  return sanitise(ok and data or nil)
end

function M.saveCar(carId, profile)
  io.createDir(M.folder())
  return io.save(carFile(carId), stringify(sanitise(profile)))
end

function M.deleteCar(carId)
  local path = carFile(carId)
  if io.fileExists(path) then io.deleteFile(path) end
end

return M
