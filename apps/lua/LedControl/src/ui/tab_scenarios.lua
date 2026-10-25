-- Tab Scénáře: the scenarios of the car's current preset in priority order (grouped by category), each with on/off,
-- priority arrows, Test, a live "svítí teď" mark and its availability on this car; one scenario at a time is expanded
-- with its settings: target, pattern and only the settings the pattern uses (colours, Hz, direction, width, fill zones,
-- fill source), the scenario's parameter, and for custom scenarios the name and the condition rows.
-- Every edit goes through runtime (a built-in preset is copied to a user preset on the first edit, in presets.lua).
-- Slider, colour and name edits are kept here while the control is in use and saved once: on release for sliders and
-- text (ui.itemDeactivatedAfterEdit / ui.itemActive), at most every 0.3 s for the colour picker (its release cannot
-- be seen), so the preset file is not written every frame while dragging. A pending edit is saved before any other
-- edit and goes to the preset it was made in, even when the car switched presets meanwhile (hotkey, preset combo).
-- No allocation per frame: rows, labels and texts are rebuilt only when presets.version, runtime.version, the preset
-- id, the test mode or this tab's own version change; combo contents are module-level functions that read the
-- expanded scenario (X) and the condition row (comboRow) from module-level variables.

local common = require('src/ui/common')
local config = require('src/config')
local runtime = require('src/runtime')
local presets = require('src/presets')
local scenarios = require('src/scenarios')
local patterns = require('src/patterns')
local conditions = require('src/conditions')
local color = require('src/color')

local S = config.S
local M = {}

local floor = math.floor

local WHITE = rgbm(1, 1, 1, 1)
local GREY = rgbm(0.6, 0.6, 0.6, 1)
local DIM = rgbm(0.45, 0.45, 0.45, 1)
local GREEN = rgbm(0.4, 1, 0.5, 1)
local YELLOW = rgbm(1, 0.85, 0.3, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)

local ARROW = vec2(24, 0)
local TEST_SIZE = vec2(44, 0)
local TOGGLE_SIZE = vec2(64, 0)
local SWATCH = vec2(44, 0)
local COMBO_W, SLIDER_W, ROW_Q_W, ROW_OP_W, ROW_V_W = 240, 260, 190, 56, 150
local INDENT = 28

local BF = ui.ButtonFlags
local BUTTON_NONE = BF and BF.None or 0
local BUTTON_DISABLED = BF and BF.Disabled or 0
local PICKER = ui.ColorPickerFlags.PickerHueBar
local COMBO = ui.ComboFlags.None

local SAVE_EVERY = 0.3      -- s between saves when the release of a control cannot be seen
local CONFIRM_TIME = 4
local MAX_ZONES = 8
local MAX_ROWS = 8          -- conditions.sanitise keeps 8 rows
local EMPTY = {}

-- patterns.compile's default fill zones (used when a fill look has none)
local DEFAULT_ZONES = patterns.DEFAULT_ZONES

-- ---------------------------------------------------------------- static texts and labels

local T = {
  intro = 'Nahoře je vyšší priorita: když platí víc scénářů najednou, na každé skupině diod svítí ten výš.'
    .. ' Zaškrtnutí = scénář je zapnutý.',
  cowBuiltin = 'Vestavěný preset zůstane beze změny: první úprava vytvoří vaši vlastní kopii a toto auto ji začne'
    .. ' používat.',
  cowUser = 'Změny se ukládají do tohoto presetu (platí pro všechna auta, která ho používají).',
  base = 'Základ presetu (když žádný scénář nesvítí):',
  testMode = 'Karta Diody teď ukazuje testovací vzor, scénáře na autě neběží.',
  testTip = 'Ukáže scénář na autě na 5 s, i když jeho podmínka teď neplatí.',
  upTip = 'Výš = vyšší priorita',
  downTip = 'Níž = nižší priorita',
  testLater = 'Test se na autě ukáže, až scénáře poběží (viz řádek nahoře).',
  testOff = 'Vypnutý scénář (nebo scénář bez diod na tomto autě) se při Testu na autě neukáže, nejdřív ho zapněte.',
  now = 'svítí teď',
  testing = 'test',
  target = 'Kde svítí:',
  pattern = 'Vzor:',
  dir = 'Směr:',
  src = 'Plnění:',
  frames = 'Snímky tohoto vzoru se kreslí v kartě Editor.',
  noSettings = 'Tento vzor nemá další nastavení.',
  zones = 'Barvy podle zaplnění (každá zóna platí od své hranice):',
  fromStart = 'od začátku',
  carSrcMissing = 'Ne každá dioda cíle má práh otáček z auta: skupiny bez prahů se plní relativně.',
  carSrcHint = '„Podle prahů otáček z auta“ jde jen u aut, která mají práh otáček u každé diody cíle.',
  name = 'Název:',
  rows = 'Svítí, když platí všechny podmínky:',
  noRows = 'Bez podmínky scénář nikdy nesvítí (jen při Testu).',
  waiting = 'Čekám na načtení auta…',
}

local TARGETS, TARGET_NAMES = scenarios.TARGETS, scenarios.TARGET_NAMES
local KINDS, KIND_NAMES, USES = patterns.KINDS, patterns.NAMES, patterns.USES
local DIRS, DIR_NAMES = patterns.DIRS, patterns.DIR_NAMES
local SRCS = { 'relative', 'car' }
local SRC_NAMES = { relative = 'relativně (od začátku po bod řazení)', car = 'podle prahů otáček z auta' }
local QUANTITIES, OPS, OP_NAMES = conditions.QUANTITIES, conditions.OPS, conditions.OP_NAMES

local C1_NAME = { solid = 'Barva', blink = 'Barva', alternate = 'Liché diody', pulse = 'Barva', run = 'Světlo' }
local C2_NAME = { blink = 'Mezi bliknutími', alternate = 'Sudé diody', pulse = 'Útlum do', run = 'Pozadí',
  fill = 'Nerozsvícené diody' }

local function fmtText(s) return (tostring(s or ''):gsub('%%', '%%%%')) end

-- condition value sliders: format and step per quantity
local Q_FMT, Q_STEP = {}, {}
for i = 1, #QUANTITIES do
  local q = QUANTITIES[i]
  local fine = q.id == 'time'
  Q_STEP[q.id] = fine and 0.1 or 1
  Q_FMT[q.id] = (fine and '%.1f' or '%.0f') .. (q.unit and q.unit ~= '' and (' ' .. fmtText(q.unit)) or '')
end

local ZU, ZC, ZR, ZN = {}, {}, {}, {}
for k = 1, MAX_ZONES do
  ZU[k], ZC[k], ZR[k], ZN[k] = '##zu' .. k, '##zc' .. k, 'Odebrat##rmzone' .. k, 'Zóna ' .. k
end
local QL, OPL, VL, VB, RM = {}, {}, {}, {}, {}
for r = 1, MAX_ROWS do
  QL[r], OPL[r], VL[r], VB[r], RM[r] = '##q' .. r, '##op' .. r, '##v' .. r, 'ano##vb' .. r, 'Odebrat##rmrow' .. r
end

-- colour slots of the expanded scenario: 1 = colour 1, 2 = colour 2, 2 + k = fill zone k. The rgbm a colour button
-- edits is kept between frames (the picker keeps its own floats); it is set from the stored colour only when that
-- changed from what the slot last showed and the slot is not being edited.
local NSLOTS = 2 + MAX_ZONES
local COLS, COL_SHOWN, COL_LABEL = {}, {}, {}
for s = 1, NSLOTS do
  COLS[s] = rgbm(0, 0, 0, 1)
  COL_SHOWN[s] = -2
  COL_LABEL[s] = s <= 2 and ('##c' .. s) or ZC[s - 2]
end

local idLabels = {}
local function labelsOf(id)
  local l = idLabels[id]
  if not l then
    l = { on = '##on_' .. id, up = '↑##up_' .. id, down = '↓##dn_' .. id, test = 'Test##test_' .. id,
      open = 'Upravit##ex_' .. id, close = 'Skrýt##ex_' .. id }
    idLabels[id] = l
  end
  return l
end

-- ---------------------------------------------------------------- state

local rows, nRows = {}, 0
local seenPresets, seenRuntime, seenPresetId, seenMode, seenOwn = -1, -1, nil, -1, -1
local own = 0                   -- this tab's version (expanded scenario, ...)
local expanded = nil            -- id of the expanded scenario
local freshC = nil              -- runtime.compiled when it matches the shown preset, else nil
local head = { name = '', note = nil, cow = '', baseOff = true, status = nil, warnings = {}, testMode = false }
local testMsg, testMsgUntil = T.testLater, -1
local confirmDelete = -1
local comboRow = 1
local testQueued = nil          -- id of a Test clicked while the compiled preset was a frame old

-- the expanded scenario, rebuilt with the rows
local X = { id = nil, e = nil, custom = false, p = 'solid', pName = '', uses = EMPTY, to = 'all', toName = '',
  c = { 0, 0 }, c1Name = '', c2Name = '', hz = 2, width = 1, dir = 'left', dirName = '', src = 'relative',
  srcName = '', carSrcOk = false, rpmFill = true, nz = 0, zu = {}, zc = {}, zEnd = 1,
  param = nil, pValue = 0, pFmt = '', name = '', nw = 0, wq = {}, wop = {}, wv = {}, wbool = {}, desc = '' }

-- pending edit of a slider, colour or text control
local K_LOOK, K_PARAM, K_ZONE, K_COLOUR, K_COND, K_NAME = 1, 2, 3, 4, 5, 6
local P = { on = false, label = nil, id = nil, preset = nil, kind = 0, field = nil, slot = 0, num = 0, str = '',
  wait = false, drawn = false }
local lastSave = -10

-- ---------------------------------------------------------------- helpers (edits; they may allocate)

local function num(v, def, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return def end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function snap(v, step, lo, hi)
  v = floor(v / step + 0.5) * step
  if step < 1 then v = floor(v * 1000 + 0.5) / 1000 end
  if v < lo then v = lo end
  if v > hi then v = hi end
  return v
end

local function hexOf(p) return string.format('#%06X', p) end

-- The current effective entry of a scenario in a preset (not the cached one, which may be a frame old).
local function entryIn(preset, id)
  if not (preset and id) then return nil end
  local list = presets.effective(preset)
  for i = 1, #list do if list[i].id == id then return list[i] end end
  return nil
end

local function freshEntry(id) return entryIn(runtime.preset(), id) end

local function lookCopy(e)
  local copy = presets.deepCopy(e.look)
  if type(copy) ~= 'table' then copy = {} end
  return copy
end

-- Flat valid zone list { u, '#RRGGBB', ... } of a look (the default zones when it has none), first start 0.
local function zonesOf(look)
  local z = type(look.zones) == 'table' and look.zones or DEFAULT_ZONES
  local out = {}
  for i = 1, #z - 1, 2 do
    local u, c = tonumber(z[i]), color.parse(z[i + 1], nil)
    if u and c then out[#out + 1] = math.max(0, math.min(1, u)); out[#out + 1] = hexOf(c) end
  end
  if #out == 0 then out[1], out[2] = 0, '#FFFFFF' end
  out[1] = 0
  return out
end

local function setColour(copy, slot, hex)
  if slot <= 2 then
    if type(copy.c) ~= 'table' then copy.c = {} end
    if slot == 2 and copy.c[1] == nil then copy.c[1] = '#FFFFFF' end
    copy.c[slot] = hex
  else
    local z = zonesOf(copy)
    local k = slot - 2
    if z[2 * k] then z[2 * k] = hex end
    copy.zones = z
  end
end

local function cleanName(s)
  s = (tostring(s or ''):gsub('^%s+', ''))
  s = (s:gsub('%s+$', ''))
  if s == '' then return nil end
  if #s > 40 then
    local cut = 40
    while cut > 0 do
      local b = s:byte(cut + 1)
      if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
    end
    s = s:sub(1, cut)
  end
  return s
end

-- Saves the pending edit (if any) into the preset it was made in. When the car switched to another preset meanwhile
-- (preset combo, hotkey), the edit goes to the old preset if that is a user preset, and is dropped for a built-in
-- one (a copy nobody uses would be made); it never lands in the new preset.
local function commit()
  if not P.on then return end
  P.on = false
  own = own + 1            -- rebuild, so a control shows the stored value again (also when nothing was saved)
  local id, here = P.id, P.preset == runtime.presetId
  local preset = here and runtime.preset() or presets.get(P.preset)
  if not preset or (not here and preset.builtin) then return end
  local e = entryIn(preset, id)
  if not e then return end
  local k = P.kind
  local field, value
  if k == K_PARAM then
    field, value = 'param', P.num
  elseif k == K_NAME then
    field, value = 'name', cleanName(P.str)
    if not value then return end
  elseif k == K_COND then
    local w = presets.deepCopy(e.when or {})
    if type(w[P.slot]) ~= 'table' then return end
    w[P.slot].v = P.num
    field, value = 'when', w
  else
    local copy = lookCopy(e)
    if k == K_LOOK then
      copy[P.field] = P.num
    elseif k == K_ZONE then
      local z = zonesOf(copy)
      if z[2 * P.slot - 1] then z[2 * P.slot - 1] = P.num end
      copy.zones = z
    elseif k == K_COLOUR then
      setColour(copy, P.slot, hexOf(P.num))
    end
    field, value = 'look', copy
  end
  if here then runtime.editScenario(id, field, value)
  else presets.setScenario(P.preset, id, field, value) end
  lastSave = runtime.clock
end

-- Immediate edits (combos, checkboxes, buttons) of the expanded scenario: a pending edit is saved first, so both are
-- kept and the pending one goes to the preset it was made in.
local function editField(field, value)
  commit()
  runtime.editScenario(X.id, field, value)
  lastSave = runtime.clock
end

local function editLook(field, value)
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local copy = lookCopy(e)
  copy[field] = value
  runtime.editScenario(X.id, 'look', copy)
  lastSave = runtime.clock
end

-- true when the game can tell this tab that a slider / text field was released
local function releaseVisible()
  return ui.itemDeactivatedAfterEdit ~= nil or ui.itemActive ~= nil
end

-- true while the control with this label (in the expanded scenario of the current preset) holds a pending value
local function pending(label)
  return P.label == label and P.id == X.id and P.preset == runtime.presetId
end

local function pend(label, kind, field, slot, value)
  if P.on and not pending(label) then commit() end
  P.on, P.label, P.id, P.preset = true, label, X.id, runtime.presetId
  P.kind, P.field, P.slot, P.num = kind, field, slot, value
  P.wait = kind ~= K_COLOUR and releaseVisible()
end

-- Called right after the control with this label: saves its pending value once the control is released.
local function released(label)
  if not (P.on and pending(label)) then return end
  P.drawn = true
  local deact, active = ui.itemDeactivatedAfterEdit, ui.itemActive
  if deact and deact() then commit()
  elseif active and not active() then commit() end
end

-- ---------------------------------------------------------------- caches (rebuilt on change)

local function carThresholdsOk(to)
  local lay = runtime.layout
  if not lay or not lay.groups or #lay.groups == 0 then return false end
  local hasRole = {}
  for gi = 1, #lay.groups do hasRole[lay.groups[gi].role] = true end
  local any = false
  for gi = 1, #lay.groups do
    local g = lay.groups[gi]
    -- same target rule as engine.lua: a role the car does not have falls back to the main row
    if to == 'all' or to == g.role or (g.role == 'main' and not hasRole[to]) then
      any = true
      for k = 1, #g.leds do
        local led = lay.leds[g.leds[k]]
        local r = led and tonumber(led.rpm)
        if not r or r <= 0 or r > 50000 then return false end
      end
    end
  end
  return any
end

-- whether a condition row holds for the value x (the operators of conditions.eval)
local function holds(op, x, v)
  if op == '<' then return x < v end
  if op == '<=' then return x <= v end
  if op == '>' then return x > v end
  if op == '>=' then return x >= v end
  if op == '=' then return math.abs(x - v) < 0.5 end
  return math.abs(x - v) >= 0.5
end

local function buildX(e)
  X.id, X.e, X.custom = e.id, e, e.custom == true
  local look = type(e.look) == 'table' and e.look or EMPTY
  local p = patterns.KIND_INDEX[look.p] and look.p or 'solid'
  X.p, X.pName, X.uses = p, KIND_NAMES[p] or p, USES[p] or EMPTY
  X.to = e.to or 'all'
  X.toName = TARGET_NAMES[X.to] or X.to
  local c = type(look.c) == 'table' and look.c or EMPTY
  X.c[1], X.c[2] = color.parse(c[1], 0xFFFFFF), color.parse(c[2], color.OFF)
  X.c1Name, X.c2Name = C1_NAME[p] or 'Barva', C2_NAME[p] or 'Druhá barva'
  X.hz = num(look.hz, 2, 0.05, 30)
  X.width = floor(num(look.width, 1, 1, 64))
  X.dir = DIR_NAMES[look.dir] and look.dir or 'left'
  if X.dir == 'bounce' and p ~= 'run' then X.dir = 'left' end   -- a fill treats 'bounce' as left to right
  X.dirName = DIR_NAMES[X.dir]
  X.src = look.src == 'car' and 'car' or 'relative'
  X.srcName = SRC_NAMES[X.src]
  X.carSrcOk = carThresholdsOk(X.to)
  -- a fill driven by time (start countdown) has nothing to do with RPM thresholds
  X.rpmFill = not (e.def and e.def.value and e.def.id ~= 'shiftLights')
  local z = zonesOf(look)
  X.nz = math.min(MAX_ZONES, #z / 2)
  for k = 1, X.nz do X.zu[k], X.zc[k] = z[2 * k - 1], color.parse(z[2 * k], 0xFFFFFF) end
  X.zEnd = z[2 * X.nz + 1] or 1     -- start of the first zone not shown (an imported look may have more), else 1
  local def = e.def and e.def.param
  X.param = def
  if def then
    X.pValue = num(e.param, def.default or def.min, def.min, def.max)
    X.pFmt = fmtText(def.name) .. ': %.0f' .. (def.unit and def.unit ~= '' and (' ' .. fmtText(def.unit)) or '')
  end
  X.name = e.name or ''
  local w = type(e.when) == 'table' and e.when or EMPTY
  X.nw = math.min(MAX_ROWS, #w)
  for r = 1, X.nw do
    local q = conditions.BY_ID[w[r].q] or QUANTITIES[1]
    X.wq[r], X.wop[r], X.wv[r] = q, w[r].op or '<', tonumber(w[r].v) or 0
    X.wbool[r] = holds(X.wop[r], 1, X.wv[r])   -- "ano" = the row holds while the quantity is on
  end
  X.desc = (X.custom and X.nw > 0) and ('Shrnutí: svítí, když ' .. conditions.describe(w) .. '.') or ''
end

local function rebuild()
  local preset = runtime.preset()
  local list = presets.effective(preset)
  local C = runtime.compiled
  freshC = (C and C.presetId == preset.id and runtime.compiledVersion == presets.version) and C or nil
  local index = {}
  if freshC then for i = 1, #C.scen do index[C.scen[i].id] = i end end
  local lay = runtime.layout
  rows = {}
  local prevCat, found = nil, false
  for i = 1, #list do
    local e = list[i]
    local r = { id = e.id, e = e, on = e.on, l = labelsOf(e.id), name = e.name, first = i == 1, last = i == #list,
      ci = index[e.id], avail = true }
    if e.cat ~= prevCat then r.cat, prevCat = e.cat, e.cat end
    local ok, note = true, nil
    if r.ci then
      local sc = C.scen[r.ci]
      ok, note = sc.avail ~= false, sc.note
    elseif lay and e.def and e.def.avail then
      local okCall, a, b = pcall(e.def.avail, runtime.ST, lay)
      if okCall then ok, note = a ~= false, b end
    end
    r.avail = ok
    if not ok then r.availLine = '      nedostupné: ' .. tostring(note or 'na tomto autě')
    elseif e.custom then
      r.hint = (type(e.when) == 'table' and #e.when > 0) and ('      Svítí, když ' .. conditions.describe(e.when))
        or ('      ' .. T.noRows)
    elseif note then r.hint = '      ' .. tostring(note) end
    r.colour = not ok and DIM or (e.on and WHITE or GREY)
    r.tip = string.format('%s\nKde svítí: %s\nVzor: %s', e.name, TARGET_NAMES[e.to] or tostring(e.to),
      KIND_NAMES[type(e.look) == 'table' and e.look.p or ''] or 'Svítí')
    rows[i] = r
    if e.id == expanded then found = true; buildX(e) end
  end
  nRows = #list
  if not found then expanded = nil; X.id = nil end
  head.name = 'Preset: ' .. tostring(preset.name) .. (preset.builtin and ' (vestavěný)' or ' (vlastní)')
  if preset.builtin then head.note = preset.note
  else
    local from = preset.from and presets.get(preset.from)
    head.note = from and ('Vychází z presetu „' .. from.name .. '“.') or nil
  end
  head.cow = preset.builtin and T.cowBuiltin or T.cowUser
  head.baseOff = preset.base ~= 'original'
  head.testMode = S.testMode ~= runtime.NORMAL
  head.status = nil
  if runtime.state == 'wait' or not lay then head.status = T.waiting
  elseif runtime.state ~= 'run' then
    head.status = 'Scénáře teď na autě neběží: ' .. tostring(runtime.STATES[runtime.state] or runtime.state) .. '.'
  elseif head.testMode then head.status = T.testMode end
  head.warnings = freshC and freshC.warnings or EMPTY
end

local function refresh()
  local pv, rv, pid, mode = presets.version, runtime.version, runtime.presetId, S.testMode
  if pv == seenPresets and rv == seenRuntime and pid == seenPresetId and mode == seenMode and own == seenOwn then
    return
  end
  seenPresets, seenRuntime, seenPresetId, seenMode, seenOwn = pv, rv, pid, mode, own
  if not P.on then P.label = nil end
  rebuild()
end

local function toggle(id)
  commit()
  expanded = expanded ~= id and id or nil
  confirmDelete = -1
  own = own + 1
end

-- ---------------------------------------------------------------- combo contents (module level, no closures)

local function targetItems()
  for i = 1, #TARGETS do
    local t = TARGETS[i]
    if ui.selectable(TARGET_NAMES[t], t == X.to) and t ~= X.to then editField('to', t) end
  end
end

local function patternItems()
  for i = 1, #KINDS do
    local k = KINDS[i]
    if ui.selectable(KIND_NAMES[k], k == X.p) and k ~= X.p then editLook('p', k) end
  end
end

local function dirItems()
  for i = 1, #DIRS do
    local d = DIRS[i]
    if (d ~= 'bounce' or X.p == 'run') and ui.selectable(DIR_NAMES[d], d == X.dir) and d ~= X.dir then
      editLook('dir', d)
    end
  end
end

local function srcItems()
  for i = 1, #SRCS do
    local s = SRCS[i]
    if (s ~= 'car' or X.carSrcOk) and ui.selectable(SRC_NAMES[s], s == X.src) and s ~= X.src then editLook('src', s) end
  end
end

local function editRow(r, q, op, v)
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local w = presets.deepCopy(e.when or {})
  local row = w[r]
  if type(row) ~= 'table' then return end
  if q then row.q = q end
  if op then row.op = op end
  if v then row.v = v end
  runtime.editScenario(X.id, 'when', w)
  lastSave = runtime.clock
end

local function quantityItems()
  local r = comboRow
  local cur = X.wq[r]
  for i = 1, #QUANTITIES do
    local q = QUANTITIES[i]
    if ui.selectable(q.name, q == cur) and q ~= cur then
      if q.bool then editRow(r, q.id, '=', 1)
      else
        local v = X.wv[r]
        if v < q.min or v > q.max or cur.bool then v = q.min + floor((q.max - q.min) / 2) end
        editRow(r, q.id, cur.bool and '<' or X.wop[r], v)
      end
    end
  end
end

local function opItems()
  local r = comboRow
  for i = 1, #OPS do
    local o = OPS[i]
    if ui.selectable(OP_NAMES[o], o == X.wop[r]) and o ~= X.wop[r] then editRow(r, nil, o, nil) end
  end
end

-- ---------------------------------------------------------------- expanded scenario

local function colourCell(slot, name)
  local c = COLS[slot]
  local stored = slot <= 2 and X.c[slot] or X.zc[slot - 2]
  local label = COL_LABEL[slot]
  if not pending(label) and COL_SHOWN[slot] ~= stored then
    c.r, c.g, c.b = color.unpack(stored)
    COL_SHOWN[slot] = stored
  end
  -- the picker edits c in place; a change is seen by comparing (as CSP's Radar app does), not by the return value
  ui.colorButton(label, c, PICKER, SWATCH)
  local p = color.pack(c.r, c.g, c.b)
  if p ~= COL_SHOWN[slot] then
    COL_SHOWN[slot] = p
    pend(label, K_COLOUR, nil, slot, p)
  end
  ui.sameLine()
  ui.text(name)
end

local function lookSlider(label, field, value, lo, hi, fmt, step)
  local shown = pending(label) and P.num or value
  ui.setNextItemWidth(SLIDER_W)
  local v, changed = ui.slider(label, shown, lo, hi, fmt)
  if changed then
    v = snap(v, step, lo, hi)
    if v ~= shown or not P.on then pend(label, K_LOOK, field, 0, v) end
  end
  released(label)
end

local function zonesEditor()
  ui.text(T.zones)
  local nz = X.nz
  for k = 1, nz do
    colourCell(2 + k, ZN[k])
    ui.sameLine()
    if k == 1 then
      common.note(T.fromStart, GREY)
    else
      local label = ZU[k]
      local lo = X.zu[k - 1] * 100
      local hi = (k < nz and X.zu[k + 1] or X.zEnd) * 100
      local shown = (pending(label) and P.num or X.zu[k]) * 100
      ui.setNextItemWidth(SLIDER_W - 60)
      local v, changed = ui.slider(label, shown, lo, hi, 'od %.0f %% řady')
      if changed then
        v = snap(v, 1, lo, hi) / 100
        if v * 100 ~= shown or not P.on then pend(label, K_ZONE, nil, k, v) end
      end
      released(label)
    end
    if nz > 1 then
      ui.sameLine()
      if ui.button(ZR[k]) then
        commit()
        local e = freshEntry(X.id)
        if e then
          local copy = lookCopy(e)
          local z = zonesOf(copy)
          table.remove(z, 2 * k)
          table.remove(z, 2 * k - 1)
          z[1] = 0
          copy.zones = z
          runtime.editScenario(X.id, 'look', copy)
          lastSave = runtime.clock
        end
      end
    end
  end
  if nz < MAX_ZONES and ui.button('Přidat zónu##addzone') then
    commit()
    local e = freshEntry(X.id)
    if e then
      local copy = lookCopy(e)
      local z = zonesOf(copy)
      local last = z[#z - 1]
      z[#z + 1] = floor((last + (1 - last) / 2) * 100 + 0.5) / 100
      z[#z + 1] = '#FFFFFF'
      copy.zones = z
      runtime.editScenario(X.id, 'look', copy)
      lastSave = runtime.clock
    end
  end
end

local function srcRow()
  ui.text(T.src)
  ui.sameLine()
  ui.setNextItemWidth(COMBO_W + 60)
  ui.combo('##sc_src', X.srcName, COMBO, srcItems)
  if not X.carSrcOk then
    common.note(X.src == 'car' and T.carSrcMissing or T.carSrcHint, X.src == 'car' and ORANGE or GREY)
  end
end

local function paramSlider()
  local d = X.param
  local label = '##sc_param'
  local shown = pending(label) and P.num or X.pValue
  ui.setNextItemWidth(SLIDER_W + 80)
  local v, changed = ui.slider(label, shown, d.min, d.max, X.pFmt)
  if changed then
    v = snap(v, 1, d.min, d.max)
    if v ~= shown or not P.on then pend(label, K_PARAM, nil, 0, v) end
  end
  released(label)
end

local function conditionRow(r)
  local q = X.wq[r]
  comboRow = r
  ui.setNextItemWidth(ROW_Q_W)
  ui.combo(QL[r], q.name, COMBO, quantityItems)
  ui.sameLine()
  if q.bool then
    if ui.checkbox(VB[r], X.wbool[r]) then editRow(r, nil, '=', X.wbool[r] and 0 or 1) end
  else
    comboRow = r
    ui.setNextItemWidth(ROW_OP_W)
    ui.combo(OPL[r], OP_NAMES[X.wop[r]] or X.wop[r], COMBO, opItems)
    ui.sameLine()
    local label = VL[r]
    local shown = pending(label) and P.num or X.wv[r]
    local step = Q_STEP[q.id] or 1
    ui.setNextItemWidth(ROW_V_W)
    local v, changed = ui.slider(label, shown, q.min, q.max, Q_FMT[q.id])
    if changed then
      v = snap(v, step, q.min, q.max)
      if v ~= shown or not P.on then pend(label, K_COND, nil, r, v) end
    end
    released(label)
  end
  ui.sameLine()
  if ui.button(RM[r]) then
    commit()
    local e = freshEntry(X.id)
    if e then
      local w = presets.deepCopy(e.when or {})
      table.remove(w, r)
      runtime.editScenario(X.id, 'when', w)
      lastSave = runtime.clock
    end
  end
end

local function customConditions()
  ui.text(T.name)
  ui.sameLine()
  ui.setNextItemWidth(COMBO_W + 60)
  local label = '##sc_name'
  local s, changed, enter = ui.inputText(label, pending(label) and P.str or X.name)
  if changed then
    pend(label, K_NAME, nil, 0, 0)
    P.str = s
  end
  if enter then commit() else released(label) end
  ui.text(T.rows)
  for r = 1, X.nw do conditionRow(r) end
  if X.nw == 0 then common.note(T.noRows, ORANGE) end
  if X.nw < MAX_ROWS and ui.button('Přidat podmínku##addrow') then
    commit()
    local e = freshEntry(X.id)
    if e then
      local w = presets.deepCopy(e.when or {})
      w[#w + 1] = { q = 'speed', op = '<', v = 60 }
      runtime.editScenario(X.id, 'when', w)
      lastSave = runtime.clock
    end
  end
  if X.desc ~= '' then ui.textWrapped(X.desc) end
end

local function deleteButton()
  local now = runtime.clock
  if confirmDelete > now then
    if ui.button('Opravdu smazat? Klikněte znovu##sc_delete') then
      confirmDelete = -1
      P.on = false
      runtime.removeScenario(X.id)
      expanded = nil
      own = own + 1
    end
  elseif ui.button('Smazat tento scénář##sc_delete') then
    confirmDelete = now + CONFIRM_TIME
  end
end

local function details()
  local indent = ui.indent ~= nil
  if indent then ui.indent(INDENT) end
  if X.custom then customConditions() end
  ui.text(T.target)
  ui.sameLine()
  ui.setNextItemWidth(COMBO_W)
  ui.combo('##sc_target', X.toName, COMBO, targetItems)
  ui.text(T.pattern)
  ui.sameLine()
  ui.setNextItemWidth(COMBO_W)
  ui.combo('##sc_pattern', X.pName, COMBO, patternItems)
  local u = X.uses
  if u.c1 then colourCell(1, X.c1Name) end
  if u.c2 then
    if u.c1 then ui.sameLine() end
    colourCell(2, X.c2Name)
  end
  if u.hz then lookSlider('##sc_hz', 'hz', X.hz, 0.1, 20, 'Rychlost: %.1f Hz', 0.1) end
  if u.dir then
    ui.text(T.dir)
    ui.sameLine()
    ui.setNextItemWidth(COMBO_W)
    ui.combo('##sc_dir', X.dirName, COMBO, dirItems)
  end
  if u.width then lookSlider('##sc_width', 'width', X.width, 1, 16, 'Počet diod světla: %.0f', 1) end
  if u.zones then
    zonesEditor()
    if X.rpmFill then srcRow() end
  end
  if u.frames then common.note(T.frames, GREY) end
  if not (u.c1 or u.c2 or u.hz or u.zones or u.frames) then common.note(T.noSettings, GREY) end
  if X.param then paramSlider() end
  if X.custom then deleteButton() end
  if indent then ui.unindent(INDENT) end
  ui.separator()
end

-- ---------------------------------------------------------------- list and header

local function header()
  ui.text(head.name)
  if head.note then ui.textWrapped(head.note) end
  ui.textWrapped(head.cow)
  ui.text(T.base)
  ui.sameLine()
  if ui.radioButton('zhasnuto##base_off', head.baseOff) and not head.baseOff then
    commit()
    runtime.setBase('off')
  end
  ui.sameLine()
  if ui.radioButton('podle auta##base_orig', not head.baseOff) and head.baseOff then
    commit()
    runtime.setBase('original')
  end
  local warnings = head.warnings
  for i = 1, #warnings do common.note(warnings[i], ORANGE) end
  if head.status then
    common.note(head.status, ORANGE)
    if head.testMode and runtime.state == 'run' then
      ui.sameLine()
      if ui.button('Zpět na normální provoz##sc_normal') then runtime.setMode(runtime.NORMAL) end
    end
  end
  if runtime.clock < testMsgUntil then common.note(testMsg, YELLOW) end
  ui.textWrapped(T.intro)
end

-- true when the compiled scenario is a candidate of at least one LED group (an older engine.compile left switched-off
-- scenarios out, so their Test showed nothing)
local function painted(C, sc)
  for gi = 1, #C.groups do
    local cands = C.groups[gi].cands
    for k = 1, #cands do if cands[k] == sc then return true end end
  end
  return false
end

local function running() return runtime.state == 'run' and S.testMode == runtime.NORMAL end

local function test(C, r)
  if running() then
    -- the compiled preset is a frame old (an edit this frame): test once runtime has compiled it again
    if not C then testQueued = r.id; return end
    runtime.testScenario(r.id)
    local sc = r.ci and C.scen[r.ci]
    if sc and painted(C, sc) then return end
    testMsg = T.testOff
  else
    testMsg = T.testLater
  end
  testMsgUntil = runtime.clock + CONFIRM_TIME
end

local function list()
  local C = runtime.compiled == freshC and freshC or nil
  local live = C ~= nil and running()      -- scenario states are frozen while the engine does not run
  local t = runtime.ST.t
  for i = 1, nRows do
    local r = rows[i]
    local l = r.l
    if r.cat then ui.header(r.cat) end
    if ui.checkbox(l.on, r.on) then
      commit()
      runtime.editScenario(r.id, 'on', not r.on)
      lastSave = runtime.clock
    end
    ui.sameLine()
    if ui.button(l.up, ARROW, r.first and BUTTON_DISABLED or BUTTON_NONE) and not r.first then
      commit()
      runtime.moveScenario(r.id, -1)
    end
    if ui.itemHovered() then ui.setTooltip(T.upTip) end
    ui.sameLine()
    if ui.button(l.down, ARROW, r.last and BUTTON_DISABLED or BUTTON_NONE) and not r.last then
      commit()
      runtime.moveScenario(r.id, 1)
    end
    if ui.itemHovered() then ui.setTooltip(T.downTip) end
    ui.sameLine()
    if ui.button(l.test, TEST_SIZE) then test(C, r) end
    if ui.itemHovered() then ui.setTooltip(T.testTip) end
    ui.sameLine()
    if ui.button(expanded == r.id and l.close or l.open, TOGGLE_SIZE) then toggle(r.id) end
    ui.sameLine()
    common.note(r.name, r.colour)
    if ui.itemHovered() then ui.setTooltip(r.tip) end
    local sc = live and r.ci and C.scen[r.ci]
    if sc then
      if sc.forceUntil > t then
        ui.sameLine()
        common.note(T.testing, YELLOW)
      elseif sc.active then
        ui.sameLine()
        common.note(T.now, GREEN)
      end
    end
    if r.availLine then common.note(r.availLine, DIM)
    elseif r.hint then common.note(r.hint, GREY) end
    if expanded == r.id and X.id == r.id then details() end
  end
end

local function draw()
  if P.on and not P.wait and runtime.clock - lastSave >= SAVE_EVERY then commit() end
  refresh()
  if testQueued then
    if not running() then testQueued = nil
    elseif freshC and runtime.compiled == freshC then
      runtime.testScenario(testQueued)
      testQueued = nil
    end
  end
  P.drawn = false
  header()
  ui.separator()
  list()
  ui.separator()
  if ui.button('Přidat vlastní scénář##addcustom') then
    commit()
    local scId = runtime.addCustom()
    if scId then expanded = scId end
    own = own + 1
  end
  -- a slider / text field that was being edited is not drawn any more (scenario collapsed or removed): save it
  if P.on and P.wait and not P.drawn then commit() end
end

M.draw = draw
M.flush = commit   -- saves a pending slider / colour / name edit now (for a caller that hides the tab)

return M
