-- Diagnostics text for "Kopírovat diagnostiku" (built on demand, not per frame).

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')
local lights = require('src/lights')

local S = config.S
local M = { VERSION = '0.6.4' }

local function join(list)
  if type(list) ~= 'table' then return tostring(list) end
  local out = {}
  for i = 1, #list do out[i] = tostring(list[i]) end
  return table.concat(out, ', ')
end

local function keysOf(t)
  local out = {}
  for k, v in pairs(t or {}) do out[#out + 1] = tostring(k) .. '=' .. join(v) end
  table.sort(out)
  return table.concat(out, '; ')
end

function M.text()
  local L = {}
  local function add(fmt, ...) L[#L + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt end
  local lay, info, st = runtime.layout, runtime.info, takeover.stats
  add('LedControl %s – diagnostika', M.VERSION)
  add('Auto: %s | stav: %s | poslední restart: %s', runtime.carId, runtime.STATES[runtime.state] or runtime.state,
    runtime.lastRestart)
  add('Metoda: chtěná %s, běží %s', takeover.NAMES[runtime.method()] or '?', takeover.NAMES[takeover.method] or 'žádná')
  if takeover.fallback then add('Záloha: %s', takeover.fallback) end
  add('Jas: ruční %d, auto %s (den %d, noc %d), teď %.1f | ochrana barev %d %%', S.intensity, tostring(S.autoBrightness),
    S.intensityDay, S.intensityNight, runtime.effectiveIntensity(), math.floor((S.colourGuard or 0) * 100 + 0.5))
  local R = runtime.rpm
  if R then
    add('Otáčky: začátek %s, řazení %d (%s%s), omezovač %d (%s%s), naměřeno %d, max %d, příznak AC %s%s',
      R.start > 0 and tostring(R.start) or 'z presetu', R.shift, R.auto.shiftFrom or '?', R.manual.shift and ', ručně' or '',
      R.limiter, R.auto.limiterFrom or '?', R.manual.limiter and ', ručně' or '', R.learned, R.maxSeen,
      R.flagUnreliable and 'nespolehlivý' or 'ok', R.ledRpm and (', vlastní otáčky ' .. #R.ledRpm .. ' diod') or '')
  end
  add('Hlavní vypínač: %s | jas: %d | režim: %s | preset: %s', tostring(S.master), S.intensity,
    runtime.MODES[S.testMode] or 'normální provoz', runtime.presetId)
  local C = runtime.compiled
  if C then
    for gi = 1, #C.groups do
      local g = C.groups[gi]
      add('  skupina %d (%s): kandidátů %d, teď svítí: %s', gi, g.name, #g.cands, g.activeName or 'základ presetu')
    end
    for i = 1, #C.scen do
      local sc = C.scen[i]
      if not sc.avail or sc.note then add('  scénář %s: %s%s', sc.id, sc.avail and '' or 'nedostupný, ', sc.note or '') end
    end
    for i = 1, #C.warnings do add('  varování: %s', C.warnings[i]) end
  end
  local ST = runtime.ST
  add('Stav auta: rpm %.0f / omezovač %.0f / řazení %.0f%s | rychlost %.0f | palivo %.1f (varování %.1f) | vlajka %d | DRS %s | ABS %s TC %s',
    ST.rpm, ST.rpmLimiter, ST.shiftUp, ST.shiftKnown and ' (ai.ini)' or ' (odhad)', ST.speed, ST.fuel, ST.fuelWarn, ST.flag,
    tostring(ST.drsPresent), tostring(ST.hasAbs), tostring(ST.hasTc))
  if lay then
    local c = lay.counts or {}
    add('Zdroj diod: %s | kandidáti: digital_instruments=%d, csp_rpm=%d, actsAsLED=%d, jména=%d', lay.source,
      c.digital_instruments or 0, c.csp_rpm or 0, c.acts_as_led or 0, c.names or 0)
    add('Skupiny: %s (práh shluků %.1f cm), volant při hledání %.0f°', lay.signature, (lay.threshold or 0) * 100,
      lay.steer or 0)
    for gi = 1, #lay.groups do
      local g = lay.groups[gi]
      add('  skupina %d: %s (%s, %s), diody %s', gi, g.name, g.role, g.vertical and 'svisle' or 'vodorovně', join(g.leds))
    end
    add('Diody (zleva doprava v každé skupině):')
    for i = 1, #lay.leds do
      local led = lay.leds[i]
      add('  %d. %s | skupina %d | zdroj %s | rpm %s | bok %.3f m, výška %.3f m | instancí %d', i, led.name, led.group,
        led.source, tostring(led.rpm or '-'), led.lateral, led.height, #led.inst)
      for k = 1, #led.inst do
        local inst = led.inst[k]
        add('      #%d uzel %s | materiál %s | r %.1f cm | LOD A %s | viditelný %s', k, inst.parentName, inst.material,
          inst.radius * 100, tostring(inst.lodA), tostring(inst.visible))
      end
    end
    for i = 1, #lay.rejected do
      local r = lay.rejected[i]
      add('Odmítnuto: %s (%s): %s', r.name, r.source, r.reason)
    end
    for i = 1, #lay.warnings do add('Varování: %s', lay.warnings[i]) end
  end
  add('Převzetí: kopií %d, instancí %d, zápisů %d, znovu zobrazené originály %d, AC přepsal kopii %d, boje (C) %d%s',
    st.copies, st.instances, st.writes, st.reShows, st.copyWrites, st.fights, takeover.fightMode and ' (zapisuji každý snímek)' or '')
  add('Kontrola při vykreslení: %d, prohraných %d, přepnutí metody %d | LuaJIT: %s', st.renderChecks or 0,
    st.renderLost or 0, st.switched or 0, tostring(require('src/csp').jitVersion))
  add('Materiály (C): před %d, po %d, rozděleno %s | chyby kreslení (B) %d | uzdraveno meshů %d', st.materialsBefore,
    st.materialsAfter, tostring(st.split), st.drawErrors, runtime.healed)
  local okD, dsp = pcall(require, 'src/display')
  if okD and dsp then
    local c = dsp.cfg()
    add('Displej: nalezeno %d, převzato %d, zapnuto %s, stránka %d, %d Hz, překreslení %d%s', #dsp.displays, dsp.nTaken,
      tostring(c.on == true), dsp.page, S.displayHz or 0, dsp.paints, dsp.error and (' | chyba: ' .. dsp.error) or '')
    for i = 1, #dsp.displays do
      add('  %s [%s] převzetí: %s, svítí sám: %s', dsp.displays[i].label, dsp.displays[i].section,
        tostring(dsp.modeOf(i) or 'ne'), tostring(dsp.glows(i)))
      local okX, line = pcall(dsp.describe, i)
      if okX and line then add('    %s | otočení %d°', line, dsp.rotation()) end
    end
    if dsp.lastRestore then add('  poslední návrat displeje: %s', dsp.lastRestore) end
  end
  local okL, lines = pcall(lights.diagLines)
  if okL and type(lines) == 'table' then
    for i = 1, #lines do add('%s', tostring(lines[i])) end
  end
  if info then
    add('ai.ini [GEARS] UP: %s | CSP config: %d sekcí', tostring(info.shiftUp), info.cspSections)
    for i = 1, #info.leds do
      local led = info.leds[i]
      add('[%s] %s', led.section, keysOf(led.keys))
    end
    for i = 1, #info.cspRpm do
      local e = info.cspRpm[i]
      add('CSP [%s] NAME=%s INPUT_THRESHOLD=%s COLOR=%s', e.section, join(e.names), tostring(e.threshold), join(e.color))
    end
    for i = 1, #info.generators do add('CSP generátor %s', info.generators[i]) end
    for i = 1, #info.errors do add('Chyba čtení: %s', info.errors[i]) end
  end
  if safety.error then add('CHYBA (%s): %s\n%s', tostring(safety.where), safety.error, tostring(safety.trace)) end
  if safety.uiError then add('Chyba okna: %s', safety.uiError) end
  return table.concat(L, '\n')
end

return M
