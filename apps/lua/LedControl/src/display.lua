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
local ac, vec2, rgbm = csp.ac, csp.vec2, csp.rgbm
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

local function release(i)
  local t = M.taken[i]
  if not t then return end
  for k = 1, #t.copies do pcall(t.copies[k].dispose, t.copies[k]) end
  for k = 1, #t.origs do pcall(t.origs[k].setVisible, t.origs[k], true) end
  M.taken[i] = nil
  M.nTaken = M.nTaken - 1
end

local function take(i)
  local d = M.displays[i]
  local root = ac.findNodes('carRoot:0')
  local t = { copies = {}, origs = {}, params = nil }
  for _, name in ipairs(d.meshes) do
    local ref = root:findMeshes(name)
    for k = 1, #ref do
      local one = ref:at(k)
      local v, ix = one:getVertices(), one:getIndices()
      if not v or not ix then error('getVertices/getIndices nevrátily data (' .. name .. ')') end
      local copy = one:getParent():createMesh(string.format('__ledcontrol_disp_%d_%d', i, #t.copies + 1), nil, v, ix,
        false, true)
      if not copy or #copy == 0 then error('createMesh nevytvořil kopii displeje (' .. name .. ')') end
      t.copies[#t.copies + 1] = copy
      copy:assignMaterialFrom(one)
      copy:ensureUniqueMaterials()
      t.origs[#t.origs + 1] = one
    end
  end
  if #t.copies == 0 then error('mesh displeje nenalezen (' .. table.concat(d.meshes, ', ') .. ')') end
  -- hidden only once every copy exists; the marker is written before hiding
  M.taken[i] = t
  M.nTaken = M.nTaken + 1
  writeGuard()
  for k = 1, #t.origs do t.origs[k]:setVisible(false) end
  -- the parameters of the paint call, reused (the callback reads the display being painted from `painting`)
  t.params = { textureSize = d.res, background = BLACK, region = { from = d.pos, size = d.size }, callback = nil }
end

function M.releaseAll()
  for i in pairs(M.taken) do release(i) end
  M.taken, M.nTaken = {}, 0
  if guardWritten then config.set('displayGuard', ''); guardWritten = false end
  bump()
end

-- ---------------------------------------------------------------- the values on the page

-- virtual LED row: one main group of 12 cells, compiled from the car's preset like the real LEDs
local VLAYOUT = { leds = {}, groups = { { name = 'Displej', role = 'main', leds = {} } }, signature = 'display12' }
for k = 1, VIRTUAL_N do
  VLAYOUT.leds[k] = { name = 'display_' .. k, group = 1, inst = {} }
  VLAYOUT.groups[1].leds[k] = k
end
local compiled, compiledFor, compiledVersion, compiledRpm = nil, nil, -1, -1

local D = { gear = '', speed = '', rpm = '', lap = '', last = '', best = '', fuel = '', pos = '', laps = '', delta = '',
  deltaSign = 0, cells = {}, nCells = VIRTUAL_N, overlay = nil, overlaySub = '', blink = true }
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
local function fill(ST, preset, t)
  -- LED row
  if compiledFor ~= preset or compiledVersion ~= presets.version or compiledRpm ~= rpm.version then
    compiled = engine.compile(preset, VLAYOUT, ST)
    compiledFor, compiledVersion, compiledRpm = preset, presets.version, rpm.version
  end
  engine.step(compiled, ST, D.cells)
  fp = 0
  for k = 1, VIRTUAL_N do mix(D.cells[k] + 3) end
  local gear = math.floor(ST.gear or 0)
  local speed = math.floor((ST.speed or 0) + 0.5)
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
    else mix(lapT); mix(lastT); mix(bestT); mix(pos); mix(lap) end
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
  return fp
end

-- ---------------------------------------------------------------- painting

local painting = nil           -- the display being painted (read by the callback)
local function paintCallback()
  local d = M.displays[painting]
  pages.origin(0, 0, 1)
  pages.draw(M.page, d.size.x, d.size.y, D)
end

local function slotName()
  local s = cfg().slot
  for i = 1, #SLOTS do if SLOTS[i] == s then return s end end
  return SLOTS[1]
end

local function paint(i)
  local t = M.taken[i]
  t.params.callback = paintCallback
  painting = i
  local slot = slotName()
  for k = 1, #t.copies do t.copies[k]:setMaterialTexture(slot, t.params) end
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
