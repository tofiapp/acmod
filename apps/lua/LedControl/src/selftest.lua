-- Self-test in the game (Diody → Diagnostika → Self-test): goes through every scenario of the car's preset and every
-- display page / takeover screen, a few seconds each, and writes an OK / FAIL / SKIP protocol that can be copied as
-- text. Per scenario (shown with Test, also when it is switched off):
--   * the engine must make it win in at least one LED group (else SKIP: unavailable on this car or covered by a
--     scenario above it, with the reason),
--   * every LED of the groups it wins must hold the wanted colour: read back with getMaterialPropertyValue
--     (shadow: the copy, the original hidden; direct: the LED's material; redraw draws in the render pass and cannot
--     be read: SKIP),
--   * twice per scenario, so a game that writes over the LEDs later in the frame shows as FAIL.
-- Display: each page and takeover screen of a taken display must be painted (counted paints, no error); what the
-- texture shows cannot be read back, so the protocol asks to check it by eye.
-- The protocol starts with the versions (LuaJIT, CSP, LedControl), car, method and what was found.

local csp = require('src/csp')
local ac = csp.ac
local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local presets = require('src/presets')
local engine = require('src/engine')
local display = require('src/display')
local pages = require('src/display_pages')

local S = config.S
local M = { running = false, done = false, lines = {}, ok = 0, fail = 0, skip = 0, step = 0, total = 0, version = 0,
  current = '' }

local STEP_TIME = 2.0        -- seconds per scenario
local CHECK_AT = { 0.6, 1.5 } -- two read-backs per scenario
local PAGE_TIME = 1.2

local steps = {}
local stepIndex, stepTime, checksDone = 0, 0, 0
local stepFail, stepOk, stepWhy, stepPainted = 0, 0, nil, 0
local savedPage, savedMode = 1, 0
local checkDue = nil

local function bump() M.version = M.version + 1 end
local function line(kind, text)
  M.lines[#M.lines + 1] = string.format('%-4s %s', kind, text)
  if kind == 'OK' then M.ok = M.ok + 1 elseif kind == 'FAIL' then M.fail = M.fail + 1
  elseif kind == 'SKIP' then M.skip = M.skip + 1 end
  bump()
end

local function header()
  local okV, v = pcall(ac.getPatchVersion)
  local okC, c = pcall(ac.getPatchVersionCode)
  M.lines[#M.lines + 1] = 'LedControl self-test'
  M.lines[#M.lines + 1] = string.format('LedControl %s | LuaJIT: %s | CSP: %s (%s)', require('src/diag').VERSION,
    tostring(csp.jitVersion), okV and tostring(v) or '?', okC and tostring(c) or '?')
  M.lines[#M.lines + 1] = string.format('Auto: %s | stav: %s | metoda: %s | diod: %d | skupin: %d | preset: %s',
    tostring(runtime.carId), tostring(runtime.state), takeover.NAMES[takeover.method] or 'žádná', runtime.n or 0,
    runtime.layout and #runtime.layout.groups or 0, tostring(runtime.presetId))
  M.lines[#M.lines + 1] = string.format('Displej: nalezeno %d, převzato %d', #display.displays, display.nTaken)
end

-- Builds the list of steps for the car as it is now.
local function plan()
  steps = {}
  if runtime.state == 'run' and runtime.compiled then
    local list = presets.effective(runtime.preset())
    for i = 1, #list do steps[#steps + 1] = { kind = 'scenario', id = list[i].id, name = tostring(list[i].name) } end
  end
  if display.nTaken > 0 then
    for p = 1, #pages.PAGES do steps[#steps + 1] = { kind = 'page', page = p, name = 'Displej: stránka ' .. pages.PAGES[p].name } end
    for o = 1, #pages.OVERLAYS do
      local ov = pages.OVERLAYS[o]
      steps[#steps + 1] = { kind = 'overlay', scenario = ov.scenario, name = 'Displej: převzetí ' .. ov.title }
    end
  end
  M.total = #steps
end

function M.start()
  M.lines, M.ok, M.fail, M.skip, M.done = {}, 0, 0, 0, false
  header()
  if runtime.state ~= 'run' and display.nTaken == 0 then
    line('SKIP', 'diody neběží (' .. tostring(runtime.STATES[runtime.state] or runtime.state) .. ') a displej není převzatý')
    M.done = true
    return
  end
  if S.testMode ~= runtime.NORMAL then runtime.setMode(runtime.NORMAL) end
  plan()
  savedPage = display.page
  M.running, stepIndex, stepTime = true, 0, STEP_TIME
  bump()
end

local function finish()
  M.running, M.done = false, true
  display.forced = nil
  checkDue = nil
  if runtime.compiled then runtime.compiled.solo = nil end
  display.setPage(savedPage)
  M.current = ''
  M.lines[#M.lines + 1] = string.format('Výsledek: OK %d, FAIL %d, SKIP %d', M.ok, M.fail, M.skip)
  if display.nTaken > 0 then
    M.lines[#M.lines + 1] = 'Obsah displeje nejde přečíst zpět: zkontrolujte okem, že stránky a převzetí byly vidět.'
  end
  bump()
end

function M.stop()
  if not M.running then return end
  line('SKIP', 'zastaveno ručně')
  finish()
end

local function beginStep(s)
  stepTime, checksDone, stepFail, stepOk, stepWhy, stepPainted = 0, 0, 0, 0, nil, display.paints
  M.current = s.name
  display.forced = nil
  if s.kind ~= 'scenario' and runtime.compiled then runtime.compiled.solo = nil end
  if s.kind == 'scenario' then
    runtime.testScenario(s.id, STEP_TIME)
  elseif s.kind == 'page' then
    display.setPage(s.page)
    display.invalidate()
  else
    display.forced = s.scenario
    display.invalidate()
  end
  bump()
end

-- one read-back of the LEDs the scenario paints
local function checkScenario(s)
  local C = runtime.compiled
  if not C then return end
  local sc = engine.find(C, s.id)
  if not sc then stepWhy = 'scénář není v presetu'; return end
  local groups = 0
  for gi = 1, #C.groups do
    local g = C.groups[gi]
    if g.activeId == s.id then
      groups = groups + 1
      for k = 1, g.n do
        local i = g.ids[k]
        local status, detail = takeover.readback(i)
        if status == 'ok' then stepOk = stepOk + 1
        elseif status == 'wrong' then
          stepFail = stepFail + 1
          if not stepWhy then stepWhy = string.format('%s, dioda %d: %s', g.name, k, tostring(detail)) end
        elseif status == 'unread' then stepWhy = stepWhy or 'unread'
        end
      end
    end
  end
  if groups == 0 and stepOk == 0 and stepFail == 0 then
    stepWhy = stepWhy or (sc.avail == false and ('nedostupné: ' .. tostring(sc.note or 'na tomto autě'))
      or 'nevyhrál v žádné skupině (vyšší scénář svítí, nebo nemá diody)')
  end
end

local function endStep(s)
  if s.kind == 'scenario' then
    if stepFail > 0 then line('FAIL', string.format('%s – %s', s.name, stepWhy))
    elseif stepOk > 0 then line('OK', string.format('%s – %d čtení odpovídá', s.name, stepOk))
    elseif stepWhy == 'unread' then line('SKIP', s.name .. ' – metoda B kreslí, barvu nejde přečíst (zkontrolujte okem)')
    else line('SKIP', string.format('%s – %s', s.name, tostring(stepWhy))) end
  else
    local n = display.paints - stepPainted
    if display.error then line('FAIL', string.format('%s – %s', s.name, display.error))
    elseif n > 0 then line('OK', string.format('%s – %d× překresleno', s.name, n))
    else line('FAIL', s.name .. ' – displej se nepřekreslil') end
  end
end

-- Every frame from runtime.update (after the LEDs are set).
function M.update(dt)
  if not M.running then return end
  stepTime = stepTime + dt
  local s = steps[stepIndex]
  local len = (s and s.kind ~= 'scenario') and PAGE_TIME or STEP_TIME
  if s and s.kind == 'scenario' then
    -- only the tested scenario may light the LEDs (a pit limiter in the box must not cover it)
    if runtime.compiled then runtime.compiled.solo = s.id end
    if checksDone < #CHECK_AT and stepTime >= CHECK_AT[checksDone + 1] then
      checksDone = checksDone + 1
      checkDue = s                 -- read back in the render pass, after everything else of the frame
    end
  end
  if stepTime < len then return end
  if s then endStep(s) end
  stepIndex = stepIndex + 1
  M.step = stepIndex
  if stepIndex > #steps then finish(); return end
  beginStep(steps[stepIndex])
end

-- From the render callback: the read-back sees what the frame is drawn with (a later write of the game included).
function M.render()
  if not checkDue then return end
  local s = checkDue
  checkDue = nil
  checkScenario(s)
end

function M.text() return table.concat(M.lines, '\n') end

function M.copy()
  pcall(ac.setClipboardText, M.text())
end

return M
