-- Persistent lap data, one file per car + track + layout combination.

local M = {}

local fileName = nil

local function sanitize(value)
  return (tostring(value or 'unknown'):gsub('[^%w%-%._]', '_'))
end

function M.folder()
  return ac.getFolder(ac.FolderID.ScriptConfig)
end

function M.fileName()
  if not fileName then
    -- getTrackFullID includes the layout, for example "ks_nurburgring_layout_gp"
    fileName = M.folder() .. '/' .. sanitize(ac.getCarID(0)) .. '__' .. sanitize(ac.getTrackFullID('_')) .. '.lon'
  end
  return fileName
end

function M.load()
  local path = M.fileName()
  if not io.fileExists(path) then return nil end
  local ok, data = pcall(stringify.parse, io.load(path))
  if ok and type(data) == 'table' and data.version == 1 then return data end
  ac.log('MirrorDelta: could not read ' .. path)
  return nil
end

function M.save(data)
  io.createDir(M.folder())
  if not io.save(M.fileName(), stringify(data)) then
    ac.log('MirrorDelta: could not write ' .. M.fileName())
  end
end

function M.delete()
  local path = M.fileName()
  if io.fileExists(path) then io.deleteFile(path) end
end

return M
