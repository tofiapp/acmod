-- Presets: a complete LED setup = which scenarios are on, their priority, target and look, plus the base look
-- (what the LEDs show when no scenario is active: 'off' or 'original' = the car's own logic).
-- Built-in presets are code and relative (they work on any LED count). User presets are stored sparse: missing
-- scenario keys inherit from the built-in they were copied from ("from"), then from the catalogue, so new built-in
-- scenarios reach old presets. Built-in presets are edited in place: the changes are a sparse overlay (p.edits,
-- saved as builtinEdits), "Obnovit výchozí" clears it. (Up to 0.3.2 an edit made a hidden copy "(upravený)" and the
-- car switched to it, so changes seemed lost once the built-in was picked again.)
-- Animations: the look of a catalogue scenario is a named animation in a library (M.anims) that applies to the
-- presets ticked in it (anim.presets[presetId] = true; one animation per scenario and preset). A look edit goes into
-- the animation of that scenario in that preset, a new one is made when there is none. Resolution of a look:
-- catalogue <- built-in <- the preset's own entry <- the animation.
-- Export / import: one line "LEDCONTROL-PRESET 1 " + JSON; imported text is parsed with JSON.parse under pcall
-- and sanitised (never executed).

local csp = require('src/csp')
local JSON = csp.JSON
local scenarios = require('src/scenarios')
local conditions = require('src/conditions')
local patterns = require('src/patterns')
local store = require('src/store')

local M = { version = 1, user = {}, nextId = 1 }

local EXPORT_PREFIX = 'LEDCONTROL-PRESET 1 '
M.EXPORT_PREFIX = EXPORT_PREFIX

local BLUE, GREEN, RED, YELLOW, ORANGE, PURPLE = '#0000FF', '#00FF00', '#FF0000', '#FFC800', '#FF5000', '#A000FF'

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
for i = 1, #M.BUILTIN do
  BUILTIN_BY_ID[M.BUILTIN[i].id] = M.BUILTIN[i]
  M.BUILTIN[i].edits = { scenarios = {} }      -- the user's changes (base = nil: the built-in's own)
end

M.anims, M.nextAnim = {}, 1
local animIdx = {}            -- [presetId][scenarioId] = animation

-- ---------------------------------------------------------------- sanitising

-- Cuts s to at most max bytes without splitting a UTF-8 character.
local function cutUtf8(s, max)
  if #s <= max then return s end
  local cut = max
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end
M.cutUtf8 = cutUtf8

local function str(v, max)
  if type(v) ~= 'string' then return nil end
  return cutUtf8(v, max)
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
  local d = scenarios.byId[id]
  if d and d.param then out.param = num(e.param, d.param.min, d.param.max) else out.param = nil end
  out.look = M.sanitiseLook(e.look)
  if scenarios.isCustom(id) then
    out.name = str(e.name, 40) or 'Vlastní podmínka'
    out.when = conditions.sanitise(e.when)
  end
  return out
end

function M.sanitiseScenarios(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  local n = 0
  for id, e in pairs(t) do
    if type(id) == 'string' and (scenarios.byId[id] or id:match('^custom:%d+$')) then
      local clean = sanitiseEntry(id, e)
      if clean then
        out[id] = clean
        n = n + 1
        if n >= 80 then break end
      end
    end
  end
  return out
end

-- Clean copy of a stored animation, or nil.
function M.sanitiseAnim(a)
  if type(a) ~= 'table' or type(a.id) ~= 'string' or not a.id:match('^anim:%d+$') then return nil end
  if not scenarios.byId[a.sc] then return nil end
  local look = M.sanitiseLook(a.look)
  if not look then return nil end
  local out = { id = a.id, name = str(a.name, 40) or 'Animace', sc = a.sc, look = look, presets = {} }
  if type(a.presets) == 'table' then
    local n = 0
    for id, on in pairs(a.presets) do
      if on == true and type(id) == 'string' and (id:match('^builtin:[%w_]+$') or id:match('^user:%d+$')) then
        out.presets[id] = true
        n = n + 1
        if n >= 100 then break end
      end
    end
  end
  return out
end

-- Clean copy of a user preset, or nil when it is not a preset at all.
function M.sanitise(p)
  if type(p) ~= 'table' then return nil end
  local out = { v = 1, id = str(p.id, 40), name = str(p.name, 40) or 'Preset',
    from = BUILTIN_BY_ID[p.from] and p.from or nil, base = p.base == 'original' and 'original' or 'off',
    layout = str(p.layout, 40), scenarios = {} }
  out.scenarios = M.sanitiseScenarios(p.scenarios)
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
  local edits = type(t.builtinEdits) == 'table' and t.builtinEdits or {}
  for i = 1, #M.BUILTIN do
    local b = M.BUILTIN[i]
    local e = type(edits[b.id]) == 'table' and edits[b.id] or {}
    b.edits = { scenarios = M.sanitiseScenarios(e.scenarios),
      base = (e.base == 'original' or e.base == 'off') and e.base or nil }
  end
  M.anims = {}
  local list = type(t.anims) == 'table' and t.anims or {}
  for i = 1, math.min(#list, 200) do
    local a = M.sanitiseAnim(list[i])
    if a and not seen[a.id] then
      seen[a.id] = true
      for id in pairs(a.presets) do if not M.get(id) then a.presets[id] = nil end end
      M.anims[#M.anims + 1] = a
    end
  end
  M.nextAnim = math.max(1, math.floor(tonumber(t.nextAnim) or 1))
  for i = 1, #M.anims do
    local n = tonumber(M.anims[i].id:match('%d+')) or 0
    if n >= M.nextAnim then M.nextAnim = n + 1 end
  end
  M.reindex()
  M.version = M.version + 1
end

function M.save()
  local edits = {}
  for i = 1, #M.BUILTIN do
    local b = M.BUILTIN[i]
    if M.isModified(b.id) then edits[b.id] = b.edits end
  end
  M.reindex()
  store.savePresets({ v = 1, nextId = M.nextId, list = M.user, builtinEdits = edits, anims = M.anims,
    nextAnim = M.nextAnim })
  M.version = M.version + 1
end

-- ---------------------------------------------------------------- animations

-- Rebuilds the lookup [presetId][scenarioId]; a scenario ticked in two animations of one preset keeps the first.
function M.reindex()
  animIdx = {}
  for i = 1, #M.anims do
    local a = M.anims[i]
    for id in pairs(a.presets) do
      local t = animIdx[id]
      if not t then t = {}; animIdx[id] = t end
      if not t[a.sc] then t[a.sc] = a end
    end
  end
end

function M.animFor(presetId, scId)
  local t = animIdx[presetId]
  return t and t[scId] or nil
end

function M.anim(id)
  for i = 1, #M.anims do if M.anims[i].id == id then return M.anims[i] end end
  return nil
end

-- Animations of one scenario, in library order (allocates: for UI rebuilds).
function M.animsOf(scId)
  local out = {}
  for i = 1, #M.anims do if M.anims[i].sc == scId then out[#out + 1] = M.anims[i] end end
  return out
end

-- Presets an animation applies to, in the order of M.all() (allocates).
function M.presetsOf(a)
  local out = {}
  if not a then return out end
  local all = M.all()
  for i = 1, #all do if a.presets[all[i].id] then out[#out + 1] = all[i] end end
  return out
end

local function uniqueAnimName(name, except)
  local taken = {}
  for i = 1, #M.anims do if M.anims[i] ~= except then taken[M.anims[i].name] = true end end
  if not taken[name] then return name end
  for i = 2, 99 do
    local n = string.format('%s (%d)', name, i)
    if not taken[n] then return n end
  end
  return name
end

-- Ticks / unticks a preset in an animation (no save). Ticking takes the preset out of the scenario's other animations.
local function tick(a, presetId, on)
  if on then
    for i = 1, #M.anims do
      local o = M.anims[i]
      if o ~= a and o.sc == a.sc then o.presets[presetId] = nil end
    end
    a.presets[presetId] = true
  else
    a.presets[presetId] = nil
  end
  M.reindex()
end

-- New animation of scenario scId with the given look, applying to presetId (optional). Returns it.
function M.newAnim(scId, look, presetId, name)
  if not scenarios.byId[scId] then return nil end
  local a = { id = 'anim:' .. M.nextAnim, sc = scId, look = M.sanitiseLook(look) or {}, presets = {},
    name = uniqueAnimName(cutUtf8(name or scenarios.byId[scId].name, 40)) }
  M.nextAnim = M.nextAnim + 1
  M.anims[#M.anims + 1] = a
  if presetId and M.get(presetId) then tick(a, presetId, true) end
  M.save()
  return a
end

-- Applies (on) or stops applying an animation in a preset. Applying also switches the scenario on in that preset.
function M.assign(animId, presetId, on)
  local a = M.anim(animId)
  local p = M.get(presetId)
  if not a or not p then return false end
  tick(a, presetId, on == true)
  if on then
    local own = M.ownOf(p)
    local e = own[a.sc] or {}
    e.on = true
    own[a.sc] = e
  end
  M.save()
  return true
end

function M.renameAnim(animId, name)
  local a = M.anim(animId)
  if not a or type(name) ~= 'string' then return false end
  name = cutUtf8((name:gsub('^%s+', ''):gsub('%s+$', '')), 40)
  if name == '' then return false end
  a.name = uniqueAnimName(name, a)
  M.save()
  return true
end

function M.deleteAnim(animId)
  for i = 1, #M.anims do
    if M.anims[i].id == animId then
      table.remove(M.anims, i)
      M.save()
      return true
    end
  end
  return false
end

-- A copy of an animation for presetId alone (the original keeps its other presets). Returns the copy.
function M.splitAnim(animId, presetId)
  local a = M.anim(animId)
  if not a then return nil end
  return M.newAnim(a.sc, a.look, presetId, a.name)   -- newAnim keeps a clean copy of the look
end

-- Number of presets an animation applies to.
function M.animCount(a)
  local n = 0
  if a then for _ in pairs(a.presets) do n = n + 1 end end
  return n
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
  local base, own = nil, nil
  if preset.builtin then base, own = preset, preset.edits.scenarios
  else base, own = BUILTIN_BY_ID[preset.from], preset.scenarios end
  local anims = animIdx[preset.id]
  local list = {}
  for i = 1, #scenarios.list do
    local d = scenarios.list[i]
    local e = { id = d.id, def = d, custom = false, name = d.name, cat = d.cat, on = true, prio = d.order, to = d.to,
      look = d.look, param = d.param and d.param.default or nil, order = d.order }
    for pass = 1, 2 do
      local src
      if pass == 1 then src = base and base.scenarios[d.id] else src = own[d.id] end
      if src then
        if src.on ~= nil then e.on = src.on end
        if src.prio then e.prio = src.prio end
        if src.to then e.to = src.to end
        if src.look then e.look = src.look end
        if src.param then e.param = src.param end
      end
    end
    local a = anims and anims[d.id]
    if a then e.look, e.anim = a.look, a end
    list[#list + 1] = e
  end
  for id, o in pairs(own) do
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
    p = { v = 1, from = src.id, base = M.baseOf(src), scenarios = deepCopy(src.edits.scenarios) }
  else
    p = deepCopy(src)
  end
  p.id = newUserId()
  p.name = uniqueName(name or (src.name .. ' (kopie)'))
  p.builtin = nil
  M.user[#M.user + 1] = p
  -- the copy uses the same animations
  for i = 1, #M.anims do
    if M.anims[i].presets[src.id] then M.anims[i].presets[p.id] = true end
  end
  M.save()
  return p.id
end

-- The id that takes an edit: the preset itself (built-ins are edited in place, see M.ownOf).
function M.editable(id)
  if M.get(id) then return id end
  return M.BUILTIN[1].id
end

-- The table that holds a preset's own scenario entries: the overlay of a built-in, else the preset's.
function M.ownOf(p)
  if p.builtin then return p.edits.scenarios end
  return p.scenarios
end

-- Base look of a preset ('off' / 'original'), with a built-in's change.
function M.baseOf(p)
  if not p then return 'off' end
  if p.builtin then return p.edits.base or p.base end
  return p.base
end

-- true when a built-in preset has changes of its own or animations applied to it.
function M.isModified(id)
  local p = BUILTIN_BY_ID[id]
  if not p then return false end
  return next(p.edits.scenarios) ~= nil or p.edits.base ~= nil or (animIdx[id] ~= nil and next(animIdx[id]) ~= nil)
end

-- Back to the built-in's own settings: its changes are cleared and no animation applies to it any more.
function M.resetBuiltin(id)
  local p = BUILTIN_BY_ID[id]
  if not p then return false end
  p.edits = { scenarios = {} }
  for i = 1, #M.anims do M.anims[i].presets[id] = nil end
  M.save()
  return true
end

-- Sets one field of a scenario entry ('on', 'prio', 'to', 'look', 'param', 'name', 'when'); returns the preset id
-- that holds the change (a new one when presetId was built-in).
function M.setScenario(presetId, scId, field, value)
  local id = M.editable(presetId)
  local p = M.get(id)
  if field == 'look' and scenarios.byId[scId] then
    -- the look of a catalogue scenario lives in an animation (shared by the presets ticked in it)
    local a = M.animFor(id, scId)
    if a then
      a.look = M.sanitiseLook(value) or {}
      M.save()
    else
      M.newAnim(scId, value, id)
    end
    return id
  end
  local own = M.ownOf(p)
  local e = own[scId]
  if not e then e = {}; own[scId] = e end
  if field == 'look' then value = M.sanitiseLook(value) end
  if field == 'when' then value = conditions.sanitise(value) end
  if field == 'name' then value = str(value, 40) or 'Vlastní podmínka' end
  if field == 'to' then value = TARGET_OK[value] and value or nil end
  if field == 'param' then
    local d = scenarios.byId[scId]
    value = (d and d.param) and num(value, d.param.min, d.param.max) or nil
  end
  if field == 'prio' then value = num(value, 1, 999) end
  if field == 'on' then value = value == true end
  e[field] = value
  M.save()
  return id
end

function M.setBase(presetId, base)
  local id = M.editable(presetId)
  local p = M.get(id)
  local b = base == 'original' and 'original' or 'off'
  if p.builtin then p.edits.base = b ~= p.base and b or nil else p.base = b end
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
  local own = M.ownOf(M.get(id))
  -- give everything explicit, spaced priorities so a swap is always visible
  for i = 1, #list do
    local e = own[list[i].id] or {}
    e.prio = i * 10
    own[list[i].id] = e
  end
  own[scId].prio, own[other.id].prio = (at + delta) * 10, at * 10
  M.save()
  return id
end

function M.addCustom(presetId)
  local id = M.editable(presetId)
  local p = M.get(id)
  local own = M.ownOf(p)
  local n = 1
  while own['custom:' .. n] do n = n + 1 end
  local scId = 'custom:' .. n
  local last = 0
  local list = M.effective(p)
  for i = 1, #list do if list[i].prio > last then last = list[i].prio end end
  own[scId] = { name = 'Vlastní podmínka ' .. n, on = true, prio = math.min(999, last + 1), to = 'all',
    look = deepCopy(scenarios.CUSTOM_LOOK), when = { { q = 'speed', op = '<', v = 60 } } }
  M.save()
  return id, scId
end

function M.removeScenario(presetId, scId)
  local id = M.editable(presetId)
  M.ownOf(M.get(id))[scId] = nil
  M.save()
  return id
end

-- Renames a user preset; returns false and a Czech reason when the name is empty or taken.
function M.rename(id, name)
  local p = M.get(id)
  if not p or p.builtin then return false, 'Vestavěný preset nejde přejmenovat.' end
  if type(name) ~= 'string' then return false, 'Zadejte jméno.' end
  name = cutUtf8((name:gsub('^%s+', ''):gsub('%s+$', '')), 40)
  if name == '' then return false, 'Zadejte jméno.' end
  for _, o in ipairs(M.all()) do
    if o.id ~= id and o.name == name then return false, 'Preset s tímto názvem už existuje, zvolte jiný.' end
  end
  p.name = name
  M.save()
  return true
end

function M.delete(id)
  for i = 1, #M.user do
    if M.user[i].id == id then
      table.remove(M.user, i)
      for k = 1, #M.anims do M.anims[k].presets[id] = nil end
      M.save()
      return true
    end
  end
  return false
end

function M.deleteAllUser()
  M.user, M.nextId = {}, 1
  M.anims, M.nextAnim = {}, 1
  for i = 1, #M.BUILTIN do M.BUILTIN[i].edits = { scenarios = {} } end
  M.save()
end

-- ---------------------------------------------------------------- export / import

function M.export(id)
  local p = M.get(id)
  if not p then return nil end
  local out
  if p.builtin then out = { v = 1, name = p.name, from = p.id, base = M.baseOf(p), scenarios = deepCopy(p.edits.scenarios) }
  else out = M.sanitise(p); out.id = nil end
  -- the animations it uses go along as plain looks
  for scId, a in pairs(animIdx[id] or {}) do
    local e = out.scenarios[scId] or {}
    e.look = deepCopy(a.look)
    out.scenarios[scId] = e
  end
  return EXPORT_PREFIX .. JSON.stringify(out)
end

-- true when text is one complete JSON object: starts with '{' and its brackets close exactly at the end
-- (counted outside strings). CSP's JSON.parse does not fail on damaged input, so a cut text must be caught here.
function M.balanced(text)
  if text:sub(1, 1) ~= '{' then return false end
  local depth, inString, escaped = 0, false, false
  for i = 1, #text do
    local c = text:sub(i, i)
    if inString then
      if escaped then escaped = false
      elseif c == '\\' then escaped = true
      elseif c == '"' then inString = false end
    elseif c == '"' then inString = true
    elseif c == '{' or c == '[' then depth = depth + 1
    elseif c == '}' or c == ']' then
      depth = depth - 1
      if depth < 0 then return false end
      if depth == 0 and i < #text then return false end
    end
  end
  return depth == 0 and not inString
end

-- Returns the new preset id, or nil and a Czech reason.
function M.import(text)
  if type(text) ~= 'string' then return nil, 'Schránka je prázdná.' end
  local at = text:find(EXPORT_PREFIX, 1, true)
  if not at then return nil, 'Ve schránce není preset LedControl (chybí „LEDCONTROL-PRESET 1“).' end
  local body = text:sub(at + #EXPORT_PREFIX):gsub('^%s+', ''):gsub('%s+$', '')
  if not M.balanced(body) then
    return nil, 'Preset ve schránce je neúplný (text je useknutý), zkopírujte ho znovu celý.'
  end
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
