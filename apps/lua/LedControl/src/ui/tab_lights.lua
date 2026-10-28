-- Tab Světla (docs/ledcontrol-ui.md): the two switches, what the car has (live dots, details in tooltips), the rain
-- light and the backlight in collapsible sections (mesh pickers inside), the light scenarios as rows like the Scénáře
-- tab (on/off, name that expands to its parameters and colour, live dot, Test, Výš / Níž inside one light) and a
-- collapsed Diagnostika section.
-- No allocation per frame: rows and labels are rebuilt only when lights.version changes, tooltips of the lights are
-- built on hover and kept until their text changes, section and combo contents are module-level functions, the
-- diagnostics text is rebuilt on a version change or a click.
-- CSP calls: ui.selectable(label, selected, flags, size) (TrackCoordinatesHelper), ui.inputText with
-- ui.InputTextFlags.Placeholder (WebBrowser, RailroadEditor), ui.Icons.ArrowUp / ArrowDown (official apps),
-- ac.setClipboardText (official apps); the rest through src/ui/kit.lua.

local csp = require('src/csp')
local ac, ui, vec2, rgbm = csp.ac, csp.ui, csp.vec2, csp.rgbm
local K = require('src/ui/kit')
local config = require('src/config')
local runtime = require('src/runtime')
local lights = require('src/lights')
local color = require('src/color')
local diag = require('src/diag')

local S = config.S
local G = lights.G
local M = {}

local COMBO = ui.ComboFlags.None
local PLACEHOLDER = ui.InputTextFlags and ui.InputTextFlags.Placeholder or 0
local ICON_UP = ui.Icons and ui.Icons.ArrowUp or 'ArrowUp'
local ICON_DOWN = ui.Icons and ui.Icons.ArrowDown or 'ArrowDown'
local SHOWN = 60            -- mesh picker rows at most
local MESSAGE_TIME = 5

-- scenario rows: x positions of the parts (the window is 560 px wide, rows end before 480 px)
local NAME_SIZE = vec2(280, 0)
local TEST_SIZE = vec2(76, 0)
local X_DOT, X_TEST, X_UP, X_DOWN = 318, 336, 418, 446
local INDENT = vec2(26, 0)
-- "Auto má": three columns after the label column
local ITEM_X, ITEM_W, ITEM_COLS = K.LABEL_W, 123, 3

local T = {
  enabled = 'Ovládat světla auta##lenabled',
  enabledTip = 'Aplikace rozsvěcí světla auta podle scénářů níže. Vypnuto: světla řídí jen řidič.',
  realOnline = 'I online##lrealonline',
  realOnlineHelp = 'Online vidí skutečná světla (světla, dálková, problik, výstražná, přepínače) i ostatní jezdci.\n'
    .. 'Vypnuto: online je neovládám; kopie meshů a podsvícení (vidíte jen vy) běží dál.',
  masterOff = 'Hlavní vypínač je vypnutý: světla řídí jen řidič.',
  onlineBlocked = 'Online: skutečná světla teď řídí jen řidič („I online“ je vypnuto).',
  wait = 'Čekám na načtení auta…',
  has = 'Auto má',
  hasNone = 'žádná světla, která by šla ovládat',
  hasHelp = 'Zelená = svítí, šedá = nesvítí, oranžové jméno = něco nejde (podrobnosti po najetí myší).\n'
    .. 'Skutečná světla (světla, dálková, problik, výstražná, přepínače) vidí i ostatní jezdci.\n'
    .. 'Brzdová světla, dešťové světlo z meshů a podsvícení vidíte jen vy.',
  real = 'Skutečné: vidí i ostatní jezdci.',
  localOnly = 'Jen u vás.',
  now = 'Teď: ',
  rainTitle = 'Dešťové světlo',
  rainId = '###lrain',
  rainOff = 'nepoužívá se', rainNone = 'nenalezeno', rainMeshes = 'meshe',
  rainPickBoth = 'Nic nenalezeno: vyberte přepínač nebo meshe.',
  rainPickMesh = 'Nic nenalezeno: vyberte meshe.',
  rainSource = 'Zdroj',
  rainHelp = 'Automaticky: aplikace vybere sama podle auta.\n'
    .. 'Přepínač: skutečný přepínač auta, vidí i ostatní jezdci (bliká nejvýš 2× za sekundu).\n'
    .. 'Meshe: vybrané meshe svítí a blikají jen u vás.\nNe: dešťové světlo nepoužívat.',
  switch = 'Přepínač',
  noSource = '(žádný přepínač)',
  meshes = 'Meshe',
  meshIntensity = 'Jas kopií',
  backSection = 'Podsvícení##lback',
  cabin = 'Světlo v kabině##lcabin',
  cabinHelp = 'Zdroj světla u palubní desky v barvě scénáře, posunutý od očí jezdce. Jen u vás.',
  bright = 'Jas světla', range = 'Dosah', offX = 'Do strany', offY = 'Výška', offZ = 'Vpřed',
  dashHelp = 'Vybrané meshe palubní desky se přebarví barvou scénáře. Jen u vás.',
  dashIntensity = 'Jas meshů',
  scenTitle = 'Scénáře světel',
  scenHelp = 'Zaškrtnutí = scénář je zapnutý. Klikněte na název: nastavení a barva.\n'
    .. 'Na každém světle svítí nejvýš položený aktivní scénář (Výš / Níž). Zelená tečka = právě svítí.\n'
    .. 'Test spustí scénář na 5 s. Scénáře platí pro všechna auta, dešťové světlo a meshe jsou pro toto auto.',
  noScen = 'Auto nemá světla pro scénáře.',
  testTip = 'Spustí scénář na 5 s, i když jeho podmínka teď neplatí.',
  up = 'Výš', down = 'Níž',
  colour = 'Barva',
  diagSection = 'Diagnostika##ldiag',
  refresh = 'Obnovit##ldiag_refresh',
  extras = 'Online extras##lextras',
  extrasTip = 'Načte, co server nastavuje v CSP online extras (jen pro diagnostiku).',
  copyDiag = 'Kopírovat diagnostiku##ldiag_copy',
  copied = 'Diagnostika je ve schránce.',
  selectedNone = 'nic nevybráno',
  testMaster = 'Test nejde: zapněte hlavní vypínač.',
  testEnabled = 'Test nejde: zapněte „Ovládat světla auta“.',
  testHighBeams = 'Test nejde: problik dálkovými jen se zapnutými světly.',
  testOnline = 'Test běží, ale online skutečná světla neovládám („I online“).',
  testOther = 'Test teď nejde.',
  flashHigh = 'Auto nemá vlastní problik: bliknou dálková světla, jen když svítí potkávací.',
}

-- shorter names in the tab (the light is the caption above); unknown ids keep the module's own name
local SHORT = {
  rainPit = 'Bliká s pit limiterem', rainWet = 'Svítí v dešti', hazardStop = 'Při zastavení na trati',
  lightsDusk = 'Za šera a v dešti', brakeBlink = 'Blikají při prudkém brzdění', backlightPit = 'S pit limiterem',
  backlight = 'Palubní deska a kabina', flash = 'Na klávesu',
}
local CAPTION = {
  rain = 'DEŠŤOVÉ SVĚTLO', headlights = 'SVĚTLA', hazards = 'VÝSTRAŽNÁ SVĚTLA', flash = 'PROBLIK',
  brake = 'BRZDOVÁ SVĚTLA', backlight = 'PODSVÍCENÍ',
}
-- one hint in an expanded row, only where the driver has to do something
local HINT = { flash = 'Klávesu nastavíte v kartě Nastavení (Klávesy).' }
local ITEM_SHORT = { highBeams = 'Dálková', flash = 'Problik', hazards = 'Výstražná', brake = 'Brzdová',
  rainMesh = 'Dešťové', backlight = 'Podsvícení' }

local RAIN_LABELS = { 'Automaticky##rm_auto', 'Přepínač##rm_switch', 'Meshe##rm_mesh', 'Ne##rm_off' }
local RAIN_MODES = { false, 'switch', 'mesh', 'off' }
local RAIN_LABELS_NOSW = { RAIN_LABELS[1], RAIN_LABELS[3], RAIN_LABELS[4] }
local RAIN_MODES_NOSW = { false, 'mesh', 'off' }

local PICK = {
  rain = { open = 'Vybrat…##pick_rain', close = 'Hotovo##pick_rain_done', filter = 'Filtr##flt_rain',
    clear = 'Zrušit výběr##clr_rain' },
  dash = { open = 'Vybrat…##pick_dash', close = 'Hotovo##pick_dash_done', filter = 'Filtr##flt_dash',
    clear = 'Zrušit výběr##clr_dash' },
}

-- ---------------------------------------------------------------- messages

local message, messageColour, messageAt, messageUntil = nil, K.ORANGE, nil, 0
local function say(at, text, colour)
  message, messageColour, messageAt, messageUntil = text, colour or K.ORANGE, at, runtime.clock + MESSAGE_TIME
end
local function showMessage(at)
  if message and messageAt == at and runtime.clock < messageUntil then K.note(message, messageColour) end
end

-- ---------------------------------------------------------------- caches (rebuilt when lights.version changes)

local seen = -1
local rows, nRows = {}, 0       -- visible scenario rows, grouped by light
local items = {}                -- "Auto má" entries: { it, name, tip, tipHolder, tipNote }
local sourceLabels = {}
local selectedText = { rain = T.selectedNone, dash = T.selectedNone }
local brakeText = ''
local rainTitle = T.rainTitle .. T.rainId
local autoRain = {}             -- automatic mesh mode: the detected meshes count as selected in the picker
local COLOURS = {}              -- persistent colour per scenario id (the picker edits it in place)
local LABELS = {}               -- prebuilt labels per scenario id
local expanded = nil            -- id of the expanded scenario row

local function labelsOf(s)
  local l = LABELS[s.id]
  if l then return l end
  local id = s.id
  l = { on = '##lon_' .. id, name = (SHORT[id] or s.name) .. '##lx_' .. id, test = 'Test##lt_' .. id,
    testing = 'Test běží…##lt_' .. id, up = 'lup_' .. id, down = 'ldn_' .. id, colour = '##lc_' .. id, params = {} }
  for k = 1, #s.def.params do
    local d = s.def.params[k]
    local pid = '##lp_' .. id .. '_' .. d.key
    local name, extra = d.name:match('^(.-)%s*%((.*)%)$')
    l.params[k] = {
      label = d.bool and ((name or d.name) .. pid) or pid,
      name = d.name,
      help = extra,                                                  -- '(…)' of a checkbox name goes into (?)
      -- 'Blikání: %.1f Hz' -> '%.1f Hz' (the name stands in the label column)
      fmt = d.fmt and (d.fmt:gsub('^[^:%%]*:%s*', '')) or nil,
    }
  end
  LABELS[id] = l
  return l
end

local function selectedLine(list)
  if not list or #list == 0 then return T.selectedNone end
  return table.concat(list, ', ')
end

local function itemName(it)
  if it.id == 'headlights' then return it.name == 'Světla' and 'Světla' or 'Spínač světel' end
  if it.id:match('^extra') then return it.name:match('^(Přepínač %u)') or it.name end
  return ITEM_SHORT[it.id] or it.name
end

local function refresh()
  if lights.version == seen then return end
  seen = lights.version
  -- scenario rows: visible ones (the car has their light), grouped by light in order of first appearance
  local groups, byOut = {}, {}
  local order = lights.order
  for i = 1, #order do
    local s = order[i]
    if s.out.has then
      local g = byOut[s.out]
      if not g then g = { out = s.out }; byOut[s.out] = g; groups[#groups + 1] = g end
      g[#g + 1] = s
    end
  end
  rows, nRows = {}, 0
  local found = false
  for gi = 1, #groups do
    local g = groups[gi]
    for k = 1, #g do
      local s = g[k]
      local tip = s.name .. '\n' .. s.desc
      if s.out == lights.OUT.flash and s.out.ch == lights.CH.highBeams then tip = tip .. '\n' .. T.flashHigh end
      local r = { s = s, l = labelsOf(s), tip = tip, caption = k == 1 and (CAPTION[s.out.id] or s.out.name) or nil,
        prev = g[k - 1], next = g[k + 1], hasColour = s.def.colour ~= nil and not s.out.real, hint = HINT[s.id] }
      local c = COLOURS[s.id]
      if not c then c = rgbm(0, 0, 0, 1); COLOURS[s.id] = c end
      -- only when the stored colour differs: the picker keeps editing its own (unquantised) value
      if color.pack(c.r, c.g, c.b) ~= s.colour then c.r, c.g, c.b = color.unpack(s.colour) end
      r.colour = c
      if s.id == expanded then found = true end
      nRows = nRows + 1
      rows[nRows] = r
    end
  end
  if not found then expanded = nil end
  -- lights of the car
  items = {}
  for i = 1, #lights.items do
    local it = lights.items[i]
    items[i] = { it = it, name = itemName(it), tip = nil, tipHolder = nil, tipNote = nil }
  end
  sourceLabels = {}
  for i = 1, #lights.rainSources do
    local e = lights.rainSources[i]
    sourceLabels[i] = e.label .. (e.note and (' (' .. e.note .. ')') or '') .. '##rs' .. i
  end
  local cfg = lights.carSettings()
  -- the rain light picker shows the meshes in use (automatic mode: the detected ones)
  selectedText.rain = selectedLine(lights.rainNames or (cfg and cfg.rain.meshes))
  autoRain = {}
  if cfg and cfg.rain.mode == nil and lights.rainMode == 'mesh' then
    for i = 1, #(lights.rainNames or {}) do autoRain[lights.rainNames[i]] = true end
  end
  selectedText.dash = selectedLine(cfg and cfg.dash.meshes)
  brakeText = #lights.brakeNames > 0 and table.concat(lights.brakeNames, ', ') or ''
  -- section title with what the rain light uses now (the section is closed by default)
  local mode, src, state = lights.rainMode, lights.rainSource, nil
  if mode == 'switch' and src then
    state = src.key == 'lights' and 'spínač světel' or ('přepínač ' .. src.key)
  elseif mode == 'mesh' then
    state = T.rainMeshes
  elseif cfg then
    state = cfg.rain.mode == 'off' and T.rainOff or T.rainNone
  end
  rainTitle = (state and (T.rainTitle .. ': ' .. state) or T.rainTitle) .. T.rainId
end

-- ---------------------------------------------------------------- "Auto má"

local function problem(it)
  if it.note then return true end
  local h = it.holder
  if h == lights.TEXT.noEffect or h == lights.TEXT.blocked then return true end
  if it.ch and it.ch.failed then return true end
  return it.out == lights.OUT.backlight and lights.cabin.error ~= nil
end

-- tooltip text of a light, rebuilt only when its live parts (holder, note) change
local function tipOf(e)
  local it = e.it
  if e.tip and e.tipHolder == it.holder and e.tipNote == it.note then return e.tip end
  local t = it.name .. '\n' .. it.desc .. '\n' .. (it.real and T.real or T.localOnly)
  if it.id == 'brake' and brakeText ~= '' then t = t .. ' (' .. brakeText .. ')' end
  t = t .. '\n' .. T.now .. tostring(it.holder)
  if it.note then t = t .. '\n' .. it.note end
  e.tip, e.tipHolder, e.tipNote = t, it.holder, it.note
  return t
end

local function itemsRow()
  K.label(T.has)
  local n = #items
  if n == 0 then
    K.note(T.hasNone, K.DIM)
    return
  end
  for i = 1, n do
    local col = (i - 1) % ITEM_COLS
    if col == 0 then
      if i > 1 then K.label('') end            -- next line, same column start
    else
      ui.sameLine(ITEM_X + col * ITEM_W)
    end
    local e = items[i]
    local it = e.it
    K.dot(it.on and K.GREEN or K.DIM)
    ui.sameLine(0, 2)
    if problem(it) then ui.textColored(e.name, K.ORANGE) else ui.text(e.name) end
    if ui.itemHovered() then ui.setTooltip(tipOf(e)) end
  end
  K.help(T.hasHelp)
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

local function pickerBlock(role, help)
  local P = PICK[role]
  K.label(T.meshes)
  if picker ~= role then
    if ui.button(P.open) then openPicker(role) end
    ui.sameLine()
    ui.textWrapped(selectedText[role])
    if help then K.help(help) end
    return
  end
  if ui.button(P.close) then picker = nil return end
  ui.sameLine()
  if ui.button(P.clear) then lights.clearMeshes(role) end
  ui.sameLine()
  ui.textWrapped(selectedText[role])
  K.label('')
  ui.setNextItemWidth(K.CONTROL_W)
  local text, changed = ui.inputText(P.filter, filter, PLACEHOLDER)
  if changed then filter = text; rebuildVisible() end
  for i = 1, #visible do
    local k = visible[i]
    local name = list[k].name
    if ui.selectable(labels[k], lights.meshSelected(role, name) or (role == 'rain' and autoRain[name] == true)) then
      -- automatic mesh mode: the detected meshes become the explicit list first, then the click changes it
      if role == 'rain' and lights.carSettings().rain.mode == nil then lights.setRainMode('mesh') end
      lights.toggleMesh(role, name)
    end
  end
  if moreText then K.dim(moreText) end
end

-- ---------------------------------------------------------------- Dešťové světlo

local function rainSourceItems()
  local src = lights.rainSources
  for i = 1, #src do
    local e = src[i]
    if e.usable then
      if ui.selectable(sourceLabels[i], lights.rainSource == e) then lights.setRainSwitch(e.key) end
    else
      K.note(sourceLabels[i], K.DIM)
    end
  end
end

local function rainContent()
  local cfg = lights.carSettings()
  local withSwitch = #lights.rainSources > 0
  local L, modes = withSwitch and RAIN_LABELS or RAIN_LABELS_NOSW, withSwitch and RAIN_MODES or RAIN_MODES_NOSW
  local want = cfg.rain.mode or false
  local cur = nil
  for i = 1, #modes do if modes[i] == want then cur = i end end
  K.label(T.rainSource)
  local k = K.choice(L, cur)
  if k then lights.setRainMode(modes[k] or nil) end
  K.help(T.rainHelp)
  local mode = lights.rainMode
  -- automatic and nothing recognised: say what to do (a found switch / mesh shows below anyway)
  if cfg.rain.mode == nil and mode == 'off' then
    K.label('')
    K.dim(withSwitch and T.rainPickBoth or T.rainPickMesh)
  end
  if mode == 'switch' then
    K.label(T.switch)
    ui.setNextItemWidth(K.CONTROL_W)
    ui.combo('##rainSource', lights.rainSource and lights.rainSource.label or T.noSource, COMBO, rainSourceItems)
  elseif mode == 'mesh' then
    pickerBlock('rain')
    K.label(T.meshIntensity)
    ui.setNextItemWidth(K.CONTROL_W)
    local v, changed = ui.slider('##lmeshint', G.meshIntensity, 1, 100, '%.0f')
    if changed then lights.setGlobal('meshIntensity', math.floor(v + 0.5)) end
  end
end

-- ---------------------------------------------------------------- Podsvícení

local function dashSlider(label, id, value, min, max, fmt, key, scale)
  K.label(label)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, ch = ui.slider(id, value * scale, min, max, fmt)
  if ch then lights.setDash(key, v / scale) end
end

local function backContent()
  local d = lights.carSettings().dash
  if ui.checkbox(T.cabin, d.cabinLight) then lights.setDash('cabinLight', not d.cabinLight) end
  K.help(T.cabinHelp)
  if d.cabinLight then
    dashSlider(T.bright, '##cab_b', d.bright, 0.05, 10, '%.1f', 'bright', 1)
    dashSlider(T.range, '##cab_r', d.range, 0.1, 3, '%.2f m', 'range', 1)
    dashSlider(T.offX, '##cab_x', d.offset.x, -100, 100, '%.0f cm', 'x', 100)
    dashSlider(T.offY, '##cab_y', d.offset.y, -100, 100, '%.0f cm', 'y', 100)
    dashSlider(T.offZ, '##cab_z', d.offset.z, -100, 150, '%.0f cm', 'z', 100)
  end
  pickerBlock('dash', T.dashHelp)
  if #d.meshes > 0 then dashSlider(T.dashIntensity, '##dash_i', d.intensity, 0.1, 60, '%.1f', 'intensity', 1) end
end

-- ---------------------------------------------------------------- scenario rows

-- Výš / Níž inside one light: moves past the scenarios of other lights until it passes its neighbour (the order of
-- different lights does not matter, each light has its own winner)
local function moveInLight(r, delta)
  local other = delta < 0 and r.prev or r.next
  if not other then return end
  for _ = 1, #lights.order do
    lights.move(r.s.id, delta)
    if (delta < 0 and r.s.prio < other.prio) or (delta > 0 and r.s.prio > other.prio) then break end
  end
end

local function test(r)
  local s = r.s
  if lights.test(s.id) then
    if s.out.real and lights.online.realBlock(G.realOnline) then say(s.id, T.testOnline) end
    return
  end
  if not S.master then say(s.id, T.testMaster)
  elseif not G.enabled then say(s.id, T.testEnabled)
  elseif s.out == lights.OUT.flash and s.out.ch == lights.CH.highBeams then say(s.id, T.testHighBeams)
  else say(s.id, T.testOther) end
end

local function subLabel(text)
  ui.dummy(INDENT)
  ui.sameLine(0, 0)
  K.label(text)
end

local function details(r)
  local s, l = r.s, r.l
  local params = s.def.params
  for k = 1, #params do
    local d, p = params[k], l.params[k]
    if d.bool then
      ui.dummy(INDENT)
      ui.sameLine(0, 0)
      local cur = s.P[d.key] >= 0.5
      if ui.checkbox(p.label, cur) then lights.setParam(s.id, d.key, cur and 0 or 1) end
      if p.help then K.help(p.help) end
    else
      subLabel(d.name)
      ui.setNextItemWidth(K.CONTROL_W)
      local v, changed = ui.slider(p.label, s.P[d.key], d.min, d.max, p.fmt)
      if changed then lights.setParam(s.id, d.key, v) end
    end
  end
  if r.hasColour then
    subLabel(T.colour)
    local c = r.colour
    if K.colourField(l.colour, c) then lights.setColour(s.id, color.pack(c.r, c.g, c.b)) end
  end
  if r.hint then
    subLabel('')
    K.dim(r.hint)
  end
end

local function scenarioRow(r)
  local s, l = r.s, r.l
  if r.caption then K.caption(r.caption) end
  if ui.checkbox(l.on, s.on) then lights.setOn(s.id, not s.on) end
  ui.sameLine()
  if ui.selectable(l.name, expanded == s.id, 0, NAME_SIZE) then expanded = expanded ~= s.id and s.id or nil end
  if ui.itemHovered() then ui.setTooltip(r.tip) end
  if s.active then
    ui.sameLine(X_DOT)
    K.dot(K.GREEN)
  end
  ui.sameLine(X_TEST)
  local testing = s.forceUntil > lights.clock
  if ui.button(testing and l.testing or l.test, TEST_SIZE) then test(r) end
  K.tip(T.testTip)
  if r.prev then
    ui.sameLine(X_UP)
    if K.iconButton(l.up, ICON_UP, T.up) then moveInLight(r, -1) end
  end
  if r.next then
    ui.sameLine(X_DOWN)
    if K.iconButton(l.down, ICON_DOWN, T.down) then moveInLight(r, 1) end
  end
  if expanded == s.id then details(r) end
  showMessage(s.id)
end

-- ---------------------------------------------------------------- Diagnostika

local diagText, diagVersion = '', -1

local function diagContent()
  if diagVersion ~= lights.version then
    diagText, diagVersion = table.concat(lights.diagLines(), '\n'), lights.version
  end
  ui.textWrapped(diagText)
  if ui.button(T.refresh) then diagVersion = -1 end
  ui.sameLine()
  if ui.button(T.extras) then
    lights.online.readExtras()
    diagVersion = -1
  end
  K.tip(T.extrasTip)
  ui.sameLine()
  if ui.button(T.copyDiag) then
    ac.setClipboardText(diag.text())
    say('diag', T.copied, K.GREEN)
  end
  showMessage('diag')
end

-- ---------------------------------------------------------------- tab

local function draw()
  refresh()
  if ui.checkbox(T.enabled, G.enabled) then lights.setGlobal('enabled', not G.enabled) end
  K.tip(T.enabledTip)
  ui.sameLine(0, 24)
  if ui.checkbox(T.realOnline, G.realOnline) then lights.setGlobal('realOnline', not G.realOnline) end
  K.help(T.realOnlineHelp)
  if not S.master then K.note(T.masterOff, K.ORANGE) end
  -- online: the header says that real lights are seen by others; here only when the app does not drive them
  if runtime.ST.isOnline and not G.realOnline then K.note(T.onlineBlocked, K.ORANGE) end
  if lights.carId == '' or runtime.state == 'wait' or not lights.carSettings() then
    K.dim(T.wait)
    return
  end
  if not lights.running then lights.poll() end
  for i = 1, #lights.notes do K.note(lights.notes[i], K.ORANGE) end
  itemsRow()
  K.section(rainTitle, false, rainContent)
  K.section(T.backSection, false, backContent)
  K.header(T.scenTitle)
  K.help(T.scenHelp)
  if nRows == 0 then K.dim(T.noScen) end
  for i = 1, nRows do scenarioRow(rows[i]) end
  K.section(T.diagSection, false, diagContent)
end

M.draw = draw

return M
