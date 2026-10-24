-- Diagnostics text for "Kopírovat diagnostiku" (built on demand, not per frame).

local config = require('src/config')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local safety = require('src/safety')

local S = config.S
local M = { VERSION = '0.1.0' }

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
  add('Hlavní vypínač: %s | jas: %d | test: %s', tostring(S.master), S.intensity, runtime.MODES[S.testMode] or '?')
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
  add('Materiály (C): před %d, po %d, rozděleno %s | chyby kreslení (B) %d | uzdraveno meshů %d', st.materialsBefore,
    st.materialsAfter, tostring(st.split), st.drawErrors, runtime.healed)
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
