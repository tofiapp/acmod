-- Tab Displej: takes the car's display over (src/display.lua) and shows a live preview of the page drawn by the same
-- code (src/display_pages.lua) into the window. Rows: Převzít displej, the displays (when the car has more than
-- one), Stránka, Obnovování, Převezme (takeover situations), Textura (collapsed section), the state line, Náhled.
-- No allocation per frame: labels are built when the car's displays change (display.version), the paint rate
-- line once a second.
-- CSP calls besides the kit: ui.checkbox, ui.slider, ui.getCursorX / getCursorY, ui.availableSpaceX, ui.dummy
-- (official apps, all already used by the other tabs).

local csp = require('src/csp')
local ui, vec2 = csp.ui, csp.vec2
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
  page = 'Stránka',
  hz = 'Obnovování',
  hzHelp = 'Nejvýš kolikrát za sekundu se displej překreslí. Kreslí se jen při změně, stojící auto se nepřekresluje.',
  takes = 'Převezme',
  takesHelp = 'Situace, které na chvíli zaberou celý displej (málo paliva jen pruh dole).',
  advanced = 'Textura##dispAdvanced',
  slot = 'Textura',
  slotHelp = 'Do které textury materiálu displeje se kreslí. Když displej po převzetí zůstane černý nebo se nemění, '
    .. 'zkuste druhou.',
  preview = 'Náhled',
  running = 'Kreslí se %d× za sekundu',
  idle = 'Displej se teď nepřekresluje (nic se nemění)',
}

local PAGE_LABELS = {}
for i = 1, #pages.PAGES do PAGE_LABELS[i] = pages.PAGES[i].name .. '##dispPage' .. i end
local SLOT_LABELS = { 'txDiffuse##dispSlot1', 'txEmissive##dispSlot2' }
local GROUP_LABELS = {}
for i = 1, #pages.OVERLAY_GROUPS do GROUP_LABELS[i] = pages.OVERLAY_GROUPS[i][2] .. '##dispGroup' .. i end
local GROUP_KEYS = { pit = 'displayPit', flags = 'displayFlags', fuel = 'displayFuel' }

local displayLabels, seenVersion = {}, -1
local rateText, lastPaints, rateClock = T.idle, 0, 0

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
  K.label(T.page)
  local pick = K.choice(PAGE_LABELS, display.page)
  if pick then display.setPage(pick) end
  K.label(T.hz)
  ui.setNextItemWidth(K.CONTROL_W)
  local v, changed = ui.slider('##dispHz', S.displayHz, 5, 60, '%.0f Hz')
  if changed then config.set('displayHz', math.floor(v + 0.5)) end
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

local function advanced()
  local c = display.cfg()
  K.label(T.slot)
  local pick = K.choice(SLOT_LABELS, c.slot == 'txEmissive' and 2 or 1)
  if pick then
    c.slot = pick == 2 and 'txEmissive' or nil
    display.save()
    display.invalidate()
  end
  K.help(T.slotHelp)
end

local size = vec2()
local function preview()
  local d = display.displays[1]
  local W, H = d and d.size.x or 800, d and d.size.y or 480
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
  if #display.displays == 0 then K.note(T.none, K.GREY) end
  settingsRows()
  K.section(T.advanced, false, advanced)
  if display.error then K.note(display.error, K.RED)
  elseif display.nTaken > 0 then K.dim(rateText) end
  display.preview(1 / 60, runtime.ST, runtime.preset())
  K.caption(T.preview)
  preview()
end

M.draw = draw
return M
