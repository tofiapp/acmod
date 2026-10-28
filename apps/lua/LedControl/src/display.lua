-- Display takeover (tab Displej): LedControl draws its own pages on the car's dash / steering wheel display.
--
-- Displays are the CSP car config sections [SCRIPTABLE_DISPLAY_...] (MESHES, RESOLUTION, DISPLAY_POS, DISPLAY_SIZE,
-- as in acc-lua-examples/cars/dash_display_8100). A taken display gets a shadow copy of its meshes (createMesh of
-- getVertices / getIndices in the same parent, assignMaterialFrom + ensureUniqueMaterials, as src/takeover.lua does
-- for LEDs), the original meshes are hidden, and the copy's texture is painted with
--   copy:setMaterialTexture(slot, { textureSize, background, region = { from, size }, callback })
-- (acc-lua-sdk lib_scene.lua: "draw a texture in a style of scriptable displays"; used by CSP's traffic tool for
-- licence plates). Master off, display off or an error: the copies go away and the originals are shown again, so the
-- car's own display script is back. A self-heal marker (config displayGuard) re-shows originals a crash left hidden.
--
-- What is painted: a page of src/display_pages.lua with the live values; the LED row on the page comes from the
-- same engine and preset as the real LEDs (a virtual row of 12 cells), so the user's animations show there too.
-- Takeover situations (pit limiter, pit lane, flags, low fuel) use the catalogue scenarios' own tests.
-- Refresh: at most S.displayHz paints per second and only when something drawn changed (a number fingerprint of
-- every value on the page), so a standing car is not repainted at all.
--
-- UNSURE (needs the game): which texture slot a display uses (txDiffuse by default, txEmissive selectable); whether
-- the callback's coordinates are relative to the region (assumed, as the licence plate code draws at 0, 0); whether
-- a copy's cloned material keeps receiving the display script's texture (the copy's slot is replaced, so it should
-- not matter); how expensive a paint is.

local csp = require('src/csp')
local ac, vec2, vec3, rgbm = csp.ac, csp.vec2, csp.vec3, csp.rgbm
local config = require('src/config')
local engine = require('src/engine')
local presets = require('src/presets')
local scenarios = require('src/scenarios')
local pages = require('src/display_pages')
local rpm = require('src/rpm')

local S = config.S
local M = {
  displays = {},      -- found on this car: { name, section, meshes (string), res, pos, size, label }
  taken = {},         -- index -> { copies = { refs }, origs = { refs } }
  nTaken = 0,
  paints = 0,         -- paints since load (diagnostics, tests)
  version = 0,
  error = nil,        -- last error (Czech), the takeover is off after it
  data = nil,         -- what the last paint showed (the tab's preview draws it too)
  page = 1,
}

local VIRTUAL_N = 12
local SLOTS = { 'txDiffuse', 'txEmissive' }
M.SLOTS = SLOTS

local profile, carId, saveFn = nil, '', nil
local function save() if saveFn then pcall(saveFn) end end
M.save = save
local function bump() M.version = M.version + 1 end

-- ---------------------------------------------------------------- settings (per car: profile.display)

local function cfg()
  if not profile then return { on = false } end
  if type(profile.display) ~= 'table' then profile.display = { on = false } end
  return profile.display
end
M.cfg = cfg

-- ---------------------------------------------------------------- finding displays

local function first(v) if type(v) == 'table' then return v[1] end return v end
local function vecOf(v, dx, dy)
  if type(v) == 'table' then
    local x, y = tonumber(v[1]), tonumber(v[2])
    if x and y then return vec2(x, y) end
    local s = tostring(v[1] or '')
    x, y = s:match('^%s*([%d%.]+)%s*,%s*([%d%.]+)')
    if x then return vec2(tonumber(x), tonumber(y)) end
  end
  return vec2(dx, dy)
end

-- Displays of the car from its CSP config (info.cspConfig from car_info), sorted by section name.
function M.find(info)
  local out = {}
  local cfgIni = info and info.cspConfig
  local sections = cfgIni and cfgIni.sections
  if type(sections) ~= 'table' then return out end
  for name, keys in pairs(sections) do
    if type(name) == 'string' and name:match('^SCRIPTABLE_DISPLAY') and type(keys) == 'table' then
      local meshes = keys.MESHES
      local list = {}
      if type(meshes) == 'table' then
        for i = 1, #meshes do
          for part in tostring(meshes[i]):gmatch('[^,]+') do
            part = part:gsub('^%s+', ''):gsub('%s+$', '')
            if part ~= '' then list[#list + 1] = part end
          end
        end
      end
      if #list > 0 then
        local res = vecOf(keys.RESOLUTION, 1024, 1024)
        local pos = vecOf(keys.DISPLAY_POS, 0, 0)
        local size = vecOf(keys.DISPLAY_SIZE, res.x - pos.x, res.y - pos.y)
        out[#out + 1] = { section = name, meshes = list, res = res, pos = pos, size = size }
      end
    end
  end
  table.sort(out, function (a, b) return a.section < b.section end)
  for i = 1, #out do
    local d = out[i]
    d.label = string.format('Displej %d – %s (%d × %d)', i, table.concat(d.meshes, ', '), math.floor(d.size.x),
      math.floor(d.size.y))
  end
  return out
end

-- ---------------------------------------------------------------- self-heal marker

local guardWritten = false        -- only the run that wrote the marker clears it (a restart must not lose it)
local function writeGuard()
  guardWritten = true
  local parts = { carId }
  for i in pairs(M.taken) do
    for _, n in ipairs(M.displays[i].meshes) do parts[#parts + 1] = n end
  end
  config.set('displayGuard', #parts > 1 and table.concat(parts, '|') or '')
end

-- Originals an earlier run left hidden (crash without ac.onRelease) are shown again.
function M.heal(currentCarId)
  local g = S.displayGuard or ''
  if g == '' then return 0 end
  local parts = {}
  for p in g:gmatch('[^|]+') do parts[#parts + 1] = p end
  local n = 0
  if parts[1] == currentCarId then
    local root = ac.findNodes('carRoot:0')
    for i = 2, #parts do
      local ok, ref = pcall(root.findMeshes, root, parts[i])
      if ok and ref and #ref > 0 then ref:setVisible(true); n = n + #ref end
    end
  end
  config.set('displayGuard', '')
  return n
end

-- ---------------------------------------------------------------- takeover of one display

local BLACK = rgbm(0, 0, 0, 1)

-- Two ways per mesh: a shadow copy (the original hidden) when the game gives the mesh's vertices, else painting the
-- original itself ("direct": its material is made its own with ensureUniqueMaterials, the texture filename of the
-- slot is kept and set back on release; getVertices returns nil for meshes without CPU data, as the SDK says).
-- UNSURE: whether a scriptable display's own texture comes back from its filename (a dynamic one may start with '$').
local RESTORE = { textureSize = nil, background = nil, callback = function () end }
local function release(i)
  local t = M.taken[i]
  if not t then return end
  for k = 1, #t.copies do pcall(t.copies[k].dispose, t.copies[k]) end
  for k = 1, #t.origs do pcall(t.origs[k].setVisible, t.origs[k], true) end
  for k = 1, #t.direct do
    local e = t.direct[k]
    local ok = false
    if e.file and e.file ~= '' then ok = pcall(e.ref.setMaterialTexture, e.ref, e.slot, e.file) end
    if not ok then
      -- no filename (or it failed): one paint with nothing drawn and the original texture as the background
      -- ("background = nil reuses original texture", SDK lib_scene) - UNSURE whether that brings it back
      RESTORE.textureSize = t.params and t.params.textureSize or M.displays[i].res
      ok = pcall(e.ref.setMaterialTexture, e.ref, e.slot, RESTORE)
      M.lastRestore = ok and 'prázdné překreslení s původním pozadím' or 'nepodařilo se'
    else
      M.lastRestore = 'textura ' .. tostring(e.file)
    end
  end
  -- the original's own glow back (only meshes painted directly: copies are disposed)
  if t.glowBase and t.glowNow ~= 1 then
    for k = 1, #t.targets do
      local b = t.glowBase[k]
      if b and t.isDirect[k] then pcall(t.targets[k].setMaterialProperty, t.targets[k], 'ksEmissive', b) end
    end
  end
  M.taken[i] = nil
  M.nTaken = M.nTaken - 1
end

local function slotName()
  local s = cfg().slot
  for i = 1, #SLOTS do if SLOTS[i] == s then return s end end
  return SLOTS[1]
end

local function take(i)
  local d = M.displays[i]
  local root = ac.findNodes('carRoot:0')
  local slot = slotName()
  local t = { copies = {}, origs = {}, direct = {}, targets = {}, isDirect = {}, params = nil, mode = '' }
  for _, name in ipairs(d.meshes) do
    local ref = root:findMeshes(name)
    for k = 1, #ref do
      local one = ref:at(k)
      local okV, v = pcall(one.getVertices, one)
      local okI, ix = pcall(one.getIndices, one)
      local copy = nil
      if okV and okI and v and ix then
        local okC, c = pcall(one:getParent().createMesh, one:getParent(),
          string.format('__ledcontrol_disp_%d_%d', i, #t.copies + 1), nil, v, ix, false, true)
        if okC and c and #c > 0 then copy = c end
      end
      if copy then
        t.copies[#t.copies + 1] = copy
        copy:assignMaterialFrom(one)
        copy:ensureUniqueMaterials()
        t.origs[#t.origs + 1] = one
        t.targets[#t.targets + 1] = copy
      else
        local okF, file = pcall(one.getTextureSlotFilename, one, 1, slot)
        one:ensureUniqueMaterials()
        t.direct[#t.direct + 1] = { ref = one, slot = slot, file = okF and file or nil }
        t.targets[#t.targets + 1] = one
        t.isDirect[#t.targets] = true
      end
    end
  end
  -- the material's own glow (ksEmissive), scaled by the Svit setting; written only when the factor changes
  t.glowBase, t.glowNow = {}, -1
  for k = 1, #t.targets do
    local ref = t.targets[k]
    local ok, v = pcall(ref.getMaterialPropertyValue, ref, 1, 'ksEmissive')
    if ok and v ~= nil and type(v) ~= 'number' then
      t.glowBase[k] = vec3(v.x or v.r or 0, v.y or v.g or 0, v.z or v.b or 0)
    end
  end
  if #t.targets == 0 then error('mesh displeje nenalezen (' .. table.concat(d.meshes, ', ') .. ')') end
  t.mode = #t.direct == 0 and 'copy' or (#t.copies == 0 and 'direct' or 'mixed')
  -- hidden only once every copy exists; the marker is written before hiding
  M.taken[i] = t
  M.nTaken = M.nTaken + 1
  if #t.origs > 0 then writeGuard() end
  for k = 1, #t.origs do t.origs[k]:setVisible(false) end
  -- the parameters of the paint call, reused (the callback reads the display being painted from `painting`)
  t.params = { textureSize = d.res, background = BLACK, region = { from = vec2(), size = vec2() }, callback = nil }
  M.applyRegion(i)
end

-- Region of display i with the user's correction (profile.display.adjust[i] = { x, y, w, h } in texture pixels).
function M.regionOf(i)
  local d = M.displays[i]
  local a = cfg().adjust and cfg().adjust[i]
  local x, y, w, h = d.pos.x, d.pos.y, d.size.x, d.size.y
  if type(a) == 'table' then
    x, y = x + (tonumber(a[1]) or 0), y + (tonumber(a[2]) or 0)
    w, h = math.max(16, w + (tonumber(a[3]) or 0)), math.max(16, h + (tonumber(a[4]) or 0))
  end
  return x, y, w, h
end

function M.applyRegion(i)
  local t = M.taken[i]
  if not t then return end
  local x, y, w, h = M.regionOf(i)
  t.params.region.from.x, t.params.region.from.y = x, y
  t.params.region.size.x, t.params.region.size.y = w, h
  t.w, t.h = w, h
end

-- How display i is taken ('copy', 'direct', 'mixed' or nil) for the tab.
function M.modeOf(i) return M.taken[i] and M.taken[i].mode or nil end

-- Settings that change how a display is taken (texture slot): give it back and take it again.
function M.retake()
  for i in pairs(M.taken) do release(i) end
  M.invalidate()
  bump()
end

function M.releaseAll()
  for i in pairs(M.taken) do release(i) end
  M.taken, M.nTaken = {}, 0
  if guardWritten then config.set('displayGuard', ''); guardWritten = false end
  bump()
end

-- ---------------------------------------------------------------- the values on the page

-- virtual LED row: one main group of 12 cells, compiled from the car's preset like the real LEDs
local VLAYOUT = nil
local function buildLayout(n)
  VIRTUAL_N = n
  VLAYOUT = { leds = {}, groups = { { name = 'Displej', role = 'main', leds = {} } }, signature = 'display' .. n }
  for k = 1, n do
    VLAYOUT.leds[k] = { name = 'display_' .. k, group = 1, inst = {} }
    VLAYOUT.groups[1].leds[k] = k
  end
end
buildLayout(VIRTUAL_N)
local compiled, compiledFor, compiledVersion, compiledRpm = nil, nil, -1, -1

local D = { gear = '', speed = '', rpm = '', lap = '', last = '', best = '', fuel = '', pos = '', laps = '', delta = '',
  deltaSign = 0, cells = {}, nCells = VIRTUAL_N, overlay = nil, overlaySub = '', blink = true, speedUnit = 'km/h' }
M.data = D

-- strings per field and value: made once per value seen (RPM steps of 10, speeds, tenths of a lap time come back),
-- a table is cleared when it grows large
local cache = {}
local function cached(key, value, fmt)
  local c = cache[key]
  if not c then c = { n = 0, map = {} }; cache[key] = c end
  local s = c.map[value]
  if not s then
    if c.n > 3000 then c.map, c.n = {}, 0 end
    s = fmt(value)
    c.map[value], c.n = s, c.n + 1
  end
  return s
end
local function fmtInt(v) return tostring(v) end
local function fmtGear(g) return g < 0 and 'R' or (g == 0 and 'N' or tostring(g)) end
local function fmtTime(t)
  if t <= 0 then return '–:––.–' end
  local m = math.floor(t / 600)
  local s = (t - m * 600) / 10
  return string.format('%d:%04.1f', m, s)
end
local function fmtFuel(f) return string.format('%.1f l', f / 10) end
local function fmtPos(p) return p > 0 and ('P' .. p) or '' end
local function fmtLaps(l) return 'Kolo ' .. l end
local function fmtDelta(d)
  if d == 0 then return '±0.00' end
  return string.format('%+.2f', d / 100)
end
local function fmtSpeedSub(v) return v .. ' km/h' end

local fp = 0
local function mix(v)
  fp = (fp * 33 + math.floor(v)) % 2147483629
end

local function overlayGroupOn(group)
  if group == 'pit' then return S.displayPit ~= false end
  if group == 'flags' then return S.displayFlags ~= false end
  if group == 'fuel' then return S.displayFuel ~= false end
  return true
end

-- the active takeover situation (first in OVERLAYS order) or nil
local function currentOverlay(ST, preset)
  local list = pages.OVERLAYS
  if M.forced then
    for i = 1, #list do if list[i].scenario == M.forced then return list[i], i end end
  end
  for i = 1, #list do
    local o = list[i]
    if overlayGroupOn(o.group) then
      local d = scenarios.byId[o.scenario]
      if d and d.test then
        local param = d.param and d.param.default or 0
        local ok, on = pcall(d.test, ST, param)
        if ok and on then return o, i end
      end
    end
  end
  return nil, 0
end

-- Fills D from the car state and returns its fingerprint.
-- ---------------------------------------------------------------- style (tab Displej settings, global)

local function packed(hex, default)
  local h = type(hex) == 'string' and hex:match('^#?(%x%x%x%x%x%x)$')
  return h and tonumber(h, 16) or default
end

local styleVersion = 0
local appliedNight = 1

-- 1 by day; S.displayNight % at night when switched on (sim time before 6:00 or from 20:00)
local stClock = nil
function M.nightFactor()
  if S.displayNightOn ~= true then return 1 end
  local h = stClock and stClock.timeHours or 12
  if h < 6 or h >= 20 then return math.max(0.05, math.min(1, (tonumber(S.displayNight) or 50) / 100)) end
  return 1
end
-- Reads the design settings from S into display_pages (theme or own colours, font, rounding, brightness, LED row,
-- zones of the page Vlastní, units) and makes the next paint happen.
function M.applyStyle()
  local st = {}
  local th = pages.THEMES[tonumber(S.displayTheme) or 1]
  local own = {}
  for part in tostring(S.displayColours or ''):gmatch('[^,]+') do own[#own + 1] = part end
  for k, key in ipairs(pages.COLOUR_KEYS) do
    local base = (th or pages.THEMES[1])[key]
    st[key] = th and base or packed(own[k], base)
  end
  local f = pages.FONTS[tonumber(S.displayFont) or 1] or pages.FONTS[1]
  if f.font ~= pages.style.font then pages.clearWidths() end
  st.font = f.font
  st.rounding = math.max(0, math.min(1, (tonumber(S.displayRounding) or 0) / 100))
  st.brightness = math.max(0.2, math.min(1, (tonumber(S.displayBrightness) or 100) / 100))
  st.cells = S.displayCellsOn ~= false
  st.cellH = math.max(0.4, math.min(2, (tonumber(S.displayCellH) or 100) / 100))
  st.cellGap = math.max(0, math.min(0.05, (tonumber(S.displayCellGap) or 8) / 1000))
  local zones = {}
  for part in tostring(S.displayZones or ''):gmatch('[^,]+') do
    if pages.FIELD_BY_ID[part] then zones[#zones + 1] = part end
  end
  for k = #zones + 1, #pages.DEFAULT_ZONES do zones[k] = pages.DEFAULT_ZONES[k] end
  st.zones = zones
  st.textScale = math.max(0.5, math.min(1.6, (tonumber(S.displayTextScale) or 100) / 100))
  st.margin = math.max(0, math.min(0.12, (tonumber(S.displayMargin) or 3) / 100))
  local night = M.nightFactor()
  st.brightness = st.brightness * night
  pages.setStyle(st)
  appliedNight = night
  local n = math.max(4, math.min(24, math.floor(tonumber(S.displayCells) or 12)))
  if n ~= VIRTUAL_N then
    buildLayout(n)
    for k = n + 1, #D.cells do D.cells[k] = nil end
    compiledFor = nil
  end
  D.nCells = VIRTUAL_N
  D.speedUnit = (tonumber(S.displayUnits) or 1) == 2 and 'mph' or 'km/h'
  styleVersion = styleVersion + 1
  M.invalidate()
end

-- A design setting changed in the tab: saved and applied.
function M.setSetting(key, value)
  config.set(key, value)
  M.applyStyle()
  bump()
end

local function fill(ST, preset, t)
  stClock = ST
  if M.nightFactor() ~= appliedNight then M.applyStyle() end
  -- LED row
  if compiledFor ~= preset or compiledVersion ~= presets.version or compiledRpm ~= rpm.version then
    compiled = engine.compile(preset, VLAYOUT, ST)
    compiledFor, compiledVersion, compiledRpm = preset, presets.version, rpm.version
  end
  engine.step(compiled, ST, D.cells)
  fp = 0
  for k = 1, VIRTUAL_N do mix(D.cells[k] + 3) end
  local gear = math.floor(ST.gear or 0)
  local speed = math.floor((ST.speed or 0) * ((tonumber(S.displayUnits) or 1) == 2 and 0.621371 or 1) + 0.5)
  local rpm = math.floor((ST.rpm or 0) / 10 + 0.5) * 10
  local lapT = math.floor((ST.lapTimeMs or 0) / 100)
  local lastT = math.floor((ST.lastLapMs or 0) / 100)
  local bestT = math.floor((ST.bestLapMs or 0) / 100)
  local fuel = math.floor((ST.fuel or 0) * 10 + 0.5)
  local pos = math.floor(ST.position or 0)
  local lap = math.floor(ST.lap or 0) + 1
  local delta = math.floor((ST.delta or 0) * 100 + 0.5)
  -- the fingerprint holds only what the current page shows, so a value it does not show causes no repaint
  D.gear = cached('gear', gear, fmtGear)
  D.speed = cached('speed', speed, fmtInt)
  D.rpm = cached('rpm', rpm, fmtInt)
  D.lap = cached('lap', lapT, fmtTime)
  D.last = cached('last', lastT, fmtTime)
  D.best = cached('best', bestT, fmtTime)
  D.fuel = cached('fuel', fuel, fmtFuel)
  D.pos = cached('pos', pos, fmtPos)
  D.laps = cached('laps', lap, fmtLaps)
  D.delta = cached('delta', delta, fmtDelta)
  D.deltaSign = delta < 0 and -1 or (delta > 0 and 1 or 0)
  local o, oi = currentOverlay(ST, preset)
  D.overlay = o
  mix(oi)
  if o and not o.banner then
    fp = 0                                    -- a full screen takeover hides the page and its LED row
    mix(oi)
    if o.sub == 'speed' then mix(speed) end
  else
    local id = (pages.PAGES[M.page] or pages.PAGES[1]).id
    if id == 'race' then mix(gear + 2); mix(speed); mix(lapT); mix(lastT); mix(fuel); mix(pos); mix(delta + 100000)
    elseif id == 'revs' then mix(rpm); mix(gear + 2)
    elseif id == 'laps' then mix(lapT); mix(lastT); mix(bestT); mix(pos); mix(lap)
    else                                      -- Vlastní: any field may be on it
      mix(gear + 2); mix(speed); mix(rpm); mix(lapT); mix(lastT); mix(bestT); mix(fuel); mix(pos); mix(lap)
      mix(delta + 100000)
    end
    if o then mix(fuel) end                   -- the fuel banner
  end
  D.overlaySub = ''
  if o then
    if o.sub == 'speed' then D.overlaySub = cached('subSpeed', speed, fmtSpeedSub)
    elseif o.sub == 'fuel' then D.overlaySub = D.fuel end
    D.blink = not o.blink or (t * o.blink) % 1 < 0.5
    mix(D.blink and 1 or 0)
  else
    D.blink = true
  end
  mix(M.page)
  mix(styleVersion)
  return fp
end

-- ---------------------------------------------------------------- painting

local painting = nil           -- the display being painted (read by the callback)
local function paintCallback()
  local t = M.taken[painting]
  pages.origin(0, 0, 1)
  pages.draw(M.page, t.w, t.h, D)
end

-- glow factor of the display now (Svit x night)
local GLOW = vec3()
local function glowFactor()
  return math.max(0, math.min(4, (tonumber(S.displayGlow) or 100) / 100)) * M.nightFactor()
end
local function applyGlow(t)
  local k = glowFactor()
  if k == t.glowNow then return end
  t.glowNow = k
  for q = 1, #t.targets do
    local b = t.glowBase[q]
    if b then
      GLOW.x, GLOW.y, GLOW.z = b.x * k, b.y * k, b.z * k
      t.targets[q]:setMaterialProperty('ksEmissive', GLOW)
    end
  end
end
-- true when the display's material glows on its own (Svit has an effect)
function M.glows(i)
  local t = M.taken[i]
  if not t then return nil end
  for q = 1, #t.targets do
    local b = t.glowBase[q]
    if b and (b.x > 0.001 or b.y > 0.001 or b.z > 0.001) then return true end
  end
  return false
end

local function paint(i)
  local t = M.taken[i]
  t.params.callback = paintCallback
  painting = i
  local slot = slotName()
  for k = 1, #t.targets do t.targets[k]:setMaterialTexture(slot, t.params) end
  painting = nil
  M.paints = M.paints + 1
end

-- ---------------------------------------------------------------- lifecycle

-- On every car detection (runtime.detectCar): the car's displays and its settings.
function M.init(prof, info, id, saveProfile)
  M.releaseAll()
  profile, carId, saveFn = prof, id or '', saveProfile
  M.error = nil
  local ok, list = pcall(M.find, info)
  M.displays = ok and list or {}
  local c = cfg()
  M.page = math.max(1, math.min(#pages.PAGES, math.floor(tonumber(c.page) or 1)))
  compiledFor = nil
  M.applyStyle()
  bump()
end

local timer, lastFp, t = 0, -1, 0

-- true when display i should be taken now
local function wanted(i)
  local c = cfg()
  if not c.on or M.error then return false end
  local which = c.which
  if type(which) == 'table' then return which[i] == true end
  return i == 1
end

-- Every frame while the master switch is on (runtime). dt: frame time, preset: the car's preset.
function M.update(dt, ST, preset)
  t = t + dt
  for i = 1, #M.displays do
    local want = wanted(i)
    if want and not M.taken[i] then
      local ok, err = pcall(take, i)
      if not ok then
        release(i)
        M.error = 'Displej nejde převzít: ' .. tostring(err)
        writeGuard()
      end
      lastFp = -1
      bump()
    elseif not want and M.taken[i] then
      release(i)
      writeGuard()
      bump()
    end
  end
  if M.nTaken == 0 then return end        -- nothing taken: nothing to fill (the tab's preview fills on its own)
  timer = timer + dt
  local hz = math.max(1, math.min(60, tonumber(S.displayHz) or 20))
  if timer < 1 / hz then return end
  timer = 0
  local f = fill(ST, preset, t)
  for i in pairs(M.taken) do pcall(applyGlow, M.taken[i]) end
  if f == lastFp then return end       -- nothing on the page changed: no paint
  lastFp = f
  for i in pairs(M.taken) do
    local ok, err = pcall(paint, i)
    if not ok then
      M.error = 'Kreslení na displej selhalo: ' .. tostring(err)
      M.releaseAll()
      return
    end
  end
end

-- The tab shows a preview while no display is taken: values without painting.
function M.preview(dt, ST, preset)
  if M.nTaken > 0 then return end
  timer = timer + dt
  if timer < 0.1 then return end
  timer = 0
  t = t + 0.1
  fill(ST, preset, t)
end

function M.setPage(p)
  M.page = math.max(1, math.min(#pages.PAGES, p))
  cfg().page = M.page
  save()
  lastFp = -1
  bump()
end

function M.nextPage() M.setPage(M.page % #pages.PAGES + 1) end

-- A forced repaint (settings changed).
function M.invalidate() lastFp = -1 end

-- Self-test (src/selftest.lua): forces an overlay (or nil = live) and a page.
M.forced = nil

return M
