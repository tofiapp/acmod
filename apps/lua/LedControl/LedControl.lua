-- LedControl: takes over the LEDs on the player's steering wheel and dash (and, in tab Světla, the car's lights).
-- Entry point: every callback runs under the error boundary (src/safety.lua); on an error, on the master switch, on
-- unload (ac.onRelease) and on every restart the car gets its own LEDs and lights back.

local config = require('src/config')
local safety = require('src/safety')
local runtime = require('src/runtime')
local takeover = require('src/takeover')
local lights = require('src/lights')
local hotkeys = require('src/hotkeys')
local mainWindow = require('src/ui/main')

local S = config.S

runtime.init()
safety.onHalt(runtime.halt)

ac.onRelease(function ()
  pcall(runtime.halt)
end)

ac.onSessionStart(function ()
  runtime.restart('session')
end)

hotkeys.on('master', function () config.set('master', not S.master) end)
hotkeys.on('nextPreset', function () runtime.cyclePreset() end)
hotkeys.on('flash', function () lights.flash() end)

local function draw3D()
  takeover.draw3D()
  lights.draw3D()
end
render.on('main.root.transparent', function ()
  safety.run('kreslení', draw3D)
end)

local function update(dt)
  hotkeys.update()
  runtime.update(dt)
end

local function frameBegin()
  takeover.frameBegin()
  lights.frameBegin()
end

function script.update(dt)
  safety.run('update', update, dt)
end

function script.frameBegin(dt)
  safety.run('frameBegin', frameBegin)
end

function script.windowMain(dt)
  mainWindow.draw()
end
