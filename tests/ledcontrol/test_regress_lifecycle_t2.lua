-- LedControl lights (tab Světla): detection of what the car has, real controls with confirmation, minimum interval
-- and driver override, restore on scenario end / master off / error boundary / session restart, rain light in both
-- modes, brake light copies, backlight (cabin light source + dash meshes), flash on the hotkey, priorities, Test,
-- self-heal of hidden meshes, online banner and block, persistence, no allocation with the tab open.

local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame = H.frame
local U = env.ui

-- ---------------------------------------------------------------- mock extensions (this file only)

-- CSP flag filter for brake lights ('{ actsAsBrakeLights:yes & lod:A }', Radar.lua)
local refmt = getmetatable(env.ref({})).__index
local baseFind = refmt.findMeshes
local function walk(obj, fn)
  if obj.kind == 'mesh' then fn(obj) return end
  for i = 1, #obj.children do walk(obj.children[i], fn) end
end
function refmt:findMeshes(filter)
  if type(filter) == 'string' and filter:find('actsAsBrakeLights:yes', 1, true) then
    local lodA = filter:find('lod:A', 1, true) ~= nil
    local out, seenM = {}, {}
    for i = 1, #self do
      walk(self[i], function (m)
        if not seenM[m] and not m.disposed and m.actsAsBrakeLights and (not lodA or m.lod == 'A') then
          seenM[m] = true
          out[#out + 1] = m
        end
      end)
    end
    return env.ref(out)
  end
  return baseFind(self, filter)
end

-- AC's light controls: commands are logged and take effect in the next frame (as AC applies them in its update)
-- lag: frames until AC shows a command (0 = the next frame)
local A = { queue = {}, due = {}, qn = 0, lag = 0, log = {}, flashes = {}, flashFrames = 0, ignore = {}, made = 0,
  alive = 0, last = nil }
local function queue(f) A.qn = A.qn + 1; A.queue[A.qn] = f; A.due[A.qn] = env.frameNo + 1 + A.lag end
local function logCmd(name, value) A.log[#A.log + 1] = { name = name, value = value, t = env.clock } end
ac.setHeadlights = function (on)
  logCmd('headlights', on)
  queue(function () env.car.headlightsActive = on end)
end
ac.setHighBeams = function (on)
  logCmd('highBeams', on)
  queue(function () env.car.lowBeams = not on end)
end
ac.TurningLights = { None = 0, Left = 1, Right = 2, Hazards = 3 }
ac.setTurningLights = function (v)
  logCmd('turn', v)
  queue(function ()
    local c = env.car
    c.hazardLights, c.turningLeftOnly, c.turningRightOnly = v == 3, v == 1, v == 2
  end)
end
ac.isExtraSwitchAvailable = function (i) return env.extras ~= nil and env.extras[i] ~= nil end
ac.getExtraSwitchName = function (i) return env.extras and env.extras[i] and env.extras[i].name or nil end
ac.accessExtraSwitchParams = function (i) return env.extras and env.extras[i] and env.extras[i].params or nil end
ac.simulateCustomHotkeyPress = function (id)
  logCmd(id, true)
  queue(function ()
    local L = id:match('^__EXT_LIGHT_(%u)$')
    if L and not A.ignore[L] then env.car['extra' .. L] = not env.car['extra' .. L] end
  end)
end
local controlsT = { headlightsFlash = false }
ac.overrideCarControls = function () return controlsT end
ac.LightType = { Regular = 1 }
ac.LightSource = function (t)
  A.made, A.alive = A.made + 1, A.alive + 1
  local l = { lightType = t, position = vec3(), color = rgb(), range = 0, disposed = false }
  l.dispose = function (self)
    if not self.disposed then self.disposed = true; A.alive = A.alive - 1 end
  end
  A.last = l
  return l
end
ac.INIConfig.onlineExtras = function () return env.onlineExtras end

local baseStep = env.acStep
env.acStep = function ()
  local q, due, keep = A.queue, A.due, 0
  for i = 1, A.qn do
    if due[i] <= env.frameNo then q[i]()
    else keep = keep + 1; q[keep], due[keep] = q[i], due[i] end
  end
  for i = keep + 1, A.qn do q[i], due[i] = nil, nil end
  A.qn = keep
  if controlsT.headlightsFlash then
    controlsT.headlightsFlash = false
    A.flashes[#A.flashes + 1] = env.clock
    A.flashFrames = 8
  end
  if A.flashFrames > 0 then A.flashFrames = A.flashFrames - 1 end
  env.car.flashingLightsActive = A.flashFrames > 0
  -- AC lights the brake light meshes while braking
  local lit = env.car.brake > 0.05
  for i = 1, #(env.brakeMats or {}) do
    local e = env.brakeMats[i].ksEmissive
    e.r, e.g, e.b = lit and 30 or 0, 0, 0
  end
  baseStep()
end

-- remembers the colour object each colour button edits (to see that the tab keeps it between frames)
local baseColorButton = ui.colorButton
U.colourSeen = {}
ui.colorButton = function (label, c, flags, size)
  U.colourSeen[label] = c
  return baseColorButton(label, c, flags, size)
end

ui.inputText = function (label, str)
  U.last = label
  local v = U.input and U.input[label]
  if v ~= nil then U.input[label] = nil; return v, true end
  return str, false
end

-- ---------------------------------------------------------------- test car

local function lightCar(opts)
  opts = opts or {}
  local c = env.car
  c.headlightsActive, c.lowBeams, c.hazardLights = false, true, false
  c.hasLowBeams = opts.lowBeams ~= false
  c.hasFlashingLights = opts.flash ~= false
  c.hasTurningLights = opts.turning ~= false
  c.headlightsAreHeadlights = opts.headlights ~= false
  c.flashingLightsActive, c.brakeLightsActive, c.turningLeftOnly, c.turningRightOnly = false, false, false, false
  for _, L in ipairs({ 'A', 'B', 'C', 'D', 'E', 'F' }) do c['extra' .. L] = false end
  env.extras = opts.extras or { [2] = { name = 'Rain light', params = { holdMode = false } },
    [4] = { name = 'Horn light', params = { holdMode = true } } }
  local body = env.node('BODY', env.root, 0, 0.6, -2)
  env.brakeMats = {}
  if opts.brake ~= false then
    for k, x in ipairs({ 0.6, -0.6 }) do
      local mat = env.material('brake_' .. k)
      local m = env.mesh(k == 1 and 'BRAKE_L' or 'BRAKE_R', body, { centre = { x, 0, -0.1 }, radius = 0.15, material = mat })
      m.actsAsBrakeLights = true
      env.brakeMats[k] = mat
      env['brake' .. k] = m
    end
  end
  env.rainMesh = env.mesh('RAIN_LIGHT', body, { centre = { 0, 0.2, -0.2 }, radius = 0.05 })
  env.dashMesh = env.mesh('DASH_GLOW', env.node('DASH', env.root, 0, 0.6, 0.5), { centre = { 0, 0, 0 }, radius = 0.12 })
  env.sim.timeHours = 14
end

local app, L, rt
-- crash = true: the script starts again without ac.onRelease (CSP calls it on a normal reload)
local function loadApp(crash)
  if app and not crash and env.callbacks.release then env.callbacks.release() end
  app = H.loadApp()
  L = require('src/lights')
  rt = app.runtime
  return app
end

local function count(name, from)
  local n = 0
  for i = from or 1, #A.log do if A.log[i].name == name then n = n + 1 end end
  return n
end
local function lastOf(name)
  for i = #A.log, 1, -1 do if A.log[i].name == name then return A.log[i] end end
  return nil
end
local function minGap(name, from)
  local prev, gap = nil, math.huge
  for i = from or 1, #A.log do
    local e = A.log[i]
    if e.name == name then
      if prev then gap = math.min(gap, e.t - prev) end
      prev = e.t
    end
  end
  return gap
end
local function itemOf(id)
  for i = 1, #L.items do if L.items[i].id == id then return L.items[i] end end
  return nil
end
local function seconds(s) frame(math.floor(s * 60 + 0.5)) end
local function texts(fn)
  U.record, U.texts = true, {}
  fn()
  U.record = false
  return U.texts
end
local function hasText(list, needle)
  for i = 1, #list do if type(list[i]) == 'string' and list[i]:find(needle, 1, true) then return true end end
  return false
end
local function drawTab()
  env.windowOpen = true
  U.tab = 'Světla'
  frame(1)
end
local function clickTab(label)
  U.tab = 'Světla'
  H.click(label)
  env.windowOpen = false
end

-- ===== REVIEW T2: an error whose cause also breaks takeover.dispose -> runtime.halt aborts before lights.release
H.formulaCar(1)
env.storage = { lc_method = 3 }      -- direct method
lightCar()
env.car.speedKmh = 0
env.car.rpm = 8000
env.startMode = 5                    -- all white: every LED taken
loadApp()
frame(5)
local car = env.car
check(app.takeover.method == 3, 'direct method active')
seconds(4)                           -- standing on track: hazards on
env.sim.timeHours = 21               -- dusk: headlights on
seconds(1)
check(car.hazardLights and car.headlightsActive and L.CH.hazards.held, 'hazards + headlights held before the error')
env.failSetMaterial = true           -- the scene call that fails in update fails again in the restorer
H.mode(4)                            -- change of colour -> setMaterialProperty -> error
frame(5)
check(app.safety.halted, 'error boundary halted')
print(string.format('[T2] after halt: hazards %s held %s, headlights %s held %s, lights.running %s',
  tostring(car.hazardLights), tostring(L.CH.hazards.held), tostring(car.headlightsActive), tostring(L.CH.headlights.held),
  tostring(L.running)))
check(not L.CH.hazards.held and not car.hazardLights, 'halt: hazards given back to the driver')
check(not L.CH.headlights.held and not car.headlightsActive, 'halt: headlights given back to the driver')
-- unload while the scene call still fails: the same
env.callbacks.release()
frame(3)
print(string.format('[T2] after ac.onRelease: hazards %s held %s', tostring(car.hazardLights), tostring(L.CH.hazards.held)))
check(not L.CH.hazards.held, 'unload: hazards given back')
env.failSetMaterial = false
return H.finish('test_regress_lifecycle_t2')
