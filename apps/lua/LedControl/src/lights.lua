-- Lights of the player's car (tab Světla): what the car has, real controls, visual items and the light scenarios.
--
-- Real controls change the car's real state, other drivers see them online (calls as in CSP's Unbound app):
--   headlights ac.setHeadlights, high beams ac.setHighBeams, flash ac.overrideCarControls().headlightsFlash,
--   hazards ac.setTurningLights(ac.TurningLights.Hazards / None), CSP extra switches
--   ac.simulateCustomHotkeyPress('__EXT_LIGHT_A'..'F') (a toggle, state car.extraA..F).
-- Rules: a command only on a change and at least 0.25 s after the previous one on that control, confirmed by reading
-- the state back (retried twice, then the control is marked as not working); the state the driver had before a
-- scenario took a control is given back when no scenario wants it any more; when the driver changes a held light by
-- hand, the scenarios let go of it until they end (never fight the driver).
-- Visual items (only this PC): copies of light meshes (src/light_meshes.lua) for the rain light in 'mesh' mode, the
-- blinking brake lights and dash meshes, and an ac.LightSource in the cabin placed relative to the driver's eyes.
-- Scenarios: on/off, priority (per output the highest active one wins), Test (forced 5 s), parameters. Their settings
-- are global (own ac.storage, prefix 'lcl_'); the rain light mode and picked meshes are per car (profile.lights).
-- No allocation per frame in update().

local csp = require('src/csp')
local ac, stringify, vec3 = csp.ac, csp.stringify, csp.vec3
local color = require('src/color')
local store = require('src/store')
local meshes = require('src/light_meshes')
local online = require('src/online')

local M = { available = false, items = {}, version = 0, clock = 0, running = false, carId = '', online = online,
  order = {}, byId = {}, rainSources = {}, brakeNames = {}, healed = 0, rainAuto = '', notes = {},
  stats = { commands = 0 } }

local MIN_INTERVAL = 0.25    -- s between two commands on one real control
local CONFIRM = 0.6          -- s to wait for AC to show a commanded state
local MAX_RETRIES = 2
local FLASH_PERIOD = 0.6     -- s per flash pulse (on half, off half: both above MIN_INTERVAL)
local TEST_SECONDS = 5
local ORIGINAL = color.ORIGINAL
M.MIN_INTERVAL, M.TEST_SECONDS = MIN_INTERVAL, TEST_SECONDS

local function bump() M.version = M.version + 1 end

-- ---------------------------------------------------------------- global settings (own ac.storage)

local defaults = {
  enabled = true,        -- the app controls the car's lights (the master switch must be on as well)
  realOnline = true,     -- online: real controls too (other drivers see them)
  meshIntensity = 30,    -- emissive of a full colour on the rain light copies
  scen = '',             -- scenario settings: stringify { [id] = { on, prio, p = { key = value }, c = '#RRGGBB' } }
  meshGuard = '',        -- self-heal marker of light_meshes.lua: "carId|mesh|mesh..."
  realGuard = '',        -- self-heal marker of held real controls: "carId|channel=driver's state|..."
  showDiag = false,      -- tab Světla: diagnostics block
}
local stored = ac.storage(defaults, 'lcl_')
local G = {}
for k in pairs(defaults) do G[k] = stored[k] end
M.G = G

-- Saves of slider values are deferred (written 0.5 s after the last change, and on release), so dragging a slider
-- does not write ac.storage or the car file every frame.
local SAVE_DELAY = 0.5
local globalDue, globalPending = nil, {}

function M.setGlobal(key, value)
  if defaults[key] == nil then return end
  G[key] = value
  if type(value) == 'number' then
    globalPending[key] = true
    globalDue = M.clock + SAVE_DELAY
  else
    stored[key] = value
    bump()
  end
end

-- ---------------------------------------------------------------- car fields (probed once per car)

local FIELDS = { 'headlightsActive', 'lowBeams', 'hazardLights', 'hasLowBeams', 'hasFlashingLights', 'hasTurningLights',
  'headlightsAreHeadlights', 'flashingLightsActive', 'brakeLightsActive', 'turningLeftOnly', 'turningRightOnly',
  'extraA', 'extraB', 'extraC', 'extraD', 'extraE', 'extraF' }
local has = {}
local car = nil

local function readField(o, k) return o[k] end

local function probe(c)
  for i = 1, #FIELDS do
    local ok, v = pcall(readField, c, FIELDS[i])
    has[FIELDS[i]] = ok and v ~= nil
  end
end

local function flag(k) return has[k] and car[k] == true end

local function fn(name) return type(ac[name]) == 'function' end

-- ---------------------------------------------------------------- real controls

local LETTERS = { 'A', 'B', 'C', 'D', 'E', 'F' }
local EXTRA_FIELD, EXTRA_HOTKEY = {}, {}
for i = 1, 6 do
  EXTRA_FIELD[i] = 'extra' .. LETTERS[i]
  EXTRA_HOTKEY[i] = '__EXT_LIGHT_' .. LETTERS[i]
end

local function channel(id, kind)
  return { id = id, kind = kind or 'bool', toggle = false, has = false, held = false, before = false, confirmed = false,
    pending = false, expected = false, lastCmd = -1e9, retries = 0, yielded = false, failed = nil, cmds = 0,
    state = false, lastOn = false, restoreTurn = 0, owner = nil, read = nil, cmd = nil }
end

local CH = { headlights = channel('headlights'), highBeams = channel('highBeams'), hazards = channel('hazards'),
  flash = channel('flash', 'trigger'), extra = {} }
M.CH = CH

local controlsRef = nil
local function controls()
  if controlsRef == nil then controlsRef = ac.overrideCarControls() end
  return controlsRef
end

CH.headlights.read = function () return flag('headlightsActive') end
CH.headlights.cmd = function (on) ac.setHeadlights(on == true) end
CH.highBeams.read = function () return flag('headlightsActive') and has.lowBeams and not car.lowBeams end
CH.highBeams.cmd = function (on) ac.setHighBeams(on == true) end
CH.hazards.read = function () return flag('hazardLights') end
CH.hazards.cmd = function (on, ch) ac.setTurningLights(on and ac.TurningLights.Hazards or ch.restoreTurn) end
CH.flash.read = function () return flag('flashingLightsActive') end
CH.flash.cmd = function () controls().headlightsFlash = true end
for i = 1, 6 do
  local ch = channel('extra' .. i)
  local field, hotkey = EXTRA_FIELD[i], EXTRA_HOTKEY[i]
  ch.toggle, ch.index = true, i
  ch.read = function () return flag(field) end
  ch.cmd = function () ac.simulateCustomHotkeyPress(hotkey) end
  CH.extra[i] = ch
end
local ALL_CH = { CH.headlights, CH.highBeams, CH.hazards, CH.flash, CH.extra[1], CH.extra[2], CH.extra[3], CH.extra[4],
  CH.extra[5], CH.extra[6] }

local TEXT = {
  driver = 'řídí řidič',
  yielded = 'vráceno řidiči (změnil ho ručně), scénář ho pustil',
  restoring = 'vracím, jak to bylo',
  original = 'jak to má auto',
  blocked = online.BLOCKED,
  noEffect = 'AC příkaz neprovedl (stav se nezměnil), scénář toto světlo pustil',
  replay = 'záznam: nic neřídím',
}
M.TEXT = TEXT

local function send(ch, want, now)
  local ok, err = pcall(ch.cmd, want, ch)
  ch.lastCmd = now
  ch.cmds = ch.cmds + 1
  M.stats.commands = M.stats.commands + 1
  if not ok then
    ch.failed = 'příkaz selhal: ' .. tostring(err)
    bump()
    return false
  end
  return true
end

-- Self-heal of real controls: which channels the app holds and the driver's state before, written on every take /
-- give-back (never per frame), healed at init after a restart without ac.onRelease.
local function writeRealGuard()
  local t = { M.carId }
  for i = 1, #ALL_CH do
    local c = ALL_CH[i]
    if c.held and c.kind ~= 'trigger' then t[#t + 1] = c.id .. '=' .. (c.before and '1' or '0') end
  end
  local text = #t > 1 and table.concat(t, '|') or ''
  if text ~= G.realGuard then G.realGuard = text; stored.realGuard = text end
end

local function take(ch)
  ch.held, ch.yielded, ch.failed, ch.retries, ch.lastOn = true, false, nil, 0, false
  local s = ch.read()
  ch.state = s
  local inFlight = ch.pending and M.clock - ch.lastCmd < CONFIRM
  if inFlight then
    s = ch.expected                  -- a give-back command is still on its way: that is the driver's state
  else
    ch.pending = false
  end
  ch.before, ch.confirmed = s, s
  if ch == CH.hazards and not inFlight then   -- in flight: keep the indicator state remembered last time
    local TL = ac.TurningLights
    ch.restoreTurn = (flag('turningLeftOnly') and TL.Left) or (flag('turningRightOnly') and TL.Right) or TL.None
  end
  writeRealGuard()
  bump()
end

-- A give-back command may still be pending (checked by the next take).
local function unhold(ch)
  ch.held, ch.owner, ch.lastOn = false, nil, false
  writeRealGuard()
  bump()
end

-- After a restart without ac.onRelease: give the driver back the real lights an earlier run held (same car only).
local function healReal(carId)
  local marker = G.realGuard
  if marker == '' then return 0 end
  local parts = {}
  for p in string.gmatch(marker, '[^|]+') do parts[#parts + 1] = p end
  if parts[1] ~= carId then return 0 end
  local n = 0
  for i = 2, #parts do
    local id, v = parts[i]:match('^([%w]+)=([01])$')
    for k = 1, #ALL_CH do
      local ch = ALL_CH[k]
      if id and ch.id == id and ch.has and not ch.held and ch.kind ~= 'trigger' and ch.read() ~= (v == '1') then
        if send(ch, v == '1', M.clock) then ch.pending, ch.expected = true, v == '1'; n = n + 1 end
      end
    end
  end
  G.realGuard = ''
  stored.realGuard = ''
  return n
end

-- Brings ch towards want. Returns true when settled (state == want, nothing pending) or when the channel gave up
-- (driver override, AC does not react).
local function drive(ch, want, now)
  local state = ch.read()
  ch.state = state
  if ch.pending then
    if state == ch.expected then
      ch.pending, ch.retries, ch.confirmed = false, 0, state
    elseif now - ch.lastCmd < CONFIRM then
      return false
    else
      ch.pending = false
      ch.retries = ch.retries + 1
      ch.confirmed = state          -- nothing changed: still the state we know
      if ch.retries > MAX_RETRIES then
        ch.failed = TEXT.noEffect
        bump()
        return true
      end
    end
  elseif state ~= ch.confirmed then
    ch.yielded = true                -- changed without a command of ours: the driver did it
    bump()
    return true
  end
  if state == want then return true end
  if now - ch.lastCmd < MIN_INTERVAL then return false end
  if send(ch, want, now) then ch.pending, ch.expected = true, want end
  return false
end

-- Gives ch back right now (release paths: master off, error, unload, configuration change).
local function restoreNow(ch)
  if not ch.held then return end
  if not ch.yielded and ch.kind ~= 'trigger' then
    -- a command still on its way counts as done (not "pending and expected or read()": expected may be false, and a
    -- second toggle of an extra switch would undo the first one)
    local state
    -- in a replay the car shows the recorded lights: the live state is the last one confirmed before it
    if ch.pending then state = ch.expected elseif M.parked then state = ch.confirmed else state = ch.read() end
    if state ~= ch.before and send(ch, ch.before, M.clock) then ch.pending, ch.expected = true, ch.before end
  end
  unhold(ch)
end

local function applyReal(ch, win, value, now)
  if ch.kind == 'trigger' then
    ch.state = ch.read()
    if win then
      if not ch.held then take(ch) end
      ch.owner = win
      local on = value > 0
      if on and not ch.lastOn and not ch.failed and now - ch.lastCmd >= MIN_INTERVAL then send(ch, true, now) end
      ch.lastOn = on
    elseif ch.held then
      unhold(ch)
    end
    return
  end
  if win then
    if not ch.held then take(ch) end
    if ch.owner ~= win then ch.owner = win; bump() end
    if ch.yielded or ch.failed then ch.state = ch.read() return end
    drive(ch, value > 0, now)
  elseif ch.held then
    if ch.owner then ch.owner = nil; bump() end
    if ch.yielded then unhold(ch) return end
    if ch.failed then
      ch.state = ch.read()
      if ch.state ~= ch.before and send(ch, ch.before, now) then ch.pending, ch.expected = true, ch.before end
      unhold(ch)
      return
    end
    if drive(ch, ch.before, now) then unhold(ch) end
  end
end

-- ---------------------------------------------------------------- outputs (what scenarios drive)

local function output(id, name)
  return { id = id, name = name, has = false, real = false, ch = nil, writer = nil, winner = nil, value = -1 }
end
local OUT = {
  rain = output('rain', 'Dešťové světlo'),
  headlights = output('headlights', 'Světla'),
  hazards = output('hazards', 'Výstražná světla'),
  flash = output('flash', 'Problik'),
  brake = output('brake', 'Brzdová světla'),
  backlight = output('backlight', 'Podsvícení'),
}
local OUT_LIST = { OUT.rain, OUT.headlights, OUT.hazards, OUT.flash, OUT.brake, OUT.backlight }
M.OUT, M.OUT_LIST = OUT, OUT_LIST

local W = { rain = meshes.writer('rain'), brake = meshes.writer('brake'), dash = meshes.writer('dash') }
M.W = W

-- cabin light (ac.LightSource, as CSP's Flashlight app uses it)
local cabin = { light = nil, pos = nil, error = nil, colour = -1, k = -1, placed = false, created = 0, disposed = 0 }
M.cabin = cabin
local cabinLocal, cabinWorld = vec3(), vec3()

-- ---------------------------------------------------------------- per car settings (profile.lights)

local prof = nil
local carCfg = nil
local skipNames = {}
local headlightsReal = true

local function num(v, def, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return def end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return v
end

local function nameList(t)
  local out, seen = {}, {}
  if type(t) ~= 'table' then return out end
  for i = 1, math.min(#t, 32) do
    local s = t[i]
    if type(s) == 'string' and s ~= '' and #s <= 120 and not seen[s] then seen[s] = true; out[#out + 1] = s end
  end
  return out
end

local function sanitiseCar(L)
  L = type(L) == 'table' and L or {}
  local rain = type(L.rain) == 'table' and L.rain or {}
  local dash = type(L.dash) == 'table' and L.dash or {}
  local off = type(dash.offset) == 'table' and dash.offset or {}
  local mode = (rain.mode == 'switch' or rain.mode == 'mesh' or rain.mode == 'off') and rain.mode or nil
  local sw = rain.switch
  if not (sw == 'lights' or (type(sw) == 'string' and sw:match('^[A-F]$'))) then sw = nil end
  return {
    rain = { mode = mode, switch = sw, meshes = nameList(rain.meshes) },
    dash = { meshes = nameList(dash.meshes), cabinLight = dash.cabinLight ~= false,
      offset = { x = num(off.x, 0, -1, 1), y = num(off.y, -0.25, -1, 1), z = num(off.z, 0.45, -1, 1.5) },
      bright = num(dash.bright, 1.5, 0.05, 20), range = num(dash.range, 0.8, 0.1, 3), intensity = num(dash.intensity, 3, 0.1, 60) },
  }
end

local function saveCar()
  if not prof or M.carId == '' then return end
  prof.lights = carCfg
  store.saveCar(M.carId, prof)
end
local carDue, scenDue = nil, nil
local function saveCarSoon() carDue = M.clock + SAVE_DELAY end

-- ---------------------------------------------------------------- scenarios

local function tPitLimiter(ST) return ST.pitLimiter end
local function tRainLight(ST, P) return ST.rain * 100 >= P.rain end
local function tStopped(ST, P)
  return ST.standingFor >= P.stop and not ST.inPitlane and not ST.inPit and ST.sessionStarted ~= false
    and ST.timeToStart <= 0
end
local function tDusk(ST, P)
  local h = ST.timeHours
  return h >= P.dusk or h < P.dawn or ST.rain * 100 >= P.rain
end
local function tBrake(ST, P) return ST.brake * 100 >= P.brake and ST.speed >= P.speed end
local duskP = nil      -- parameters of 'lightsDusk' (evening / morning hour), set below
local function dark(ST) return ST.timeHours >= duskP.dusk or ST.timeHours < duskP.dawn end
-- with the lights on; on cars without headlights (the lights switch does something else) when it is dark
local function tBacklight(ST, P)
  if P.withLights < 0.5 then return true end
  if headlightsReal then return ST.headlights end
  return dark(ST)
end
local function tFlash(ST, P, s)
  if M.clock >= s.flashUntil then return false end
  return OUT.flash.ch ~= CH.highBeams or ST.headlights
end

-- kind: nil = number, 'bool' = checkbox (0 / 1), 'int' = whole numbers (the slider shows %.0f)
local function P(key, name, fmt, def, min, max, kind)
  return { key = key, name = name, fmt = fmt, def = def, min = min, max = max, bool = kind == 'bool', int = kind == 'int' }
end

local function paramValue(d, v, fallback)
  v = num(v, fallback, d.min, d.max)
  if d.int or d.bool then v = math.floor(v + 0.5) end
  return v
end

-- Catalogue order = default priority (first = highest).
local DEFS = {
  { id = 'rainPit', out = 'rain', look = 'blink', colour = '#FF1E00', hold = 0,
    name = 'Dešťové světlo bliká s pit limiterem',
    desc = 'Se zapnutým pit limiterem dešťové světlo bliká (jako u formulí). Přepínač auta zvládne nejvýš 2 Hz.',
    test = tPitLimiter, params = { P('hz', 'Blikání', 'Blikání: %.1f Hz', 2, 0.5, 6) } },
  { id = 'rainWet', out = 'rain', look = 'solid', colour = '#FF1E00', hold = 10, on = false,
    name = 'Dešťové světlo svítí v dešti',
    desc = 'Svítí, když prší víc než nastavená mez; zhasne 10 s po konci deště.',
    test = tRainLight, params = { P('rain', 'Déšť od', 'Déšť od: %.0f %%', 20, 1, 100) } },
  { id = 'hazardStop', out = 'hazards', look = 'solid', hold = 1,
    name = 'Výstražná světla při zastavení na trati',
    desc = 'Když stojíte na trati (mimo pit lane, po startu) déle než nastavený čas, zapnou se výstražná světla; '
      .. 'po rozjetí je vrátí, jak byla.',
    test = tStopped, params = { P('stop', 'Po zastavení', 'Po zastavení: %.0f s', 3, 1, 30) } },
  { id = 'lightsDusk', out = 'headlights', look = 'solid', hold = 20,
    name = 'Světla za šera a v dešti',
    desc = 'Rozsvítí světla večer, v noci a v dešti; 20 s po konci podmínky je vrátí, jak byla.',
    test = tDusk, params = { P('dusk', 'Večer od', 'Večer od: %.1f h', 19, 14, 23.5),
      P('dawn', 'Ráno do', 'Ráno do: %.1f h', 6.5, 3, 11), P('rain', 'Déšť od', 'Déšť od: %.0f %%', 10, 1, 100) } },
  { id = 'brakeBlink', out = 'brake', look = 'blink', hold = 0.6,
    name = 'Brzdová světla blikají při prudkém brzdění',
    desc = 'Při silném brzdění ve vyšší rychlosti brzdová světla blikají. Jen u vás: ostatní jezdci vidí normální '
      .. 'brzdová světla.',
    test = tBrake, params = { P('brake', 'Brzda od', 'Brzda od: %.0f %%', 85, 30, 100),
      P('speed', 'Rychlost od', 'Rychlost od: %.0f km/h', 60, 0, 250), P('hz', 'Blikání', 'Blikání: %.1f Hz', 5, 1, 10) } },
  { id = 'backlightPit', out = 'backlight', look = 'solid', colour = '#FF7800', hold = 0, on = false,
    name = 'Podsvícení oranžově s pit limiterem',
    desc = 'S pit limiterem změní barvu podsvícení (má přednost před běžným podsvícením, když je výš).',
    test = tPitLimiter, params = {} },
  { id = 'backlight', out = 'backlight', look = 'solid', colour = '#2A5CFF', hold = 2,
    name = 'Podsvícení palubní desky a kabiny',
    desc = 'Barevné světlo v kabině u palubní desky a vybrané meshe palubní desky. Jen u vás.',
    test = tBacklight, params = { P('withLights', 'Jen se zapnutými světly (auto bez světlometů: za tmy)', nil, 1, 0, 1,
      'bool') } },
  { id = 'flash', out = 'flash', look = 'pulse', hold = 0,
    name = 'Problik dálkovými na klávesu',
    desc = 'Klávesa „Problik dálkovými světly“ (karta Nastavení) blikne dálkovými. Vidí i ostatní jezdci.',
    test = tFlash, params = { P('count', 'Počet', 'Probliknout: %.0f×', 2, 1, 5, 'int') } },
}
M.DEFS = DEFS

local LIST = {}
for i = 1, #DEFS do
  local d = DEFS[i]
  local s = { def = d, id = d.id, name = d.name, desc = d.desc, out = OUT[d.out], idx = i, on = d.on ~= false,
    prio = i * 10, P = {}, colour = color.parse(d.colour, 0xFFFFFF), active = false, since = 0, holdUntil = -1,
    forceUntil = -1, flashUntil = -1, flashStart = 0, holderText = 'řídí: ' .. d.name, lit = 0xFF0000, litK = 30,
    startedNow = false }
  for k = 1, #d.params do s.P[d.params[k].key] = d.params[k].def end
  LIST[i] = s
  M.byId[d.id] = s
end
M.list = LIST
duskP = M.byId.lightsDusk.P

local function sortOrder()
  local order = {}
  for i = 1, #LIST do order[i] = LIST[i] end
  table.sort(order, function (a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    return a.idx < b.idx
  end)
  M.order = order
end

local function saveScen()
  local t = {}
  for i = 1, #LIST do
    local s = LIST[i]
    local p = {}
    for k, v in pairs(s.P) do p[k] = v end
    t[s.id] = { on = s.on, prio = s.prio, p = p, c = color.hex(s.colour) }
  end
  local ok, text = pcall(stringify, t)
  if ok and type(text) == 'string' then
    G.scen = text
    stored.scen = text
  end
end

local function loadScen()
  if type(G.scen) ~= 'string' or G.scen == '' then return end
  local ok, t = pcall(stringify.parse, G.scen)
  if not ok or type(t) ~= 'table' then return end
  for i = 1, #LIST do
    local s = LIST[i]
    local e = t[s.id]
    if type(e) == 'table' then
      if type(e.on) == 'boolean' then s.on = e.on end
      s.prio = math.floor(num(e.prio, s.prio, 1, 9999))
      if type(e.p) == 'table' then
        for k = 1, #s.def.params do
          local d = s.def.params[k]
          s.P[d.key] = paramValue(d, e.p[d.key], s.P[d.key])
        end
      end
      if s.def.colour then s.colour = color.parse(e.c, s.colour) end
    end
  end
end

loadScen()
sortOrder()

-- ---------------------------------------------------------------- scenario settings used by the tab

function M.setOn(id, on)
  local s = M.byId[id]
  if not s then return end
  s.on = on == true
  saveScen()
  bump()
end

function M.setParam(id, key, value)
  local s = M.byId[id]
  if not s then return end
  for k = 1, #s.def.params do
    local d = s.def.params[k]
    if d.key == key then s.P[key] = paramValue(d, value, d.def) end
  end
  scenDue = M.clock + SAVE_DELAY        -- the rows read the live value, no rebuild of the tab needed
end

-- Writes deferred saves when due (force: now, e.g. on release or a car change).
local function flushSaves(force)
  local now = M.clock
  if carDue and (force or now >= carDue) then carDue = nil; saveCar() end
  if scenDue and (force or now >= scenDue) then scenDue = nil; saveScen() end
  if globalDue and (force or now >= globalDue) then
    globalDue = nil
    for k in pairs(globalPending) do stored[k] = G[k]; globalPending[k] = nil end
  end
end
M.flushSaves = flushSaves

function M.setColour(id, packed)
  local s = M.byId[id]
  if not s or not s.def.colour then return end
  s.colour = color.parse(packed, s.colour)
  scenDue = M.clock + SAVE_DELAY        -- the picker changes it every frame while dragging: save once it rests
end

-- Moves a scenario one place up (-1) or down (+1) in the priority order, past the scenarios the tab does not show
-- (their light is missing on this car), so every click changes the visible list.
function M.move(id, delta)
  local order = M.order
  local at
  for i = 1, #order do if order[i].id == id then at = i end end
  if not at or (delta ~= -1 and delta ~= 1) then return end
  local to = at + delta
  while order[to] and not order[to].out.has do to = to + delta end
  if not order[to] then return end
  order[at], order[to] = order[to], order[at]
  for i = 1, #order do order[i].prio = i * 10 end
  sortOrder()
  saveScen()
  bump()
end

local function startFlash(s)
  s.flashStart = M.clock
  s.flashUntil = M.clock + s.P.count * FLASH_PERIOD
end

-- Button Test: the scenario runs for 5 s even when its condition does not hold (flash: one series of pulses).
-- Returns false when nothing can be tested now (master switch or 'Ovládat světla auta' off): a test set then would
-- fire the real lights later, when the switch is turned on.
function M.test(id)
  local s = M.byId[id]
  if not s or not M.running then return false end
  if s.out == OUT.flash then
    -- without the car's own flash the high beams blink, which needs the headlights on
    if OUT.flash.ch == CH.highBeams and not (car and flag('headlightsActive')) then return end
    startFlash(s)
    s.forceUntil = s.flashUntil
  else
    s.forceUntil = M.clock + TEST_SECONDS
  end
  return true
end

function M.testing(id)
  local s = M.byId[id]
  return s ~= nil and s.forceUntil > M.clock
end

-- Hotkey "Problik dálkovými světly" (hotkeys.lua 'flash').
function M.flash()
  local s = M.byId.flash
  if not s or not s.on or not OUT.flash.has or not M.running then return end
  startFlash(s)
end

-- Restores the defaults of every scenario (on/off, priority, parameters, colours).
function M.resetScenarios()
  for i = 1, #LIST do
    local s, d = LIST[i], LIST[i].def
    s.on, s.prio = d.on ~= false, i * 10
    for k = 1, #d.params do s.P[d.params[k].key] = d.params[k].def end
    s.colour = color.parse(d.colour, 0xFFFFFF)
  end
  sortOrder()
  saveScen()
  bump()
end

-- ---------------------------------------------------------------- detection

local function switchInfo(i)
  local e = { key = LETTERS[i], index = i, ch = CH.extra[i], name = nil, usable = true, note = nil }
  local okN, name = pcall(ac.getExtraSwitchName, i - 1)
  if okN and type(name) == 'string' and name ~= '' then e.name = name end
  local okP, p = pcall(ac.accessExtraSwitchParams, i - 1)
  if okP and p then
    local notes = {}
    local function get(k) local ok, v = pcall(readField, p, k); return ok and v == true end
    if get('holdMode') then notes[#notes + 1] = 'funguje jen při držení tlačítka'; e.usable = false end
    if get('unavailable') then notes[#notes + 1] = 'auto ho klávesou nepovoluje'; e.usable = false end
    if get('stationaryOnly') then notes[#notes + 1] = 'přepne jen v klidu' end
    if get('neutralGearOnly') then notes[#notes + 1] = 'přepne jen na neutrál' end
    if get('requiresBrake') then notes[#notes + 1] = 'přepne jen se sešlápnutou brzdou' end
    if #notes > 0 then e.note = table.concat(notes, ', ') end
  end
  e.label = string.format('Přepínač %s%s', e.key, e.name and (' – ' .. e.name) or '')
  return e
end

local function detectChannels()
  local hlField = has.headlightsAreHeadlights
  headlightsReal = not hlField or car.headlightsAreHeadlights == true
  CH.headlights.has = fn('setHeadlights') and has.headlightsActive == true
  CH.highBeams.has = CH.headlights.has and headlightsReal and fn('setHighBeams') and flag('hasLowBeams')
    and has.lowBeams == true
  CH.hazards.has = fn('setTurningLights') and type(ac.TurningLights) == 'table' and flag('hasTurningLights')
    and has.hazardLights == true
  CH.flash.has = fn('overrideCarControls') and flag('hasFlashingLights')
  M.switches = {}
  for i = 1, 6 do
    local ch = CH.extra[i]
    local okA, avail = pcall(ac.isExtraSwitchAvailable, i - 1, false)
    ch.has = okA and avail == true and has[EXTRA_FIELD[i]] == true and fn('simulateCustomHotkeyPress')
    if ch.has then M.switches[#M.switches + 1] = switchInfo(i) end
  end
end

local function upperFirst(v)
  if type(v) == 'table' then v = v[1] end
  return type(v) == 'string' and v:upper() or ''
end

local function detectBrake(info)
  local names = meshes.namesOf('{ actsAsBrakeLights:yes & lod:A }', 32, skipNames)
  if #names == 0 then names = meshes.namesOf('{ actsAsBrakeLights:yes }', 32, skipNames) end
  local seen = {}
  for i = 1, #names do seen[names[i]] = true end
  -- CSP car config parsed once per car by car_info (it can be huge)
  local cfg = info and info.cspConfig
  if cfg == nil and not info then
    local ok, c = pcall(ac.INIConfig.carConfig, 0)
    cfg = ok and c or nil
  end
  local root = ac.findNodes('carRoot:0')
  if cfg and type(cfg.sections) == 'table' and root and #root > 0 then
    for sec, keys in pairs(cfg.sections) do
      if type(keys) == 'table' and (upperFirst(keys.INPUT) == 'BRAKE' or tostring(sec):find('^EMISSIVE_BRAKE')) then
        local list = type(keys.NAME) == 'table' and keys.NAME or { keys.NAME }
        for k = 1, #list do
          local nm = list[k]
          if type(nm) == 'string' and nm ~= '' and not seen[nm] and not skipNames[nm] and #names < 32 then
            local okF, found = pcall(root.findMeshes, root, nm)
            if okF and found and #found > 0 then seen[nm] = true; names[#names + 1] = nm end
          end
        end
      end
    end
  end
  M.brakeNames = names
end

-- Rain light sources for 'switch' mode: extra switches, and the headlights when they are no headlights on this car
-- (Kunos formula cars use the lights switch for the rain light).
local function detectRain()
  local list = {}
  for i = 1, #M.switches do
    local e = M.switches[i]
    list[#list + 1] = { key = e.key, ch = e.ch, label = e.label, usable = e.usable, note = e.note, name = e.name }
  end
  if CH.headlights.has and not headlightsReal then
    list[#list + 1] = { key = 'lights', ch = CH.headlights, usable = true,
      label = 'Světla auta (na tomto autě nejsou světlomety, obvykle jde o dešťové světlo)' }
  end
  M.rainSources = list
  M.rainMeshAuto = meshes.namesOf('{ (?RAIN?, ?Rain?, ?rain?) & lod:A }', 8, skipNames)
end

local function sourceByKey(key)
  for i = 1, #M.rainSources do
    if M.rainSources[i].key == key and M.rainSources[i].usable then return M.rainSources[i] end
  end
  return nil
end

-- Effective rain light setup: mode, source (switch) and mesh names; automatic when the car has no saved choice.
local function resolveRain()
  local r = carCfg.rain
  local mode, src, names = r.mode, nil, r.meshes
  local auto = ''
  if mode == nil then
    for i = 1, #M.rainSources do
      local e = M.rainSources[i]
      if e.usable and e.key ~= 'lights' and e.name and e.name:lower():find('rain') then src = e; break end
    end
    if not src then src = sourceByKey('lights') end
    if src then
      mode = 'switch'
      auto = 'Automaticky: ' .. src.label
    elseif #M.rainMeshAuto > 0 then
      mode, names = 'mesh', M.rainMeshAuto
      auto = 'Automaticky: kopie meshů ' .. table.concat(M.rainMeshAuto, ', ')
    else
      mode = 'off'
      auto = 'Auto nemá rozpoznané dešťové světlo: vyberte přepínač nebo meshe.'
    end
  elseif mode == 'switch' then
    src = sourceByKey(r.switch or '')
    if not src then
      for i = 1, #M.rainSources do if M.rainSources[i].usable then src = M.rainSources[i]; break end end
    end
  end
  M.rainMode, M.rainSource, M.rainNames, M.rainAuto = mode, src, names, auto
  local o = OUT.rain
  o.real, o.ch, o.writer = false, nil, nil
  if mode == 'switch' and src then
    o.real, o.ch, o.has = true, src.ch, src.ch.has
  elseif mode == 'mesh' and #names > 0 then
    o.writer, o.has = W.rain, true
  else
    o.has = false
  end
end

-- ---------------------------------------------------------------- items listed by the tab

local function item(id, name, desc, real, ch, out)
  return { id = id, name = name, desc = desc, real = real, ch = ch, out = out, on = false, holder = TEXT.driver,
    note = nil }
end

local function buildItems()
  local items = {}
  if CH.headlights.has then
    if headlightsReal then
      items[#items + 1] = item('headlights', 'Světla', 'Skutečná světla auta (zapnout / vypnout).', true, CH.headlights)
    else
      items[#items + 1] = item('headlights', 'Světla auta (slouží jinak)',
        'Na tomto autě tlačítko světel neovládá světlomety (často jde o dešťové světlo).', true, CH.headlights)
    end
  end
  if CH.highBeams.has then
    items[#items + 1] = item('highBeams', 'Dálková světla',
      'Přepíná potkávací / dálková. Pro problik, když auto nemá vlastní problik.', true, CH.highBeams)
  end
  if CH.flash.has then
    items[#items + 1] = item('flash', 'Problik', 'Krátké bliknutí dálkovými jako klávesa problik v AC.', true, CH.flash)
  end
  if CH.hazards.has then
    items[#items + 1] = item('hazards', 'Výstražná světla', 'Všechny blinkry naráz.', true, CH.hazards)
  end
  for i = 1, #M.switches do
    local e = M.switches[i]
    local it = item('extra' .. e.index, e.label, 'Extra přepínač auta (CSP), skutečný stav; lze ho použít jako '
      .. 'dešťové světlo.', true, e.ch)
    it.note = e.note
    items[#items + 1] = it
  end
  if #M.brakeNames > 0 then
    local it = item('brake', string.format('Brzdová světla (%d %s)', #M.brakeNames,
      #M.brakeNames == 1 and 'mesh' or (#M.brakeNames < 5 and 'meshe' or 'meshů')),
      'Jen u vás: kopie meshů brzdových světel, které umí blikat.', false, nil, OUT.brake)
    items[#items + 1] = it
  end
  if OUT.rain.has and OUT.rain.writer then
    items[#items + 1] = item('rainMesh', 'Dešťové světlo (kopie meshů)',
      'Jen u vás: kopie vybraných meshů svítí a blikají místo nich.', false, nil, OUT.rain)
  end
  if OUT.backlight.has then
    items[#items + 1] = item('backlight', 'Podsvícení',
      'Jen u vás: světlo v kabině u palubní desky a vybrané meshe palubní desky v barvě scénáře.', false, nil,
      OUT.backlight)
  end
  M.items = items
  M.available = #items > 0
end

-- ---------------------------------------------------------------- configuration (writers, outputs)

local dirty = true
local parked = false

local REAL_OUT = { OUT.rain, OUT.headlights, OUT.hazards, OUT.flash }
local oldCh = {}

-- picked names minus the LEDs of the current layout (an LED mesh belongs to takeover.lua only)
local function notLeds(list)
  local out = {}
  for i = 1, #list do if not skipNames[list[i]] then out[#out + 1] = list[i] end end
  return out
end

local function configure()
  dirty = false
  for i = 1, #REAL_OUT do oldCh[i] = REAL_OUT[i].real and REAL_OUT[i].ch or false end
  for _, w in pairs(W) do meshes.release(w) end
  if cabin.light then
    pcall(cabin.light.dispose, cabin.light)
    cabin.light, cabin.pos = nil, nil
    cabin.disposed = cabin.disposed + 1
  end
  cabin.colour, cabin.k, cabin.placed = -1, -1, false
  resolveRain()
  -- an output the car does not have drives no channel: on cars without headlights the lights switch belongs to the
  -- rain light, and an idle headlights output would give it back every frame (the two would fight)
  local hl = CH.headlights.has and headlightsReal and OUT.rain.ch ~= CH.headlights
  OUT.headlights.real, OUT.headlights.ch, OUT.headlights.has = true, hl and CH.headlights or nil, hl
  OUT.hazards.real, OUT.hazards.ch, OUT.hazards.has = true, CH.hazards.has and CH.hazards or nil, CH.hazards.has
  if CH.flash.has then
    OUT.flash.real, OUT.flash.ch, OUT.flash.has = true, CH.flash, true
  else
    OUT.flash.real, OUT.flash.ch, OUT.flash.has = true, CH.highBeams.has and CH.highBeams or nil, CH.highBeams.has
  end
  -- a real control no output drives any more goes back to the driver (the others stay held)
  for i = 1, #REAL_OUT do
    local c = oldCh[i]
    if c and c ~= OUT.rain.ch and c ~= OUT.headlights.ch and c ~= OUT.hazards.ch and c ~= OUT.flash.ch then
      restoreNow(c)
    end
  end
  OUT.brake.writer, OUT.brake.has = W.brake, #M.brakeNames > 0
  OUT.backlight.writer = W.dash
  OUT.backlight.has = type(ac.LightSource) == 'function' or #carCfg.dash.meshes > 0
  if OUT.rain.writer then meshes.prepare(W.rain, notLeds(M.rainNames)) end
  if OUT.brake.has then meshes.prepare(W.brake, M.brakeNames) end
  if #carCfg.dash.meshes > 0 then meshes.prepare(W.dash, notLeds(carCfg.dash.meshes)) end
  M.notes = {}
  if OUT.rain.writer and not W.rain.ready then M.notes[#M.notes + 1] = 'Dešťové světlo: ' .. tostring(W.rain.error) end
  if OUT.brake.has and not W.brake.ready then M.notes[#M.notes + 1] = 'Brzdová světla: ' .. tostring(W.brake.error) end
  if #carCfg.dash.meshes > 0 and not W.dash.ready then
    M.notes[#M.notes + 1] = 'Meshe podsvícení: ' .. tostring(W.dash.error)
  end
  if fn('setBrakingLightsThreshold') then
    M.brakeThreshold = 'ac.setBrakingLightsThreshold existuje, ale nepoužívám ji: původní práh nejde přečíst a vrátit.'
  else
    M.brakeThreshold = 'ac.setBrakingLightsThreshold aplikace nemá: brzdová světla blikají jen jako kopie meshů.'
  end
  buildItems()
  bump()
end

-- ---------------------------------------------------------------- per car settings used by the tab

local function listOf(role)
  if not carCfg then return nil end
  if role == 'rain' then return carCfg.rain.meshes end
  if role == 'dash' then return carCfg.dash.meshes end
  return nil
end

local selected = { rain = {}, dash = {} }
local function rebuildSelected()
  for role, set in pairs(selected) do
    for k in pairs(set) do set[k] = nil end
    local list = listOf(role) or {}
    for i = 1, #list do set[list[i]] = true end
  end
end

function M.setRainMode(mode)
  if not carCfg then return end
  carCfg.rain.mode = (mode == 'switch' or mode == 'mesh' or mode == 'off') and mode or nil
  if mode == 'mesh' and #carCfg.rain.meshes == 0 then
    for i = 1, #(M.rainMeshAuto or {}) do carCfg.rain.meshes[i] = M.rainMeshAuto[i] end
    rebuildSelected()
  end
  saveCar()
  dirty = true
  bump()
end

function M.setRainSwitch(key)
  if not carCfg then return end
  carCfg.rain.mode, carCfg.rain.switch = 'switch', key
  saveCar()
  dirty = true
  bump()
end

function M.meshSelected(role, name)
  local set = selected[role]
  return set ~= nil and set[name] == true
end

function M.toggleMesh(role, name)
  local list = listOf(role)
  if not list or type(name) ~= 'string' then return end
  local at
  for i = 1, #list do if list[i] == name then at = i end end
  if at then table.remove(list, at) elseif #list < 32 then list[#list + 1] = name end
  if role == 'rain' then carCfg.rain.mode = 'mesh' end
  rebuildSelected()
  saveCar()
  dirty = true
  bump()
end

function M.clearMeshes(role)
  local list = listOf(role)
  if not list then return end
  for i = #list, 1, -1 do list[i] = nil end
  rebuildSelected()
  saveCar()
  dirty = true
  bump()
end

-- Cabin light and dash mesh settings: cabinLight (bool), bright, range, intensity, x / y / z (offset from the eyes, m).
function M.setDash(key, value)
  if not carCfg then return end
  local d = carCfg.dash
  if key == 'cabinLight' then d.cabinLight = value == true
  elseif key == 'bright' then d.bright = num(value, d.bright, 0.05, 20)
  elseif key == 'range' then d.range = num(value, d.range, 0.1, 3)
  elseif key == 'intensity' then d.intensity = num(value, d.intensity, 0.1, 60)
  elseif key == 'x' or key == 'y' or key == 'z' then d.offset[key] = num(value, d.offset[key], -1, 1.5)
  else return end
  cabin.k, cabin.placed = -1, false
  if cabin.light and key == 'range' then pcall(function () cabin.light.range = d.range end) end
  saveCarSoon()
  if key == 'cabinLight' then dirty = true; bump() end
end

function M.carSettings() return carCfg end

local meshCache, meshCacheFor = nil, nil
-- LOD A meshes of the car for the pickers (listed on demand, cached per car).
function M.listMeshes()
  if meshCache and meshCacheFor == M.carId then return meshCache end
  meshCache = meshes.listMeshes(ac.getCar(0), 400, skipNames)
  meshCacheFor = M.carId
  return meshCache
end

-- ---------------------------------------------------------------- cabin light

local function setupLight(l, range)
  l.range = range
  l.rangeGradientOffset = 0
  l.specularMultiplier = 0.3
  l.shadows = false
  l.showInReflections = false
  l.spot = 0
end

local function createCabin()
  local ok, l = pcall(ac.LightSource, ac.LightType.Regular)
  if not ok or not l then
    cabin.error = 'ac.LightSource nefunguje: ' .. tostring(l)
    bump()
    return
  end
  pcall(setupLight, l, carCfg.dash.range)
  cabin.light, cabin.error, cabin.colour, cabin.k, cabin.placed = l, nil, -1, -1, false
  cabin.pos = l.position          -- reference into the light (lives as long as the light), reused every frame
  cabin.created = cabin.created + 1
end

local function cabinOff()
  if cabin.light then
    pcall(cabin.light.dispose, cabin.light)
    cabin.light, cabin.pos = nil, nil
    cabin.disposed = cabin.disposed + 1
  end
  cabin.colour, cabin.k = -1, -1
end

-- Eyes + offset in car space is computed once (light created, setting changed); the world position every frame.
local function placeCabin()
  if not cabin.placed then
    local eyes, off = car.driverEyesPosition, carCfg.dash.offset
    cabinLocal:set(eyes.x + off.x, eyes.y + off.y, eyes.z + off.z)
    cabin.placed = true
  end
  car.transform:transformPointTo(cabinWorld, cabinLocal)
  cabin.pos:set(cabinWorld)
end

local function applyBacklight(win, value)
  local d = carCfg.dash
  if win and value >= 0 then
    if d.cabinLight and type(ac.LightSource) == 'function' and not cabin.error then
      if not cabin.light then createCabin() end
      local l = cabin.light
      if l then
        if cabin.colour ~= value or cabin.k ~= d.bright then
          local r, g, b = color.unpack(value)
          l.color:set(r * d.bright, g * d.bright, b * d.bright)
          cabin.colour, cabin.k = value, d.bright
        end
        placeCabin()
      end
    elseif cabin.light then
      cabinOff()
    end
    if W.dash.ready then meshes.set(W.dash, value, d.intensity) end
  else
    if cabin.light then cabinOff() end
    if W.dash.ready then meshes.set(W.dash, ORIGINAL, 0) end
  end
end

-- ---------------------------------------------------------------- frame loop

local function evalScenario(s, ST, now)
  local on = false
  if s.forceUntil > now then
    on = true
  elseif s.on and ST.ready then
    on = s.def.test(ST, s.P, s) == true
    if on then s.holdUntil = now + s.def.hold
    elseif s.holdUntil > now then on = true end
  end
  s.startedNow = on and not s.active
  if s.startedNow then s.since = now end
  s.active = on
end

local function captureBrake(s)
  local r, g, b = meshes.originalEmissive(W.brake)
  local m = r and math.max(r, g, b) or 0
  if m > 0.05 then
    s.lit, s.litK = color.pack(r / m, g / m, b / m), m
  else
    s.lit, s.litK = 0xFF0000, G.meshIntensity
  end
end

local function valueOf(s, o, now)
  local look = s.def.look
  local on = true
  if look == 'blink' then
    local hz = s.P.hz or 2
    if o.real and hz > 2 then hz = 2 end      -- a real switch: one command per 0.25 s at most
    on = ((now - s.since) * hz) % 1 < 0.5
  elseif look == 'pulse' then
    on = ((now - s.flashStart) % FLASH_PERIOD) < FLASH_PERIOD * 0.5
  end
  if o.real then return on and 1 or 0 end
  if not on then return 0 end
  if o == OUT.brake then return s.lit end
  return s.colour
end

local function refreshItems()
  local items = M.items
  local blocked = online.realBlock(G.realOnline)
  for i = 1, #items do
    local it = items[i]
    local ch = it.ch
    if ch then
      it.on = ch.held and ch.state or ch.read()
      if blocked then it.holder = TEXT.blocked
      elseif ch.held then
        if ch.yielded then it.holder = TEXT.yielded
        elseif ch.failed then it.holder = ch.failed
        elseif ch.owner then it.holder = ch.owner.holderText
        else it.holder = TEXT.restoring end
      else
        it.holder = ch.failed or TEXT.driver
      end
    else
      local o = it.out
      local w = o.writer
      if o == OUT.backlight then
        it.on = cabin.light ~= nil or (w.taken and w.cur > 0)
      else
        it.on = w ~= nil and w.taken and w.cur > 0
      end
      it.holder = o.winner and o.winner.holderText or TEXT.original
      if o == OUT.backlight and cabin.error then it.holder = cabin.error end
    end
  end
end

-- Reads the live state for the tab while update() does not run (master switch off).
function M.poll()
  if M.carId == '' then return end
  car = ac.getCar(0)
  if car then refreshItems() end
end

local function releaseAll()
  for i = 1, #ALL_CH do restoreNow(ALL_CH[i]) end
  for _, w in pairs(W) do meshes.set(w, ORIGINAL, 0); meshes.release(w) end
  meshes.clearMarker()
  cabinOff()
  for i = 1, #LIST do
    local s = LIST[i]
    s.active, s.holdUntil, s.forceUntil, s.flashUntil = false, -1, -1, -1
  end
  for i = 1, #OUT_LIST do OUT_LIST[i].winner, OUT_LIST[i].value = nil, -1 end
  dirty = true
  M.running = false
end

function M.update(dt, ST)
  if M.carId == '' then return end
  if ST.paused then
    -- AC is paused: nothing is commanded (AC would not apply it), timers stand still
    refreshItems()
    return
  end
  M.clock = M.clock + dt
  flushSaves(false)
  local now = M.clock
  car = ac.getCar(0)
  if not car then return end
  online.update(ST)
  if not G.enabled then
    if M.running then releaseAll(); bump() end
    refreshItems()
    return
  end
  if dirty then configure() end
  M.running = true
  if ST.replay then
    -- AC plays the recorded lights: nothing is commanded, the visual copies give the car its own look
    if not parked then
      parked = true
      M.parked = true
      for _, w in pairs(W) do meshes.set(w, ORIGINAL, 0) end
      cabinOff()
      for i = 1, #M.items do M.items[i].holder = TEXT.replay end
    end
    return
  end
  parked = false
  M.parked = false
  local blocked = online.realBlock(G.realOnline) ~= nil
  local order = M.order
  for i = 1, #order do evalScenario(order[i], ST, now) end
  for i = 1, #OUT_LIST do
    local o = OUT_LIST[i]
    local win = nil
    if o.has then
      -- the highest active scenario wins; one in Test wins over the others (the button must show its effect)
      for k = 1, #order do
        local s = order[k]
        if s.active and s.out == o then
          if s.forceUntil > now then win = s; break end
          if not win then win = s end
        end
      end
    end
    if win and o == OUT.brake and win.startedNow then captureBrake(win) end
    local value = win and valueOf(win, o, now) or -1
    o.winner, o.value = win, value
    if o.real then
      if o.ch then applyReal(o.ch, (not blocked) and win or nil, value, now) end
    elseif o == OUT.backlight then
      applyBacklight(win, value)
    elseif o.writer and o.writer.ready then
      local k = o == OUT.brake and (win and win.litK or 0) or G.meshIntensity
      meshes.set(o.writer, win and value or ORIGINAL, k)
    end
  end
  meshes.guard(W.rain, dt)
  meshes.guard(W.brake, dt)
  meshes.guard(W.dash, dt)
  refreshItems()
end

-- Everything back to how the driver had it: real controls to the state before the app took them, copies removed and
-- originals visible, the cabin light disposed. Safe to call at any time (also before init).
function M.release()
  flushSaves(true)
  local was = M.running
  releaseAll()
  if was then bump() end
end

local lastCar = nil

-- On every car detection (runtime.detectCar).
local function releaseVisuals()
  for _, w in pairs(W) do meshes.set(w, ORIGINAL, 0); meshes.release(w) end
  meshes.clearMarker()
  cabinOff()
  for i = 1, #OUT_LIST do if not OUT_LIST[i].real then OUT_LIST[i].winner, OUT_LIST[i].value = nil, -1 end end
  dirty = true
end

function M.init(carId, profile, layout, info)
  flushSaves(true)
  local keep = M.running and carId == M.carId
  if keep then releaseVisuals() else M.release() end
  M.carId = carId or ''
  prof = profile
  car = ac.getCar(0)
  carCfg = sanitiseCar(profile and profile.lights)
  rebuildSelected()
  skipNames = {}
  if layout and layout.leds then
    for i = 1, #layout.leds do skipNames[layout.leds[i].name] = true end
  end
  meshes.useStorage(stored, M.carId)
  M.healed = meshes.heal(M.carId)
  online.reset()
  meshCache = nil
  local sameCar = carId == lastCar
  lastCar = carId
  for i = 1, #ALL_CH do
    local ch = ALL_CH[i]
    if not ch.held then ch.failed, ch.yielded = nil, false end
    if not sameCar then ch.cmds, ch.lastCmd, ch.pending = 0, -1e9, false end
  end
  controlsRef = nil
  cabin.error = nil
  if car then
    probe(car)
    detectChannels()
    if not keep then M.healedReal = healReal(M.carId) end
  else
    -- nothing of the previous car may stay usable
    for i = 1, #ALL_CH do ALL_CH[i].has = false end
    M.switches = {}
  end
  detectBrake(info)
  detectRain()
  configure()
  dirty = false
end

-- Diagnostics lines (tab Světla, "Kopírovat diagnostiku"); built on demand, never per frame.
function M.diagLines()
  local L = {}
  local function add(fmt, ...) L[#L + 1] = string.format(fmt, ...) end
  add('Světla: %s, auto %s, položek %d, příkazů %d, uzdraveno meshů %d, světlo v kabině vytvořeno %d / zrušeno %d',
    G.enabled and 'zapnuto' or 'vypnuto', tostring(M.carId), #M.items, M.stats.commands, M.healed or 0,
    cabin.created, cabin.disposed)
  for i = 1, #M.items do
    local it = M.items[i]
    local ch = it.ch
    if ch then
      add('  %s: %s | %s | příkazů %d, drží %s, před převzetím %s', tostring(it.name), it.on and 'svítí' or 'nesvítí',
        tostring(it.holder), ch.cmds, tostring(ch.held), tostring(ch.before))
    else
      add('  %s: %s | %s', tostring(it.name), it.on and 'svítí' or 'nesvítí', tostring(it.holder))
    end
  end
  for i = 1, #OUT_LIST do
    local o = OUT_LIST[i]
    if o.has then add('  výstup %s: %s', o.name, o.winner and o.winner.name or 'nic aktivního') end
  end
  add('  dešťové světlo: %s%s', tostring(M.rainMode), (M.rainAuto or '') ~= '' and (' | ' .. M.rainAuto) or '')
  for _, role in ipairs({ 'rain', 'brake', 'dash' }) do
    local w = W[role]
    add('  meshe %s: kopií %d, zápisů %d, znovu zobrazené originály %d%s', role, w.copies, w.writes, w.reShows,
      w.error and (', ' .. tostring(w.error)) or '')
  end
  for i = 1, #M.notes do add('  %s', tostring(M.notes[i])) end
  if cabin.error then add('  %s', cabin.error) end
  add('  %s', tostring(M.brakeThreshold or ''))
  if online.extrasText ~= '' then add('  %s', online.extrasText) end
  return L
end

-- Light meshes are shadow copies (no redraw) and AC does not write their own materials: nothing to do here.
function M.draw3D() end
function M.frameBegin() end

return M
