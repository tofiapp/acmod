-- Error boundary. The first error in the logic stops all scene work, runs the restorers (so the car gets its own
-- LEDs back) and keeps the message with a traceback for the window, until the user presses "Zkusit znovu".

local M = { halted = false, error = nil, where = nil, trace = nil, uiError = nil }

local restorers = {}
local failing = ''

function M.onHalt(fn)
  restorers[#restorers + 1] = fn
end

local function handler(err)
  return { msg = tostring(err), trace = debug.traceback('', 2) }
end

function M.fail(where, err, trace)
  if M.halted then return end
  M.halted, M.error, M.where, M.trace = true, tostring(err), where, trace
  for i = 1, #restorers do pcall(restorers[i]) end
end

-- Runs fn(a, b) unless halted; returns true when it ran without an error.
function M.run(where, fn, a, b)
  if M.halted then return false end
  failing = where
  local ok, res = xpcall(fn, handler, a, b)
  if not ok then
    M.fail(where, type(res) == 'table' and res.msg or res, type(res) == 'table' and res.trace or nil)
  end
  return ok
end

-- Window drawing: an error there is shown, but does not stop the LED logic.
function M.ui(fn, a)
  local ok, res = xpcall(fn, handler, a)
  if not ok then M.uiError = type(res) == 'table' and res.msg or tostring(res) end
  return ok
end

function M.retry()
  M.halted, M.error, M.where, M.trace, M.uiError = false, nil, nil, nil, nil
end

return M
