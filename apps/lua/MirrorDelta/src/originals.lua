-- Turns off AC's own HUD elements that MirrorDelta replaces:
-- - overlay leaderboard (F9): ac.accessOverlayLeaderboardParams().displayMode = 0, as the official Unbound app does;
-- - system messages: CSP option gui.ini [HIDE] HIDE_SYSTEM_MESSAGES, applied with ac.applyLiveConfigEdit
--   (used by CSP's own modules; apps may not be allowed to, so it is tried under pcall and reported).
-- System messages are caught with ac.onMessage (as RGBControl does) and shown in the notification window.

local config = require('src/config')
local notify = require('src/notify')
local S = config.S

local M = {
  leaderboard = '-',        -- state for Diagnostika
  messages = '-',
}

local CHECK_EVERY = 1        -- s
local nextCheck = 0
local messagesApplied = nil  -- value of S.hideSystemMessages last applied

local function applyMessages()
  if messagesApplied == S.hideSystemMessages then return end
  messagesApplied = S.hideSystemMessages
  if type(ac.applyLiveConfigEdit) ~= 'function' then
    M.messages = 'CSP to aplikacím nedovoluje, zapněte ručně (viz README)'
    return
  end
  local ok, err = pcall(ac.applyLiveConfigEdit, 'gui.ini',
    '[HIDE]\nHIDE_SYSTEM_MESSAGES=' .. (S.hideSystemMessages and '1' or '0'))
  if ok then
    M.messages = S.hideSystemMessages and 'skryté' or 'zobrazené'
  else
    M.messages = 'nejde zapnout z aplikace: ' .. tostring(err)
  end
end

local function hideLeaderboard()
  if not S.hideOverlayLeaderboard then
    M.leaderboard = 'ponechané'
    return
  end
  if type(ac.accessOverlayLeaderboardParams) ~= 'function' then
    M.leaderboard = 'tato verze CSP to neumí'
    return
  end
  local params = ac.accessOverlayLeaderboardParams()
  if not params then
    M.leaderboard = 'nedostupné'
    return
  end
  if params.displayMode ~= 0 then params.displayMode = 0 end
  M.leaderboard = 'vypnuté'
end

function M.update()
  local now = os.preciseClock()
  if now < nextCheck then return end
  nextCheck = now + CHECK_EVERY
  local ok, err = pcall(hideLeaderboard)
  if not ok then M.leaderboard = 'chyba: ' .. tostring(err) end
  ok, err = pcall(applyMessages)
  if not ok then M.messages = 'chyba: ' .. tostring(err) end
end

-- AC's system messages (ABS, TC, penalties, joins...) go to the notification window instead.
if type(ac.onMessage) == 'function' then
  pcall(ac.onMessage, function (title, description, kind)
    if not S.notifySystem then return end
    title = type(title) == 'string' and title or ''
    description = type(description) == 'string' and description or ''
    if title == '' and description == '' then return end
    notify.push(kind == 'illegal' and notify.PENALTY or notify.SYSTEM, title, description)
  end)
end

return M
