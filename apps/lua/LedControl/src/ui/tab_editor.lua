-- Tab Editor: manual presets and frame animations.
-- Preset row: choose, Nový, Kopírovat, Přejmenovat / Smazat (user presets only, delete with an in-window second click),
-- Kopírovat do schránky (presets.export), Vložit ze schránky (presets.import). Animation: the look of one scenario of
-- the current preset (or a new custom one, which can be deleted again with a second click) edited as frames on a local
-- working copy
--   { p = 'frames', fps, rescale, palette = { 9 x '#RRGGBB' }, g = { [group] = { n = cells, f = { frame strings } } } }
-- with '.' transparent (lower scenarios show through), '0' off, '1'..'9' palette (patterns.framesFor). Every group of
-- the copy holds the same number of frames. Grid = one row of cells per LED group of the car in real order; click or
-- drag paints the brush. Uložit = runtime.editScenario(id, 'look', copy); Test na autě = save + runtime.testScenario
-- once the runtime has compiled the saved preset. No allocation per frame: labels are prebuilt or rebuilt only when
-- presets.version, runtime.version, the preset id or the editor's own version change. Unsaved edits are dropped with a
-- message when the car's preset changes from outside the editor (header combo, hotkey, import, delete).

local config = require('src/config')
local runtime = require('src/runtime')
local presets = require('src/presets')
local patterns = require('src/patterns')
local color = require('src/color')
local conditions = require('src/conditions')
local engine = require('src/engine')

local S = config.S
local M = {}

local MAX_GROUPS, MAX_CELLS, MAX_FRAMES = 8, 64, 64
local CONFIRM_TIME, TEST_SECONDS, PENDING_TIME = 4, 5, 2
local floor, min, max = math.floor, math.min, math.max

local GREY = rgbm(0.6, 0.6, 0.6, 1)
local GREEN = rgbm(0.4, 1, 0.5, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)
local RED = rgbm(1, 0.4, 0.35, 1)
local DARK = rgbm(0.1, 0.1, 0.11, 1)
local CHECK_A = rgbm(0.28, 0.28, 0.3, 1)
local CHECK_B = rgbm(0.45, 0.45, 0.48, 1)
local OUTLINE = rgbm(1, 1, 1, 0.9)
local SELECTED = rgbm(1, 0.8, 0.2, 1)

local CELL_SIZE = vec2(22, 22)
local CELL_GAP = 3
local CELL_STEP = 25
local BTN_AUTO = vec2(0, 0)
local FRAME_SIZE = vec2(38, 0)
local FRAME_STEP = 42
local PREVIEW_CELL, PREVIEW_STEP = 10, 12
local ROW_X = 110
local Q1, Q2, P1, P2, O1, O2 = vec2(), vec2(), vec2(), vec2(), vec2(), vec2()

-- flags (enums from the SDK: ac_ui_enums.lua ButtonFlags / HoveredFlags / ColorPickerFlags)
local DISABLED = ui.ButtonFlags and ui.ButtonFlags.Disabled or 0
local HOVER_DRAG = ui.HoveredFlags and ui.HoveredFlags.AllowWhenBlockedByActiveItem or 0
local PICKER = ui.ColorPickerFlags.PickerHueBar
local TEXT_COLOUR = ui.StyleColor and ui.StyleColor.Text

local DEFAULT_PALETTE = { '#FF0000', '#00FF00', '#0000FF', '#FFC800', '#FFFFFF', '#FF5000', '#A000FF', '#00C8FF',
  '#FF40A0' }

local L = {
  presetCombo = '##edPreset', new = 'Nový##edNew', copy = 'Kopírovat##edCopy', rename = 'Přejmenovat##edRename',
  delete = 'Smazat##edDelete', deleteConfirm = 'Opravdu smazat? Klikněte znovu##edDelete',
  export = 'Kopírovat do schránky##edExport', import = 'Vložit ze schránky##edImport', renameText = '##edRenameText', renameOk = 'Uložit název##edRenameOk',
  renameCancel = 'Zrušit##edRenameCancel', scenarioCombo = '##edScenario', newAnim = 'Nová vlastní animace##edScNew',
  on = 'Scénář zapnutý##edOn', delAnim = 'Smazat animaci##edScDel',
  delAnimConfirm = 'Opravdu smazat animaci? Klikněte znovu##edScDel', fit = 'Přizpůsobit počtu diod##edFit',
  rescale = 'Na autě s jiným počtem diod snímky přepočítat##edRescale', add = 'Přidat snímek##edAdd',
  dup = 'Duplikovat##edDup', delFrame = 'Smazat snímek##edDelFrame', left = '< Posunout##edLeft',
  right = 'Posunout >##edRight', fill = 'Vyplnit štětcem##edFill', fps = '##edFps', save = 'Uložit##edSave',
  test = 'Test na autě##edTest', discard = 'Zahodit změny##edDiscard',
}
M.LABELS = L

local T = {
  hint = 'Vestavěné presety (F1 styl, GT3 styl, Minimální) jsou relativní – sedí na libovolný počet diod. '
    .. 'Vlastní animace níže se kreslí po diodách tohoto auta. Úpravou vestavěného presetu vznikne jeho kopie.',
  builtinNote = 'Vestavěný preset nejde přejmenovat ani smazat, nejdřív ho zkopírujte.',
  waiting = 'Čekám na načtení auta…',
  noLeds = 'Auto nemá rozpoznané diody – editor snímků potřebuje znát jejich počet (karta Diody: Vybrat diody ručně).',
  pick = 'Vyberte scénář, jehož vzhled chcete kreslit po snímcích, nebo založte novou vlastní animaci.',
  pickPreview = 'Vyberte animaci…',
  brush = 'Štětec:', palette = 'Barvy 1–9:', frames = 'Snímky (klik = vybrat):',
  gridHint = 'Klik nebo tažení myší maluje štětcem. Najetím na buňku dioda na autě bliká.',
  fpsFormat = 'Rychlost: %.1f snímků/s',
  rescaleNote = 'Bez toho se scénář na autě s jiným počtem diod vypne.',
  unsaved = 'neuloženo',
  offNote = 'Scénář je vypnutý: na autě se ukáže jen tlačítkem Test na autě.',
  dropped = 'Preset auta se změnil: neuložené změny animace jsou zahozené.',
  nameTaken = 'Preset s tímto názvem už existuje, zvolte jiný.',
  nameEmpty = 'Název nesmí být prázdný.',
}

-- prebuilt per frame labels
local CELL = {}
for gi = 1, MAX_GROUPS do
  CELL[gi] = {}
  for k = 1, MAX_CELLS do CELL[gi][k] = '##edCell' .. gi .. '_' .. k end
end
local FRAME_LABEL, FRAME_ACTIVE = {}, {}
for i = 1, MAX_FRAMES do
  FRAME_LABEL[i] = i .. '##edFrame' .. i
  FRAME_ACTIVE[i] = '[' .. i .. ']##edFrame' .. i
end
local BRUSH_CHAR, BRUSH_BYTE, BRUSH_LABEL, BRUSH_TIP, BRUSH_NAME = {}, {}, {}, {}, {}
for b = 1, 11 do
  local ch = b == 1 and '.' or tostring(b - 2)
  BRUSH_CHAR[b], BRUSH_BYTE[b], BRUSH_LABEL[b] = ch, ch:byte(), '##edBrush' .. ch
  if b == 1 then
    BRUSH_TIP[b] = 'Průhledná: propustí scénáře s nižší prioritou'
    BRUSH_NAME[b] = 'štětec: průhledná'
  elseif b == 2 then
    BRUSH_TIP[b] = 'Zhasnuto'
    BRUSH_NAME[b] = 'štětec: zhasnuto'
  else
    BRUSH_TIP[b] = 'Barva ' .. (b - 2)
    BRUSH_NAME[b] = 'štětec: barva ' .. (b - 2)
  end
end
local PAL_LABEL, PAL_EDIT, PAL_DRAW, palHex = {}, {}, {}, {}
for i = 1, 9 do
  PAL_LABEL[i] = '##edPal' .. i
  PAL_EDIT[i] = rgb(1, 1, 1)        -- kept between frames: the picker keeps its own colour (no re-read from hex)
  PAL_DRAW[i] = rgbm(1, 1, 1, 1)
  palHex[i] = ''
end
local PREVIEW_SIZE = {}
for gi = 1, MAX_GROUPS do PREVIEW_SIZE[gi] = vec2(10, PREVIEW_CELL) end

-- ---------------------------------------------------------------- state

local work, baseline = nil, nil   -- working copy; normalised stored look (false: the stored look is not frames)
local workPreset, workScenario = nil, nil
local sel, selEntry = nil, nil    -- selected scenario id and its effective entry
local nFrames, cur = 1, 1
local brushIndex = 3              -- '1'
local dirty, touched = false, false
local ver = 0
local painting = false
local renameFor, renameText = nil, ''   -- preset id whose name is being edited
local confirmId, confirmUntil = nil, -1
local confirmScId, confirmScUntil = nil, -1   -- custom animation asked to be deleted
local pendingTest, pendingUntil, testUntil = nil, -1, -1
local presetMsg, presetMsgColour, presetMsgUntil = '', GREEN, -1
local editMsg, editMsgColour, editMsgUntil = '', GREEN, -1

-- caches (rebuilt in refresh)
local presetItems, scItems = {}, {}
local scPreview = T.pickPreview
local layoutGroups = 0
local groupLabel, groupNote, warnLines = {}, {}, {}
local hasMismatch = false
local lookNote, condNote = nil, nil
local frameInfo, previewLabel = '', ''

local function sayPreset(text, colour)
  presetMsg, presetMsgColour, presetMsgUntil = text, colour or GREEN, runtime.clock + 6
end
local function sayEdit(text, colour)
  editMsg, editMsgColour, editMsgUntil = text, colour or GREEN, runtime.clock + 6
end

local function plural(n, one, few, many)
  if n == 1 then return one end
  if n >= 2 and n <= 4 then return few end
  return many
end

-- At most maxBytes bytes of s without splitting a UTF-8 character (presets.rename cuts at 40 bytes blindly).
local function cutUtf8(s, maxBytes)
  if #s <= maxBytes then return s end
  local cut = maxBytes
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b < 0x80 or b >= 0xC0 then break end   -- the next byte starts a character: cut here
    cut = cut - 1
  end
  return s:sub(1, cut)
end
M.cutUtf8 = cutUtf8

-- Coloured text that wraps at the window edge (long Czech notes would be cut off by ui.textColored).
local function note(text, colour)
  if TEXT_COLOUR and ui.pushStyleColor then
    ui.pushStyleColor(TEXT_COLOUR, colour)
    ui.textWrapped(text)
    ui.popStyleColor()
  else
    ui.textColored(text, colour)
  end
end

-- ---------------------------------------------------------------- working copy helpers

local function hexOf(v)
  local p = color.parse(v, nil)
  if p and p >= 0 then return color.hex(p) end
  return nil
end

-- One frame string resampled to n cells by nearest-centre sampling (as patterns.framesFor does on the car).
local function resample(s, n)
  local len = #s
  if len == n then return s end
  if len == 0 then return string.rep('0', n) end
  local out = {}
  for k = 1, n do
    -- same rule as patterns.framesFor: mirrored halves, a tie goes to the outer cell
    local m = (2 * k <= n) and k or (n + 1 - k)
    local src = floor((m - 0.5) * len / n + 1 - 1e-6)
    if src < 1 then src = 1 end
    if m ~= k then src = len + 1 - src end
    out[k] = s:sub(src, src)
  end
  return table.concat(out)
end
M.resample = resample

local function cleanFrame(v)
  if type(v) ~= 'string' then return '' end
  return (v:gsub('[^%.0-9]', '0'):sub(1, MAX_CELLS))
end

local function same(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function groupSize(gi)
  local lay = runtime.layout
  local g = lay and lay.groups[gi]
  if not g then return 0 end
  return max(1, min(#g.leds, MAX_CELLS))
end

-- Clean working copy of a stored frames look (nil = a fresh animation: one frame per group, all cells off).
local function normalise(look)
  local w = { p = 'frames', fps = 4, rescale = true, palette = {}, g = {} }
  if look then
    local fps = tonumber(look.fps)
    if fps and fps == fps then w.fps = max(0.2, min(30, fps)) end
    w.rescale = look.rescale ~= false
  end
  local pal = look and type(look.palette) == 'table' and look.palette or nil
  for i = 1, 9 do
    -- the engine shows a missing palette entry white; a fresh animation starts with the default palette
    w.palette[i] = hexOf(pal and pal[i]) or (look and '#FFFFFF' or DEFAULT_PALETTE[i])
  end
  local frames = 0
  if look and type(look.g) == 'table' then
    for key, g in pairs(look.g) do
      local gi = floor(tonumber(key) or 0)
      if gi >= 1 and gi <= MAX_GROUPS and type(g) == 'table' and type(g.f) == 'table' and #g.f > 0 then
        local n = max(1, min(MAX_CELLS, floor(tonumber(g.n) or 1)))
        local e = { n = n, f = {} }
        for fi = 1, min(#g.f, MAX_FRAMES) do e.f[fi] = resample(cleanFrame(g.f[fi]), n) end
        w.g[gi] = e
        if #e.f > frames then frames = #e.f end
      end
    end
  end
  if frames == 0 then frames = 1 end
  local lay = runtime.layout
  local fill = look and '.' or '0'    -- a group without frames is transparent on the car, same as '.'
  if lay then
    for gi = 1, min(#lay.groups, MAX_GROUPS) do
      if not w.g[gi] then
        local n = groupSize(gi)
        local e = { n = n, f = {} }
        for fi = 1, frames do e.f[fi] = string.rep(fill, n) end
        w.g[gi] = e
      end
    end
  end
  for _, e in pairs(w.g) do
    local k = #e.f
    for fi = k + 1, frames do e.f[fi] = e.f[(fi - 1) % k + 1] end
  end
  return w, frames
end
M.normalise = normalise

local function syncPalette()
  for i = 1, 9 do
    local hex = work.palette[i]
    if hex ~= palHex[i] then
      local r, g, b = color.unpack(color.parse(hex, 0xFFFFFF))
      PAL_EDIT[i].r, PAL_EDIT[i].g, PAL_EDIT[i].b = r, g, b
      PAL_DRAW[i].r, PAL_DRAW[i].g, PAL_DRAW[i].b = r, g, b
      palHex[i] = hex
    end
  end
end

local function isFramesLook(look)
  return type(look) == 'table' and look.p == 'frames' and type(look.g) == 'table'
end

local function loadWork()
  local look = selEntry and selEntry.look
  local frames = isFramesLook(look)
  work, nFrames = normalise(frames and look or nil)
  baseline = frames and presets.deepCopy(work) or false
  dirty, touched = false, false     -- a scenario that is no animation yet is only shown: nothing changed
  workPreset, workScenario = runtime.presetId, sel
  if cur > nFrames then cur = nFrames end
  if cur < 1 then cur = 1 end
  syncPalette()
end

-- Groups the car has but the copy does not (layout changed while editing): transparent, also in the baseline.
local function ensureGroups()
  local lay = runtime.layout
  if not (work and lay) then return end
  for gi = 1, min(#lay.groups, MAX_GROUPS) do
    if not work.g[gi] then
      local n = groupSize(gi)
      local e = { n = n, f = {} }
      for fi = 1, nFrames do e.f[fi] = string.rep('.', n) end
      work.g[gi] = e
      if baseline and not baseline.g[gi] then baseline.g[gi] = presets.deepCopy(e) end
    end
  end
end

local function edited()
  touched = true
  dirty = not (baseline and same(work, baseline))
  ver = ver + 1
end

-- ---------------------------------------------------------------- caches

local function rebuildLists()
  presetItems = {}
  local all = presets.all()
  for i = 1, #all do
    presetItems[i] = { id = all[i].id, label = all[i].name .. '##edPreset:' .. all[i].id }
  end
  scItems = {}
  local list = presets.effective(runtime.preset())
  for i = 1, #list do
    local e = list[i]
    local frames = isFramesLook(e.look)
    scItems[i] = { id = e.id, entry = e, frames = frames,
      label = e.name .. (frames and ' – vlastní snímky' or '') .. '##edSc:' .. e.id }
  end
  selEntry = nil
  if sel then
    for i = 1, #scItems do if scItems[i].id == sel then selEntry = scItems[i].entry end end
    if not selEntry then sel, work, baseline, dirty = nil, nil, nil, false end
  end
  if not sel then
    -- default: the first custom animation, else the first scenario that already has frames
    for pass = 1, 2 do
      for i = 1, #scItems do
        local it = scItems[i]
        if not sel and it.frames and (pass == 2 or it.entry.custom) then sel, selEntry = it.id, it.entry end
      end
    end
  end
end

local function rebuildTexts()
  local lay = runtime.layout
  layoutGroups = lay and min(#lay.groups, MAX_GROUPS) or 0
  groupLabel, groupNote, warnLines = {}, {}, {}
  hasMismatch = false
  scPreview = selEntry and selEntry.name or T.pickPreview
  local C = runtime.compiled
  -- the runtime compiles only in normal operation: a compile of another preset (or an older version) says nothing
  if C and (C.presetId ~= runtime.presetId or runtime.compiledVersion ~= presets.version) then C = nil end
  local sc = C and sel and engine.find(C, sel) or nil
  for gi = 1, layoutGroups do
    local g = lay.groups[gi]
    local n = #g.leds
    groupLabel[gi] = string.format('%s – %d %s', g.name, n, plural(n, 'dioda', 'diody', 'diod'))
    local cg = sc and C.groups[gi]
    if cg then
      local targeted = false
      for i = 1, #cg.cands do if cg.cands[i] == sc then targeted = true end end
      if not targeted then groupNote[gi] = '(sem tento scénář nesvítí)' end
    end
    local w = work and work.g[gi]
    if w and w.n ~= groupSize(gi) then
      hasMismatch = true
      warnLines[#warnLines + 1] = string.format('Skupina %s: snímky jsou pro %d %s, auto má %d %s.', g.name, w.n,
        plural(w.n, 'diodu', 'diody', 'diod'), n, plural(n, 'diodu', 'diody', 'diod'))
    end
  end
  if hasMismatch then
    warnLines[#warnLines + 1] = work.rescale
      and 'Na autě se snímky přepočítají na skutečný počet diod. Tlačítkem je přizpůsobíte natrvalo a můžete je dokreslit.'
      or 'Bez přepočtu se tento scénář na autě vypne. Zapněte přepočet níže nebo snímky přizpůsobte tlačítkem.'
  end
  if lay and #lay.groups > MAX_GROUPS then
    warnLines[#warnLines + 1] = string.format('Auto má %d skupin diod, editor ukazuje prvních %d.', #lay.groups, MAX_GROUPS)
  end
  lookNote, condNote = nil, nil
  if selEntry then
    local look = selEntry.look
    if not isFramesLook(look) then
      local kind = type(look) == 'table' and look.p or 'solid'
      lookNote = string.format('Scénář „%s“ teď používá vzor „%s“. Uložením ho nahradíte vlastními snímky.',
        selEntry.name, patterns.NAMES[kind] or kind)
    end
    if selEntry.custom then
      condNote = 'Ukáže se, když: ' .. conditions.describe(selEntry.when) .. ' (podmínku změníte v kartě Scénáře).'
    end
  end
  if work then
    frameInfo = string.format('Snímek %d z %d', cur, nFrames)
    previewLabel = string.format('Náhled animace (%d %s, %.1f snímků/s):', nFrames,
      plural(nFrames, 'snímek', 'snímky', 'snímků'), work.fps)
  end
end

local seenPresets, seenRuntime, seenPresetId, seenVer = -1, -1, nil, -1

local function refresh()
  local pv, rv, pid = presets.version, runtime.version, runtime.presetId
  if pv == seenPresets and rv == seenRuntime and pid == seenPresetId and ver == seenVer then return end
  local presetChanged = pv ~= seenPresets or pid ~= seenPresetId
  local runtimeChanged = rv ~= seenRuntime
  seenPresets, seenRuntime, seenPresetId = pv, rv, pid
  -- every editor action that switches the car's preset moves the working copy along (workPreset); anything else
  -- (header combo, hotkey, import, delete) drops the unsaved edits, so say so
  local dropped = dirty and work ~= nil and workPreset ~= pid
  if presetChanged then rebuildLists() end
  if sel and runtime.layout then
    if work == nil or workPreset ~= pid or workScenario ~= sel or (not dirty and (presetChanged or runtimeChanged)) then
      loadWork()
    elseif runtimeChanged then
      ensureGroups()
    end
  elseif dropped then
    work, baseline, dirty = nil, nil, false
  end
  if dropped then sayEdit(T.dropped, ORANGE) end
  rebuildTexts()
  seenVer = ver
end

-- ---------------------------------------------------------------- actions

local function paint(gi, k)
  local g = work.g[gi]
  local s = g and g.f[cur]
  if not s or k > #s then return false end
  local b = BRUSH_BYTE[brushIndex]
  if s:byte(k) == b then return false end
  g.f[cur] = s:sub(1, k - 1) .. BRUSH_CHAR[brushIndex] .. s:sub(k + 1)
  edited()
  return true
end

local function save()
  if not (work and sel) then return false end
  local wasBuiltin = presets.isBuiltin(runtime.presetId)
  runtime.editScenario(sel, 'look', work)
  workPreset = runtime.presetId
  baseline = presets.deepCopy(work)
  dirty = false
  ver = ver + 1
  if wasBuiltin then
    sayEdit('Uloženo. Vestavěný preset se nemění: auto teď používá kopii „' .. runtime.preset().name .. '“.')
  else
    sayEdit('Uloženo do presetu „' .. runtime.preset().name .. '“.')
  end
  return true
end

local function testBlocked()
  if runtime.state ~= 'run' then
    return 'Diody nejsou převzaté (' .. (runtime.STATES[runtime.state] or runtime.state) .. '), test se na autě neukáže.'
  end
  if S.testMode ~= runtime.NORMAL then
    return 'Karta Diody ukazuje testovací vzor – přepněte ji na „Normální provoz“, pak se test ukáže.'
  end
  return nil
end

local function testOnCar()
  local why = testBlocked()
  if why then sayEdit(why, ORANGE) return end      -- blocked: nothing is saved (no copy of a built-in preset)
  -- nothing painted on a scenario that is no animation yet: test its current look, do not replace it with dark frames
  if not (baseline == false and not touched) and not save() then return end
  -- the runtime compiles the saved preset in its next update; the test is started on that compiled preset
  pendingTest, pendingUntil = sel, runtime.clock + PENDING_TIME
end

local function runPendingTest()
  if not pendingTest then return end
  if runtime.compiled and runtime.compiledVersion == presets.version then
    runtime.testScenario(pendingTest, TEST_SECONDS)
    testUntil = runtime.clock + TEST_SECONDS
    pendingTest = nil
    sayEdit('Test na autě: animace se ukazuje 5 s.')
  elseif runtime.clock > pendingUntil then
    pendingTest = nil
    sayEdit(testBlocked() or 'Test se nespustil, zkuste to znovu.', ORANGE)
  end
end

local function discard()
  if not (sel and runtime.layout) then return end
  loadWork()
  ver = ver + 1
  sayEdit('Změny jsou zahozené.')
end

local function selectScenario(id)
  if id == sel and work then return end
  if dirty then sayEdit('Neuložené změny předchozí animace jsou zahozené.', ORANGE) end
  sel, cur = id, 1
  for i = 1, #scItems do if scItems[i].id == id then selEntry = scItems[i].entry end end
  if runtime.layout then loadWork() else work = nil end
  ver = ver + 1
end

local function newAnimation()
  local lay = runtime.layout
  if not lay or #lay.leds == 0 then sayEdit(T.noLeds, ORANGE) return end
  if dirty then sayEdit('Neuložené změny předchozí animace jsou zahozené.', ORANGE) end
  local scId = runtime.addCustom()
  if not scId then return end
  local name = 'Vlastní animace ' .. (scId:match('%d+') or '')
  runtime.editScenario(scId, 'name', name)
  sel, selEntry, cur = scId, nil, 1
  work, nFrames = normalise(nil)
  -- stored right away, so the new scenario is an animation from the start (all LEDs off until painted)
  runtime.editScenario(scId, 'look', work)
  workPreset, workScenario = runtime.presetId, scId
  baseline = presets.deepCopy(work)
  dirty = false
  syncPalette()
  ver = ver + 1
  sayEdit('Nová animace „' .. name .. '“ v presetu „' .. runtime.preset().name .. '“. Dokud ji nenakreslíte, zhasíná '
    .. 'diody, když platí její podmínka (změníte v kartě Scénáře).')
end

local function deleteAnimation()
  if not (sel and selEntry and selEntry.custom) then return end
  local name = selEntry.name
  runtime.removeScenario(sel)
  workPreset = runtime.presetId
  sel, selEntry, work, baseline, dirty, cur = nil, nil, nil, nil, false, 1
  ver = ver + 1
  sayEdit('Animace „' .. name .. '“ je smazaná z presetu „' .. runtime.preset().name .. '“.')
end

local function fitToLayout()
  for gi = 1, layoutGroups do
    local g = work.g[gi]
    local n = groupSize(gi)
    if g and g.n ~= n then
      for fi = 1, #g.f do g.f[fi] = resample(g.f[fi], n) end
      g.n = n
    end
  end
  edited()
  sayEdit('Snímky jsou přizpůsobené počtu diod tohoto auta.')
end

-- True when every frame of the group is fully transparent (the animation does not use the group).
local function unusedGroup(g)
  for fi = 1, #g.f do
    if g.f[fi]:find('[^%.]') then return false end
  end
  return true
end

local function frameOp(op)
  if op == 'add' or op == 'dup' then
    if nFrames >= MAX_FRAMES then return end
    for _, g in pairs(work.g) do
      -- an empty frame is off, except in a group this animation leaves transparent everywhere (it stays so)
      local s = g.f[cur]
      if op ~= 'dup' or not s then s = string.rep(unusedGroup(g) and '.' or '0', g.n) end
      table.insert(g.f, cur + 1, s)
    end
    nFrames, cur = nFrames + 1, cur + 1
  elseif op == 'del' then
    if nFrames <= 1 then return end
    for _, g in pairs(work.g) do table.remove(g.f, cur) end
    nFrames = nFrames - 1
    if cur > nFrames then cur = nFrames end
  elseif op == 'left' or op == 'right' then
    local other = op == 'left' and cur - 1 or cur + 1
    if other < 1 or other > nFrames then return end
    for _, g in pairs(work.g) do g.f[cur], g.f[other] = g.f[other], g.f[cur] end
    cur = other
  elseif op == 'fill' then
    for gi = 1, layoutGroups do
      local g = work.g[gi]
      if g then g.f[cur] = string.rep(BRUSH_CHAR[brushIndex], g.n) end
    end
  end
  edited()
end

local function newPreset(copy)
  local from = runtime.preset().name
  local id = presets.create(runtime.presetId, not copy and 'Nový preset' or nil)
  runtime.setPreset(id)
  workPreset = runtime.presetId    -- unsaved edits of the animation move into the new preset
  if copy then
    sayPreset('Kopie „' .. runtime.preset().name .. '“ je vytvořená, auto ji teď používá.')
  else
    renameFor, renameText = runtime.presetId, runtime.preset().name
    sayPreset('Nový preset je vytvořený z „' .. from .. '“, auto ho teď používá. Zadejte jeho název.')
  end
end

local function confirmRename()
  local name = (cutUtf8((renameText:gsub('^%s+', '')), 40):gsub('%s+$', ''))
  if name == '' then sayPreset(T.nameEmpty, RED) return end
  local all = presets.all()
  for i = 1, #all do
    -- two presets with one name could not be told apart in the combos
    if all[i].id ~= runtime.presetId and all[i].name == name then sayPreset(T.nameTaken, RED) return end
  end
  if presets.rename(runtime.presetId, name) then
    renameFor = nil
    sayPreset('Preset se teď jmenuje „' .. runtime.preset().name .. '“.')
  else
    sayPreset(T.nameEmpty, RED)
  end
end

local function deletePreset()
  local id, name = runtime.presetId, runtime.preset().name
  if presets.isBuiltin(id) or not presets.delete(id) then return end
  runtime.setPreset(presets.choose(nil, S.defaultPreset, runtime.layout, runtime.ST.drsPresent))
  sayPreset('Preset „' .. name .. '“ je smazaný, auto teď používá „' .. runtime.preset().name .. '“.')
end

local function exportPreset()
  local text = presets.export(runtime.presetId)
  if not text then return end
  ac.setClipboardText(text)
  sayPreset('Preset „' .. runtime.preset().name .. '“ je ve schránce jako jeden řádek textu.'
    .. (dirty and ' Neuložené změny animace v něm nejsou, nejdřív je uložte.' or ''), dirty and ORANGE or GREEN)
end

local function importPreset()
  local id, why = presets.import(ui.getClipboardText())
  if not id then sayPreset(why or 'Preset ve schránce nejde načíst.', RED) return end
  runtime.setPreset(id)
  sayPreset('Načteno ze schránky: „' .. runtime.preset().name .. '“, auto ho teď používá.')
end

-- ---------------------------------------------------------------- drawing

local function presetComboItems()
  for i = 1, #presetItems do
    local it = presetItems[i]
    if ui.selectable(it.label, it.id == runtime.presetId) and it.id ~= runtime.presetId then
      runtime.setPreset(it.id)    -- unsaved edits are dropped with a message in refresh()
    end
  end
end

local function scenarioComboItems()
  for i = 1, #scItems do
    local it = scItems[i]
    if ui.selectable(it.label, it.id == sel) then selectScenario(it.id) end
  end
  if ui.selectable(L.newAnim, false) then newAnimation() end
end

local function presetRow()
  ui.text('Preset:')
  ui.sameLine(ROW_X)
  ui.setNextItemWidth(240)
  ui.combo(L.presetCombo, runtime.preset().name, ui.ComboFlags.None, presetComboItems)
  local user = not presets.isBuiltin(runtime.presetId)
  if ui.button(L.new) then newPreset(false) end
  ui.sameLine()
  if ui.button(L.copy) then newPreset(true) end
  ui.sameLine()
  if ui.button(L.rename, BTN_AUTO, user and 0 or DISABLED) and user then
    renameFor, renameText = runtime.presetId, runtime.preset().name
  end
  ui.sameLine()
  local now = runtime.clock
  if user and confirmId == runtime.presetId and now < confirmUntil then
    if ui.button(L.deleteConfirm) then
      confirmId = nil
      deletePreset()
    end
  elseif ui.button(L.delete, BTN_AUTO, user and 0 or DISABLED) and user then
    confirmId, confirmUntil = runtime.presetId, now + CONFIRM_TIME
  end
  if ui.button(L.export) then exportPreset() end
  ui.sameLine()
  if ui.button(L.import) then importPreset() end
  if user and renameFor == runtime.presetId then
    ui.setNextItemWidth(240)
    local text, changed, enter = ui.inputText(L.renameText, renameText)
    if changed then renameText = text end
    ui.sameLine()
    if ui.button(L.renameOk) or enter then confirmRename() end
    ui.sameLine()
    if ui.button(L.renameCancel) then renameFor = nil end
  end
  if not user then note(T.builtinNote, GREY) end
  ui.textWrapped(T.hint)
  if now < presetMsgUntil then note(presetMsg, presetMsgColour) end
end

-- One cell: palette colour, dark for off, a checker for transparent.
local function drawCell(p1, p2, b)
  if b == 46 then
    ui.drawRectFilled(p1, p2, CHECK_A, 0)
    local mx, my = (p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5
    ui.drawRectFilled(Q1:set(p1.x, p1.y), Q2:set(mx, my), CHECK_B, 0)
    ui.drawRectFilled(Q1:set(mx, my), Q2:set(p2.x, p2.y), CHECK_B, 0)
  else
    local d = b and b - 48 or 0
    ui.drawRectFilled(p1, p2, (d >= 1 and d <= 9) and PAL_DRAW[d] or DARK, 3)
  end
end

local function outline(p1, p2, c, grow)
  ui.drawRect(O1:set(p1.x - grow, p1.y - grow), O2:set(p2.x + grow, p2.y + grow), c)
end

local function brushRow()
  ui.text(T.brush)
  for b = 1, 11 do
    ui.sameLine(b == 1 and ROW_X or 0, 4)
    local clicked = ui.invisibleButton(BRUSH_LABEL[b], CELL_SIZE)
    local r1, r2 = ui.itemRect()
    drawCell(r1, r2, BRUSH_BYTE[b])
    if b == brushIndex then
      outline(r1, r2, SELECTED, 1)
      outline(r1, r2, SELECTED, 2)
    end
    if ui.itemHovered() then ui.setTooltip(BRUSH_TIP[b]) end
    if clicked then brushIndex = b end
  end
  ui.sameLine()
  ui.text(BRUSH_NAME[brushIndex])
  ui.text(T.palette)
  for i = 1, 9 do
    ui.sameLine(i == 1 and ROW_X + 2 * (CELL_SIZE.x + 4) or 0, 4)
    if ui.colorButton(PAL_LABEL[i], PAL_EDIT[i], PICKER, CELL_SIZE) then
      local c = PAL_EDIT[i]
      PAL_DRAW[i].r, PAL_DRAW[i].g, PAL_DRAW[i].b = c.r, c.g, c.b
      local hex = color.hex(color.pack(c.r, c.g, c.b))
      palHex[i] = hex
      work.palette[i] = hex
      edited()
    end
    if ui.itemClicked() then brushIndex = i + 2 end
  end
end

local function grid()
  local lay = runtime.layout
  local down = ui.mouseDown()
  if not down then painting = false end
  local perRow = max(1, floor((ui.availableSpaceX() + CELL_GAP) / CELL_STEP))
  local mark = runtime.clock >= testUntil and not down
  note(T.gridHint, GREY)
  for gi = 1, layoutGroups do
    ui.text(groupLabel[gi] or '')
    if groupNote[gi] then
      ui.sameLine()
      ui.textColored(groupNote[gi], GREY)
    end
    local g = work.g[gi]
    if g then
      local labels, leds = CELL[gi], lay.groups[gi].leds
      local mapped = g.n == #leds
      local s = g.f[cur]
      for k = 1, g.n do
        if k > 1 and (k - 1) % perRow ~= 0 then ui.sameLine(0, CELL_GAP) end
        local clicked = ui.invisibleButton(labels[k], CELL_SIZE)
        if ui.itemActive() then painting = true end
        local hovered = ui.itemHovered(HOVER_DRAG)
        if (clicked or (painting and down and hovered)) and paint(gi, k) then s = g.f[cur] end
        local r1, r2 = ui.itemRect()
        drawCell(r1, r2, s and s:byte(k))
        if hovered then
          outline(r1, r2, OUTLINE, 0)
          if mapped and mark then runtime.markHover(leds[k]) end
        end
      end
    end
  end
end

local function mismatchBlock()
  for i = 1, #warnLines do note(warnLines[i], ORANGE) end
  if hasMismatch and ui.button(L.fit) then fitToLayout() end
  if ui.checkbox(L.rescale, work.rescale) then
    work.rescale = not work.rescale
    edited()
  end
  if not work.rescale then note(T.rescaleNote, GREY) end
end

local function frameStrip()
  ui.text(T.frames)
  ui.sameLine()
  ui.text(frameInfo)
  local perRow = max(1, floor((ui.availableSpaceX() + 4) / FRAME_STEP))
  for i = 1, nFrames do
    if i > 1 and (i - 1) % perRow ~= 0 then ui.sameLine(0, 4) end
    if ui.button(i == cur and FRAME_ACTIVE[i] or FRAME_LABEL[i], FRAME_SIZE) and i ~= cur then
      cur = i
      ver = ver + 1
    end
  end
  local full = nFrames >= MAX_FRAMES
  if ui.button(L.add, BTN_AUTO, full and DISABLED or 0) then frameOp('add') end
  ui.sameLine()
  if ui.button(L.dup, BTN_AUTO, full and DISABLED or 0) then frameOp('dup') end
  ui.sameLine()
  if ui.button(L.delFrame, BTN_AUTO, nFrames <= 1 and DISABLED or 0) then frameOp('del') end
  if ui.button(L.left, BTN_AUTO, cur <= 1 and DISABLED or 0) then frameOp('left') end
  ui.sameLine()
  if ui.button(L.right, BTN_AUTO, cur >= nFrames and DISABLED or 0) then frameOp('right') end
  ui.sameLine()
  if ui.button(L.fill) then frameOp('fill') end
  ui.setNextItemWidth(260)
  local v, changed = ui.slider(L.fps, work.fps, 0.2, 30, T.fpsFormat)
  if changed then
    work.fps = max(0.2, min(30, floor(v * 10 + 0.5) / 10))
    edited()
  end
end

local function preview()
  ui.text(previewLabel)
  local fi = floor(runtime.clock * work.fps) % nFrames + 1
  local avail = ui.availableSpaceX()
  for gi = 1, layoutGroups do
    local g = work.g[gi]
    if g then
      local step = min(PREVIEW_STEP, max(3, floor(avail / g.n)))
      local cell = min(PREVIEW_CELL, step - 1)
      ui.dummy(PREVIEW_SIZE[gi]:set(step * g.n, PREVIEW_CELL))
      local r1 = ui.itemRect()
      local x, y = r1.x, r1.y
      local s = g.f[fi]
      for k = 1, g.n do
        local px = x + (k - 1) * step
        drawCell(P1:set(px, y), P2:set(px + cell, y + PREVIEW_CELL), s and s:byte(k))
      end
    end
  end
end

local function saveRow()
  if ui.button(L.save) then save() end
  ui.sameLine()
  if ui.button(L.test) then testOnCar() end
  ui.sameLine()
  if ui.button(L.discard, BTN_AUTO, dirty and 0 or DISABLED) and dirty then discard() end
  if dirty then
    ui.sameLine()
    ui.textColored(T.unsaved, ORANGE)
  end
end

local function animationPicker()
  ui.text('Animace:')
  ui.sameLine(ROW_X)
  ui.setNextItemWidth(300)
  ui.combo(L.scenarioCombo, scPreview, ui.ComboFlags.None, scenarioComboItems)
  if not selEntry then
    ui.textWrapped(T.pick)
    return
  end
  if lookNote then note(lookNote, ORANGE) end
  if condNote then note(condNote, GREY) end
  if ui.checkbox(L.on, selEntry.on) then
    runtime.editScenario(sel, 'on', not selEntry.on)
    workPreset = runtime.presetId
  end
  local off = not selEntry.on
  if selEntry.custom then
    ui.sameLine()
    local now = runtime.clock
    if confirmScId == sel and now < confirmScUntil then
      if ui.button(L.delAnimConfirm) then
        confirmScId = nil
        deleteAnimation()
      end
    elseif ui.button(L.delAnim) then
      confirmScId, confirmScUntil = sel, now + CONFIRM_TIME
    end
  end
  if off and selEntry then note(T.offNote, GREY) end
end

local function draw()
  refresh()
  runPendingTest()
  presetRow()
  ui.separator()
  local lay = runtime.layout
  if not lay or runtime.state == 'wait' then
    ui.text(T.waiting)
    return
  end
  if #lay.leds == 0 then
    ui.textWrapped(T.noLeds)
    return
  end
  animationPicker()
  if work and selEntry then
    ui.separator()
    brushRow()
    grid()
    mismatchBlock()
    ui.separator()
    frameStrip()
    preview()
    ui.separator()
    saveRow()
  end
  if runtime.clock < editMsgUntil then note(editMsg, editMsgColour) end
end

M.draw = draw

-- For tests: the working copy and the editor state.
function M.peek()
  return work, cur, dirty, sel, nFrames, brushIndex
end

return M
