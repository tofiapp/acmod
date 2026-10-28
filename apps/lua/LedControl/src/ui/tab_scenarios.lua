-- Tab Scénáře (docs/ledcontrol-ui.md, section "Scénáře"): one line for the base look, then the scenarios of the car's
-- current preset in priority order under small category captions, one row each: on/off, the name (a click expands
-- its settings), a live dot (green = lit now, blue = Test, orange = a layout problem), Test and Výš / Níž. A scenario
-- this car cannot show has a grey name with the reason in "(?)". The expanded scenario is a form of aligned rows with
-- only the settings its pattern uses (patterns.USES), colours via K.colourField, the scenario's parameter, and for
-- custom scenarios the name, the condition rows and Smazat.
-- Every edit goes through runtime into the car's preset (built-ins are edited in place, presets.lua; "Obnovit výchozí"
-- on the base line clears their changes). The look of a catalogue scenario is an animation: the expanded scenario's
-- first rows pick one (or "Vzhled presetu"), rename it, tick the presets it applies to, split or delete it.
-- Slider, colour and name edits are kept here while the control is in use and saved once: on release for sliders and
-- text (ui.itemDeactivatedAfterEdit / ui.itemActive), at most every 0.3 s for the colour picker (its release cannot
-- be seen), so the preset file is not written every frame while dragging. A pending edit is saved before any other
-- edit and goes to the preset it was made in, even when the car switched presets meanwhile (hotkey, preset combo);
-- main.lua calls M.flush when the tab is hidden.
-- No allocation per frame: rows, labels and texts are rebuilt only when presets.version, runtime.version, the preset
-- id, the test mode or this tab's own version change; combo contents are module-level functions that read the
-- expanded scenario (X) and the condition row (comboRow) from module-level variables.
-- CSP calls besides the kit: ui.selectable(label, selected, flags, size) (TrackCoordinatesHelper), ui.measureText
-- (WebBrowser), ui.setNextItemIcon (AISplineEditor, RGBControl), ui.Icons.ArrowUp / ArrowDown (RGBControl),
-- ui.Icons.Cancel (WebBrowser), ui.Icons.Plus (RGBControl), ui.indent / unindent (official android_auto apps).

local csp = require('src/csp')
local ui, vec2, rgbm = csp.ui, csp.vec2, csp.rgbm
local K = require('src/ui/kit')
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

-- columns of a scenario row (px from the window's left edge; the window is 560 px, rows end before 520)
local COL_DOT, COL_TEST, COL_UP, COL_DOWN = 330, 348, 398, 424
local NAME_MAX = COL_DOT - 68          -- the checkbox before the name, a "(?)" after it
local TEST_SIZE = vec2(44, 0)
local INDENT = 20                      -- the expanded scenario's form
local ZONE_SLIDER_W, ZONE_RM_X = 110, 466
local Q_W, OP_W, V_W, COND_RM_X = 160, 48, 120, 490
local GAP = vec2(0, 4)

local TEXT = ui.StyleColor and ui.StyleColor.Text or nil
local COMBO = ui.ComboFlags.None
local ICONS = ui.Icons
local ICON_UP, ICON_DOWN = ICONS.ArrowUp, ICONS.ArrowDown
local ICON_REMOVE, ICON_ADD = ICONS.Cancel, ICONS.Plus

local SAVE_EVERY = 0.3      -- s between saves when the release of a control cannot be seen
local CONFIRM_TIME = 4
local MSG_TIME, MSG_ACTION_TIME = 4, 8
local MAX_ZONES = 8
local MAX_ROWS = 8          -- conditions.sanitise keeps 8 rows
local EMPTY = {}

-- patterns.compile's default fill zones (used when a fill look has none)
local DEFAULT_ZONES = patterns.DEFAULT_ZONES

-- ---------------------------------------------------------------- static texts and labels

local T = {
  base = 'Základ (když nic nesvítí)',
  baseWhat = 'Co diody ukazují, když žádný scénář nesvítí. Podle auta = diody ovládá auto samo.',
  baseBuiltin = 'Změny se ukládají přímo do vestavěného presetu „%s“ (platí pro všechna auta, která ho používají). '
    .. 'Obnovit výchozí vrátí jeho původní nastavení.',
  reset = 'Obnovit výchozí##resetBuiltin',
  resetConfirm = 'Opravdu obnovit?##resetBuiltin',
  resetDone = 'Preset „%s“ má zase výchozí nastavení.',
  anim = 'Animace',
  animNone = 'Vzhled presetu',
  animNew = 'Nová animace (kopie tohoto vzhledu)',
  animHelp = 'Animace = vzhled scénáře (vzor, barvy, blikání), který můžete použít ve více presetech: zaškrtněte je '
    .. 'v Platí pro. Úprava vzhledu změní animaci ve všech zaškrtnutých presetech.\n\nVzhled presetu = vzhled, '
    .. 'který má jen tento preset. Jeho první úprava z něj udělá animaci.',
  animName = 'Název',
  animFor = 'Platí pro',
  animShared = 'Úprava se projeví ve všech zaškrtnutých presetech.',
  animSplit = 'Jen pro tento preset##sc_animSplit',
  animSplitTip = 'Udělá z animace kopii jen pro tento preset; ostatní presety si nechají původní.',
  animDelete = 'Smazat animaci##sc_animDel',
  animDeleteConfirm = 'Opravdu smazat?##sc_animDel',
  baseUser = 'Změny se ukládají do tohoto presetu „%s“ (platí pro všechna auta, která ho používají).',
  baseFrom = 'Vychází z presetu „%s“.',
  copied = 'Uloženo do vaší kopie „%s“.',
  onTip = 'Zapnout nebo vypnout scénář',
  nameTip = 'Kde: %s, vzor: %s. Kliknutím otevřete nastavení.',
  testTip = 'Ukáže scénář na autě na 5 s, i když jeho podmínka teď neplatí.',
  upTip = 'Výš = vyšší priorita: když platí víc scénářů najednou, na každé skupině diod svítí ten výš.',
  downTip = 'Níž = nižší priorita',
  dotNow = 'Svítí teď',
  dotTest = 'Test',
  unavailable = 'Nedostupné: %s',
  unavailableDefault = 'na tomto autě',
  testLater = 'Test teď nejde: %s.',
  testPattern = 'diody ukazují testovací vzor',
  testNoLeds = 'Test se neukáže: scénář nemá na tomto autě žádné diody.',
  normal = 'Zpět na provoz##sc_normal',
  -- the expanded scenario
  target = 'Kde',
  pattern = 'Vzor',
  hz = 'Blikání',
  dir = 'Směr',
  width = 'Počet diod',
  zones = 'Barvy',
  zonesHelp = 'Každá barva platí od své hranice (v % řady) až k další.',
  fromStart = 'od začátku',
  zonesMax = 'nejvýš 8 barev',
  removeZone = 'Odebrat barvu',
  addZone = 'Přidat barvu##addzone',
  src = 'Plnění',
  carSrcMissing = 'Skupiny bez prahů otáček se plní od začátku po bod řazení.',
  carSrcHint = '„Podle prahů otáček auta“ jde jen u aut, která mají práh otáček u každé diody cíle.',
  frames = 'Snímky',
  framesWhere = 'kreslí se v kartě Editor',
  rpm = 'Otáčky',
  rpmWhere = 'nastavíte v kartě Otáčky',
  targetMissing = 'Auto nemá %s, svítí hlavní řada.',
  startManual = 'U tohoto auta platí začátek nastavený v kartě Otáčky.',
  name = 'Název',
  when = 'Když',
  andWord = 'a',
  noRows = 'Bez podmínky nikdy nesvítí (jen při Testu).',
  removeRow = 'Odebrat podmínku',
  addRow = 'Přidat podmínku##addrow',
  delete = 'Smazat scénář##sc_delete',
  deleteConfirm = 'Opravdu smazat?##sc_delete',
  addCustom = 'Přidat vlastní scénář##addcustom',
  conditionHolds = 'Svítí, když %s.',
}

local BASE_LABELS = { 'Zhasnuto##base_off', 'Podle auta##base_orig' }

local TARGETS, TARGET_NAMES = scenarios.TARGETS, scenarios.TARGET_NAMES
local KINDS, KIND_NAMES, USES = patterns.KINDS, patterns.NAMES, patterns.USES
local DIRS, DIR_NAMES = patterns.DIRS, patterns.DIR_NAMES
local SRCS = { 'relative', 'car' }
local SRC_NAMES = { relative = 'od začátku po bod řazení', car = 'podle prahů otáček auta' }
local QUANTITIES, OPS, OP_NAMES = conditions.QUANTITIES, conditions.OPS, conditions.OP_NAMES

local C1_NAME = { solid = 'Barva', blink = 'Barva', alternate = 'Liché diody', pulse = 'Barva', run = 'Světlo' }
local C2_NAME = { blink = 'Mezi bliknutími', alternate = 'Sudé diody', pulse = 'Útlum do', run = 'Pozadí',
  fill = 'Pozadí' }

local function fmtText(s) return (tostring(s or ''):gsub('%%', '%%%%')) end

-- condition value sliders: format and step per quantity
local Q_FMT, Q_STEP = {}, {}
for i = 1, #QUANTITIES do
  local q = QUANTITIES[i]
  local fine = q.id == 'time'
  Q_STEP[q.id] = fine and 0.1 or 1
  Q_FMT[q.id] = (fine and '%.1f' or '%.0f') .. (q.unit and q.unit ~= '' and (' ' .. fmtText(q.unit)) or '')
end

-- zone labels: start slider, colour button, remove button id (K.iconButton)
local ZU, ZC, ZR = {}, {}, {}
for k = 1, MAX_ZONES do
  ZU[k], ZC[k], ZR[k] = '##zu' .. k, '##zc' .. k, 'rmzone' .. k
end
-- condition row labels: quantity, operator, value, yes / no, remove button id (K.iconButton)
local QL, OPL, VL, VB, RM = {}, {}, {}, {}, {}
for r = 1, MAX_ROWS do
  QL[r], OPL[r], VL[r], VB[r], RM[r] = '##q' .. r, '##op' .. r, '##v' .. r, 'ano##vb' .. r, 'rmrow' .. r
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
    l = { on = '##on_' .. id, up = 'up_' .. id, down = 'dn_' .. id, test = 'Test##test_' .. id }
    idLabels[id] = l
  end
  return l
end

-- category captions in capitals (Czech letters included; string.upper only knows ASCII)
local UPPER = { ['á'] = 'Á', ['č'] = 'Č', ['ď'] = 'Ď', ['é'] = 'É', ['ě'] = 'Ě', ['í'] = 'Í', ['ň'] = 'Ň',
  ['ó'] = 'Ó', ['ř'] = 'Ř', ['š'] = 'Š', ['ť'] = 'Ť', ['ú'] = 'Ú', ['ů'] = 'Ů', ['ý'] = 'Ý', ['ž'] = 'Ž' }
local captions = {}
local function captionOf(cat)
  cat = tostring(cat or '')
  local c = captions[cat]
  if not c then
    c = cat:upper():gsub('[\195\196\197][\128-\191]', UPPER)
    captions[cat] = c
  end
  return c
end

local function firstUpper(s)
  s = tostring(s or '')
  local b = s:byte(1)
  if b and b >= 97 and b <= 122 then return s:sub(1, 1):upper() .. s:sub(2) end
  return s
end

-- ---------------------------------------------------------------- state

local rows, nRows = {}, 0
local seenPresets, seenRuntime, seenPresetId, seenMode, seenOwn = -1, -1, nil, -1, -1
local own = 0                   -- this tab's version (expanded scenario, ...)
local expanded = nil            -- id of the expanded scenario
local freshC = nil              -- runtime.compiled when it matches the shown preset, else nil
local head = { baseOff = true, help = '' }
local confirmDelete = -1
local comboRow = 1
local testQueued = nil          -- id of a Test clicked while the compiled preset was a frame old

-- one short message (feedback of a click) under the row it belongs to ('' = under the base line)
local msg, msgColour, msgId, msgUntil, msgAction = '', K.GREY, nil, -1, false

-- the expanded scenario, rebuilt with the rows
local X = { id = nil, e = nil, custom = false, p = 'solid', pName = '', uses = EMPTY, to = 'all', toName = '', toNote = nil,
  c = { 0, 0 }, c1Name = '', c2Name = '', hz = 2, width = 1, dir = 'left', dirName = '', src = 'relative',
  srcName = '', carSrcOk = false, rpmFill = true, nz = 0, zu = {}, zc = {}, zEnd = 1,
  param = nil, pValue = 0, paramName = '', pFmt = '', name = '', nw = 0, wq = {}, wop = {}, wv = {}, wbool = {},
  warn = nil, shift = false, anim = nil, animName = '', anims = EMPTY, animLabels = EMPTY, ap = EMPTY, apOn = {},
  animShared = false }
local confirmAnim, confirmReset = -1, -1

-- pending edit of a slider, colour or text control
local K_LOOK, K_PARAM, K_ZONE, K_COLOUR, K_COND, K_NAME, K_ANIM_NAME = 1, 2, 3, 4, 5, 6, 7
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

local function flash(text, colour, id, action)
  msg, msgColour, msgId, msgAction = text, colour, id, action == true
  msgUntil = runtime.clock + (action and MSG_ACTION_TIME or MSG_TIME)
end

-- After an edit: remembers when it was saved; when it made a copy of a built-in preset, says so under the row.
local function after(before, id)
  lastSave = runtime.clock
  if before ~= runtime.presetId and presets.isBuiltin(before) then
    flash(string.format(T.copied, tostring(runtime.preset().name)), K.GREEN, id or '')
  end
end

local function edit(id, field, value)
  local before = runtime.presetId
  runtime.editScenario(id, field, value)
  after(before, id)
end

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

-- Saves the pending edit (if any) into the preset it was made in, also when the car switched to another preset
-- meanwhile (preset combo, hotkey); it never lands in the new preset.
local function commit()
  if not P.on then return end
  P.on = false
  own = own + 1            -- rebuild, so a control shows the stored value again (also when nothing was saved)
  if P.kind == K_ANIM_NAME then
    local name = cleanName(P.str)
    if name then presets.renameAnim(P.field, name); lastSave = runtime.clock end
    return
  end
  local id, here = P.id, P.preset == runtime.presetId
  local preset = here and runtime.preset() or presets.get(P.preset)
  if not preset then return end
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
  if here then edit(id, field, value)
  else
    presets.setScenario(P.preset, id, field, value)
    lastSave = runtime.clock
  end
end

-- Immediate edits (combos, checkboxes, buttons) of the expanded scenario: a pending edit is saved first, so both are
-- kept and the pending one goes to the preset it was made in.
local function editField(field, value)
  commit()
  edit(X.id, field, value)
end

local function editLook(field, value)
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local copy = lookCopy(e)
  copy[field] = value
  edit(X.id, 'look', copy)
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

local function buildX(e, r, lay, hasRole)
  X.id, X.e, X.custom = e.id, e, e.custom == true
  local look = type(e.look) == 'table' and e.look or EMPTY
  local p = patterns.KIND_INDEX[look.p] and look.p or 'solid'
  X.p, X.pName, X.uses = p, KIND_NAMES[p] or p, USES[p] or EMPTY
  X.to = e.to or 'all'
  X.toName = TARGET_NAMES[X.to] or X.to
  -- a role the car does not have falls back to the main row (engine.lua)
  X.toNote = nil
  if lay and X.to ~= 'all' and X.to ~= 'main' and not hasRole[X.to] then
    X.toNote = string.format(T.targetMissing, X.toName)
  end
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
  X.shift = e.id == 'shiftLights'
  local z = zonesOf(look)
  X.nz = math.min(MAX_ZONES, #z / 2)
  for k = 1, X.nz do X.zu[k], X.zc[k] = z[2 * k - 1], color.parse(z[2 * k], 0xFFFFFF) end
  X.zEnd = z[2 * X.nz + 1] or 1     -- start of the first zone not shown (an imported look may have more), else 1
  local def = e.def and e.def.param
  X.param = def
  if def then
    X.pValue = num(e.param, def.default or def.min, def.min, def.max)
    X.paramName = tostring(def.name)
    X.pFmt = '%.0f' .. (def.unit and def.unit ~= '' and (' ' .. fmtText(def.unit)) or '')
  end
  X.name = e.name or ''
  local w = type(e.when) == 'table' and e.when or EMPTY
  X.nw = math.min(MAX_ROWS, #w)
  for i = 1, X.nw do
    local q = conditions.BY_ID[w[i].q] or QUANTITIES[1]
    X.wq[i], X.wop[i], X.wv[i] = q, w[i].op or '<', tonumber(w[i].v) or 0
    X.wbool[i] = holds(X.wop[i], 1, X.wv[i])   -- "ano" = the row holds while the quantity is on
  end
  X.warn = r.warn
  -- animation rows (catalogue scenarios only)
  X.anim = (not X.custom) and e.anim or nil
  X.animName = X.anim and X.anim.name or T.animNone
  X.anims, X.animLabels, X.ap = EMPTY, EMPTY, EMPTY
  if not X.custom then
    X.anims = presets.animsOf(e.id)
    X.animLabels = {}
    for i = 1, #X.anims do X.animLabels[i] = X.anims[i].name .. '##an_' .. X.anims[i].id end
  end
  if X.anim then
    X.ap = presets.all()
    for i = 1, #X.ap do
      local id = X.ap[i].id
      X.apOn[i] = X.anim.presets[id] == true
      X.ap[i] = { id = id, label = X.ap[i].name .. '##ap_' .. id }
    end
    X.animShared = presets.animCount(X.anim) > 1
  end
end

local function nameWidth(name)
  local w = ui.measureText and ui.measureText(name).x or #name * 7
  w = floor(w + 8)
  return w > NAME_MAX and NAME_MAX or w
end

local function rebuild()
  local preset = runtime.preset()
  local list = presets.effective(preset)
  local C = runtime.compiled
  freshC = (C and C.presetId == preset.id and runtime.compiledVersion == presets.version) and C or nil
  local index = {}
  if freshC then for i = 1, #C.scen do index[C.scen[i].id] = i end end
  local lay = runtime.layout
  local hasRole = {}
  if lay and lay.groups then for gi = 1, #lay.groups do hasRole[lay.groups[gi].role] = true end end
  rows = {}
  local prevCat, found = nil, false
  for i = 1, #list do
    local e = list[i]
    local r = { id = e.id, e = e, on = e.on, l = labelsOf(e.id), first = i == 1, last = i == #list,
      ci = index[e.id], label = tostring(e.name) .. '##ex_' .. e.id }
    if e.cat ~= prevCat then r.cat, prevCat = captionOf(e.cat), e.cat end
    local ok, note = true, nil
    local sc = r.ci and C.scen[r.ci]
    if sc then
      ok, note = sc.avail ~= false, sc.note
      if sc.layoutOk == false then
        local prefix = tostring(sc.name) .. ':'
        for k = 1, #C.warnings do
          local wtext = C.warnings[k]
          if wtext:sub(1, #prefix) == prefix then r.warn = r.warn and (r.warn .. ' ' .. wtext) or wtext end
        end
      end
    elseif lay and e.def and e.def.avail then
      local okCall, a, b = pcall(e.def.avail, runtime.ST, lay)
      if okCall then ok, note = a ~= false, b end
    end
    if not ok then
      r.help = string.format(T.unavailable, tostring(note or T.unavailableDefault))
    elseif e.custom then
      r.help = (type(e.when) == 'table' and #e.when > 0) and string.format(T.conditionHolds, conditions.describe(e.when))
        or T.noRows
    elseif note and not (e.def and e.def.to == 'side') then
      -- (the note of a side scenario says it falls back to the main row: shown at Kde, for the actual target)
      r.help = firstUpper(note)
    end
    r.colour = not ok and K.DIM or (not e.on and K.GREY or nil)
    r.tip = string.format(T.nameTip, TARGET_NAMES[e.to] or tostring(e.to),
      KIND_NAMES[type(e.look) == 'table' and e.look.p or ''] or KIND_NAMES.solid)
    r.size = vec2(nameWidth(tostring(e.name)), 0)
    rows[i] = r
    if e.id == expanded then found = true; buildX(e, r, lay, hasRole) end
  end
  nRows = #list
  if not found then expanded = nil; X.id = nil end
  local text
  if preset.builtin then
    text = string.format(T.baseBuiltin, tostring(preset.name))
    if preset.note then text = text .. '\n\n' .. preset.note end
  else
    text = string.format(T.baseUser, tostring(preset.name))
    local from = preset.from and presets.get(preset.from)
    if from then text = text .. '\n' .. string.format(T.baseFrom, tostring(from.name)) end
  end
  head.help = T.baseWhat .. '\n\n' .. text
  head.baseOff = presets.baseOf(preset) ~= 'original'
  head.modified = preset.builtin and presets.isModified(preset.id) or false
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
  confirmDelete, confirmAnim = -1, -1
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
  edit(X.id, 'when', w)
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

-- a form row without a label of its own (the control sits in the control column)
local function moreRow() K.label('') end

local function colourCell(slot)
  local c = COLS[slot]
  local stored = slot <= 2 and X.c[slot] or X.zc[slot - 2]
  local label = COL_LABEL[slot]
  if not pending(label) and COL_SHOWN[slot] ~= stored then
    c.r, c.g, c.b = color.unpack(stored)
    COL_SHOWN[slot] = stored
  end
  -- the picker and the quick picks edit c in place; a change is seen by comparing (as CSP's Radar app does)
  K.colourField(label, c)
  local p = color.pack(c.r, c.g, c.b)
  if p ~= COL_SHOWN[slot] then
    COL_SHOWN[slot] = p
    pend(label, K_COLOUR, nil, slot, p)
  end
end

local function colourRow(slot, name)
  K.label(name)
  colourCell(slot)
end

local function lookSlider(name, label, field, value, lo, hi, fmt, step)
  K.label(name)
  local shown = pending(label) and P.num or value
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider(label, shown, lo, hi, fmt)
  if changed then
    v = snap(v, step, lo, hi)
    if v ~= shown or not P.on then pend(label, K_LOOK, field, 0, v) end
  end
  released(label)
end

local function removeZone(k)
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local copy = lookCopy(e)
  local z = zonesOf(copy)
  table.remove(z, 2 * k)
  table.remove(z, 2 * k - 1)
  z[1] = 0
  copy.zones = z
  edit(X.id, 'look', copy)
end

local function addZone()
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local copy = lookCopy(e)
  local z = zonesOf(copy)
  local last = z[#z - 1]
  z[#z + 1] = floor((last + (1 - last) / 2) * 100 + 0.5) / 100
  z[#z + 1] = '#FFFFFF'
  copy.zones = z
  edit(X.id, 'look', copy)
end

local function zonesEditor()
  local nz = X.nz
  for k = 1, nz do
    if k == 1 then K.label(T.zones) else moreRow() end
    colourCell(2 + k)
    ui.sameLine(0, 8)
    if k == 1 then
      K.dim(T.fromStart)
    else
      local label = ZU[k]
      local lo = X.zu[k - 1] * 100
      local hi = (k < nz and X.zu[k + 1] or X.zEnd) * 100
      local shown = (pending(label) and P.num or X.zu[k]) * 100
      ui.setNextItemWidth(ZONE_SLIDER_W)
      local v, changed = ui.slider(label, shown, lo, hi, 'od %.0f %%')
      if changed then
        v = snap(v, 1, lo, hi) / 100
        if v * 100 ~= shown or not P.on then pend(label, K_ZONE, nil, k, v) end
      end
      released(label)
    end
    if nz > 1 then
      ui.sameLine(ZONE_RM_X)
      if K.iconButton(ZR[k], ICON_REMOVE, T.removeZone) then removeZone(k) end
    end
  end
  moreRow()
  if nz < MAX_ZONES then
    if ui.setNextItemIcon then ui.setNextItemIcon(ICON_ADD) end
    if ui.button(T.addZone) then addZone() end
  else
    K.dim(T.zonesMax)
  end
  K.help(T.zonesHelp)
end

local function srcRow()
  K.label(T.src)
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##sc_src', X.srcName, COMBO, srcItems)
  if not X.carSrcOk then
    if X.src == 'car' then K.note(T.carSrcMissing, K.ORANGE) else K.help(T.carSrcHint) end
  end
end

local function paramSlider()
  local d = X.param
  local label = '##sc_param'
  K.label(X.paramName)
  local shown = pending(label) and P.num or X.pValue
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider(label, shown, d.min, d.max, X.pFmt)
  if changed then
    v = snap(v, 1, d.min, d.max)
    if v ~= shown or not P.on then pend(label, K_PARAM, nil, 0, v) end
  end
  released(label)
  if X.shift and runtime.ST.shiftStartManual > 0 then K.help(T.startManual) end
end

local function removeRow(r)
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local w = presets.deepCopy(e.when or {})
  table.remove(w, r)
  edit(X.id, 'when', w)
end

local function addRow()
  commit()
  local e = freshEntry(X.id)
  if not e then return end
  local w = presets.deepCopy(e.when or {})
  w[#w + 1] = { q = 'speed', op = '<', v = 60 }
  edit(X.id, 'when', w)
end

local function conditionRow(r)
  K.label(r == 1 and T.when or T.andWord)
  local q = X.wq[r]
  comboRow = r
  ui.setNextItemWidth(Q_W)
  ui.combo(QL[r], q.name, COMBO, quantityItems)
  ui.sameLine(0, 4)
  if q.bool then
    if ui.checkbox(VB[r], X.wbool[r]) then editRow(r, nil, '=', X.wbool[r] and 0 or 1) end
  else
    comboRow = r
    ui.setNextItemWidth(OP_W)
    ui.combo(OPL[r], OP_NAMES[X.wop[r]] or X.wop[r], COMBO, opItems)
    ui.sameLine(0, 4)
    local label = VL[r]
    local shown = pending(label) and P.num or X.wv[r]
    local step = Q_STEP[q.id] or 1
    ui.setNextItemWidth(V_W)
    local v, changed = ui.slider(label, shown, q.min, q.max, Q_FMT[q.id])
    if changed then
      v = snap(v, step, q.min, q.max)
      if v ~= shown or not P.on then pend(label, K_COND, nil, r, v) end
    end
    released(label)
  end
  ui.sameLine(COND_RM_X)
  if K.iconButton(RM[r], ICON_REMOVE, T.removeRow) then removeRow(r) end
end

local function customRows()
  K.label(T.name)
  ui.setNextItemWidth(K.CONTROL_W)
  local label = '##sc_name'
  local s, changed, enter = ui.inputText(label, pending(label) and P.str or X.name)
  if changed then
    pend(label, K_NAME, nil, 0, 0)
    P.str = s
  end
  if enter then commit() else released(label) end
  for r = 1, X.nw do conditionRow(r) end
  if X.nw == 0 then
    K.label(T.when)
    K.note(T.noRows, K.ORANGE)
  end
  if X.nw < MAX_ROWS then
    moreRow()
    if ui.setNextItemIcon then ui.setNextItemIcon(ICON_ADD) end
    if ui.button(T.addRow) then addRow() end
  end
end

local function deleteButton()
  local now = runtime.clock
  if confirmDelete > now then
    if ui.button(T.deleteConfirm) then
      confirmDelete = -1
      P.on = false
      local before = runtime.presetId
      runtime.removeScenario(X.id)
      after(before, '')
      expanded = nil
      own = own + 1
    end
  elseif ui.button(T.delete) then
    confirmDelete = now + CONFIRM_TIME
  end
end

local function animChanged()
  own = own + 1
  lastSave = runtime.clock
end

local function animItems()
  if ui.selectable(T.animNone, X.anim == nil) and X.anim then
    commit()
    presets.assign(X.anim.id, runtime.presetId, false)
    animChanged()
  end
  for i = 1, #X.anims do
    local a = X.anims[i]
    if ui.selectable(X.animLabels[i], a == X.anim) and a ~= X.anim then
      commit()
      presets.assign(a.id, runtime.presetId, true)
      animChanged()
    end
  end
  if ui.selectable(T.animNew, false) then
    commit()
    local e = freshEntry(X.id)
    if e then presets.newAnim(X.id, lookCopy(e), runtime.presetId) end
    animChanged()
  end
end

local function animRows()
  K.label(T.anim)
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##sc_anim', X.animName, COMBO, animItems)
  K.help(T.animHelp)
  local a = X.anim
  if not a then return end
  K.label(T.animName)
  ui.setNextItemWidth(K.CONTROL_W)
  local label = '##sc_animName'
  local s, changed, enter = ui.inputText(label, pending(label) and P.str or a.name)
  if changed then
    pend(label, K_ANIM_NAME, a.id, 0, 0)
    P.str = s
  end
  if enter then commit() else released(label) end
  for i = 1, #X.ap do
    if i == 1 then K.label(T.animFor) else moreRow() end
    if ui.checkbox(X.ap[i].label, X.apOn[i]) then
      commit()
      presets.assign(a.id, X.ap[i].id, not X.apOn[i])
      animChanged()
    end
  end
  moreRow()
  if X.animShared then
    if ui.button(T.animSplit) then
      commit()
      presets.splitAnim(a.id, runtime.presetId)
      animChanged()
    end
    K.tip(T.animSplitTip)
    ui.sameLine()
  end
  local now = runtime.clock
  if confirmAnim > now then
    if ui.button(T.animDeleteConfirm) then
      confirmAnim = -1
      P.on = false
      presets.deleteAnim(a.id)
      animChanged()
    end
  elseif ui.button(T.animDelete) then
    confirmAnim = now + CONFIRM_TIME
  end
  if X.animShared then K.dim(T.animShared) end
end

local function details()
  local indent = ui.indent ~= nil
  if indent then ui.indent(INDENT) end
  if X.custom then customRows() else animRows() end
  K.label(T.target)
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##sc_target', X.toName, COMBO, targetItems)
  if X.toNote then K.help(X.toNote) end
  K.label(T.pattern)
  ui.setNextItemWidth(K.CONTROL_W)
  ui.combo('##sc_pattern', X.pName, COMBO, patternItems)
  local u = X.uses
  if u.zones then zonesEditor() end
  if u.c1 then colourRow(1, X.c1Name) end
  if u.c2 then colourRow(2, X.c2Name) end
  if u.hz then lookSlider(T.hz, '##sc_hz', 'hz', X.hz, 0.1, 20, '%.1f Hz', 0.1) end
  if u.dir then
    K.label(T.dir)
    ui.setNextItemWidth(K.CONTROL_W)
    ui.combo('##sc_dir', X.dirName, COMBO, dirItems)
  end
  if u.width then lookSlider(T.width, '##sc_width', 'width', X.width, 1, 16, '%.0f', 1) end
  if u.zones and X.rpmFill then srcRow() end
  if u.frames then
    K.label(T.frames)
    K.dim(T.framesWhere)
  end
  if X.warn then K.note(X.warn, K.ORANGE) end
  if X.param then paramSlider() end
  if X.shift then
    K.label(T.rpm)
    K.dim(T.rpmWhere)
  end
  if X.custom then deleteButton() end
  if indent then ui.unindent(INDENT) end
  ui.separator()
end

-- ---------------------------------------------------------------- list and base line

local function message(id)
  if msgId ~= id or runtime.clock >= msgUntil then return end
  K.note(msg, msgColour)
  if msgAction and S.testMode ~= runtime.NORMAL then
    ui.sameLine()
    if ui.button(T.normal) then
      runtime.setMode(runtime.NORMAL)
      msgUntil = -1
    end
  end
end

local function baseLine()
  ui.text(T.base)
  ui.sameLine()
  local pick = K.choice(BASE_LABELS, head.baseOff and 1 or 2)
  K.help(head.help)
  if pick then
    commit()
    local before = runtime.presetId
    runtime.setBase(pick == 1 and 'off' or 'original')
    after(before, '')
  end
  if head.modified then
    ui.sameLine()
    local now = runtime.clock
    if confirmReset > now then
      if ui.button(T.resetConfirm) then
        confirmReset = -1
        commit()
        local name = tostring(runtime.preset().name)
        presets.resetBuiltin(runtime.presetId)
        lastSave = runtime.clock
        own = own + 1
        flash(string.format(T.resetDone, name), K.GREEN, '')
      end
    elseif ui.button(T.reset) then
      confirmReset = now + CONFIRM_TIME
    end
  end
  message('')
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
    flash(T.testNoLeds, K.ORANGE, r.id)
  elseif runtime.state == 'run' then
    flash(string.format(T.testLater, T.testPattern), K.ORANGE, r.id)   -- the header has [Zpět na provoz]
  else
    flash(string.format(T.testLater, tostring(runtime.STATES[runtime.state] or runtime.state)), K.ORANGE, r.id)
  end
end

local function move(r, delta)
  commit()
  local before = runtime.presetId
  runtime.moveScenario(r.id, delta)
  after(before, r.id)
end

local function dot(colour, tip)
  ui.sameLine(COL_DOT)
  K.dot(colour)
  K.tip(tip)
end

local function row(r, C, live, t)
  local l = r.l
  if r.cat then K.caption(r.cat) end
  if ui.checkbox(l.on, r.on) then
    commit()
    edit(r.id, 'on', not r.on)
  end
  K.tip(T.onTip)
  ui.sameLine()
  local colour = r.colour
  if colour and TEXT then ui.pushStyleColor(TEXT, colour) end
  if ui.selectable(r.label, expanded == r.id, 0, r.size) then toggle(r.id) end
  if colour and TEXT then ui.popStyleColor() end
  K.tip(r.tip)
  if r.help then K.help(r.help) end
  local sc = live and r.ci and C.scen[r.ci]
  if sc and sc.forceUntil > t then dot(K.BLUE, T.dotTest)
  elseif sc and sc.active then dot(K.GREEN, T.dotNow)
  elseif r.warn then dot(K.ORANGE, r.warn) end
  ui.sameLine(COL_TEST)
  if ui.button(l.test, TEST_SIZE) then test(C, r) end
  K.tip(T.testTip)
  if not r.first then
    ui.sameLine(COL_UP)
    if K.iconButton(l.up, ICON_UP, T.upTip) then move(r, -1) end
  end
  if not r.last then
    ui.sameLine(COL_DOWN)
    if K.iconButton(l.down, ICON_DOWN, T.downTip) then move(r, 1) end
  end
  message(r.id)
  if expanded == r.id and X.id == r.id then details() end
end

local function list()
  local C = runtime.compiled == freshC and freshC or nil
  local live = C ~= nil and running()      -- scenario states are frozen while the engine does not run
  local t = runtime.ST.t
  for i = 1, nRows do row(rows[i], C, live, t) end
end

local function addCustom()
  commit()
  local before = runtime.presetId
  local scId = runtime.addCustom()
  if scId then expanded = scId end
  after(before, scId)
  own = own + 1
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
  baseLine()
  ui.separator()
  list()
  ui.dummy(GAP)
  if ui.setNextItemIcon then ui.setNextItemIcon(ICON_ADD) end
  if ui.button(T.addCustom) then addCustom() end
  -- a slider / text field that was being edited is not drawn any more (scenario collapsed or removed): save it
  if P.on and P.wait and not P.drawn then commit() end
end

M.draw = draw
M.flush = commit   -- saves a pending slider / colour / name edit now (for a caller that hides the tab)

return M
