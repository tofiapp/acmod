-- Tab Displej: takes the car's display over (src/display.lua) and shows a live preview of the page drawn by the same
-- code (src/display_pages.lua) into the window.
-- Rows: Převzít displej, the displays (more than one), how it is drawn (copy / directly), Stránka, Obnovování,
-- Převezme; collapsed sections Vzhled (theme, own colours, font, rounding, brightness, units), Řada diod (shown,
-- cells, height, gap), Vlastní stránka (field per zone), Oblast displeje (correction of the region in the texture),
-- Textura; then the state line and Náhled.
-- Sliders and colour pickers take effect at once and are saved once they rest (config.setLive / flushLive, the car
-- profile for the region the same way), so nothing is written every frame while dragging.
-- No allocation per frame: labels are prebuilt or built when the car's displays change (display.version), combo
-- contents are module-level functions, the paint rate line is built once a second.
-- CSP calls besides the kit: ui.checkbox, ui.slider, ui.combo, ui.selectable, ui.colorButton(label, rgbm,
-- ui.ColorPickerFlags.PickerHueBar, size), ui.getCursorX / getCursorY, ui.availableSpaceX, ui.dummy, ui.button
-- (official apps, all already used by the other tabs).

local csp = require('src/csp')
local ui, vec2, rgbm = csp.ui, csp.vec2, csp.rgbm
local K = require('src/ui/kit')
local config = require('src/config')
local runtime = require('src/runtime')
local display = require('src/display')
local pages = require('src/display_pages')

local S = config.S
local M = {}

local T = {
  take = 'Převzít displej##dispOn',
  takeHelp = 'Aplikace kreslí na displej auta vlastní stránku: řada otáček (stejný preset a animace jako diody), '
    .. 'převod, rychlost, časy kol. Pit limiter, vlajky a málo paliva převezmou celý displej.\n\n'
    .. 'Funguje u aut, která mají displej jako „scriptable display“ CSP (sekce [SCRIPTABLE_DISPLAY_...] v konfiguraci '
    .. 'auta). Původní displej je jen schovaný: po vypnutí se vrátí.',
  none = 'Auto nemá displej, který by aplikace poznala (CSP [SCRIPTABLE_DISPLAY_...]). Náhled ukazuje, jak by stránka '
    .. 'vypadala.',
  displays = 'Displeje',
  modeCopy = 'Kreslí se do kopie displeje (původní je schovaný).',
  modeDirect = 'Kreslí se přímo do displeje: z jeho meshe nejde udělat kopie. Po vypnutí se vrátí původní textura.',
  modeMixed = 'Část meshů displeje se kreslí do kopie, část přímo.',
  page = 'Stránka',
  hz = 'Obnovování',
  hzHelp = 'Nejvýš kolikrát za sekundu se displej překreslí. Kreslí se jen při změně, stojící auto se nepřekresluje.',
  takes = 'Převezme',
  takesHelp = 'Situace, které na chvíli zaberou celý displej (málo paliva jen pruh dole).',
  look = 'Vzhled##dispLook',
  theme = 'Motiv',
  themeHelp = 'Hotové barvy. Změnou kterékoli barvy níž vznikne vlastní motiv (začne z barev vybraného).',
  font = 'Písmo',
  fontHelp = 'Písma z Windows. Text se vždy zmenší tak, aby se vešel.',
  rounding = 'Zaoblení',
  textScale = 'Velikost textu',
  textScaleHelp = 'Text se vždy zmenší tak, aby se vešel do svého místa; tady ho jde celkově zmenšit nebo zvětšit.',
  margin = 'Okraje',
  light = 'Jas',
  brightness = 'Jas barev',
  brightnessHelp = 'Ztlumí barvy stránky (bílá šedne). Převzetí vlajkou se ztlumí taky.',
  glow = 'Svit displeje',
  glowHelp = 'Jak silně displej svítí sám (emisivita jeho materiálu, 100 % = jako v autě). Když je displej v noci '
    .. 'oslňující nebo ve dne bledý, upravte ho tady.',
  noGlow = 'Tento displej sám nesvítí (materiál bez emisivity): jas jde měnit jen přes Jas barev.',
  nightOn = 'V noci ztlumit##dispNightOn',
  nightHelp = 'Podle času na trati: před 6:00 a od 20:00 se svit i barvy ztlumí na zadanou hodnotu.',
  night = 'V noci na',
  units = 'Rychlost',
  row = 'Řada diod##dispRow',
  rowShow = 'Zobrazit řadu diod##dispCellsOn',
  rowHelp = 'Řada otáček na stránce: stejný preset jako diody na volantu, takže ukazuje i vaše animace.',
  cells = 'Políček',
  cellH = 'Výška',
  cellGap = 'Mezera',
  custom = 'Vlastní stránka##dispCustom',
  customHelp = 'Co ukáže stránka Vlastní na kterém místě (rozvržení jako stránka Závod).',
  area = 'Oblast displeje##dispArea',
  areaHelp = 'Kde v textuře displeje se kreslí. Když stránka sedí posunutá, oříznutá nebo moc malá, zapněte Kalibraci '
    .. 'a upravte ji tady (v pixelech textury, k výchozí oblasti).',
  source = 'Výchozí oblast',
  sourceHelp = 'Podle meshe: část textury, kterou mesh displeje opravdu ukazuje (z jeho UV). Podle konfigurace: '
    .. 'DISPLAY_POS / DISPLAY_SIZE z konfigurace auta. Když hra vrcholy meshe nedá, jde jen konfigurace.',
  sourceLabels = { 'Podle meshe##dispSrc1', 'Podle konfigurace auta##dispSrc2' },
  sourceNoUv = 'Mesh nedal vrcholy (UV), oblast je z konfigurace auta: dolaďte ji s Kalibrací.',
  rotation = 'Otočení',
  rotationHelp = 'Když je displej v textuře otočený (stránka je na volantu bokem nebo vzhůru nohama), otočte ji tady '
    .. '(po směru hodinových ručiček). Při kalibraci ukazuje oranžový pruh, kam padne horní okraj stránky.',
  rotationLabels = { '0°##dispRot1', '90°##dispRot2', '180°##dispRot3', '270°##dispRot4' },
  calibrate = 'Kalibrace (mřížka přes celou texturu)##dispCalib',
  calibrateHelp = 'Na displej se nakreslí mřížka přes celou texturu: v každém políčku je nahoře modře x a pod ním '
    .. 'růžově y jeho levého horního rohu (pixely textury). Žlutý rámeček je oblast, kam se kreslí (rohy 1–4 po směru '
    .. 'hodinových ručiček, oranžový pruh = horní okraj stránky). Podle čísel u okrajů displeje na volantu nastavte '
    .. 'posun a velikost tak, aby rámeček seděl přesně na okraje displeje. Neukládá se.',
  areaX = 'Posun vodorovně',
  areaY = 'Posun svisle',
  areaW = 'Šířka ±',
  areaH = 'Výška ±',
  areaReset = 'Výchozí oblast##dispAreaReset',
  areaNone = 'Oblast jde upravit, až bude displej převzatý.',
  advanced = 'Textura##dispAdvanced',
  slot = 'Textura',
  slotHelp = 'Do které textury materiálu displeje se kreslí. Automaticky: txDiffuse, a když ji materiál má, i '
    .. 'txEmissive (svítí jako displej auta). Když displej po převzetí zůstane černý nebo se nemění, zkuste jinou.',
  material = 'Materiál',
  preview = 'Náhled',
  running = 'Kreslí se %d× za sekundu',
  idle = 'Displej se teď nepřekresluje (nic se nemění)',
}

local function labels(list, key, tag)
  local out = {}
  for i = 1, #list do out[i] = list[i][key] .. '##' .. tag .. i end
  return out
end
local PAGE_LABELS = labels(pages.PAGES, 'name', 'dispPage')
local THEME_LABELS = labels(pages.THEMES, 'name', 'dispTheme')
THEME_LABELS[#THEME_LABELS + 1] = 'Vlastní##dispTheme0'
local FONT_LABELS = labels(pages.FONTS, 'name', 'dispFont')
local UNIT_LABELS = { 'km/h##dispUnit1', 'mph##dispUnit2' }
local SLOT_LABELS = { 'Automaticky##dispSlot0', 'txDiffuse##dispSlot1', 'txEmissive##dispSlot2' }
local SLOT_INDEX = { auto = 1, txDiffuse = 2, txEmissive = 3 }
local GROUP_LABELS = {}
for i = 1, #pages.OVERLAY_GROUPS do GROUP_LABELS[i] = pages.OVERLAY_GROUPS[i][2] .. '##dispGroup' .. i end
local GROUP_KEYS = { pit = 'displayPit', flags = 'displayFlags', fuel = 'displayFuel' }
local COLOUR_LABELS, COLOURS, SHOWN = {}, {}, {}
for i = 1, #pages.COLOUR_KEYS do
  COLOUR_LABELS[i] = '##dispColour' .. i
  COLOURS[i] = rgbm(0, 0, 0, 1)
  SHOWN[i] = -1
end
local ZONE_LABELS = {}
for i = 1, #pages.ZONE_NAMES do ZONE_LABELS[i] = '##dispZone' .. i end
local COLOUR_SIZE = vec2(60, 0)
local PICKER = ui.ColorPickerFlags and ui.ColorPickerFlags.PickerHueBar or 0
local SAVE_AFTER = 0.5     -- s a live edit has to rest before it is saved

local displayLabels, seenVersion = {}, -1
local rateText, lastPaints, rateClock = T.idle, 0, 0
local editedAt, profileDirty = -10, false

local function refresh()
  if seenVersion == display.version then return end
  seenVersion = display.version
  displayLabels = {}
  for i = 1, #display.displays do displayLabels[i] = display.displays[i].label .. '##dispWhich' .. i end
end

local function rate()
  local now = runtime.clock
  if now - rateClock < 1 then return end
  local n = display.paints - lastPaints
  lastPaints, rateClock = display.paints, now
  rateText = n > 0 and string.format(T.running, n) or T.idle
end

-- a setting dragged / picked: in effect now, saved once it rests
local function live(key, value)
  config.setLive(key, value)
  display.applyStyle()
  editedAt = runtime.clock
end

local regionDirty = false
local function flush()
  config.flushLive()
  if profileDirty then display.save(); profileDirty = false end
  -- a moved / resized region: take the display again, so nothing painted outside the new region stays in the texture
  if regionDirty then display.retake(); regionDirty = false end
end

local function slider(label, id, key, lo, hi, fmt)
  K.label(label)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider(id, tonumber(S[key]) or lo, lo, hi, fmt)
  if changed then live(key, math.floor(v + 0.5)) end
end

-- ---------------------------------------------------------------- rows

local function settingsRows()
  local c = display.cfg()
  if ui.checkbox(T.take, c.on == true) then
    c.on = not c.on
    display.error = nil
    display.save()
    display.invalidate()
  end
  K.help(T.takeHelp)
  if #display.displays > 1 then
    for i = 1, #display.displays do
      if i == 1 then K.label(T.displays) else K.label('') end
      local which = type(c.which) == 'table' and c.which or nil
      local on = which and which[i] == true or (not which and i == 1)
      if ui.checkbox(displayLabels[i], on) then
        if not which then which = { true }; c.which = which end
        which[i] = not on
        display.save()
      end
    end
  elseif #display.displays == 1 then
    K.dim(display.displays[1].label)
  end
  local mode = display.modeOf(1) or display.modeOf(2)
  if mode == 'copy' then K.dim(T.modeCopy) elseif mode == 'direct' then K.note(T.modeDirect, K.GREY)
  elseif mode == 'mixed' then K.dim(T.modeMixed) end
  K.label(T.page)
  local pick = K.choice(PAGE_LABELS, display.page)
  if pick then display.setPage(pick) end
  K.label(T.hz)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider('##dispHz', S.displayHz, 5, 60, '%.0f Hz')
  if changed then config.setLive('displayHz', math.floor(v + 0.5)); editedAt = runtime.clock end
  K.help(T.hzHelp)
  for i = 1, #pages.OVERLAY_GROUPS do
    if i == 1 then K.label(T.takes) else K.label('') end
    local key = GROUP_KEYS[pages.OVERLAY_GROUPS[i][1]]
    if ui.checkbox(GROUP_LABELS[i], S[key] ~= false) then
      config.set(key, S[key] == false)
      display.invalidate()
    end
    if i == 1 then K.help(T.takesHelp) end
  end
end

-- own colours: the current style's colours, edited in place by the colour buttons
local function byte(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
local function packOf(c) return byte(c.r) * 65536 + byte(c.g) * 256 + byte(c.b) end
local function colourString()
  local parts = {}
  for i = 1, #pages.COLOUR_KEYS do parts[i] = string.format('#%06X', packOf(COLOURS[i])) end
  return table.concat(parts, ',')
end

local function lookRows()
  K.label(T.theme)
  local th = tonumber(S.displayTheme) or 1
  local pick = K.choice(THEME_LABELS, th == 0 and #THEME_LABELS or th)
  if pick then
    if pick == #THEME_LABELS then
      live('displayColours', colourString())
      live('displayTheme', 0)
    else
      live('displayTheme', pick)
    end
  end
  K.help(T.themeHelp)
  local st = pages.style
  for i = 1, #pages.COLOUR_KEYS do
    local key = pages.COLOUR_KEYS[i]
    local c = COLOURS[i]
    local stored = st[key]
    if SHOWN[i] ~= stored then
      c.r, c.g, c.b = math.floor(stored / 65536) % 256 / 255, math.floor(stored / 256) % 256 / 255, stored % 256 / 255
      SHOWN[i] = stored
    end
    K.label(pages.COLOUR_NAMES[i])
    ui.colorButton(COLOUR_LABELS[i], c, PICKER, COLOUR_SIZE)
    local p = packOf(c)
    if p ~= SHOWN[i] then
      SHOWN[i] = p
      live('displayColours', colourString())
      if (tonumber(S.displayTheme) or 1) ~= 0 then live('displayTheme', 0) end
    end
  end
  K.label(T.font)
  pick = K.choice(FONT_LABELS, tonumber(S.displayFont) or 1)
  if pick then live('displayFont', pick) end
  K.help(T.fontHelp)
  slider(T.rounding, '##dispRounding', 'displayRounding', 0, 100, '%.0f %%')
  slider(T.textScale, '##dispTextScale', 'displayTextScale', 50, 160, '%.0f %%')
  K.help(T.textScaleHelp)
  slider(T.margin, '##dispMargin', 'displayMargin', 0, 12, '%.0f %%')
  K.label(T.units)
  pick = K.choice(UNIT_LABELS, tonumber(S.displayUnits) or 1)
  if pick then live('displayUnits', pick) end
end

-- brightness rows (in the main view: glow of the display material, colour brightness, night dimming)
local function lightRows()
  K.caption(T.light)
  slider(T.glow, '##dispGlow', 'displayGlow', 0, 400, '%.0f %%')
  K.help(T.glowHelp)
  for k = 1, #display.displays do
    if display.modeOf(k) and display.glows(k) == false then K.note(T.noGlow, K.GREY); break end
  end
  slider(T.brightness, '##dispBrightness', 'displayBrightness', 20, 100, '%.0f %%')
  K.help(T.brightnessHelp)
  if ui.checkbox(T.nightOn, S.displayNightOn == true) then live('displayNightOn', S.displayNightOn ~= true) end
  K.help(T.nightHelp)
  if S.displayNightOn == true then slider(T.night, '##dispNight', 'displayNight', 5, 100, '%.0f %%') end
end

local function rowRows()
  if ui.checkbox(T.rowShow, S.displayCellsOn ~= false) then live('displayCellsOn', S.displayCellsOn == false) end
  K.help(T.rowHelp)
  slider(T.cells, '##dispCells', 'displayCells', 4, 24, '%.0f')
  slider(T.cellH, '##dispCellH', 'displayCellH', 40, 200, '%.0f %%')
  slider(T.cellGap, '##dispCellGap', 'displayCellGap', 0, 50, '%.0f ‰')
end

-- page Vlastní: a combo per zone (contents read the zone being drawn from comboZone)
local comboZone = 1
local function zoneItems()
  local z = pages.style.zones
  local cur = z[comboZone]
  for i = 1, #pages.FIELDS do
    local f = pages.FIELDS[i]
    if ui.selectable(f.name, f.id == cur) and f.id ~= cur then
      local copy = {}
      for k = 1, #pages.ZONE_NAMES do copy[k] = z[k] or pages.DEFAULT_ZONES[k] end
      copy[comboZone] = f.id
      config.set('displayZones', table.concat(copy, ','))
      display.applyStyle()
    end
  end
end
local function customRows()
  local z = pages.style.zones
  for i = 1, #pages.ZONE_NAMES do
    K.label(pages.ZONE_NAMES[i])
    comboZone = i
    ui.setNextItemWidth(K.CONTROL_W)
    local f = pages.FIELD_BY_ID[z[i] or 'none']
    ui.combo(ZONE_LABELS[i], f and f.name or '—', ui.ComboFlags.None, zoneItems)
    if i == 1 then K.help(T.customHelp) end
  end
end

-- region correction of the first taken display
local AREA = { { T.areaX, '##dispAreaX', -400, 400 }, { T.areaY, '##dispAreaY', -400, 400 },
  { T.areaW, '##dispAreaW', -600, 600 }, { T.areaH, '##dispAreaH', -600, 600 } }
local areaText, areaFor = '', { -1, -1, -1, -1 }
local ZERO = { 0, 0, 0, 0 }
local function areaRows()
  local i = nil
  for k = 1, #display.displays do if display.modeOf(k) then i = k; break end end
  if not i then K.dim(T.areaNone); return end
  local c = display.cfg()
  K.label(T.source)
  local src = K.choice(T.sourceLabels, c.regionMode == 'config' and 2 or 1)
  if src then
    c.regionMode = src == 2 and 'config' or nil
    display.save()
    display.retake()
  end
  K.help(T.sourceHelp)
  if not display.taken[i] or not display.taken[i].uv then K.note(T.sourceNoUv, K.GREY) end
  K.label(T.rotation)
  local rot = K.choice(T.rotationLabels, display.rotation() / 90 + 1)
  if rot then
    c.rotation = rot > 1 and (rot - 1) * 90 or nil
    display.save()
    display.retake()
  end
  K.help(T.rotationHelp)
  local cal = ui.checkbox(T.calibrate, display.calibrate)
  if cal then display.setCalibrate(not display.calibrate) end
  K.help(T.calibrateHelp)
  local a = (c.adjust and c.adjust[i]) or ZERO
  for k = 1, 4 do
    local e = AREA[k]
    K.label(e[1])
    ui.setNextItemWidth(K.CONTROL_W)
    local v, changed = ui.slider(e[2], tonumber(a[k]) or 0, e[3], e[4], '%.0f px')
    if changed then
      if a == ZERO then a = { 0, 0, 0, 0 } end
      a[k] = math.floor(v + 0.5)
      c.adjust = c.adjust or {}
      c.adjust[i] = a
      display.applyRegion(i)
      display.invalidate()
      profileDirty, regionDirty, editedAt = true, true, runtime.clock
    end
    if k == 1 then K.help(T.areaHelp) end
  end
  local x, y, w, h = display.regionOf(i)
  local d = display.displays[i]
  if x ~= areaFor[1] or y ~= areaFor[2] or w ~= areaFor[3] or h ~= areaFor[4] then
    areaFor[1], areaFor[2], areaFor[3], areaFor[4] = x, y, w, h
    areaText = string.format('Kreslí se na %d, %d – %d × %d v textuře %d × %d', x, y, w, h, d.res.x, d.res.y)
  end
  K.dim(areaText)
  if ui.button(T.areaReset) and c.adjust then
    c.adjust[i] = nil
    display.save()
    display.retake()
  end
end

local describeText, describeVersion = '', -1
local function advanced()
  local c = display.cfg()
  K.label(T.slot)
  local pick = K.choice(SLOT_LABELS, SLOT_INDEX[display.slotMode()] or 1)
  if pick then
    c.slot = pick == 2 and 'txDiffuse' or (pick == 3 and 'txEmissive' or nil)
    display.save()
    display.retake()
  end
  K.help(T.slotHelp)
  for k = 1, #display.displays do
    if display.modeOf(k) then
      if describeVersion ~= display.version then
        describeVersion = display.version
        describeText = display.describe(k) or ''
      end
      K.label(T.material)
      K.dim(describeText)
      break
    end
  end
end

local size = vec2()
local function preview()
  local W, H = 800, 480
  for k = 1, #display.displays do
    if display.modeOf(k) then
      local _, _, w, h = display.regionOf(k)
      W, H = w, h
      break
    end
  end
  if W == 800 and display.displays[1] then W, H = display.displays[1].size.x, display.displays[1].size.y end
  local avail = ui.availableSpaceX()
  local scale = math.min(1, (avail - 4) / W)
  local x, y = ui.getCursorX(), ui.getCursorY()
  pages.origin(x, y, scale)
  pages.draw(display.page, W, H, display.data)
  size.x, size.y = W * scale, H * scale
  ui.dummy(size)
end

local function draw()
  refresh()
  rate()
  if (config.hasLive() or profileDirty or regionDirty) and runtime.clock - editedAt > SAVE_AFTER then flush() end
  if #display.displays == 0 then K.note(T.none, K.GREY) end
  settingsRows()
  lightRows()
  K.section(T.look, false, lookRows)
  K.section(T.row, false, rowRows)
  K.section(T.custom, false, customRows)
  K.section(T.area, false, areaRows)
  K.section(T.advanced, false, advanced)
  if display.error then K.note(display.error, K.RED)
  elseif display.nTaken > 0 then K.dim(rateText) end
  display.preview(1 / 60, runtime.ST, runtime.preset())
  K.caption(T.preview)
  preview()
end

M.draw = draw
M.flush = flush
return M
