-- Files in the app's ScriptConfig folder (ac.getFolder(ac.FolderID.ScriptConfig)):
--   car_<carId>.lon   per car profile: takeover method, preset, manual LED map, lights settings
--   presets.lon       user presets
-- Stored text is parsed with stringify.parse under pcall and sanitised, never executed as code.

local M = {}

function M.folder()
  return ac.getFolder(ac.FolderID.ScriptConfig)
end

local function fileOf(name)
  return M.folder() .. '/' .. name
end

local function carFile(carId)
  return fileOf('car_' .. tostring(carId):gsub('[^%w%-_%.]', '_') .. '.lon')
end

local function readFile(path)
  if not io.fileExists(path) then return nil end
  local raw = io.load(path)
  local ok, data = pcall(stringify.parse, raw)
  if ok and type(data) == 'table' then return data end
  -- unreadable (damaged, cut by a crash): keep a copy, so the next save does not lose it silently
  if type(raw) == 'string' and raw ~= '' then pcall(io.save, path .. '.bad', raw) end
  return nil
end

local function writeFile(path, data)
  io.createDir(M.folder())
  return io.save(path, stringify(data))
end

-- Plain data only (numbers, strings, booleans, nested tables), limited depth and size.
function M.plain(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == 'number' then return (v == v and v > -math.huge and v < math.huge) and v or nil end
  if t == 'string' then return #v <= 400 and v or v:sub(1, 400) end
  if t == 'boolean' then return v end
  if t ~= 'table' or depth > 6 then return nil end
  local out, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 400 then break end
    if type(k) == 'string' or type(k) == 'number' then out[k] = M.plain(x, depth + 1) end
  end
  return out
end

local function sanitiseMap(m)
  if type(m) ~= 'table' or type(m.leds) ~= 'table' then return nil end
  local out = { leds = {}, groups = {} }
  for i = 1, math.min(#m.leds, 64) do
    local e = m.leds[i]
    if type(e) == 'table' and type(e[1]) == 'string' and e[1] ~= '' then
      out.leds[#out.leds + 1] = { e[1]:sub(1, 120), math.max(1, math.min(8, math.floor(tonumber(e[2]) or 1))) }
    end
  end
  if type(m.groups) == 'table' then
    for i = 1, math.min(#m.groups, 8) do
      local g = m.groups[i]
      if type(g) == 'table' then
        local role = (g[2] == 'main' or g[2] == 'side' or g[2] == 'other') and g[2] or 'main'
        out.groups[i] = { type(g[1]) == 'string' and g[1]:sub(1, 40) or ('Skupina ' .. i), role }
      end
    end
  end
  if #out.leds == 0 then return nil end
  return out
end

local function sanitiseCar(t)
  local out = { v = 1 }
  if type(t) ~= 'table' then return out end
  local m = tonumber(t.method)
  if m and m >= 1 and m <= 3 then out.method = math.floor(m) end
  if type(t.preset) == 'string' and #t.preset <= 60 then out.preset = t.preset end
  out.map = sanitiseMap(t.map)
  if type(t.lights) == 'table' then out.lights = M.plain(t.lights) end
  return out
end
M.sanitiseCar = sanitiseCar

function M.loadCar(carId)
  return sanitiseCar(readFile(carFile(carId)))
end

function M.saveCar(carId, profile)
  if not carId or carId == '' then return false end
  return writeFile(carFile(carId), sanitiseCar(profile))
end

function M.deleteCar(carId)
  local path = carFile(carId)
  if io.fileExists(path) then io.deleteFile(path) end
end

-- User presets: { v = 1, nextId = n, list = { preset, ... } } (presets.lua sanitises each preset).
function M.loadPresets()
  local t = readFile(fileOf('presets.lon'))
  if type(t) ~= 'table' or type(t.list) ~= 'table' then return { v = 1, nextId = 1, list = {} } end
  return t
end

function M.savePresets(t)
  return writeFile(fileOf('presets.lon'), t)
end

-- Deletes every file this app saved (car profiles of the given ids and the presets).
function M.deleteAll(carIds)
  local p = fileOf('presets.lon')
  if io.fileExists(p) then io.deleteFile(p) end
  for i = 1, #(carIds or {}) do M.deleteCar(carIds[i]) end
  if type(io.scanDir) == 'function' then
    pcall(function ()
      for _, name in ipairs(io.scanDir(M.folder(), 'car_*.lon') or {}) do io.deleteFile(fileOf(name)) end
    end)
  end
end

return M
