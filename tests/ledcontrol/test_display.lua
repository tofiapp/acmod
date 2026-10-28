-- Display takeover (src/display.lua, src/display_pages.lua) on the fake canvas:
--   * every page and every takeover screen at 800 x 480, 480 x 272 and 512 x 512: no rectangle or text outside the
--     screen, no text wider than its box (mock font metric), commands dumped to tests/output/display for the PNG
--     previews (tools/render_display.py, run by run_tests.py);
--   * the takeover: original hidden, a copy painted, scenarios (pit limiter, flags, low fuel) take the screen,
--     the user's LED animation shows on the display's LED row;
--   * refresh: never more paints per second than set, no paint while nothing changes, no identical repaint;
--   * two displays, master off / error / crash restore.
-- Not provable here: whether the game shows the painted texture on the display (slot, region coordinates), the
-- real font widths (Bahnschrift in the game, DejaVu in the previews) and the cost of a paint.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
local OUT = appDir .. '/../../../tests/output/display'
os.execute('mkdir -p "' .. OUT .. '"')

local function seconds(s) frame(math.floor(s * 60 + 0.5)) end

-- ---------------------------------------------------------------- layouts on the fake canvas

H.displayCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
local pages = require('src/display_pages')

local SIZES = { { 800, 480 }, { 480, 272 }, { 512, 512 } }
-- long, realistic values (the widest each field gets)
local DATA = { gear = 'N', speed = '312', speedUnit = 'km/h', rpm = '18450', lap = '12:59.9', last = '1:23.4', best = '1:22.9', fuel = '105.3 l',
  pos = 'P12', laps = 'Kolo 123', delta = '+12.34', deltaSign = 1, cells = {}, nCells = 12, overlay = nil, overlaySub = '',
  blink = true }
local SHIFT = { 0x00FF00, 0x00FF00, 0x00FF00, 0x00FF00, 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000, 0x0000FF, 0x0000FF, -2, -2 }
for k = 1, 12 do DATA.cells[k] = SHIFT[k] end

local function render(page, W, H, overlay, sub)
  DATA.overlay, DATA.overlaySub = overlay, sub or ''
  local cv = { n = 0, cmds = {} }
  env.recording = cv
  pages.origin(0, 0, 1)
  pages.draw(page, W, H, DATA)
  env.recording = nil
  return cv
end

local function bounds(cv, W, H, what)
  local problems = {}
  for i = 1, cv.n do
    local c = cv.cmds[i]
    local x1, y1, x2, y2 = c[2], c[3], c[4], c[5]
    if x1 < -0.5 or y1 < -0.5 or x2 > W + 0.5 or y2 > H + 0.5 then
      problems[#problems + 1] = string.format('%s outside the screen (%.0f,%.0f – %.0f,%.0f)', c[1], x1, y1, x2, y2)
    end
    if c[1] == 'text' then
      local w, size = c[14], c[11]
      if w > (x2 - x1) + 0.5 then
        problems[#problems + 1] = string.format('text "%s" %.0f px wide in a %.0f px box', c[10], w, x2 - x1)
      end
      if size * 1.2 > (y2 - y1) * 1.35 + 0.5 then
        problems[#problems + 1] = string.format('text "%s" %.0f px high in a %.0f px box', c[10], size * 1.2, y2 - y1)
      end
    end
  end
  check(#problems == 0, what .. ': ' .. (#problems == 0 and 'fits' or table.concat(problems, '; ')))
end

local function dump(cv, W, H, name)
  local f = io.open(OUT .. '/' .. name .. '.txt', 'w')
  f:write(string.format('size %d %d\n', W, H))
  for i = 1, cv.n do
    local c = cv.cmds[i]
    if c[1] == 'rect' then
      f:write(string.format('rect %.2f %.2f %.2f %.2f %.4f %.4f %.4f %.4f %.2f\n', c[2], c[3], c[4], c[5], c[6], c[7], c[8],
        c[9], c[10] or 0))
    else
      f:write(string.format('text %.2f %.2f %.2f %.2f %.4f %.4f %.4f %.4f %.2f %d %d|%s\n', c[2], c[3], c[4], c[5], c[6],
        c[7], c[8], c[9], c[11], c[12], c[13], c[10]))
    end
  end
  f:close()
end

local OVERLAY_SUB = { speed = '62 km/h', fuel = '2.1 l' }
for _, sz in ipairs(SIZES) do
  local W, H = sz[1], sz[2]
  for p = 1, #pages.PAGES do
    local cv = render(p, W, H, nil)
    local name = string.format('%s_%dx%d', pages.PAGES[p].id, W, H)
    bounds(cv, W, H, 'page ' .. name)
    check(cv.n >= 12, 'page ' .. name .. ': drawn (' .. cv.n .. ' commands)')
    dump(cv, W, H, name)
  end
  for _, o in ipairs(pages.OVERLAYS) do
    local cv = render(1, W, H, o, OVERLAY_SUB[o.sub])
    local name = string.format('takeover_%s_%dx%d', o.scenario, W, H)
    bounds(cv, W, H, name)
    local hasTitle = false
    for i = 1, cv.n do if cv.cmds[i][1] == 'text' and cv.cmds[i][10] == o.title then hasTitle = true end end
    check(hasTitle, name .. ': shows "' .. o.title .. '"')
    dump(cv, W, H, name)
  end
end

-- ---------------------------------------------------------------- takeover on the car

local display = require('src/display')
check(#display.displays == 1 and display.displays[1].size.x == 800 and display.displays[1].size.y == 480
  and display.displays[1].pos.x == 112, 'display found from [SCRIPTABLE_DISPLAY_0] (MESHES, RESOLUTION, DISPLAY_POS/SIZE)')
local rt = app.runtime
check(rt.state == 'noleds', 'the display car has no LEDs: the display works on its own')
local orig = env.displayMesh
local function copyOf()
  for _, c in ipairs(orig.parent.children) do if c.created and not c.disposed then return c end end
end
check(orig.visible and not copyOf(), 'before the takeover: the car\'s own display')
display.cfg().on = true
env.car.speedKmh, env.car.rpm, env.car.gear = 120, 9000, 3
frame(5)
local copy = copyOf()
check(copy and copy.visible and not orig.visible, 'taken: original hidden, a copy shown')
local cv = copy and copy.textures and copy.textures.txDiffuse
check(cv and cv.n > 10 and cv.size.x == 1024 and cv.region.from.x == 112 and cv.region.size.y == 480,
  'the copy\'s txDiffuse painted in the display region of the 1024 x 1024 texture')

local function lastTexts()
  local c = copyOf()
  local t = c and c.textures and c.textures.txDiffuse
  local out = {}
  if t then for i = 1, t.n do if t.cmds[i][1] == 'text' then out[t.cmds[i][10]] = true end end end
  return out
end
check(lastTexts()['3'] and lastTexts()['120'], 'the page shows the gear and the speed')

-- scenarios take the display over
env.car.isInPitlane, env.car.manualPitsSpeedLimiterEnabled, env.car.speedKmh = true, true, 60
seconds(0.3)
check(display.data.overlay and display.data.overlay.scenario == 'pitLimiter', 'pit limiter takes the display')
local seenTitle = false
for _ = 1, 30 do frame(1); if lastTexts()['PIT LIMITER'] then seenTitle = true end end
check(seenTitle, 'the display shows PIT LIMITER')
env.car.manualPitsSpeedLimiterEnabled = false
seconds(0.3)
check(display.data.overlay and display.data.overlay.scenario == 'pitLane', 'pit lane without the limiter: ZAPNI LIMITER')
env.car.isInPitlane, env.car.speedKmh = false, 150
env.sim.raceFlagType = 12
seconds(0.3)
check(display.data.overlay and display.data.overlay.scenario == 'flagBlue', 'blue flag takes the display')
env.sim.raceFlagType = 0
env.car.fuel = 2
seconds(0.3)
check(display.data.overlay and display.data.overlay.banner, 'low fuel: a banner over the page')
env.car.fuel = 50
app.config.set('displayFlags', false)
env.sim.raceFlagType = 12
seconds(0.3)
check(display.data.overlay == nil, 'flags switched off in the tab: the page stays')
env.sim.raceFlagType = 0
app.config.set('displayFlags', true)

-- the user's LED animation on the display's LED row
rt.editScenario('limiter', 'look', { p = 'solid', c = { '#00FF00' } })
env.car.rpm = env.car.rpmLimiter * 0.995
seconds(0.5)
local green = true
for k = 1, 12 do if display.data.cells[k] ~= 0x00FF00 then green = false end end
check(green, 'on the limiter the display\'s LED row shows the user\'s limiter animation (green)')

-- refresh rate and repaints
app.config.set('displayHz', 20)
display.setPage(2)                 -- Otáčky: shows the RPM, which changes every frame here
local p0 = env.paints
for f = 1, 180 do env.car.rpm = 6000 + f * 20; frame(1) end
local n = env.paints - p0
check(n <= 61 and n >= 40, string.format('changing values: %d paints in 3 s at 20 Hz', n))
display.setPage(1)                 -- Závod does not show the RPM: the same sweep below the shift lights repaints
p0 = env.paints                    -- nothing but what changes on it
for f = 1, 60 do env.car.rpm = 6000 + f * 20; frame(1) end
check(env.paints - p0 <= 2, 'RPM not on the page: no repaint for it (' .. (env.paints - p0) .. ')')
env.car.rpm, env.car.speedKmh = 5000, 0
seconds(0.5)
p0 = env.paints
seconds(2)
check(env.paints - p0 == 0, 'standing car, nothing changes: no paint (' .. (env.paints - p0) .. ')')
app.config.set('displayHz', 5)
display.setPage(2)
p0 = env.paints
for f = 1, 120 do env.car.rpm = 6000 + f * 20; frame(1) end
check(env.paints - p0 <= 11, 'at 5 Hz: at most 10 paints in 2 s (' .. (env.paints - p0) .. ')')
check(env.redundant.emissive == 0, 'no repaint of an identical picture (' .. env.redundant.emissive .. ')')

-- master off: the car's display back
app.config.set('master', false)
frame(3)
check(orig.visible and not copyOf() and app.config.S.displayGuard == '', 'master off: original shown, copy gone, marker cleared')
app.config.set('master', true)
frame(3)
check(copyOf() and not orig.visible, 'master on again: taken again')

-- an error while painting: the display is given back and the reason shown
env.paintFails = true
local base = getmetatable(env.ref({})).__index.setMaterialTexture
getmetatable(env.ref({})).__index.setMaterialTexture = function (s, slot, v)
  if env.paintFails then error('paint failed (test)') end
  return base(s, slot, v)
end
env.car.rpm = 7777
seconds(0.2)
check(display.error and display.error:find('selhalo', 1, true) and orig.visible and not copyOf(),
  'paint error: display given back, reason kept (' .. tostring(display.error) .. ')')
getmetatable(env.ref({})).__index.setMaterialTexture = base
env.paintFails = false

-- crash without ac.onRelease: the next run shows the hidden original again
display.error = nil
frame(3)
check(copyOf() and not orig.visible, 'taken again after the error is cleared')
env.reloadScene()                  -- CSP drops created meshes on a reload; the original stays hidden
app = H.loadApp()
frame(5)
-- the marker showed the original again; the display is still switched on in the car's profile, so the new run
-- takes it over again: exactly one of the two is visible
local c = copyOf()
check(app.runtime.healed >= 1 and ((c and c.visible and not orig.visible) or (not c and orig.visible)),
  'crash: the next run healed the hidden original (' .. app.runtime.healed .. ') and shows one display, not none')

-- ---------------------------------------------------------------- two displays

H.dualDisplayCar(1)
env.storage = {}
app = H.loadApp()
frame(3)
display = require('src/display')
check(#display.displays == 2, 'two displays found')
display.cfg().on = true
display.cfg().which = { true, true }
env.car.speedKmh, env.car.rpm = 100, 9000
frame(5)
local function canvasOf(mesh)
  for _, c in ipairs(mesh.parent.children) do
    if c.created and not c.disposed and c.copyOf == mesh and c.textures then return c.textures.txDiffuse end
  end
end
local c1, c2 = canvasOf(env.displayMesh), canvasOf(env.displayMesh2)
check(c1 and c2 and c1.region.size.x == 800 and c2.region.size.x == 480, 'both displays painted, each in its own size')
check(not env.displayMesh.visible and not env.displayMesh2.visible, 'both originals hidden')
check(app.runtime.state == 'run', 'the LEDs of the same car still run')
display.cfg().which = { true, false }
frame(3)
check(env.displayMesh2.visible and not env.displayMesh.visible, 'second display given back when unticked')

-- ---------------------------------------------------------------- design settings on the fake canvas

H.displayCar(1)
env.storage = {}
app = H.loadApp()
frame(3)
display = require('src/display')
pages = require('src/display_pages')
local cfgS = app.config.S
local function setAll(t)
  for k, v in pairs(t) do app.config.set(k, v) end
  display.applyStyle()
end
-- every theme, LED row extremes, rounding, no row: every page at every size inside the screen
local STYLES = {
  { name = 'theme2', set = { displayTheme = 2 } },
  { name = 'theme3', set = { displayTheme = 3, displayRounding = 100 } },
  { name = 'theme4', set = { displayTheme = 4, displayCells = 24, displayCellH = 200, displayCellGap = 50 } },
  { name = 'own', set = { displayTheme = 0, displayColours = '#202020,#00FF80,#808080,#FF00FF,#300000,#303030',
    displayCells = 4, displayCellH = 40, displayCellGap = 0, displayFont = 3 } },
  { name = 'norow', set = { displayTheme = 1, displayCellsOn = false, displayRounding = 0, displayCells = 12,
    displayCellH = 100, displayCellGap = 8, displayFont = 1 } },
}
for _, st in ipairs(STYLES) do
  setAll(st.set)
  for _, sz in ipairs(SIZES) do
    for p = 1, #pages.PAGES do
      local cv = render(p, sz[1], sz[2], nil)
      local name = string.format('%s_%s_%dx%d', st.name, pages.PAGES[p].id, sz[1], sz[2])
      bounds(cv, sz[1], sz[2], 'style ' .. name)
      if sz[1] == 800 then dump(cv, sz[1], sz[2], 'style_' .. name) end
    end
  end
end
check(pages.style.cells == false and pages.style.bg == 0x000000, 'style: settings reach the pages (row off, theme 1)')
setAll({ displayTheme = 0, displayColours = '#123456,#FFFFFF,#999999,#C080FF,#1E1E1E,#101010' })
check(pages.style.bg == 0x123456, 'own colours: background from the stored string')
setAll({ displayTheme = 1, displayCellsOn = true })
-- the page Vlastní: every field in every zone fits
for f = 1, #pages.FIELDS do
  local id = pages.FIELDS[f].id
  local z = {}
  for k = 1, #pages.ZONE_NAMES do z[k] = id end
  app.config.set('displayZones', table.concat(z, ','))
  display.applyStyle()
  for _, sz in ipairs(SIZES) do
    local cv = render(4, sz[1], sz[2], nil)
    bounds(cv, sz[1], sz[2], string.format('Vlastní with "%s" everywhere %dx%d', id, sz[1], sz[2]))
  end
end
app.config.set('displayZones', 'rpm,gear,best,delta,laps,fuel,speed')
display.applyStyle()
for _, sz in ipairs(SIZES) do
  dump(render(4, sz[1], sz[2], nil), sz[1], sz[2], string.format('custom_mix_%dx%d', sz[1], sz[2]))
end
-- the virtual LED row follows the number of cells
app.config.set('displayCells', 20)
display.applyStyle()
check(display.data.nCells == 20, 'LED row: 20 cells')
display.cfg().on = true
env.car.speedKmh, env.car.rpm = 100, 9000
frame(10)
local lit = 0
for k = 1, 20 do if display.data.cells[k] ~= nil then lit = lit + 1 end end
check(lit == 20, 'the engine fills all 20 cells of the display row (' .. lit .. ')')
-- units
app.config.set('displayUnits', 2)
display.applyStyle()
frame(10)
check(display.data.speedUnit == 'mph' and display.data.speed == '62', 'mph: 100 km/h shown as 62 mph ('
  .. tostring(display.data.speed) .. ')')
app.config.set('displayUnits', 1)
display.applyStyle()
-- region correction
display.cfg().adjust = { { 10, 20, -100, -50 } }
display.applyRegion(1)
display.invalidate()
env.car.rpm = 9100
frame(5)
local cp
for _, c in ipairs(env.displayMesh.parent.children) do if c.created and not c.disposed then cp = c end end
local cvx = cp and cp.textures and cp.textures.txDiffuse
check(cvx and cvx.region.from.x == 122 and cvx.region.from.y == 292 and cvx.region.size.x == 700
  and cvx.region.size.y == 430, 'region correction: painted at 122, 292 – 700 x 430')
local inside = true
for i = 1, cvx.n do if cvx.cmds[i][4] > 700.5 or cvx.cmds[i][5] > 430.5 then inside = false end end
check(inside, 'the page is laid out for the corrected size')
display.cfg().adjust = nil
display.applyRegion(1)
-- live edits are saved once they rest, not while dragging
app.config.setLive('displayRounding', 55)
check(env.storage['lc_displayRounding'] ~= 55 and cfgS.displayRounding == 55, 'live edit: in effect, not stored yet')
app.config.flushLive()
check(env.storage['lc_displayRounding'] == 55, 'live edit: stored after flush')

-- ---------------------------------------------------------------- no vertex data: painted directly

H.displayCar(1)
env.storage = {}
env.noVertices = { DISPLAY_SCREEN = true }
env.displayMesh.texFile = 'motec_screen.dds'
app = H.loadApp()
frame(3)
display = require('src/display')
display.cfg().on = true
env.car.speedKmh, env.car.rpm = 100, 9000
frame(10)
orig = env.displayMesh
local anyCopy = false
for _, c in ipairs(orig.parent.children) do if c.created and not c.disposed then anyCopy = true end end
check(display.error == nil and display.modeOf(1) == 'direct' and orig.visible and not anyCopy,
  'no vertex data: taken directly, no copy, original stays visible (' .. tostring(display.error) .. ')')
local tex = orig.textures and orig.textures.txDiffuse
check(type(tex) == 'table' and tex.n > 10, 'painted into the original display\'s texture')
check(app.config.S.displayGuard == '', 'direct: nothing hidden, no self-heal marker')
app.config.set('master', false)
frame(3)
check(orig.textures.txDiffuse == 'motec_screen.dds', 'master off: the original texture set back by its filename')
env.noVertices = {}

-- ---------------------------------------------------------------- the tab: drawn, no UI error, no allocation

H.displayCar(1)
env.storage = {}
app = H.loadApp()
frame(3)
display = require('src/display')
display.cfg().on = true
env.windowOpen = true
env.ui.tab = 'Displej'
env.car.speedKmh, env.car.rpm = 120, 9000
frame(30)
check(app.safety.uiError == nil, 'Displej tab drawn without an error (' .. tostring(app.safety.uiError) .. ')')
env.ui.click = 'Otáčky##dispPage2'
frame(2)
env.ui.click = nil
check(display.page == 2, 'Stránka: Otáčky picked in the tab')
local function sweep(f)
  env.car.rpm = 8000 + (f % 120) * 40
  env.car.speedKmh = 100 + (f % 60)
  frame(1)
end
for f = 1, 240 do sweep(f) end
jit.off()
collectgarbage('collect')
collectgarbage('stop')
local mem = collectgarbage('count')
for f = 1, 300 do sweep(f) end
local grown = collectgarbage('count') - mem
collectgarbage('restart')
jit.on()
check(grown < 4, string.format('no per-frame allocation with the display taken and the Displej tab open (%.2f KB / 300 frames)',
  grown))

return H.finish('test_display')
