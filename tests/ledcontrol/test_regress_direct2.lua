local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame, seenOf = H.frame, H.seenOf

H.formulaCar(1)
env.acWrites = 'material'
env.storage = { lc_method = 3 }
local app = H.loadApp()
frame(3)
app.runtime.setPreset('builtin:minimal')     -- base 'original': the car shows its own RPM lights
env.car.rpm = 12000; frame(5)
local _, hiG = seenOf('RPM_LED_1')
env.car.rpm = 5000; frame(5)
local _, loG = seenOf('RPM_LED_1')
print('method', app.takeover.method, 'split', app.takeover.stats.split, string.format('LED1 g at 12000=%.1f at 5000=%.1f', hiG, loG))
check(near(hiG, 30) and near(loG, 0), 'method C + Minimální: the car still drives its own RPM LED')
env.acWrites = 'mesh'
return H.finish('test_regress_direct2')
