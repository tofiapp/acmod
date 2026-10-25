local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, frame = H.env, H.check, H.frame
H.formulaCar(1)
env.storage = {}
local app = H.loadApp()
frame(3)
local rt, S = app.runtime, app.config.S
app.config.set('master', false)
frame(3)
print('before: master =', S.master, ' state =', rt.state)
local function clickIn(label) env.windowOpen = true; env.ui.tab = 'Nastavení'; env.ui.click = label; frame(1); env.ui.click = nil end
app.config.set('intensity', 70)
clickIn('Výchozí nastavení##defaults')
clickIn('Opravdu obnovit? Klikněte znovu##defaults')
frame(5)
print('after "Obnovit výchozí nastavení": master =', S.master, ' state =', rt.state)
check(S.intensity == 25, 'the defaults were restored (brightness back to 25)')
check(S.master == false, 'restoring defaults keeps the master switch as the driver set it')
return H.finish('test_regress_ux_restore')
