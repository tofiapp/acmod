local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check = H.env, H.check
local frame = H.frame

H.formulaCar(1)
env.storage = { lc_method = 2 }; env.startMode = 5      -- method B (redraw), all white
local app = H.loadApp()
frame(3)
print('method', app.takeover.method)
local function ancestorsActive(m)
  local p = m.parent
  while p do if p.active == false then return false end p = p.parent end
  return true
end
local inactiveDrawn, total = 0, 0
for mesh, d in pairs(env.draws) do
  if d.frame == env.frameNo then
    total = total + 1
    if not ancestorsActive(mesh) then inactiveDrawn = inactiveDrawn + 1 end
  end
end
print('draws this frame', total, 'of meshes under an inactive LOD root', inactiveDrawn)
check(inactiveDrawn == 0, 'redraw draws only instances whose whole node chain is active')
return H.finish('test_regress_redraw')
