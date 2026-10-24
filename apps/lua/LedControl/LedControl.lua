-- LedControl: takes over the LEDs on the player's steering wheel and dash.
-- Entry point: every callback runs under the error boundary (src/safety.lua); on an error, on the master switch, on
-- unload (ac.onRelease) and on every restart the car gets its own LEDs back.

local safety = require('src/safety')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local hotkeys = require('src/hotkeys')
local mainWindow = require('src/ui/main')

safety.onHalt(runtime.halt)

ac.onRelease(function ()
  pcall(takeover.dispose)
end)

ac.onSessionStart(function ()
  runtime.restart('session')
end)

local function draw3D() takeover.draw3D() end
render.on('main.root.transparent', function ()
  safety.run('kreslení', draw3D)
end)

local function update(dt)
  hotkeys.update()
  runtime.update(dt)
end

function script.update(dt)
  safety.run('update', update, dt)
end

function script.frameBegin(dt)
  safety.run('frameBegin', takeover.frameBegin)
end

function script.windowMain(dt)
  mainWindow.draw()
end
