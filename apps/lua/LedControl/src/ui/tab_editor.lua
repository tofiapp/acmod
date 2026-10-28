-- Tab Editor: own presets and frame animations (layout: docs/ledcontrol-ui.md, section Editor).
-- Rows: Preset (combo + icons Nový / Kopie / Přejmenovat / Smazat; rename in place, delete with a second click; user
-- presets only), Animace (a scenario of the current preset or a new custom one, on / off, a custom one deleted with a
-- second click), the grid (one row of cells per LED group of the car in real order; click or drag paints the brush),
-- Štětec ('.' transparent, '0' off, palette 1..9) + Barva (the chosen palette colour: colour button + quick picks),
-- Snímky (frame strip + icons add / duplicate / delete / move), Rychlost (fps + live preview), Jiný počet diod
-- (rescale), then Uložit / Test na autě / Zahodit with a "neuloženo" dot. Export / import live in Nastavení.
-- The animation is edited on a local working copy
--   { p = 'frames', fps, rescale, palette = { 9 x '#RRGGBB' }, g = { [group] = { n = cells, f = { frame strings } } } }
-- with '.' transparent (lower scenarios show through), '0' off, '1'..'9' palette (patterns.framesFor). Every group of
-- the copy holds the same number of frames. Uložit = runtime.editScenario(id, 'look', copy); Test na autě = save +
-- runtime.testScenario once the runtime has compiled the saved preset. No allocation per frame: labels are prebuilt,
-- texts are rebuilt only when presets.version, runtime.version, the preset id or the editor's own version change.
-- Unsaved edits are dropped with a message when the car's preset changes from outside the editor (header combo,
-- hotkey, import, delete).
-- CSP calls beyond the kit: ui.iconButton(icon, 22, 5, true, ui.ButtonFlags.Disabled) (RGBControl utils.lua),
-- ui.invisibleButton / itemRect / itemActive / mouseDown / itemHovered(HoveredFlags) / drawRect(Filled) (official apps),
-- ui.alignTextToFramePadding (TimeShift) and ui.offsetCursorY (MirrorDelta, official apps), both only when present.

local csp = require('src/csp')
local ui, vec2, rgb, rgbm = csp.ui, csp.vec2, csp.rgb, csp.rgbm
local config = require('src/config')
local runtime = require('src/runtime')
local presets = require('src/presets')
local patterns = require('src/patterns')
local color = require('src/color')
local conditions = require('src/conditions')
local engine = require('src/engine')
local K = require('src/ui/kit')

local S = config.S
local M = {}

local MAX_GROUPS, MAX_CELLS, MAX_FRAMES = 8, 64, 64
local CONFIRM_TIME, TEST_SECONDS, PENDING_TIME, MESSAGE_TIME = 4, 5, 2, 6
local floor, min, max = math.floor, math.min, math.max
local plural = K.plural

local DARK = rgbm(0.1, 0.1, 0.11, 1)
local CHECK_A = rgbm(0.28, 0.28, 0.3, 1)
local CHECK_B = rgbm(0.45, 0.45, 0.48, 1)
local OUTLINE = rgbm(1, 1, 1, 0.9)
local SELECTED = rgbm(1, 0.8, 0.2, 1)

local CELL_SIZE = vec2(22, 22)
local CELL_GAP, CELL_STEP = 2, 24            -- grid
local BRUSH_GAP = 3                           -- brush row (room for the selection outline)
local BTN_AUTO = vec2(0, 0)
local FRAME_SIZE = vec2(26, 0)
local FRAME_GAP, FRAME_STEP = 2, 28
local ICON_W, ICON_SPACING = 22, 8
local FRAME_ICONS_X = K.ROW_W - 5 * ICON_W - 4 * ICON_SPACING   -- frame icons end at the row's right edge
local FRAMES_PER_ROW = max(1, floor((FRAME_ICONS_X - ICON_SPACING - K.LABEL_W + FRAME_GAP) / FRAME_STEP))
local COMBO_W, SPEED_W, SPEED_GAP = 180, 150, 14
local PREVIEW_W = K.ROW_W - K.LABEL_W - SPEED_W - SPEED_GAP   -- the preview ends at the row's right edge
local PREVIEW_BOX_H, PREVIEW_CELL_H, PREVIEW_STEP, PREVIEW_GROUP_GAP = 20, 10, 12, 8
local PREVIEW_SIZE = vec2(10, PREVIEW_BOX_H)
local Q1, Q2, P1, P2, O1, O2 = vec2(), vec2(), vec2(), vec2(), vec2(), vec2()

-- flags (enums from the SDK: ac_ui_enums.lua ButtonFlags / HoveredFlags; ui.StyleColor.Button as in the kit)
local DISABLED = ui.ButtonFlags and ui.ButtonFlags.Disabled or 0
local HOVER_DRAG = ui.HoveredFlags and ui.HoveredFlags.AllowWhenBlockedByActiveItem or 0
local BUTTON = ui.StyleColor and ui.StyleColor.Button or nil

local DEFAULT_PALETTE = { '#FF0000', '#00FF00', '#0000FF', '#FFC800', '#FFFFFF', '#FF5000', '#A000FF', '#00C8FF',
  '#FF40A0' }

local L = {
  deleteConfirm = 'Smazat?##edDeleteOk',
  renameText = '##edRenameText', renameOk = 'Uložit název##edRenameOk', renameCancel = 'Zrušit##edRenameCancel',
  scenarioCombo = '##edScenario', newAnim = 'Nová animace##edScNew', on = 'Zapnutý##edOn',
  delAnimConfirm = 'Smazat?##edScDelOk', fit = 'Přizpůsobit##edFit', rescale = 'Přepočítat##edRescale',
  fill = 'Vyplnit##edFill', fps = '##edFps', save = 'Uložit##edSave', test = 'Test na autě##edTest',
  discard = 'Zahodit##edDiscard',
}
-- icon button ids (K.iconButton pushes them; the tests click them by id)
local ID = {
  new = 'edNew', copy = 'edCopy', rename = 'edRename', delete = 'edDelete', delAnim = 'edScDel',
  add = 'edAdd', dup = 'edDup', delFrame = 'edDelFrame', left = 'edLeft', right = 'edRight',
}
M.LABELS, M.IDS = L, ID

local T = {
  preset = 'Preset', animation = 'Animace', brush = 'Štětec', colour = 'Barva', frames = 'Snímky',
  speed = 'Rychlost', rescaleLabel = 'Jiný počet diod',
  tipNew = 'Nový preset (z aktuálního)', tipCopy = 'Kopie presetu', tipRename = 'Přejmenovat', tipDelete = 'Smazat',
  tipConfirm = 'Klikněte znovu: preset se smaže.',
  presetHelp = 'Vestavěné presety (F1 styl, GT3 styl, Minimální) jsou relativní – sedí na libovolný počet diod.\n'
    .. 'Úpravy vestavěného presetu se ukládají přímo do něj (karta Scénáře: Obnovit výchozí). Přejmenovat a smazat jde jen '
    .. 'vlastní preset.',
  animHelp = 'Animace je vzhled jednoho scénáře kreslený po snímcích.\n'
    .. 'Vyberte scénář presetu, nebo vytvořte novou vlastní animaci.',
  tipDelAnim = 'Smazat animaci', tipConfirmAnim = 'Klikněte znovu: animace se smaže.',
  onHelp = 'Vypnutý scénář se na autě ukáže jen při Testu na autě.',
  onHelpCustom = 'Kdy a kde svítí, nastavíte v kartě Scénáře.\n'
    .. 'Vypnutý scénář se na autě ukáže jen při Testu na autě.',
  brushHelp = 'Klik nebo tažení myší maluje štětcem.\nNajetím na políčko dioda na autě blikne.',
  tipFill = 'Vyplnit celý snímek štětcem',
  transparent = 'průhledná – ukáže scénáře s nižší prioritou', offBrush = 'zhasnuto',
  tipAdd = 'Přidat snímek', tipDup = 'Duplikovat snímek', tipDelFrame = 'Smazat snímek', tipLeft = 'Posunout doleva',
  tipRight = 'Posunout doprava',
  fpsFormat = '%.1f snímků/s', previewTip = 'Náhled animace',
  rescaleHelp = 'Na autě s jiným počtem diod se snímky přepočítají.\nBez přepočtu tam tento scénář nesvítí.',
  fitHelpOn = 'Na autě se snímky zatím přepočítají samy.\nPřizpůsobit je převede natrvalo, pak je můžete dokreslit.',
  fitHelpOff = 'Bez přepočtu (Jiný počet diod) tu tento scénář nesvítí.\n'
    .. 'Přizpůsobit převede snímky natrvalo na počet diod tohoto auta.',
  unsaved = 'neuloženo',
  waiting = 'Čekám na načtení auta…',
  noLeds = 'Diody nenalezeny.', noLedsHelp = 'Editor potřebuje znát diody auta.\nKarta Diody: Vybrat diody ručně.',
  pickPreview = 'Vyberte…',
  dropped = 'Preset se změnil – neuložené změny zahozené.',
  droppedSwitch = 'Neuložené změny zahozené.',
  nameTaken = 'Preset s tímto názvem už existuje.',
  nameEmpty = 'Název nesmí být prázdný.',
}

-- prebuilt per frame labels
local CELL = {}
for gi = 1, MAX_GROUPS do
  CELL[gi] = {}
  for k = 1, MAX_CELLS do CELL[gi][k] = '##edCell' .. gi .. '_' .. k end
end
local FRAME_LABEL = {}
for i = 1, MAX_FRAMES do FRAME_LABEL[i] = i .. '##edFrame' .. i end
local BRUSH_CHAR, BRUSH_BYTE, BRUSH_LABEL, BRUSH_TIP = {}, {}, {}, {}
for b = 1, 11 do
  local ch = b == 1 and '.' or tostring(b - 2)
  BRUSH_CHAR[b], BRUSH_BYTE[b], BRUSH_LABEL[b] = ch, ch:byte(), '##edBrush' .. ch
  BRUSH_TIP[b] = b == 1 and 'Průhledná' or (b == 2 and 'Zhasnuto' or ('Barva ' .. (b - 2)))
end
local PAL_LABEL, PAL_EDIT, PAL_DRAW, palHex = {}, {}, {}, {}
for i = 1, 9 do
  PAL_LABEL[i] = '##edPal' .. i
  PAL_EDIT[i] = rgb(1, 1, 1)        -- kept between frames: the picker keeps its own colour (no re-read from hex)
  PAL_DRAW[i] = rgbm(1, 1, 1, 1)
  palHex[i] = ''
end

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
local presetMsg, presetMsgColour, presetMsgUntil = '', K.GREEN, -1
local editMsg, editMsgColour, editMsgUntil = '', K.GREEN, -1

-- caches (rebuilt in refresh)
local scItems = {}
local scPreview = T.pickPreview
local layoutGroups = 0
local groupName, groupTip, groupOff = {}, {}, {}
local mismatchText, mismatchHelp, tooManyText = '', '', nil
local onHelp, stateText = T.onHelp, ''

local function sayPreset(text, colour)
  presetMsg, presetMsgColour, presetMsgUntil = text, colour or K.GREEN, runtime.clock + MESSAGE_TIME
end
local function sayEdit(text, colour)
  editMsg, editMsgColour, editMsgUntil = text, colour or K.GREEN, runtime.clock + MESSAGE_TIME
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

-- Icon button as K.iconButton, greyed out (ui.ButtonFlags.Disabled, as RGBControl does) when the action is not possible.
local function icon(id, ic, tip, disabled)
  if not disabled then return K.iconButton(id, ic, tip) end
  ui.pushID(id)
  ui.iconButton(ic, ICON_W, 5, true, DISABLED)
  ui.popID()
  K.tip(tip)
  return false
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
  scItems = {}
  local list = presets.effective(runtime.preset())
  local prevCat = nil
  for i = 1, #list do
    local e = list[i]
    local frames = isFramesLook(e.look)
    -- category caption before the first scenario of each category (as in the Scénáře tab)
    scItems[i] = { id = e.id, entry = e, frames = frames, cat = e.cat ~= prevCat and e.cat or nil,
      label = e.name .. (frames and ' – snímky' or '') .. '##edSc:' .. e.id }
    prevCat = e.cat
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

local function diodes(n, accusative)
  if accusative then return plural(n, 'diodu', 'diody', 'diod') end
  return plural(n, 'dioda', 'diody', 'diod')
end

local function rebuildTexts()
  local lay = runtime.layout
  layoutGroups = lay and min(#lay.groups, MAX_GROUPS) or 0
  groupName, groupTip, groupOff = {}, {}, {}
  scPreview = selEntry and selEntry.name or T.pickPreview
  local C = runtime.compiled
  -- the runtime compiles only in normal operation: a compile of another preset (or an older version) says nothing
  if C and (C.presetId ~= runtime.presetId or runtime.compiledVersion ~= presets.version) then C = nil end
  local sc = C and sel and engine.find(C, sel) or nil
  local details, mismatches = {}, 0
  for gi = 1, layoutGroups do
    local g = lay.groups[gi]
    local n = #g.leds
    groupName[gi] = g.name
    local tip = string.format('%d %s', n, diodes(n))
    local cg = sc and C.groups[gi]
    if cg then
      local targeted = false
      for i = 1, #cg.cands do if cg.cands[i] == sc then targeted = true end end
      if not targeted then
        groupOff[gi] = true
        tip = tip .. '\nTento scénář sem nesvítí (karta Scénáře: Kde).'
      end
    end
    groupTip[gi] = tip
    local w = work and work.g[gi]
    if w and w.n ~= groupSize(gi) then
      mismatches = mismatches + 1
      details[#details + 1] = string.format('%s: snímky pro %d %s, auto má %d', g.name, w.n, diodes(w.n, true), n)
    end
  end
  mismatchText, mismatchHelp = '', ''
  if mismatches > 0 then
    local off = not work.rescale
    mismatchText = (mismatches == 1 and details[1] or 'Snímky jsou pro jiný počet diod') .. (off and ' – nesvítí.' or '.')
    mismatchHelp = table.concat(details, '.\n') .. '.\n\n' .. (off and T.fitHelpOff or T.fitHelpOn)
  end
  tooManyText = nil
  if lay and #lay.groups > MAX_GROUPS then
    tooManyText = string.format('Auto má %d skupin diod, editor ukazuje prvních %d.', #lay.groups, MAX_GROUPS)
  end
  onHelp, stateText = T.onHelp, ''
  if selEntry then
    local look = selEntry.look
    local parts = {}
    if selEntry.custom then
      onHelp = T.onHelpCustom
      parts[#parts + 1] = 'Kdy: ' .. conditions.describe(selEntry.when)
    end
    if not isFramesLook(look) then
      local kind = type(look) == 'table' and look.p or 'solid'
      parts[#parts + 1] = string.format('teď vzor „%s“', patterns.NAMES[kind] or kind)
      onHelp = onHelp .. '\nUložením nahradíte jeho vzor vlastními snímky.'
    end
    stateText = table.concat(parts, ' · ')
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
  if dropped then sayEdit(T.dropped, K.ORANGE) end
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
  runtime.editScenario(sel, 'look', work)
  workPreset = runtime.presetId
  baseline = presets.deepCopy(work)
  dirty = false
  ver = ver + 1
  -- the look of a catalogue scenario is an animation shared by the presets ticked in it (tab Scénáře)
  local a = presets.animFor(runtime.presetId, sel)
  local n = presets.animCount(a)
  if a and n > 1 then
    sayEdit('Uloženo do animace „' .. a.name .. '“ (platí pro ' .. n .. ' presetů, viz karta Scénáře).')
  elseif a then
    sayEdit('Uloženo do animace „' .. a.name .. '“. V kartě Scénáře ji můžete zapnout i v jiných presetech.')
  else
    sayEdit('Uloženo do „' .. runtime.preset().name .. '“.')
  end
  return true
end

local function testBlocked()
  if runtime.state ~= 'run' then
    return 'Diody nejsou převzaté (' .. (runtime.STATES[runtime.state] or runtime.state) .. '), test se neukáže.'
  end
  if S.testMode ~= runtime.NORMAL then
    return 'Běží testovací vzor (karta Diody → Provoz), test se neukáže.'
  end
  return nil
end

local function testOnCar()
  local why = testBlocked()
  if why then sayEdit(why, K.ORANGE) return end      -- blocked: nothing is saved
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
    sayEdit('Test na autě: 5 s.')
  elseif runtime.clock > pendingUntil then
    pendingTest = nil
    sayEdit(testBlocked() or 'Test se nespustil, zkuste to znovu.', K.ORANGE)
  end
end

local function discard()
  if not (sel and runtime.layout) then return end
  loadWork()
  ver = ver + 1
  sayEdit('Změny zahozené.')
end

local function selectScenario(id)
  if id == sel and work then return end
  if dirty then sayEdit(T.droppedSwitch, K.ORANGE) end
  sel, cur = id, 1
  for i = 1, #scItems do if scItems[i].id == id then selEntry = scItems[i].entry end end
  if runtime.layout then loadWork() else work = nil end
  ver = ver + 1
end

local function newAnimation()
  local lay = runtime.layout
  if not lay or #lay.leds == 0 then sayEdit(T.noLeds, K.ORANGE) return end
  local wasDirty = dirty
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
  local text = 'Nová animace „' .. name .. '“.'
  if wasDirty then text = text .. ' Neuložené změny předchozí jsou zahozené.' end
  sayEdit(text, wasDirty and K.ORANGE or K.GREEN)
end

local function deleteAnimation()
  if not (sel and selEntry and selEntry.custom) then return end
  local name = selEntry.name
  runtime.removeScenario(sel)
  workPreset = runtime.presetId
  sel, selEntry, work, baseline, dirty, cur = nil, nil, nil, nil, false, 1
  ver = ver + 1
  sayEdit('Animace „' .. name .. '“ je smazaná.')
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
  sayEdit('Snímky přizpůsobené počtu diod.')
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
    sayPreset('Kopie „' .. runtime.preset().name .. '“ vytvořená.')
  else
    renameFor, renameText = runtime.presetId, runtime.preset().name
    sayPreset('Nový preset z „' .. from .. '“ – zadejte název.')
  end
end

local function confirmRename()
  local name = (cutUtf8((renameText:gsub('^%s+', '')), 40):gsub('%s+$', ''))
  if name == '' then sayPreset(T.nameEmpty, K.RED) return end
  local all = presets.all()
  for i = 1, #all do
    -- two presets with one name could not be told apart in the combos
    if all[i].id ~= runtime.presetId and all[i].name == name then sayPreset(T.nameTaken, K.RED) return end
  end
  if presets.rename(runtime.presetId, name) then
    renameFor = nil
    sayPreset('Přejmenováno na „' .. runtime.preset().name .. '“.')
  else
    sayPreset(T.nameEmpty, K.RED)
  end
end

local function deletePreset()
  local id, name = runtime.presetId, runtime.preset().name
  if presets.isBuiltin(id) or not presets.delete(id) then return end
  runtime.setPreset(presets.choose(nil, S.defaultPreset, runtime.layout, runtime.ST.drsPresent))
  sayPreset('Preset „' .. name .. '“ je smazaný, auto používá „' .. runtime.preset().name .. '“.')
end

-- ---------------------------------------------------------------- drawing

local function scenarioComboItems()
  for i = 1, #scItems do
    local it = scItems[i]
    if it.cat then K.caption(it.cat) end
    if ui.selectable(it.label, it.id == sel) then selectScenario(it.id) end
  end
end

local function presetRow()
  local user = not presets.isBuiltin(runtime.presetId)
  K.label(T.preset)
  ui.setNextItemWidth(COMBO_W)
  if user and renameFor == runtime.presetId then
    -- rename in place: the name box takes the combo's place until it is saved or cancelled
    local text, changed, enter = ui.inputText(L.renameText, renameText)
    if changed then renameText = text end
    ui.sameLine()
    if ui.button(L.renameOk) or enter then confirmRename() end
    ui.sameLine()
    if ui.button(L.renameCancel) then renameFor = nil end
  else
    -- the header's combo switches presets; here only the name and what can be done with it
    if ui.alignTextToFramePadding then ui.alignTextToFramePadding() end
    ui.text(runtime.preset().name)
    ui.sameLine()
    if icon(ID.new, ui.Icons.Plus, T.tipNew) then newPreset(false) end
    ui.sameLine()
    if icon(ID.copy, ui.Icons.Copy, T.tipCopy) then newPreset(true) end
    ui.sameLine()
    if icon(ID.rename, ui.Icons.Edit, T.tipRename, not user) and user then
      renameFor, renameText = runtime.presetId, runtime.preset().name
    end
    ui.sameLine()
    local now = runtime.clock
    if user and confirmId == runtime.presetId and now < confirmUntil then
      if ui.button(L.deleteConfirm) then
        confirmId = nil
        deletePreset()
      end
      K.tip(T.tipConfirm)
    elseif icon(ID.delete, ui.Icons.Trash, T.tipDelete, not user) and user then
      confirmId, confirmUntil = runtime.presetId, now + CONFIRM_TIME
    end
    K.help(T.presetHelp)
  end
  if runtime.clock < presetMsgUntil then K.note(presetMsg, presetMsgColour) end
end

local function animationRows()
  K.label(T.animation)
  ui.setNextItemWidth(COMBO_W)
  ui.combo(L.scenarioCombo, scPreview, ui.ComboFlags.None, scenarioComboItems)
  ui.sameLine()
  if ui.button(L.newAnim) then newAnimation() end
  K.help(T.animHelp)
  if selEntry and selEntry.custom then
    ui.sameLine()
    local now = runtime.clock
    if confirmScId == sel and now < confirmScUntil then
      if ui.button(L.delAnimConfirm) then
        confirmScId = nil
        deleteAnimation()
      end
      K.tip(T.tipConfirmAnim)
    elseif icon(ID.delAnim, ui.Icons.Trash, T.tipDelAnim) then
      confirmScId, confirmScUntil = sel, now + CONFIRM_TIME
    end
  end
  if not selEntry then return end
  K.label('')
  if ui.checkbox(L.on, selEntry.on) then
    runtime.editScenario(sel, 'on', not selEntry.on)
    workPreset = runtime.presetId
  end
  K.help(onHelp)
  if stateText ~= '' then
    ui.sameLine(0, 14)
    K.dim(stateText)
  end
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

local function grid()
  local lay = runtime.layout
  local down = ui.mouseDown()
  if not down then painting = false end
  local mark = runtime.clock >= testUntil and not down
  for gi = 1, layoutGroups do
    if ui.alignTextToFramePadding then ui.alignTextToFramePadding() end   -- name centred on the cells (TimeShift)
    if groupOff[gi] then ui.textColored(groupName[gi], K.DIM) else ui.text(groupName[gi]) end
    K.tip(groupTip[gi])
    ui.sameLine(K.LABEL_W)
    local g = work.g[gi]
    if g then
      local perRow = max(1, floor((ui.availableSpaceX() + CELL_GAP) / CELL_STEP))
      local labels, leds = CELL[gi], lay.groups[gi].leds
      local mapped = g.n == #leds
      local s = g.f[cur]
      for k = 1, g.n do
        if k > 1 then
          if (k - 1) % perRow ~= 0 then ui.sameLine(0, CELL_GAP) else K.label('') end
        end
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
    else
      ui.text('')
    end
  end
  if tooManyText then K.dim(tooManyText) end
end

local function mismatchRow()
  if mismatchText == '' then return end
  if ui.alignTextToFramePadding then ui.alignTextToFramePadding() end
  ui.textColored(mismatchText, K.ORANGE)
  ui.sameLine()
  if ui.button(L.fit) then fitToLayout() end
  K.help(mismatchHelp)
end

local function brushRow()
  K.label(T.brush)
  for b = 1, 11 do
    if b > 1 then ui.sameLine(0, BRUSH_GAP) end
    local clicked = ui.invisibleButton(BRUSH_LABEL[b], CELL_SIZE)
    local r1, r2 = ui.itemRect()
    drawCell(r1, r2, BRUSH_BYTE[b])
    if b == brushIndex then
      outline(r1, r2, SELECTED, 1)
      outline(r1, r2, SELECTED, 2)
    end
    K.tip(BRUSH_TIP[b])
    if clicked then brushIndex = b end
  end
  ui.sameLine(0, 10)
  if ui.button(L.fill) then frameOp('fill') end
  K.tip(T.tipFill)
  K.help(T.brushHelp)
end

-- Colour of the chosen palette brush: colour button + quick picks that stay true at any brightness.
local function colourRow()
  K.label(T.colour)
  local b = brushIndex
  if b < 3 then
    K.dim(b == 1 and T.transparent or T.offBrush)
    return
  end
  local i = b - 2
  if K.colourField(PAL_LABEL[i], PAL_EDIT[i]) then
    local c = PAL_EDIT[i]
    PAL_DRAW[i].r, PAL_DRAW[i].g, PAL_DRAW[i].b = c.r, c.g, c.b
    local hex = color.hex(color.pack(c.r, c.g, c.b))
    palHex[i] = hex
    work.palette[i] = hex
    edited()
  end
end

local function frameIcons()
  ui.sameLine(FRAME_ICONS_X)
  local op = nil
  local full = nFrames >= MAX_FRAMES
  if icon(ID.add, ui.Icons.Plus, T.tipAdd, full) then op = 'add' end
  ui.sameLine()
  if icon(ID.dup, ui.Icons.Copy, T.tipDup, full) then op = 'dup' end
  ui.sameLine()
  if icon(ID.delFrame, ui.Icons.Trash, T.tipDelFrame, nFrames <= 1) then op = 'del' end
  ui.sameLine()
  if icon(ID.left, ui.Icons.ArrowLeft, T.tipLeft, cur <= 1) then op = 'left' end
  ui.sameLine()
  if icon(ID.right, ui.Icons.ArrowRight, T.tipRight, cur >= nFrames) then op = 'right' end
  return op
end

-- Frame buttons (the current one highlighted as in K.choice), wrapped at the label column; the frame icons stay at
-- the end of the first line, so they do not move while frames are added.
local function frameStrip()
  K.label(T.frames)
  local op, pick = nil, nil
  local n = nFrames
  for i = 1, n do
    if i > 1 then
      if (i - 1) % FRAMES_PER_ROW ~= 0 then
        ui.sameLine(0, FRAME_GAP)
      else
        if i == FRAMES_PER_ROW + 1 then op = frameIcons() end
        K.label('')
      end
    end
    local on = i == cur
    if on and BUTTON then ui.pushStyleColor(BUTTON, K.ACCENT) end
    if ui.button(FRAME_LABEL[i], FRAME_SIZE) and not on then pick = i end
    if on and BUTTON then ui.popStyleColor() end
  end
  if n <= FRAMES_PER_ROW then op = frameIcons() end
  if pick then
    cur = pick
    ver = ver + 1
  end
  if op then frameOp(op) end
end

-- The animation playing at its speed: every group in one strip, in real order.
local function preview()
  local total, used = 0, 0
  for gi = 1, layoutGroups do
    local g = work.g[gi]
    if g then
      total = total + g.n
      used = used + 1
    end
  end
  if total == 0 then return end
  local gaps = (used - 1) * PREVIEW_GROUP_GAP
  local step = min(PREVIEW_STEP, max(3, floor((min(PREVIEW_W, ui.availableSpaceX()) - gaps) / total)))
  local cell = max(2, step - 2)
  ui.dummy(PREVIEW_SIZE:set(step * total + gaps, PREVIEW_BOX_H))
  K.tip(T.previewTip)
  local r1 = ui.itemRect()
  local x, y = r1.x, r1.y + (PREVIEW_BOX_H - PREVIEW_CELL_H) * 0.5
  local fi = floor(runtime.clock * work.fps) % nFrames + 1
  for gi = 1, layoutGroups do
    local g = work.g[gi]
    if g then
      local s = g.f[fi]
      for k = 1, g.n do
        drawCell(P1:set(x, y), P2:set(x + cell, y + PREVIEW_CELL_H), s and s:byte(k))
        x = x + step
      end
      x = x + PREVIEW_GROUP_GAP
    end
  end
end

local function speedRow()
  K.label(T.speed)
  ui.setNextItemWidth(SPEED_W)
  local v, changed = ui.slider(L.fps, work.fps, 0.2, 30, T.fpsFormat)
  if changed then
    work.fps = max(0.2, min(30, floor(v * 10 + 0.5) / 10))
    edited()
  end
  ui.sameLine(0, SPEED_GAP)
  preview()
end

local function rescaleRow()
  K.label(T.rescaleLabel)
  if ui.checkbox(L.rescale, work.rescale) then
    work.rescale = not work.rescale
    edited()
  end
  K.help(T.rescaleHelp)
end

local function saveRow()
  if ui.button(L.save) then save() end
  ui.sameLine()
  if ui.button(L.test) then testOnCar() end
  ui.sameLine()
  if ui.button(L.discard, BTN_AUTO, dirty and 0 or DISABLED) and dirty then discard() end
  if dirty then
    ui.sameLine(0, 14)
    K.dot(K.ORANGE)
    ui.sameLine(0, 2)
    ui.text(T.unsaved)
  end
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
    ui.text(T.noLeds)
    K.help(T.noLedsHelp)
    return
  end
  animationRows()
  if work and selEntry then
    if ui.offsetCursorY then ui.offsetCursorY(6) end
    grid()
    mismatchRow()
    if ui.offsetCursorY then ui.offsetCursorY(6) end
    brushRow()
    colourRow()
    frameStrip()
    speedRow()
    rescaleRow()
    ui.separator()
    saveRow()
  end
  if runtime.clock < editMsgUntil then K.note(editMsg, editMsgColour) end
end

M.draw = draw

-- True while the editor holds animation edits that are not saved in the car's preset (e.g. for an export warning).
function M.unsaved()
  return dirty and work ~= nil and workPreset == runtime.presetId
end

-- For tests: the working copy and the editor state.
function M.peek()
  return work, cur, dirty, sel, nFrames, brushIndex
end

return M
