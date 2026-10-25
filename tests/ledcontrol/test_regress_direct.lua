local appDir, tmpDir, mockPath, helpersPath = ...
local H = dofile(helpersPath)(appDir, tmpDir, mockPath)
local env, check, near = H.env, H.check, H.near
local frame, seenOf, mode = H.frame, H.seenOf, H.mode
local app

-- AC keeps writing the material each LED had at load (the case test_ledcontrol section 5 already models)
H.formulaCar(1)
env.acWrites = 'material'
env.storage = { lc_method = 3 }; env.startMode = 5      -- method C, test pattern "all white"
app = H.loadApp()
frame(3)
local tk, rt = app.takeover, app.runtime
print('method', tk.method, 'split', tk.stats.split)
-- before: LED 1 is lit by AC above its threshold (RPM_SWITCH 9200), dark below
-- now give the LEDs back: master switch off
app.config.set('master', false)
frame(3)
env.car.rpm = 12000; frame(3)
local hiR, hiG = seenOf('RPM_LED_1')
env.car.rpm = 5000; frame(3)
local loR, loG = seenOf('RPM_LED_1')
print(string.format('after master off: rpm 12000 -> g=%.1f, rpm 5000 -> g=%.1f', hiG, loG))
check(near(hiG, 30) and near(loG, 0), 'master off gives RPM_LED_1 back to AC (lit at 12000, dark at 5000)')
env.acWrites = 'mesh'
return H.finish('test_regress_direct')
