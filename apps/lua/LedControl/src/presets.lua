-- Presets: a complete LED setup = which scenarios are on, their priority, target and look, plus the base look
-- (what the LEDs show when no scenario is active: 'off' or 'original' = the car's own logic).
-- Built-in presets are code and relative (they work on any LED count). User presets are stored sparse: missing
-- scenario keys inherit from the built-in they were copied from ("from"), then from the catalogue, so new built-in
-- scenarios reach old presets. Editing a built-in preset makes a user copy first (copy-on-write).
-- Export / import: one line "LEDCONTROL-PRESET 1 " + JSON; imported text is parsed with JSON.parse under pcall
-- and sanitised (never executed).

local scenarios = require('src/scenarios')
local conditions = require('src/conditions')
local patterns = require('src/patterns')
local store = require('src/store')

local M = { version = 1, user = {}, nextId = 1 }

local EXPORT_PREFIX = 'LEDCONTROL-PRESET 1 '
M.EXPORT_PREFIX = EXPORT_PREFIX

local BLUE, GREEN, RED, YELLOW, ORANGE, PURPLE = '#0050FF', '#00FF40', '#FF0000', '#FFD000', '#FF8000', '#A000FF'

M.BUILTIN = {
  {
    id = 'builtin:f1', name = 'F1 styl', builtin = true, base = 'off',
    note = 'Řada se plní zleva doprava zelená – červená – modrá, v bodě řazení vše modře, omezovač bliká.',
    scenarios = {
      shiftLights = { param = 75, look = { p = 'fill', dir = 'left', src = 'relative', c = { '#FFFFFF', '#000000' },
        zones = { 0, GREEN, 0.34, RED, 0.67, BLUE } } },
      shiftPoint = { look = { p = 'solid', c = { BLUE } } },
      limiter = { look = { p = 'blink', c = { BLUE, '#000000' }, hz = 8 } },
    },
  },
  {
    id = 'builtin:gt3', name = 'GT3 styl', builtin = true, base = 'off',
    note = 'Řada se plní od krajů ke středu zelená – žlutá – červená, v bodě řazení bliká červeně.',
    scenarios = {
      shiftLights = { param = 80, look = { p = 'fill', dir = 'edges', src = 'relative', c = { '#FFFFFF', '#000000' },
        zones = { 0, GREEN, 0.5, YELLOW, 0.8, RED } } },
      shiftPoint = { look = { p = 'blink', c = { RED, '#000000' }, hz = 5 } },
      limiter = { look = { p = 'blink', c = { RED, '#000000' }, hz = 10 } },
      pitLimiter = { look = { p = 'alternate', c = { YELLOW, '#000000' }, hz = 2 } },
      drsActive = { on = false }, drsAvailable = { on = false },
    },
  },
  {
    id = 'builtin:minimal', name = 'Minimální', builtin = true, base = 'original',
    note = 'Otáčky ukazuje auto samo, přidá jen pit limiter, modrou a žlutou vlajku.',
    scenarios = {
      pitLane = { on = false }, flagBlack = { on = false }, flagPenalty = { on = false }, flagWhite = { on = false },
      flagChequered = { on = false }, flagRed = { on = false }, limiter = { on = false }, shiftPoint = { on = false },
      shiftLights = { on = false }, drsActive = { on = false }, drsAvailable = { on = false }, abs = { on = false },
      tc = { on = false }, lowFuel = { on = false }, damage = { on = false }, startCountdown = { on = false },
      startGo = { on = false }, idle = { on = false },
    },
  },
}
local BUILTIN_BY_ID = {}
for i = 1, #M.BUILTIN do BUILTIN_BY_ID[M.BUILTIN[i].id] = M.BUILTIN[i] end

-- ---------------------------------------------------------------- sanitising

local function str(v, max)
  if type(v) ~= 'string' then return nil end
  return #v > max and v:sub(1, max) or v
end

local function num(v, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return nil end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return v
end

local function colourStr(v)
  if type(v) == 'string' then
    local h = v:match('^#?(%x%x%x%x%x%x)$')
    if h then return '#' .. h:upper() end
  end
  return nil
end

function M.sanitiseLook(l)
  if type(l) ~= 'table' then return nil end
  local out = { p = patterns.KIND_INDEX[l.p] and l.p or 'solid' }
  if type(l.c) == 'table' then
    out.c = {}
    for i = 1, math.min(#l.c, 4) do out.c[i] = colourStr(l.c[i]) or '#000000' end
  end
  out.hz = num(l.hz, 0.05, 30)
  out.dir = patterns.DIR_NAMES[l.dir] and l.dir or nil
  out.width = num(l.width, 1, 64)
  out.src = (l.src == 'car' or l.src == 'relative') and l.src or nil
  out.fps = num(l.fps, 0.2, 30)
  if l.rescale == false then out.rescale = false end
  if type(l.zones) == 'table' then
    out.zones = {}
    for i = 1, math.min(#l.zones - 1, 31), 2 do
      local u, c = num(l.zones[i], 0, 1), colourStr(l.zones[i + 1])
      if u and c then out.zones[#out.zones + 1] = u; out.zones[#out.zones + 1] = c end
    end
  end
  if type(l.palette) == 'table' then
    out.palette = {}
    for i = 1, 9 do out.palette[i] = colourStr(l.palette[i]) or '#FFFFFF' end
  end
  if type(l.g) == 'table' then
    out.g = {}
    for k, g in pairs(l.g) do
      local gi = math.floor(tonumber(k) or 0)
      if gi >= 1 and gi <= 8 and type(g) == 'table' and type(g.f) == 'table' then
        local e = { n = math.floor(num(g.n, 1, 64) or 1), f = {} }
        for fi = 1, math.min(#g.f, 64) do
          local s = type(g.f[fi]) == 'string' and g.f[fi]:gsub('[^%.0-9]', '0'):sub(1, 64) or ''
          e.f[#e.f + 1] = s
        end
        out.g[gi] = e
      end
    end
  end
  return out
end

local TARGET_OK = { all = true, main = true, side = true, other = true }

local function sanitiseEntry(id, e)
  if type(e) ~= 'table' then return nil end
  local out = {}
  if type(e.on) == 'boolean' then out.on = e.on end
  out.prio = num(e.prio, 1, 999)
  out.to = TARGET_OK[e.to] and e.to or nil
  out.param = num(e.param, -1e6, 1e6)
  out.look = M.sanitiseLook(e.look)
  if scenarios.isCustom(id) then
    out.name = str(e.name, 40) or 'Vlastní podmínka'
    out.when = conditions.sanitise(e.when)
  end
  return out
end

-- Clean copy of a user preset, or nil when it is not a preset at all.
function M.sanitise(p)
  if type(p) ~= 'table' then return nil end
  local out = { v = 1, id = str(p.id, 40), name = str(p.name, 40) or 'Preset',
    from = BUILTIN_BY_ID[p.from] and p.from or nil, base = p.base == 'original' and 'original' or 'off',
    layout = str(p.layout, 40), scenarios = {} }
  if type(p.scenarios) == 'table' then
    local n = 0
    for id, e in pairs(p.scenarios) do
      if type(id) == 'string' and (scenarios.byId[id] or id:match('^custom:%d+$')) then
        local clean = sanitiseEntry(id, e)
        if clean then
          out.scenarios[id] = clean
          n = n + 1
          if n >= 80 then break end
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------- storage

function M.load()
  local t = store.loadPresets()
  M.user = {}
  local seen = {}
  for i = 1, math.min(#t.list, 100) do
    local p = M.sanitise(t.list[i])
    if p and p.id and p.id:match('^user:%d+$') and not seen[p.id] then
      seen[p.id] = true
      M.user[#M.user + 1] = p
    end
  end
  M.nextId = math.max(1, math.floor(tonumber(t.nextId) or 1))
  for i = 1, #M.user do
    local n = tonumber(M.user[i].id:match('%d+')) or 0
    if n >= M.nextId then M.nextId = n + 1 end
  end
  M.version = M.version + 1
end

function M.save()
  store.savePresets({ v = 1, nextId = M.nextId, list = M.user })
  M.version = M.version + 1
end

-- ---------------------------------------------------------------- access

function M.get(id)
  if BUILTIN_BY_ID[id] then return BUILTIN_BY_ID[id] end
  for i = 1, #M.user do if M.user[i].id == id then return M.user[i] end end
  return nil
end

function M.isBuiltin(id) return BUILTIN_BY_ID[id] ~= nil end

-- All presets for a combo: built-ins first, then user presets.
function M.all()
  local out = {}
  for i = 1, #M.BUILTIN do out[#out + 1] = M.BUILTIN[i] end
  for i = 1, #M.user do out[#out + 1] = M.user[i] end
  return out
end

local function deepCopy(v)
  if type(v) ~= 'table' then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deepCopy(x) end
  return o
end
M.deepCopy = deepCopy

-- Effective scenario list of a preset: catalogue defaults <- built-in base ("from") <- the preset's own entries.
-- Returns an array sorted by priority of { id, def, custom, name, cat, on, prio, to, look, param, when, order }.
function M.effective(preset)
  preset = preset or M.BUILTIN[1]
  local base = nil
  if not preset.builtin then base = BUILTIN_BY_ID[preset.from] end
  local list = {}
  for i = 1, #scenarios.list do
    local d = scenarios.list[i]
    local e = { id = d.id, def = d, custom = false, name = d.name, cat = d.cat, on = true, prio = d.order, to = d.to,
      look = d.look, param = d.param and d.param.default or nil, order = d.order }
    for pass = 1, 2 do
      local src
      if pass == 1 then src = base and base.scenarios[d.id] else src = preset.scenarios[d.id] end
      if src then
        if src.on ~= nil then e.on = src.on end
        if src.prio then e.prio = src.prio end
        if src.to then e.to = src.to end
        if src.look then e.look = src.look end
        if src.param then e.param = src.param end
      end
    end
    list[#list + 1] = e
  end
  for id, o in pairs(preset.scenarios) do
    if scenarios.isCustom(id) then
      list[#list + 1] = { id = id, def = nil, custom = true, name = o.name or 'Vlastní podmínka', cat = 'Vlastní',
        on = o.on ~= false, prio = o.prio or 100, to = o.to or 'all', look = o.look or scenarios.CUSTOM_LOOK,
        when = o.when or {}, order = 1000 + (tonumber(id:match('%d+')) or 0) }
    end
  end
  table.sort(list, function (a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    return a.order < b.order
  end)
  return list
end

-- The preset a car uses: its saved choice, else the default setting; 'auto' picks F1 for a long main row or DRS.
function M.choose(profilePreset, defaultPreset, layout, drsPresent)
  if profilePreset and M.get(profilePreset) then return profilePreset end
  if defaultPreset and defaultPreset ~= 'auto' and M.get(defaultPreset) then return defaultPreset end
  local main = layout and layout.groups[1] and #layout.groups[1].leds or 0
  if drsPresent or main >= 12 then return 'builtin:f1' end
  return 'builtin:gt3'
end

-- ---------------------------------------------------------------- editing (copy-on-write)

local function newUserId()
  local id = 'user:' .. M.nextId
  M.nextId = M.nextId + 1
  return id
end

local function uniqueName(name)
  local taken = {}
  for _, p in ipairs(M.all()) do taken[p.name] = true end
  if not taken[name] then return name end
  for i = 2, 99 do
    local n = string.format('%s (%d)', name, i)
    if not taken[n] then return n end
  end
  return name
end

-- New user preset copied from fromId (a built-in or a user preset). Returns its id.
function M.create(fromId, name)
  local src = M.get(fromId) or M.BUILTIN[1]
  local p
  if src.builtin then
    p = { v = 1, from = src.id, base = src.base, scenarios = {} }
  else
    p = deepCopy(src)
  end
  p.id = newUserId()
  p.name = uniqueName(name or (src.name .. ' (kopie)'))
  p.builtin = nil
  M.user[#M.user + 1] = p
  M.save()
  return p.id
end

-- Returns the id of a preset that may be edited: id itself for a user preset, a fresh copy for a built-in one.
function M.editable(id)
  local p = M.get(id)
  if p and not p.builtin then return id end
  local src = p or M.BUILTIN[1]
  return M.create(src.id, src.name .. ' (upravený)')
end

-- Sets one field of a scenario entry ('on', 'prio', 'to', 'look', 'param', 'name', 'when'); returns the preset id
-- that holds the change (a new one when presetId was built-in).
function M.setScenario(presetId, scId, field, value)
  local id = M.editable(presetId)
  local p = M.get(id)
  local e = p.scenarios[scId]
  if not e then e = {}; p.scenarios[scId] = e end
  if field == 'look' then value = M.sanitiseLook(value) end
  if field == 'when' then value = conditions.sanitise(value) end
  e[field] = value
  M.save()
  return id
end

function M.setBase(presetId, base)
  local id = M.editable(presetId)
  M.get(id).base = base == 'original' and 'original' or 'off'
  M.save()
  return id
end

-- Moves a scenario one step up (-1) or down (+1) in the effective order by swapping priorities with its neighbour.
function M.move(presetId, scId, delta)
  local list = M.effective(M.get(presetId))
  local at
  for i = 1, #list do if list[i].id == scId then at = i end end
  local other = at and list[at + delta]
  if not other then return presetId end
  local id = M.editable(presetId)
  local p = M.get(id)
  -- give everything explicit, spaced priorities so a swap is always visible
  for i = 1, #list do
    local e = p.scenarios[list[i].id] or {}
    e.prio = i * 10
    p.scenarios[list[i].id] = e
  end
  p.scenarios[scId].prio, p.scenarios[other.id].prio = (at + delta) * 10, at * 10
  M.save()
  return id
end

function M.addCustom(presetId)
  local id = M.editable(presetId)
  local p = M.get(id)
  local n = 1
  while p.scenarios['custom:' .. n] do n = n + 1 end
  local scId = 'custom:' .. n
  p.scenarios[scId] = { name = 'Vlastní podmínka ' .. n, on = true, prio = 100 + n, to = 'all',
    look = deepCopy(scenarios.CUSTOM_LOOK), when = { { q = 'speed', op = '<', v = 60 } } }
  M.save()
  return id, scId
end

function M.removeScenario(presetId, scId)
  local id = M.editable(presetId)
  M.get(id).scenarios[scId] = nil
  M.save()
  return id
end

function M.rename(id, name)
  local p = M.get(id)
  if not p or p.builtin or type(name) ~= 'string' or name == '' then return false end
  p.name = name:sub(1, 40)
  M.save()
  return true
end

function M.delete(id)
  for i = 1, #M.user do
    if M.user[i].id == id then
      table.remove(M.user, i)
      M.save()
      return true
    end
  end
  return false
end

function M.deleteAllUser()
  M.user, M.nextId = {}, 1
  M.save()
end

-- ---------------------------------------------------------------- export / import

function M.export(id)
  local p = M.get(id)
  if not p then return nil end
  local out
  if p.builtin then out = { v = 1, name = p.name, from = p.id, base = p.base, scenarios = {} }
  else out = M.sanitise(p); out.id = nil end
  return EXPORT_PREFIX .. JSON.stringify(out)
end

-- Returns the new preset id, or nil and a Czech reason.
function M.import(text)
  if type(text) ~= 'string' then return nil, 'Schránka je prázdná.' end
  local at = text:find(EXPORT_PREFIX, 1, true)
  if not at then return nil, 'Ve schránce není preset LedControl (chybí „LEDCONTROL-PRESET 1“).' end
  local body = text:sub(at + #EXPORT_PREFIX):gsub('^%s+', ''):gsub('%s+$', '')
  local ok, data = pcall(JSON.parse, body)
  if not ok or type(data) ~= 'table' then return nil, 'Preset ve schránce nejde přečíst (poškozený JSON).' end
  local p = M.sanitise(data)
  if not p then return nil, 'Preset ve schránce nemá platný obsah.' end
  p.id = newUserId()
  p.name = uniqueName(p.name or 'Importovaný preset')
  M.user[#M.user + 1] = p
  M.save()
  return p.id
end

return M
