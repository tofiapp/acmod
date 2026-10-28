-- The jammer: imitates the game fighting the app over the LEDs (the "part A" bug: red on the limiter and at the shift
-- point instead of the user's animation, with every takeover method). It works on the original LED meshes of a test
-- car and writes through the mock's write log as writer 'jammer'.
--
--   local J = dofile(jammerPath)(env)
--   J.watch(meshes)           the original LED meshes (every instance, all LODs)
--   J.set{ ... }              options below; J.on = false stops it
--   J.lodSwitch(frames)       LOD B shown for `frames`, then LOD A again with its meshes shown (setVisible(true))
--   J.sessionReset()          originals shown, emissive black, the session callback fired
--
-- Options:
--   when    'always' | 'limiter' (rpm >= 98.5 % of car.rpmLimiter, as AC blinks its LEDs there)
--   after   frames to wait after J.set before it starts (the "after N frames" case)
--   phase   'before' (between AC's own LED update and script.update) | 'after' (after script.frameBegin, right
--           before rendering: the worst case, nothing of the app runs between it and the picture)
--   target  'original' (the material the mesh had at load, AC's digital instruments) | 'mesh' (the mesh's current
--           material) | 'byName' (every material in the scene with the original's material name: CSP config
--           emissive by material name would also reach a copy whose cloned material keeps the name; UNSURE)
--   reshow  true: the original meshes are set visible (AC blinking its LEDs by visibility, or a LOD system showing
--           the meshes of the active LOD; UNSURE)
--   blinkHz with reshow: visible / hidden at this rate instead of always visible
--   colour  { r, g, b } emissive it writes (default AC red 30, 0, 0)

return function (env)
  local J = { on = false, opts = {}, meshes = {}, materials = {}, startFrame = 0, lodUntil = -1, steps = 0 }

  function J.watch(meshes)
    J.meshes, J.materials = {}, {}
    for i = 1, #meshes do
      J.meshes[i] = meshes[i]
      J.materials[i] = meshes[i].material
    end
  end

  function J.set(opts)
    J.opts = opts or {}
    J.on = true
    J.startFrame = env.frameNo + (J.opts.after or 0)
  end

  local function allMaterialsNamed(name, out)
    local seen = {}
    local function walk(o)
      if o.kind == 'mesh' then
        if not o.disposed and o.material and o.material.name == name and not seen[o.material] then
          seen[o.material] = true
          out[#out + 1] = o.material
        end
        return
      end
      for i = 1, #o.children do walk(o.children[i]) end
    end
    walk(env.root)
    return out
  end

  local function active()
    if not J.on or env.frameNo < J.startFrame then return false end
    if J.opts.when == 'limiter' then
      local car = env.car
      return car.rpm >= car.rpmLimiter * 0.985
    end
    return true
  end

  local function jam()
    local o = J.opts
    local c = o.colour or { 30, 0, 0 }
    J.steps = J.steps + 1
    local show = true
    if o.blinkHz then show = (env.clock * o.blinkHz) % 1 < 0.5 end
    for i = 1, #J.meshes do
      local m = J.meshes[i]
      if not m.disposed then
        if o.reshow and m.visible ~= show then env.writeVisible(m, show, 'jammer') end
        local target = o.target or 'original'
        if target == 'byName' then
          local list = allMaterialsNamed(J.materials[i].name, {})
          for k = 1, #list do env.writeEmissive(list[k], c[1], c[2], c[3], 'jammer') end
        else
          env.writeEmissive(target == 'mesh' and m.material or J.materials[i], c[1], c[2], c[3], 'jammer')
        end
      end
    end
  end

  -- called by helpers.frame with 'before' / 'after'
  function J.step(phase)
    if J.lodUntil >= 0 and phase == 'before' and env.frameNo >= J.lodUntil then
      J.lodUntil = -1
      J.lodBack()
    end
    if (J.opts.phase or 'before') == phase and active() then jam() end
  end

  -- LOD switch: the cockpit's LOD A nodes go inactive and LOD B active; after `frames` it switches back and, as a LOD
  -- system would, shows the meshes of LOD A again.
  J.lodNodes = { a = {}, b = {} }
  function J.lodSwitch(frames)
    local function walk(o)
      if o.kind == 'node' then
        if o.name == 'LOD_B' then J.lodNodes.b[#J.lodNodes.b + 1] = o end
        if o.name == 'COCKPIT_HR' then J.lodNodes.a[#J.lodNodes.a + 1] = o end
        for i = 1, #o.children do walk(o.children[i]) end
      end
    end
    J.lodNodes = { a = {}, b = {} }
    walk(env.root)
    for _, n in ipairs(J.lodNodes.a) do n.active = false end
    for _, n in ipairs(J.lodNodes.b) do n.active = true end
    J.lodUntil = env.frameNo + (frames or 30)
  end
  function J.lodBack()
    for _, n in ipairs(J.lodNodes.a) do n.active = true end
    for _, n in ipairs(J.lodNodes.b) do n.active = false end
    for i = 1, #J.meshes do
      local m = J.meshes[i]
      if not m.disposed and m.lod == 'A' and not m.visible then env.writeVisible(m, true, 'jammer') end
    end
  end

  -- Session reset: AC puts its LEDs back (shown, emissive black) and CSP fires the session callback.
  function J.sessionReset()
    for i = 1, #J.meshes do
      local m = J.meshes[i]
      if not m.disposed then
        if not m.visible then env.writeVisible(m, true, 'jammer') end
        env.writeEmissive(J.materials[i], 0, 0, 0, 'jammer')
      end
    end
    if env.callbacks.session then env.callbacks.session(0, true) end
  end

  return J
end
