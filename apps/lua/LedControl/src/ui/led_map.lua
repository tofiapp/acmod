-- Diody tab, section "Pořadí a skupiny": order and groups of the LEDs, edited on a working copy that follows the
-- detected layout until the first edit; "Uložit" stores it as the car's map (runtime.setMap -> car profile, detection
-- then uses it instead of the automatic order). A list of small cockpit meshes (detect.listMeshes) adds LEDs by hand,
-- also on a car with none detected (M.startPicking, drawn inline by the tab). Hovering a row blinks that LED on the car.

local K = require('src/ui/kit')
local runtime = require('src/runtime')
local detect = require('src/detect')

local M = { open = false }

local MAX = detect.MAX_LEDS
local MAX_GROUPS = 8
local NAME_MAX = 22
local ROW_COMBO_X = 230
local ROLES = { 'main', 'side', 'other' }
local ROLE_NAMES = { main = 'hlavní řada', side = 'boční diody', other = 'další řada' }
local ROLE_LABELS = {}
for i = 1, #ROLES do ROLE_LABELS[i] = ROLE_NAMES[ROLES[i]] .. '##role_' .. ROLES[i] end

local LABEL_AUTO = 'Pořadí a skupiny###map'
local LABEL_MANUAL = 'Pořadí a skupiny (ruční)###map'
local HELP_ORDER = 'Seznam shora dolů = diody zleva doprava. ↑ ↓ mění pořadí, rozbalovací seznam skupinu,'
  .. ' Obrátit otočí celou skupinu. Najetím myší na řádek dioda na autě bliká. Uložit platí pro toto auto.'
local HELP_PICK = 'Malé díly modelu do 2 m od očí řidiče, nejbližší první. Klik = přidat / odebrat.'
local TIP_AUTO = 'Zapomene ruční pořadí, diody se najdou samy.'

local work = nil          -- { leds = { { name, group } }, groups = { { name, role } } }
local layoutOf = nil      -- the layout work was taken from (followed until the first edit)
local dirty = false
local meshes = nil        -- detect.listMeshes result (on demand)
local filter = ''
local version, seen = 0, -1
local rowLabels, rowLed, meshLabels, groupPick = {}, {}, {}, {}
local countLabel = ''

local UP, DOWN, DEL, GROUP, GNAME, GROLE, GREV = {}, {}, {}, {}, {}, {}, {}
for i = 1, MAX do
  UP[i], DOWN[i], DEL[i], GROUP[i] = '↑##mapUp' .. i, '↓##mapDown' .. i, '×##mapDel' .. i, '##mapGroup' .. i
end
for g = 1, MAX_GROUPS do
  GNAME[g], GROLE[g], GREV[g] = '##mapGroupName' .. g, '##mapGroupRole' .. g, 'Obrátit##mapRev' .. g
end
local ARROW = vec2(22, 0)
local AUTO_SIZE = vec2(0, 0)
local LIST_SIZE = vec2(0, 180)
local GROUP_W, NAME_W, ROLE_W = 130, 160, 130

local function changed() version = version + 1 end
local function edited() dirty = true; changed() end

local function shorten(s, n)
  if #s <= n then return s end
  local cut = n
  while cut > 1 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut) .. '…'
end

-- Map from the current layout (names in order, groups with names and roles).
local function fromLayout()
  local lay = runtime.layout
  local m = { leds = {}, groups = {} }
  if lay then
    for gi = 1, math.min(#lay.groups, MAX_GROUPS) do
      local g = lay.groups[gi]
      m.groups[gi] = { g.name, g.role }
      for _, id in ipairs(g.leds) do m.leds[#m.leds + 1] = { lay.leds[id].name, gi } end
    end
    -- more than 8 groups (the map's limit): the rest goes into group 8 instead of being dropped
    for gi = MAX_GROUPS + 1, #lay.groups do
      for _, id in ipairs(lay.groups[gi].leds) do m.leds[#m.leds + 1] = { lay.leds[id].name, MAX_GROUPS } end
    end
  end
  if #m.groups == 0 then m.groups[1] = { 'Řada otáček', 'main' } end
  return m
end

-- A copy for the car profile (the working copy keeps changing after a save).
local function copyOf(m)
  local out = { leds = {}, groups = {} }
  for i = 1, #m.leds do out.leds[i] = { m.leds[i][1], m.leds[i][2] } end
  for g = 1, #m.groups do out.groups[g] = { m.groups[g][1], m.groups[g][2] } end
  return out
end

-- The working copy follows the detected layout until the user edits it; another car starts from scratch.
local carOf = nil
local function ensureWork()
  if carOf ~= runtime.carId then
    carOf = runtime.carId
    work, layoutOf, dirty, meshes, filter = nil, nil, false, nil, ''
    M.open = false
  end
  local lay = runtime.layout
  if work and (dirty or layoutOf == lay) then return end
  work, layoutOf, dirty = fromLayout(), lay, false
  changed()
end

local function reset()
  work, layoutOf, dirty = nil, nil, false
  M.open = false
  changed()
end

local function loadMeshes()
  meshes = detect.listMeshes(ac.getCar(0), 300)
  changed()
end

-- No LEDs detected: the tab shows the editor inline with the mesh list already loaded.
function M.startPicking()
  ensureWork()
  M.open = true
  if not meshes then loadMeshes() end
end

function M.label()
  local lay = runtime.layout
  return lay and lay.manual and LABEL_MANUAL or LABEL_AUTO
end

local refreshedFor = nil  -- the layout the row -> LED links were built for
local function refresh()
  if seen == version and refreshedFor == runtime.layout then return end
  seen, refreshedFor = version, runtime.layout
  rowLabels, rowLed, meshLabels, groupPick = {}, {}, {}, {}
  if not work then return end
  local byName = {}
  local lay = runtime.layout
  if lay then for i = 1, #lay.leds do byName[lay.leds[i].name] = i end end
  for i = 1, #work.leds do
    local e = work.leds[i]
    rowLabels[i] = string.format('%d  %s', i, shorten(e[1], NAME_MAX))
    rowLed[i] = byName[e[1]] or 0
  end
  for g = 1, #work.groups do groupPick[g] = work.groups[g][1] .. '##pickGroup' .. g end
  if meshes then
    local f = filter:lower()
    for i = 1, #meshes do
      local m = meshes[i]
      if f == '' or m.name:lower():find(f, 1, true) then
        meshLabels[#meshLabels + 1] = { i, string.format('%s   %.1f cm · %.2f m · %s##mesh%d', m.name,
          m.radius * 100, m.dist, m.material, i) }
      end
    end
    local n = #meshLabels
    countLabel = n .. ' ' .. K.plural(n, 'díl', 'díly', 'dílů')
  end
end

local rowIndex = 0
local function groupItems()
  for g = 1, #work.groups do
    if ui.selectable(groupPick[g] or work.groups[g][1], work.leds[rowIndex][2] == g) then
      work.leds[rowIndex][2] = g
      edited()
    end
  end
end
local groupIndex = 0
local function roleItems()
  for i = 1, #ROLES do
    local r = ROLES[i]
    if ui.selectable(ROLE_LABELS[i], work.groups[groupIndex][2] == r) then
      work.groups[groupIndex][2] = r
      edited()
    end
  end
end

local function has(name)
  for i = 1, #work.leds do if work.leds[i][1] == name then return true end end
  return false
end

-- "1  RPM_LED_3   [skupina v] ↑ ↓ ×"
local function rows()
  local swap
  local n = #work.leds
  for i = 1, n do
    local e = work.leds[i]
    ui.text(rowLabels[i] or e[1])
    if ui.itemHovered() and (rowLed[i] or 0) > 0 then runtime.markHover(rowLed[i]) end
    ui.sameLine(ROW_COMBO_X)
    ui.setNextItemWidth(GROUP_W)
    rowIndex = i
    local g = work.groups[e[2]]
    ui.combo(GROUP[i], g and g[1] or '?', ui.ComboFlags.None, groupItems)
    ui.sameLine(0, 4)
    if ui.button(UP[i], ARROW, i == 1 and ui.ButtonFlags.Disabled or ui.ButtonFlags.None) and i > 1 then swap = { i, i - 1 } end
    ui.sameLine(0, 2)
    if ui.button(DOWN[i], ARROW, i == n and ui.ButtonFlags.Disabled or ui.ButtonFlags.None) and i < n then swap = { i, i + 1 } end
    ui.sameLine(0, 2)
    if ui.button(DEL[i], ARROW) then swap = { i, 0 } end
    K.tip('Odebrat')
  end
  if swap then
    if swap[2] == 0 then table.remove(work.leds, swap[1])
    else work.leds[swap[1]], work.leds[swap[2]] = work.leds[swap[2]], work.leds[swap[1]] end
    edited()
  end
end

local function groupsEditor()
  K.caption('Skupiny')
  for g = 1, #work.groups do
    ui.setNextItemWidth(NAME_W)
    local name, nameEdited = ui.inputText(GNAME[g], work.groups[g][1])
    if nameEdited then work.groups[g][1] = name; edited() end
    ui.sameLine(0, 4)
    ui.setNextItemWidth(ROLE_W)
    groupIndex = g
    ui.combo(GROLE[g], ROLE_NAMES[work.groups[g][2]] or '?', ui.ComboFlags.None, roleItems)
    ui.sameLine(0, 4)
    if ui.button(GREV[g]) then
      -- reverse the order of this group's LEDs (a mirrored row needs one click, not n(n-1)/2 moves)
      local idx = {}
      for i = 1, #work.leds do if work.leds[i][2] == g then idx[#idx + 1] = i end end
      for a = 1, math.floor(#idx / 2) do
        local i, j = idx[a], idx[#idx + 1 - a]
        work.leds[i], work.leds[j] = work.leds[j], work.leds[i]
      end
      edited()
    end
    K.tip('Obrátí pořadí diod v této skupině.')
  end
  if #work.groups < MAX_GROUPS and ui.button('Přidat skupinu##mapAddGroup') then
    work.groups[#work.groups + 1] = { 'Skupina ' .. (#work.groups + 1), 'side' }
    edited()
  end
end

local function meshList()
  for k = 1, #meshLabels do
    local i, label = meshLabels[k][1], meshLabels[k][2]
    local name = meshes[i].name
    if ui.selectable(label, has(name)) then
      if has(name) then
        for j = #work.leds, 1, -1 do if work.leds[j][1] == name then table.remove(work.leds, j) end end
      elseif #work.leds < MAX then
        work.leds[#work.leds + 1] = { name, 1 }
      end
      edited()
    end
  end
end

local function picker()
  if not meshes then
    if ui.button('Přidat diody ručně##mapPick') then loadMeshes() end
    K.help(HELP_PICK)
    return
  end
  ui.setNextItemWidth(K.CONTROL_W - 60)
  local f, filterEdited = ui.inputText('Hledat##meshFilter', filter)
  if filterEdited then filter = f; changed() end
  ui.sameLine()
  ui.text(countLabel)
  K.help(HELP_PICK)
  ui.sameLine()
  if ui.button('Skrýt##mapPickHide') then meshes = nil; changed() end
  ui.childWindow('##meshList', LIST_SIZE, true, meshList)
end

local function buttons()
  local flags = dirty and ui.ButtonFlags.None or ui.ButtonFlags.Disabled
  if ui.button('Uložit##mapSave', AUTO_SIZE, flags) and dirty then
    runtime.setMap(#work.leds > 0 and copyOf(work) or nil)
    reset()
  end
  ui.sameLine()
  if ui.button('Zahodit##mapCancel', AUTO_SIZE, flags) and dirty then reset() end
  local lay = runtime.layout
  if lay and lay.manual then
    ui.sameLine()
    if ui.button('Automaticky##mapAuto') then
      runtime.setMap(nil)
      reset()
    end
    K.tip(TIP_AUTO)
  end
  if dirty then
    ui.sameLine(0, 12)
    K.dot(K.ORANGE)
    ui.sameLine(0, 2)
    ui.textColored('neuloženo', K.ORANGE)
  end
end

-- Section content (also drawn inline by the tab when the car has no LEDs and the user picks them by hand).
function M.content()
  ensureWork()
  refresh()
  if #work.leds > 0 then
    K.caption('Zleva doprava')
    K.help(HELP_ORDER)
    rows()
    groupsEditor()
  end
  picker()
  buttons()
end

return M
