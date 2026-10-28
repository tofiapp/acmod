local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame = H.frame
local U = env.ui

local seen = {}
local base = ui.colorButton
ui.colorButton = function (label, c, flags, size) seen[label] = { c = c, r = c.r, g = c.g, b = c.b }; return base(label, c, flags, size) end

H.formulaCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
-- the picker writes (0.33, 0.9, 0.25) into the Diody preview swatch of LED 1 (as ImGui's picker does while dragging)
env.windowOpen = true
U.tab = 'Diody'
U.pick = { ['##led1'] = { 0.33, 0.9, 0.25 } }
frame(1)
U.pick = nil
frame(1)   -- next frame: what the swatch hands the picker before it edits again
local s = seen['##led1']
print(string.format('value handed to the picker on the next frame: %.4f %.4f %.4f', s.r, s.g, s.b))
check(near(s.r, 0.33) and near(s.g, 0.9) and near(s.b, 0.25), 'Diody swatch keeps the picker value between frames (as tab_lights/tab_scenarios do)')
return H.finish('test_regress_pick')
