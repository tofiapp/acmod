-- Tab Světla: online banner, the lights the car has (live state, who drives them, real or only local), the rain light
-- mode per car, the cabin light / dash meshes of the backlight, mesh pickers and the light scenarios (on/off, priority,
-- Test, parameters, colour). Labels are built when lights.version changes, never per frame.

local common = require('src/ui/common')
local config = require('src/config')
local runtime = require('src/runtime')
local lights = require('src/lights')
local color = require('src/color')

local S = config.S
local G = lights.G
local M = {}

local ORANGE = rgbm(1, 0.7, 0.2, 1)
local GREY = rgbm(0.6, 0.6, 0.6, 1)
local GREEN = rgbm(0.4, 1, 0.5, 1)
local CELL = vec2(24, 24)
local SHOWN = 60          -- mesh picker rows at most
local TEST_OFF = 'Test teď nejde: zapněte hlavní vypínač a „Ovládat světla auta“.'
local message, messageUntil = nil, 0
local function say(text) message, messageUntil = text, runtime.clock + 5 end

local T = {
  intro = 'Světla vašeho auta. Ukazuji jen to, co auto má. Skutečná světla mění opravdový stav auta, „jen u vás“ '
    .. 'vidíte jen vy.',
  masterOff = 'Hlavní vypínač je vypnutý: světla řídí jen řidič (Test funguje se zapnutým vypínačem).',
  enabled = 'Ovládat světla auta##lenabled',
  realOnline = 'Online používat i skutečná světla##lrealonline',
  wait = 'Čekám na načtení auta…',
  itemsTitle = 'Co auto má:',
  none = 'Auto nemá žádná světla, která by šla ovládat.',
  on = 'svítí', off = 'nesvítí',
  real = 'skutečné – vidí i ostatní', localOnly = 'jen u vás',
  holder = 'Stav:',
  rainTitle = 'Dešťové světlo',
  rainHelp = 'Přepínač = skutečný přepínač auta (vidí i ostatní). Kopie meshů = vybrané meshe svítí a blikají jen u vás.',
  rmSwitch = 'Přepínač auta##rm_switch', rmMesh = 'Kopie vybraných meshů##rm_mesh', rmOff = 'Nepoužívat##rm_off',
  rmAuto = 'Vybrat automaticky##rm_auto',
  noSource = '(žádný přepínač)',
  meshIntensity = 'Jas kopií: %.0f',
  backTitle = 'Podsvícení (palubní deska a kabina)',
  backHelp = 'Světlo v kabině je zdroj světla u palubní desky (posun od očí jezdce). Meshe palubní desky se přebarví '
    .. 'barvou scénáře. Obojí jen u vás.',
  cabin = 'Světlo v kabině##lcabin',
  bright = 'Jas světla: %.1f', range = 'Dosah: %.2f m',
  offX = 'Do strany: %.0f cm', offY = 'Výška: %.0f cm', offZ = 'Vpřed: %.0f cm',
  dashIntensity = 'Jas meshů: %.1f',
  brakeTitle = 'Brzdová světla',
  scenTitle = 'Scénáře světel',
  scenHelp = 'Nahoře je nejvyšší priorita; na každém světle vyhrává nejvyšší aktivní scénář. Test spustí scénář na 5 s. '
    .. 'Nastavení scénářů platí pro všechna auta, dešťové světlo a meshe se ukládají pro toto auto.',
  active = 'aktivní', forced = 'test',
  colour = 'Barva',
  diag = 'Diagnostika světel##ldiag',
  extras = 'Načíst online extras serveru##lextras',
  selectedNone = 'Vybráno: nic',
  flashHigh = 'Auto nemá vlastní problik: bliknou dálková světla, jen když svítí potkávací.',
}

local PICK = {
  rain = { open = 'Vybrat meshe dešťového světla…##pick_rain', close = 'Hotovo##pick_rain_done',
    filter = 'Filtr##flt_rain', clear = 'Zrušit výběr##clr_rain' },
  dash = { open = 'Vybrat meshe palubní desky…##pick_dash', close = 'Hotovo##pick_dash_done',
    filter = 'Filtr##flt_dash', clear = 'Zrušit výběr##clr_dash' },
}

-- ---------------------------------------------------------------- caches

local seen = -1
local rows = {}             -- scenario rows (only scenarios whose light the car has)
local itemDesc = {}
local sourceLabels = {}
local selectedText = { rain = T.selectedNone, dash = T.selectedNone }
local brakeText = ''
local COLOURS = {}          -- persistent colour per scenario id (the picker edits it in place)
local diagText, diagAt = '', -10

local function plural(n, one, few, many)
  if n == 1 then return one end
  if n >= 2 and n <= 4 then return few end
  return many
end

local function selectedLine(list)
  if not list or #list == 0 then return T.selectedNone end
  return string.format('Vybráno %d: %s', #list, table.concat(list, ', '))
end

local function refresh()
  if lights.version == seen then return end
  seen = lights.version
  rows = {}
  local order = lights.order
  for i = 1, #order do
    local s = order[i]
    if s.out.has then
      local desc = s.desc .. ' Ovládá: ' .. s.out.name .. '.'
      if s.out == lights.OUT.flash and s.out.ch == lights.CH.highBeams then desc = desc .. ' ' .. T.flashHigh end
      local r = { s = s, on = s.name .. '##lon_' .. s.id, up = 'Výš##lup_' .. s.id, down = 'Níž##ldn_' .. s.id,
        test = 'Test##lt_' .. s.id, testing = 'Test běží…##lt_' .. s.id, colourLabel = '##lc_' .. s.id,
        hasColour = s.def.colour ~= nil and not (s.out.real), params = {}, desc = desc }
      local c = COLOURS[s.id]
      if not c then c = rgbm(0, 0, 0, 1); COLOURS[s.id] = c end
      -- only when the stored colour differs: the picker keeps editing its own (unquantised) value
      if color.pack(c.r, c.g, c.b) ~= s.colour then c.r, c.g, c.b = color.unpack(s.colour) end
      r.colour = c
      for k = 1, #s.def.params do
        local d = s.def.params[k]
        local id = '##lp_' .. s.id .. '_' .. d.key
        r.params[k] = { d = d, label = d.bool and (d.name .. id) or id }
      end
      rows[#rows + 1] = r
    end
  end
  itemDesc = {}
  for i = 1, #lights.items do itemDesc[i] = lights.items[i].desc end
  sourceLabels = {}
  for i = 1, #lights.rainSources do
    local e = lights.rainSources[i]
    sourceLabels[i] = e.label .. (e.note and (' (' .. e.note .. ')') or '') .. '##rs' .. i
  end
  local cfg = lights.carSettings()
  selectedText.rain = selectedLine(cfg and cfg.rain.meshes)
  selectedText.dash = selectedLine(cfg and cfg.dash.meshes)
  brakeText = #lights.brakeNames > 0 and string.format('Nalezeno %d %s: %s', #lights.brakeNames,
    plural(#lights.brakeNames, 'mesh', 'meshe', 'meshů'), table.concat(lights.brakeNames, ', ')) or ''
end

-- ---------------------------------------------------------------- mesh picker

local picker = nil          -- 'rain' | 'dash' | nil
local filter = ''
local list, labels, visible = nil, {}, {}
local moreText = nil
local listCar = nil

local function rebuildVisible()
  visible = {}
  local f = filter:lower()
  local total = 0
  for i = 1, #list do
    if f == '' or list[i].lower:find(f, 1, true) then
      total = total + 1
      if #visible < SHOWN then visible[#visible + 1] = i end
    end
  end
  moreText = total > #visible and string.format('Zobrazeno %d z %d, zpřesněte filtr.', #visible, total) or nil
  if total == 0 then moreText = 'Filtru nic neodpovídá.' end
end

local function openPicker(role)
  picker = role
  if list == nil or listCar ~= lights.carId then
    list = lights.listMeshes()
    listCar = lights.carId
    labels = {}
    for i = 1, #list do
      local e = list[i]
      labels[i] = string.format('%s  (%.0f cm, %.1f m od očí)##lm%d', e.name, e.radius * 100, e.dist, i)
    end
  end
  rebuildVisible()
end

local function pickerBlock(role)
  local P = PICK[role]
  ui.textWrapped(selectedText[role])
  if picker ~= role then
    if ui.button(P.open) then openPicker(role) end
    return
  end
  if ui.button(P.close) then picker = nil return end
  ui.sameLine()
  if ui.button(P.clear) then lights.clearMeshes(role) end
  ui.setNextItemWidth(220)
  local text, changed = ui.inputText(P.filter, filter)
  if changed then filter = text; rebuildVisible() end
  for i = 1, #visible do
    local k = visible[i]
    local name = list[k].name
    if ui.selectable(labels[k], lights.meshSelected(role, name)) then lights.toggleMesh(role, name) end
  end
  if moreText then common.note(moreText, GREY) end
end

-- ---------------------------------------------------------------- sections

local function itemsSection()
  ui.text(T.itemsTitle)
  local items = lights.items
  if #items == 0 then ui.textWrapped(T.none) return end
  for i = 1, #items do
    local it = items[i]
    ui.text(it.name)
    ui.sameLine()
    common.note(it.on and T.on or T.off, it.on and GREEN or GREY)
    ui.sameLine()
    common.note(it.real and T.real or T.localOnly, it.real and ORANGE or GREY)
    ui.textWrapped(itemDesc[i] or '')
    ui.text(T.holder)
    ui.sameLine()
    ui.text(it.holder)
    if it.note then common.note(it.note, ORANGE) end
  end
end

local function rainSourceItems()
  local src = lights.rainSources
  for i = 1, #src do
    local e = src[i]
    if e.usable then
      if ui.selectable(sourceLabels[i], lights.rainSource == e) then lights.setRainSwitch(e.key) end
    else
      common.note(sourceLabels[i], GREY)
    end
  end
end

local function rainSection()
  ui.text(T.rainTitle)
  ui.textWrapped(T.rainHelp)
  local cfg = lights.carSettings()
  local mode = lights.rainMode
  if cfg.rain.mode == nil and lights.rainAuto ~= '' then common.note(lights.rainAuto, GREY) end
  if #lights.rainSources > 0 then
    if ui.radioButton(T.rmSwitch, mode == 'switch') and mode ~= 'switch' then lights.setRainMode('switch') end
    ui.sameLine()
  end
  if ui.radioButton(T.rmMesh, mode == 'mesh') and mode ~= 'mesh' then lights.setRainMode('mesh') end
  ui.sameLine()
  if ui.radioButton(T.rmOff, mode == 'off') and mode ~= 'off' then lights.setRainMode('off') end
  if cfg.rain.mode ~= nil then
    ui.sameLine()
    if ui.button(T.rmAuto) then lights.setRainMode(nil) end
  end
  if mode == 'switch' then
    ui.setNextItemWidth(320)
    ui.combo('##rainSource', lights.rainSource and lights.rainSource.label or T.noSource, ui.ComboFlags.None,
      rainSourceItems)
  elseif mode == 'mesh' then
    pickerBlock('rain')
    ui.setNextItemWidth(220)
    local v, changed = ui.slider('##lmeshint', G.meshIntensity, 1, 100, T.meshIntensity)
    if changed then lights.setGlobal('meshIntensity', math.floor(v + 0.5)) end
  end
end

local function backlightSection()
  ui.text(T.backTitle)
  ui.textWrapped(T.backHelp)
  local d = lights.carSettings().dash
  if ui.checkbox(T.cabin, d.cabinLight) then lights.setDash('cabinLight', not d.cabinLight) end
  if d.cabinLight then
    ui.setNextItemWidth(220)
    local v, ch = ui.slider('##cab_b', d.bright, 0.05, 10, T.bright)
    if ch then lights.setDash('bright', v) end
    ui.setNextItemWidth(220)
    v, ch = ui.slider('##cab_r', d.range, 0.1, 3, T.range)
    if ch then lights.setDash('range', v) end
    ui.setNextItemWidth(220)
    v, ch = ui.slider('##cab_x', d.offset.x * 100, -100, 100, T.offX)
    if ch then lights.setDash('x', v / 100) end
    ui.setNextItemWidth(220)
    v, ch = ui.slider('##cab_y', d.offset.y * 100, -100, 100, T.offY)
    if ch then lights.setDash('y', v / 100) end
    ui.setNextItemWidth(220)
    v, ch = ui.slider('##cab_z', d.offset.z * 100, -100, 150, T.offZ)
    if ch then lights.setDash('z', v / 100) end
  end
  pickerBlock('dash')
  if #d.meshes > 0 then
    ui.setNextItemWidth(220)
    local v, ch = ui.slider('##dash_i', d.intensity, 0.1, 60, T.dashIntensity)
    if ch then lights.setDash('intensity', v) end
  end
end

local function scenarioRow(r)
  local s = r.s
  if ui.checkbox(r.on, s.on) then lights.setOn(s.id, not s.on) end
  ui.sameLine()
  if ui.button(r.up) then lights.move(s.id, -1) end
  ui.sameLine()
  if ui.button(r.down) then lights.move(s.id, 1) end
  ui.sameLine()
  local testing = s.forceUntil > lights.clock
  if ui.button(testing and r.testing or r.test) and not lights.test(s.id) then
    say(TEST_OFF)
  end
  if s.active then
    ui.sameLine()
    common.note(testing and T.forced or T.active, GREEN)
  end
  ui.textWrapped(r.desc)
  for k = 1, #r.params do
    local p = r.params[k]
    local d = p.d
    if d.bool then
      local cur = s.P[d.key] >= 0.5
      if ui.checkbox(p.label, cur) then lights.setParam(s.id, d.key, cur and 0 or 1) end
    else
      ui.setNextItemWidth(220)
      local v, changed = ui.slider(p.label, s.P[d.key], d.min, d.max, d.fmt)
      if changed then lights.setParam(s.id, d.key, v) end
    end
  end
  if r.hasColour then
    local c = r.colour
    if ui.colorButton(r.colourLabel, c, ui.ColorPickerFlags.PickerHueBar, CELL) then
      lights.setColour(s.id, color.pack(c.r, c.g, c.b))
    end
    ui.sameLine()
    ui.text(T.colour)
  end
end

local function diagSection()
  if ui.checkbox(T.diag, G.showDiag) then lights.setGlobal('showDiag', not G.showDiag) end
  if not G.showDiag then return end
  if runtime.clock - diagAt > 1 then
    diagText, diagAt = table.concat(lights.diagLines(), '\n'), runtime.clock
  end
  ui.textWrapped(diagText)
  if ui.button(T.extras) then
    lights.online.readExtras()
    diagAt = -10
  end
end

local function draw()
  refresh()
  if runtime.ST.isOnline then common.note(lights.online.BANNER, ORANGE) end
  ui.textWrapped(T.intro)
  if not S.master then common.note(T.masterOff, ORANGE) end
  if message and runtime.clock < messageUntil then common.note(message, ORANGE) end
  if ui.checkbox(T.enabled, G.enabled) then lights.setGlobal('enabled', not G.enabled) end
  ui.sameLine()
  if ui.checkbox(T.realOnline, G.realOnline) then lights.setGlobal('realOnline', not G.realOnline) end
  if lights.carId == '' or runtime.state == 'wait' or not lights.carSettings() then
    ui.text(T.wait)
    return
  end
  if not lights.running then lights.poll() end
  for i = 1, #lights.notes do common.note(lights.notes[i], ORANGE) end
  ui.separator()
  itemsSection()
  ui.separator()
  rainSection()
  ui.separator()
  backlightSection()
  if brakeText ~= '' then
    ui.separator()
    ui.text(T.brakeTitle)
    ui.textWrapped(brakeText)
  end
  ui.separator()
  ui.text(T.scenTitle)
  ui.textWrapped(T.scenHelp)
  for i = 1, #rows do
    ui.separator()
    scenarioRow(rows[i])
  end
  ui.separator()
  diagSection()
end

M.draw = draw

return M
