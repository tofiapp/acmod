local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
H.formulaCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
local rt, S = app.runtime, app.config.S
print('car profile preset:', tostring(rt.profile.preset), ' current preset:', rt.presetId)
env.windowOpen, env.ui.tab = true, 'Nastavení'
env.ui.openCombo = '##defaultPreset'
env.ui.click = 'Minimální'
frame(1)
env.ui.click, env.ui.openCombo = nil, nil
frame(3)
print('after choosing default "Minimální":', 'S.defaultPreset=', S.defaultPreset, ' car without own choice uses:', rt.presetId)
check(rt.presetId == 'builtin:minimal', 'a car without its own choice follows the new default preset')
return H.finish('test_regress_ux_default')
