-- Diody tab, section "Pořadí a výběr diod": edit the order and groups of the detected LEDs, or pick LED meshes by
-- hand when the car has none detected. Works on a local copy; "Uložit" stores it as the car's map
-- (runtime.setMap -> car profile, detection uses it instead of the automatic order).

local common = require('src/ui/common')
local runtime = require('src/runtime')
local detect = require('src/detect')

local M = { open = false }

local MAX = detect.MAX_LEDS
local GREY = rgbm(0.6, 0.6, 0.6, 1)
local ORANGE = rgbm(1, 0.7, 0.2, 1)
local ROLES = { 'main', 'side', 'other' }
local ROLE_NAMES = { main = 'hlavní řada', side = 'boční diody', other = 'další řada' }

local work = nil          -- { leds = { { name, group } }, groups = { { name, role } } }
local meshes = nil        -- detect.listMeshes result (on demand)
local filter = ''
local version, seen = 0, -1
local rowLabels, meshLabels = {}, {}
local countLabel = ''

local UP, DOWN, DEL, GROUP, GNAME, GROLE = {}, {}, {}, {}, {}, {}
for i = 1, MAX do
  UP[i], DOWN[i], DEL[i], GROUP[i] = '↑##mapUp' .. i, '↓##mapDown' .. i, 'Odebrat##mapDel' .. i, '##mapGroup' .. i
end
local GREV = {}
for g = 1, 8 do GNAME[g], GROLE[g], GREV[g] = '##mapGroupName' .. g, '##mapGroupRole' .. g, 'Obrátit pořadí##mapRev' .. g end
local ARROW = vec2(24, 0)

-- Czech plural: 1 mesh, 2-4 meshe, 5+ meshů
local function meshCount(n)
  if n == 1 then return '1 mesh' end
  if n >= 2 and n <= 4 then return n .. ' meshe' end
  return n .. ' meshů'
end

local function changed() version = version + 1 end

-- Map from the current layout (names in order, groups with names and roles).
local function fromLayout()
  local lay = runtime.layout
  local m = { leds = {}, groups = {} }
  if lay then
    for gi = 1, math.min(#lay.groups, 8) do
      local g = lay.groups[gi]
      m.groups[gi] = { g.name, g.role }
      for _, id in ipairs(g.leds) do m.leds[#m.leds + 1] = { lay.leds[id].name, gi } end
    end
    -- more than 8 groups (the map's limit): the rest goes into group 8 instead of being dropped
    for gi = 9, #lay.groups do
      for _, id in ipairs(lay.groups[gi].leds) do m.leds[#m.leds + 1] = { lay.leds[id].name, 8 } end
    end
  end
  if #m.groups == 0 then m.groups[1] = { 'Řada otáček', 'main' } end
  return m
end

function M.start()
  work = fromLayout()
  M.open = true
  changed()
end

local function refresh()
  if seen == version then return end
  seen = version
  rowLabels, meshLabels = {}, {}
  if not work then return end
  for i = 1, #work.leds do
    local e = work.leds[i]
    rowLabels[i] = string.format('%d. %s', i, e[1])
  end
  if meshes then
    local f = filter:lower()
    for i = 1, #meshes do
      local m = meshes[i]
      if f == '' or m.name:lower():find(f, 1, true) then
        meshLabels[#meshLabels + 1] = { i, string.format('%s  (%.1f cm, %.2f m od očí, %s)##mesh%d', m.name,
          m.radius * 100, m.dist, m.material, i) }
      end
    end
    countLabel = meshCount(#meshLabels)
  end
end

local rowIndex = 0
local function groupItems()
  for g = 1, #work.groups do
    if ui.selectable(work.groups[g][1] .. '##pickGroup' .. g, work.leds[rowIndex][2] == g) then
      work.leds[rowIndex][2] = g
      changed()
    end
  end
end
local groupIndex = 0
local function roleItems()
  for _, r in ipairs(ROLES) do
    if ui.selectable(ROLE_NAMES[r], work.groups[groupIndex][2] == r) then
      work.groups[groupIndex][2] = r
      changed()
    end
  end
end

local function has(name)
  for i = 1, #work.leds do if work.leds[i][1] == name then return true end end
  return false
end

local function rows()
  local swap
  for i = 1, #work.leds do
    local e = work.leds[i]
    ui.text(rowLabels[i] or e[1])
    ui.sameLine(200)
    ui.setNextItemWidth(110)
    rowIndex = i
    local g = work.groups[e[2]]
    ui.combo(GROUP[i], g and g[1] or '?', ui.ComboFlags.None, groupItems)
    ui.sameLine()
    if ui.button(UP[i], ARROW) and i > 1 then swap = { i, i - 1 } end
    ui.sameLine()
    if ui.button(DOWN[i], ARROW) and i < #work.leds then swap = { i, i + 1 } end
    ui.sameLine()
    if ui.button(DEL[i]) then swap = { i, 0 } end
  end
  if swap then
    if swap[2] == 0 then table.remove(work.leds, swap[1])
    else work.leds[swap[1]], work.leds[swap[2]] = work.leds[swap[2]], work.leds[swap[1]] end
    changed()
  end
end

local function groupsEditor()
  ui.text('Skupiny:')
  for g = 1, #work.groups do
    ui.setNextItemWidth(160)
    local name, edited = ui.inputText(GNAME[g], work.groups[g][1])
    if edited then work.groups[g][1] = name; changed() end
    ui.sameLine()
    ui.setNextItemWidth(140)
    groupIndex = g
    ui.combo(GROLE[g], ROLE_NAMES[work.groups[g][2]] or '?', ui.ComboFlags.None, roleItems)
    ui.sameLine()
    if ui.button(GREV[g]) then
      -- reverse the order of this group's LEDs (a mirrored row needs one click, not n(n-1)/2 moves)
      local idx = {}
      for i = 1, #work.leds do if work.leds[i][2] == g then idx[#idx + 1] = i end end
      for a = 1, math.floor(#idx / 2) do
        local i, j = idx[a], idx[#idx + 1 - a]
        work.leds[i], work.leds[j] = work.leds[j], work.leds[i]
      end
      changed()
    end
  end
  if #work.groups < 8 and ui.button('Přidat skupinu') then
    work.groups[#work.groups + 1] = { 'Skupina ' .. (#work.groups + 1), 'side' }
    changed()
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
      changed()
    end
  end
end
local LIST_SIZE = vec2(0, 180)

local function picker()
  if not meshes then
    if ui.button('Načíst meshe z kokpitu') then
      meshes = detect.listMeshes(ac.getCar(0), 300)
      changed()
    end
    common.note('Seznam malých meshů do 2 m od očí řidiče, nejbližší první.', GREY)
    return
  end
  ui.setNextItemWidth(220)
  local f, edited = ui.inputText('Hledat##meshFilter', filter)
  if edited then filter = f; changed() end
  ui.sameLine()
  ui.text(countLabel)
  ui.childWindow('##meshList', LIST_SIZE, true, meshList)
end

function M.draw()
  if not M.open then
    if ui.button(runtime.n > 0 and 'Upravit pořadí a skupiny diod' or 'Vybrat diody ručně') then M.start() end
    if runtime.layout and runtime.layout.manual then
      ui.sameLine()
      if ui.button('Zpět na automatické hledání') then runtime.setMap(nil) end
      common.note('Toto auto používá vaše ruční pořadí diod.', ORANGE)
    end
    return
  end
  refresh()
  ui.header('Pořadí a výběr diod')
  common.note('Pořadí shora dolů = zleva doprava na volantu. Šipkami ↑ ↓ měňte pořadí, v rozbalovacím seznamu skupinu,'
    .. ' „Obrátit pořadí“ otočí celou skupinu.', GREY)
  rows()
  groupsEditor()
  picker()
  if ui.button('Uložit pořadí') then
    runtime.setMap(#work.leds > 0 and work or nil)
    M.open = false
  end
  ui.sameLine()
  if ui.button('Zrušit##mapCancel') then M.open = false end
  ui.sameLine()
  if ui.button('Zpět na automatické hledání##mapAuto') then
    runtime.setMap(nil)
    M.open = false
  end
end

return M
