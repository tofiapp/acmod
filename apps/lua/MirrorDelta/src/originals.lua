-- Turns off AC's own HUD elements that MirrorDelta replaces:
-- - overlay leaderboard (F9): ac.accessOverlayLeaderboardParams().displayMode = 0, as the official Unbound app does;
-- - system messages: CSP option gui.ini [HIDE] HIDE_SYSTEM_MESSAGES, applied with ac.applyLiveConfigEdit
--   (used by CSP's own modules; apps may not be allowed to, so it is tried under pcall and reported).
-- System messages are caught with ac.onMessage (as RGBControl does) and shown in the notification window.

local config = require('src/config')
local notify = require('src/notify')
local setupLine = require('src/setup_line')
local S = config.S

local M = {
  leaderboard = '-',        -- state for Diagnostika
  messages = '-',
}

local CHECK_EVERY = 1        -- s
local nextCheck = 0
local messagesApplied = nil  -- value of S.hideSystemMessages last applied
local LIVE_AGAIN = { 3, 10, 30 }   -- s after start (or a session change / file write): apply the live edit again
local liveStart, liveStep, liveSession = 0, 1, -1

-- CSP's own option (Content Manager > Custom Shaders Patch > GUI > Hide system messages) lives in the user's
-- cfg/extension/gui.ini. It is written the way the official ControllerTweaks app writes CSP user configs
-- (ac.INIConfig.load + setAndSave), only when the value differs; CSP reloads its configs when they change.
local function writeGuiIni(value)
  local path = ac.getFolder(ac.FolderID.ExtCfgUser) .. '/gui.ini'
  local ini = ac.INIConfig.load(path)
  if ini:get('HIDE', 'HIDE_SYSTEM_MESSAGES', 0) == value then return 'už nastaveno' end
  ini:setAndSave('HIDE', 'HIDE_SYSTEM_MESSAGES', value)
  return 'zapsáno do cfg/extension/gui.ini'
end

-- The live edit (what hid them in versions up to 1.12.0, also the penalty / track limits messages) is applied again
-- a few times after start, after the file was written (CSP reloads the file and may drop live edits) and after
-- every session change, so a reload cannot bring AC's message line back.
local function liveEdit(value)
  if type(ac.applyLiveConfigEdit) ~= 'function' then return false end
  return (pcall(ac.applyLiveConfigEdit, 'gui.ini', '[HIDE]\nHIDE_SYSTEM_MESSAGES=' .. value))
end

local function applyMessages(now)
  local value = S.hideSystemMessages and 1 or 0
  local sim = ac.getSim()
  local session = sim and sim.currentSessionIndex or -1
  if session ~= liveSession then
    liveSession, liveStart, liveStep = session, now, 1
  end
  if messagesApplied ~= S.hideSystemMessages then
    messagesApplied = S.hideSystemMessages
    local ok, result = pcall(writeGuiIni, value)
    local live = liveEdit(value)
    liveStart, liveStep = now, 1
    M.messages = (S.hideSystemMessages and 'skryté' or 'zobrazené') .. ' (' .. (ok and result or ('chyba: ' .. tostring(result)))
      .. (live and ', živě' or '') .. ')'
  elseif liveStep <= #LIVE_AGAIN and now - liveStart >= LIVE_AGAIN[liveStep] then
    liveStep = liveStep + 1
    liveEdit(value)
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

-- Rear view mirrors and flag displays of other apps (or AC, if it lists them as app windows) are hidden with
-- ac.accessAppWindow(name):setVisible(false) (lib_accessappwindow: works for original AC apps, Python and Lua apps).
-- Done a few seconds after start and after a session change; what was found is announced once.
M.hiddenWindows = '-'
local windowsAt, windowsSession, windowsAnnounced = 3, -1, false
local function looksLike(text, word)
  return text:find(word, 1, true) ~= nil and not text:find('mirrordelta', 1, true) and not text:find('config', 1, true)
end
local function hideOtherWindows()
  if not S.hideOriginalMirror and not S.hideOriginalFlags then M.hiddenWindows = 'vypnuto'; return end
  local found = {}
  for _, v in ipairs(ac.getAppWindows()) do
    local title = type(v.title) == 'string' and v.title or ''
    local text = (title .. ' ' .. tostring(v.name or '')):lower()
    if (S.hideOriginalMirror and looksLike(text, 'mirror')) or (S.hideOriginalFlags and looksLike(text, 'flag')) then
      local window = ac.accessAppWindow(v.name)
      if window then
        window:setVisible(false)
        found[#found + 1] = title ~= '' and title or tostring(v.name)
      end
    end
  end
  M.hiddenWindows = #found > 0 and table.concat(found, ', ') or 'nic (AC je nevede jako okna aplikací)'
  if not windowsAnnounced then
    windowsAnnounced = true
    notify.push(notify.SYSTEM, 'PŮVODNÍ ZRCÁTKO A VLAJKY', #found > 0 and ('skryto: ' .. M.hiddenWindows)
      or 'AC je nevede jako okna, aplikace je skrýt neumí')
  end
end

function M.update()
  local now = os.preciseClock()
  if now < nextCheck then return end
  nextCheck = now + CHECK_EVERY
  local ok, err = pcall(hideLeaderboard)
  if not ok then M.leaderboard = 'chyba: ' .. tostring(err) end
  ok, err = pcall(applyMessages, now)
  if not ok then M.messages = 'chyba: ' .. tostring(err) end
  local sim = ac.getSim()
  local session = sim and sim.currentSessionIndex or -1
  if session ~= windowsSession then windowsSession, windowsAt = session, now + 3 end
  if windowsAt and now >= windowsAt then
    windowsAt = nil
    ok, err = pcall(hideOtherWindows)
    if not ok then M.hiddenWindows = 'chyba: ' .. tostring(err) end
  end
end

-- AC writes its messages in English; they are translated phrase by phrase (whole words, any case, longest
-- phrases first), so the notifications stay Czech. Unknown words are kept. Runs once per message, cached.
local PHRASES = {
  { 'traction control', 'trakční kontrola' }, { 'stability control', 'stabilizace' },
  { 'brake balance', 'rozložení brzd' }, { 'brake bias', 'rozložení brzd' },
  { 'engine braking', 'brzdění motorem' }, { 'engine brake', 'brzdění motorem' },
  { 'automatic transmission', 'automatická převodovka' }, { 'automatic gearbox', 'automatická převodovka' },
  { 'auto shifter', 'automatická převodovka' }, { 'auto gearbox', 'automatická převodovka' },
  { 'auto clutch', 'automatická spojka' }, { 'auto blip', 'automatický meziplyn' },
  { 'ideal racing line', 'ideální stopa' }, { 'ideal line', 'ideální stopa' }, { 'racing line', 'ideální stopa' },
  { 'driver names', 'jména jezdců' }, { 'pit speed limiter', 'omezovač v boxech' },
  { 'pit limiter', 'omezovač v boxech' }, { 'speed limiter', 'omezovač rychlosti' },
  { 'fuel map', 'mapa paliva' }, { 'fuel mixture', 'směs paliva' }, { 'fuel', 'palivo' },
  { 'turbo boost', 'plnicí tlak turba' }, { 'mgu-k delivery', 'MGU-K výdej' }, { 'mgu-k recovery', 'MGU-K rekuperace' },
  { 'mgu-h mode', 'MGU-H režim' }, { 'drs available', 'DRS k dispozici' }, { 'drs enabled', 'DRS povoleno' },
  { 'drive through penalty', 'penalizace průjezdem boxy' }, { 'drive through', 'průjezd boxy' },
  { 'drive-through', 'průjezd boxy' }, { 'stop and go', 'stop and go' }, { 'stop & go', 'stop and go' },
  { 'penalty', 'penalizace' }, { 'penalties', 'penalizace' }, { 'disqualified', 'diskvalifikován' },
  { 'lap invalidated', 'kolo neplatné' }, { 'invalid lap', 'neplatné kolo' }, { 'lap invalid', 'kolo neplatné' },
  { 'track limits', 'limity trati' }, { 'cutting', 'řezání trati' }, { 'cut detected', 'řezání trati' },
  { 'cut', 'řezání trati' }, { 'slow down', 'zpomalte' }, { 'wrong way', 'špatný směr' },
  { 'yellow flag', 'žlutá vlajka' }, { 'blue flag', 'modrá vlajka' }, { 'black flag', 'černá vlajka' },
  { 'white flag', 'bílá vlajka' }, { 'checkered flag', 'cílová vlajka' }, { 'chequered flag', 'cílová vlajka' },
  { 'personal best', 'osobní rekord' }, { 'best lap', 'nejlepší kolo' }, { 'last lap', 'poslední kolo' },
  { 'has joined the server', 'se připojil' }, { 'joined the server', 'se připojil' }, { 'has joined', 'se připojil' },
  { 'joined', 'se připojil' }, { 'has left the server', 'se odpojil' }, { 'left the server', 'se odpojil' },
  { 'disconnected', 'odpojen' }, { 'connected', 'připojen' },
  { 'qualifying', 'kvalifikace' }, { 'qualify', 'kvalifikace' }, { 'practice', 'trénink' }, { 'race', 'závod' },
  { 'session', 'session' }, { 'starts in', 'začne za' }, { 'time left', 'zbývá' }, { 'remaining', 'zbývá' },
  { 'seconds', 's' }, { 'second', 's' }, { 'laps', 'kol' }, { 'lap', 'kolo' },
  { 'damage', 'poškození' }, { 'puncture', 'defekt' }, { 'tyres', 'pneumatiky' }, { 'tires', 'pneumatiky' },
  { 'headlights', 'světla' }, { 'lights', 'světla' }, { 'wipers', 'stěrače' },
  { 'replay', 'záznam' }, { 'paused', 'pozastaveno' }, { 'saved', 'uloženo' }, { 'screenshot', 'snímek obrazovky' },
  { 'camera', 'kamera' }, { 'level', 'úroveň' }, { 'mode', 'režim' }, { 'map', 'mapa' },
  { 'enabled', 'zapnuto' }, { 'disabled', 'vypnuto' }, { 'activated', 'zapnuto' }, { 'deactivated', 'vypnuto' },
  { 'on', 'zapnuto' }, { 'off', 'vypnuto' }, { 'abs', 'ABS' }, { 'tc', 'TC' },
}
table.sort(PHRASES, function (a, b) return #a[1] > #b[1] end)

local function isWordByte(c) return c ~= '' and c:match('[%w%-]') ~= nil end

-- Upper case including Czech letters (string.upper only knows ASCII).
local UPPER = { ['á'] = 'Á', ['č'] = 'Č', ['ď'] = 'Ď', ['é'] = 'É', ['ě'] = 'Ě', ['í'] = 'Í', ['ň'] = 'Ň',
  ['ó'] = 'Ó', ['ř'] = 'Ř', ['š'] = 'Š', ['ť'] = 'Ť', ['ú'] = 'Ú', ['ů'] = 'Ů', ['ý'] = 'Ý', ['ž'] = 'Ž' }
local CZ_LETTER = '[\195\196\197][\128-\191]'
function M.upper(str)
  return (str:upper():gsub(CZ_LETTER, UPPER))
end
function M.capitalize(str)
  local first = str:match('^' .. CZ_LETTER)
  if first then return (UPPER[first] or first) .. str:sub(3) end
  return str:sub(1, 1):upper() .. str:sub(2)
end

local translated, translatedCount = {}, 0
function M.translate(str)
  if str == '' then return str end
  local done = translated[str]
  if done then return done end
  local out = str
  for _, pair in ipairs(PHRASES) do
    local key, value = pair[1], pair[2]
    local lower = out:lower()
    local i, j = lower:find(key, 1, true)
    while i do
      if not isWordByte(lower:sub(i - 1, i - 1)) and not isWordByte(lower:sub(j + 1, j + 1)) then
        out = out:sub(1, i - 1) .. value .. out:sub(j + 1)
        lower = out:lower()
        i, j = lower:find(key, i + #value, true)
      else
        i, j = lower:find(key, j + 1, true)
      end
    end
  end
  out = M.capitalize(out)
  if translatedCount > 200 then translated, translatedCount = {}, 0 end
  translated[str], translatedCount = out, translatedCount + 1
  return out
end

-- Messages about car settings (AC's titles: 'ABS', 'TC', 'Auto Shifter', 'Turbo: ...', as CSP's split screen mode
-- checks them). Short words must stand alone, longer ones may be part of a word.
local SETTING_WORDS = { 'abs', 'tc', 'tc2', 'esc', 'ers', 'map' }
local SETTING_PARTS = { 'traction', 'stability', 'brake', 'bias', 'turbo', 'mgu', 'kers', 'limiter', 'shifter',
  'gearbox', 'clutch', 'blip', 'fuel', 'engine', 'boost', 'differential', 'diff ' }
function M.isSettingMessage(title)
  local t = title:lower()
  for _, w in ipairs(SETTING_WORDS) do
    if t:find('%f[%w]' .. w .. '%f[%W]') then return true end
  end
  for _, p in ipairs(SETTING_PARTS) do
    if t:find(p, 1, true) then return true end
  end
  return false
end

-- AC's system messages, in Czech. Car settings go to the one-line settings window (only when the app did not
-- read the change itself), penalties and everything else to the notifications, kept apart.
if type(ac.onMessage) == 'function' then
  pcall(ac.onMessage, function (title, description, kind)
    title = type(title) == 'string' and title or ''
    description = type(description) == 'string' and description or ''
    if title == '' and description == '' then return end
    local setting = kind ~= 'illegal' and M.isSettingMessage(title)
    title, description = M.upper(M.translate(title)), M.translate(description)
    if setting and S.setupLine then
      setupLine.acMessage(title, description)
      return
    end
    if not S.notifySystem then return end
    notify.push(kind == 'illegal' and notify.PENALTY or notify.SYSTEM, title, description)
  end)
end

return M
