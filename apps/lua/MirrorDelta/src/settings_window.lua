-- Settings window, shared by all three windows (gear icon in their title bar).

local config = require('src/config')
local tracker = require('src/tracker')
local notify = require('src/notify')
local tyres = require('src/tyres_window')
local damage = require('src/damage_window')
local layout = require('src/layout')
local originals = require('src/originals')
local D = require('src/draw')
local S = config.S

local COLOR_KEYS = {
  { 'colPurple', 'Nejlepší čas (fialová)' },
  { 'colGreen', 'Rychlejší (zelená)' },
  { 'colYellow', 'Pomalejší mini sektor (žlutá)' },
  { 'colRed', 'Pomalejší delta (červená)' },
  { 'colIdle', 'Neprojetý mini sektor' },
  { 'colCurrent', 'Aktuální mini sektor' },
  { 'colNeutral', 'Bez reference / šedá' },
  { 'colText', 'Text' },
}

local colorEdits = {}
local confirmClearUntil = 0

local function checkbox(key, label)
  if ui.checkbox(label, S[key]) then config.set(key, not S[key]) end
end

local function slider(key, label, min, max, format, step)
  ui.setNextItemWidth(ui.availableSpaceX())
  local value = ui.slider('##' .. key, S[key], min, max, label .. ': ' .. format)
  if step then value = math.floor(value / step + 0.5) * step end
  value = math.max(min, math.min(max, value))
  if value ~= S[key] then config.set(key, value) end
end

local function combo(key, label, options)
  ui.text(label)
  ui.setNextItemWidth(ui.availableSpaceX())
  ui.combo('##' .. key, options[S[key]] or options[1], ui.ComboFlags.None, function ()
    for i = 1, #options do
      if ui.selectable(options[i], S[key] == i) then config.set(key, i) end
    end
  end)
end

local function colorPicker(key, label)
  local edit = colorEdits[key]
  if not edit then
    edit = rgbm()
    colorEdits[key] = edit
  end
  edit:set(S[key])
  ui.colorButton('##' .. key, edit, ui.ColorPickerFlags.PickerHueBar)
  if ui.itemEdited() then config.set(key, edit:clone()) end
  ui.sameLine(0, 8)
  ui.text(label)
end

local function gap()
  ui.offsetCursorY(6)
end

local function tabDelta()
  ui.header('Zobrazit')
  checkbox('showSectors', 'Mini sektory')
  checkbox('showDeltaLine', 'Čára delty')
  checkbox('showDeltaNumber', 'Delta v sekundách (±)')
  gap()
  combo('deltaLayout', 'Rozložení', {
    'A: čas nahoře, čára delty uprostřed, mini sektory dole',
    'B: mini sektory nahoře, čára delty uprostřed, čas dole',
  })
  gap()
  ui.header('Mini sektory')
  slider('sectors', 'Počet mini sektorů', 6, tracker.MAX_SECTORS, '%.0f', 1)
  slider('sectorGroups', 'Skupiny', 1, 6, '%.0f', 1)
  slider('groupGap', 'Mezera mezi skupinami', 2, 30, '%.0f px', 1)
  gap()
  ui.header('Vzhled (px při šířce okna 600)')
  slider('lineThickness', 'Tloušťka čar', 1, 20, '%.1f px', 0.5)
  slider('lineGap', 'Mezera mezi čarami', 0, 30, '%.1f px', 0.5)
  slider('numberSize', 'Velikost čísla', 9, 60, '%.0f px', 1)
  slider('opacity', 'Průhlednost', 0.1, 1, '%.2f')
  combo('deltaLineMode', 'Barva čáry delty', {
    'Podle aktuálního úseku: zelená = teď rychlejší, červená = teď pomalejší',
    'Podle celkové delty',
  })
  checkbox('deltaLimiterFlash', 'Na omezovači blikat modře: čára delty i mini sektory')
  checkbox('intensityByDelta', 'Intenzita barvy podle velikosti delty')
  if S.intensityByDelta then
    slider('intensityFullAt', 'Plná barva od', 0.1, 2, '±%.2f s')
  end
  gap()
  ui.header('Reference')
  combo('deltaSource', 'Zdroj delty', {
    'Vlastní měření, jinak delta z AC',
    'Jen vlastní měření',
    'Jen delta z AC',
  })
  combo('referenceMode', 'Porovnávat s', { 'Nejlepší kolo této session', 'Nejlepší kolo vůbec (uložené)' })
  ui.text('Session: ' .. D.formatLap(tracker.sessionRefMs, 3) .. '    Vůbec: ' .. D.formatLap(tracker.allTimeRefMs, 3))
  ui.textWrapped('Data pro toto auto a trať: ' .. tracker.dataFile())
  if os.preciseClock() < confirmClearUntil then
    if ui.button('Opravdu smazat? Klikněte znovu') then
      tracker.clearSaved()
      confirmClearUntil = 0
    end
  elseif ui.button('Smazat uložená data') then
    confirmClearUntil = os.preciseClock() + 4
  end
end

local function tabTiming()
  ui.header('Zobrazit')
  checkbox('showPosition', 'Pozice')
  checkbox('showLaps', 'Počet kol')
  checkbox('showCurrent', 'Aktuální čas')
  checkbox('showBest', 'Nejrychlejší čas')
  gap()
  combo('timingLayout', 'Uspořádání', { 'Pod sebou', 'Vedle sebe' })
  gap()
  checkbox('bestHighlight', 'Zvýraznit nejlepší kolo (fialový rámeček)')
  checkbox('lapFlash', 'Po projetí cíle obarvit čas kola')
  if S.lapFlash then
    slider('lapFlashTime', 'Jak dlouho', 1, 10, '%.0f s', 1)
  end
  checkbox('timingPlate', 'Tmavý podklad')
end

local function tabTyres()
  combo('tyreStyle', 'Vzhled', {
    'Velká čísla jádra a proužek pláště',
    'Velké číslo jádra, pneumatika a tři čísla pláště',
  })
  combo('tyreArrange', 'Uspořádání', { '2 × 2 jako na autě', 'Vedle sebe v řadě' })
  gap()
  checkbox('tyreNumbers', 'Teplota jádra (velké číslo)')
  checkbox('tyreZones', 'Zóny pláště (vnitřní / střed / vnější)')
  checkbox('tyresPlate', 'Tmavý podklad')
  gap()
  ui.header('Optimální teplota')
  checkbox('tyreOptimumAuto', 'Podle auta (pokud ji CSP poskytuje)')
  slider('tyreOptimum', S.tyreOptimumAuto and 'Záložní hodnota' or 'Optimum', 50, 120, '%.0f °C', 1)
  gap()
  local available = tyres.available()
  if available == nil then
    ui.textWrapped('Teploty: zjistí se po otevření okna MirrorDelta Tyres.')
  elseif available then
    ui.textWrapped(tyres.optimumFromCar()
      and 'Teploty: dostupné. Optimum: podle auta.'
      or 'Teploty: dostupné. Optimum: auto ho neposkytuje, platí záložní hodnota.')
  else
    ui.textWrapped('Teploty: tato verze CSP je neposkytuje. Aktualizujte Custom Shaders Patch.')
  end
end

local SPEED_STEPS = { 1, 2, 3, 5 }

local function tabGear()
  ui.header('Zobrazit')
  checkbox('gearShowBar', 'Ukazatel otáček (12 dílků, od krajů ke středu)')
  checkbox('gearShowSpeed', 'Rychlost pod převodem')
  checkbox('gearPlate', 'Tmavý podklad')
  gap()
  ui.header('Rychlost')
  ui.text('Číslo se změní, až se rychlost posune o celý krok:')
  ui.setNextItemWidth(ui.availableSpaceX())
  ui.combo('##gearSpeedStep', string.format('po %d km/h', S.gearSpeedStep), ui.ComboFlags.None, function ()
    for i = 1, #SPEED_STEPS do
      local v = SPEED_STEPS[i]
      if ui.selectable(string.format('po %d km/h', v), S.gearSpeedStep == v) then config.set('gearSpeedStep', v) end
    end
  end)
  gap()
  ui.header('Otáčky (rozsah podle omezovače auta)')
  slider('gearRpmStart', 'První dílky od', 0.3, 0.9, '%.2f × omezovač')
  checkbox('gearShiftFlash', 'Na omezovači blikat modře (čára, převod i rychlost)')
end

local function tabDamage()
  combo('damageStyle', 'Vzhled', damage.STYLE_NAMES)
  gap()
  ui.header('Zobrazit')
  checkbox('damageAutoHide', 'Ukázat jen při poškození')
  checkbox('damagePlate', 'Tmavý podklad')
  checkbox('damageHideOriginal', 'Skrýt původní ukazatel poškození z AC, když je toto okno otevřené')
  gap()
  ui.header('Citlivost')
  slider('damageFull', 'Plně červená od hodnoty', 1, 300, '%.0f', 1)
  local car = ac.getCar(0)
  if car then
    ui.textWrapped(string.format('Aktuální hodnoty z AC: přední %.1f, zadní %.1f, levá %.1f, pravá %.1f, motor %.0f / 1000',
      car.damage[0], car.damage[1], car.damage[2], car.damage[3], car.engineLifeLeft))
    ui.textWrapped('Po nárazu podle těchto čísel nastavte, od kolika má být strana plně červená.')
  end
  ui.textWrapped('Kola ukazují pneumatiky: opotřebení (od žluté po červenou) a defekt (červená).'
    .. (damage.wheelFieldsOk() == false and ' Tato verze CSP stav pneumatik neposkytuje.' or ''))
end

local function tabNotify()
  combo('notifyStyle', 'Vzhled', { 'Zaoblená pilulka', 'Šikmý pruh', 'Tenká linka' })
  slider('notifyTime', 'Jak dlouho', 2, 10, '%.1f s', 0.5)
  slider('notifyCount', 'Najednou nejvýš', 1, 3, '%.0f', 1)
  if ui.button('Ukázat ukázku') then notify.demo() end
  ui.textWrapped('Ukázka se zobrazí v okně MirrorDelta Notifications, podle ní okno umístěte.')
  gap()
  ui.header('Co oznamovat')
  checkbox('notifyFastest', 'Nejrychlejší kolo session (kdokoli)')
  checkbox('notifyPositions', 'Moje pozice: předjetí a ztráta')
  checkbox('notifyPits', 'Ostatní auta v boxech a z boxů')
  checkbox('notifySystem', 'Systémové zprávy AC (ABS, TC, penalizace, připojení…)')
  checkbox('notifyFlags', 'Vlajky i jako notifikace (okno MirrorDelta Flags je ukazuje vždy)')
  checkbox('notifyInvalid', 'Moje neplatné kolo (řezání trati)')
  checkbox('notifyConnections', 'Odpojení jezdce (online)')
  checkbox('notifyRaceOnly', 'Pozice a boxy jen v závodě')
  gap()
  ui.header('Původní ukazatele AC')
  checkbox('hideOverlayLeaderboard', 'Vypnout původní pořadí AC (F9)')
  ui.text('Stav: ' .. originals.leaderboard)
  checkbox('hideSystemMessages', 'Skrýt původní systémové zprávy AC')
  ui.text('Stav: ' .. originals.messages)
  ui.textWrapped('Kdyby se původní zprávy dál zobrazovaly: Content Manager > Nastavení > Custom Shaders Patch > GUI > '
    .. 'zapnout „Hide system messages“. Zprávy pak ukáže okno MirrorDelta Notifications.')
end

local function yesNo(v) return v and 'ano' or 'ne' end
local REF_KINDS = { 'žádná', 'nejlepší kolo session', 'nejlepší kolo vůbec', 'dočasné kolo (out lap / neplatné)' }

local function tabDiagnostics()
  local d = tracker.diag
  ui.text('MirrorDelta ' .. config.VERSION)
  if d.error then
    ui.header('Chyba skriptu')
    ui.textWrapped(d.error)
    gap()
  end
  ui.header('Měření kola')
  ui.text('Kolo se měří: ' .. yesNo(tracker.flying) .. '    out lap od výjezdu: ' .. yesNo(tracker.partial) .. '    platné zatím: ' .. yesNo(tracker.clean))
  ui.text('Delta k dispozici: ' .. yesNo(tracker.hasDelta) .. '    reference: ' .. D.formatLap(tracker.refMs, 3))
  ui.text('Reference: ' .. REF_KINDS[tracker.refKind + 1] .. '    dočasné kolo: ' .. D.formatLap(tracker.provisionalMs, 3))
  ui.text('Delta z AC (performanceMeter): ' .. (d.acDelta == nil and 'zatím nezjištěno' or yesNo(d.acDelta))
    .. '    právě použitá: ' .. yesNo(tracker.deltaFromAC))
  if tracker.status then ui.textWrapped('Stav: ' .. tracker.status) end
  ui.text(string.format('Průjezdů cílem: %d    změřených kol: %d    nových referencí: %d', d.lapEvents, d.timedLaps, d.references))
  ui.textWrapped('Poslední zahození kola: ' .. d.lastReset)
  ui.textWrapped('Poslední nezapočítané kolo: ' .. d.lastReject)
  ui.text(string.format('Teleporty/resety: %d    nové session: %d', d.jumps, d.sessionStarts))
  gap()
  ui.header('Hodnoty z AC')
  local car = ac.getCar(0)
  if car then
    local start, u, k = tracker.lapFraction()
    ui.text(string.format('lapCount %d    lapTimeMs %d    previousLapTimeMs %d', car.lapCount, car.lapTimeMs, car.previousLapTimeMs))
    ui.text(string.format('splinePosition %.4f    čára %.4f    část kola %.4f    bodů %d', car.splinePosition, start, u, k - 1))
    ui.text('isLapValid ' .. yesNo(car.isLapValid) .. '    isInPitlane ' .. yesNo(car.isInPitlane) .. '    isInPit ' .. yesNo(car.isInPit))
  end
  gap()
  ui.header('Notifikace')
  ui.text(string.format('Zobrazeno zpráv: %d', notify.count))
  ui.textWrapped('Poslední: ' .. notify.lastLine)
  local sim = ac.getSim()
  ui.text(string.format('Vlajka z AC: %d    online: %s', sim.raceFlagType or -1, yesNo(sim.isOnlineRace)))
  gap()
  ui.textWrapped('Když delta nefunguje: odjeďte dvě až tři celá kola bez řezání a pošlete screenshot této záložky.')
end

local function tabColors()
  for i = 1, #COLOR_KEYS do
    colorPicker(COLOR_KEYS[i][1], COLOR_KEYS[i][2])
  end
  gap()
  if ui.button('Obnovit výchozí barvy') then
    for i = 1, #COLOR_KEYS do config.reset(COLOR_KEYS[i][1]) end
  end
end

local M = {}

function M.draw()
  ui.text('MirrorDelta ' .. config.VERSION)
  ui.sameLine()
  if ui.button('Zobrazit všechna okna uprostřed obrazovky') then
    local ok, err = pcall(layout.arrange)
    if not ok then layout.lastResult = 'chyba: ' .. tostring(err) end
  end
  if layout.lastResult ~= '-' then ui.text(layout.lastResult) end
  ui.tabBar('mirrorDeltaSettings', function ()
    ui.tabItem('Delta', tabDelta)
    ui.tabItem('Časy', tabTiming)
    ui.tabItem('Pneumatiky', tabTyres)
    ui.tabItem('Převody', tabGear)
    ui.tabItem('Poškození', tabDamage)
    ui.tabItem('Notifikace', tabNotify)
    ui.tabItem('Barvy', tabColors)
    ui.tabItem('Diagnostika', tabDiagnostics)
  end)
end

return M
